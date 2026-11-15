//! Static-session surface ownership. All entry points run on the main thread.
const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const runtime = @import("runtime.zig");
const Session = @import("../session/manager.zig").Session;
const tab_strip = @import("../session/tab_strip.zig");
const c_dispatch = @import("darwin-c");
extern "c" fn dispatch_async_f(queue: ?*anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

/// A deferred request belongs to one incarnation, never to the active tab.
pub const Ticket = struct {
    session_id: u64,
    generation: u64,

    pub fn matches(self: Ticket, session: *const Session) bool {
        return self.session_id == session.id and self.generation == session.surface_generation;
    }
};

fn findSession(id: u64) ?*Session {
    const sm = app.g.session_manager orelse return null;
    for (sm.sessions.items) |*session| {
        if (session.id == id) return session;
    }
    return null;
}

fn refresh() void {
    tab_strip.refresh();
    if (app.g.menubar) |mb| mb.refresh();
}

const InitialSurfaceState = struct { focused: bool, visible: bool };

fn initialSurfaceState(active: bool, visible: bool, key: bool) InitialSurfaceState {
    return .{ .focused = active and visible and key, .visible = active and visible };
}

/// A failed explicit cwd must be visible even for lazy/restart launches with
/// no terminal yet. Never let Ghostty silently choose a different directory.
fn reportLaunchFailure(session: *const Session, err: anyerror) void {
    var buffer: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Cannot start profile '{s}': working directory '{s}' is unavailable ({s}). Restore it or fix the profile, then retry.", .{
        session.profile.name, session.profile.cwd orelse "", @errorName(err),
    }) catch "Cannot start terminal: the configured working directory is unavailable. Fix the profile and retry.";
    std.debug.print("djinn: {s}\n", .{message});
    const NSString = objc.getClass("NSString") orelse return;
    const NSAlert = objc.getClass("NSAlert") orelse return;
    const text = NSString.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithBytes:length:encoding:", .{ message.ptr, @as(c_ulong, message.len), @as(c_ulong, 4) });
    if (text.value == null) return;
    defer text.msgSend(void, "release", .{});
    const alert = NSAlert.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    if (alert.value == null) return;
    defer alert.msgSend(void, "release", .{});
    alert.msgSend(void, "setMessageText:", .{text});
    _ = alert.msgSend(c_long, "runModal", .{});
}

/// Session-owned C strings remain valid through surface destruction.
pub fn bindGhosttySurface(allocator: std.mem.Allocator, ga: *runtime.App, host: objc.Object, session: *Session) ?runtime.c.ghostty_surface_t {
    session.validateLaunch() catch |err| {
        reportLaunchFailure(session, err);
        return null;
    };
    std.debug.assert(session.surface == null);
    runtime.releaseSessionInput(session);
    session.terminal_title_len = 0;
    const command = if (session.profile.command) |cmd| allocator.dupeSentinel(u8, cmd, 0) catch return null else null;
    const cwd = if (session.profile.cwd) |dir| allocator.dupeSentinel(u8, dir, 0) catch {
        if (command) |s| allocator.free(s);
        return null;
    } else null;
    const window = host.msgSend(objc.Object, "window", .{});
    const scale: f64 = if (window.value != null) window.msgSend(f64, "backingScaleFactor", .{}) else 1.0;
    session.surface_generation +%= 1;
    const surface = ga.newSurface(host.value, scale, if (command) |s| s.ptr else null, if (cwd) |s| s.ptr else null, session) orelse {
        if (command) |s| allocator.free(s);
        if (cwd) |s| allocator.free(s);
        session.terminal_title_len = 0;
        return null;
    };
    session.command_z = command;
    session.cwd_z = cwd;
    session.surface = @ptrCast(surface);
    session.spawned = true;
    session.exited = false;
    // Ghostty starts surfaces focused. Reset EVERY incarnation first, including
    // the initial hidden binding and inactive surfaces created before switching.
    runtime.surfaceSetFocus(surface, false);
    runtime.surfaceSetOcclusion(surface, false);
    const active = if (app.g.session_manager) |sm| sm.active() == session else false;
    const state = if (app.g.window.panel) |panel|
        initialSurfaceState(active, panel.visible, panel.ns_panel.msgSend(bool, "isKeyWindow", .{}))
    else
        initialSurfaceState(active, false, false);
    runtime.surfaceSetOcclusion(surface, state.visible);
    runtime.surfaceSetFocus(surface, state.focused);
    const bounds = host.msgSend(NSRect, "bounds", .{});
    runtime.surfaceSetContentScale(surface, scale);
    runtime.surfaceSetSize(surface, @intFromFloat(@max(1.0, bounds.size.width * scale)), @intFromFloat(@max(1.0, bounds.size.height * scale)));
    return surface;
}

pub fn destroySession(session: *Session) void {
    if (app.g.session_manager) |sm| {
        if (sm.active().id == session.id) @import("../terminal/find.zig").endSearch();
    }
    // Balance host-owned Secure Input / cursor hide before removing the source.
    runtime.releaseSessionInput(session);
    // Invalidate deferred requests and clear lookup BEFORE destruction callbacks.
    session.surface_generation +%= 1;
    const surface = session.surface;
    session.surface = null;
    session.spawned = false;
    session.exited = false;
    session.terminal_title_len = 0;
    if (surface) |sp| {
        if (app.g.ghostty.surface == sp) app.g.ghostty.surface = null;
        if (app.g.ghostty.app) |ga| ga.surfaceFree(@ptrCast(sp));
    }
    if (app.g.allocator) |allocator| {
        if (session.command_z) |s| allocator.free(s);
        if (session.cwd_z) |s| allocator.free(s);
    }
    session.command_z = null;
    session.cwd_z = null;
}

/// Called on show as well as selection: a closed profile is still selectable.
pub fn ensureActiveSession() bool {
    const sm = app.g.session_manager orelse return false;
    const session = sm.active();
    if (session.surface == null) {
        const ga = app.g.ghostty.app orelse return false;
        const allocator = app.g.allocator orelse return false;
        const host = objc.Object.fromId(session.surface_host orelse return false);
        _ = bindGhosttySurface(allocator, ga, host, session) orelse {
            std.debug.print("djinn: cannot start profile '{s}'\n", .{session.profile.name});
            return false;
        };
    }
    app.g.ghostty.surface = session.surface;
    app.g.layout.surface_host_id = @ptrCast(@alignCast(session.surface_host));
    if (session.surface_host) |host| objc.Object.fromId(host).msgSend(void, "setHidden:", .{@as(c_int, 0)});
    return true;
}

pub fn activateSession(idx: usize) bool {
    const sm = app.g.session_manager orelse return false;
    if (idx >= sm.sessions.items.len) return false;
    const previous = sm.active_idx;
    if (idx != previous) {
        // Spawn before switching so a failure leaves the old session usable.
        const target = &sm.sessions.items[idx];
        if (target.surface == null) {
            const ga = app.g.ghostty.app orelse return false;
            const allocator = app.g.allocator orelse return false;
            const host = objc.Object.fromId(target.surface_host orelse return false);
            _ = bindGhosttySurface(allocator, ga, host, target) orelse return false;
        }
        @import("../terminal/find.zig").endSearch();
        const old = sm.active();
        if (old.surface) |sp| {
            runtime.surfaceSetFocus(@ptrCast(sp), false);
            runtime.surfaceSetOcclusion(@ptrCast(sp), false);
        }
        if (old.surface_host) |host| objc.Object.fromId(host).msgSend(void, "setHidden:", .{@as(c_int, 1)});
        _ = sm.switchTo(idx);
    }
    if (!ensureActiveSession()) return false;
    const current = sm.active();
    if (current.surface_host) |host| objc.Object.fromId(host).msgSend(void, "setHidden:", .{@as(c_int, 0)});
    const visible = if (app.g.window.panel) |p| p.visible else false;
    const focused = if (app.g.window.panel) |p| visible and p.ns_panel.msgSend(bool, "isKeyWindow", .{}) else false;
    runtime.surfaceSetFocus(@ptrCast(current.surface.?), focused);
    runtime.surfaceSetOcclusion(@ptrCast(current.surface.?), visible);
    applyProfileWindowSize(current.profile.name);
    @import("../terminal/view.zig").syncResize();
    if (app.g.term.view_id) |vid| {
        if (app.g.window.panel) |p| _ = p.ns_panel.msgSend(c_int, "makeFirstResponder:", .{objc.Object.fromId(vid)});
    }
    refresh();
    return true;
}

pub fn closeActiveSession() void {
    const sm = app.g.session_manager orelse return;
    destroySession(sm.active());
    if (app.g.window.panel) |p| p.hide();
    refresh();
}

pub fn restartActiveSession(_: ?[]const u8) void {
    const sm = app.g.session_manager orelse return;
    const allocator = app.g.allocator orelse return;
    const context = allocator.create(Ticket) catch return;
    const session = sm.active();
    destroySession(session);
    context.* = .{ .session_id = session.id, .generation = session.surface_generation };
    dispatch_async_f(@ptrCast(c_dispatch.dispatch_get_main_queue()), context, &restartCallback);
}

fn restartCallback(raw: ?*anyopaque) callconv(.c) void {
    const ticket: *Ticket = @ptrCast(@alignCast(raw orelse return));
    const allocator = app.g.allocator orelse return;
    defer allocator.destroy(ticket);
    const session = findSession(ticket.session_id) orelse return;
    if (!ticket.matches(session) or session.surface != null) return;
    const ga = app.g.ghostty.app orelse return;
    const host = objc.Object.fromId(session.surface_host orelse return);
    _ = bindGhosttySurface(allocator, ga, host, session) orelse return;
    const sm = app.g.session_manager orelse return;
    if (sm.active().id == session.id) _ = activateSession(sm.active_idx);
    refresh();
}

/// Close callbacks are deferred to avoid freeing a surface inside its callback.
pub fn closeRequested(ticket: Ticket) void {
    const session = findSession(ticket.session_id) orelse return;
    if (!ticket.matches(session)) return;
    const sm = app.g.session_manager orelse return;
    const is_active = sm.active().id == session.id;
    destroySession(session);
    if (is_active) {
        if (app.g.window.panel) |p| p.hide();
    }
    refresh();
}

fn applyProfileWindowSize(name: []const u8) void {
    const cfg = app.g.config orelse return;
    if (cfg.window.width != null and cfg.window.height != null) return;
    const allocator = app.g.allocator orelse return;
    const panel = app.g.window.panel orelse return;
    const persist = @import("../state/persist.zig");
    var state = persist.load(allocator) orelse return;
    defer state.deinit(allocator);
    const dims = state.profileSize(name) orelse return;
    panel.setSize(@floatFromInt(cfg.window.width orelse dims.w), @floatFromInt(cfg.window.height orelse dims.h));
}

test "new surfaces inherit only active visible key state, never Ghostty defaults" {
    for ([_]bool{ false, true }) |active| {
        for ([_]bool{ false, true }) |visible| {
            for ([_]bool{ false, true }) |key| {
                const state = initialSurfaceState(active, visible, key);
                try std.testing.expectEqual(active and visible, state.visible);
                try std.testing.expectEqual(active and visible and key, state.focused);
            }
        }
    }
}

test "deferred tickets preserve source identity and reject stale generations" {
    var session: Session = .{ .id = 7, .profile = .{ .name = "shell", .command = null } };
    session.surface_generation = 3;
    const ticket: Ticket = .{ .session_id = 7, .generation = 3 };
    try std.testing.expect(ticket.matches(&session));
    var other = session;
    other.id = 8;
    try std.testing.expect(!ticket.matches(&other));
    session.surface_generation += 1;
    try std.testing.expect(!ticket.matches(&session));
}
