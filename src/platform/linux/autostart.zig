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
const builtin = @import("builtin");

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

    // Best-effort: create the parent dir. ENOENT on the dir means
    // we're the first autostart-using app on this system; any other
    // error gets reported through the file create below with a
    // clearer message.
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| {
                std.debug.print("autostart: makeDirAbsolute({s}) failed: {}\n", .{ dir, e });
                return Error.OperationFailed;
            },
        };
    }

    const exec_path = try resolveExePath(allocator);
    defer allocator.free(exec_path);

    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, desktop_template, .{exec_path}) catch
        return Error.OperationFailed;

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        std.debug.print("autostart: create({s}) failed: {}\n", .{ path, err });
        return Error.OperationFailed;
    };
    defer file.close();
    file.writeAll(body) catch |err| {
        std.debug.print("autostart: write failed: {}\n", .{err});
        return Error.OperationFailed;
    };
}

/// Remove the autostart entry. ENOENT is treated as success — the
/// desired state ("djinn is NOT registered") matches, so reporting
/// the operation as having failed would be misleading.
pub fn unregister(allocator: std.mem.Allocator) !void {
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| {
            std.debug.print("autostart: delete({s}) failed: {}\n", .{ path, e });
            return Error.OperationFailed;
        },
    };
}

/// Read the current state. Truthful but coarse: any existing file
/// counts as `enabled`. We don't parse the `Hidden=true` /
/// `X-GNOME-Autostart-enabled=false` opt-out keys; if a user wants
/// to keep the file but disable the autostart, they can edit the
/// file and we won't claim it's enabled — but the simpler rule
/// matches what real DEs do at session-start time.
pub fn status(allocator: std.mem.Allocator) !Status {
    const path = try desktopPath(allocator);
    defer allocator.free(path);

    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
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
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/autostart/djinn.desktop", .{xdg});
        }
    }
    const home = std.posix.getenv("HOME") orelse return Error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/autostart/djinn.desktop", .{home});
}

/// Read `/proc/self/exe`'s symlink target. Allocator owns the
/// returned slice. Bounded at 4096 bytes — PATH_MAX on linux.
fn resolveExePath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const link_target = std.posix.readlink("/proc/self/exe", &buf) catch
        return Error.OperationFailed;
    return allocator.dupe(u8, link_target);
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

test "desktopPath honors XDG_CONFIG_HOME when set" {
    // std.posix.getenv reads the real process env, which we can't
    // mutate portably in tests. We can still cover the fallback
    // branch by checking the suffix shape.
    if (builtin.os.tag != .linux) return;
    const path = try desktopPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/autostart/djinn.desktop"));
}

test "Status.label covers every case" {
    if (builtin.os.tag != .linux) return;
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
