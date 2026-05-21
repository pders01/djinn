//! Type-to-switch profile palette.
//!
//! Phase 2 of the multi-profile rollout. Linux analogue of darwin's
//! command-K profile palette (`terminal/palette.zig`). A `GtkPopover`
//! anchored to the SessionHost's GtkStack with a `GtkSearchEntry` on
//! top and a `GtkListBox` of profile labels underneath. Anchoring on
//! the stack - not the active VTE - means the popover survives profile
//! switches without reparenting, same trick `find_overlay.zig` uses
//! for the find chip.
//!
//! Why a palette in addition to the tab strip + Alt+1..9: scan-by-
//! name beats scan-by-position once a user has more profiles than
//! fit comfortably across the chip row, and Alt+N tops out at 9.
//! The palette covers the long tail with substring search.
//!
//! Keyboard interaction (a `GtkEventControllerKey` attached to the
//! search entry intercepts these BEFORE the entry consumes them):
//!
//!   - Up / Down       → move selection in the listbox, entry keeps focus
//!   - Return          → activate the selected row (switch profile + close)
//!   - Escape          → close the popover without switching
//!   - any printable   → falls through to the entry's normal input path
//!
//! `search-changed` (GtkSearchEntry's 150ms-debounced text-change
//! signal) lowercases the needle into `needle_buf` and runs
//! `gtk_list_box_invalidate_filter`; the filter function reads the
//! cached needle so the per-row hot path stays one `mem.indexOf` per
//! lowercased label / name.
//!
//! Lifetime / ownership:
//!
//!   - Popover + entry + listbox + rows built once at `init`; rebuilt
//!     when hot-reload reconcile lands (not in this phase). Per-row
//!     `Slot` lives in `self.slots`; capacity reserved up front so the
//!     stored slot pointer (used by row-activated handlers + the
//!     filter function) stays valid across appends. Label strings are
//!     duped into `label_bufs` (sentinel-terminated for the `gtk_label`
//!     pointer) and `needle_bufs` (lowercased, no sentinel - only read
//!     as a slice) so a Config-reload arena drop can't invalidate
//!     them mid-keystroke.
//!   - `deinit` disconnects every stashed signal id before unparenting
//!     the popover and freeing the bufs. The popover's `set_parent`
//!     retained a ref on the anchor; `unparent` must run before the
//!     panel teardown chain reaches the anchor itself.
//!
//! Theming:
//!
//!   - Module-local `GtkCssProvider` reloaded in place on `applyTheme`
//!     (same pattern as `tab_strip.zig` / `log_pane.zig`). Stacking
//!     providers leaves orphan rules across theme reloads - we already
//!     paid for that once.
//!   - CSS-node gotcha (already burned us in log_pane): `GtkListBox`'s
//!     node is `list`, not `listbox`. Selectors here use `.djinn-
//!     palette-list` on the listbox widget directly so the rule
//!     matches regardless of GTK's internal naming.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const SessionManager = @import("../../session/manager.zig").SessionManager;
const ThemeOptions = @import("terminal.zig").ThemeOptions;

const GtkWidget = gtk.GtkWidget;
const GdkDisplay = gtk.GdkDisplay;
const GtkCssProvider = gtk.GtkCssProvider;
const GtkEventController = gtk.GtkEventController;
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
const gtk_widget_get_visible = gtk.gtk_widget_get_visible;
const gtk_widget_add_controller = gtk.gtk_widget_add_controller;

// ─── GTK4 popover / list / search-entry surface ──────────────────────

const GtkBox = opaque {};
const GtkPopover = opaque {};
const GtkLabel = opaque {};
const GtkListBox = opaque {};
const GtkListBoxRow = opaque {};
const GtkScrolledWindow = opaque {};
const GtkEditable = opaque {};

const GtkPositionType = c_int;
const GtkOrientation = c_int;
const GtkSelectionMode = c_int;
const GtkPolicyType = c_int;
const GtkPropagationPhase = c_int;

const GTK_POS_BOTTOM: GtkPositionType = 3;
const GTK_ORIENTATION_HORIZONTAL: GtkOrientation = 0;
const GTK_ORIENTATION_VERTICAL: GtkOrientation = 1;
const GTK_SELECTION_BROWSE: GtkSelectionMode = 2;
const GTK_POLICY_NEVER: GtkPolicyType = 2;
const GTK_POLICY_AUTOMATIC: GtkPolicyType = 1;
const GTK_PHASE_CAPTURE: GtkPropagationPhase = 1;

const GdkRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

// `gtk_css_provider_add_provider_for_display` priority constant.
// Matches `STYLE_PROVIDER_PRIORITY_APPLICATION` (above the system
// theme, below user `~/.config/gtk-4.0/gtk.css`).
const STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;

// GDK keyvals (`gdkkeysyms.h`). Only the four we intercept.
const GDK_KEY_Return: c_uint = 0xff0d;
const GDK_KEY_KP_Enter: c_uint = 0xff8d;
const GDK_KEY_Escape: c_uint = 0xff1b;
const GDK_KEY_Up: c_uint = 0xff52;
const GDK_KEY_Down: c_uint = 0xff54;

extern "c" fn gtk_popover_new() *GtkWidget;
extern "c" fn gtk_popover_set_child(popover: *GtkPopover, child: ?*GtkWidget) void;
extern "c" fn gtk_popover_set_position(popover: *GtkPopover, pos: GtkPositionType) void;
extern "c" fn gtk_popover_set_has_arrow(popover: *GtkPopover, has: gboolean) void;
extern "c" fn gtk_popover_set_autohide(popover: *GtkPopover, autohide: gboolean) void;
extern "c" fn gtk_popover_set_pointing_to(popover: *GtkPopover, rect: ?*const GdkRectangle) void;
extern "c" fn gtk_popover_popup(popover: *GtkPopover) void;
extern "c" fn gtk_popover_popdown(popover: *GtkPopover) void;
extern "c" fn gtk_widget_get_width(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_get_height(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_set_parent(widget: *GtkWidget, parent: *GtkWidget) void;
extern "c" fn gtk_widget_unparent(widget: *GtkWidget) void;
extern "c" fn gtk_widget_grab_focus(widget: *GtkWidget) gboolean;
extern "c" fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, w: c_int, h: c_int) void;
extern "c" fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
extern "c" fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
extern "c" fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: c_int) void;

extern "c" fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) *GtkWidget;
extern "c" fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;

extern "c" fn gtk_search_entry_new() *GtkWidget;
extern "c" fn gtk_editable_get_text(editable: *GtkEditable) [*:0]const u8;
extern "c" fn gtk_editable_set_text(editable: *GtkEditable, text: [*:0]const u8) void;

extern "c" fn gtk_label_new(text: ?[*:0]const u8) *GtkWidget;
extern "c" fn gtk_label_set_xalign(label: *GtkLabel, xalign: f32) void;

extern "c" fn gtk_scrolled_window_new() *GtkWidget;
extern "c" fn gtk_scrolled_window_set_child(sw: *GtkScrolledWindow, child: ?*GtkWidget) void;
extern "c" fn gtk_scrolled_window_set_policy(sw: *GtkScrolledWindow, h: GtkPolicyType, v: GtkPolicyType) void;
extern "c" fn gtk_scrolled_window_set_min_content_height(sw: *GtkScrolledWindow, h: c_int) void;
extern "c" fn gtk_scrolled_window_set_max_content_height(sw: *GtkScrolledWindow, h: c_int) void;

extern "c" fn gtk_list_box_new() *GtkWidget;
extern "c" fn gtk_list_box_append(box: *GtkListBox, child: *GtkWidget) void;
extern "c" fn gtk_list_box_set_selection_mode(box: *GtkListBox, mode: GtkSelectionMode) void;
extern "c" fn gtk_list_box_select_row(box: *GtkListBox, row: ?*GtkListBoxRow) void;
extern "c" fn gtk_list_box_get_selected_row(box: *GtkListBox) ?*GtkListBoxRow;
extern "c" fn gtk_list_box_get_row_at_index(box: *GtkListBox, idx: c_int) ?*GtkListBoxRow;
extern "c" fn gtk_list_box_invalidate_filter(box: *GtkListBox) void;
extern "c" fn gtk_list_box_set_filter_func(
    box: *GtkListBox,
    filter_func: ?*const fn (row: *GtkListBoxRow, user_data: gpointer) callconv(.c) gboolean,
    user_data: gpointer,
    destroy: ?*const anyopaque,
) void;

extern "c" fn gtk_list_box_row_new() *GtkWidget;
extern "c" fn gtk_list_box_row_set_child(row: *GtkListBoxRow, child: ?*GtkWidget) void;
extern "c" fn gtk_list_box_row_set_selectable(row: *GtkListBoxRow, selectable: gboolean) void;
extern "c" fn gtk_list_box_row_get_index(row: *GtkListBoxRow) c_int;

extern "c" fn gtk_event_controller_key_new() *GtkEventController;
extern "c" fn gtk_event_controller_set_propagation_phase(controller: *GtkEventController, phase: GtkPropagationPhase) void;

// ─── Public surface ──────────────────────────────────────────────────

/// Caller-supplied "activate this profile index" hook. Wired in
/// main_linux onto `SessionHost.activate` - same shape `tab_strip.zig`
/// uses, so the typed dependency stays in main_linux and the palette
/// stays free of `session_host.zig`.
pub const OnActivate = struct {
    ctx: *anyopaque,
    on_invoke: *const fn (ctx: *anyopaque, idx: usize) bool,
};

/// Per-row bookkeeping. The lowercased label / name slices are owned
/// by `label_bufs` / `needle_bufs` on `Palette`; the slot just stores
/// the index ranges plus a back-pointer for the row-activated +
/// filter signal handlers.
const Slot = struct {
    palette: *Palette,
    /// Profile index in `SessionManager.sessions`. Stable for the
    /// palette's lifetime (hot-reload reconcile will rebuild the
    /// palette wholesale rather than mutating indices in place).
    idx: usize,
    /// Lowercased label string, owned by `Palette.needle_bufs[idx]`.
    /// Read by the filter function once per keystroke; pre-lowercased
    /// so the per-row path stays one `mem.indexOf` rather than a
    /// case-fold per profile per keystroke.
    label_lower: []const u8,
    /// Lowercased profile name. Distinct from `label_lower` because
    /// users may type either -`name` is the config key, `label` is
    /// the display string from `profile.title`. Matched independently
    /// so typing "main" still finds a profile titled "Main Repo".
    name_lower: []const u8,
};

pub const Palette = struct {
    allocator: std.mem.Allocator,
    sm: *SessionManager,
    on_activate: OnActivate,
    popover: *GtkWidget,
    /// Parent widget the popover anchors to. Stored so `open()` can
    /// re-read its width/height on each popup and rebuild the
    /// pointing-to rect against the live panel size. Same idiom as
    /// `cheatsheet.open`.
    anchor: *GtkWidget,
    entry: *GtkWidget,
    list_box: *GtkWidget,
    /// Module-local CSS provider - reloaded in place on `applyTheme`,
    /// same shape as tab_strip / log_pane.
    provider: *GtkCssProvider,
    /// Cached at init + refreshed by `applyTheme`. Held so a future
    /// rebuild path (hot-reload reconcile) can re-skin without
    /// main_linux re-passing the options.
    theme_opts: ThemeOptions,

    /// Lowercased search needle, owned. Built fresh on every
    /// `search-changed` from `gtk_editable_get_text`'s string and
    /// then read by the filter callback. Empty when the entry is
    /// empty (the filter then matches every row).
    needle_buf: std.ArrayList(u8) = .{},

    /// One slot per profile, parallel-indexed to `rows` and the
    /// owned label / name buffers. Capacity reserved in `init` so
    /// `&self.slots.items[i]` stays valid for the palette's
    /// lifetime -`gtk_list_box_row_get_index` indexes into this.
    slots: std.ArrayList(Slot) = .{},
    rows: std.ArrayList(*GtkWidget) = .{},
    /// Sentinel-terminated label buffers handed to `gtk_label_new`.
    label_bufs: std.ArrayList([:0]u8) = .{},
    /// Lowercased label/name slices for the filter hot path. Plain
    /// `[]u8` (not sentinel-terminated) since they're only read as
    /// `mem.indexOf` haystacks.
    needle_bufs: std.ArrayList([]u8) = .{},

    /// Signal handler ids - disconnected in `deinit` before any free
    /// that invalidates user_data so a dispatch queued on the GLib
    /// main loop mid-teardown can't deref freed state. Same shape as
    /// find_overlay / tab_strip.
    search_changed_id: c_ulong = 0,
    row_activated_id: c_ulong = 0,
    key_pressed_id: c_ulong = 0,

    /// Build the popover + child widgets + per-profile rows. Caller
    /// must run `install` (separately, after the struct's address
    /// stabilizes) to wire signal handlers. Same shape Terminal +
    /// LogPane + FindOverlay use.
    ///
    /// `anchor` is the GtkStack returned by `SessionHost.widget()`;
    /// the popover stays anchored there so it survives profile
    /// switches without reparenting.
    pub fn init(
        allocator: std.mem.Allocator,
        sm: *SessionManager,
        on_activate: OnActivate,
        anchor: *GtkWidget,
        theme_opts: ThemeOptions,
    ) !Palette {
        const popover = gtk_popover_new();
        gtk_popover_set_position(@ptrCast(popover), GTK_POS_BOTTOM);
        // No arrow, autohide on: click-outside dismisses the palette
        // without us wiring a focus-out handler. Matches the
        // find_overlay / cheatsheet chrome.
        gtk_popover_set_has_arrow(@ptrCast(popover), 0);
        gtk_popover_set_autohide(@ptrCast(popover), 1);
        gtk_widget_set_parent(popover, anchor);
        gtk_widget_add_css_class(popover, "djinn-palette");

        // Vertical box: search entry on top, scrolled listbox underneath.
        const vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_widget_set_margin_start(vbox, 8);
        gtk_widget_set_margin_end(vbox, 8);
        gtk_widget_set_margin_top(vbox, 8);
        gtk_widget_set_margin_bottom(vbox, 8);

        const entry = gtk_search_entry_new();
        gtk_widget_set_hexpand(entry, 1);
        gtk_widget_add_css_class(entry, "djinn-palette-entry");
        gtk_box_append(@ptrCast(vbox), entry);

        const scrolled = gtk_scrolled_window_new();
        // Horizontal scroll never makes sense for a label-only list;
        // wider labels get ellipsized by GTK's default label rendering.
        // Vertical AUTOMATIC so the scrollbar appears only when the
        // content overflows.
        gtk_scrolled_window_set_policy(@ptrCast(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
        gtk_scrolled_window_set_min_content_height(@ptrCast(scrolled), 120);
        gtk_scrolled_window_set_max_content_height(@ptrCast(scrolled), 360);
        gtk_widget_set_vexpand(scrolled, 1);

        const list_box = gtk_list_box_new();
        gtk_widget_add_css_class(list_box, "djinn-palette-list");
        // BROWSE keeps one row selected at all times (no "no selection"
        // state), which matches what type-to-switch users expect:
        // Enter always has a target. SINGLE would let Up-past-top
        // deselect; we'd then have to special-case Enter-with-no-selection.
        gtk_list_box_set_selection_mode(@ptrCast(list_box), GTK_SELECTION_BROWSE);
        gtk_scrolled_window_set_child(@ptrCast(scrolled), list_box);

        gtk_box_append(@ptrCast(vbox), scrolled);
        gtk_popover_set_child(@ptrCast(popover), vbox);

        // Provider attached to the default display at app-level
        // priority. Same shape tab_strip uses; the provider's content
        // gets filled by `applyTheme` below.
        const provider = gtk_css_provider_new();
        if (gdk_display_get_default()) |display| {
            gtk_style_context_add_provider_for_display(
                display,
                @ptrCast(provider),
                STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }

        var self: Palette = .{
            .allocator = allocator,
            .sm = sm,
            .on_activate = on_activate,
            .popover = popover,
            .anchor = anchor,
            .entry = entry,
            .list_box = list_box,
            .provider = provider,
            .theme_opts = theme_opts,
        };
        try self.buildRows();
        self.applyTheme(theme_opts);
        return self;
    }

    pub fn deinit(self: *Palette) void {
        if (self.search_changed_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.entry), self.search_changed_id);
        if (self.row_activated_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.list_box), self.row_activated_id);
        // The key controller hangs off the entry; disconnecting via the
        // signal-handler id is enough (GTK drops the controller when
        // the widget destroys, but the explicit disconnect makes the
        // teardown ordering symmetric with find_overlay / tab_strip).
        if (self.key_pressed_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.entry), self.key_pressed_id);

        for (self.label_bufs.items) |buf| self.allocator.free(buf);
        for (self.needle_bufs.items) |buf| self.allocator.free(buf);
        self.slots.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.label_bufs.deinit(self.allocator);
        self.needle_bufs.deinit(self.allocator);
        self.needle_buf.deinit(self.allocator);

        gtk_widget_unparent(self.popover);
        g_object_unref(@ptrCast(self.provider));
    }

    /// Wire signal handlers. Separate from `init` so the Palette's
    /// stable address (post-move-to-host-frame) can be passed as
    /// `user_data` - find_overlay + tab_strip use the same shape.
    pub fn install(self: *Palette) void {
        self.search_changed_id = g_signal_connect_data(
            @ptrCast(self.entry),
            "search-changed",
            @ptrCast(&onSearchChanged),
            @ptrCast(self),
            null,
            0,
        );
        self.row_activated_id = g_signal_connect_data(
            @ptrCast(self.list_box),
            "row-activated",
            @ptrCast(&onRowActivated),
            @ptrCast(self),
            null,
            0,
        );

        // Filter hooks: GtkListBox calls filter_func once per row when
        // we invalidate. The user_data is the Palette so the filter
        // can read the cached needle.
        gtk_list_box_set_filter_func(
            @ptrCast(self.list_box),
            &filterRow,
            @ptrCast(self),
            null,
        );

        // Key controller on the entry. Up / Down / Return / Escape
        // get intercepted at CAPTURE phase so the GtkSearchEntry's
        // own handlers (which would otherwise treat Return as
        // "activate" and pass arrows through unprocessed) never see
        // them. Anything else returns FALSE → falls through to the
        // entry for normal text input.
        const key_controller = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(key_controller, GTK_PHASE_CAPTURE);
        self.key_pressed_id = g_signal_connect_data(
            @ptrCast(key_controller),
            "key-pressed",
            @ptrCast(&onKeyPressed),
            @ptrCast(self),
            null,
            0,
        );
        gtk_widget_add_controller(self.entry, key_controller);
    }

    /// Pop up the palette + focus the entry. Resets the entry text and
    /// selects the first row so each open starts from a clean slate.
    /// Idempotent -`gtk_popover_popup` no-ops when already visible.
    pub fn open(self: *Palette) void {
        // Without `set_pointing_to`, GTK4 anchors the popover against
        // the parent widget's full bounds + GTK_POS_BOTTOM, which lands
        // it below the panel window. Re-aim at a 1x1 rect roughly a
        // third of the way down the anchor so the popover hangs into
        // the visual center across the panel resizes. Same idiom as
        // `cheatsheet.open`.
        const w = gtk_widget_get_width(self.anchor);
        const h = gtk_widget_get_height(self.anchor);
        const rect: GdkRectangle = .{
            .x = @divTrunc(@max(w, 0), 2),
            .y = @max(@divTrunc(@max(h, 0), 3), 24),
            .width = 1,
            .height = 1,
        };
        gtk_popover_set_pointing_to(@ptrCast(self.popover), &rect);
        // Clearing the entry triggers `search-changed` → filter
        // invalidation → all rows visible → first-row selection. The
        // ordering matters: text clear first, then popup, then focus.
        // Popping up before the focus grab lets GTK's autohide arm
        // itself against the entry's grab rather than racing it.
        gtk_editable_set_text(@ptrCast(self.entry), "");
        gtk_popover_popup(@ptrCast(self.popover));
        _ = gtk_widget_grab_focus(self.entry);
        self.selectFirstVisible();
    }

    pub fn close(self: *Palette) void {
        gtk_popover_popdown(@ptrCast(self.popover));
    }

    /// Toggle by visibility - bound to Ctrl+Shift+P in keymap.zig.
    /// Mirrors `cheatsheet.toggle` so the keymap action is a one-liner.
    pub fn toggle(self: *Palette) void {
        if (gtk_widget_get_visible(self.popover) != 0) {
            self.close();
        } else {
            self.open();
        }
    }

    /// Underlying popover widget. Exposed so `panel.trackPopoverGrabs`
    /// can wire its show/closed signals — the panel suppresses
    /// hide-on-blur while this popover holds an input grab. Not for
    /// general consumption.
    pub fn popoverWidget(self: *Palette) *GtkWidget {
        return self.popover;
    }

    /// Reload the palette CSS from `opts`. Same shape as tab_strip /
    /// log_pane: build a fresh string, hand it to the provider via
    /// reload-in-place. main_linux's `onConfigChanged` fans every
    /// palette / strip / pane through their own `applyTheme` so a
    /// config save flips colors across all chrome simultaneously.
    pub fn applyTheme(self: *Palette, opts: ThemeOptions) void {
        self.theme_opts = opts;
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        writeThemedCss(self.allocator, &buf, opts) catch |err| {
            std.debug.print(
                "palette: CSS build failed: {} - keeping previous styles\n",
                .{err},
            );
            return;
        };
        // `gtk_css_provider_load_from_string` is C - needs a sentinel.
        // Without the appended 0 the parser reads past `buf.items.len`
        // into uninitialized capacity / next-allocation bytes and emits
        // garbage "Expected '{' after selectors" Gtk-WARNINGs.
        // log_pane.zig hits this same trap; tab_strip happens to dodge
        // it today only by luck of allocator layout.
        buf.append(self.allocator, 0) catch return;
        gtk_css_provider_load_from_string(self.provider, @ptrCast(buf.items.ptr));
    }

    // ─── Internal: row build / selection / filter ────────────────────

    fn buildRows(self: *Palette) !void {
        const n = self.sm.count();
        try self.slots.ensureTotalCapacity(self.allocator, n);
        try self.rows.ensureTotalCapacity(self.allocator, n);
        try self.label_bufs.ensureTotalCapacity(self.allocator, n);
        try self.needle_bufs.ensureTotalCapacity(self.allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const profile = self.sm.sessions.items[i].profile;
            const display = profile.label();

            // Sentinel-terminated label for the gtk_label pointer.
            const label_buf = try self.allocator.allocSentinel(u8, display.len, 0);
            @memcpy(label_buf, display);
            self.label_bufs.appendAssumeCapacity(label_buf);

            // Pre-lowercased haystack for the filter. Allocated as a
            // single buffer holding `label_lower + name_lower` so we
            // only pay one alloc per row; the slots then take slices
            // into it. Using ASCII-lowercase is the right call here:
            // profile names + labels are ASCII-y in practice, and a
            // full Unicode case-fold would drag in a heavyweight
            // dependency for a fuzzy-search toy.
            const name = profile.name;
            const needle_buf = try self.allocator.alloc(u8, display.len + name.len);
            var j: usize = 0;
            while (j < display.len) : (j += 1) needle_buf[j] = std.ascii.toLower(display[j]);
            j = 0;
            while (j < name.len) : (j += 1) needle_buf[display.len + j] = std.ascii.toLower(name[j]);
            self.needle_bufs.appendAssumeCapacity(needle_buf);

            const label = gtk_label_new(label_buf.ptr);
            gtk_label_set_xalign(@ptrCast(label), 0.0);
            gtk_widget_set_margin_start(label, 6);
            gtk_widget_set_margin_end(label, 6);
            gtk_widget_set_margin_top(label, 4);
            gtk_widget_set_margin_bottom(label, 4);

            const row = gtk_list_box_row_new();
            gtk_widget_add_css_class(row, "djinn-palette-row");
            gtk_list_box_row_set_child(@ptrCast(row), label);
            gtk_list_box_row_set_selectable(@ptrCast(row), 1);

            gtk_list_box_append(@ptrCast(self.list_box), row);
            self.rows.appendAssumeCapacity(row);

            self.slots.appendAssumeCapacity(.{
                .palette = self,
                .idx = i,
                .label_lower = needle_buf[0..display.len],
                .name_lower = needle_buf[display.len..],
            });
        }
    }

    /// Select the first row that passes the current filter. Used after
    /// `open()` (entry empty → first row) and after each
    /// `search-changed` (filter narrowed → first visible match).
    /// Falls back to selecting nothing when every row filtered out;
    /// Enter then becomes a no-op, which is the right behavior for a
    /// "no matches" state.
    fn selectFirstVisible(self: *Palette) void {
        for (self.slots.items, 0..) |slot, i| {
            if (self.matchSlot(slot)) {
                if (gtk_list_box_get_row_at_index(@ptrCast(self.list_box), @intCast(i))) |row| {
                    gtk_list_box_select_row(@ptrCast(self.list_box), row);
                    return;
                }
            }
        }
        gtk_list_box_select_row(@ptrCast(self.list_box), null);
    }

    /// Move selection up or down through the visible (post-filter)
    /// rows. Wraps at top / bottom so Down past the last match goes to
    /// the first, mirroring how command palettes everywhere behave
    /// (VS Code, Sublime, iTerm). `direction` is +1 for Down, -1 for Up.
    fn moveSelection(self: *Palette, direction: i32) void {
        const n = self.slots.items.len;
        if (n == 0) return;
        const current_idx = self.selectedSlotIdx();

        // Start one past current in the requested direction; walk up
        // to `n` slots looking for the next match. Bounded by `n` so a
        // no-match state can't infinite-loop.
        var step: usize = 1;
        while (step <= n) : (step += 1) {
            const at: usize = blk: {
                if (current_idx) |c| {
                    const signed_c: isize = @intCast(c);
                    const signed_step: isize = @intCast(step);
                    const signed_n: isize = @intCast(n);
                    const raw = @mod(signed_c + direction * signed_step, signed_n);
                    // Zig `@mod` returns sign-of-divisor for negatives;
                    // signed_n is positive, so `raw` is already
                    // [0, n). Cast safely.
                    break :blk @intCast(raw);
                } else {
                    // No current selection: start from 0 going down,
                    // n-1 going up.
                    break :blk if (direction > 0) (step - 1) else (n - step);
                }
            };
            if (self.matchSlot(self.slots.items[at])) {
                if (gtk_list_box_get_row_at_index(@ptrCast(self.list_box), @intCast(at))) |row| {
                    gtk_list_box_select_row(@ptrCast(self.list_box), row);
                    return;
                }
            }
        }
    }

    fn selectedSlotIdx(self: *Palette) ?usize {
        const row = gtk_list_box_get_selected_row(@ptrCast(self.list_box)) orelse return null;
        const raw = gtk_list_box_row_get_index(row);
        if (raw < 0) return null;
        return @intCast(raw);
    }

    /// Pure-data filter check. The GtkListBox filter_func and the
    /// up/down navigation both reach through this so "is this row
    /// visible" stays one source of truth.
    fn matchSlot(self: *Palette, slot: Slot) bool {
        const needle = self.needle_buf.items;
        if (needle.len == 0) return true;
        if (std.mem.indexOf(u8, slot.label_lower, needle) != null) return true;
        if (std.mem.indexOf(u8, slot.name_lower, needle) != null) return true;
        return false;
    }

    /// Activate whatever row is currently selected. Hooked from the
    /// Return-key path AND the `row-activated` GtkListBox signal
    /// (which fires on double-click or the listbox's own Enter
    /// behavior when it has focus). The OnActivate callback returns
    /// whether the switch actually happened; either way we close so
    /// the palette doesn't linger after a no-op (e.g. re-selecting
    /// the already-active profile).
    fn activateSelected(self: *Palette) void {
        if (self.selectedSlotIdx()) |i| {
            _ = self.on_activate.on_invoke(self.on_activate.ctx, i);
        }
        self.close();
    }
};

// ─── Signal handlers ─────────────────────────────────────────────────

/// GtkSearchEntry's `search-changed` is emitted ~150ms after the last
/// keystroke (built-in debounce) - cheap enough to rebuild the
/// lowercased needle buffer and invalidate the filter on each fire
/// without throttling further.
fn onSearchChanged(entry_ptr: *GObject, user_data: gpointer) callconv(.c) void {
    const self: *Palette = @ptrCast(@alignCast(user_data orelse return));
    const editable: *GtkEditable = @ptrCast(entry_ptr);
    const text_z = gtk_editable_get_text(editable);
    const text = std.mem.span(text_z);

    self.needle_buf.clearRetainingCapacity();
    self.needle_buf.ensureTotalCapacity(self.allocator, text.len) catch return;
    for (text) |c| self.needle_buf.appendAssumeCapacity(std.ascii.toLower(c));

    gtk_list_box_invalidate_filter(@ptrCast(self.list_box));
    self.selectFirstVisible();
}

/// GtkListBox filter callback. Row index is the model index - a
/// straight `slots[idx]` lookup so we don't need `g_object_get_data`
/// gymnastics on the row.
fn filterRow(row: *GtkListBoxRow, user_data: gpointer) callconv(.c) gboolean {
    const self: *Palette = @ptrCast(@alignCast(user_data orelse return 1));
    const raw = gtk_list_box_row_get_index(row);
    if (raw < 0) return 0;
    const idx: usize = @intCast(raw);
    if (idx >= self.slots.items.len) return 0;
    return if (self.matchSlot(self.slots.items[idx])) 1 else 0;
}

/// `row-activated`: GtkListBox emits this on double-click + on the
/// listbox's own Enter handling when IT has focus. Our normal flow
/// keeps focus on the entry, so the Return-key path inside
/// `onKeyPressed` is what fires for keyboard activation; this handler
/// covers the mouse-double-click path.
fn onRowActivated(_: *GObject, _: ?*GtkListBoxRow, user_data: gpointer) callconv(.c) void {
    const self: *Palette = @ptrCast(@alignCast(user_data orelse return));
    self.activateSelected();
}

/// CAPTURE-phase key handler on the search entry. Intercepts Up /
/// Down / Return / Escape; everything else returns FALSE so the entry
/// gets the keystroke as normal text input.
fn onKeyPressed(
    _: *GObject,
    keyval: c_uint,
    _: c_uint,
    _: c_uint,
    user_data: gpointer,
) callconv(.c) gboolean {
    const self: *Palette = @ptrCast(@alignCast(user_data orelse return 0));
    return switch (keyval) {
        GDK_KEY_Up => blk: {
            self.moveSelection(-1);
            break :blk 1;
        },
        GDK_KEY_Down => blk: {
            self.moveSelection(1);
            break :blk 1;
        },
        GDK_KEY_Return, GDK_KEY_KP_Enter => blk: {
            self.activateSelected();
            break :blk 1;
        },
        GDK_KEY_Escape => blk: {
            self.close();
            break :blk 1;
        },
        else => 0,
    };
}

// ─── Theming ─────────────────────────────────────────────────────────

/// Build the palette CSS into `buf`. Null theme fields fall back to
/// GTK named colors so a no-inheritance setup still reads coherently.
/// Selection accent matches the tab strip: `palette[4]` (blue ANSI
/// slot) when available, `@accent_color` otherwise - keeps the chrome
/// vocabulary internally consistent across the multi-profile UI.
fn writeThemedCss(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    opts: ThemeOptions,
) !void {
    const w = buf.writer(allocator);

    // Popover surface mirrors the resolved terminal background +
    // opacity so the palette reads as part of the terminal chrome,
    // not as a stray GTK dialog. Same `background-image: none` belt
    // tab_strip / log_pane carry - some user themes set a gradient
    // image that the color alone wouldn't override.
    if (opts.background) |bg| {
        const alpha = opts.opacity orelse 1.0;
        try w.print(
            "popover.djinn-palette > contents {{\n" ++
                "  background-color: rgba({d}, {d}, {d}, {d:.2});\n" ++
                "  background-image: none;\n" ++
                "  border-radius: 6px;\n" ++
                "  padding: 0;\n" ++
                "}}\n",
            .{ bg.r, bg.g, bg.b, alpha },
        );
    } else {
        try w.writeAll(
            \\popover.djinn-palette > contents {
            \\  background-color: @theme_bg_color;
            \\  background-image: none;
            \\  border-radius: 6px;
            \\  padding: 0;
            \\}
            \\
        );
    }

    // The list itself should be transparent so the popover bg shows
    // through. GtkListBox's CSS node is `list`, NOT `listbox`;
    // selectors against `listbox` silently never match. Already-burned
    // bug in log_pane; the `.djinn-palette-list` class survives the
    // node-name confusion either way.
    try w.writeAll(
        \\.djinn-palette-list {
        \\  background-color: transparent;
        \\  background-image: none;
        \\}
        \\
    );

    // Unselected row: full-strength foreground.
    if (opts.foreground) |fg| {
        try w.print(
            "row.djinn-palette-row {{\n" ++
                "  background-color: transparent;\n" ++
                "  background-image: none;\n" ++
                "  color: rgb({d}, {d}, {d});\n" ++
                "  padding: 2px 6px;\n" ++
                "  border-radius: 4px;\n" ++
                "}}\n",
            .{ fg.r, fg.g, fg.b },
        );
    } else {
        try w.writeAll(
            \\row.djinn-palette-row {
            \\  background-color: transparent;
            \\  background-image: none;
            \\  color: @theme_fg_color;
            \\  padding: 2px 6px;
            \\  border-radius: 4px;
            \\}
            \\
        );
    }

    // Selected row: accent fill + contrasting text. Use the foreground
    // (terminal text color) as the selected-row text so the user's
    // chosen palette stays internally consistent. Without an explicit
    // foreground, fall back to @theme_selected_fg_color.
    const accent = opts.palette[4];
    if (accent) |a| {
        if (opts.foreground) |fg| {
            try w.print(
                "row.djinn-palette-row:selected {{\n" ++
                    "  background-color: rgba({d}, {d}, {d}, 0.30);\n" ++
                    "  color: rgb({d}, {d}, {d});\n" ++
                    "  font-weight: bold;\n" ++
                    "}}\n",
                .{ a.r, a.g, a.b, fg.r, fg.g, fg.b },
            );
        } else {
            try w.print(
                "row.djinn-palette-row:selected {{\n" ++
                    "  background-color: rgba({d}, {d}, {d}, 0.30);\n" ++
                    "  color: @theme_fg_color;\n" ++
                    "  font-weight: bold;\n" ++
                    "}}\n",
                .{ a.r, a.g, a.b },
            );
        }
    } else {
        try w.writeAll(
            \\row.djinn-palette-row:selected {
            \\  background-color: alpha(@accent_color, 0.30);
            \\  color: @theme_fg_color;
            \\  font-weight: bold;
            \\}
            \\
        );
    }
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Palette CSS includes selected-row selector" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    // Smoke check: the CSS must define the selected-row rule, since
    // selection drives the entire keyboard-nav UX. A typo there means
    // the user can't tell which profile Enter would activate.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ".djinn-palette-row:selected") != null);
    // List background rule must reference the `.djinn-palette-list`
    // class - chasing the `list` vs `listbox` CSS-node trap by
    // exercising the class selector directly.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ".djinn-palette-list") != null);
}

test "Palette CSS uses palette[4] for selection accent when available" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var opts = ThemeOptions{};
    opts.palette[4] = .{ .r = 100, .g = 149, .b = 237 };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, opts);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rgba(100, 149, 237, 0.30)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@accent_color") == null);
}

test "Palette CSS falls back to @accent_color when palette[4] is null" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@accent_color") != null);
}

test "Palette type compiles" {
    _ = Palette;
    _ = Slot;
    _ = OnActivate;
}
