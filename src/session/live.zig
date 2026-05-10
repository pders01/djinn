//! Hot-config-reload glue for the multi-profile session set.
//!
//! `reconcileProfiles` diffs old vs new `Config.profiles.entries`
//! against the running SessionManager and drives the live add /
//! remove / update paths. `addSessionLive` + `removeSessionLive`
//! mutate the Cocoa view tree (surface_host NSViews, tab strip
//! visibility) without restarting the process, so users can manage
//! sessions by editing `~/.config/djinn/config` and saving.
//!
//! Cocoa-bound: every public entry point dispatches NSView messages
//! on the main thread. Reads `app.g.session_manager`,
//! `app.g.layout.*`, `app.g.ghostty.app`, `app.g.agent.*` —
//! producing this module is what makes those substruct groupings
//! pull their weight.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const Config = @import("../config.zig").Config;
const main_mod = @import("../main.zig");
const tab_strip = @import("tab_strip.zig");
const surface_lifecycle = @import("../ghostty/surface_lifecycle.zig");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const view_mod = @import("../terminal/view.zig");

/// Build (when `visible` and absent) or tear down (when not `visible`
/// and present) the multi-profile tab strip, then re-run the
/// container reflow so every other child absorbs / releases
/// `tab_strip.tab_h` of vertical space. Used by hot-config-reload's
/// session add/remove path when the count crosses 1↔2.
pub fn ensureTabStripVisible(visible: bool) void {
    const cur = app.g.layout.tab_strip_id != null;
    if (visible == cur) return;

    const container_id = app.g.layout.container_id orelse return;
    const container = objc.Object.fromId(container_id);

    if (visible) {
        const c_bounds = container.msgSend(NSRect, "bounds", .{});
        const strip = tab_strip.create(c_bounds.size.width, c_bounds.size.height);
        container.msgSend(void, "addSubview:", .{strip});
        app.g.layout.tab_strip_id = strip.value;
        if (app.g.theme.chrome_style) |s| tab_strip.applyStyle(s);
    } else {
        const sid = app.g.layout.tab_strip_id.?;
        objc.Object.fromId(sid).msgSend(void, "removeFromSuperview", .{});
        app.g.layout.tab_strip_id = null;
        app.g.layout.tab_strip_separator_id = null;
    }
    view_mod.relayout();
}

/// Append a new profile at runtime. Allocates a hidden `surface_host`
/// NSView (positioned BELOW the active host so TerminalView's input
/// overlay stays on top), inherits the active host's frame +
/// autoresizing mask, and refreshes the tab strip + menubar.
/// ghostty surface is *not* spawned eagerly — first activation via
/// `activateSession` (palette/Cmd+number/tab click) drives the spawn.
pub fn addSessionLive(entry: Config.ProfileEntry) !void {
    const sm = app.g.session_manager orelse return error.NoManager;
    const container_id = app.g.layout.container_id orelse return error.NoContainer;
    const container = objc.Object.fromId(container_id);

    // Build the strip first when crossing 1→2 so the new surface_host
    // is sized to the post-strip terminal area (otherwise it'd be
    // tab_h px too tall + cover the tab strip on first activate).
    const will_cross = sm.count() == 1;
    if (will_cross) ensureTabStripVisible(true);

    const new_idx = try sm.appendEntry(entry);

    // Mirror the active host's frame + autoresizing mask so the new
    // host stays in lockstep with terminal/log/divider on container
    // resize. The active host's frame already accounts for tab_h.
    const NSView = objc.getClass("NSView") orelse return error.NSViewMissing;
    const sh_alloc = NSView.msgSend(objc.Object, "alloc", .{});
    const template_id = sm.active().surface_host orelse return error.NoTemplate;
    const template = objc.Object.fromId(template_id);
    const tmpl_frame = template.msgSend(NSRect, "frame", .{});
    const tmpl_mask = template.msgSend(c_ulong, "autoresizingMask", .{});
    const sh = sh_alloc.msgSend(objc.Object, "initWithFrame:", .{tmpl_frame});
    sh.msgSend(void, "setAutoresizingMask:", .{tmpl_mask});
    sh.msgSend(void, "setHidden:", .{@as(c_int, 1)});

    // NSWindowBelow keeps the new host under TerminalView so the
    // transparent overlay still captures key + mouse events for the
    // (eventual) active surface.
    const NSWindowBelow: c_long = -1;
    container.msgSend(void, "addSubview:positioned:relativeTo:", .{ sh, NSWindowBelow, template });
    sm.sessions.items[new_idx].surface_host = sh.value;

    // Force AppKit to commit the new sibling subview into the
    // layer tree on this runloop turn. addSubview alone schedules
    // layout for the next pass; without an explicit nudge, the
    // first activateSession on this host can race with ghostty's
    // CAMetalLayer attach + show a blank pane until the next
    // unrelated event repaints.
    container.msgSend(void, "setNeedsLayout:", .{@as(c_int, 1)});
    container.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    container.msgSend(void, "layoutSubtreeIfNeeded", .{});

    tab_strip.refresh();
    if (app.g.agent.menubar) |mb| if (app.g.agent.state) |st| {
        const snap = st.snapshot();
        mb.updateState(@enumFromInt(@intFromEnum(snap.state)), snap.message);
    };
}

/// Remove the profile at `idx` at runtime. If the entry is currently
/// active, switches to a neighbor *before* tearing down so the
/// visible surface flip happens with the old session still in the
/// slice (activateSession reaches via index). Frees the ghostty
/// surface (if spawned), removes the surface_host NSView, then
/// shrinks the session slice. Crossing 2→1 destroys the tab strip.
pub fn removeSessionLive(idx: usize) void {
    const sm = app.g.session_manager orelse return;
    if (idx >= sm.sessions.items.len) return;
    if (sm.sessions.items.len <= 1) {
        // Removing the last profile would leave the host with no
        // surface to show. Treat as restart-required.
        main_mod.hostWarn("config: cannot remove last profile at runtime; restart djinn after editing config", .{});
        return;
    }

    if (idx == sm.active_idx) {
        const fallback: usize = if (idx + 1 < sm.sessions.items.len) idx + 1 else 0;
        _ = surface_lifecycle.activateSession(fallback);
    }

    const dying = sm.sessions.items[idx];
    if (dying.surface) |sp| {
        if (app.g.ghostty.app) |ga| ga.surfaceFree(@ptrCast(sp));
    }
    if (dying.surface_host) |sh_id| {
        const sh = objc.Object.fromId(sh_id);
        sh.msgSend(void, "removeFromSuperview", .{});
        // removeFromSuperview drops the container's retain, but the
        // +1 from `[NSView alloc]` in addSessionLive is still ours.
        // Release it so the NSView (and its CAMetalLayer / backing
        // store from the bound ghostty surface) actually deallocs
        // instead of leaking on every profile removal.
        sh.msgSend(void, "release", .{});
    }
    _ = sm.removeAt(idx);

    if (sm.count() <= 1) ensureTabStripVisible(false);

    tab_strip.refresh();
}

/// Diff old vs new profile entries against the running
/// SessionManager. Drives the live-add / live-remove / live-update
/// paths so users can manage sessions by editing config without a
/// restart. The legacy single-profile path (zero entries on either
/// side) is restart-required and skipped here — `warnRestartRequired`
/// surfaces it.
pub fn reconcileProfiles(old: Config, new_cfg: Config) void {
    const sm = app.g.session_manager orelse return;
    if (old.profiles.entries.len == 0 or new_cfg.profiles.entries.len == 0) return;
    const allocator = app.g.allocator orelse return;

    // Phase 1: collect indices of sessions whose name is no longer
    // present in the new config. Removed in *descending* order so
    // earlier indices stay stable while we mutate. Heap-backed list
    // sized to the current session count: a removal can't exceed
    // existing sessions, so ensureTotalCapacity is the high-water mark.
    // Previous stack cap silently truncated large diffs (32-entry
    // limit hit = surprise data loss).
    var remove_buf: std.ArrayList(usize) = .{};
    defer remove_buf.deinit(allocator);
    remove_buf.ensureTotalCapacity(allocator, sm.sessions.items.len) catch {
        main_mod.hostWarn("config: profile reconcile OOM; skipping diff", .{});
        return;
    };
    for (sm.sessions.items, 0..) |sess, i| {
        var found = false;
        for (new_cfg.profiles.entries) |new_e| {
            if (std.mem.eql(u8, sess.profile.name, new_e.name)) {
                found = true;
                break;
            }
        }
        if (!found) remove_buf.appendAssumeCapacity(i);
    }
    var ri = remove_buf.items.len;
    while (ri > 0) {
        ri -= 1;
        removeSessionLive(remove_buf.items[ri]);
    }

    // Phase 2: append new entries that don't match any current
    // session by name.
    for (new_cfg.profiles.entries) |new_e| {
        var found = false;
        for (sm.sessions.items) |sess| {
            if (std.mem.eql(u8, sess.profile.name, new_e.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            addSessionLive(new_e) catch |err| {
                main_mod.hostWarn("config: failed to add profile '{s}': {}", .{ new_e.name, err });
            };
        }
    }

    // Phase 3: re-point display fields on matched-name sessions +
    // warn for spawn-affecting changes (command / script / provider).
    // Match-by-name walk over the *new* config so post-add iterations
    // see appended sessions too. We only re-point title/cwd because
    // the spawn command is already baked into Session.profile by
    // resolveEntry; changing it post-append would lie about what
    // surface_free + re-spawn would do without an explicit user
    // restart action.
    for (new_cfg.profiles.entries) |new_e| {
        const sess_idx = sm.indexOf(new_e.name) orelse continue;
        sm.updateProfileDisplay(sess_idx, new_e.title, new_e.cwd);

        var old_entry: ?Config.ProfileEntry = null;
        for (old.profiles.entries) |oe| {
            if (std.mem.eql(u8, oe.name, new_e.name)) {
                old_entry = oe;
                break;
            }
        }
        if (old_entry) |oe| {
            const cmd_changed =
                !eqOptStr(oe.command, new_e.command) or
                !eqOptStr(oe.script, new_e.script) or
                !eqOptStr(oe.provider, new_e.provider);
            if (cmd_changed) {
                main_mod.hostWarn("config: profile '{s}' command/script/provider changed; Cmd+R to restart that session", .{new_e.name});
            }
        }
    }

    tab_strip.refresh();
}

fn eqOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
