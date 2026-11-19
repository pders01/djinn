//! Native GTK search entry over VTE scrollback. GTK owns key editing and IME;
//! no failed edit is ever forwarded as shell input.
const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
const GtkPopover = opaque {};
const GtkBox = opaque {};
const GtkEditable = opaque {};
const VteRegex = opaque {};
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };
const Rectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
extern "c" fn g_error_free(*GError) void;
extern "c" fn g_object_ref(*anyopaque) *anyopaque;
extern "c" fn g_object_ref_sink(*anyopaque) *anyopaque;
extern "c" fn g_signal_stop_emission_by_name(*anyopaque, [*:0]const u8) void;
extern "c" fn vte_regex_new_for_search([*]const u8, isize, u32, ?*?*GError) ?*VteRegex;
extern "c" fn vte_regex_unref(*VteRegex) ?*VteRegex;
extern "c" fn vte_terminal_search_set_regex(*VteTerminal, ?*VteRegex, u32) void;
extern "c" fn vte_terminal_search_find_next(*VteTerminal) gtk.gboolean;
extern "c" fn vte_terminal_search_find_previous(*VteTerminal) gtk.gboolean;
extern "c" fn vte_terminal_search_set_wrap_around(*VteTerminal, gtk.gboolean) void;
extern "c" fn gtk_popover_new() *GtkWidget;
extern "c" fn gtk_popover_set_child(*GtkPopover, ?*GtkWidget) void;
extern "c" fn gtk_popover_set_position(*GtkPopover, c_int) void;
extern "c" fn gtk_popover_set_has_arrow(*GtkPopover, gtk.gboolean) void;
extern "c" fn gtk_popover_set_autohide(*GtkPopover, gtk.gboolean) void;
extern "c" fn gtk_popover_set_pointing_to(*GtkPopover, ?*const Rectangle) void;
extern "c" fn gtk_popover_popup(*GtkPopover) void;
extern "c" fn gtk_popover_popdown(*GtkPopover) void;
extern "c" fn gtk_widget_set_parent(*GtkWidget, *GtkWidget) void;
extern "c" fn gtk_widget_unparent(*GtkWidget) void;
extern "c" fn gtk_widget_grab_focus(*GtkWidget) gtk.gboolean;
extern "c" fn gtk_widget_get_width(*GtkWidget) c_int;
extern "c" fn gtk_box_new(c_int, c_int) *GtkWidget;
extern "c" fn gtk_box_append(*GtkBox, *GtkWidget) void;
extern "c" fn gtk_search_entry_new() *GtkWidget;
extern "c" fn gtk_editable_get_text(*GtkEditable) [*:0]const u8;
extern "c" fn gtk_editable_get_delegate(*GtkEditable) ?*GtkEditable;
extern "c" fn gtk_widget_set_hexpand(*GtkWidget, gtk.gboolean) void;
extern "c" fn gtk_button_new_from_icon_name([*:0]const u8) *GtkWidget;
extern "c" fn gtk_widget_set_tooltip_text(*GtkWidget, [*:0]const u8) void;

const max_needle_bytes = 4096;
fn validNeedle(text: []const u8) bool {
    if (text.len > max_needle_bytes or !std.unicode.utf8ValidateSlice(text)) return false;
    var it = (std.unicode.Utf8View.initUnchecked(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    }
    return true;
}
fn canInsert(current: []const u8, inserted: []const u8) bool {
    return validNeedle(current) and validNeedle(inserted) and inserted.len <= max_needle_bytes - current.len;
}

/// Callback state is heap stable even if the public wrapper moves after init
/// or install. Disconnect all callbacks before releasing widgets or this box.
const State = struct {
    allocator: std.mem.Allocator,
    terminal: ?*VteTerminal,
    popover: *GtkWidget,
    anchor: *GtkWidget,
    entry: *GtkWidget,
    editable: *GtkEditable,
    prev: *GtkWidget,
    next: *GtkWidget,
    regex: ?*VteRegex = null,
    needle: [max_needle_bytes]u8 = @splat(0),
    needle_len: usize = 0,
    search_id: c_ulong = 0,
    insert_id: c_ulong = 0,
    activate_id: c_ulong = 0,
    prev_id: c_ulong = 0,
    next_id: c_ulong = 0,

    fn refresh(self: *State) bool {
        const terminal = self.terminal orelse return false;
        const text = std.mem.span(gtk_editable_get_text(self.editable));
        if (std.mem.eql(u8, text, self.needle[0..self.needle_len])) return false;
        self.needle_len = 0;
        if (validNeedle(text)) {
            @memcpy(self.needle[0..text.len], text);
            self.needle_len = text.len;
        }
        vte_terminal_search_set_regex(terminal, null, 0);
        if (self.regex) |r| _ = vte_regex_unref(r);
        self.regex = null;
        if (text.len == 0 or !validNeedle(text)) return true;
        var err: ?*GError = null;
        // CASELESS | MULTILINE, VTE's regex engine handles Unicode.
        self.regex = vte_regex_new_for_search(text.ptr, @intCast(text.len), 0x00000008 | 0x00000400, &err);
        if (err) |e| g_error_free(e);
        vte_terminal_search_set_regex(terminal, self.regex, 0);
        return true;
    }
};

pub const FindOverlay = struct {
    state: *State,
    pub fn init(a: std.mem.Allocator, anchor: *GtkWidget, terminal: *VteTerminal) !FindOverlay {
        const state = try a.create(State);
        const popover = gtk_popover_new();
        _ = g_object_ref_sink(@ptrCast(popover));
        _ = g_object_ref(@ptrCast(terminal));
        gtk_popover_set_position(@ptrCast(popover), 3);
        gtk_popover_set_has_arrow(@ptrCast(popover), 0);
        gtk_popover_set_autohide(@ptrCast(popover), 1);
        gtk_widget_set_parent(popover, anchor);
        const row = gtk_box_new(0, 6);
        const entry = gtk_search_entry_new();
        gtk_widget_set_hexpand(entry, 1);
        const prev = gtk_button_new_from_icon_name("go-up-symbolic");
        const next = gtk_button_new_from_icon_name("go-down-symbolic");
        gtk_widget_set_tooltip_text(prev, "Find previous (Ctrl+Shift+G)");
        gtk_widget_set_tooltip_text(next, "Find next (Ctrl+G)");
        gtk_box_append(@ptrCast(row), entry);
        gtk_box_append(@ptrCast(row), prev);
        gtk_box_append(@ptrCast(row), next);
        gtk_popover_set_child(@ptrCast(popover), row);
        vte_terminal_search_set_wrap_around(terminal, 1);
        state.* = .{ .allocator = a, .terminal = terminal, .popover = popover, .anchor = anchor, .entry = entry, .editable = gtk_editable_get_delegate(@ptrCast(entry)) orelse @ptrCast(entry), .prev = prev, .next = next };
        return .{ .state = state };
    }
    pub fn install(self: *FindOverlay) void {
        const s = self.state;
        if (s.search_id != 0) return;
        s.search_id = gtk.g_signal_connect_data(@ptrCast(s.entry), "search-changed", @ptrCast(&onSearchChanged), s, null, 0);
        s.insert_id = gtk.g_signal_connect_data(@ptrCast(s.editable), "insert-text", @ptrCast(&onInsertText), s, null, 0);
        s.activate_id = gtk.g_signal_connect_data(@ptrCast(s.entry), "activate", @ptrCast(&onNext), s, null, 0);
        s.prev_id = gtk.g_signal_connect_data(@ptrCast(s.prev), "clicked", @ptrCast(&onPrev), s, null, 0);
        s.next_id = gtk.g_signal_connect_data(@ptrCast(s.next), "clicked", @ptrCast(&onNext), s, null, 0);
    }
    pub fn setTarget(self: *FindOverlay, widget: ?*GtkWidget) void {
        const s = self.state;
        const target: ?*VteTerminal = @ptrCast(widget);
        const previous = s.terminal;
        if (target == previous) return;
        if (target) |terminal| _ = g_object_ref(@ptrCast(terminal));
        s.terminal = target;
        if (previous) |old| {
            vte_terminal_search_set_regex(old, null, 0);
            gtk.g_object_unref(@ptrCast(old));
        }
        if (target) |terminal| {
            vte_terminal_search_set_wrap_around(terminal, 1);
            vte_terminal_search_set_regex(terminal, s.regex, 0);
        } else {
            gtk_popover_popdown(@ptrCast(s.popover));
        }
    }
    pub fn deinit(self: *FindOverlay) void {
        const s = self.state;
        if (s.search_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(s.entry), s.search_id);
        if (s.insert_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(s.editable), s.insert_id);
        if (s.activate_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(s.entry), s.activate_id);
        if (s.prev_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(s.prev), s.prev_id);
        if (s.next_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(s.next), s.next_id);
        if (s.terminal) |terminal| {
            vte_terminal_search_set_regex(terminal, null, 0);
            gtk.g_object_unref(@ptrCast(terminal));
        }
        if (s.regex) |r| _ = vte_regex_unref(r);
        gtk_widget_unparent(s.popover);
        gtk.g_object_unref(@ptrCast(s.popover));
        s.allocator.destroy(s);
    }
    pub fn open(self: *FindOverlay) void {
        const s = self.state;
        if (s.terminal == null) return;
        const rect = Rectangle{ .x = @divTrunc(@max(gtk_widget_get_width(s.anchor), 0), 2), .y = 12, .width = 1, .height = 1 };
        gtk_popover_set_pointing_to(@ptrCast(s.popover), &rect);
        gtk_popover_popup(@ptrCast(s.popover));
        _ = gtk_widget_grab_focus(s.entry);
    }
    pub fn popoverWidget(self: *FindOverlay) *GtkWidget {
        return self.state.popover;
    }
    pub fn findNext(self: *FindOverlay) void {
        // Flush GtkSearchEntry's debounce before acting on the current query.
        find(self.state, .next);
    }
    pub fn findPrevious(self: *FindOverlay) void {
        find(self.state, .previous);
    }
};
fn onSearchChanged(_: *gtk.GObject, data: gtk.gpointer) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(data orelse return));
    const terminal = s.terminal orelse return;
    if (s.refresh() and s.regex != null) _ = vte_terminal_search_find_next(terminal);
}
fn onInsertText(editable: *GtkEditable, bytes: [*]const u8, length: c_int, _: *c_int, data: gtk.gpointer) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(data orelse return));
    // Reject the entire edit rather than truncate a codepoint. GtkEditable
    // still owns selection, deletion, composition and all non-text keys.
    if (length < 0 or !canInsert(std.mem.span(gtk_editable_get_text(s.editable)), bytes[0..@intCast(length)]))
        g_signal_stop_emission_by_name(@ptrCast(editable), "insert-text");
}
fn onNext(_: *gtk.GObject, data: gtk.gpointer) callconv(.c) void {
    find(@ptrCast(@alignCast(data orelse return)), .next);
}
fn onPrev(_: *gtk.GObject, data: gtk.gpointer) callconv(.c) void {
    find(@ptrCast(@alignCast(data orelse return)), .previous);
}

fn find(s: *State, direction: enum { next, previous }) void {
    const terminal = s.terminal orelse return;
    _ = s.refresh();
    if (s.regex == null) return;
    _ = switch (direction) {
        .next => vte_terminal_search_find_next(terminal),
        .previous => vte_terminal_search_find_previous(terminal),
    };
}

test "FindOverlay struct compiles" {
    if (builtin.os.tag != .linux) return;
    _ = FindOverlay;
}
test "find edits are bounded UTF8 and reject binary/control input" {
    try std.testing.expect(canInsert("naïve", " 日本語"));
    try std.testing.expect(!canInsert("", "\xff"));
    try std.testing.expect(!canInsert("", "x\x00y"));
    try std.testing.expect(!canInsert("", "x\x1b[31m"));
    try std.testing.expect(!canInsert("", "line\ncommand"));
    try std.testing.expect(!canInsert("", "\xc2\x85"));
    const full: [max_needle_bytes]u8 = @splat('x');
    try std.testing.expect(canInsert(&full, ""));
    try std.testing.expect(!canInsert(&full, "é"));
}
