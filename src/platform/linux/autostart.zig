//! Autostart-at-login via XDG `.desktop` autostart entry.
//!
//! Linux equivalent of `src/system/loginitem.zig`'s SMAppService
//! wrapper. The freedesktop autostart spec
//! (https://specifications.freedesktop.org/autostart-spec/) says every
//! `.desktop` file in `$XDG_CONFIG_HOME/autostart/` (default
//! `$HOME/.config/autostart/`) gets launched at session start by
//! every spec-compliant session (KDE Plasma, GNOME, XFCE, MATE,
//! LXDE/LXQt, sway/Hyprland via xdg-autostart-generator, …). We just
//! drop or remove the file; no D-Bus, no daemon, no per-DE quirks.
//!
//! The file also doubles as the app-identity anchor the portal-based
//! hotkey needs for stable BindShortcuts approvals on KDE. KDE's
//! portal pegs its remembered consent to whatever `.desktop` id the
//! caller can be matched against; without one, every relaunch can
//! retrigger the consent prompt. Writing this file fixes the issue
//! noted in TODO.md's Known Issues even when the user has
//! `open-at-login=false` — but we only write the autostart entry
//! when the config opts in, so the side effect only kicks in when
//! the user has explicitly enabled autostart. A future task can
//! split the .desktop install (always, into XDG_DATA_HOME/applications)
//! from the autostart symlink/entry (conditional, into autostart/).
//!
//! Exec= path derivation: `/proc/self/exe` is the kernel-resolved
//! absolute path of the running binary. That's the right Exec value
//! — `$PATH` lookup for "djinn" would launch whatever bare-name
//! `djinn` resolves to at session-start time, which can drift if the
//! user has a system install AND a dev build.

const std = @import("std");
const platform = @import("../../io/platform.zig");

/// Mirrors `system/loginitem.zig`'s Status. Linux only ever returns
/// `not_registered` or `enabled` — the macOS-specific
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
            .not_registered => "not registered",
            .enabled => "enabled (will launch at session start)",
            .requires_approval => "registered, awaiting user approval",
            .not_found => "not found",
            .unknown => "unknown",
        };
    }
};

pub const Error = error{
    NoHomeDir,
    OperationFailed,
};

/// Write `~/.config/autostart/djinn.desktop`. Creates the parent dir
/// if missing. Overwrites an existing file — the content is
/// deterministic, so a rewrite is a no-op as long as the binary
/// path hasn't moved.
pub fn register(allocator: std.mem.Allocator) !void {
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    const exec_path = try resolveExePath(allocator);
    defer allocator.free(exec_path);
    try registerAt(allocator, path, exec_path);
}

/// Explicit destination/executable for safe fixtures. No environment reads.
fn registerAt(allocator: std.mem.Allocator, path: []const u8, exec_path: []const u8) !void {
    const io = platform.io();
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.OperationFailed;
    }
    const body = try std.fmt.allocPrint(allocator, desktop_template, .{exec_path});
    defer allocator.free(body);

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

/// Read the current state. Truthful but coarse: any existing file
/// counts as `enabled`. We don't parse the `Hidden=true` /
/// `X-GNOME-Autostart-enabled=false` opt-out keys; an entry edited
/// outside djinn can therefore be present but disabled by the DE.
pub fn status(allocator: std.mem.Allocator) !Status {
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    return statusAt(path);
}

fn statusAt(path: []const u8) Status {
    std.Io.Dir.cwd().access(platform.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_registered,
        else => return .unknown,
    };
    return .enabled;
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

/// Read `/proc/self/exe`'s symlink target. Allocator owns the
/// returned slice. Bounded at 4096 bytes — PATH_MAX on linux.
///
/// Linux appends ` (deleted)` to the link target when the underlying
/// inode has been unlinked while the process is still running —
/// happens routinely on a package update mid-session (pacman / apt
/// replace the binary by unlink + create). The annotation is part
/// of the readlink output, not just `/proc/self/status` — it would
/// land in the .desktop's `Exec=` and the autostart entry would
/// silently fail at the next login.
fn resolveExePath(allocator: std.mem.Allocator) ![]u8 {
    const path = platform.executablePathAlloc(allocator) catch return Error.OperationFailed;
    defer allocator.free(path);
    return allocator.dupe(u8, stripDeletedAnnotation(path));
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

/// `.desktop` content. `{s}` is the absolute binary path.
///
/// Categories spelling: per the freedesktop menu spec, `Utility` is
/// the broad bucket; `TerminalEmulator` is the canonical sub-category
/// every DE recognizes for "looks like a terminal" apps.
///
/// `X-GNOME-Autostart-enabled=true` is GNOME-specific but harmless on
/// other DEs — every parser that doesn't recognize the key skips it.
/// `Hidden=false` is the explicit opt-in (some session managers
/// short-circuit on a missing `Hidden` to "hidden", which is the
/// opposite of what we want).
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
    const expected = try std.fmt.allocPrint(a, desktop_template, .{"/fixture/replaced/djinn"});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, body);
    const staged = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer a.free(staged);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, staged, .{}));
    try unregisterAt(path);
    try unregisterAt(path);
    try std.testing.expectEqual(Status.not_registered, statusAt(path));
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
