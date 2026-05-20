//! Multi-profile tab strip.
//!
//! Linux analogue of darwin's `terminal/tabstrip.zig`. A horizontal
//! row of `GtkButton` chips, one per session, with the active profile
//! marked via a `.djinn-tab-active` CSS class. Mouse click activates
//! the profile through a caller-supplied callback; keyboard switching
//! (`Ctrl+Tab` / `Ctrl+Shift+Tab` / `Alt+1..9`) lives in keymap.zig
//! and reaches the same SessionHost.activate path.
//!
//! Hidden when `sm.count() < 2` — a single-profile setup has nothing
//! to switch between, so an always-visible single chip would just be
//! chrome. main_linux passes the strip's `widget()` into a vertical
//! GtkBox above the existing GtkPaned, so toggling visibility leaves
//! the rest of the layout untouched (hidden widgets don't claim any
//! row height).
//!
//! Lifetime:
//!
//!   - The strip is built once at startup. Hot-reload reconcile (add
//!     / remove profile rows on watcher fire) lands with the rest of
//!     the linux analogue of `src/session/live.zig`.
//!   - Per-button `clicked` signal handlers are connected during
//!     `init`; ids are stashed so `deinit` can disconnect before any
//!     parent destroy chain frees the slot user_data. Without that,
//!     a click queued on the GLib main loop could dispatch into freed
//!     memory mid-shutdown.
//!   - Labels are heap-duped (sentinel-terminated) on `init` so the C
//!     `gtk_button_new_with_label` pointer outlives any reload that
//!     swaps the Config arena.
//!
//! Theming:
//!
//!   - Module-local `GtkCssProvider` reloaded in place on `applyTheme`
//!     (same pattern as `log_pane.zig` / `theme.zig`). Stacking
//!     providers on each apply leaves orphan rules behind — bug we
//!     already paid for once in log_pane, no need to relearn it.
//!   - Active chip gets an accent underline drawn in `palette[4]`
//!     (blue ANSI slot) with `@accent_color` as the GTK-named-color
//!     fallback. Same semantic darwin uses for the active tab
//!     indicator: an accent color, not a contrast flip.
//!   - The strip's own background mirrors the resolved terminal
//!     background + opacity so the row visually continues the VTE
//!     paint instead of breaking it with a GTK theme stripe.
//!
//! What this module doesn't do (deferred):
//!
//!   - Drag-to-reorder. Needs profile-config rewrites the same way
//!     darwin would (config file is the source of truth, manual drag
//!     edits to disk are out of scope for the MVP).
//!   - Close-button per chip. Same reason — closing a session removes
//!     a profile entry, which is a config edit. Restart-session
//!     (`Ctrl+R`) covers the "re-spawn this shell" need without
//!     mutating config.
//!   - New-tab button. Profile creation is a config edit; the
//!     palette switcher (Phase 2) covers fast jumps between existing
//!     profiles.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const SessionManager = @import("../../session/manager.zig").SessionManager;
const ThemeOptions = @import("terminal.zig").ThemeOptions;

const GtkWidget = gtk.GtkWidget;
const GdkDisplay = gtk.GdkDisplay;
const GtkCssProvider = gtk.GtkCssProvider;
const GObject = gtk.GObject;
const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

const g_signal_connect_data = gtk.g_signal_connect_data;
const g_signal_handler_disconnect = gtk.g_signal_handler_disconnect;
const g_object_unref = gtk.g_object_unref;
const gtk_css_provider_new = gtk.gtk_css_provider_new;
const gtk_css_provider_load_from_string = gtk.gtk_css_provider_load_from_string;
const gtk_style_context_add_provider_for_display = gtk.gtk_style_context_add_provider_for_display;
const gdk_display_get_default = gtk.gdk_display_get_default;
const gtk_widget_set_visible = gtk.gtk_widget_set_visible;

// ─── GtkBox + GtkButton extern surface ───────────────────────────────

const GtkBox = opaque {};
const GtkButton = opaque {};

// GtkOrientation: HORIZONTAL=0, VERTICAL=1.
const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
const GTK_ORIENTATION_VERTICAL: c_int = 1;
// Matches GTK_STYLE_PROVIDER_PRIORITY_APPLICATION — above theme.
const STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;

extern "c" fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
extern "c" fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;
extern "c" fn gtk_button_new_with_label(label: [*:0]const u8) *GtkWidget;
extern "c" fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
extern "c" fn gtk_widget_remove_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
extern "c" fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
extern "c" fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;

// ─── Public surface ──────────────────────────────────────────────────

/// Callback fired when a tab chip is clicked. `idx` is the session
/// index in `SessionManager.sessions`. Main_linux wires this onto
/// `SessionHost.activate` — pulling the typed dependency out keeps
/// tab_strip free of session_host.zig (which in turn carries an
/// optional `*TabStrip` slot for the reverse direction without a
/// circular import).
pub const OnActivate = struct {
    ctx: *anyopaque,
    on_invoke: *const fn (ctx: *anyopaque, idx: usize) bool,
};

/// Per-button user_data. Each button's `clicked` handler reads its
/// slot to recover both the tab strip pointer and the session index
/// the chip represents. Slots live on `TabStrip.slots` and the strip
/// reserves capacity up front in `init` so the pointers handed to
/// `g_signal_connect_data` stay stable for the strip's lifetime.
const Slot = struct {
    strip: *TabStrip,
    idx: usize,
};

pub const TabStrip = struct {
    allocator: std.mem.Allocator,
    sm: *SessionManager,
    on_activate: OnActivate,
    container: *GtkWidget,
    provider: *GtkCssProvider,
    /// One entry per session. Indexed by session index — `buttons[i]`
    /// is the chip for `sm.sessions.items[i]`. `clicked_ids[i]` is the
    /// signal id for the same button's `clicked` handler.
    buttons: std.ArrayList(*GtkWidget) = .{},
    clicked_ids: std.ArrayList(c_ulong) = .{},
    slots: std.ArrayList(Slot) = .{},
    /// Owned sentinel-terminated label buffers (one per chip). Held
    /// for the strip's lifetime so the C-side `GtkButton` label
    /// pointer stays valid past Config-reload arena drops.
    label_bufs: std.ArrayList([:0]u8) = .{},
    /// Cached at init + refreshed by `applyTheme` so the rebuild path
    /// (when hot-reload reconcile lands) can re-skin without main_linux
    /// re-passing the theme.
    theme_opts: ThemeOptions,

    /// Build the strip + one chip per session. The active session's
    /// chip gets `.djinn-tab-active` from the start so the first
    /// paint shows the correct indicator without waiting for a switch
    /// event. Strip is hidden when `sm.count() < 2`.
    pub fn init(
        allocator: std.mem.Allocator,
        sm: *SessionManager,
        on_activate: OnActivate,
        theme_opts: ThemeOptions,
    ) !TabStrip {
        const container = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_add_css_class(container, "djinn-tab-strip");

        // Module-local CSS provider. Reload-in-place via
        // `gtk_css_provider_load_from_string` on each `applyTheme` —
        // stacking new providers would leave orphan rules across
        // theme changes.
        const provider = gtk_css_provider_new();
        if (gdk_display_get_default()) |display| {
            gtk_style_context_add_provider_for_display(
                display,
                @ptrCast(provider),
                STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }

        var self: TabStrip = .{
            .allocator = allocator,
            .sm = sm,
            .on_activate = on_activate,
            .container = container,
            .provider = provider,
            .theme_opts = theme_opts,
        };
        // The buildButtons path mutates self.* — taking &self once
        // here avoids re-creating the receiver inside the loop.
        try self.buildButtons();
        self.applyTheme(theme_opts);
        gtk_widget_set_visible(container, if (sm.count() > 1) 1 else 0);
        return self;
    }

    pub fn deinit(self: *TabStrip) void {
        for (self.buttons.items, self.clicked_ids.items) |b, id| {
            if (id != 0) g_signal_handler_disconnect(@ptrCast(b), id);
        }
        for (self.label_bufs.items) |buf| self.allocator.free(buf);
        self.buttons.deinit(self.allocator);
        self.clicked_ids.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.label_bufs.deinit(self.allocator);
        // The container + buttons themselves are owned by their parent
        // GtkBox / GtkWindow — GTK reclaims them when the window
        // destroys. We only own the CSS provider's local ref.
        g_object_unref(@ptrCast(self.provider));
    }

    /// The outer GtkBox the caller embeds into the panel layout.
    /// Usually fed to `pairWithChild` which wraps a (strip, content)
    /// pair into a vertical GtkBox.
    pub fn widget(self: *TabStrip) *GtkWidget {
        return self.container;
    }

    /// Pair the strip with the rest of the panel content (typically
    /// the GtkPaned that holds the VTE + log pane) inside a vertical
    /// GtkBox. The strip stays at its natural height; `bottom` gets
    /// `vexpand` so the remaining height flows to the terminal area.
    ///
    /// Mirrors `LogPane.pairWithSibling` — keeps main_linux free of
    /// raw GtkBox externs so the per-feature widget-tree wiring
    /// lives in the module that owns the widget.
    pub fn pairWithChild(self: *TabStrip, bottom: *GtkWidget) *GtkWidget {
        const vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_box_append(@ptrCast(vbox), self.container);
        gtk_box_append(@ptrCast(vbox), bottom);
        gtk_widget_set_vexpand(bottom, 1);
        return vbox;
    }

    /// Re-apply the active-row CSS class. Called from SessionHost via
    /// its `on_switch` hook so every activate (click, keymap, palette)
    /// flows through one update path. Idempotent: re-asserting the
    /// same idx is a couple of class-add/remove calls per button and
    /// GTK's CSS engine no-ops on equality.
    pub fn markActive(self: *TabStrip, idx: usize) void {
        for (self.buttons.items, 0..) |button, i| {
            if (i == idx) {
                gtk_widget_add_css_class(button, "djinn-tab-active");
            } else {
                gtk_widget_remove_css_class(button, "djinn-tab-active");
            }
        }
    }

    /// Reload the strip's CSS from `opts`. Mirrors
    /// `Terminal.applyTheme` / `LogPane.applyTheme` so the watcher's
    /// config-change handler can drive all three at once. Reload-in-
    /// place via `gtk_css_provider_load_from_string`.
    pub fn applyTheme(self: *TabStrip, opts: ThemeOptions) void {
        self.theme_opts = opts;
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        writeThemedCss(self.allocator, &buf, opts) catch |err| {
            std.debug.print(
                "tab_strip: CSS build failed: {} — keeping previous styles\n",
                .{err},
            );
            return;
        };
        // `gtk_css_provider_load_from_string` is C; null-terminate so
        // the parser stops at the right byte. Without this it reads
        // into uninitialized capacity / neighbouring allocations and
        // emits garbage "Expected '{' after selectors" Gtk-WARNINGs;
        // the bug was latent here until a second provider (palette)
        // shifted allocator layout. log_pane has the same `append(0)`.
        buf.append(self.allocator, 0) catch return;
        gtk_css_provider_load_from_string(self.provider, @ptrCast(buf.items.ptr));
    }

    fn buildButtons(self: *TabStrip) !void {
        const n = self.sm.count();
        // Reserve once. After this point, appending up to `n` items
        // never reallocs, so `&self.slots.items[i]` is a stable
        // pointer for the GTK signal user_data slot.
        try self.buttons.ensureTotalCapacity(self.allocator, n);
        try self.clicked_ids.ensureTotalCapacity(self.allocator, n);
        try self.slots.ensureTotalCapacity(self.allocator, n);
        try self.label_bufs.ensureTotalCapacity(self.allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const profile = self.sm.sessions.items[i].profile;
            // Heap-dup the profile label as a sentinel-terminated buffer
            // so the C side can hold the pointer directly. Profile
            // labels are short (typically <32 chars); no truncation cap.
            const src = profile.label();
            const label = try self.allocator.allocSentinel(u8, src.len, 0);
            @memcpy(label, src);
            self.label_bufs.appendAssumeCapacity(label);

            const button = gtk_button_new_with_label(label.ptr);
            gtk_widget_add_css_class(button, "djinn-tab");
            if (i == self.sm.active_idx) {
                gtk_widget_add_css_class(button, "djinn-tab-active");
            }
            self.buttons.appendAssumeCapacity(button);
            self.slots.appendAssumeCapacity(.{ .strip = self, .idx = i });

            // Connect AFTER appending the slot so `&self.slots.items[i]`
            // resolves to the just-pushed entry. Capacity was reserved
            // up front so this pointer doesn't get invalidated by a
            // later append.
            const slot_ptr = &self.slots.items[i];
            const id = g_signal_connect_data(
                @ptrCast(button),
                "clicked",
                @ptrCast(&onClicked),
                @ptrCast(slot_ptr),
                null,
                0,
            );
            self.clicked_ids.appendAssumeCapacity(id);
            gtk_box_append(@ptrCast(self.container), button);
        }
    }
};

/// GtkButton `clicked` signal shape: `(GtkButton *button, gpointer user_data)`.
/// We ignore the button pointer (the slot carries everything we need)
/// and dispatch through the caller-supplied OnActivate hook.
fn onClicked(_: *GObject, user_data: gpointer) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(user_data orelse return));
    _ = slot.strip.on_activate.on_invoke(slot.strip.on_activate.ctx, slot.idx);
}

// ─── Theming ─────────────────────────────────────────────────────────

/// Build the tab-strip CSS into `buf`. Null theme fields fall back to
/// GTK named colors so a no-inheritance setup still reads coherently.
///
/// Palette indices follow the standard 16-color ANSI layout:
///   0 black  1 red  2 green  3 yellow  4 blue  5 magenta  6 cyan  7 white
/// `palette[4]` (blue) is the active-tab accent — matches what darwin
/// uses for the active tab indicator. Falls back to GTK 4.10+
/// `@accent_color`, then to `@theme_selected_bg_color` for older GTK.
fn writeThemedCss(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    opts: ThemeOptions,
) !void {
    const w = buf.writer(allocator);

    // Strip background mirrors the resolved VTE background + opacity
    // so the chip row visually continues the terminal paint instead
    // of breaking it with a GTK theme stripe.
    if (opts.background) |bg| {
        const alpha = opts.opacity orelse 1.0;
        try w.print(
            "box.djinn-tab-strip {{\n" ++
                "  background-color: rgba({d}, {d}, {d}, {d:.2});\n" ++
                "  background-image: none;\n" ++
                "  padding: 4px 6px 0 6px;\n" ++
                "}}\n",
            .{ bg.r, bg.g, bg.b, alpha },
        );
    } else {
        try w.writeAll(
            \\box.djinn-tab-strip {
            \\  background-color: transparent;
            \\  background-image: none;
            \\  padding: 4px 6px 0 6px;
            \\}
            \\
        );
    }

    // Inactive chip: dim foreground, no fill, no border. The strip
    // shows them in a single row so they read as a tab strip rather
    // than a row of standalone buttons.
    if (opts.foreground) |fg| {
        try w.print(
            "button.djinn-tab {{\n" ++
                "  background-color: transparent;\n" ++
                "  background-image: none;\n" ++
                "  color: rgba({d}, {d}, {d}, 0.55);\n" ++
                "  border: none;\n" ++
                "  border-bottom: 2px solid transparent;\n" ++
                "  padding: 4px 12px;\n" ++
                "  margin: 0 2px;\n" ++
                "  border-radius: 0;\n" ++
                "  box-shadow: none;\n" ++
                "  font-weight: normal;\n" ++
                "}}\n" ++
                "button.djinn-tab:hover {{\n" ++
                "  background-color: rgba({d}, {d}, {d}, 0.08);\n" ++
                "  color: rgba({d}, {d}, {d}, 0.85);\n" ++
                "}}\n",
            .{
                fg.r, fg.g, fg.b,
                fg.r, fg.g, fg.b,
                fg.r, fg.g, fg.b,
            },
        );
    } else {
        try w.writeAll(
            \\button.djinn-tab {
            \\  background-color: transparent;
            \\  background-image: none;
            \\  color: alpha(@theme_fg_color, 0.55);
            \\  border: none;
            \\  border-bottom: 2px solid transparent;
            \\  padding: 4px 12px;
            \\  margin: 0 2px;
            \\  border-radius: 0;
            \\  box-shadow: none;
            \\  font-weight: normal;
            \\}
            \\button.djinn-tab:hover {
            \\  background-color: alpha(@theme_fg_color, 0.08);
            \\  color: alpha(@theme_fg_color, 0.85);
            \\}
            \\
        );
    }

    // Active chip: full-strength foreground + accent-color underline.
    // `border-bottom` on the inactive rule reserved 2px so the active
    // chip doesn't shift vertically when switching — the inactive
    // border is transparent, the active one is opaque accent.
    const accent = opts.palette[4];
    if (opts.foreground) |fg| {
        if (accent) |a| {
            try w.print(
                "button.djinn-tab.djinn-tab-active {{\n" ++
                    "  color: rgba({d}, {d}, {d}, 1.0);\n" ++
                    "  border-bottom: 2px solid rgb({d}, {d}, {d});\n" ++
                    "  font-weight: bold;\n" ++
                    "}}\n",
                .{ fg.r, fg.g, fg.b, a.r, a.g, a.b },
            );
        } else {
            try w.print(
                "button.djinn-tab.djinn-tab-active {{\n" ++
                    "  color: rgba({d}, {d}, {d}, 1.0);\n" ++
                    "  border-bottom: 2px solid @accent_color;\n" ++
                    "  font-weight: bold;\n" ++
                    "}}\n",
                .{ fg.r, fg.g, fg.b },
            );
        }
    } else {
        if (accent) |a| {
            try w.print(
                "button.djinn-tab.djinn-tab-active {{\n" ++
                    "  color: @theme_fg_color;\n" ++
                    "  border-bottom: 2px solid rgb({d}, {d}, {d});\n" ++
                    "  font-weight: bold;\n" ++
                    "}}\n",
                .{ a.r, a.g, a.b },
            );
        } else {
            try w.writeAll(
                \\button.djinn-tab.djinn-tab-active {
                \\  color: @theme_fg_color;
                \\  border-bottom: 2px solid @accent_color;
                \\  font-weight: bold;
                \\}
                \\
            );
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────

test "TabStrip CSS includes active selector" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    // Smoke check: the CSS must define the active-row selector — a
    // typo there means markActive silently no-ops.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "djinn-tab-active") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "border-bottom") != null);
}

test "TabStrip CSS uses palette[4] for accent when available" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var opts = ThemeOptions{};
    opts.palette[4] = .{ .r = 100, .g = 149, .b = 237 }; // cornflower-ish

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, opts);
    // Match on the resolved rgb triplet, not the named-color fallback.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rgb(100, 149, 237)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@accent_color") == null);
}

test "TabStrip CSS falls back to @accent_color when palette[4] is null" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@accent_color") != null);
}

test "TabStrip type compiles" {
    _ = TabStrip;
    _ = Slot;
    _ = OnActivate;
}
