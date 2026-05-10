//! Resizable divider NSView between terminal + log pane. Subclasses
//! NSView as `DjinnDivider` to host mouseDown/Dragged/Up +
//! resetCursorRects so the user can drag-to-resize the log column.
//!
//! Drag math + responder hookup live here; the actual reflow lands in
//! `view.applyLogLayout` (shared with the log-pane toggle path).

const objc = @import("objc");
const app = @import("../app.zig");

/// Visible + grabbable width of the log/terminal divider. Wide enough
/// for a reliable mouse hit (1px is too narrow on dense displays);
/// alpha keeps the visible band reading as a hairline.
pub const width: f64 = 4.0;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

var g_class_registered: bool = false;

/// Build the resizable divider NSView between terminal + log pane.
pub fn create(term_w: f64, height: f64) objc.Object {
    registerClass();
    const cls = objc.getClass("DjinnDivider") orelse unreachable;
    const alloc = cls.msgSend(objc.Object, "alloc", .{});
    const div = alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = term_w, .y = 0 },
        .size = .{ .width = width, .height = height },
    }});
    div.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    // Divider is a transparent hit-target — the visible boundary
    // between terminal + log pane is the log pane's 1px chip.border
    // separator. Painting the divider with white@5% alpha left a
    // white-tinted fringe next to the chrome border on translucent
    // panels.
    // MinXMargin | HeightSizable — divider tracks its x relative to the
    // right edge as the panel resizes.
    div.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 0) | (1 << 4))});
    return div;
}

fn registerClass() void {
    if (g_class_registered) return;
    g_class_registered = true;
    const NSView = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(NSView, "DjinnDivider") orelse return;
    _ = cls.addMethod("mouseDown:", mouseDownImpl);
    _ = cls.addMethod("mouseDragged:", mouseDraggedImpl);
    _ = cls.addMethod("mouseUp:", mouseUpImpl);
    _ = cls.addMethod("resetCursorRects", resetCursorRectsImpl);
    _ = cls.addMethod("acceptsFirstMouse:", acceptsFirstMouseImpl);
    objc.registerClassPair(cls);
}

fn acceptsFirstMouseImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) c_int {
    // Return YES so the first click on a non-key window starts the drag
    // immediately, instead of being consumed by the window-activation
    // hit-test. Borderless NSPanel can lose key state on focus shifts.
    return 1;
}

fn mouseDownImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // No-op — `mouseDragged:` does the actual layout work each tick.
    // Implementing the selector at all is what tells AppKit we want
    // mouse events; without it the divider is transparent to clicks.
}

fn mouseUpImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // Persist the new fraction so subsequent toggles + resizes use it.
    const cfg = app.g.config orelse return;
    const lv = app.g.agent.log_view orelse return;
    const log_frame = lv.view.msgSend(NSRect, "frame", .{});
    const container = lv.view.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;
    const c_bounds = container.msgSend(NSRect, "bounds", .{});
    if (c_bounds.size.width <= 0) return;
    cfg.log_pane.width_fraction = log_frame.size.width / c_bounds.size.width;
}

fn mouseDraggedImpl(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const div = objc.Object.fromId(self);
    const container = div.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;
    const ev = objc.Object.fromId(event);
    const win_loc = ev.msgSend(NSPoint, "locationInWindow", .{});
    const cont_loc = container.msgSend(NSPoint, "convertPoint:fromView:", .{ win_loc, @as(?*anyopaque, null) });

    const c_bounds = container.msgSend(NSRect, "bounds", .{});
    const cfg = app.g.config orelse return;

    // Cursor x in container coords = the new term_w boundary. Log
    // takes whatever is right of that (minus the divider band).
    var new_log_w = c_bounds.size.width - cont_loc.x - width;
    new_log_w = @max(cfg.log_pane.width_min, @min(cfg.log_pane.width_max, new_log_w));
    const new_term_w = @max(1.0, c_bounds.size.width - new_log_w - width);
    @import("view.zig").applyLogLayout(container, new_term_w, new_log_w, c_bounds.size.height);
}

fn resetCursorRectsImpl(self: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const div = objc.Object.fromId(self);
    const NSCursor = objc.getClass("NSCursor") orelse return;
    const cursor = NSCursor.msgSend(objc.Object, "resizeLeftRightCursor", .{});
    const bounds = div.msgSend(NSRect, "bounds", .{});
    div.msgSend(void, "addCursorRect:cursor:", .{ bounds, cursor });
}
