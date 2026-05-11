//! Log pane free-text filter — Cmd+Shift+L opens a chip-style
//! overlay anchored at the top-right of the panel content view.
//! Typed characters accumulate into `app.g.log_filter.query_buf`
//! and push through to `LogView.setFilter` for an incremental
//! rebuild. Esc clears the filter + exits; Return keeps the filter
//! and exits the chip; Cmd+Shift+L toggles.
//!
//! Pattern mirrors `terminal/find.zig` (chip overlay anchored to
//! the container) and `session/palette.zig` (modal key routing via
//! `app.g.log_filter.mode`). Reuses `DjinnChipCell` for vertical-
//! centered chip text — borderless NSPanel + NSTextField + ghostty
//! surface don't compose into a working field editor, so we own
//! input via keyDownImpl + paint the rendered needle into the field.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const chrome = @import("../chrome.zig");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

pub fn actionOpen() void {
    if (app.g.log_filter.mode) {
        exitMode();
        return;
    }
    app.g.log_filter.mode = true;
    ensureChip();
    refresh();
}

/// Caller (keyDownImpl) only invokes this when `log_filter.mode` is
/// true and no Cmd / Ctrl chord is held.
pub fn handleKey(event: objc.Object, keycode: u16) void {
    // Esc — clear filter + exit. The full-clear path: log view goes
    // back to showing every entry, chip hides.
    if (keycode == 53) {
        app.g.log_filter.query_len = 0;
        applyToLogView();
        exitMode();
        return;
    }
    // Return — keep filter applied, exit chip mode. Chip stays
    // visible as the "filter on" indicator while the user's focus
    // returns to the terminal.
    if (keycode == 36 or keycode == 76) {
        exitMode();
        return;
    }
    // Backspace — shrink needle by one. Empty needle is a valid
    // intermediate state; refresh shows the chip with bare "log:".
    if (keycode == 51) {
        if (app.g.log_filter.query_len > 0) {
            app.g.log_filter.query_len -= 1;
            applyToLogView();
        }
        refresh();
        return;
    }
    // Append printable text. Skip control chars (< 0x20) so Tab /
    // Ctrl chords delivered via `event.characters` don't slip in.
    const chars_obj = event.msgSend(objc.Object, "characters", .{});
    if (chars_obj.value == null) return;
    const chars_ptr = chars_obj.msgSend([*c]const u8, "UTF8String", .{});
    if (chars_ptr == null) return;
    const s = std.mem.sliceTo(chars_ptr, 0);
    if (s.len == 0) return;
    if (s.len == 1 and s[0] < 0x20) return;

    const room = app.g.log_filter.query_buf.len - app.g.log_filter.query_len;
    const take = @min(s.len, room);
    @memcpy(
        app.g.log_filter.query_buf[app.g.log_filter.query_len .. app.g.log_filter.query_len + take],
        s[0..take],
    );
    app.g.log_filter.query_len += take;
    applyToLogView();
    refresh();
}

fn exitMode() void {
    app.g.log_filter.mode = false;
    refresh();
    // Re-anchor first responder on the terminal view. AppKit
    // sometimes shuffles responder state when modal overlays come
    // and go.
    if (app.g.term.view_id) |tid| {
        const term = objc.Object.fromId(tid);
        const window = term.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{term});
        }
    }
}

fn applyToLogView() void {
    const lv = app.g.agent.log_view orelse return;
    const state = app.g.agent.state orelse return;
    lv.setFilter(app.g.log_filter.query_buf[0..app.g.log_filter.query_len], state);
}

/// Build the chip NSTextField on first open. Subsequent opens
/// just toggle `mode` + refresh — the chip persists across
/// open/close cycles so the live filter can be re-engaged
/// without rebuilding the view.
fn ensureChip() void {
    if (app.g.log_filter.field_id != null) return;
    const container_id = app.g.layout.container_id orelse return;
    const container = objc.Object.fromId(container_id);

    const NSTextField = objc.getClass("NSTextField") orelse return;
    const NSColor = objc.getClass("NSColor") orelse return;
    const style = app.g.theme.chrome_style orelse return;
    const ChipCellClass = objc.getClass("DjinnChipCell") orelse return;

    const tf_alloc = NSTextField.msgSend(objc.Object, "alloc", .{});
    const tf_h: f64 = 24;
    const tf_init_w: f64 = 120;
    const tf = tf_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = tf_init_w, .height = tf_h },
    }});
    const cell_alloc = ChipCellClass.msgSend(objc.Object, "alloc", .{});
    const cell = cell_alloc.msgSend(objc.Object, "init", .{});
    tf.msgSend(void, "setCell:", .{cell});
    tf.msgSend(void, "setBezeled:", .{@as(c_int, 0)});
    tf.msgSend(void, "setEditable:", .{@as(c_int, 0)});
    tf.msgSend(void, "setSelectable:", .{@as(c_int, 0)});
    tf.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
    tf.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    tf.msgSend(void, "setBackgroundColor:", .{chrome.nsColorFromRgb(NSColor, style.chip.bg)});
    tf.msgSend(void, "setTextColor:", .{chrome.nsColorFromRgb(NSColor, style.chip.fg)});
    tf.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    const layer = tf.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        layer.msgSend(void, "setCornerRadius:", .{@as(f64, 4)});
        layer.msgSend(void, "setMasksToBounds:", .{@as(c_int, 1)});
        layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1)});
        const border = chrome.nsColorFromRgb(NSColor, style.chip.border);
        layer.msgSend(void, "setBorderColor:", .{border.msgSend(?*anyopaque, "CGColor", .{})});
    }
    // NSViewMinXMargin (1) + NSViewMinYMargin (32) — pinned to
    // top-right under live resize. Stacked below the find chip's
    // home position so the two never overlap when both are visible.
    tf.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 | 32)});
    container.msgSend(void, "addSubview:", .{tf});
    app.g.log_filter.field_id = tf.value;
}

/// Repaint the chip. Hides when neither mode is active nor a
/// non-empty needle is held — the chip is both the input surface
/// and the "filter on" indicator, so visibility tracks both.
fn refresh() void {
    const fid = app.g.log_filter.field_id orelse return;
    const tf = objc.Object.fromId(fid);

    const needle = app.g.log_filter.query_buf[0..app.g.log_filter.query_len];
    const visible = app.g.log_filter.mode or needle.len > 0;
    if (!visible) {
        tf.msgSend(void, "setHidden:", .{@as(c_int, 1)});
        return;
    }

    // "log: <needle>" — the leading colon doubles as the cursor
    // proxy when the chip is in input mode with no needle yet.
    var buf: [256]u8 = undefined;
    const prefix = "log: ";
    @memcpy(buf[0..prefix.len], prefix);
    const room = buf.len - prefix.len - 1;
    const take = @min(needle.len, room);
    @memcpy(buf[prefix.len .. prefix.len + take], needle[0..take]);
    buf[prefix.len + take] = 0;

    const NSString = objc.getClass("NSString") orelse return;
    const text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, &buf)});
    if (text.value == null) return;
    tf.msgSend(void, "setStringValue:", .{text});

    // Auto-size width to text + padding; anchor below the find
    // chip's home position so both chips can be visible together.
    const tf_h: f64 = 24;
    const margin: f64 = 14;
    const find_chip_offset_y: f64 = tf_h + margin + 4;
    const text_size = text.msgSend(NSSize, "size", .{});
    const pad_x: f64 = 32;
    const new_w = @ceil(text_size.width) + pad_x;
    const container_id = app.g.layout.container_id orelse return;
    const container = objc.Object.fromId(container_id);
    const c_frame = container.msgSend(NSRect, "frame", .{});
    tf.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{
            .x = c_frame.size.width - new_w - margin,
            .y = c_frame.size.height - find_chip_offset_y - tf_h - margin,
        },
        .size = .{ .width = new_w, .height = tf_h },
    }});
    tf.msgSend(void, "setHidden:", .{@as(c_int, 0)});
}

/// Re-skin the chip after a theme reload. Called from
/// `terminal/view.zig:reapplyTheme` alongside the find chip's reskin.
pub fn applyStyle(style: chrome.Style) void {
    const fid = app.g.log_filter.field_id orelse return;
    const tf = objc.Object.fromId(fid);
    const NSColor = objc.getClass("NSColor") orelse return;
    tf.msgSend(void, "setBackgroundColor:", .{chrome.nsColorFromRgb(NSColor, style.chip.bg)});
    tf.msgSend(void, "setTextColor:", .{chrome.nsColorFromRgb(NSColor, style.chip.fg)});
    const layer = tf.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        const border = chrome.nsColorFromRgb(NSColor, style.chip.border);
        layer.msgSend(void, "setBorderColor:", .{border.msgSend(?*anyopaque, "CGColor", .{})});
    }
}
