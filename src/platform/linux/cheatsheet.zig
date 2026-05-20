//! Keyboard shortcut cheatsheet popover.
//!
//! Darwin's equivalent is `session/cheatsheet.zig` (NSScrollView +
//! NSTextView reading `view.zig::actionList()`). Linux mirrors the
//! surface: a `GtkPopover` anchored to the panel window, populated
//! by walking `keymap.zig::actionList()` and rendering each row whose
//! `description` is non-empty as a two-column "accel | description"
//! Pango-formatted block. Toggled by Ctrl+? (`Ctrl+Shift+/`).
//!
//! Layout choice: single GtkLabel with Pango markup beats GtkGrid +
//! per-row widgets for an MVP — the table doesn't change at runtime,
//! and Pango handles column alignment via tab stops. Switch to a
//! grid once the actions table grows past ~25 rows or the cheatsheet
//! wants filtering.
//!
//! Lifetime mirrors `find_overlay.zig`: the popover + label are built
//! once at startup, parented to the panel widget, and torn down on
//! `deinit` via `gtk_widget_unparent` so the GtkWindow destroy chain
//! doesn't reach a dangling ref.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const keymap = @import("keymap.zig");

const GtkWidget = gtk.GtkWidget;
const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

const g_object_unref = gtk.g_object_unref;

// ─── GTK4 popover + label surface ────────────────────────────────────

const GtkPopover = opaque {};
const GtkLabel = opaque {};
const GtkPositionType = c_int;

const GTK_POS_BOTTOM: GtkPositionType = 3;

const GdkRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

extern "c" fn gtk_popover_new() *GtkWidget;
extern "c" fn gtk_popover_set_child(popover: *GtkPopover, child: ?*GtkWidget) void;
extern "c" fn gtk_popover_set_position(popover: *GtkPopover, pos: GtkPositionType) void;
extern "c" fn gtk_popover_set_has_arrow(popover: *GtkPopover, has: gboolean) void;
extern "c" fn gtk_popover_set_autohide(popover: *GtkPopover, autohide: gboolean) void;
extern "c" fn gtk_popover_set_pointing_to(popover: *GtkPopover, rect: ?*const GdkRectangle) void;
extern "c" fn gtk_popover_popup(popover: *GtkPopover) void;
extern "c" fn gtk_popover_popdown(popover: *GtkPopover) void;
extern "c" fn gtk_widget_set_parent(widget: *GtkWidget, parent: *GtkWidget) void;
extern "c" fn gtk_widget_unparent(widget: *GtkWidget) void;
extern "c" fn gtk_widget_get_visible(widget: *GtkWidget) gboolean;
extern "c" fn gtk_widget_get_width(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_get_height(widget: *GtkWidget) c_int;

extern "c" fn gtk_label_new(text: ?[*:0]const u8) *GtkWidget;
extern "c" fn gtk_label_set_markup(label: *GtkLabel, markup: [*:0]const u8) void;
extern "c" fn gtk_label_set_use_markup(label: *GtkLabel, setting: gboolean) void;
extern "c" fn gtk_label_set_xalign(label: *GtkLabel, xalign: f32) void;
extern "c" fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: c_int) void;

// ─── Public surface ──────────────────────────────────────────────────

pub const Cheatsheet = struct {
    allocator: std.mem.Allocator,
    popover: *GtkWidget,
    label: *GtkWidget,
    /// Heap-allocated Pango markup string the label borrows from.
    /// GtkLabel does NOT copy the markup — it parses on each
    /// `set_markup` call but the original buffer is consulted by
    /// debugging paths, so keep it live until `deinit`.
    markup: [:0]u8,
    /// Anchor widget kept around so `open()` can re-read its current
    /// width on every popup. Without this the pointing-to rect
    /// would be fixed at init-time, ignoring panel resizes.
    anchor: *GtkWidget,

    /// Build the popover + populate it from `keymap.actionList()`.
    /// `anchor` is typically the panel's window widget — the popover
    /// attaches to it so the `Ctrl+?` shortcut surfaces consistently
    /// regardless of which child has keyboard focus.
    pub fn init(allocator: std.mem.Allocator, anchor: *GtkWidget) !Cheatsheet {
        const markup = try buildMarkup(allocator);
        errdefer allocator.free(markup);

        const popover = gtk_popover_new();
        gtk_popover_set_position(@ptrCast(popover), GTK_POS_BOTTOM);
        gtk_popover_set_has_arrow(@ptrCast(popover), 0);
        // autohide=false: the cheatsheet contains only a GtkLabel (no
        // focusable child), so the popover's grab on popup can't
        // settle into a child input and the panel window's
        // notify::is-active flips off. When `window.hide_on_blur =
        // true` is configured, that hides the entire panel right
        // after the popup, which looks like Ctrl+? hides djinn. Ctrl+?
        // already toggles the cheatsheet, so click-outside dismiss
        // isn't needed. Find overlay + palette keep autohide=true
        // because their focusable GtkSearchEntry anchors focus.
        gtk_popover_set_autohide(@ptrCast(popover), 0);
        gtk_widget_set_parent(popover, anchor);
        // The popover's pointing-to rect is re-computed in `open()` so
        // it tracks the anchor's current width across panel resizes.
        // Without an explicit pointing-to, GTK uses the anchor's full
        // allocation as the target rectangle. For a full-window-
        // sized anchor (the GtkStack), none of the four edges have
        // room for a 400px-tall popover and GTK clips it off-screen.

        const label = gtk_label_new(null);
        gtk_label_set_use_markup(@ptrCast(label), 1);
        gtk_label_set_markup(@ptrCast(label), markup.ptr);
        // Left-align inside the label so the two-column tab layout
        // doesn't get centered into a wobble when row widths differ.
        gtk_label_set_xalign(@ptrCast(label), 0.0);
        gtk_widget_set_margin_start(label, 16);
        gtk_widget_set_margin_end(label, 16);
        gtk_widget_set_margin_top(label, 12);
        gtk_widget_set_margin_bottom(label, 12);
        gtk_popover_set_child(@ptrCast(popover), label);

        return .{
            .allocator = allocator,
            .popover = popover,
            .label = label,
            .markup = markup,
            .anchor = anchor,
        };
    }

    pub fn deinit(self: *Cheatsheet) void {
        gtk_widget_unparent(self.popover);
        self.allocator.free(self.markup);
    }

    /// Show the popover. Idempotent — `gtk_popover_popup` is a no-op
    /// when already visible. The pointing-to rect is recomputed each
    /// open so the popover stays horizontally centered across panel
    /// resizes; vertical offset is ~1/8 from the top so the popover
    /// hangs into the upper-middle of the terminal area rather than
    /// running off the bottom.
    pub fn open(self: *Cheatsheet) void {
        const w = gtk_widget_get_width(self.anchor);
        const h = gtk_widget_get_height(self.anchor);
        const rect: GdkRectangle = .{
            .x = @divTrunc(@max(w, 0), 2),
            .y = @max(@divTrunc(@max(h, 0), 8), 24),
            .width = 1,
            .height = 1,
        };
        gtk_popover_set_pointing_to(@ptrCast(self.popover), &rect);
        gtk_popover_popup(@ptrCast(self.popover));
    }

    /// Hide if visible, show otherwise — bound to Ctrl+? in the
    /// keymap. `gtk_widget_get_visible` reads the popover's runtime
    /// state rather than tracking our own flag so an autohide-driven
    /// dismissal naturally re-opens on the next toggle.
    pub fn toggle(self: *Cheatsheet) void {
        if (gtk_widget_get_visible(self.popover) != 0) {
            gtk_popover_popdown(@ptrCast(self.popover));
        } else {
            self.open();
        }
    }
};

/// Render the action table as Pango markup. Rows with empty
/// `description` (the layout-coverage dup font_inc_shift, etc.) drop
/// out. Tab stops aren't directly supported in Pango markup, so each
/// row uses a fixed-width column for the accel followed by the
/// description — gives the cheatsheet a stable two-column look
/// without a GtkGrid build-out.
fn buildMarkup(allocator: std.mem.Allocator) ![:0]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.writeAll("<span size=\"large\" weight=\"bold\">djinn — shortcuts</span>\n\n");
    try w.writeAll("<tt>");

    const display_col: usize = 18;
    for (keymap.actionList()) |a| {
        if (a.description.len == 0) continue;
        // Pango markup is XML-escape-sensitive; the action table's
        // display/description strings contain `+`, `→`, etc. — safe
        // — but if anything later includes `<` or `&` it would need
        // escaping. Keep this assertion in the file-doc until the
        // table grows that surface.
        try w.print("{s}", .{a.display});
        const pad = if (a.display.len < display_col) display_col - a.display.len else 1;
        var i: usize = 0;
        while (i < pad) : (i += 1) try w.writeByte(' ');
        try w.print("{s}\n", .{a.description});
    }

    try w.writeAll("</tt>");
    return try buf.toOwnedSliceSentinel(allocator, 0);
}

test "Cheatsheet markup renders at least one row" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    const markup = try buildMarkup(a);
    defer a.free(markup);
    // Smoke check: the markup MUST include at least one description
    // from the action table. font_inc is the first row with a
    // description set.
    try std.testing.expect(std.mem.indexOf(u8, markup, "Increase font size") != null);
    try std.testing.expect(std.mem.indexOf(u8, markup, "Ctrl+=") != null);
    // font_inc_shift has empty description; the cheatsheet must NOT
    // emit its display string as a row entry. The header text
    // doesn't contain that accel either, so a substring check is
    // sufficient.
    try std.testing.expect(std.mem.indexOf(u8, markup, "Ctrl+Shift+=") == null);
}
