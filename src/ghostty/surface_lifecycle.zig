//! Per-session ghostty surface lifecycle: bind / activate / restart.
//!
//! `bindGhosttySurface` calls into libghostty to create + foreground
//! a surface attached to a host NSView. `activateSession` flips the
//! visible session, lazy-spawning the surface on first activate.
//! `restartActiveSession` re-spawns the active session's child
//! process via a one-runloop-turn deferred re-bind so ghostty's IO
//! mailbox can unwind between surface_free + newSurface.
//!
//! Cocoa-bound: every entry point dispatches NSView messages on the
//! main thread. Reads `app.g.ghostty.app`, `app.g.session_manager`,
//! `app.g.allocator`, `app.g.layout.*`, `app.g.term.view_id`,
//! `app.g.agent.*`.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const ghostty_runtime = @import("runtime.zig");
const Session = @import("../session/manager.zig").Session;
const tab_strip = @import("../session/tab_strip.zig");

const c_dispatch = @cImport({
    @cInclude("dispatch/dispatch.h");
});

extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;

const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

/// Switch the visible session. Hides the previous active surface_host,
/// shows the target one, lazy-spawns its ghostty surface on first use,
/// and re-anchors the keyboard focus. Called by the `tab_N` / `next_tab`
/// / `prev_tab` action handlers in view.zig.
pub fn activateSession(idx: usize) bool {
    const sm = app.g.session_manager orelse return false;
    if (idx >= sm.sessions.items.len) return false;
    if (idx == sm.active_idx) return false;

    // Capture the old index up front + index by slot so the `old` /
    // `new` references don't shift under our feet when `switchTo`
    // flips `active_idx`. Both slots are reached via explicit array
    // index, never via `sm.active()` after the switch.
    const old_idx = sm.active_idx;
    const old_sess: *Session = &sm.sessions.items[old_idx];
    if (old_sess.surface_host) |host| {
        objc.Object.fromId(host).msgSend(void, "setHidden:", .{@as(c_int, 1)});
    }
    if (old_sess.surface) |sp| {
        ghostty_runtime.surfaceSetFocus(@ptrCast(sp), false);
    }

    _ = sm.switchTo(idx);
    const new_sess: *Session = &sm.sessions.items[idx];
    const new_host = objc.Object.fromId(new_sess.surface_host orelse return false);
    new_host.msgSend(void, "setHidden:", .{@as(c_int, 0)});

    // Lazy spawn — only the active-at-startup session was bound during
    // boot. Secondary profiles get their surface here on first activate.
    if (!new_sess.spawned) {
        const ga = app.g.ghostty.app orelse return false;
        const allocator = app.g.allocator orelse return false;
        const surf = bindGhosttySurface(allocator, ga, new_host, new_sess.profile.command, new_sess.profile.cwd) orelse {
            std.debug.print("error: lazy surface spawn failed for profile '{s}'\n", .{new_sess.profile.name});
            return false;
        };
        new_sess.surface = @ptrCast(surf);
        new_sess.spawned = true;
    }

    // Update the global pointer + AppState slot BEFORE re-focus so any
    // re-entrant Cocoa callback fired during setFocus sees the new
    // surface in app.g (reapplyTheme + updateSearchCountLabel both
    // read app.g.ghostty.surface).
    app.g.ghostty.surface = new_sess.surface;
    app.g.layout.surface_host_id = if (new_sess.surface_host) |h| @ptrCast(@alignCast(h)) else null;
    if (new_sess.surface) |sp| {
        ghostty_runtime.surfaceSetFocus(@ptrCast(sp), true);
    }

    // Per-profile window size memory. State.json may carry a
    // per-profile width/height — restore it here so log-heavy profiles
    // stay tall+wide while shell profiles stay compact. Skip when the
    // user pinned `window-width` / `window-height` explicitly in
    // config (config wins so editing the file takes effect immediately).
    applyProfileWindowSize(new_sess.profile.name);

    // Trigger menubar redraw — its dropdown subtitle reflects the
    // active profile name.
    if (app.g.agent.menubar) |mb| {
        if (app.g.agent.state) |st| {
            const snap = st.snapshot();
            mb.updateState(@enumFromInt(@intFromEnum(snap.state)), snap.message);
        }
    }
    // Tab strip highlights the active idx; redraw to follow.
    tab_strip.refresh();
    return true;
}

/// Context for deferred surface re-spawn. Heap-allocated by
/// `restartActiveSession` and freed by `restartSurfaceCallback` —
/// the slices it carries are *borrowed*: cmd is either
/// `active.profile.command` (owned by SessionManager for the
/// program lifetime) or a static literal like "/bin/zsh"; cwd is
/// owned by SessionManager. No string lifetime to manage here.
const RestartCtx = struct {
    cmd: []const u8,
    cwd: ?[]const u8,
};

/// Re-spawn the active session's child process. When `override_cmd` is
/// non-null it replaces the profile's command (used by `shell_session`
/// to force /bin/zsh). The old surface is freed synchronously and the
/// new surface is bound on the next main-queue iteration so ghostty's
/// IO mailbox has a runloop turn to unwind.
pub fn restartActiveSession(override_cmd: ?[]const u8) void {
    const sm = app.g.session_manager orelse return;
    const ga = app.g.ghostty.app orelse return;
    const allocator = app.g.allocator orelse return;
    const active = sm.active();

    // Free the old surface. Null the session slot + global pointer so
    // nothing tries to use a stale handle between now and when the
    // re-spawn callback runs.
    if (active.surface) |sp| {
        ga.surfaceFree(@ptrCast(sp));
        active.surface = null;
        active.spawned = false;
        active.exited = false;
        app.g.ghostty.surface = null;
    }

    const ctx = allocator.create(RestartCtx) catch return;
    ctx.* = .{
        .cmd = override_cmd orelse active.profile.command,
        .cwd = active.profile.cwd,
    };

    // Schedule re-spawn on the next main-queue iteration. The
    // one-turn gap is load-bearing: ghostty's IO mailbox needs a
    // runloop cycle to unwind after surface_free before the same
    // NSView can host a fresh surface.
    const main_queue = c_dispatch.dispatch_get_main_queue();
    dispatch_async_f(@ptrCast(main_queue), ctx, &restartSurfaceCallback);
}

/// Callback fired by dispatch_async_f after a runloop turn. Recovers
/// the active session from global state, re-binds a ghostty surface
/// to its surface_host NSView, and refreshes tab strip + menubar.
fn restartSurfaceCallback(ctx_opaque: ?*anyopaque) callconv(.c) void {
    const ctx: *RestartCtx = @ptrCast(@alignCast(ctx_opaque orelse return));
    const allocator = app.g.allocator orelse return;
    defer allocator.destroy(ctx);

    const ga = app.g.ghostty.app orelse return;
    const sm = app.g.session_manager orelse return;
    const active = sm.active();

    const host_raw = active.surface_host orelse return;
    const host = objc.Object.fromId(host_raw);

    const surf = bindGhosttySurface(allocator, ga, host, ctx.cmd, ctx.cwd) orelse {
        std.debug.print("error: restart surface spawn failed for profile '{s}'\n", .{active.profile.name});
        return;
    };

    active.surface = @ptrCast(surf);
    active.spawned = true;
    active.exited = false;
    app.g.ghostty.surface = active.surface;
    app.g.layout.surface_host_id = if (active.surface_host) |h| @ptrCast(@alignCast(h)) else null;

    // Re-anchor keyboard focus on the new surface's view. Without
    // this, AppKit may have lost the responder chain during the
    // surface_free → newSurface gap.
    if (app.g.term.view_id) |vid| {
        const term = objc.Object.fromId(vid);
        const window = term.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{term});
        }
    }

    // Tab strip + menubar refresh.
    tab_strip.refresh();
    if (app.g.agent.menubar) |mb| {
        if (app.g.agent.state) |st| {
            const snap = st.snapshot();
            mb.updateState(@enumFromInt(@intFromEnum(snap.state)), snap.message);
        }
    }
}

/// Bind a persistent ghostty surface to `surface_host`. Returns null on
/// failure (caller logs + bails — host can't run without a surface).
/// Provider override flows through as argv[0]; a shell command (`zsh`,
/// `bash`, …) maps to null so ghostty applies its own `-i / -l` logic.
/// `cwd` overrides the spawn working directory; null = ghostty default.
pub fn bindGhosttySurface(
    allocator: std.mem.Allocator,
    ga: *ghostty_runtime.App,
    surface_host: objc.Object,
    cmd: []const u8,
    cwd: ?[]const u8,
) ?ghostty_runtime.c.ghostty_surface_t {
    const window_obj = surface_host.msgSend(objc.Object, "window", .{});
    const surface_scale: f64 = if (window_obj.value != null)
        window_obj.msgSend(f64, "backingScaleFactor", .{})
    else
        1.0;

    const surface_cmd: ?[*:0]const u8 = if (isShell(cmd)) null else blk: {
        // Heap-dup so the C side has a stable pointer for the surface
        // lifetime — intentional process-lifetime leak.
        const dup = allocator.dupeZ(u8, cmd) catch break :blk null;
        break :blk dup.ptr;
    };
    const surface_cwd: ?[*:0]const u8 = if (cwd) |w| blk: {
        const dup = allocator.dupeZ(u8, w) catch break :blk null;
        break :blk dup.ptr;
    } else null;

    const surf = ga.newSurface(@ptrCast(surface_host.value), surface_scale, surface_cmd, surface_cwd) orelse return null;

    surface_host.msgSend(void, "setHidden:", .{@as(c_int, 0)});
    const host_bounds = surface_host.msgSend(NSRect, "bounds", .{});
    const px_w: u32 = @intFromFloat(host_bounds.size.width * surface_scale);
    const px_h: u32 = @intFromFloat(host_bounds.size.height * surface_scale);
    ghostty_runtime.surfaceSetContentScale(surf, surface_scale);
    ghostty_runtime.surfaceSetSize(surf, px_w, px_h);
    ghostty_runtime.surfaceSetFocus(surf, true);
    std.debug.print("ghostty: surface bound + foregrounded ({d}x{d}px @ {d:.1}x)\n", .{ px_w, px_h, surface_scale });
    return surf;
}

/// Look up the persisted size for `profile_name` in state.json and
/// resize the panel to match. Config-pinned dims short-circuit — when
/// the user wrote `window-width = N` they want the same N across all
/// profiles. State.json holds *implicit* sizes from the user dragging
/// the edge; the per-profile override only matters when the user
/// hasn't pinned a global size.
fn applyProfileWindowSize(profile_name: []const u8) void {
    const cfg = app.g.config orelse return;
    if (cfg.window.width != null and cfg.window.height != null) return;
    const allocator = app.g.allocator orelse return;
    const panel = app.g.window.panel orelse return;

    const persist = @import("../state/persist.zig");
    var maybe_state = persist.load(allocator);
    defer if (maybe_state) |*st| st.deinit(allocator);
    const st = maybe_state orelse return;
    const dims = st.profileSize(profile_name) orelse return;

    panel.setSize(@as(f64, @floatFromInt(dims.w)), @as(f64, @floatFromInt(dims.h)));
}

fn isShell(cmd: []const u8) bool {
    const base = std.fs.path.basename(cmd);
    const shells = [_][]const u8{ "bash", "zsh", "fish", "sh", "dash", "tcsh", "csh", "ksh" };
    for (shells) |s| if (std.mem.eql(u8, base, s)) return true;
    return false;
}
