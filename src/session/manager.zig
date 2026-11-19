const std = @import("std");
const platform = @import("../io/platform.zig");
const Config = @import("../config.zig").Config;

/// Resolved launch state, owned by SessionManager independently of Config.
pub const Profile = struct {
    name: []const u8,
    /// script > command > null. Null asks ghostty to launch the user's
    /// ordinary default shell; it is not an empty or hardcoded command.
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    // Original settings identify unchanged paths even when the resolved
    // directory or script is temporarily inaccessible during config reload.
    script_setting: ?[]const u8 = null,
    cwd_setting: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// null = inherit the current global bell setting.
    bell_audible: ?bool = null,
    bell_visual: ?bool = null,
    bell_sound: ?[]const u8 = null,

    pub fn label(self: Profile) []const u8 {
        return self.title orelse self.name;
    }
};

/// A configured terminal, pending until first activation. The caller owns
/// all Cocoa/ghostty handles and their destruction, not this module.
pub const Session = struct {
    /// Stable, nonzero identity for this manager's lifetime. Never changes
    /// when the active tab changes or a surface is restarted.
    id: u64,
    /// Caller increments before each surface creation/replacement and when
    /// invalidating callbacks. Pair with id to reject stale surface events.
    surface_generation: u64 = 0,
    /// Sentinel buffers are owned by the caller's surface lifecycle. Keep
    /// them alive through surface destruction; SessionManager never frees them.
    command_z: ?[:0]u8 = null,
    cwd_z: ?[:0]u8 = null,
    terminal_title: [256]u8 = @splat(0),
    terminal_title_len: usize = 0,
    profile: Profile,
    owned_strings: std.ArrayList([]u8) = .empty,
    synthetic: bool = false,
    /// Removed from config, but still owns a running child. Never relaunch it.
    retired: bool = false,
    surface: ?*anyopaque = null,
    surface_host: ?*anyopaque = null,
    spawned: bool = false,
    exited: bool = false,
    // Host input requests belong to this incarnation, not to process-global
    // Secure Input / NSCursor state. Only the active visible focused source wins.
    surface_focused: bool = false,
    surface_visible: bool = false,
    requested_secure_input: bool = false,
    requested_cursor_hidden: bool = false,
    requested_cursor_shape: [:0]const u8 = "IBeamCursor",
    mouse_over_link: bool = false,

    /// Recheck retained explicit cwd at EVERY launch, including lazy starts and
    /// restarts: Ghostty otherwise silently falls back when it disappears.
    pub fn validateLaunch(self: *const Session) !void {
        if (self.profile.cwd) |cwd| try validateCwd(cwd);
    }

    pub fn label(self: *const Session) []const u8 {
        if (self.profile.title) |title| return title;
        if (self.terminal_title_len != 0) return self.terminal_title[0..@min(self.terminal_title_len, self.terminal_title.len)];
        return self.profile.name;
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    /// Stable userdata addresses even when profile order or membership changes.
    sessions: std.ArrayList(*Session) = .empty,
    active_idx: usize = 0,
    default_idx: usize = 0,
    next_id: u64 = 1,
    /// Relative scripts use the original startup directory, even after the
    /// macOS host changes its own cwd to give new shells a home directory.
    script_base: []const u8 = "",

    /// No configured profiles means one lazy, ordinary shell. Every retained
    /// config string is copied so Config.deinit/reload cannot dangle it.
    pub fn init(allocator: std.mem.Allocator, cfg: *const Config) !SessionManager {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = std.process.currentPath(platform.io(), &path_buf) catch |err| switch (err) {
            // A deleted startup directory only prevents relative scripts.
            error.CurrentDirUnlinked => 0,
            else => return err,
        };
        return initProfiles(allocator, cfg, path_buf[0..len], null);
    }

    fn initProfiles(allocator: std.mem.Allocator, cfg: *const Config, script_base: []const u8, previous: ?*const SessionManager) !SessionManager {
        var mgr: SessionManager = .{
            .allocator = allocator,
            .script_base = try allocator.dupe(u8, script_base),
            .next_id = if (previous) |old| old.next_id else 1,
        };
        errdefer mgr.deinit();

        if (cfg.profiles.entries.len == 0) {
            try mgr.appendProfile(.{ .name = "default" }, true, previous);
        } else {
            for (cfg.profiles.entries) |entry| try mgr.appendProfile(entry, false, previous);
        }

        if (cfg.profiles.default) |name| {
            if (mgr.indexOf(name)) |idx| {
                mgr.default_idx = idx;
                mgr.active_idx = idx;
            } else {
                std.debug.print("warning: default-profile '{s}' not defined; using '{s}'\n", .{ name, mgr.sessions.items[0].profile.name });
            }
        }
        return mgr;
    }

    fn findProfile(self: *const SessionManager, name: []const u8, synthetic: bool) ?*const Session {
        for (self.sessions.items) |session| {
            if (session.synthetic == synthetic and std.mem.eql(u8, session.profile.name, name)) return session;
        }
        return null;
    }

    fn appendProfile(self: *SessionManager, entry: Config.ProfileEntry, synthetic: bool, previous: ?*const SessionManager) !void {
        const old = if (previous) |sm| sm.findProfile(entry.name, synthetic) else null;
        const session = try self.allocator.create(Session);
        session.* = .{ .id = self.next_id, .profile = undefined, .synthetic = synthetic };
        if (old) |s| {
            session.id = s.id;
            session.terminal_title = s.terminal_title;
            session.terminal_title_len = s.terminal_title_len;
            session.exited = s.exited;
        }
        errdefer self.destroy(session);
        session.profile = try resolveEntry(self.allocator, &entry, self.script_base, if (old) |s| &s.profile else null, &session.owned_strings);
        try self.sessions.append(self.allocator, session);
        if (old == null) self.next_id += 1;
    }

    fn destroy(self: *const SessionManager, session: *Session) void {
        for (session.owned_strings.items) |s| self.allocator.free(s);
        session.owned_strings.deinit(self.allocator);
        self.allocator.destroy(session);
    }

    pub fn deinit(self: *SessionManager) void {
        for (self.sessions.items) |session| self.destroy(session);
        self.sessions.deinit(self.allocator);
        self.allocator.free(self.script_base);
    }

    pub fn active(self: *const SessionManager) *Session {
        return self.sessions.items[self.active_idx];
    }

    pub fn indexOfId(self: *const SessionManager, id: u64) ?usize {
        for (self.sessions.items, 0..) |session, i| if (session.id == id) return i;
        return null;
    }

    /// Call only after the platform host has detached the native terminal.
    pub fn removeRetired(self: *SessionManager, idx: usize) void {
        const session = self.sessions.orderedRemove(idx);
        std.debug.assert(session.retired);
        // Retired sessions are always after all configured sessions.
        if (idx == self.active_idx) self.active_idx = self.default_idx else if (idx < self.active_idx) self.active_idx -= 1;
        self.destroy(session);
    }

    /// Stage a profile reload without moving any live Session or touching a
    /// running child. Hosts can prepare their native UI before committing.
    pub fn prepareReload(self: *const SessionManager, cfg: *const Config) !Reload {
        var plan = Reload{ .preview = try initProfiles(self.allocator, cfg, self.script_base, self) };
        plan.configured_count = plan.preview.count();
        errdefer plan.deinit();
        for (self.sessions.items) |old| {
            if (old.spawned and !old.exited and plan.preview.indexOfId(old.id) == null)
                try plan.preview.sessions.append(self.allocator, old);
        }
        if (plan.preview.indexOfId(self.active().id)) |idx| plan.preview.active_idx = idx;
        return plan;
    }

    pub const Reload = struct {
        preview: SessionManager,
        // Configured prefix is owned by the plan; the remaining (retiring)
        // nodes are borrowed from the current manager until commit.
        configured_count: usize = 0,

        pub fn deinit(self: *Reload) void {
            self.preview.sessions.items.len = self.configured_count;
            self.preview.deinit();
        }

        /// The host must destroy resources of all omitted sessions first.
        /// Consumes the plan and preserves native userdata, generation and PTY
        /// state of every retained session.
        pub fn commit(self: *Reload, manager: *SessionManager) void {
            for (self.preview.sessions.items[0..self.configured_count]) |*slot| {
                const fresh = slot.*;
                if (manager.indexOfId(fresh.id)) |idx| {
                    const old = manager.sessions.items[idx];
                    old.profile = fresh.profile;
                    std.mem.swap(std.ArrayList([]u8), &old.owned_strings, &fresh.owned_strings);
                    old.retired = false;
                    slot.* = old;
                    manager.destroy(fresh);
                }
            }
            for (self.preview.sessions.items[self.configured_count..]) |s| s.retired = true;
            for (manager.sessions.items) |old| {
                if (self.preview.indexOfId(old.id) == null) manager.destroy(old);
            }
            manager.sessions.deinit(manager.allocator);
            manager.allocator.free(manager.script_base);
            manager.* = self.preview;
            self.preview.sessions = .empty;
            self.preview.script_base = "";
            self.configured_count = 0;
        }
    };

    pub fn count(self: *const SessionManager) usize {
        return self.sessions.items.len;
    }

    pub fn indexOf(self: *const SessionManager, name: []const u8) ?usize {
        for (self.sessions.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.profile.name, name)) return i;
        }
        return null;
    }

    pub fn switchTo(self: *SessionManager, idx: usize) bool {
        if (idx >= self.sessions.items.len or idx == self.active_idx) return false;
        self.active_idx = idx;
        return true;
    }

    pub fn next(self: *SessionManager) bool {
        return self.switchTo(self.peekNext() orelse return false);
    }

    pub fn prev(self: *SessionManager) bool {
        return self.switchTo(self.peekPrev() orelse return false);
    }

    /// Inspect a navigation target without spawning or changing active state.
    pub fn peekNext(self: *const SessionManager) ?usize {
        if (self.sessions.items.len <= 1) return null;
        return (self.active_idx + 1) % self.sessions.items.len;
    }

    pub fn peekPrev(self: *const SessionManager) ?usize {
        if (self.sessions.items.len <= 1) return null;
        return if (self.active_idx == 0) self.sessions.items.len - 1 else self.active_idx - 1;
    }
};

fn own(allocator: std.mem.Allocator, owned: *std.ArrayList([]u8), value: []const u8) ![]const u8 {
    return retain(allocator, owned, try allocator.dupe(u8, value));
}

fn retain(allocator: std.mem.Allocator, owned: *std.ArrayList([]u8), value: []u8) ![]const u8 {
    errdefer allocator.free(value);
    try owned.append(allocator, value);
    return value;
}

fn ownOptional(allocator: std.mem.Allocator, owned: *std.ArrayList([]u8), value: ?[]const u8) !?[]const u8 {
    return if (value) |s| try own(allocator, owned, s) else null;
}

fn sameSetting(old: ?[]const u8, value: []const u8) bool {
    return std.mem.eql(u8, old orelse return false, value);
}

fn resolveEntry(allocator: std.mem.Allocator, e: *const Config.ProfileEntry, script_base: []const u8, old: ?*const Profile, owned: *std.ArrayList([]u8)) !Profile {
    // Validate even shadowed explicit settings: a script must not hide an
    // accidentally empty command. Manually constructed Configs use this too.
    for ([_]?[]const u8{ e.command, e.script, e.cwd }) |value| {
        if (value) |s| try validateLaunchValue(s);
    }
    const command = if (e.script) |script| blk: {
        if (old) |p| {
            if (sameSetting(p.script_setting, script)) break :blk try ownOptional(allocator, owned, p.command);
        }
        break :blk resolveScript(allocator, script, script_base, owned) catch |err| {
            std.debug.print("error: profile '{s}' script '{s}' cannot launch ({}); fix the path/execute permission or remove profile.{s}.script\n", .{ e.name, script, err, e.name });
            return err;
        };
    } else try ownOptional(allocator, owned, e.command);
    const cwd = if (e.cwd) |value| blk: {
        if (old) |p| {
            if (sameSetting(p.cwd_setting, value)) break :blk try ownOptional(allocator, owned, p.cwd);
        }
        break :blk try resolveCwd(allocator, value, owned);
    } else null;
    return .{
        .name = try own(allocator, owned, e.name),
        .command = command,
        .cwd = cwd,
        .script_setting = try ownOptional(allocator, owned, e.script),
        .cwd_setting = try ownOptional(allocator, owned, e.cwd),
        .title = try ownOptional(allocator, owned, e.title),
        .bell_audible = e.bell_audible,
        .bell_visual = e.bell_visual,
        .bell_sound = try ownOptional(allocator, owned, e.bell_sound),
    };
}

fn validateLaunchValue(value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.EmptyLaunchValue;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidLaunchValue;
}

fn expandHome(allocator: std.mem.Allocator, raw: []const u8, owned: *std.ArrayList([]u8)) ![]const u8 {
    if (std.mem.startsWith(u8, raw, "~/")) {
        const home = platform.getenv("HOME") orelse return error.NoHome;
        return retain(allocator, owned, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw[2..] }));
    }
    return own(allocator, owned, raw);
}

/// Ghostty silently ignores invalid working directories. Validate explicitly
/// so a configured launch cannot run somewhere else without the user's consent.
fn resolveCwd(allocator: std.mem.Allocator, raw: []const u8, owned: *std.ArrayList([]u8)) ![]const u8 {
    const path = try expandHome(allocator, raw, owned);
    try validateCwd(path);
    return path;
}

fn validateCwd(path: []const u8) !void {
    try validateLaunchValue(path);
    if (!std.fs.path.isAbsolute(path)) return error.NotAbsolutePath;
    const dir = try std.Io.Dir.openDirAbsolute(platform.io(), path, .{});
    defer dir.close(platform.io());
    try checkExecuteAccess(path);
}

/// Retain the libc access check in addition to mode bits: ACLs and mount
/// permissions can prohibit execution even when a file has executable bits.
fn checkExecuteAccess(path: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    switch (std.c.errno(std.c.access(buffer[0..path.len :0].ptr, std.c.X_OK))) {
        .SUCCESS => {},
        .ACCES => return error.PermissionDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .IO => return error.InputOutput,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// An explicitly configured script is a promise, not a shell fallback.
/// Expand ~/ and validate both file type and effective execute permission.
/// The embedded API treats .command as a SHELL command, not argv[0]. Resolve
/// relative paths against the startup directory, then quote the literal path.
fn resolveScript(allocator: std.mem.Allocator, raw: []const u8, script_base: []const u8, owned: *std.ArrayList([]u8)) ![]const u8 {
    const expanded = try expandHome(allocator, raw, owned);
    const relative = if (std.fs.path.isAbsolute(expanded)) null else blk: {
        if (script_base.len == 0) return error.CurrentDirUnlinked;
        break :blk try std.fs.path.join(allocator, &.{ script_base, expanded });
    };
    defer if (relative) |p| allocator.free(p);
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(platform.io(), relative orelse expanded, allocator);
    defer allocator.free(resolved);
    const path = try own(allocator, owned, resolved);
    const stat = try std.Io.Dir.cwd().statFile(platform.io(), path, .{});
    if (stat.kind != .file) return error.NotARegularFile;
    if (stat.permissions.toMode() & 0o111 == 0) return error.NotExecutable;
    checkExecuteAccess(path) catch |err| switch (err) {
        error.PermissionDenied => return error.NotExecutable,
        else => return err,
    };
    return quoteScriptPath(allocator, path, owned);
}

fn quoteScriptPath(allocator: std.mem.Allocator, path: []const u8, owned: *std.ArrayList([]u8)) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (path) |c| {
        if (c == '\'') {
            // End single quotes, emit one escaped apostrophe, resume quotes.
            try quoted.appendSlice(allocator, "'\\''");
        } else {
            try quoted.append(allocator, c);
        }
    }
    try quoted.append(allocator, '\'');
    return retain(allocator, owned, try quoted.toOwnedSlice(allocator));
}

// Tests --------------------------------------------------------------

test "SessionManager: no profiles means a lazy default shell" {
    const cfg = Config{};
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    try std.testing.expectEqualStrings("default", mgr.active().profile.name);
    try std.testing.expect(mgr.active().profile.command == null);
    try std.testing.expect(mgr.active().surface == null);
    try std.testing.expect(!mgr.active().spawned);
    try std.testing.expectEqual(@as(u64, 1), mgr.active().id);
    try std.testing.expectEqual(@as(u64, 0), mgr.active().surface_generation);
    try std.testing.expect(mgr.active().command_z == null);
    try std.testing.expect(mgr.active().cwd_z == null);
    try std.testing.expectEqual(@as(usize, 0), mgr.active().terminal_title_len);
    try std.testing.expectEqualSlices(u8, &@as([256]u8, @splat(0)), &mgr.active().terminal_title);
    try std.testing.expect(mgr.peekNext() == null);
    try std.testing.expect(mgr.peekPrev() == null);
}

test "SessionManager: configured shell and explicit command" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "shell" },
        .{ .name = "tool", .command = "my-tool --interactive" },
    };
    const cfg = Config{ .profiles = .{ .entries = &entries, .default = "tool" } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expect(mgr.sessions.items[0].profile.command == null);
    try std.testing.expectEqualStrings("my-tool --interactive", mgr.active().profile.command.?);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?usize, 0), mgr.indexOf("shell"));
    try std.testing.expect(mgr.indexOf("missing") == null);
}

test "SessionManager: navigation preserves identity and lazy state" {
    const entries = [_]Config.ProfileEntry{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" } };
    const cfg = Config{ .profiles = .{ .entries = &entries, .default = "missing" } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_idx);
    try std.testing.expectEqual(@as(?usize, 1), mgr.peekNext());
    try std.testing.expectEqual(@as(?usize, 2), mgr.peekPrev());
    try std.testing.expect(mgr.switchTo(2));
    const id = mgr.active().id;
    try std.testing.expect(!mgr.switchTo(2));
    try std.testing.expect(!mgr.switchTo(99));
    try std.testing.expect(mgr.next());
    try std.testing.expectEqualStrings("a", mgr.active().profile.name);
    try std.testing.expect(mgr.prev());
    try std.testing.expectEqual(id, mgr.active().id);
    for (mgr.sessions.items, 0..) |s, i| {
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), s.id);
        try std.testing.expect(!s.spawned);
        try std.testing.expect(s.surface == null);
    }
}

test "SessionManager: script beats command and is owned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(platform.io(), "launch.sh", .{ .permissions = .fromMode(0o755) });
    defer file.close(platform.io());
    try file.writeStreamingAll(platform.io(), "#!/bin/sh\nexec /bin/sh\n");
    try file.setPermissions(platform.io(), .fromMode(0o755));
    const path = try tmp.dir.realPathFileAlloc(platform.io(), "launch.sh", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .command = "ignored", .script = path }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    const expected = try std.fmt.allocPrint(std.testing.allocator, "'{s}'", .{path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, mgr.active().profile.command.?);
    try std.testing.expect(path.ptr != mgr.active().profile.command.?.ptr);
}

test "SessionManager: missing script fails instead of falling through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(platform.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "missing.sh" });
    defer std.testing.allocator.free(path);
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .command = "/bin/sh", .script = path }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    try std.testing.expectError(error.FileNotFound, SessionManager.init(std.testing.allocator, &cfg));
}

test "SessionManager: nonexecutable script fails instead of spawning shell" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(platform.io(), "launch.sh", .{ .permissions = .fromMode(0o644) });
    defer file.close(platform.io());
    try file.setPermissions(platform.io(), .fromMode(0o644));
    const path = try tmp.dir.realPathFileAlloc(platform.io(), "launch.sh", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .script = path }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    try std.testing.expectError(error.NotExecutable, SessionManager.init(std.testing.allocator, &cfg));
}

test "SessionManager: retained launch strings outlive parsed config" {
    var cfg = try Config.parse(std.testing.allocator,
        \\profile.main.command = /bin/sh
        \\profile.main.cwd = /tmp
        \\profile.main.title = Main Shell
        \\profile.main.bell-sound = Glass
        \\profile.main.bell-audible = false
        \\profile.main.bell-visual = true
    );
    var mgr = SessionManager.init(std.testing.allocator, &cfg) catch |err| {
        cfg.deinit();
        return err;
    };
    defer mgr.deinit();
    cfg.deinit();
    const p = mgr.active().profile;
    try std.testing.expectEqualStrings("main", p.name);
    try std.testing.expectEqualStrings("/bin/sh", p.command.?);
    try std.testing.expectEqualStrings("/tmp", p.cwd.?);
    try std.testing.expectEqualStrings("Main Shell", p.label());
    try std.testing.expectEqualStrings("Glass", p.bell_sound.?);
    try std.testing.expectEqual(@as(?bool, false), p.bell_audible);
    try std.testing.expectEqual(@as(?bool, true), p.bell_visual);
    try std.testing.expectEqualStrings("fallback", (Profile{ .name = "fallback" }).label());
}

test "Session: label prefers explicit title then terminal title then name" {
    var session = Session{ .id = 1, .profile = .{ .name = "main" } };
    try std.testing.expectEqualStrings("main", session.label());
    @memcpy(session.terminal_title[0..5], "shell");
    session.terminal_title_len = 5;
    try std.testing.expectEqualStrings("shell", session.label());
    session.profile.title = "Pinned";
    try std.testing.expectEqualStrings("Pinned", session.label());
    session.profile.title = "";
    try std.testing.expectEqualStrings("", session.label());
    session.profile.title = null;
    session.terminal_title_len = 0;
    try std.testing.expectEqualStrings("main", session.label());
}

test "SessionManager: explicit command remains a shell command unchanged" {
    const command = "  FOO='a b' /bin/tool --arg=\"$HOME\"; echo done  ";
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .command = command }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings(command, mgr.active().profile.command.?);
}

test "SessionManager: reject empty explicit launch settings including shadowed command" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "main", .command = "" },
        .{ .name = "main", .command = " \t\n" },
        .{ .name = "main", .script = "" },
        .{ .name = "main", .cwd = "" },
        .{ .name = "main", .cwd = " \t" },
        .{ .name = "main", .command = "", .script = "/bin/sh" },
    };
    for (entries) |entry| {
        const single = [_]Config.ProfileEntry{entry};
        const cfg = Config{ .profiles = .{ .entries = &single } };
        try std.testing.expectError(error.EmptyLaunchValue, SessionManager.init(std.testing.allocator, &cfg));
    }
    const nul = [_]Config.ProfileEntry{.{ .name = "main", .command = "echo\x00ignored" }};
    const cfg = Config{ .profiles = .{ .entries = &nul } };
    try std.testing.expectError(error.InvalidLaunchValue, SessionManager.init(std.testing.allocator, &cfg));
}

test "SessionManager: cwd must be an existing absolute directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(platform.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .cwd = path }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings(path, mgr.active().profile.cwd.?);
    try std.testing.expect(path.ptr != mgr.active().profile.cwd.?.ptr);

    const file = try tmp.dir.createFile(platform.io(), "file", .{});
    file.close(platform.io());
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ path, "file" });
    defer std.testing.allocator.free(file_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ path, "missing" });
    defer std.testing.allocator.free(missing_path);
    const invalid = [_]struct { path: []const u8, err: anyerror }{
        .{ .path = file_path, .err = error.NotDir },
        .{ .path = missing_path, .err = error.FileNotFound },
        .{ .path = "relative/path", .err = error.NotAbsolutePath },
    };
    for (invalid) |case| {
        const bad_entries = [_]Config.ProfileEntry{.{ .name = "bad", .cwd = case.path }};
        const bad_cfg = Config{ .profiles = .{ .entries = &bad_entries } };
        try std.testing.expectError(case.err, SessionManager.init(std.testing.allocator, &bad_cfg));
    }
}

test "SessionManager: leading tilde expansion is literal and owned" {
    const home = platform.getenv("HOME") orelse return error.SkipZigTest;
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| std.testing.allocator.free(s);
        owned.deinit(std.testing.allocator);
    }
    const path = try expandHome(std.testing.allocator, "~/dir with spaces/$literal", &owned);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/dir with spaces/$literal", .{home});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "SessionManager: script shell quoting escapes apostrophes and disables expansion" {
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| std.testing.allocator.free(s);
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("'/tmp/it'\\''s a $HOME `tool`'", try quoteScriptPath(std.testing.allocator, "/tmp/it's a $HOME `tool`", &owned));
    try std.testing.expectEqualStrings("'/tmp/simple'", try quoteScriptPath(std.testing.allocator, "/tmp/simple", &owned));
}

test "SessionManager: executable script path with spaces and apostrophe is one literal word" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = "it's a $HOME script.sh";
    const file = try tmp.dir.createFile(platform.io(), filename, .{ .permissions = .fromMode(0o755) });
    defer file.close(platform.io());
    try file.writeStreamingAll(platform.io(), "#!/bin/sh\nexit 0\n");
    try file.setPermissions(platform.io(), .fromMode(0o755));
    const dir = try tmp.dir.realPathFileAlloc(platform.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, filename });
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "'{s}/it'\\''s a $HOME script.sh'", .{dir});
    defer std.testing.allocator.free(expected);
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .script = path }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings(expected, mgr.active().profile.command.?);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator, script: []const u8, cwd: []const u8) !void {
            const profiles = [_]Config.ProfileEntry{.{ .name = "main", .script = script, .cwd = cwd }};
            const config = Config{ .profiles = .{ .entries = &profiles } };
            var manager = try SessionManager.init(allocator, &config);
            defer manager.deinit();
        }
    }.check, .{ path, dir });
}

test "Session: retained cwd is revalidated after load and before each launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(platform.io(), "launch", .default_dir);
    const cwd = try tmp.dir.realPathFileAlloc(platform.io(), "launch", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const entries = [_]Config.ProfileEntry{.{ .name = "main", .cwd = cwd }};
    const cfg = Config{ .profiles = .{ .entries = &entries } };
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try mgr.active().validateLaunch();
    try tmp.dir.deleteDir(platform.io(), "launch");
    // A lazy start or restart must fail, not change the retained cwd or use HOME.
    try std.testing.expectError(error.FileNotFound, mgr.active().validateLaunch());
    try std.testing.expectEqualStrings(cwd, mgr.active().profile.cwd.?);
    try tmp.dir.createDir(platform.io(), "launch", .default_dir);
    try mgr.active().validateLaunch();
    try tmp.dir.deleteDir(platform.io(), "launch");
    const file = try tmp.dir.createFile(platform.io(), "launch", .{});
    file.close(platform.io());
    try std.testing.expectError(error.NotDir, mgr.active().validateLaunch());
    var shell: Session = .{ .id = 2, .profile = .{ .name = "shell" } };
    try shell.validateLaunch();
}

test "profile reload retitles and reorders without moving a live session" {
    const a = std.testing.allocator;
    var cfg = try Config.parse(a, "profile.one.title = One\nprofile.two.command = old");
    defer cfg.deinit();
    var sm = try SessionManager.init(a, &cfg);
    defer sm.deinit();
    try std.testing.expect(sm.switchTo(1));
    const live = sm.active();
    live.surface = @ptrFromInt(0x1000);
    live.spawned = true;
    live.surface_generation = 42;
    var edited = try Config.parse(a, "default-profile = new\nprofile.two.title = Renamed\nprofile.two.command = new-command\nprofile.new.title = New");
    var plan = try sm.prepareReload(&edited);
    defer plan.deinit();
    edited.deinit();
    try std.testing.expectEqualStrings("old", live.profile.command.?);
    plan.commit(&sm);
    try std.testing.expectEqual(live, sm.active());
    try std.testing.expectEqual(@as(usize, 0), sm.active_idx);
    try std.testing.expectEqual(@as(usize, 1), sm.default_idx);
    try std.testing.expectEqual(@as(u64, 42), live.surface_generation);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1000)), live.surface);
    try std.testing.expectEqualStrings("Renamed", live.label());
    try std.testing.expectEqualStrings("new-command", live.profile.command.?);
    try std.testing.expectEqual(@as(?usize, null), sm.indexOf("one"));
    try std.testing.expect(!sm.sessions.items[1].spawned);
    try std.testing.expectEqual(@as(u64, 3), sm.sessions.items[1].id);
}

test "profile reload keeps unchanged launch paths even when they go offline" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(platform.io(), "workdir", .default_dir);
    const cwd = try tmp.dir.realPathFileAlloc(platform.io(), "workdir", a);
    defer a.free(cwd);
    const file = try tmp.dir.createFile(platform.io(), "launch.sh", .{ .permissions = .fromMode(0o755) });
    file.close(platform.io());
    const script = try tmp.dir.realPathFileAlloc(platform.io(), "launch.sh", a);
    defer a.free(script);
    var entries = [_]Config.ProfileEntry{ .{ .name = "local", .title = "Before" }, .{ .name = "remote", .script = script, .cwd = cwd } };
    const cfg: Config = .{ .profiles = .{ .entries = &entries } };
    var sm = try SessionManager.init(a, &cfg);
    defer sm.deinit();
    const remote = sm.sessions.items[1];
    remote.spawned = true;
    const command = try a.dupe(u8, remote.profile.command.?);
    defer a.free(command);
    try tmp.dir.deleteFile(platform.io(), "launch.sh");
    try tmp.dir.deleteDir(platform.io(), "workdir");

    entries[0].title = "After";
    var plan = try sm.prepareReload(&cfg);
    defer plan.deinit();
    plan.commit(&sm);
    try std.testing.expectEqualStrings("After", sm.active().label());
    try std.testing.expectEqual(remote, sm.sessions.items[1]);
    try std.testing.expectEqualStrings(command, remote.profile.command.?);
    try std.testing.expectError(error.FileNotFound, remote.validateLaunch());

    const changed_cwd = try std.fs.path.join(a, &.{ cwd, "missing" });
    defer a.free(changed_cwd);
    entries[1].cwd = changed_cwd;
    try std.testing.expectError(error.FileNotFound, sm.prepareReload(&cfg));
    try std.testing.expectEqualStrings(cwd, remote.profile.cwd.?);
}

test "relative script edits resolve against the original startup directory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(platform.io(), ".", a);
    defer a.free(base);
    for ([_][]const u8{ "before.sh", "after.sh" }) |name| {
        const file = try tmp.dir.createFile(platform.io(), name, .{ .permissions = .fromMode(0o755) });
        file.close(platform.io());
    }
    var entries = [_]Config.ProfileEntry{.{ .name = "tool", .script = "before.sh" }};
    const cfg: Config = .{ .profiles = .{ .entries = &entries } };
    // The fixture's startup directory is intentionally not this process's cwd.
    var sm = try SessionManager.initProfiles(a, &cfg, base, null);
    defer sm.deinit();
    entries[0].script = "after.sh";
    var plan = try sm.prepareReload(&cfg);
    defer plan.deinit();
    plan.commit(&sm);
    const path = try tmp.dir.realPathFileAlloc(platform.io(), "after.sh", a);
    defer a.free(path);
    const expected = try std.fmt.allocPrint(a, "'{s}'", .{path});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, sm.active().profile.command.?);
}

test "deleting a live profile retires it until exit and uses the configured fallback" {
    const a = std.testing.allocator;
    const entries = [_]Config.ProfileEntry{ .{ .name = "active" }, .{ .name = "exited" } };
    var sm = try SessionManager.init(a, &.{ .profiles = .{ .entries = &entries } });
    defer sm.deinit();
    const live = sm.active();
    live.spawned = true;
    sm.sessions.items[1].spawned = true;
    sm.sessions.items[1].exited = true;
    var plan = try sm.prepareReload(&.{});
    defer plan.deinit();
    plan.commit(&sm);
    try std.testing.expectEqual(@as(usize, 2), sm.count());
    try std.testing.expectEqual(@as(?usize, null), sm.indexOf("exited"));
    try std.testing.expectEqual(live, sm.active());
    try std.testing.expect(live.retired);
    sm.removeRetired(sm.active_idx);
    try std.testing.expectEqual(@as(usize, 1), sm.count());
    try std.testing.expectEqualStrings("default", sm.active().profile.name);
    try std.testing.expect(!sm.active().spawned);
}

test "readding a retired profile preserves the child; an invalid edit rolls back" {
    const a = std.testing.allocator;
    const entries = [_]Config.ProfileEntry{.{ .name = "work", .title = "Work" }};
    const cfg: Config = .{ .profiles = .{ .entries = &entries } };
    var sm = try SessionManager.init(a, &cfg);
    defer sm.deinit();
    const work = sm.active();
    work.spawned = true;
    var removal = try sm.prepareReload(&.{});
    defer removal.deinit();
    removal.commit(&sm);
    try std.testing.expect(work.retired);
    const invalid = [_]Config.ProfileEntry{.{ .name = "work", .command = " " }};
    try std.testing.expectError(error.EmptyLaunchValue, sm.prepareReload(&.{ .profiles = .{ .entries = &invalid } }));
    try std.testing.expect(work.retired);
    var restore = try sm.prepareReload(&cfg);
    defer restore.deinit();
    restore.commit(&sm);
    try std.testing.expectEqual(work, sm.active());
    try std.testing.expect(!work.retired);
    try std.testing.expect(work.spawned);
    try std.testing.expectEqual(@as(usize, 1), sm.count());
}

test "profile reload allocation failures keep the prior manager usable" {
    const Test = struct {
        fn run(a: std.mem.Allocator) !void {
            const initial = [_]Config.ProfileEntry{.{ .name = "live", .title = "Original" }};
            const edited = [_]Config.ProfileEntry{.{ .name = "new", .title = "New" }};
            var sm = try SessionManager.init(a, &.{ .profiles = .{ .entries = &initial } });
            defer sm.deinit();
            sm.active().spawned = true;
            var plan = sm.prepareReload(&.{ .profiles = .{ .entries = &edited } }) catch |err| {
                try std.testing.expectEqualStrings("Original", sm.active().label());
                return err;
            };
            defer plan.deinit();
            plan.commit(&sm);
            try std.testing.expect(sm.active().retired);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Test.run, .{});
}

test "SessionManager: allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            const entries = [_]Config.ProfileEntry{.{ .name = "main", .command = "/bin/sh", .cwd = "/tmp", .title = "Shell", .bell_sound = "Tink" }};
            const cfg = Config{ .profiles = .{ .entries = &entries } };
            var mgr = try SessionManager.init(allocator, &cfg);
            defer mgr.deinit();
        }
    }.check, .{});
}
