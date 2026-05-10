//! NSTextInputClient bindings for IME / dead-key composition.
//!
//! The terminal view sits in front of a ghostty surface and captures
//! every keystroke. For Latin-only input we encode straight through
//! `ghostty_surface_key`; for IME (CJK, Hangul, dead keys, emoji
//! picker, AppKit-handled command keys) we route through
//! `interpretKeyEvents:`, which fires these callbacks on whichever
//! NSView is responder.
//!
//! Key ↔ ghostty integration:
//! - `current_keydown` / `handled_during_interpret`: the keyDownImpl
//!   in view.zig stashes the NSEvent + reads the flag after
//!   `interpretKeyEvents:` returns. `doCommandBySelectorImpl` re-issues
//!   the event through ghostty's encoder so AppKit-handled commands
//!   (arrows, Tab, Enter, Backspace, …) match the wire format of a
//!   non-IME keypress.
//! - `preedit_len`: protocol-side query state for markedRange /
//!   hasMarkedText, and the gate that flagsChangedImpl + keyDownImpl
//!   read to detect mid-composition.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const ghostty_runtime = @import("../ghostty/runtime.zig");

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

/// Sentinel returned by NSTextInputClient methods when there's no
/// value (e.g. markedRange when nothing's composing).
/// `kCFNotFound`/`NSNotFound` = NSIntegerMax = (1 << 63) - 1 on
/// 64-bit darwin.
pub const ns_not_found: c_ulong = (@as(c_ulong, 1) << 63) - 1;

const preedit_buf_size: usize = 256;
var preedit_buf: [preedit_buf_size]u8 = undefined;

/// Public so view.zig's keyDownImpl + flagsChangedImpl can gate on
/// active composition. Set by setMarkedTextImpl / unmarkTextImpl /
/// insertTextImpl.
pub var preedit_len: usize = 0;

/// Stashed by keyDownImpl while `interpretKeyEvents:` runs so
/// `doCommandBySelector` can recover the original NSEvent and
/// re-encode it via the ghostty key encoder. Reset to null when
/// `interpretKeyEvents:` returns.
pub var current_keydown: ?objc.c.id = null;

/// Set by insertTextImpl / setMarkedTextImpl / doCommandBySelectorImpl
/// when called inside `interpretKeyEvents:`. Lets keyDownImpl skip
/// its fall-through `ghostty_surface_key` call so AppKit-handled
/// events don't get encoded twice.
pub var handled_during_interpret: bool = false;

/// Forward IME preedit (in-progress composition) to the ghostty
/// surface so it paints the underline overlay at the cursor cell.
/// Empty slice clears the composition.
fn forwardPreedit(text: []const u8) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_preedit(surf, text.ptr, text.len);
}

/// Forward a UTF-8 text blob to the ghostty surface (IME commit
/// path). Returns false when the surface isn't bound yet.
fn forwardText(text: []const u8) bool {
    const surf_ptr = app.g.ghostty.surface orelse return false;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_text(surf, text.ptr, text.len);
    return true;
}

pub fn insertTextImpl(self_id: objc.c.id, _: objc.c.SEL, str_id: objc.c.id, _: NSRange) callconv(.c) void {
    handled_during_interpret = true;
    preedit_len = 0;
    forwardPreedit(&[_]u8{});

    // `string` is NSString or NSAttributedString. Both respond to
    // -UTF8String, but NSAttributedString returns the attributed
    // representation; pull plain via -string when present.
    var s = objc.Object.fromId(str_id);
    if (s.value == null) return;
    if (s.msgSend(bool, "respondsToSelector:", .{objc.sel("string")})) {
        s = s.msgSend(objc.Object, "string", .{});
        if (s.value == null) return;
    }
    const utf8_ptr = s.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return;
    const text = std.mem.sliceTo(utf8_ptr, 0);
    if (text.len > 0) {
        _ = forwardText(text);
    }
    _ = self_id;
}

pub fn doCommandBySelectorImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.SEL) callconv(.c) void {
    // AppKit recognized the key as a command (arrows, Tab, Enter, Esc,
    // Backspace, …). Re-issue the original NSEvent through ghostty's
    // surface_key path so the wire format matches a non-IME keypress.
    handled_during_interpret = true;
    const event_id = current_keydown orelse return;
    const surf_ptr = app.g.ghostty.surface orelse return;
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const event = objc.Object.fromId(event_id);
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});

    const mods_g = ghostty_input.modsFromNS(flags);
    const key_event = ghostty_runtime.c.ghostty_input_key_s{
        .action = ghostty_runtime.c.GHOSTTY_ACTION_PRESS,
        .mods = mods_g,
        .consumed_mods = mods_g,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    };
    _ = ghostty_runtime.c.ghostty_surface_key(surf, key_event);
}

pub fn setMarkedTextImpl(_: objc.c.id, _: objc.c.SEL, str_id: objc.c.id, _: NSRange, _: NSRange) callconv(.c) void {
    handled_during_interpret = true;
    var s = objc.Object.fromId(str_id);
    if (s.value == null) {
        preedit_len = 0;
    } else {
        if (s.msgSend(bool, "respondsToSelector:", .{objc.sel("string")})) {
            s = s.msgSend(objc.Object, "string", .{});
        }
        if (s.value == null) {
            preedit_len = 0;
        } else {
            const utf8_ptr = s.msgSend([*c]const u8, "UTF8String", .{});
            if (utf8_ptr == null) {
                preedit_len = 0;
            } else {
                const text = std.mem.sliceTo(utf8_ptr, 0);
                const take = @min(text.len, preedit_buf_size);
                @memcpy(preedit_buf[0..take], text[0..take]);
                preedit_len = take;
            }
        }
    }
    forwardPreedit(preedit_buf[0..preedit_len]);
}

pub fn unmarkTextImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    preedit_len = 0;
    forwardPreedit(&[_]u8{});
}

pub fn selectedRangeImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    // Terminal has no "document" with a stable range — report zero.
    return .{ .location = 0, .length = 0 };
}

pub fn markedRangeImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    if (preedit_len == 0) return .{ .location = ns_not_found, .length = 0 };
    return .{ .location = 0, .length = @intCast(preedit_len) };
}

pub fn hasMarkedTextImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return preedit_len > 0;
}

pub fn attributedSubstringForProposedRangeImpl(_: objc.c.id, _: objc.c.SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.c.id {
    return null;
}

pub fn validAttributesForMarkedTextImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    const NSArray = objc.getClass("NSArray") orelse return null;
    const arr = NSArray.msgSend(objc.Object, "array", .{});
    return arr.value;
}

pub fn firstRectForCharacterRangeImpl(self_id: objc.c.id, _: objc.c.SEL, _: NSRange, _: ?*NSRange) callconv(.c) NSRect {
    // IME UI (candidate window etc.) anchors to this rect. Query
    // ghostty for the cursor position via ghostty_surface_ime_point;
    // returned coords are view-local pixels with top-left origin, so
    // we flip y to NSView's bottom-left convention before converting
    // to window → screen coords.
    const empty = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const view = objc.Object.fromId(self_id);
    const surf_ptr = app.g.ghostty.surface orelse return empty;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);

    var x: f64 = 0;
    var y: f64 = 0;
    var width: f64 = app.g.term.cell_w;
    var height: f64 = app.g.term.cell_h;
    ghostty_runtime.c.ghostty_surface_ime_point(surf, &x, &y, &width, &height);

    const frame = view.msgSend(NSRect, "frame", .{});
    const view_rect = NSRect{
        .origin = .{ .x = x, .y = frame.size.height - y },
        .size = .{ .width = width, .height = @max(height, app.g.term.cell_h) },
    };
    const win_rect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(?*anyopaque, null) });
    const window = view.msgSend(objc.Object, "window", .{});
    if (window.value == null) return empty;
    return window.msgSend(NSRect, "convertRectToScreen:", .{win_rect});
}

pub fn characterIndexForPointImpl(_: objc.c.id, _: objc.c.SEL, _: NSPoint) callconv(.c) c_ulong {
    return ns_not_found;
}
