//! Terminal-first container: surface hosts behind the native input view,
//! with an optional profile tab strip above them.

const objc = @import("objc");
const app = @import("../app.zig");
const Config = @import("../config.zig").Config;
const tab_strip = @import("../session/tab_strip.zig");

const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

pub fn buildContainer(
    width: f64,
    height: f64,
    cfg: *const Config,
    terminal: objc.Object,
    surface_host: objc.Object,
) objc.Object {
    _ = cfg;
    const NSView = objc.getClass("NSView") orelse unreachable;
    const container = NSView.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithFrame:",
        .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } }},
    );
    container.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    app.g.layout.container_id = container.value;

    var tab_h: f64 = 0;
    if (app.g.session_manager) |sm| {
        if (sm.sessions.items.len > 1) tab_h = tab_strip.tab_h;
    }
    const frame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = width, .height = @max(1.0, height - tab_h) },
    };
    // Ghostty owns the host's Metal layer. The transparent native view
    // stays above it to handle input, IME, clipboard, drag/drop, and find.
    surface_host.msgSend(void, "setFrame:", .{frame});
    surface_host.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    surface_host.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    container.msgSend(void, "addSubview:", .{surface_host});

    terminal.msgSend(void, "setFrame:", .{frame});
    terminal.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    container.msgSend(void, "addSubview:", .{terminal});

    if (tab_h > 0) {
        const strip = tab_strip.create(width, height);
        container.msgSend(void, "addSubview:", .{strip});
        app.g.layout.tab_strip_id = strip.value;
        strip.msgSend(void, "release", .{});
        if (app.g.theme.chrome_style) |style| tab_strip.applyStyle(style);
    }
    return container;
}

/// Add a Metal host below the shared input overlay. The container owns it.
pub fn attachSurfaceHost(session: *@import("../session/manager.zig").Session) void {
    if (session.surface_host != null) return;
    const view = app.g.term.view_id orelse return;
    const container = objc.Object.fromId(app.g.layout.container_id orelse return);
    const terminal = objc.Object.fromId(view);
    const frame = terminal.msgSend(NSRect, "frame", .{});
    const NSView = objc.getClass("NSView") orelse return;
    const host = NSView.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{frame});
    if (host.value == null) return;
    host.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    host.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    container.msgSend(void, "addSubview:positioned:relativeTo:", .{ host, @as(c_long, -1), terminal });
    session.surface_host = host.value;
    host.msgSend(void, "release", .{});
}

pub fn syncProfileTabs() void {
    const container = objc.Object.fromId(app.g.layout.container_id orelse return);
    const sm = app.g.session_manager orelse return;
    if (sm.count() > 1) {
        if (app.g.layout.tab_strip_id == null) {
            const bounds = container.msgSend(NSRect, "bounds", .{});
            const strip = tab_strip.create(bounds.size.width, bounds.size.height);
            container.msgSend(void, "addSubview:", .{strip});
            app.g.layout.tab_strip_id = strip.value;
            strip.msgSend(void, "release", .{});
            if (app.g.theme.chrome_style) |style| tab_strip.applyStyle(style);
        }
    } else if (app.g.layout.tab_strip_id) |id| {
        app.g.layout.tab_strip_id = null;
        app.g.layout.tab_strip_separator_id = null;
        objc.Object.fromId(id).msgSend(void, "removeFromSuperview", .{});
    }
    relayout();
}

/// Reflow all hosts, including hidden sessions. Autoresizing handles
/// ordinary view changes; window notifications also call this for hidden
/// windows and programmatic per-profile size changes.
pub fn relayout() void {
    const container_id = app.g.layout.container_id orelse return;
    const bounds = objc.Object.fromId(container_id).msgSend(NSRect, "bounds", .{});
    const tab_h: f64 = if (app.g.layout.tab_strip_id != null) tab_strip.tab_h else 0;
    const frame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @max(1.0, bounds.size.width), .height = @max(1.0, bounds.size.height - tab_h) },
    };
    if (app.g.session_manager) |sm| {
        for (sm.sessions.items) |sess| {
            if (sess.surface_host) |host| objc.Object.fromId(host).msgSend(void, "setFrame:", .{frame});
        }
    } else if (app.g.layout.surface_host_id) |host| {
        objc.Object.fromId(host).msgSend(void, "setFrame:", .{frame});
    }
    if (app.g.term.view_id) |view| objc.Object.fromId(view).msgSend(void, "setFrame:", .{frame});
    if (app.g.layout.tab_strip_id) |strip| {
        objc.Object.fromId(strip).msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = frame.size.height },
            .size = .{ .width = frame.size.width, .height = tab_h },
        }});
    }
}
