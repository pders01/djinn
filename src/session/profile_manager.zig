//! Profile manager — runtime profile duplication.
//!
//! Cmd+Shift+N appends a new `profile.<name>.*` block to
//! `~/.config/djinn/config` derived from the currently-active
//! session. The existing FSEvent watcher + `reconcileProfiles`
//! pipeline picks the new entry up automatically — no in-process
//! mutation of `Config.profiles.entries` required, and the file
//! becomes the source of truth so subsequent restarts see the
//! same profile.
//!
//! Append-only writeback: no structure-preserving editor — the
//! new block goes to the bottom of the file regardless of where
//! the source profile was declared. Comments + existing layout
//! upstream are untouched.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");

/// Bound to `profile_duplicate` (Cmd+Shift+N). Clones the active
/// session's profile under a unique derived name + flushes the
/// new block to disk. The reconcile path spawns the surface on
/// the next FSEvent tick.
pub fn duplicateActive() void {
    const sm = app.g.session_manager orelse return;
    const allocator = app.g.allocator orelse return;
    if (sm.sessions.items.len == 0) return;

    const active = sm.active();
    const base_name = active.profile.name;

    var name_buf: [128]u8 = undefined;
    const new_name = deriveUniqueName(base_name, sm.sessions.items, &name_buf) catch {
        hostLog("profile duplicate: could not derive unique name from '{s}'", .{base_name});
        return;
    };

    appendProfileBlock(allocator, new_name, active.profile) catch |err| {
        hostLog("profile duplicate: write failed ({})", .{err});
        return;
    };

    hostLog("profile duplicate: '{s}' → '{s}' (reload in <1s)", .{ base_name, new_name });
}

/// Walk `<base>-2`, `<base>-3`, … until we find a suffix that
/// isn't already in use. Bails after 256 attempts so a runaway
/// caller can't pin the main thread.
fn deriveUniqueName(
    base: []const u8,
    sessions: []const @import("manager.zig").Session,
    out: []u8,
) ![]const u8 {
    var i: u32 = 2;
    while (i < 256) : (i += 1) {
        const candidate = try std.fmt.bufPrint(out, "{s}-{d}", .{ base, i });
        var collision = false;
        for (sessions) |s| {
            if (std.mem.eql(u8, s.profile.name, candidate)) {
                collision = true;
                break;
            }
        }
        if (!collision) return candidate;
    }
    return error.NoFreeName;
}

fn appendProfileBlock(
    allocator: std.mem.Allocator,
    new_name: []const u8,
    src: @import("manager.zig").Profile,
) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/djinn/config", .{home});
    defer allocator.free(path);

    // Open in append mode so existing content + comments stay
    // intact. createFile + truncate is the wrong tool here.
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return error.NoConfigFile,
        else => return err,
    };
    defer file.close();

    try file.seekFromEnd(0);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("\n# duplicated from '{s}' on {d}\n", .{ src.name, std.time.timestamp() });
    try w.print("profile.{s}.command = {s}\n", .{ new_name, src.command });
    if (src.cwd) |c| try w.print("profile.{s}.cwd = {s}\n", .{ new_name, c });
    // Title decoration so the new tab is visually distinct from
    // the source. Falls back to derived name when source has no
    // explicit title.
    if (src.title) |t| {
        try w.print("profile.{s}.title = {s} (copy)\n", .{ new_name, t });
    } else {
        try w.print("profile.{s}.title = {s}\n", .{ new_name, new_name });
    }

    try file.writeAll(buf.items);
}

/// Bound to `profile_close` (Cmd+Shift+W). Removes the active
/// session's `profile.<name>.*` block from
/// `~/.config/djinn/config`. The existing FSEvent watcher fires
/// reconcileProfiles which drops the session live — no in-process
/// SessionManager surgery needed. Refuses to remove the last
/// profile so djinn can't end up with zero sessions.
pub fn closeActive() void {
    const sm = app.g.session_manager orelse return;
    const allocator = app.g.allocator orelse return;
    if (sm.sessions.items.len < 2) {
        hostLog("profile close: refusing to remove last profile", .{});
        return;
    }

    const active_name = sm.active().profile.name;
    // Copy the name out before mutating config — reconcileProfiles
    // will free the original slice when it drops the session.
    var name_buf: [128]u8 = undefined;
    const name_len = @min(active_name.len, name_buf.len);
    @memcpy(name_buf[0..name_len], active_name[0..name_len]);
    const name_copy = name_buf[0..name_len];

    removeProfileFromConfig(allocator, name_copy) catch |err| {
        hostLog("profile close: write failed ({})", .{err});
        return;
    };
    hostLog("profile close: removed '{s}' (reload in <1s)", .{name_copy});
}

fn removeProfileFromConfig(allocator: std.mem.Allocator, name: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/djinn/config", .{home});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoConfigFile,
        else => return err,
    };
    const contents = file.readToEndAlloc(allocator, 256 * 1024) catch |err| {
        file.close();
        return err;
    };
    file.close();
    defer allocator.free(contents);

    var prefix_buf: [144]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "profile.{s}.", .{name});
    var default_buf: [160]u8 = undefined;
    const default_line = try std.fmt.bufPrint(&default_buf, "default-profile = {s}", .{name});

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    // Filter: drop `profile.<name>.*` lines + the matching
    // `default-profile =` line. Everything else (other profiles,
    // comments, blank lines) survives verbatim so existing
    // structure stays intact.
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const trim = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, trim, prefix)) continue;
        if (std.mem.eql(u8, trim, default_line)) continue;
        if (!first) try w.writeAll("\n");
        first = false;
        try w.writeAll(raw);
    }

    // Atomic write: tmp file + rename. A truncate-write would
    // leave a zero-byte config visible to djinn's FSEvent reload
    // if djinn crashes (or is killed) between truncate and write
    // completion — that's parsed as an empty Config which silently
    // drops every profile. The rename swap means the on-disk file
    // is always either the previous content or the new content,
    // never partially written.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    {
        const out = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer out.close();
        try out.writeAll(buf.items);
    }
    try std.fs.renameAbsolute(tmp_path, path);
}

fn hostLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    std.debug.print("{s}\n", .{msg});
    if (app.g.agent.state) |st| st.appendLog(.info, msg) catch {};
}

test "deriveUniqueName: increments past collisions" {
    const Session = @import("manager.zig").Session;
    const sessions = [_]Session{
        .{ .profile = .{ .name = "main", .command = "claude" } },
        .{ .profile = .{ .name = "main-2", .command = "claude" } },
        .{ .profile = .{ .name = "main-3", .command = "claude" } },
    };
    var buf: [128]u8 = undefined;
    const name = try deriveUniqueName("main", &sessions, &buf);
    try std.testing.expectEqualStrings("main-4", name);
}

test "deriveUniqueName: no collision returns -2" {
    const Session = @import("manager.zig").Session;
    const sessions = [_]Session{
        .{ .profile = .{ .name = "main", .command = "claude" } },
    };
    var buf: [128]u8 = undefined;
    const name = try deriveUniqueName("main", &sessions, &buf);
    try std.testing.expectEqualStrings("main-2", name);
}
