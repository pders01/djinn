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

    var stack: [257]u8 = undefined;
    const take = @min(text.len, stack.len - 1);
    @memcpy(stack[0..take], text[0..take]);
    stack[take] = 0;
    const ns_text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, &stack)});

    const font = chrome_mod.chromeFont(NSFont, style.font_family, style.font_size_chip);
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
    const objects = [_]objc.c.id{ ns_color.value, font.value, para.value };
    const keys = [_]objc.c.id{ fg_key.value, font_key.value, para_key.value };
    const dict = NSDictionary.msgSend(
        objc.Object,
        "dictionaryWithObjects:forKeys:count:",
        .{ &objects, &keys, @as(c_ulong, 3) },
    );

    const attr_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const attr = attr_alloc.msgSend(objc.Object, "initWithString:attributes:", .{ ns_text, dict });
    defer attr.msgSend(void, "release", .{});
    root.msgSend(void, "appendAttributedString:", .{attr});
}

/// Set the NSFont on the find-overlay textfield. Bare-string fallback
/// before updateCountLabel pushes the styled attributed value.
fn applyFindOverlayFont(tf: objc.Object, style: chrome_mod.Style) void {
    const NSFont = objc.getClass("NSFont") orelse return;
    tf.msgSend(void, "setFont:", .{chrome_mod.chromeFont(NSFont, style.font_family, style.font_size_chip)});
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
    forwardBindingAction(buf[0 .. prefix.len + n]);
    app.g.find.total = null;
    app.g.find.selected = null;
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

fn exitMode(end_search: bool) void {
    if (!app.g.find.mode) return;
    app.g.find.mode = false;
    app.g.find.query_len = 0;
    app.g.find.total = null;
    app.g.find.selected = null;
    updateCountLabel();
    if (end_search) {
        // end_search calls Search.deinit which joins the search thread.
        // The thread's defer-block fires `.quit` via the event callback,
        // which surface routes through its mailbox to clear renderer
        // highlights. So this single call covers both teardown + clear.
        forwardBindingAction("end_search");
    }
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
    if (!app.g.find.mode) return;
    app.g.find.mode = false;
    app.g.find.query_len = 0;
    app.g.find.total = null;
    app.g.find.selected = null;
    updateCountLabel();
}

/// Public UI-sync entry point for ghostty's start_search action.
pub fn openOverlayUiOnly() void {
    if (app.g.find.mode) return;
    app.g.find.mode = true;
    app.g.find.query_len = 0;
    updateCountLabel();
}

pub fn actionOpen() void {
    if (app.g.find.mode) {
        exitMode(true);
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
        exitMode(true);
        return;
    }
    // Backspace — shrink needle. Re-pushes (empty needle stops search
    // per ghostty semantics, but UI stays in find mode).
    if (keycode == 51) {
        if (app.g.find.query_len > 0) {
            app.g.find.query_len -= 1;
            pushNeedle();
        }
        return;
    }
    // Append printable text from event.characters.
    const chars_obj = event.msgSend(objc.Object, "characters", .{});
    if (chars_obj.value == null) return;
    const chars_ptr = chars_obj.msgSend([*c]const u8, "UTF8String", .{});
    if (chars_ptr == null) return;
    const s = std.mem.sliceTo(chars_ptr, 0);
    if (s.len == 0) return;
    // Skip control chars (< 0x20) — covers Tab, Ctrl combos that AppKit
    // delivers via characters even when not intended as text.
    if (s.len == 1 and s[0] < 0x20) return;
    const room = app.g.find.query_buf.len - app.g.find.query_len;
    const take = @min(s.len, room);
    @memcpy(app.g.find.query_buf[app.g.find.query_len .. app.g.find.query_len + take], s[0..take]);
    app.g.find.query_len += take;
    pushNeedle();
}

pub fn actionNext() void {
    forwardBindingAction("navigate_search:next");
}

pub fn actionPrev() void {
    forwardBindingAction("navigate_search:previous");
}
