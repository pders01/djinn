//! Tab strip for multi-profile sessions.
//!
//! Thin row of profile name "chips" anchored above the terminal/log
//! area. Reads the session manager for names + active index, paints
//! each tab inline (no per-tab NSView), routes mouseDown to
//! `activateSession(idx)`. Hidden / not added when sessions.len < 2.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const chrome = @import("../chrome.zig");

/// Strip height in points. Matches the find chip's 24pt height so
/// every floating chrome surface sits on the same vertical metric.
pub const tab_h: f64 = 24;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// Build a `DjinnTabStrip` NSView at the requested frame. Caller adds
/// it as a subview of the panel content view + reflows the rest of
/// the layout to leave `tab_h` clear at the top.
pub fn create(width: f64, container_h: f64) objc.Object {
    registerClass();
    const cls = objc.getClass("DjinnTabStrip") orelse unreachable;
    const view = cls.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithFrame:",
        .{NSRect{
            .origin = .{ .x = 0, .y = container_h - tab_h },
            .size = .{ .width = width, .height = tab_h },
        }},
    );
    // Pin to the top of the container; AppKit anchors via
    // NSViewMinYMargin (1<<5) + NSViewWidthSizable (1<<1).
    view.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 5))});
    view.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});

    // Bottom hairline as a CALayer-backed subview pinned to the
    // bottom edge. Same construction as `LogView`'s left separator
    // so both surfaces' borders render through identical paint paths
    // — sharp 1px on @1x, 2 device pixels on @2x, no antialias drift
    // from `NSBezierPath.fillRect` rounding.
    const NSView = objc.getClass("NSView") orelse return view;
    const sep_alloc = NSView.msgSend(objc.Object, "alloc", .{});
    const sep = sep_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = width, .height = 1 },
    }});
    sep.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    // NSViewWidthSizable (1<<1) + NSViewMaxYMargin (1<<5) — pinned
    // to the bottom edge under live resize. drawRect's `isFlipped`
    // doesn't affect autoresizing math; that uses parent-relative
    // bottom-up coords.
    sep.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 << 1)});
    app.g.tab_strip_separator_id = sep.value;
    view.msgSend(void, "addSubview:", .{sep});

    return view;
}

/// Re-skin the bottom hairline. Called from `reapplyTheme` so the
/// strip's border tracks chip.border across appearance flips.
pub fn applyStyle(style: chrome.Style) void {
    const sid = app.g.tab_strip_separator_id orelse return;
    const NSColor = objc.getClass("NSColor") orelse return;
    const sep = objc.Object.fromId(sid);
    const sep_layer = sep.msgSend(objc.Object, "layer", .{});
    if (sep_layer.value != null) {
        const ns = chrome.nsColorFromRgb(NSColor, style.chip.border);
        sep_layer.msgSend(void, "setBackgroundColor:", .{ns.msgSend(?*anyopaque, "CGColor", .{})});
    }
    refresh();
}

/// Schedule a redraw — call after the active index changes so the
/// highlight follows the tab switch.
pub fn refresh() void {
    const id = app.g.tab_strip_id orelse return;
    objc.Object.fromId(id).msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
}

var g_class_registered: bool = false;

fn registerClass() void {
    if (g_class_registered) return;
    g_class_registered = true;
    const NSView = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(NSView, "DjinnTabStrip") orelse return;
    _ = cls.addMethod("drawRect:", drawRectImpl);
    _ = cls.addMethod("mouseDown:", mouseDownImpl);
    _ = cls.addMethod("isFlipped", isFlippedImpl);
    objc.registerClassPair(cls);
}

/// Top-down origin so x grows right, y grows down — matches the
/// rectangle math used in drawRectImpl. AppKit's default is
/// bottom-left which complicates per-tab x layout reasoning.
fn isFlippedImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn drawRectImpl(self_id: objc.c.id, _: objc.c.SEL, _: NSRect) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    const bounds = view.msgSend(NSRect, "bounds", .{});
    const style = app.g.chrome_style orelse return;
    const sm = app.g.session_manager orelse return;
    if (sm.sessions.items.len < 2) return;

    const NSColor = objc.getClass("NSColor") orelse return;
    const NSBezierPath = objc.getClass("NSBezierPath") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSDictionary = objc.getClass("NSDictionary") orelse return;
    const NSMutableDictionary = objc.getClass("NSMutableDictionary") orelse return;

    // Strip background: terminal bg, same as the surface below.
    // The strip recedes into the panel surface; the only chrome
    // affordance left is the label color contrast (fg vs chip.dim)
    // and the bottom hairline marking the strip/surface boundary.
    const bg = chrome.nsColorFromRgb(NSColor, style.bg);
    bg.msgSend(void, "set", .{});
    NSBezierPath.msgSend(void, "fillRect:", .{bounds});

    const tab_count: f64 = @floatFromInt(sm.sessions.items.len);
    const tab_w = bounds.size.width / tab_count;

    const font = chrome.chromeFont(NSFont, style.font_family, style.font_size_chip);
    const font_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSFont")});
    const fg_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSColor")});

    // Minimal indicator: shared chip.bg for the whole strip; active
    // vs inactive carried entirely by label color (fg vs chip.dim).
    // No fills, no underlines — the strip recedes into chrome and
    // the active tab reads via contrast alone. Same idiom as the log
    // pane's per-entry header (`{client} · HH:MM` in dim, body in fg).
    for (sm.sessions.items, 0..) |sess, i| {
        const x = @as(f64, @floatFromInt(i)) * tab_w;
        const is_active = i == sm.active_idx;

        const text_color = chrome.nsColorFromRgb(NSColor, if (is_active) style.fg else style.chip.dim);
        const attrs = NSMutableDictionary.msgSend(objc.Object, "dictionaryWithCapacity:", .{@as(c_ulong, 2)});
        attrs.msgSend(void, "setObject:forKey:", .{ font, font_key });
        attrs.msgSend(void, "setObject:forKey:", .{ text_color, fg_key });

        const label = sess.profile.label();
        var name_buf: [128]u8 = undefined;
        const z_label = std.fmt.bufPrintZ(&name_buf, "{s}", .{label}) catch continue;
        const ns_label = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, z_label.ptr)});

        const text_size = ns_label.msgSend(NSSize, "sizeWithAttributes:", .{attrs});
        // Left-align the label inside its tab cell with a fixed
        // horizontal inset. Center alignment shifted labels around as
        // active/inactive flipped fonts; left-align reads as a stable
        // anchor — same idiom as Safari's tab bar.
        const tab_pad: f64 = 12;
        const text_x = x + tab_pad;
        const text_y = (bounds.size.height - text_size.height) / 2.0;
        ns_label.msgSend(void, "drawAtPoint:withAttributes:", .{ NSPoint{ .x = text_x, .y = text_y }, attrs });

        _ = NSDictionary; // keep import live for future attribute dicts
    }

    // Bottom hairline is a CALayer-backed subview created in
    // `create()` so it shares the log pane's separator paint path.
    // Color is set on applyStyle + refreshed on theme reload.
}

fn mouseDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const sm = app.g.session_manager orelse return;
    if (sm.sessions.items.len < 2) return;

    const view = objc.Object.fromId(self_id);
    const event = objc.Object.fromId(event_id);
    const win_pt = event.msgSend(NSPoint, "locationInWindow", .{});
    const local = view.msgSend(NSPoint, "convertPoint:fromView:", .{ win_pt, @as(?*anyopaque, null) });
    const bounds = view.msgSend(NSRect, "bounds", .{});

    const tab_count: f64 = @floatFromInt(sm.sessions.items.len);
    const tab_w = bounds.size.width / tab_count;
    const idx_f = local.x / tab_w;
    if (idx_f < 0) return;
    const idx: usize = @intFromFloat(@floor(idx_f));
    if (idx >= sm.sessions.items.len) return;
    if (idx == sm.active_idx) return;

    // Re-route through main.zig's activateSession so the surface
    // swap, focus push, and menubar refresh all run.
    const main_mod = @import("../main.zig");
    _ = main_mod.activateSession(idx);
}
