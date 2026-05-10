//! Palette switcher — Cmd+Shift+P modal overlay listing all profile
//! sessions. Type-to-filter, Up/Down to move selection, Return to
//! switch, Esc to dismiss.
//!
//! Owns input via `app.g.palette.mode` while open: keyDownImpl routes
//! printable keys here instead of the ghostty surface, mirroring the
//! find-mode pattern. Borderless NSPanel + NSTextField + ghostty
//! surface don't compose into a working field editor — host-owned
//! input is the working option.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const chrome = @import("../chrome.zig");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// Modal box dimensions in points. Width covers ~30 chars at 11pt;
/// height fits header + ~9 rows + footer hint.
const palette_w: f64 = 360;
const row_h: f64 = 24;
const header_h: f64 = 32;
const max_rows: usize = 9;

pub fn open() void {
    if (app.g.palette.mode) return;
    const sm = app.g.session_manager orelse return;
    if (sm.sessions.items.len < 2) return; // nothing to switch between

    app.g.palette.mode = true;
    app.g.palette.query_len = 0;
    app.g.palette.selected = sm.active_idx;

    mountOverlay();
}

pub fn close() void {
    if (!app.g.palette.mode) return;
    app.g.palette.mode = false;
    app.g.palette.query_len = 0;
    if (app.g.palette.view_id) |vid| {
        const view = objc.Object.fromId(vid);
        view.msgSend(void, "removeFromSuperview", .{});
        app.g.palette.view_id = null;
    }
    // Re-anchor first responder on the terminal view; AppKit can
    // shuffle responder state when modal-style overlays come and go.
    if (app.g.term.view_id) |tid| {
        const term = objc.Object.fromId(tid);
        const window = term.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{term});
        }
    }
}

/// Called from `keyDownImpl` while `palette_mode` is true, with no
/// Cmd/Ctrl held. Returns whether the event was consumed.
pub fn handleKey(event: objc.Object, keycode: u16) void {
    // Esc — dismiss without switching.
    if (keycode == 53) {
        close();
        return;
    }
    // Return / Enter / numeric Enter — activate selected row.
    if (keycode == 36 or keycode == 76) {
        commitSelection();
        return;
    }
    // Up / Down — move selection within the filtered list.
    if (keycode == 126) {
        if (app.g.palette.selected > 0) {
            // Walk filtered list to the previous match. Convert
            // "selected" from absolute idx to ordinal position
            // among matches, decrement, walk back.
            moveSelection(-1);
        }
        refresh();
        return;
    }
    if (keycode == 125) {
        moveSelection(1);
        refresh();
        return;
    }
    // Backspace — shrink filter.
    if (keycode == 51) {
        if (app.g.palette.query_len > 0) {
            app.g.palette.query_len -= 1;
            // Re-clamp selection to a still-matching row.
            if (firstMatch()) |idx| app.g.palette.selected = idx;
        }
        refresh();
        return;
    }
    // Printable — append to filter.
    const chars_obj = event.msgSend(objc.Object, "characters", .{});
    if (chars_obj.value == null) return;
    const chars_ptr = chars_obj.msgSend([*c]const u8, "UTF8String", .{});
    if (chars_ptr == null) return;
    const s = std.mem.sliceTo(chars_ptr, 0);
    if (s.len == 0) return;
    if (s.len == 1 and s[0] < 0x20) return;

    const room = app.g.palette.query_buf.len - app.g.palette.query_len;
    const take = @min(s.len, room);
    @memcpy(app.g.palette.query_buf[app.g.palette.query_len .. app.g.palette.query_len + take], s[0..take]);
    app.g.palette.query_len += take;
    if (firstMatch()) |idx| app.g.palette.selected = idx;
    refresh();
}

/// Move the selection cursor by `delta` (-1 / +1) through the
/// filtered list. Wraps neither end — Up at top is a no-op.
fn moveSelection(delta: i32) void {
    const sm = app.g.session_manager orelse return;
    var sessions: usize = 0;
    var current_ordinal: usize = 0;
    var found_current = false;
    for (sm.sessions.items, 0..) |sess, i| {
        if (!matches(sess.profile.label())) continue;
        if (i == app.g.palette.selected) {
            current_ordinal = sessions;
            found_current = true;
        }
        sessions += 1;
    }
    if (sessions == 0) return;
    if (!found_current) current_ordinal = 0;

    const next_ordinal: usize = blk: {
        if (delta < 0) {
            if (current_ordinal == 0) break :blk 0;
            break :blk current_ordinal - 1;
        }
        if (current_ordinal + 1 >= sessions) break :blk sessions - 1;
        break :blk current_ordinal + 1;
    };

    var seen: usize = 0;
    for (sm.sessions.items, 0..) |sess, i| {
        if (!matches(sess.profile.label())) continue;
        if (seen == next_ordinal) {
            app.g.palette.selected = i;
            return;
        }
        seen += 1;
    }
}

fn commitSelection() void {
    const sm = app.g.session_manager orelse return;
    const idx = app.g.palette.selected;
    if (idx >= sm.sessions.items.len) {
        close();
        return;
    }
    if (!matches(sm.sessions.items[idx].profile.label())) {
        // Selection drifted out of the filter; fall through to first
        // matching row instead.
        const first = firstMatch() orelse {
            close();
            return;
        };
        _ = @import("../main.zig").activateSession(first);
    } else {
        _ = @import("../main.zig").activateSession(idx);
    }
    close();
}

fn firstMatch() ?usize {
    const sm = app.g.session_manager orelse return null;
    for (sm.sessions.items, 0..) |sess, i| {
        if (matches(sess.profile.label())) return i;
    }
    return null;
}

/// Case-insensitive substring match — palette UX, not ranked search.
fn matches(label: []const u8) bool {
    const q = app.g.palette.query_buf[0..app.g.palette.query_len];
    if (q.len == 0) return true;
    if (q.len > label.len) return false;
    var i: usize = 0;
    while (i + q.len <= label.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < q.len) : (j += 1) {
            const a = label[i + j];
            const b = q[j];
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (al != bl) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn refresh() void {
    const id = app.g.palette.view_id orelse return;
    objc.Object.fromId(id).msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
}

fn mountOverlay() void {
    const term_id = app.g.term.view_id orelse return;
    const term = objc.Object.fromId(term_id);
    const container = term.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;
    const c_bounds = container.msgSend(NSRect, "bounds", .{});

    registerClass();
    const cls = objc.getClass("DjinnPalette") orelse return;
    const sm = app.g.session_manager orelse return;
    const visible_rows = @min(sm.sessions.items.len, max_rows);
    const palette_h = header_h + @as(f64, @floatFromInt(visible_rows)) * row_h + 8;
    const x = (c_bounds.size.width - palette_w) / 2.0;
    const y = c_bounds.size.height - palette_h - 80; // anchored ~80pt below top edge
    const view = cls.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithFrame:",
        .{NSRect{
            .origin = .{ .x = x, .y = y },
            .size = .{ .width = palette_w, .height = palette_h },
        }},
    );
    view.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});

    // 1px chip.border stroke around the palette box, same idiom as
    // find chip + log pane separator. Layer-driven so it pixel-aligns
    // on Retina without antialias drift.
    const NSColor = objc.getClass("NSColor") orelse return;
    if (app.g.theme.chrome_style) |s| {
        const layer = view.msgSend(objc.Object, "layer", .{});
        if (layer.value != null) {
            layer.msgSend(void, "setCornerRadius:", .{@as(f64, 4)});
            layer.msgSend(void, "setMasksToBounds:", .{@as(c_int, 1)});
            layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1)});
            const border = chrome.nsColorFromRgb(NSColor, s.chip.border);
            layer.msgSend(void, "setBorderColor:", .{border.msgSend(?*anyopaque, "CGColor", .{})});
        }
    }

    container.msgSend(void, "addSubview:", .{view});
    app.g.palette.view_id = view.value;
}

var g_class_registered: bool = false;

fn registerClass() void {
    if (g_class_registered) return;
    g_class_registered = true;
    const NSView = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(NSView, "DjinnPalette") orelse return;
    _ = cls.addMethod("drawRect:", drawRectImpl);
    _ = cls.addMethod("isFlipped", isFlippedImpl);
    objc.registerClassPair(cls);
}

fn isFlippedImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn drawRectImpl(self_id: objc.c.id, _: objc.c.SEL, _: NSRect) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    const bounds = view.msgSend(NSRect, "bounds", .{});
    const style = app.g.theme.chrome_style orelse return;
    const sm = app.g.session_manager orelse return;

    const NSColor = objc.getClass("NSColor") orelse return;
    const NSBezierPath = objc.getClass("NSBezierPath") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSMutableDictionary = objc.getClass("NSMutableDictionary") orelse return;

    // Backdrop fill — terminal bg, matching the surface beneath. The
    // 1px chip.border outline (set on the layer in mountOverlay) is
    // the only chrome cue that the palette is a separate surface.
    const bg = chrome.nsColorFromRgb(NSColor, style.bg);
    bg.msgSend(void, "set", .{});
    NSBezierPath.msgSend(void, "fillRect:", .{bounds});

    const font = chrome.chromeFont(NSFont, style.font_family, style.font_size_chip);
    const font_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSFont")});
    const fg_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSColor")});

    // Header: "switch profile" hint + live query text.
    var header_buf: [192]u8 = undefined;
    const q = app.g.palette.query_buf[0..app.g.palette.query_len];
    const header_z = std.fmt.bufPrintZ(&header_buf, "switch profile · {s}", .{q}) catch return;
    const header_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, header_z.ptr)});
    const header_attrs = NSMutableDictionary.msgSend(objc.Object, "dictionaryWithCapacity:", .{@as(c_ulong, 2)});
    header_attrs.msgSend(void, "setObject:forKey:", .{ font, font_key });
    header_attrs.msgSend(void, "setObject:forKey:", .{ chrome.nsColorFromRgb(NSColor, style.fg), fg_key });
    header_str.msgSend(void, "drawAtPoint:withAttributes:", .{ NSPoint{ .x = 12, .y = 8 }, header_attrs });

    // Rows: one per matching profile, capped at max_rows.
    var y: f64 = header_h;
    var shown: usize = 0;
    for (sm.sessions.items, 0..) |sess, i| {
        if (shown >= max_rows) break;
        const label = sess.profile.label();
        if (!matches(label)) continue;

        const row_rect = NSRect{
            .origin = .{ .x = 0, .y = y },
            .size = .{ .width = bounds.size.width, .height = row_h },
        };
        const is_selected = i == app.g.palette.selected;
        if (is_selected) {
            // Selected row: chip.bg lift over the surface backdrop.
            // Inverse of the prior treatment now that the palette
            // backdrop is the surface bg itself.
            const sel = chrome.nsColorFromRgb(NSColor, style.chip.bg);
            sel.msgSend(void, "set", .{});
            NSBezierPath.msgSend(void, "fillRect:", .{row_rect});
        }
        const text_color = chrome.nsColorFromRgb(NSColor, if (is_selected) style.fg else style.chip.dim);
        const row_attrs = NSMutableDictionary.msgSend(objc.Object, "dictionaryWithCapacity:", .{@as(c_ulong, 2)});
        row_attrs.msgSend(void, "setObject:forKey:", .{ font, font_key });
        row_attrs.msgSend(void, "setObject:forKey:", .{ text_color, fg_key });
        var row_buf: [128]u8 = undefined;
        const row_z = std.fmt.bufPrintZ(&row_buf, "{s}", .{label}) catch continue;
        const row_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, row_z.ptr)});
        // Vertical center within the row.
        const text_size = row_str.msgSend(NSSize, "sizeWithAttributes:", .{row_attrs});
        const text_y = y + (row_h - text_size.height) / 2.0;
        row_str.msgSend(void, "drawAtPoint:withAttributes:", .{ NSPoint{ .x = 16, .y = text_y }, row_attrs });

        y += row_h;
        shown += 1;
    }
}
