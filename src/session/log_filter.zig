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
    // Auto-reveal the log pane. Filtering a hidden pane is a no-op
    // from the user's perspective — the chip surface shows the
    // filter state but the entries the filter would highlight are
    // off-screen. `setLogPaneHidden(false)` is idempotent so an
    // already-visible pane stays put.
    @import("../terminal/view.zig").setLogPaneHidden(false);
    app.g.log_filter.mode = true;
    ensureChip();
    ensurePills();
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

/// Called from `view.setLogPaneHidden(true)` when the pane goes
/// hidden. Clears the filter + hides the chip so the surface
/// state matches what the user can see — leaving the chip
/// visible (and the underlying filter still active) over a
/// hidden pane is a state leak the user can't dismiss without
/// reopening the pane first.
pub fn onPaneHidden() void {
    app.g.log_filter.query_len = 0;
    app.g.log_filter.mode = false;
    if (app.g.agent.log_view) |lv| {
        if (app.g.agent.state) |st| lv.clearFilter(st);
    }
    if (app.g.log_filter.field_id) |fid| {
        objc.Object.fromId(fid).msgSend(void, "setHidden:", .{@as(c_int, 1)});
    }
    if (app.g.log_filter.pill_view_id) |pid| {
        objc.Object.fromId(pid).msgSend(void, "setHidden:", .{@as(c_int, 1)});
    }
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
    // Mount on the LogView wrapper. The chip is semantically
    // associated with the log pane (it filters log entries), so
    // anchoring it inside the pane's own coord space keeps it
    // visually attached to the surface it acts on — and the find
    // chip stays where it belongs (over the terminal area).
    const lv = app.g.agent.log_view orelse return;
    const container = lv.view;

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
    // Single-line + clip line-break match the find chip exactly.
    // DjinnChipCell.drawInteriorWithFrame: only vertically centers
    // when the cell renders in single-line mode — without these
    // calls the text top-aligns because NSTextFieldCell defaults
    // to multi-line layout and the cell-centering math reads the
    // wrong text bounds.
    const tf_cell = tf.msgSend(objc.Object, "cell", .{});
    if (tf_cell.value != null) {
        tf_cell.msgSend(void, "setUsesSingleLineMode:", .{@as(c_int, 1)});
        tf_cell.msgSend(void, "setLineBreakMode:", .{@as(c_long, 4)}); // NSLineBreakByClipping
    }
    tf.msgSend(void, "setBackgroundColor:", .{chrome.nsColorFromRgb(NSColor, style.chip.bg)});
    tf.msgSend(void, "setTextColor:", .{chrome.nsColorFromRgb(NSColor, style.chip.fg)});
    // Field-level font in addition to attributed-run fonts. The
    // cell uses the field font for sizing decisions (line height,
    // baseline) even when the rendered runs carry their own font
    // attrs — without this the chip's vertical metric tracks
    // NSTextField's default system font, mismatching the find chip.
    const NSFont = objc.getClass("NSFont") orelse return;
    tf.msgSend(void, "setFont:", .{chrome.chromeFont(NSFont, style.font_family, style.font_size_chip)});
    tf.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    const layer = tf.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        layer.msgSend(void, "setCornerRadius:", .{@as(f64, 4)});
        layer.msgSend(void, "setMasksToBounds:", .{@as(c_int, 1)});
        layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1)});
        const border = chrome.nsColorFromRgb(NSColor, style.chip.border);
        layer.msgSend(void, "setBorderColor:", .{border.msgSend(?*anyopaque, "CGColor", .{})});
    }
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

    // "log: <needle>" — leading "log: " in dim, needle in chip.fg.
    // Build an NSAttributedString so DjinnChipCell's
    // drawInteriorWithFrame: (which reads attributedStringValue
    // only — plain stringValue renders without font/color attrs
    // and stays invisible against the chip bg) actually paints.
    const style = app.g.theme.chrome_style orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const NSAttributedString = objc.getClass("NSMutableAttributedString") orelse return;
    const root_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const root = root_alloc.msgSend(objc.Object, "init", .{});
    defer root.msgSend(void, "release", .{});

    // Match the find chip's typography exactly: dim label, optional
    // " · " + fg needle when present. Empty-needle keeps a bare
    // "log" — no trailing separator (the find chip doesn't have
    // one either; consistency matters more than the live-cursor
    // affordance).
    appendChipRun(root, "log", style.chip.dim, style);
    if (needle.len > 0) {
        appendChipRun(root, " · ", style.chip.dim, style);
        appendChipRun(root, needle, style.chip.fg, style);
    }
    tf.msgSend(void, "setAttributedStringValue:", .{root});

    const text_size = root.msgSend(NSSize, "size", .{});
    const tf_h: f64 = 24;
    const margin: f64 = 10;
    const pad_x: f64 = 32;
    const new_w = @ceil(text_size.width) + pad_x;

    // Anchor inside the log pane wrapper. Top-right of the pane,
    // small inset on each side. Frame in the wrapper's own coord
    // space — autoresize mask keeps it pinned as the pane resizes
    // via the splitview drag handle.
    const lv = app.g.agent.log_view orelse return;
    const w_frame = lv.view.msgSend(NSRect, "frame", .{});
    const right_x = w_frame.size.width - new_w - margin;
    const y = w_frame.size.height - tf_h - margin;
    tf.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = right_x, .y = y },
        .size = .{ .width = new_w, .height = tf_h },
    }});
    tf.msgSend(void, "setHidden:", .{@as(c_int, 0)});

    // Pill row sits flush against the chip's left edge with a small
    // gap. Repositioning each refresh keeps the pills tracking the
    // chip as its width changes with typed text.
    if (app.g.log_filter.pill_view_id) |pid| {
        const pills = objc.Object.fromId(pid);
        const pill_x = right_x - pill_row_w - 6;
        pills.msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = pill_x, .y = y },
            .size = .{ .width = pill_row_w, .height = tf_h },
        }});
        pills.msgSend(void, "setHidden:", .{@as(c_int, 0)});
        pills.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    }
    _ = NSString;
}

/// Append one styled run to the chip's attributed string. Mirrors
/// terminal/find.zig:appendFindRun — center-aligned, chrome chip
/// font, configurable color. Kept local to avoid a back-import
/// dependency on find.zig (smaller blast radius, no module
/// coupling).
fn appendChipRun(root: objc.Object, text: []const u8, color: chrome.Rgb, style: chrome.Style) void {
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

    const font = chrome.chromeFont(NSFont, style.font_family, style.font_size_chip);
    const ns_color = chrome.nsColorFromRgb(NSColor, color);

    // NSCenterTextAlignment = 2. Same horizontal-center idiom as
    // the find chip so the needle doesn't jitter as it grows.
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
    if (app.g.log_filter.pill_view_id) |pid| {
        objc.Object.fromId(pid).msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    }
}

// ─── Level pills (i/w/e click-toggle row) ────────────────────────────

/// Total width reserved for the pill strip — 3 pills × pill_w plus
/// gaps + insets. Fixed width so the chip positioning math (chip
/// shifts left as text grows) is independent of pill state.
const pill_row_w: f64 = 78;
const pill_w: f64 = 22;
const pill_h: f64 = 18;
const pill_gap: f64 = 4;
const pill_inset_x: f64 = 6;

var g_pills_class_registered: bool = false;

fn ensurePills() void {
    if (app.g.log_filter.pill_view_id != null) return;
    const lv = app.g.agent.log_view orelse return;
    const container = lv.view;

    registerPillsClass();
    const cls = objc.getClass("DjinnLevelPills") orelse return;
    const view = cls.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithFrame:",
        .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = pill_row_w, .height = 24 },
        }},
    );
    view.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    // NSViewMinXMargin (1) + NSViewMinYMargin (32) — pinned to the
    // top-right of the wrapper alongside the chip.
    view.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 | 32)});
    container.msgSend(void, "addSubview:", .{view});
    app.g.log_filter.pill_view_id = view.value;
}

fn registerPillsClass() void {
    if (g_pills_class_registered) return;
    g_pills_class_registered = true;
    const NSView = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(NSView, "DjinnLevelPills") orelse return;
    _ = cls.addMethod("drawRect:", pillsDrawRectImpl);
    _ = cls.addMethod("mouseDown:", pillsMouseDownImpl);
    _ = cls.addMethod("isFlipped", pillsIsFlippedImpl);
    _ = cls.addMethod("acceptsFirstMouse:", pillsAcceptsFirstMouseImpl);
    objc.registerClassPair(cls);
}

fn pillsIsFlippedImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn pillsAcceptsFirstMouseImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) c_int {
    // YES so a click on a non-key panel toggles the pill immediately
    // instead of being consumed by the window-activation hit-test.
    return 1;
}

fn pillRect(idx: usize) NSRect {
    const x = pill_inset_x + @as(f64, @floatFromInt(idx)) * (pill_w + pill_gap);
    return .{
        .origin = .{ .x = x, .y = 3 },
        .size = .{ .width = pill_w, .height = pill_h },
    };
}

fn pillsDrawRectImpl(self_id: objc.c.id, _: objc.c.SEL, _: NSRect) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    const style = app.g.theme.chrome_style orelse return;
    const lv = app.g.agent.log_view orelse return;
    const mask: u3 = lv.filter_spec.level_mask;

    const NSColor = objc.getClass("NSColor") orelse return;
    const NSBezierPath = objc.getClass("NSBezierPath") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSMutableDictionary = objc.getClass("NSMutableDictionary") orelse return;

    // Backdrop: chip.bg + 1px chip.border so the row reads as a single
    // chip alongside the free-text chip. Matches the find/log chip
    // visual idiom (lifted bg + 1px outline).
    const bounds = view.msgSend(NSRect, "bounds", .{});
    const chip_bg = chrome.nsColorFromRgb(NSColor, style.chip.bg);
    chip_bg.msgSend(void, "set", .{});
    const bg_path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
        bounds,
        @as(f64, 4),
        @as(f64, 4),
    });
    bg_path.msgSend(void, "fill", .{});
    const border_color = chrome.nsColorFromRgb(NSColor, style.chip.border);
    border_color.msgSend(void, "set", .{});
    bg_path.msgSend(void, "setLineWidth:", .{@as(f64, 1)});
    bg_path.msgSend(void, "stroke", .{});

    const font = chrome.chromeFont(NSFont, style.font_family, style.font_size_chip);
    const font_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSFont")});
    const fg_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSColor")});

    const Pill = struct { letter: [:0]const u8, accent: chrome.Rgb, bit: u3 };
    const pills = [_]Pill{
        .{ .letter = "i", .accent = style.info, .bit = 0b001 },
        .{ .letter = "w", .accent = style.warn, .bit = 0b010 },
        .{ .letter = "e", .accent = style.err, .bit = 0b100 },
    };

    inline for (pills, 0..) |p, i| {
        const rect = pillRect(i);
        const on = (mask & p.bit) != 0;

        // Active: filled at the level's accent color. Inactive: empty
        // with a dim outline. The accent tracks chrome.Style so theme
        // flips re-skin the pills via setNeedsDisplay.
        if (on) {
            const fill = chrome.nsColorFromRgb(NSColor, p.accent);
            fill.msgSend(void, "set", .{});
            const path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
                rect,
                @as(f64, 3),
                @as(f64, 3),
            });
            path.msgSend(void, "fill", .{});
        } else {
            const dim_border = chrome.nsColorFromRgb(NSColor, style.chip.dim);
            dim_border.msgSend(void, "set", .{});
            const path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
                rect,
                @as(f64, 3),
                @as(f64, 3),
            });
            path.msgSend(void, "setLineWidth:", .{@as(f64, 1)});
            path.msgSend(void, "stroke", .{});
        }

        // Letter inside the pill. Active uses chip.bg (high contrast
        // against the filled accent); inactive uses chip.dim (matches
        // the empty pill's outline tone).
        const letter_color = chrome.nsColorFromRgb(NSColor, if (on) style.chip.bg else style.chip.dim);
        const attrs = NSMutableDictionary.msgSend(objc.Object, "dictionaryWithCapacity:", .{@as(c_ulong, 2)});
        attrs.msgSend(void, "setObject:forKey:", .{ font, font_key });
        attrs.msgSend(void, "setObject:forKey:", .{ letter_color, fg_key });
        const text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, p.letter.ptr)});
        const text_size = text.msgSend(NSSize, "sizeWithAttributes:", .{attrs});
        const text_x = rect.origin.x + (rect.size.width - text_size.width) / 2.0;
        const text_y = rect.origin.y + (rect.size.height - text_size.height) / 2.0;
        text.msgSend(void, "drawAtPoint:withAttributes:", .{ NSPoint{ .x = text_x, .y = text_y }, attrs });
    }
}

fn pillsMouseDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    const event = objc.Object.fromId(event_id);
    const lv = app.g.agent.log_view orelse return;
    const state = app.g.agent.state orelse return;

    const win_pt = event.msgSend(NSPoint, "locationInWindow", .{});
    const local = view.msgSend(NSPoint, "convertPoint:fromView:", .{ win_pt, @as(?*anyopaque, null) });

    // Hit-test each pill rect — first hit wins. Empty space inside
    // the row is intentionally inert so a stray click between pills
    // doesn't flip an adjacent level.
    var hit_bit: ?u3 = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const r = pillRect(i);
        if (local.x >= r.origin.x and local.x < r.origin.x + r.size.width and
            local.y >= r.origin.y and local.y < r.origin.y + r.size.height)
        {
            hit_bit = @intCast(@as(u8, 1) << @intCast(i));
            break;
        }
    }
    const bit = hit_bit orelse return;

    const old_mask = lv.filter_spec.level_mask;
    const new_mask: u3 = old_mask ^ bit;
    // Refuse to leave the row with every pill off — `parseLevelMask`
    // falls back to all-on for an empty/unrecognized value, so a
    // mask=0 needle would round-trip back to mask=0b111 and the
    // displayed pill state would whiplash from "one on" to "three on"
    // on a single click. Treat the click as a no-op instead.
    if (new_mask == 0) return;
    // Single-source-of-truth: rewrite the chip needle's `level:`
    // portion so `parseFilterSpec` re-derives the same mask on the
    // next text edit. Avoids a divergent "pill says X, prefix says Y"
    // state that's hard to reason about.
    var new_needle_buf: [128]u8 = undefined;
    const new_len = composeNeedle(
        &new_needle_buf,
        new_mask,
        lv.filter_spec.client_buf[0..lv.filter_spec.client_len],
        lv.filter_spec.text_buf[0..lv.filter_spec.text_len],
    );
    @memcpy(app.g.log_filter.query_buf[0..new_len], new_needle_buf[0..new_len]);
    app.g.log_filter.query_len = new_len;
    lv.setFilter(app.g.log_filter.query_buf[0..new_len], state);

    refresh();
}

/// Reverse of `parseFilterSpec` — emit `level:X client:Y free text`
/// for the given parts. Omits the `level:` token entirely when the
/// mask is `0b111` (no-filter) so a freshly-cleared filter doesn't
/// leave dead syntax behind in the chip.
fn composeNeedle(buf: []u8, mask: u3, client: []const u8, text: []const u8) usize {
    var pos: usize = 0;
    const writeStr = struct {
        fn call(b: []u8, p: *usize, s: []const u8) void {
            const room = b.len - p.*;
            const n = @min(s.len, room);
            @memcpy(b[p.*..][0..n], s[0..n]);
            p.* += n;
        }
    }.call;

    if (mask != 0b111) {
        writeStr(buf, &pos, "level:");
        var first = true;
        if (mask & 0b001 != 0) {
            writeStr(buf, &pos, "info");
            first = false;
        }
        if (mask & 0b010 != 0) {
            if (!first) writeStr(buf, &pos, ",");
            writeStr(buf, &pos, "warn");
            first = false;
        }
        if (mask & 0b100 != 0) {
            if (!first) writeStr(buf, &pos, ",");
            writeStr(buf, &pos, "err");
            first = false;
        }
        // mask == 0 is unreachable through the pill UI (mouseDown
        // guards against the all-off transition). Defensive: emit a
        // bogus token so parseFilterSpec's unrecognized-fallback
        // pulls the mask back to all-on if some other code path
        // hands us mask=0.
        if (first) writeStr(buf, &pos, "none");
    }
    if (client.len > 0) {
        if (pos > 0) writeStr(buf, &pos, " ");
        writeStr(buf, &pos, "client:");
        writeStr(buf, &pos, client);
    }
    if (text.len > 0) {
        if (pos > 0) writeStr(buf, &pos, " ");
        writeStr(buf, &pos, text);
    }
    return pos;
}
