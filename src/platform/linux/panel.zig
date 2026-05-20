//! Linux Panel: GTK4 borderless window + gtk4-layer-shell Quake-drop.
//!
//! When the compositor supports `wlr-layer-shell` (KDE / Hyprland /
//! sway / wlroots-likes), the window is initialized as a layer-shell
//! OVERLAY surface anchored to the top of the screen — always above
//! other clients, present on every workspace, visible over fullscreen
//! apps. When the protocol isn't reachable (GNOME), the same window
//! opens as a plain undecorated toplevel the user manages manually.
//!
//! Linkage:
//!   - `gtk4` + `gtk4-layer-shell-0` are linked via pkg-config in
//!     build.zig. layer-shell MUST precede gtk4 on the link line so
//!     ld.so loads it before libwayland — layer-shell overrides one
//!     libwayland-client symbol via interposition, and ld.so processes
//!     `DT_NEEDED` entries in declaration order. See build.zig.
//!   - On a compositor without wlr-layer-shell, `gtk_layer_is_supported`
//!     returns false; we skip the layer-shell init and the window opens
//!     as a normal toplevel.
//!   - `Panel.detect` dlopens libgtk-4 + libgtk4-layer-shell for the
//!     pre-open capability probe (diagnostic banner). The runtime path
//!     uses the linked symbols directly.
//!
//! GTK4 binding: hand-written `extern` declarations rather than
//! `@cImport <gtk/gtk.h>`. GTK's headers translate to thousands of
//! decls under `translate-c` and balloon compile time; the explicit
//! list trades easy extension for build speed and an auditable surface.

const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.os.tag == .linux)
    @cImport({
        @cInclude("dlfcn.h");
    })
else
    struct {};

const gtk = @import("gtk.zig");

// ─── GTK4 / GLib extern surface ──────────────────────────────────────
//
// Only the symbols Panel actually calls. Adding more is mechanical;
// keeping the list short keeps the contract auditable. Opaque types
// live in gtk.zig so cross-module widget passing stays type-compatible.

const GtkWidget = gtk.GtkWidget;
const GtkWindow = gtk.GtkWindow;
const GMainLoop = gtk.GMainLoop;
const GMainContext = gtk.GMainContext;
const GObject = gtk.GObject;
const gboolean = gtk.gboolean;
const gpointer = gtk.gpointer;

extern "c" fn gtk_init() void;
extern "c" fn gtk_window_new() *GtkWidget;
extern "c" fn gtk_window_set_decorated(window: *GtkWindow, setting: gboolean) void;
extern "c" fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
extern "c" fn gtk_window_get_default_size(window: *GtkWindow, width: *c_int, height: *c_int) void;
extern "c" fn gtk_widget_get_width(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_get_height(widget: *GtkWidget) c_int;
extern "c" fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
extern "c" fn gtk_window_set_resizable(window: *GtkWindow, resizable: gboolean) void;
extern "c" fn gtk_window_set_child(window: *GtkWindow, child: ?*GtkWidget) void;
extern "c" fn gtk_window_present(window: *GtkWindow) void;
extern "c" fn gtk_window_destroy(window: *GtkWindow) void;
extern "c" fn gtk_window_is_active(window: *GtkWindow) gboolean;
const gtk_widget_get_visible = gtk.gtk_widget_get_visible;
const gtk_widget_set_visible = gtk.gtk_widget_set_visible;
extern "c" fn gtk_widget_grab_focus(widget: *GtkWidget) gboolean;

// GdkSurface opaque-region control. GTK4 computes an opaque region
// from the painted contents and forwards it to the compositor via
// `wl_surface.set_opaque_region`. When VTE's bg alpha is set but
// GTK doesn't propagate that to the calculation (the VTE-on-GTK4
// path is historically imprecise here), the compositor is told the
// surface is opaque and skips alpha blending. Calling
// `gdk_surface_set_opaque_region(surface, NULL)` forces "no opaque
// region" — every pixel is treated as alpha-capable.
const GdkSurface = opaque {};
extern "c" fn gtk_native_get_surface(self: *anyopaque) ?*GdkSurface;
extern "c" fn gdk_surface_set_opaque_region(surface: *GdkSurface, region: ?*anyopaque) void;

extern "c" fn g_main_loop_new(context: ?*GMainContext, is_running: gboolean) *GMainLoop;
extern "c" fn g_main_loop_run(loop: *GMainLoop) void;
extern "c" fn g_main_loop_quit(loop: *GMainLoop) void;
extern "c" fn g_main_loop_unref(loop: *GMainLoop) void;

// GLib main-loop source return values. G_SOURCE_CONTINUE (1) keeps
// the source alive across ticks; G_SOURCE_REMOVE (0) drops it.
// `g_timeout_add`, `g_source_remove`, `g_signal_connect_data`,
// `g_signal_handler_disconnect` all live in `gtk.zig` now — shared
// across panel / terminal / log_pane / tray / watcher.
const G_SOURCE_CONTINUE: c_int = 1;
const G_SOURCE_REMOVE: c_int = 0;
const g_timeout_add = gtk.g_timeout_add;
const g_source_remove = gtk.g_source_remove;
const g_signal_connect_data = gtk.g_signal_connect_data;
const g_signal_handler_disconnect = gtk.g_signal_handler_disconnect;

// ─── gtk4-layer-shell extern surface ─────────────────────────────────
//
// Statically linked via pkg-config (see build.zig). Direct externs
// because the link order is what makes the symbol interposition work
// — runtime dlopen would be too late.

/// gtk4-layer-shell layer constants. Matches the enum in
/// `gtk-layer-shell.h`. OVERLAY (the highest layer) sits above normal
/// toplevels AND fullscreen clients — what `window-topmost = true`
/// translates to. TOP sits above normal toplevels but below true
/// overlay surfaces like screen-lockers, which is what
/// `window-topmost = false` lands on: the panel still floats over
/// regular work but a fullscreen video or a screen-locker can cover
/// it. Going below TOP defeats the Quake-drop purpose entirely.
const LAYER_TOP: c_int = 2;
const LAYER_OVERLAY: c_int = 3;
/// Anchor edges. Anchoring to TOP keeps the panel pinned to the screen
/// top regardless of resize; the host shell controls width via
/// gtk_window_set_default_size. Edge constants: LEFT=0, RIGHT=1, TOP=2,
/// BOTTOM=3.
const ANCHOR_EDGE_TOP: c_int = 2;
/// Keyboard interactivity. gtk4-layer-shell enum:
///   NONE = 0       (events pass through to whatever's below)
///   EXCLUSIVE = 1  (always grab keyboard focus, blocks Alt-Tab)
///   ON_DEMAND = 2  (grab focus when the layer is the active surface)
const KEYBOARD_MODE_ON_DEMAND: c_int = 2;

extern "c" fn gtk_layer_init_for_window(window: *GtkWindow) void;
extern "c" fn gtk_layer_set_layer(window: *GtkWindow, layer: c_int) void;
extern "c" fn gtk_layer_set_anchor(window: *GtkWindow, edge: c_int, anchor_to_edge: gboolean) void;
extern "c" fn gtk_layer_set_keyboard_mode(window: *GtkWindow, mode: c_int) void;
extern "c" fn gtk_layer_set_namespace(window: *GtkWindow, name_space: [*:0]const u8) void;
/// Runtime probe: is the compositor advertising wlr-layer-shell? GNOME
/// returns false here so we can degrade behavior (skip the layer-shell
/// init and accept a plain toplevel) instead of leaving the warning
/// stream on. The lib loads fine either way.
extern "c" fn gtk_layer_is_supported() gboolean;

// ─── Capability probe ────────────────────────────────────────────────

pub const Capabilities = struct {
    gtk4: bool,
    layer_shell: bool,
    wayland: bool,
    desktop: []const u8,

    pub fn quakeDropAvailable(self: Capabilities) bool {
        return self.gtk4 and self.layer_shell and self.wayland;
    }
};

// ─── Panel ───────────────────────────────────────────────────────────

/// Borderless GTK4 window. `open` initializes GTK, creates the
/// undecorated toplevel, layers it via gtk4-layer-shell when available,
/// shows it, and returns control. The window is reachable via the
/// `window` pointer; the GLib main loop is owned by the caller via
/// `runLoop` / `quit`.
pub const Panel = struct {
    window: *GtkWindow,
    loop: *GMainLoop,
    /// True when the compositor advertises wlr-layer-shell and we
    /// successfully initialized the window as a layer surface. False
    /// when the compositor doesn't support the protocol (GNOME) — the
    /// window is still open, just as a normal toplevel.
    layer_shell_active: bool,
    /// Auto-hide when the window loses keyboard focus. Toggled via
    /// `setHideOnBlur` from `main_linux.zig` — true mirrors darwin's
    /// `NSWindow.setHidesOnDeactivate`. The signal is connected on
    /// first enable and gated by this flag thereafter so the watcher
    /// can flip behavior live without disconnecting / re-connecting.
    hide_on_blur: bool = false,
    /// Signal id for the `notify::is-active` handler, 0 when not yet
    /// connected. Stored so we connect at most once even if
    /// `setHideOnBlur(true)` is called multiple times.
    blur_handler_id: c_ulong = 0,
    /// Signal ids for the `close-request` and `map` handlers wired in
    /// `open`. Stashed so `deinit` can disconnect them before
    /// `gtk_window_destroy` — otherwise a teardown that races a
    /// pending dispatch (e.g. an in-flight `map` after `hide` / `show`
    /// during shutdown) would deref freed memory through `user_data`.
    close_handler_id: c_ulong = 0,
    map_handler_id: c_ulong = 0,
    /// User-supplied resize callback + context (typed opaquely so the
    /// Panel module doesn't depend on `Dispatch` from main_linux). Set
    /// via `setOnResize`; nil until then. Fires on the GLib main
    /// thread when the polled size differs from the last-seen value.
    on_resize_ctx: ?*anyopaque = null,
    on_resize_cb: ?*const fn (ctx: *anyopaque, w: u32, h: u32) void = null,
    /// `g_timeout_add` tag for the resize-poll, 0 when not running.
    /// GTK4 doesn't surface a reliable "I was resized" signal on the
    /// GtkWindow level (default-width/-height are app-set hints, not
    /// user-resize observers; GdkSurface.layout fires before the
    /// allocation settles), so we poll the allocated width/height on
    /// a slow tick instead. The `persist.saveDebounced` consumer
    /// already coalesces, so a once-per-500ms cadence is cheap and
    /// converges to a single disk write per drag.
    resize_poll_id: c_uint = 0,
    /// Last (w, h) the poll handed to the callback. Bootstrapped to
    /// (0, 0) so the first poll-tick that sees a non-zero allocation
    /// fires the callback — that captures the initial settled size
    /// without requiring an explicit kickoff call.
    last_polled_width: c_int = 0,
    last_polled_height: c_int = 0,

    pub fn detect(allocator: std.mem.Allocator) !Capabilities {
        const gtk4 = canDlopen("libgtk-4.so.1");
        const layer_shell = canDlopen("libgtk4-layer-shell.so.0");

        const wayland = std.posix.getenv("WAYLAND_DISPLAY") != null;

        const desktop_src = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse "";
        // OOM here used to swallow the failure and substitute "" —
        // a downstream caller reading `caps.desktop` couldn't tell
        // "real unknown desktop" from "allocator was out of memory
        // and we lied". Surface the error instead so the caller
        // logs it; the probe is on the hot startup path and the
        // user would otherwise see a mysterious GNOME-fallback code
        // path engage on a Plasma session.
        const desktop = try allocator.dupe(u8, desktop_src);

        return .{
            .gtk4 = gtk4,
            .layer_shell = layer_shell,
            .wayland = wayland,
            .desktop = desktop,
        };
    }

    pub const OpenOptions = struct {
        width: c_int = 800,
        height: c_int = 400,
        title: [*:0]const u8 = "djinn",
    };

    /// Create the borderless window and (if available) layer-shell it
    /// to the top of the screen. GTK is initialized lazily here; calling
    /// `open` twice in the same process is undefined — there's one
    /// panel per process by design.
    pub fn open(opts: OpenOptions) !Panel {
        gtk_init();

        const widget = gtk_window_new();
        const window: *GtkWindow = @ptrCast(widget);

        gtk_window_set_decorated(window, 0);
        gtk_window_set_resizable(window, 1);
        gtk_window_set_default_size(window, opts.width, opts.height);
        gtk_window_set_title(window, opts.title);

        // Layer-shell init must happen before the window is mapped.
        // We haven't called gtk_window_present yet, so order is fine.
        // gtk_layer_is_supported() probes the Wayland registry for
        // wlr-layer-shell-v1; on GNOME it returns false and we skip
        // the init, leaving the window as a normal toplevel rather
        // than emitting "Failed to initialize layer surface" warnings.
        // `DJINN_NO_LAYER_SHELL=1` forces the plain-toplevel path even
        // when the compositor supports the protocol — used to diagnose
        // transparency / interaction quirks specific to layer surfaces.
        const layer_shell_supported = gtk_layer_is_supported() != 0;
        const layer_shell_disabled = blk: {
            const v = std.posix.getenv("DJINN_NO_LAYER_SHELL") orelse break :blk false;
            break :blk v.len > 0 and v[0] != '0';
        };
        const layer_shell_active = layer_shell_supported and !layer_shell_disabled;
        if (layer_shell_disabled) {
            std.debug.print("panel: DJINN_NO_LAYER_SHELL set — using plain toplevel\n", .{});
        }
        if (layer_shell_active) {
            gtk_layer_init_for_window(window);
            gtk_layer_set_namespace(window, "djinn");
            gtk_layer_set_layer(window, LAYER_OVERLAY);
            gtk_layer_set_anchor(window, ANCHOR_EDGE_TOP, 1);
            gtk_layer_set_keyboard_mode(window, KEYBOARD_MODE_ON_DEMAND);
        }

        const loop = g_main_loop_new(null, 0);

        // Quit the loop when the user closes the window (Esc + WM close
        // both fire `close-request`). Stash the loop pointer as the
        // signal's `data` so the callback knows which loop to quit.
        const close_id = g_signal_connect_data(
            @ptrCast(window),
            "close-request",
            @ptrCast(&onCloseRequest),
            @ptrCast(loop),
            null,
            0,
        );

        // Drop the surface's opaque region on every map. The surface
        // doesn't exist until the window is mapped, and a hide/show
        // toggle remaps it — `map` fires both times, so this catches
        // initial show + every subsequent re-show. Without this,
        // GTK4 tells the compositor the whole VTE area is opaque and
        // transparency never reaches the screen. See clearOpaqueRegion.
        const map_id = g_signal_connect_data(
            @ptrCast(window),
            "map",
            @ptrCast(&onMapped),
            @ptrCast(window),
            null,
            0,
        );

        gtk_window_present(window);

        return .{
            .window = window,
            .loop = loop,
            .layer_shell_active = layer_shell_active,
            .close_handler_id = close_id,
            .map_handler_id = map_id,
        };
    }

    /// Block on the GLib main loop. Returns when `quit` is called or
    /// the window's close-request signal fires.
    pub fn runLoop(self: *Panel) void {
        g_main_loop_run(self.loop);
    }

    pub fn quit(self: *Panel) void {
        g_main_loop_quit(self.loop);
    }

    /// Install `child` as the window's content. GTK4 windows hold a
    /// single child (vs GTK3's free-form container); higher-level
    /// layout (split pane, log column, find chip) lives inside a Box
    /// the caller passes here once those exist.
    pub fn attachChild(self: *Panel, child: *GtkWidget) void {
        gtk_window_set_child(self.window, child);
    }

    /// Move keyboard focus to `widget`. Used to ensure the VTE child
    /// (not the surrounding GtkPaned divider) receives keys on startup
    /// — without this, the paned can grab initial focus and shortcuts
    /// like Ctrl+Shift+C / Ctrl+Shift+V never reach VTE because GTK
    /// dispatches them up the paned's focus chain instead. Returns
    /// the GTK boolean as-is so callers can log when the focus grab
    /// silently fails (widget not focusable / not yet realized).
    pub fn focusChild(self: *Panel, widget: *GtkWidget) bool {
        _ = self;
        return gtk_widget_grab_focus(widget) != 0;
    }

    /// Show the panel and bring it forward. On a layer-shell surface
    /// the compositor already keeps us on top; this just makes the
    /// surface mapped after a `hide` and re-establishes keyboard
    /// focus via gtk_window_present.
    pub fn show(self: *Panel) void {
        const widget: *GtkWidget = @ptrCast(self.window);
        gtk_widget_set_visible(widget, 1);
        gtk_window_present(self.window);
    }

    /// Unmap the panel. The window object survives; subsequent `show`
    /// re-maps the same surface so layer-shell anchor, size, and the
    /// embedded VTE state are all preserved across toggles.
    pub fn hide(self: *Panel) void {
        const widget: *GtkWidget = @ptrCast(self.window);
        gtk_widget_set_visible(widget, 0);
    }

    /// Update the window's preferred size. On a layer-shell surface
    /// the compositor controls final placement and may clip to anchor
    /// edges, so this is best-effort — for non-layer-shell toplevels
    /// (GNOME) it resizes immediately. Used by the config watcher to
    /// pick up `window-width` / `window-height` edits without a
    /// restart.
    pub fn setSize(self: *Panel, width: c_int, height: c_int) void {
        gtk_window_set_default_size(self.window, width, height);
    }

    /// Read the panel's current allocated size. Returns `0,0` until
    /// the window has been mapped + measured by GTK. On layer-shell
    /// this is the size the compositor settled on; on plain toplevel
    /// it's the user-resized size. Used by the resize-poll to detect
    /// changes.
    pub fn currentSize(self: *Panel) struct { w: c_int, h: c_int } {
        const widget: *GtkWidget = @ptrCast(self.window);
        return .{ .w = gtk_widget_get_width(widget), .h = gtk_widget_get_height(widget) };
    }

    /// Wire a callback that fires whenever the panel's allocated size
    /// changes. Idempotent — re-calling replaces the callback but
    /// reuses the underlying poll source. The callback runs on the
    /// GLib main thread; it must not block.
    ///
    /// Polls every 500ms via `g_timeout_add` rather than connecting
    /// to a GTK signal. GTK4 doesn't expose a public "the user
    /// resized me" signal on GtkWindow — `notify::default-width` is
    /// an app-set hint, not a user-resize observer, and GdkSurface
    /// `layout` fires too early for plain `gtk_widget_get_width` to
    /// see the post-configure value. Polling is simpler, dodges
    /// signal-timing pitfalls, and `persist.saveDebounced` already
    /// coalesces multiple emissions across a drag into a single
    /// disk write.
    pub fn setOnResize(
        self: *Panel,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, w: u32, h: u32) void,
    ) void {
        self.on_resize_ctx = ctx;
        self.on_resize_cb = cb;
        if (self.resize_poll_id == 0) {
            self.resize_poll_id = g_timeout_add(500, resizePollTick, @ptrCast(self));
        }
    }

    /// Enable or disable auto-hide on focus loss. First call with
    /// `enabled = true` connects to `notify::is-active`; the handler
    /// stays connected on subsequent disable/enable cycles and gates
    /// behavior via `self.hide_on_blur` — cheaper than wrestling
    /// with `g_signal_handler_disconnect` from the watcher path.
    pub fn setHideOnBlur(self: *Panel, enabled: bool) void {
        self.hide_on_blur = enabled;
        if (enabled and self.blur_handler_id == 0) {
            self.blur_handler_id = g_signal_connect_data(
                @ptrCast(self.window),
                "notify::is-active",
                @ptrCast(&onActiveChanged),
                @ptrCast(self),
                null,
                0,
            );
        }
    }

    /// Map `window-topmost` onto the layer-shell layer. On compositors
    /// that advertise wlr-layer-shell, true → OVERLAY (above
    /// fullscreen), false → TOP (above normal toplevels, below
    /// screen-lockers). On non-layer-shell compositors (GNOME plain
    /// toplevel) there's no portable GTK4 / Wayland API for
    /// always-on-top — the compositor decides — so this is a silent
    /// no-op there. Safe to call on either branch; the live-apply
    /// path doesn't have to special-case.
    pub fn setTopmost(self: *Panel, enabled: bool) void {
        if (!self.layer_shell_active) return;
        gtk_layer_set_layer(self.window, if (enabled) LAYER_OVERLAY else LAYER_TOP);
    }

    /// Drop the surface's opaque region so the compositor blends the
    /// whole window through. Defensive supplement to the CSS rules in
    /// `theme.zig::applyCss` — those parse cleanly under KWin Wayland
    /// and are the primary mechanism, but this catches compositors /
    /// VTE versions where GTK's auto-computed region claims the VTE
    /// area is solid. Idempotent; safe after any remap. No-op if the
    /// surface isn't realized yet (the `map` signal in `open` covers
    /// the timing — see onMapped).
    pub fn clearOpaqueRegion(self: *Panel) void {
        const surface = gtk_native_get_surface(@ptrCast(self.window)) orelse return;
        gdk_surface_set_opaque_region(surface, null);
    }

    /// One-call Quake-drop toggle. Whatever state the panel is in,
    /// flip it. Cheap; safe to call from any GLib main-loop context
    /// (signal callbacks, GIO source dispatches, idle handlers).
    pub fn toggle(self: *Panel) void {
        const widget: *GtkWidget = @ptrCast(self.window);
        if (gtk_widget_get_visible(widget) != 0) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn deinit(self: *Panel) void {
        if (self.resize_poll_id != 0) {
            _ = g_source_remove(self.resize_poll_id);
            self.resize_poll_id = 0;
        }
        // Disconnect signal handlers before destroying the window.
        // `close-request` and `map` hold the window itself in user_data
        // (harmless if the destroy happens first), but `notify::is-active`
        // captures `self` — a pending dispatch racing teardown would
        // deref freed memory. Symmetry across all three keeps the
        // pattern auditable.
        const obj: *GObject = @ptrCast(self.window);
        if (self.blur_handler_id != 0) {
            g_signal_handler_disconnect(obj, self.blur_handler_id);
            self.blur_handler_id = 0;
        }
        if (self.map_handler_id != 0) {
            g_signal_handler_disconnect(obj, self.map_handler_id);
            self.map_handler_id = 0;
        }
        if (self.close_handler_id != 0) {
            g_signal_handler_disconnect(obj, self.close_handler_id);
            self.close_handler_id = 0;
        }
        gtk_window_destroy(self.window);
        g_main_loop_unref(self.loop);
    }
};

/// Close-request handler. GTK calls this when the user dismisses the
/// window; returning FALSE lets the default handler proceed with the
/// destroy. We quit the main loop here so `runLoop` returns to the
/// caller for normal cleanup.
fn onCloseRequest(_: *GtkWindow, user_data: gpointer) callconv(.c) gboolean {
    if (user_data) |p| {
        const loop: *GMainLoop = @ptrCast(@alignCast(p));
        g_main_loop_quit(loop);
    }
    return 0;
}

/// `map` handler — fires once on first show and again on every
/// re-show after a hide/show toggle. Clears the GdkSurface's opaque
/// region so the compositor blends the whole window through. The
/// CSS rule alone covers the common case on KWin Wayland but this
/// is cheap defense for compositors / VTE versions where GTK's
/// auto-computed region claims the VTE area is solid.
fn onMapped(window: *GtkWidget, _: gpointer) callconv(.c) void {
    const surface = gtk_native_get_surface(@ptrCast(window)) orelse return;
    gdk_surface_set_opaque_region(surface, null);
}

/// `notify::is-active` handler — fires when the window's active state
/// flips (keyboard focus gained or lost). The signal carries a GParamSpec
/// as the second arg we don't use. When the panel transitions from
/// active to inactive and hide-on-blur is on, drop the surface so the
/// user-flow matches Raycast / Spotlight semantics: lose focus → tuck
/// away. Re-focus comes via the hotkey or IPC toggle.
fn onActiveChanged(
    window: *GtkWindow,
    _: ?*anyopaque,
    user_data: gpointer,
) callconv(.c) void {
    const self: *Panel = @ptrCast(@alignCast(user_data orelse return));
    if (!self.hide_on_blur) return;
    if (gtk_window_is_active(window) == 0) self.hide();
}

/// Resize-poll tick. Reads the window's allocated width/height,
/// fires the callback when either dimension actually changed (and
/// both are positive — pre-map measurements report zero), then
/// stashes the new values for the next tick to diff against. Stays
/// alive across ticks via G_SOURCE_CONTINUE. Drops itself
/// (G_SOURCE_REMOVE) if user_data is null — `deinit` clears the
/// source via `g_source_remove` in the normal path, so a null
/// user_data here means teardown is in flight and re-firing against
/// torn-down state would deref freed memory.
fn resizePollTick(user_data: gpointer) callconv(.c) c_int {
    const self: *Panel = @ptrCast(@alignCast(user_data orelse return G_SOURCE_REMOVE));
    const widget: *GtkWidget = @ptrCast(self.window);
    const w = gtk_widget_get_width(widget);
    const h = gtk_widget_get_height(widget);
    if (w <= 0 or h <= 0) return G_SOURCE_CONTINUE;
    if (w == self.last_polled_width and h == self.last_polled_height) return G_SOURCE_CONTINUE;
    self.last_polled_width = w;
    self.last_polled_height = h;
    if (self.on_resize_cb) |cb| {
        if (self.on_resize_ctx) |ctx| cb(ctx, @intCast(w), @intCast(h));
    }
    return G_SOURCE_CONTINUE;
}

/// `dlopen(name, RTLD_LAZY)` + immediate `dlclose`. Returns true when
/// the library is resolvable on the running system. Used only by the
/// capability probe — the actual runtime path links the symbols
/// statically (see build.zig).
fn canDlopen(name: [*:0]const u8) bool {
    if (builtin.os.tag != .linux) return false;
    const handle = c.dlopen(name, 1); // RTLD_LAZY
    if (handle == null) return false;
    _ = c.dlclose(handle);
    return true;
}

test "Panel.detect doesn't crash without env vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caps = try Panel.detect(arena.allocator());
    _ = caps;
}
