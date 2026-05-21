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
const AgentState = @import("../../agent/state.zig").AgentState;
const Agent = @import("../../agent/state.zig").Agent;

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
extern "c" fn gtk_widget_set_halign(widget: *GtkWidget, align_: c_int) void;
extern "c" fn gtk_widget_set_valign(widget: *GtkWidget, align_: c_int) void;
extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, w: c_int, h: c_int) void;

// GtkAlign enum: FILL=0, START=1, END=2, CENTER=3.
const GTK_ALIGN_END: c_int = 2;
const GTK_ALIGN_CENTER: c_int = 3;

const g_timeout_add = gtk.g_timeout_add;
const g_source_remove = gtk.g_source_remove;
const G_SOURCE_CONTINUE: c_int = 1;

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
    /// Small CSS-painted circle pinned to the trailing edge. Color
    /// per agent state (working / attention / error / idle-or-done);
    /// idle and done render transparent so the dot is invisible in
    /// the quiet state. Lives in the strip's GtkBox after the last
    /// chip with `hexpand=true; halign=END` so it gravitates to the
    /// right without disturbing chip layout.
    state_dot: *GtkWidget,
    /// Latest pushed state, used to skip no-op CSS class swaps.
    last_state: Agent = .idle,
    /// AgentState observed by `observeAgentState`. Null until
    /// wiring lands; the poll callback short-circuits while null.
    observed_state: ?*AgentState = null,
    /// `g_timeout_add` tag for the 250ms agent-state poll. 0 when
    /// not running; cleared in `deinit` so the timer doesn't fire
    /// against a freed strip after teardown.
    state_poll_id: c_uint = 0,

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

        // Agent-state dot. Created here (before buildButtons) so
        // the field assignment below can reach it, but appended to
        // the container AFTER the chips so it sits at the trailing
        // edge. The widget itself is an empty GtkBox; CSS draws the
        // colored circle via background-color + border-radius. Min
        // size 8x8 keeps the visual stable across GTK themes that
        // would otherwise inflate empty containers to their padding
        // minimum.
        const state_dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_add_css_class(state_dot, "djinn-state-dot");
        gtk_widget_add_css_class(state_dot, "djinn-state-dot-idle");
        gtk_widget_set_size_request(state_dot, 8, 8);
        gtk_widget_set_halign(state_dot, GTK_ALIGN_END);
        gtk_widget_set_valign(state_dot, GTK_ALIGN_CENTER);
        gtk_widget_set_hexpand(state_dot, 1);

        var self: TabStrip = .{
            .allocator = allocator,
            .sm = sm,
            .on_activate = on_activate,
            .container = container,
            .provider = provider,
            .theme_opts = theme_opts,
            .state_dot = state_dot,
        };
        // The buildButtons path mutates self.* — taking &self once
        // here avoids re-creating the receiver inside the loop.
        try self.buildButtons();
        // Dot lands AFTER chips so it pins to the trailing edge.
        gtk_box_append(@ptrCast(container), state_dot);
        self.applyTheme(theme_opts);
        gtk_widget_set_visible(container, if (sm.count() > 1) 1 else 0);
        return self;
    }

    pub fn deinit(self: *TabStrip) void {
        if (self.state_poll_id != 0) {
            _ = g_source_remove(self.state_poll_id);
            self.state_poll_id = 0;
        }
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

    /// Flip the exited CSS class on the chip at `idx`. Fed by the
    /// SessionHost `on_exit_changed` hook so the chip dims and gains
    /// a strikethrough when an inactive session's shell dies, and
    /// reverts when `restartActive` revives the slot. Out-of-bounds
    /// idx is a no-op; same-value flips are cheap (GTK skips
    /// duplicate class adds/removes).
    pub fn markExited(self: *TabStrip, idx: usize, exited: bool) void {
        if (idx >= self.buttons.items.len) return;
        const button = self.buttons.items[idx];
        if (exited) {
            gtk_widget_add_css_class(button, "djinn-tab-exited");
        } else {
            gtk_widget_remove_css_class(button, "djinn-tab-exited");
        }
    }

    /// Swap the trailing-edge dot's CSS class so its background
    /// color tracks the agent's state. Same-value calls are cheap
    /// (GTK no-ops on duplicate class adds/removes); same-state
    /// re-polls hit the early return above via `last_state`.
    pub fn markState(self: *TabStrip, state: Agent) void {
        const klass: [*:0]const u8 = stateClass(state);
        // Drop every state-specific class, then add the new one.
        // Cheaper than tracking the previous class string and
        // robust to a future re-init that left a stale class on
        // the widget.
        gtk_widget_remove_css_class(self.state_dot, "djinn-state-dot-idle");
        gtk_widget_remove_css_class(self.state_dot, "djinn-state-dot-working");
        gtk_widget_remove_css_class(self.state_dot, "djinn-state-dot-attention");
        gtk_widget_remove_css_class(self.state_dot, "djinn-state-dot-done");
        gtk_widget_remove_css_class(self.state_dot, "djinn-state-dot-error");
        gtk_widget_add_css_class(self.state_dot, klass);
        self.last_state = state;
    }

    /// Begin polling `state` on the GLib main thread at the same
    /// 250ms cadence the tray uses. The poll snapshots state under
    /// AgentState.mutex, releases the lock, then calls `markState`
    /// when the value differs from the last push. Idempotent;
    /// re-calling replaces the prior timer. Cleared in `deinit`.
    pub fn observeAgentState(self: *TabStrip, state: *AgentState) void {
        if (self.state_poll_id != 0) {
            _ = g_source_remove(self.state_poll_id);
            self.state_poll_id = 0;
        }
        self.observed_state = state;
        self.state_poll_id = g_timeout_add(250, pollStateTick, @ptrCast(self));
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

/// 250ms agent-state poll. Same shape as `tray.zig::pollAgentTick`:
/// snapshot under the AgentState mutex, release, then re-skin the
/// dot when state actually changed. Skipping the no-op rewrite
/// keeps GTK's CSS engine quiet during idle stretches.
fn pollStateTick(user_data: gpointer) callconv(.c) c_int {
    const self: *TabStrip = @ptrCast(@alignCast(user_data orelse return G_SOURCE_CONTINUE));
    const state = self.observed_state orelse return G_SOURCE_CONTINUE;

    var snap: Agent = .idle;
    {
        state.mutex.lock();
        defer state.mutex.unlock();
        snap = state.state;
    }
    if (snap == self.last_state) return G_SOURCE_CONTINUE;
    self.markState(snap);
    return G_SOURCE_CONTINUE;
}

/// CSS class name for each Agent value. Kept in one place so the
/// list in `markState` (remove-all-then-add) and the rules in
/// `writeThemedCss` (color per class) stay in lockstep.
fn stateClass(state: Agent) [*:0]const u8 {
    return switch (state) {
        .idle => "djinn-state-dot-idle",
        .working => "djinn-state-dot-working",
        .attention => "djinn-state-dot-attention",
        .done => "djinn-state-dot-done",
        .@"error" => "djinn-state-dot-error",
    };
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

    // Exited chip: heavily dim + line-through on the label. Highest-
    // specificity selector (3 classes) so it overrides the active
    // accent when the user activates an exited session — color is
    // muted, border-bottom stays at the active accent so the user
    // sees both "this is the focused slot" and "the shell here is
    // dead." Targets the inner `label` child because GTK4's
    // text-decoration property cascades through label nodes more
    // reliably than through the button's own node (KDE Breeze GTK4
    // theme paints button text via a `label` node specifically).
    if (opts.foreground) |fg| {
        try w.print(
            "button.djinn-tab.djinn-tab-exited {{\n" ++
                "  color: rgba({d}, {d}, {d}, 0.35);\n" ++
                "  font-style: italic;\n" ++
                "}}\n" ++
                "button.djinn-tab.djinn-tab-exited > label {{\n" ++
                "  text-decoration: line-through;\n" ++
                "}}\n" ++
                "button.djinn-tab.djinn-tab-exited:hover {{\n" ++
                "  color: rgba({d}, {d}, {d}, 0.6);\n" ++
                "}}\n",
            .{ fg.r, fg.g, fg.b, fg.r, fg.g, fg.b },
        );
    } else {
        try w.writeAll(
            \\button.djinn-tab.djinn-tab-exited {
            \\  color: alpha(@theme_fg_color, 0.35);
            \\  font-style: italic;
            \\}
            \\button.djinn-tab.djinn-tab-exited > label {
            \\  text-decoration: line-through;
            \\}
            \\button.djinn-tab.djinn-tab-exited:hover {
            \\  color: alpha(@theme_fg_color, 0.6);
            \\}
            \\
        );
    }

    // Agent-state dot at the trailing edge. Idle + done render
    // transparent so the strip is visually quiet during the resting
    // states; working / attention / error paint in the ANSI slot
    // colors that match the rest of djinn's chrome conventions:
    //   palette[4] (blue)  = working / info
    //   palette[3] (yellow)= attention / warn
    //   palette[1] (red)   = error / err
    // GTK named-color fallbacks mirror those semantic roles for
    // setups without ghostty palette inheritance.
    try w.writeAll(
        \\box.djinn-state-dot {
        \\  background-image: none;
        \\  border-radius: 50%;
        \\  min-width: 8px;
        \\  min-height: 8px;
        \\  margin-right: 8px;
        \\}
        \\box.djinn-state-dot.djinn-state-dot-idle,
        \\box.djinn-state-dot.djinn-state-dot-done {
        \\  background-color: transparent;
        \\}
        \\
    );
    if (opts.palette[4]) |c| {
        try w.print(
            "box.djinn-state-dot.djinn-state-dot-working {{\n" ++
                "  background-color: rgb({d}, {d}, {d});\n" ++
                "}}\n",
            .{ c.r, c.g, c.b },
        );
    } else {
        try w.writeAll(
            \\box.djinn-state-dot.djinn-state-dot-working {
            \\  background-color: @accent_color;
            \\}
            \\
        );
    }
    if (opts.palette[3]) |c| {
        try w.print(
            "box.djinn-state-dot.djinn-state-dot-attention {{\n" ++
                "  background-color: rgb({d}, {d}, {d});\n" ++
                "}}\n",
            .{ c.r, c.g, c.b },
        );
    } else {
        try w.writeAll(
            \\box.djinn-state-dot.djinn-state-dot-attention {
            \\  background-color: @warning_color;
            \\}
            \\
        );
    }
    if (opts.palette[1]) |c| {
        try w.print(
            "box.djinn-state-dot.djinn-state-dot-error {{\n" ++
                "  background-color: rgb({d}, {d}, {d});\n" ++
                "}}\n",
            .{ c.r, c.g, c.b },
        );
    } else {
        try w.writeAll(
            \\box.djinn-state-dot.djinn-state-dot-error {
            \\  background-color: @error_color;
            \\}
            \\
        );
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

test "TabStrip CSS includes exited-chip rules" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    // The exited chip needs a dimmed-color rule AND a line-through
    // on the label child — both have to ship for the visual to read
    // as "this shell is dead, restart with Ctrl+R."
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "djinn-tab-exited") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "line-through") != null);
}

test "TabStrip type compiles" {
    _ = TabStrip;
    _ = Slot;
    _ = OnActivate;
}
