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
    /// Fixed membership after init. This module never reallocates the list
    /// after returning it; surface lifecycle is managed by the caller.
    sessions: std.ArrayList(Session) = .empty,
    active_idx: usize = 0,
    owned_strings: std.ArrayList([]u8) = .empty,

    /// No configured profiles means one lazy, ordinary shell. Every retained
    /// config string is copied so Config.deinit/reload cannot dangle it.
    pub fn init(allocator: std.mem.Allocator, cfg: *const Config) !SessionManager {
        var mgr = SessionManager{ .allocator = allocator };
        errdefer mgr.deinit();

        if (cfg.profiles.entries.len == 0) {
            try mgr.sessions.append(allocator, .{
                .id = 1,
                .profile = .{ .name = try own(allocator, &mgr.owned_strings, "default") },
            });
        } else {
            for (cfg.profiles.entries, 0..) |entry, i| {
                try mgr.sessions.append(allocator, .{
                    .id = @as(u64, @intCast(i)) + 1,
                    .profile = try resolveEntry(allocator, &entry, &mgr.owned_strings),
                });
            }
        }

        if (cfg.profiles.default) |name| {
            if (mgr.indexOf(name)) |idx| {
                mgr.active_idx = idx;
            } else {
                std.debug.print("warning: default-profile '{s}' not defined; using '{s}'\n", .{ name, mgr.sessions.items[0].profile.name });
            }
        }
        return mgr;
    }

    pub fn deinit(self: *SessionManager) void {
        self.sessions.deinit(self.allocator);
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
    }

    pub fn active(self: *SessionManager) *Session {
        return &self.sessions.items[self.active_idx];
    }

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

fn resolveEntry(allocator: std.mem.Allocator, e: *const Config.ProfileEntry, owned: *std.ArrayList([]u8)) !Profile {
    // Validate even shadowed explicit settings: a script must not hide an
    // accidentally empty command. Manually constructed Configs use this too.
    for ([_]?[]const u8{ e.command, e.script, e.cwd }) |value| {
        if (value) |s| try validateLaunchValue(s);
    }
    const command = if (e.script) |script|
        resolveScript(allocator, script, owned) catch |err| {
            std.debug.print("error: profile '{s}' script '{s}' cannot launch ({}); fix the path/execute permission or remove profile.{s}.script\n", .{ e.name, script, err, e.name });
            return err;
        }
    else
        try ownOptional(allocator, owned, e.command);
    return .{
        .name = try own(allocator, owned, e.name),
        .command = command,
        .cwd = if (e.cwd) |cwd| try resolveCwd(allocator, cwd, owned) else null,
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
/// relative paths before changing cwd, then quote the entire literal path.
fn resolveScript(allocator: std.mem.Allocator, raw: []const u8, owned: *std.ArrayList([]u8)) ![]const u8 {
    const expanded = try expandHome(allocator, raw, owned);
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(platform.io(), expanded, allocator);
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
