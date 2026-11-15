const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const ghostty_runtime = @import("../ghostty/runtime.zig");
const chrome_mod = @import("../chrome.zig");

// ─── Find on page ────────────────────────────────────────────────────
//
// Cmd+F enters find mode. While `app.g.find.mode` is true, view.zig's
// keyDownImpl routes printable keys into the needle buffer
// (`app.g.find.query_buf`) instead of the ghostty surface and
// `pushNeedle()` fires `search:<needle>` via the binding-action API;
// backspace shrinks the needle; Esc / Return exit + clear; Cmd+F
// again toggles off. The display NSTextField is read-only —
// borderless NSPanel + NSTextField + ghostty surface don't compose
// into a working field editor, so we own input + just paint the
// result into the field.

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

var g_chip_cell_class_registered: bool = false;

/// Append a complete-codepoint prefix that fits. The existing buffer must
/// contain valid UTF-8. Reject the entire input if it is invalid or contains
/// control characters (including embedded NULs), rather than searching a
/// misleading prefix of clipboard/binary data. No allocation or AppKit state.
fn validQueryText(text: []const u8) bool {
    const utf8 = std.unicode.Utf8View.init(text) catch return false;
    var it = utf8.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    }
    return true;
}

pub fn appendQueryBuffer(buffer: []u8, len: *usize, text: []const u8) bool {
    if (!validQueryText(text)) return false;
    const room = buffer.len - len.*;
    var take: usize = 0;
    while (take < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[take]) catch unreachable;
        if (width > room - take) break;
        take += width;
    }
    if (take == 0) return false;
    @memcpy(buffer[len.* .. len.* + take], text[0..take]);
    len.* += take;
    return true;
}

/// Synchronously copy a start_search needle. Null opens an empty overlay or
/// preserves an already-open query. An explicit needle replaces even an open
/// query; oversized valid text is clipped at a UTF-8 boundary. Malformed/control
/// input is rejected in FULL (including beyond capacity), preserving an open
/// query and issuing no search. True means issue search, including empty text.
fn applyStartSearchQuery(buffer: []u8, len: *usize, was_open: bool, needle: ?[]const u8) bool {
    if (!was_open) len.* = 0;
    const text = needle orelse return false;
    if (!validQueryText(text)) return false;
    len.* = 0;
    _ = appendQueryBuffer(buffer, len, text);
    return true;
}

/// Remove one Unicode scalar value, not one byte. Grapheme clusters may
/// require multiple backspaces; the buffer always remains valid UTF-8.
pub fn backspaceQueryBuffer(buffer: []const u8, len: *usize) bool {
    if (len.* == 0) return false;
    len.* -= 1;
    while (len.* > 0 and (buffer[len.*] & 0xc0) == 0x80) len.* -= 1;
    return true;
}

/// Shared keyboard/clipboard query input. Rejected input never reaches the
/// terminal, and a full buffer does not issue a redundant search action.
pub fn appendText(text: []const u8) void {
    if (!app.g.find.mode) return;
    if (appendQueryBuffer(&app.g.find.query_buf, &app.g.find.query_len, text)) pushNeedle();
}

/// Pump a ghostty binding action ("start_search", "end_search",
/// "search:foo", "navigate_search:next"). Local copy so the find
/// module doesn't have to back-import view.zig; the call surface is
/// trivially small (3 lines).
fn forwardBindingAction(action_str: []const u8) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    _ = ghostty_runtime.c.ghostty_surface_binding_action(surf, action_str.ptr, action_str.len);
}

/// Build the find-overlay NSTextField + DjinnChipCell, wire it as a
/// subview of `parent` (the terminal view), stash it on
/// `app.g.find.field_id`. Hidden until Cmd+F flips `find_mode`.
/// Width auto-sizes in `updateCountLabel` — initial frame just
/// reserves a slot in the responder chain + an initial position.
pub fn createOverlay(parent: objc.Object, width: f64, height: f64, style: chrome_mod.Style) !void {
    registerChipCellClass();
    const NSTextField = objc.getClass("NSTextField") orelse return error.ClassNotFound;
    const NSColor = objc.getClass("NSColor") orelse return error.ClassNotFound;
    const tf_alloc = NSTextField.msgSend(objc.Object, "alloc", .{});
    const tf_h: f64 = 24;
    const tf_margin: f64 = 14;
    const tf_init_w: f64 = 80;
    const tf_frame = NSRect{
        .origin = .{ .x = width - tf_init_w - tf_margin, .y = height - tf_h - tf_margin },
        .size = .{ .width = tf_init_w, .height = tf_h },
    };
    const tf = tf_alloc.msgSend(objc.Object, "initWithFrame:", .{tf_frame});
    // DjinnChipCell vertically centers the attributed text — stock
    // NSTextFieldCell baselines at top.
    const ChipCellClass = objc.getClass("DjinnChipCell") orelse return error.ClassNotFound;
    const cell_alloc = ChipCellClass.msgSend(objc.Object, "alloc", .{});
    const cell = cell_alloc.msgSend(objc.Object, "init", .{});
    tf.msgSend(void, "setCell:", .{cell});
    tf.msgSend(void, "setBezeled:", .{@as(c_int, 0)});
    tf.msgSend(void, "setEditable:", .{@as(c_int, 0)});
    tf.msgSend(void, "setSelectable:", .{@as(c_int, 0)});
    tf.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
    tf.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    // NSViewMinXMargin (1) + NSViewMinYMargin (32) — pinned
    // top-right under live resize. Width is dynamic so the
    // autoresize mask doesn't need to track height/width.
    tf.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 | 32)});
    const tf_cell = tf.msgSend(objc.Object, "cell", .{});
    if (tf_cell.value != null) {
        tf_cell.msgSend(void, "setUsesSingleLineMode:", .{@as(c_int, 1)});
        // NSLineBreakByClipping = 4. Stops the cell from shrinking
        // text to fit when the needle gets long.
        tf_cell.msgSend(void, "setLineBreakMode:", .{@as(c_long, 4)});
    }
    tf.msgSend(void, "setBackgroundColor:", .{chrome_mod.nsColorFromRgb(NSColor, style.chip.bg)});
    tf.msgSend(void, "setTextColor:", .{chrome_mod.nsColorFromRgb(NSColor, style.chip.fg)});
    // Lifted bg + 1px border + 4px round corners. Border survives
    // background-opacity translucency where the bg fill alone can
    // disappear into the desktop backdrop.
    tf.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    const tf_layer = tf.msgSend(objc.Object, "layer", .{});
    if (tf_layer.value != null) {
        tf_layer.msgSend(void, "setCornerRadius:", .{@as(f64, 4)});
        tf_layer.msgSend(void, "setMasksToBounds:", .{@as(c_int, 1)});
        tf_layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1)});
        const border_ns = chrome_mod.nsColorFromRgb(NSColor, style.chip.border);
        tf_layer.msgSend(void, "setBorderColor:", .{border_ns.msgSend(?*anyopaque, "CGColor", .{})});
    }
    parent.msgSend(void, "addSubview:", .{tf});
    app.g.find.field_id = tf.value;
    applyFindOverlayFont(tf, style);
}

/// Re-render the find-overlay display field from current state.
/// Three styled runs: dim "find " label, fg needle, dim count. Layout
/// echoes the log-pane "ACTIVITY" header idiom so the find overlay
/// reads as the same chrome family rather than a stray native field.
pub fn updateCountLabel() void {
    const fid = app.g.find.field_id orelse return;
    const tf = objc.Object.fromId(fid);
    if (!app.g.find.mode) {
        tf.msgSend(void, "setHidden:", .{@as(c_int, 1)});
        return;
    }
    const style = app.g.theme.chrome_style orelse return;

    const needle = app.g.find.query_buf[0..app.g.find.query_len];
    var count_buf: [32]u8 = undefined;
    const count_str: []const u8 = blk: {
        if (app.g.find.total) |total| {
            const sel_disp: u32 = if (app.g.find.selected) |s| s + 1 else 0;
            break :blk std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ sel_disp, total }) catch "";
        }
        break :blk "";
    };

    const NSAttributedString = objc.getClass("NSMutableAttributedString") orelse return;
    const root_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const root = root_alloc.msgSend(objc.Object, "init", .{});
    if (root.value == null) return;
    // alloc/init owned by us; setAttributedStringValue copies the
    // string into the field's cell, so we release after the set.
    defer root.msgSend(void, "release", .{});

    // Format mirrors log-entry headers (`{client} · {hh:mm}`) — middle
    // dot separators, dim accent text, fg body. Same idiom, different
    // chrome surface.
    appendFindRun(root, "find", style.chip.dim, style);
    if (needle.len > 0) {
        appendFindRun(root, " · ", style.chip.dim, style);
        appendFindRun(root, needle, style.chip.fg, style);
    }
    if (count_str.len > 0) {
        appendFindRun(root, " · ", style.chip.dim, style);
        appendFindRun(root, count_str, style.chip.dim, style);
    }

    tf.msgSend(void, "setAttributedStringValue:", .{root});

    // Auto-size width to content + horizontal padding. Re-anchor at
    // top-right of parent so the chip grows leftward, not rightward
    // off-screen. h is fixed; only width tracks content.
    const text_size = root.msgSend(NSSize, "size", .{});
    const pad_x: f64 = 32; // 16px each side — generous chip padding
    const tf_h: f64 = 24;
    const margin: f64 = 14;
    const new_w = @ceil(text_size.width) + pad_x;
    const parent = tf.msgSend(objc.Object, "superview", .{});
    if (parent.value != null) {
        const parent_frame = parent.msgSend(NSRect, "frame", .{});
        const new_frame = NSRect{
            .origin = .{
                .x = parent_frame.size.width - new_w - margin,
                .y = parent_frame.size.height - tf_h - margin,
            },
            .size = .{ .width = new_w, .height = tf_h },
        };
        tf.msgSend(void, "setFrame:", .{new_frame});
    }

    tf.msgSend(void, "setHidden:", .{@as(c_int, 0)});
}

/// Append one styled run to the find-overlay's attributed string.
/// Center-aligned, system UI font at semibold weight — chip typography
/// sits on a different axis from the terminal so the overlay doesn't
/// blend into the surface text behind it.
fn appendFindRun(root: objc.Object, text: []const u8, color: chrome_mod.Rgb, style: chrome_mod.Style) void {
    const NSString = objc.getClass("NSString") orelse return;
    const NSColor = objc.getClass("NSColor") orelse return;
    const NSDictionary = objc.getClass("NSDictionary") orelse return;
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSParagraphStyle = objc.getClass("NSMutableParagraphStyle") orelse return;

    // Length-based conversion avoids truncating UTF-8 or embedded NULs.
    // Invalid input can still fail conversion: never pass nil to an
    // attributed-string initializer (it raises an AppKit exception).
    const ns_text = NSString.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithBytes:length:encoding:", .{
        text.ptr, @as(c_ulong, @intCast(text.len)), @as(c_ulong, 4), // NSUTF8StringEncoding
    });
    if (ns_text.value == null) return;
    defer ns_text.msgSend(void, "release", .{});

    const font = chrome_mod.chromeFont(NSFont, style.font_size_chip);
    const ns_color = chrome_mod.nsColorFromRgb(NSColor, color);

    // NSCenterTextAlignment = 2. NSTextField paints the cell vertically
    // centered already; horizontal center keeps the chip balanced even
    // when needle length changes (no jitter).
    //
    // `alloc/init` returns +1 retain owned by us; the dict retains on
    // insert. release after balances the +1 so para's lifetime tracks
    // the dict's.
    const para = NSParagraphStyle.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer para.msgSend(void, "release", .{});
    para.msgSend(void, "setAlignment:", .{@as(c_long, 2)});

    const fg_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSColor")});
    const font_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSFont")});
    const para_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSParagraphStyle")});
    if (fg_key.value == null or font_key.value == null or para_key.value == null or
        ns_color.value == null or font.value == null or para.value == null) return;
    const objects = [_]objc.c.id{ ns_color.value, font.value, para.value };
    const keys = [_]objc.c.id{ fg_key.value, font_key.value, para_key.value };
    const dict = NSDictionary.msgSend(
        objc.Object,
        "dictionaryWithObjects:forKeys:count:",
        .{ &objects, &keys, @as(c_ulong, 3) },
    );

    if (dict.value == null) return;
    const attr_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const attr = attr_alloc.msgSend(objc.Object, "initWithString:attributes:", .{ ns_text, dict });
    if (attr.value == null) return;
    defer attr.msgSend(void, "release", .{});
    root.msgSend(void, "appendAttributedString:", .{attr});
}

/// Set the NSFont on the find-overlay textfield. Bare-string fallback
/// before updateCountLabel pushes the styled attributed value.
fn applyFindOverlayFont(tf: objc.Object, style: chrome_mod.Style) void {
    const NSFont = objc.getClass("NSFont") orelse return;
    tf.msgSend(void, "setFont:", .{chrome_mod.chromeFont(NSFont, style.font_size_chip)});
}

/// Reskin the find-overlay chip after a theme reload. Layer bg + font
/// flip immediately; the per-run colors of the next setAttributedStringValue
/// pick up `style.chip.*` automatically since updateCountLabel reads
/// `app.g.theme.chrome_style` on every call.
pub fn applyOverlayStyle(style: chrome_mod.Style) void {
    const fid = app.g.find.field_id orelse return;
    const tf = objc.Object.fromId(fid);
    const NSColor = objc.getClass("NSColor") orelse return;
    tf.msgSend(void, "setBackgroundColor:", .{chrome_mod.nsColorFromRgb(NSColor, style.chip.bg)});
    tf.msgSend(void, "setTextColor:", .{chrome_mod.nsColorFromRgb(NSColor, style.chip.fg)});

    const tf_layer = tf.msgSend(objc.Object, "layer", .{});
    if (tf_layer.value != null) {
        const border_ns = chrome_mod.nsColorFromRgb(NSColor, style.chip.border);
        tf_layer.msgSend(void, "setBorderColor:", .{border_ns.msgSend(?*anyopaque, "CGColor", .{})});
    }

    applyFindOverlayFont(tf, style);
    if (app.g.find.mode) updateCountLabel();
}

/// Register `DjinnChipCell : NSTextFieldCell` once. The override
/// vertically centers attributed text within the cell rect — stock
/// NSTextFieldCell baselines at the top regardless of
/// `usesSingleLineMode`, which leaves chip text floating above center.
fn registerChipCellClass() void {
    if (g_chip_cell_class_registered) return;
    g_chip_cell_class_registered = true;

    const superclass = objc.getClass("NSTextFieldCell") orelse return;
    const cls = objc.allocateClassPair(superclass, "DjinnChipCell") orelse return;
    _ = cls.addMethod("drawInteriorWithFrame:inView:", drawChipInteriorImpl);
    objc.registerClassPair(cls);
}

fn drawChipInteriorImpl(
    self: objc.c.id,
    _: objc.c.SEL,
    frame: NSRect,
    control_view: objc.c.id,
) callconv(.c) void {
    _ = control_view;
    const cell = objc.Object.fromId(self);
    const attr = cell.msgSend(objc.Object, "attributedStringValue", .{});
    if (attr.value == null) return;
    const text_size = attr.msgSend(NSSize, "size", .{});

    // Center on both axes. Frame is sized to text + horizontal padding
    // by updateCountLabel, so horizontal centering yields equal padding
    // on each side regardless of needle length.
    var rect = frame;
    if (text_size.height < frame.size.height) {
        rect.origin.y = frame.origin.y + (frame.size.height - text_size.height) / 2.0;
        rect.size.height = text_size.height;
    }
    if (text_size.width < frame.size.width) {
        rect.origin.x = frame.origin.x + (frame.size.width - text_size.width) / 2.0;
        rect.size.width = text_size.width;
    }
    attr.msgSend(void, "drawInRect:", .{rect});
}

fn pushNeedle() void {
    var buf: [160]u8 = undefined;
    const prefix = "search:";
    @memcpy(buf[0..prefix.len], prefix);
    const n = app.g.find.query_len;
    @memcpy(buf[prefix.len .. prefix.len + n], app.g.find.query_buf[0..n]);
    app.g.find.total = null;
    app.g.find.selected = null;
    forwardBindingAction(buf[0 .. prefix.len + n]);
    updateCountLabel();
}

fn enterMode() void {
    if (app.g.find.mode) return;
    app.g.find.mode = true;
    app.g.find.query_len = 0;
    app.g.find.total = null;
    app.g.find.selected = null;
    updateCountLabel();
    forwardBindingAction("start_search");
}

/// End search on the CURRENT global surface and clear all overlay state.
/// Lifecycle callers must invoke this BEFORE switching or destroying the
/// active surface, so end_search reaches the old search owner.
pub fn endSearch() void {
    const was_open = app.g.find.mode;
    closeOverlayUiOnly();
    // end_search calls Search.deinit which joins the search thread.
    // The thread's defer-block fires `.quit` via the event callback,
    // which surface routes through its mailbox to clear renderer
    // highlights. This is safe even if UI state was already closed.
    forwardBindingAction("end_search");
    if (!was_open) return;
    // Re-anchor first responder on the terminal view. The end_search
    // path blocks main on Search.deinit's thread.join; AppKit can
    // shuffle event/responder state during that pause and stop
    // delivering keyDown back to us. Force the responder back.
    if (app.g.term.view_id) |vid| {
        const view = objc.Object.fromId(vid);
        const window = view.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{view});
        }
    }
}

/// Public UI-sync entry point for ghostty's end_search action.
/// Hides UI without re-emitting the binding (would recurse).
pub fn closeOverlayUiOnly() void {
    app.g.find.mode = false;
    app.g.find.query_len = 0;
    app.g.find.total = null;
    app.g.find.selected = null;
    updateCountLabel();
}

/// Handle Ghostty's borrowed start_search payload without re-emitting
/// start_search (which would recurse). search_selection frees it on return.
pub fn startSearchFromGhostty(needle: ?[]const u8) void {
    const was_open = app.g.find.mode;
    const search = applyStartSearchQuery(&app.g.find.query_buf, &app.g.find.query_len, was_open, needle);
    app.g.find.mode = true;
    if (!was_open) {
        app.g.find.total = null;
        app.g.find.selected = null;
    }
    if (search) pushNeedle() else updateCountLabel();
}

/// UI-only opener retained for callers without a search payload.
pub fn openOverlayUiOnly() void {
    startSearchFromGhostty(null);
}

pub fn actionOpen() void {
    if (app.g.find.mode) {
        endSearch();
        return;
    }
    enterMode();
}

/// Handle a keystroke while find_mode is active. Caller (keyDownImpl)
/// only invokes this when find_mode is true and no command modifier
/// is held.
pub fn handleKey(event: objc.Object, keycode: u16) void {
    // Esc / Return — exit, clear highlights.
    if (keycode == 53 or keycode == 36 or keycode == 76) {
        endSearch();
        return;
    }
    // Backspace — shrink needle. Re-pushes (empty needle stops search
    // per ghostty semantics, but UI stays in find mode).
    if (keycode == 51) {
        if (backspaceQueryBuffer(&app.g.find.query_buf, &app.g.find.query_len)) pushNeedle();
        return;
    }
    // Append printable text from event.characters.
    const chars_obj = event.msgSend(objc.Object, "characters", .{});
    if (chars_obj.value == null) return;
    const chars_ptr = chars_obj.msgSend([*c]const u8, "UTF8String", .{});
    if (chars_ptr == null) return;
    const s = std.mem.sliceTo(chars_ptr, 0);
    if (s.len == 0) return;
    // AppKit encodes arrows/function keys in this private-use range;
    // they aren't query text. Control/binary rejection is shared with paste.
    if (s.len == 3 and s[0] == 0xef and s[1] >= 0x9c and s[1] <= 0xa3) return;
    appendText(s);
}

pub fn actionNext() void {
    forwardBindingAction("navigate_search:next");
}

pub fn actionPrev() void {
    forwardBindingAction("navigate_search:previous");
}

test "start_search synchronously replaces a query even when already open" {
    var buffer: [16]u8 = undefined;
    var len: usize = 0;
    var borrowed = [_]u8{ 'n', 'e', 'w' };
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "old"));
    try std.testing.expect(applyStartSearchQuery(&buffer, &len, true, &borrowed));
    @memset(&borrowed, 'x');
    try std.testing.expectEqualStrings("new", buffer[0..len]);
    try std.testing.expect(!applyStartSearchQuery(&buffer, &len, true, null));
    try std.testing.expectEqualStrings("new", buffer[0..len]);
    try std.testing.expect(applyStartSearchQuery(&buffer, &len, true, ""));
    try std.testing.expectEqual(@as(usize, 0), len);
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "stale"));
    try std.testing.expect(!applyStartSearchQuery(&buffer, &len, false, null));
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "start_search bounds valid UTF-8 and rejects malformed payloads in full" {
    const text = "aé界😀";
    for (0..text.len + 1) |capacity| {
        var buffer: [16]u8 = undefined;
        var len: usize = 0;
        try std.testing.expect(applyStartSearchQuery(buffer[0..capacity], &len, false, text));
        const expected: usize = if (capacity >= 10) 10 else if (capacity >= 6) 6 else if (capacity >= 3) 3 else if (capacity >= 1) 1 else 0;
        try std.testing.expectEqual(expected, len);
        try std.testing.expectEqualStrings(text[0..expected], buffer[0..len]);
    }
    for ([_][]const u8{ "a\xff", "\xc3", "\xed\xa0\x80", "abcde\xff", "abcde\n", "a\x00b", "\u{85}" }) |bad| {
        var buffer: [4]u8 = undefined;
        var len: usize = 0;
        try std.testing.expect(appendQueryBuffer(&buffer, &len, "old"));
        try std.testing.expect(!applyStartSearchQuery(&buffer, &len, true, bad));
        try std.testing.expectEqualStrings("old", buffer[0..len]);
        try std.testing.expect(!applyStartSearchQuery(&buffer, &len, false, bad));
        try std.testing.expectEqual(@as(usize, 0), len);
    }
}

test "query append and backspace preserve complete UTF-8 codepoints" {
    var buffer: [32]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "aé界😀"));
    try std.testing.expectEqualStrings("aé界😀", buffer[0..len]);
    for ([_][]const u8{ "aé界", "aé", "a", "" }) |expected| {
        try std.testing.expect(backspaceQueryBuffer(&buffer, &len));
        try std.testing.expectEqualStrings(expected, buffer[0..len]);
        try std.testing.expect(std.unicode.utf8ValidateSlice(buffer[0..len]));
    }
    try std.testing.expect(!backspaceQueryBuffer(&buffer, &len));
}

test "query capacity truncates only between codepoints" {
    const text = "aé界😀";
    for (0..text.len + 2) |capacity| {
        var buffer: [16]u8 = undefined;
        var len: usize = 0;
        _ = appendQueryBuffer(buffer[0..capacity], &len, text);
        const expected_len: usize = if (capacity >= 10) 10 else if (capacity >= 6) 6 else if (capacity >= 3) 3 else if (capacity >= 1) 1 else 0;
        try std.testing.expectEqual(expected_len, len);
        try std.testing.expectEqualStrings(text[0..expected_len], buffer[0..len]);
        try std.testing.expect(std.unicode.utf8ValidateSlice(buffer[0..len]));
    }

    var buffer: [5]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "é"));
    try std.testing.expect(!appendQueryBuffer(&buffer, &len, "😀"));
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "界"));
    try std.testing.expect(!appendQueryBuffer(&buffer, &len, "x"));
    try std.testing.expectEqualStrings("é界", buffer[0..len]);
    try std.testing.expect(backspaceQueryBuffer(&buffer, &len));
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "abc"));
    try std.testing.expectEqualStrings("éabc", buffer[0..len]);
}

test "query rejects invalid UTF-8 and binary or control input atomically" {
    var buffer: [16]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "ok"));
    for ([_][]const u8{
        "",      "x\x00y", "x\ny", "\t",       "\x7f",         "\u{85}",
        "x\xff", "\xc3",   "\x80", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80",
    }) |input| {
        try std.testing.expect(!appendQueryBuffer(&buffer, &len, input));
        try std.testing.expectEqualStrings("ok", buffer[0..len]);
    }
    // Invalid data beyond available capacity must not permit a valid prefix.
    try std.testing.expect(!appendQueryBuffer(buffer[0..3], &len, "a\xff"));
    try std.testing.expectEqualStrings("ok", buffer[0..len]);
}

test "query backspace treats combining marks as codepoints" {
    var buffer: [8]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(appendQueryBuffer(&buffer, &len, "e\u{301}"));
    try std.testing.expect(backspaceQueryBuffer(&buffer, &len));
    try std.testing.expectEqualStrings("e", buffer[0..len]);
}
