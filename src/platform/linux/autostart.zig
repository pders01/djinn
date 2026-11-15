//! Autostart-at-login via XDG `.desktop` autostart entry.
//!
//! Linux equivalent of `src/system/loginitem.zig`'s SMAppService
//! wrapper. The freedesktop autostart spec
//! (https://specifications.freedesktop.org/autostart-spec/) defines eligible
//! `.desktop` entries in `$XDG_CONFIG_HOME/autostart/` (default
//! `$HOME/.config/autostart/`). Launch still depends on desktop/session
//! policy, disabled/conditional entries, and an autostart implementation.
//! We manage this entry only on explicit CLI/menu actions or config policy;
//! an absent open-at-login setting leaves existing OS state alone.
//!
//! The application launcher is packaged separately as
//! `share/applications/djinn.desktop`. An autostart entry controls login
//! launch; creating it is not a guarantee of portal app identity, stable
//! shortcut consent, or GlobalShortcuts support. Do not enable autostart
//! as a workaround for a missing portal implementation.
//!
//! Preserve the launcher's spelling (not its realpath): Nix's GTK wrapper
//! supplies required environment and must not be bypassed by /proc/self/exe.
//! Startup should supply argv[0] with setLauncherArgv0 before CLI actions.

const std = @import("std");
const platform = @import("../../io/platform.zig");

/// Mirrors `system/loginitem.zig`'s Status. Linux also returns `unknown`
/// for unreadable, malformed or desktop-conditional entries. The macOS-specific
/// `requires_approval` / `not_found` states have no analogue here
/// (no per-app consent UI in the linux autostart spec). The values
/// stay in the enum so cross-platform callers compile unchanged.
pub const Status = enum {
    not_registered,
    enabled,
    requires_approval,
    not_found,
    unknown,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .not_registered => "not registered or disabled",
            .enabled => "enabled (desktop entry; session policy still applies)",
            .requires_approval => "registered, awaiting user approval",
            .not_found => "not found",
            .unknown => "unknown",
        };
    }
};

pub const Error = error{
    NoHomeDir,
    OperationFailed,
    PolicyConflict,
    InvalidExecPath,
    LauncherUnavailable,
};

// Published centrally before startup sync and each accepted config reload.
var configured_policy: ?bool = null;
var launcher_argv0: ?[]const u8 = null;

pub fn setPolicy(value: ?bool) void {
    configured_policy = value;
}

pub fn policy() ?bool {
    return configured_policy;
}

pub fn checkRequest(enabled: bool) Error!void {
    if (configured_policy) |required| {
        if (enabled != required) return Error.PolicyConflict;
    }
}

pub fn policyConflict(actual: Status) bool {
    const required = configured_policy orelse return false;
    return if (required) actual != .enabled else actual != .not_registered;
}

pub fn syncPolicy(allocator: std.mem.Allocator) !void {
    const required = configured_policy orelse return;
    const actual = try status(allocator);
    if (required) {
        if (actual != .enabled) try register(allocator);
    } else if (actual != .not_registered) {
        try unregister(allocator);
    }
}

/// Borrowed for process lifetime; main must keep its Args iterator alive.
/// Call before skipping argv[0], including the early CLI action path.
pub fn setLauncherArgv0(value: ?[]const u8) void {
    launcher_argv0 = value;
}

/// Write `~/.config/autostart/djinn.desktop`. Creates the parent dir
/// if missing. Overwrites an existing file — the content is
/// deterministic, so a rewrite is a no-op as long as the binary
/// path hasn't moved.
pub fn register(allocator: std.mem.Allocator) !void {
    try checkRequest(true);
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    const exec_path = try resolveExePath(allocator);
    defer allocator.free(exec_path);
    try registerAt(allocator, path, exec_path);
}

/// Explicit destination/executable for safe fixtures. No environment reads.
fn registerAt(allocator: std.mem.Allocator, path: []const u8, exec_path: []const u8) !void {
    const io = platform.io();
    const exec = try encodeExecPath(allocator, exec_path);
    defer allocator.free(exec);
    const body = try std.fmt.allocPrint(allocator, desktop_template, .{exec});
    defer allocator.free(body);
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.OperationFailed;
    }

    // Atomic write: stage to `<path>.tmp`, then rename over `<path>`.
    // Crash between createFile and writeAll on the prior shape left
    // a zero-byte / partial djinn.desktop, which the user's DE
    // would then parse as a malformed entry and silently skip — and
    // the next launch's status() call sees the file and reports
    // "enabled" anyway. The .tmp + rename gives the directory only
    // ever the old-or-new state, never a torn intermediate.
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch
        return Error.OperationFailed;
    defer allocator.free(tmp_path);

    {
        const file = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch |err| {
            std.debug.print("autostart: create({s}) failed: {}\n", .{ tmp_path, err });
            return Error.OperationFailed;
        };
        defer file.close(io);
        file.writeStreamingAll(io, body) catch |err| {
            std.debug.print("autostart: write failed: {}\n", .{err});
            // Clean up the partial .tmp so we don't leave debris on
            // the next register attempt's rename target.
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return Error.OperationFailed;
        };
    }

    std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io) catch |err| {
        std.debug.print("autostart: rename({s} → {s}) failed: {}\n", .{ tmp_path, path, err });
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return Error.OperationFailed;
    };
}

/// Remove the autostart entry. ENOENT is treated as success — the
/// desired state ("djinn is NOT registered") matches, so reporting
/// the operation as having failed would be misleading.
pub fn unregister(allocator: std.mem.Allocator) !void {
    try checkRequest(false);
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    try unregisterAt(path);
}

fn unregisterAt(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(platform.io(), path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| {
            std.debug.print("autostart: delete({s}) failed: {}\n", .{ path, e });
            return Error.OperationFailed;
        },
    };
}

/// Read actual desktop-entry state, not configuration policy. Conditional
/// entries are unknown rather than claiming the current desktop will run them.
pub fn status(allocator: std.mem.Allocator) !Status {
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    return statusAt(path);
}

fn statusAt(path: []const u8) Status {
    const allocator = std.heap.page_allocator;
    const body = std.Io.Dir.cwd().readFileAlloc(platform.io(), path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .not_registered,
        else => return .unknown,
    };
    defer allocator.free(body);
    return statusFromDesktop(body);
}

fn statusFromDesktop(body: []const u8) Status {
    if (!std.unicode.utf8ValidateSlice(body) or std.mem.indexOfScalar(u8, body, 0) != null) return .unknown;
    var in_entry = false;
    var seen_entry = false;
    var kind: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var hidden: ?bool = null;
    var gnome_enabled: ?bool = null;
    var conditional = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            if (in_entry) {
                if (seen_entry) return .unknown;
                seen_entry = true;
            }
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .unknown;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Hidden")) {
            if (hidden != null) return .unknown;
            hidden = desktopBool(value) orelse return .unknown;
        } else if (std.mem.eql(u8, key, "X-GNOME-Autostart-enabled")) {
            if (gnome_enabled != null) return .unknown;
            gnome_enabled = desktopBool(value) orelse return .unknown;
        } else if (std.mem.eql(u8, key, "Type")) {
            if (kind != null) return .unknown;
            kind = value;
        } else if (std.mem.eql(u8, key, "Exec")) {
            if (exec != null) return .unknown;
            exec = value;
        } else if (std.mem.eql(u8, key, "OnlyShowIn") or std.mem.eql(u8, key, "NotShowIn") or
            std.mem.eql(u8, key, "TryExec") or std.mem.eql(u8, key, "AutostartCondition") or
            std.mem.eql(u8, key, "X-KDE-autostart-condition"))
        {
            conditional = true;
        }
    }
    if (!seen_entry) return .unknown;
    // Hidden tombstones can legitimately omit Type/Exec.
    if (hidden orelse false) return .not_registered;
    if (!std.mem.eql(u8, kind orelse return .unknown, "Application")) return .unknown;
    if (!validDesktopExec(exec orelse return .unknown)) return .unknown;
    if (conditional) return .unknown;
    // GNOME-specific opt-out is not portable to all desktops.
    if (!(gnome_enabled orelse true)) return .unknown;
    return .enabled;
}

// Validate the two escaping layers and common Exec syntax without running a
// shell or consulting a desktop. This does not promise the target still exists.
fn validDesktopExec(value: []const u8) bool {
    var decoded: [64 * 1024]u8 = undefined;
    if (value.len == 0 or value.len > decoded.len) return false;
    var length: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        var byte = value[i];
        if (byte == '\\') {
            i += 1;
            if (i == value.len) return false;
            byte = switch (value[i]) {
                '\\' => '\\',
                's' => ' ',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return false,
            };
        }
        decoded[length] = byte;
        length += 1;
    }
    var quoted = false;
    var escaped = false;
    var has_executable = false;
    i = 0;
    while (i < length) : (i += 1) {
        const byte = decoded[i];
        if (byte < 32 or byte == 127) return false;
        if (escaped) {
            escaped = false;
            has_executable = true;
        } else if (byte == '\\') {
            escaped = true;
        } else if (byte == '"') {
            quoted = !quoted;
        } else if (byte == '%') {
            i += 1;
            if (i == length or std.mem.indexOfScalar(u8, "%fFuUdDnNickvm", decoded[i]) == null) return false;
            has_executable = true;
        } else if (byte != ' ') {
            has_executable = true;
        }
    }
    return has_executable and !quoted and !escaped;
}

fn desktopBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// One literal executable argument. Exec quoting is NOT shell quoting:
/// escape reserved characters, then desktop-entry string backslashes.
fn encodeExecPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path) or
        std.mem.indexOfScalar(u8, path, '=') != null) return Error.InvalidExecPath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (path) |byte| {
        switch (byte) {
            0...31, 127 => return Error.InvalidExecPath,
            '\\' => try out.appendSlice(allocator, "\\\\\\\\"),
            '"', '$', '`' => {
                try out.appendSlice(allocator, "\\\\");
                try out.append(allocator, byte);
            },
            '%' => try out.appendSlice(allocator, "%%"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

// ─── Internals ───────────────────────────────────────────────────────

/// Resolve `$XDG_CONFIG_HOME/autostart/djinn.desktop`, with fallback
/// to `$HOME/.config/autostart/djinn.desktop` when XDG_CONFIG_HOME
/// is unset. Returned slice is allocator-owned.
fn desktopPath(allocator: std.mem.Allocator) ![]u8 {
    return desktopPathFor(allocator, platform.getenv("XDG_CONFIG_HOME"), platform.getenv("HOME"));
}

fn desktopPathFor(allocator: std.mem.Allocator, xdg_home: ?[]const u8, home_dir: ?[]const u8) ![]u8 {
    if (xdg_home) |xdg| {
        if (std.fs.path.isAbsolute(xdg)) {
            return std.fmt.allocPrint(allocator, "{s}/autostart/djinn.desktop", .{xdg});
        }
    }
    const home = home_dir orelse return Error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/autostart/djinn.desktop", .{home});
}

/// Keep a valid absolute argv[0], including symlinks and GTK wrappers.
/// Bare argv[0] is resolved once through absolute PATH directories. Only then
/// fall back to the kernel executable, and never persist a known wrapper's
/// internal .djinn-wrapped payload. No launcher is executed here.
fn resolveExePath(allocator: std.mem.Allocator) ![]u8 {
    // Preserve a relative wrapper invocation too. Resolve only the startup cwd,
    // never the launcher's symlink: realpath(argv[0]) can bypass its environment.
    if (launcher_argv0) |original| {
        if (!std.fs.path.isAbsolute(original) and std.mem.indexOfScalar(u8, original, '/') != null) {
            const cwd = try std.Io.Dir.cwd().realPathFileAlloc(platform.io(), ".", allocator);
            defer allocator.free(cwd);
            const absolute = try relativeLauncherPath(allocator, cwd, original);
            defer allocator.free(absolute);
            return resolveLauncher(allocator, absolute, platform.getenv("PATH"), null);
        }
    }
    return resolveLauncher(allocator, launcher_argv0, platform.getenv("PATH"), null);
}

fn relativeLauncherPath(allocator: std.mem.Allocator, cwd: []const u8, original: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{ cwd, original });
}

test "autostart relative wrapper keeps its spelling under the startup directory" {
    const a = std.testing.allocator;
    const path = try relativeLauncherPath(a, "/fixture/start", "./wrapped/bin/djinn");
    defer a.free(path);
    try std.testing.expectEqualStrings("/fixture/start/wrapped/bin/djinn", path);
}

fn resolveLauncher(allocator: std.mem.Allocator, argv0: ?[]const u8, search_path: ?[]const u8, fallback: ?[]const u8) ![]u8 {
    if (argv0) |original| {
        if (std.fs.path.isAbsolute(original)) {
            if (isWrappedPayload(original)) {
                // Some wrappers don't preserve argv[0]. Prefer their adjacent
                // public launcher, never the environment-dependent payload.
                const wrapper = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(original).?, "djinn" });
                if (validLauncher(wrapper)) return wrapper;
                allocator.free(wrapper);
            } else if (validLauncher(original)) return allocator.dupe(u8, original);
        } else if (std.mem.indexOfScalar(u8, original, '/') == null and original.len > 0 and !isWrappedPayload(original)) {
            if (try launcherOnPath(allocator, search_path, original)) |found| return found;
        }
    }
    if (try launcherOnPath(allocator, search_path, "djinn")) |found| return found;
    const owned = if (fallback == null) platform.executablePathAlloc(allocator) catch return Error.LauncherUnavailable else null;
    defer if (owned) |path| allocator.free(path);
    const path = stripDeletedAnnotation(fallback orelse owned.?);
    if (std.mem.startsWith(u8, std.fs.path.basename(path), ".") or !validLauncher(path)) return Error.LauncherUnavailable;
    return allocator.dupe(u8, path);
}

fn launcherOnPath(allocator: std.mem.Allocator, search_path: ?[]const u8, name: []const u8) !?[]u8 {
    var dirs = std.mem.splitScalar(u8, search_path orelse return null, ':');
    while (dirs.next()) |dir| {
        // Ignore cwd-dependent entries: login won't share this working dir.
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (validLauncher(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn isWrappedPayload(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.mem.eql(u8, name, ".djinn-wrapped") or std.mem.startsWith(u8, name, ".djinn-wrapped-");
}

fn validLauncher(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    const io = platform.io();
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Trim the trailing ` (deleted)` annotation kernels append when the
/// exe inode has been unlinked since process start.
fn stripDeletedAnnotation(target: []const u8) []const u8 {
    const tail = " (deleted)";
    if (std.mem.endsWith(u8, target, tail)) {
        return target[0 .. target.len - tail.len];
    }
    return target;
}

test "stripDeletedAnnotation: trailing annotation removed" {
    try std.testing.expectEqualStrings(
        "/usr/bin/djinn",
        stripDeletedAnnotation("/usr/bin/djinn (deleted)"),
    );
}

test "stripDeletedAnnotation: clean path untouched" {
    try std.testing.expectEqualStrings(
        "/usr/local/bin/djinn",
        stripDeletedAnnotation("/usr/local/bin/djinn"),
    );
}

/// `.desktop` content. `{s}` is an encoded, quoted absolute launcher path.
///
/// Categories spelling: per the freedesktop menu spec, `Utility` is
/// the broad bucket; `TerminalEmulator` is the canonical sub-category
/// every DE recognizes for "looks like a terminal" apps.
///
/// `X-GNOME-Autostart-enabled=true` is GNOME-specific but harmless on
/// other DEs — every parser that doesn't recognize the key skips it.
/// `Hidden=false` is an explicit opt-in; absent Hidden also means false.
const desktop_template =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=djinn
    \\Comment=Drop-down terminal panel
    \\Exec={s}
    \\Icon=utilities-terminal
    \\Terminal=false
    \\Categories=Utility;TerminalEmulator;
    \\StartupNotify=false
    \\X-GNOME-Autostart-enabled=true
    \\Hidden=false
    \\
;

// ─── Tests ───────────────────────────────────────────────────────────

test "Autostart native API compiles without accessing personal files" {
    std.testing.refAllDecls(@This());
}

test "desktopPath honors injected XDG_CONFIG_HOME and HOME fallback" {
    const a = std.testing.allocator;
    const path = try desktopPathFor(a, "/fixture/config", "/fixture/home");
    defer a.free(path);
    try std.testing.expectEqualStrings("/fixture/config/autostart/djinn.desktop", path);
    for ([_]?[]const u8{ null, "", "relative" }) |xdg| {
        const fallback = try desktopPathFor(a, xdg, "/fixture/home");
        defer a.free(fallback);
        try std.testing.expectEqualStrings("/fixture/home/.config/autostart/djinn.desktop", fallback);
    }
    try std.testing.expectError(Error.NoHomeDir, desktopPathFor(a, null, null));
}

test "autostart register, replace, status and unregister use only a temp fixture" {
    const a = std.testing.allocator;
    const io = platform.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "config/autostart/djinn.desktop" });
    defer a.free(path);
    try std.testing.expectEqual(Status.not_registered, statusAt(path));
    try registerAt(a, path, "/fixture/bin/djinn");
    try std.testing.expectEqual(Status.enabled, statusAt(path));
    try registerAt(a, path, "/fixture/replaced/djinn");
    const body = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8192));
    defer a.free(body);
    const expected = try std.fmt.allocPrint(a, desktop_template, .{"\"/fixture/replaced/djinn\""});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, body);
    const staged = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer a.free(staged);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, staged, .{}));
    try unregisterAt(path);
    try unregisterAt(path);
    try std.testing.expectEqual(Status.not_registered, statusAt(path));
}

test "autostart policy models startup, restart, reload and conflicting actions without OS calls" {
    defer setPolicy(null);
    setPolicy(null);
    try checkRequest(true);
    // A user enable persists through restart with absent config: no sync IO.
    try syncPolicy(std.testing.allocator);
    setPolicy(null);
    try std.testing.expect(!policyConflict(.enabled));
    try checkRequest(false);
    setPolicy(true);
    try checkRequest(true);
    try std.testing.expectError(Error.PolicyConflict, checkRequest(false));
    try std.testing.expect(policyConflict(.not_registered));
    try std.testing.expect(policyConflict(.unknown));
    setPolicy(false);
    try std.testing.expectError(Error.PolicyConflict, checkRequest(true));
    try checkRequest(false);
    try std.testing.expect(policyConflict(.enabled));
    setPolicy(null);
    try checkRequest(true);
    try checkRequest(false);
}

test "autostart status parses Hidden false, tombstones, malformed and conditional entries" {
    const base = "[Desktop Entry]\nType=Application\nExec=\"/fixture/djinn\"\n";
    try std.testing.expectEqual(Status.enabled, statusFromDesktop(base));
    try std.testing.expectEqual(Status.enabled, statusFromDesktop(base ++ "Hidden=false\nX-GNOME-Autostart-enabled=true\n"));
    try std.testing.expectEqual(Status.not_registered, statusFromDesktop("[Desktop Entry]\nHidden=true\n"));
    for ([_][]const u8{
        "",                                                            "[Other]\nHidden=false\n",             "[Desktop Entry]\nType=Application\n",
        base ++ "Hidden=FALSE\n",                                      base ++ "Hidden=false\nHidden=true\n", base ++ "OnlyShowIn=GNOME;\n",
        base ++ "NotShowIn=KDE;\n",                                    base ++ "TryExec=/fixture/missing\n",  base ++ "AutostartCondition=foo\n",
        base ++ "X-GNOME-Autostart-enabled=false\n",                   base ++ "[Desktop Entry]\n",           "[Desktop Entry]\nType=Application\nExec=\"unterminated\n",
        "[Desktop Entry]\nType=Application\nExec=/fixture/invalid%\n",
    }) |body| try std.testing.expectEqual(Status.unknown, statusFromDesktop(body));
    // Only the primary group controls autostart, never desktop action groups.
    try std.testing.expectEqual(Status.enabled, statusFromDesktop(base ++ "[Desktop Action Test]\nHidden=true\n"));
}

test "autostart Exec encodes both desktop escaping layers literally" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "/fixture/bin/djinn", "\"/fixture/bin/djinn\"" },
        .{ "/fixture/a b/djinn", "\"/fixture/a b/djinn\"" },
        .{ "/fixture/a\"b", "\"/fixture/a\\\\\"b\"" },
        .{ "/fixture/a\\b", "\"/fixture/a\\\\\\\\b\"" },
        .{ "/fixture/%f%/djinn", "\"/fixture/%%f%%/djinn\"" },
        .{ "/fixture/$a`b'c", "\"/fixture/\\\\$a\\\\`b'c\"" },
    };
    inline for (cases) |case| {
        const encoded = try encodeExecPath(a, case[0]);
        defer a.free(encoded);
        try std.testing.expectEqualStrings(case[1], encoded);
        try std.testing.expect(validDesktopExec(encoded));
    }
    for ([_][]const u8{ "relative", "/fixture/a\nb", "/fixture/a\rb", "/fixture/a\x00b", "/fixture/a=b" }) |invalid|
        try std.testing.expectError(Error.InvalidExecPath, encodeExecPath(a, invalid));
}

test "autostart launcher keeps absolute argv0 and PATH wrappers in temporary fixtures" {
    const a = std.testing.allocator;
    const io = platform.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    for ([_][]const u8{ "djinn", ".djinn-wrapped", "explicit wrapper" }) |name| {
        const file = try tmp.dir.createFile(io, name, .{ .permissions = .fromMode(0o700) });
        defer file.close(io);
        // Fixture is never executed, only checked for executable permissions.
        try file.writeStreamingAll(io, "#!/bin/sh\nexport FIXTURE_WRAPPER=1\n");
    }
    const wrapper = try std.fs.path.join(a, &.{ root, "djinn" });
    defer a.free(wrapper);
    const original = try std.fs.path.join(a, &.{ root, "explicit wrapper" });
    defer a.free(original);
    const internal = try std.fs.path.join(a, &.{ root, ".djinn-wrapped" });
    defer a.free(internal);
    const from_original = try resolveLauncher(a, original, root, internal);
    defer a.free(from_original);
    try std.testing.expectEqualStrings(original, from_original);
    const from_internal_argv = try resolveLauncher(a, internal, "", internal);
    defer a.free(from_internal_argv);
    try std.testing.expectEqualStrings(wrapper, from_internal_argv);
    try tmp.dir.symLink(io, "djinn", "distro-launcher", .{});
    const symlink = try std.fs.path.join(a, &.{ root, "distro-launcher" });
    defer a.free(symlink);
    const from_symlink = try resolveLauncher(a, symlink, root, internal);
    defer a.free(from_symlink);
    try std.testing.expectEqualStrings(symlink, from_symlink);
    const from_path = try resolveLauncher(a, "djinn", root, internal);
    defer a.free(from_path);
    try std.testing.expectEqualStrings(wrapper, from_path);
    const without_argv = try resolveLauncher(a, null, root, internal);
    defer a.free(without_argv);
    try std.testing.expectEqualStrings(wrapper, without_argv);
    try std.testing.expectError(Error.LauncherUnavailable, resolveLauncher(a, null, "relative::.", internal));
    const body_path = try std.fs.path.join(a, &.{ root, "autostart/djinn.desktop" });
    defer a.free(body_path);
    try registerAt(a, body_path, original);
    try std.testing.expectEqual(Status.enabled, statusAt(body_path));
    // Rejected encoding leaves the existing entry intact.
    try std.testing.expectError(Error.InvalidExecPath, registerAt(a, body_path, "/bad\npath"));
    try std.testing.expectEqual(Status.enabled, statusAt(body_path));
}

test "Status.label covers every case" {
    const cases = [_]Status{
        .not_registered,
        .enabled,
        .requires_approval,
        .not_found,
        .unknown,
    };
    for (cases) |s| {
        try std.testing.expect(s.label().len > 0);
    }
}
