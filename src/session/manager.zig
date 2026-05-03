const std = @import("std");
const Config = @import("../config.zig").Config;

/// Resolved profile — config defaults applied, ready to spawn. The
/// session layer hands one of these to the Cocoa wiring (in main.zig)
/// when a surface needs to be created. UI layers (keybind switcher
/// today, tab strip / palette later) only see profile names + active
/// index; they don't reach into the spawn payload.
pub const Profile = struct {
    name: []const u8,
    /// Effective command to spawn. Already resolved through provider
    /// shortcut → command mapping, so the caller hands this to ghostty
    /// without further interpretation.
    command: []const u8,
    /// Working directory for the spawned process. Null = inherit
    /// caller's cwd (typically $HOME after djinn's startup chdir).
    cwd: ?[]const u8 = null,
    /// Display label for the menubar / log-pane indicator. Falls back
    /// to `name` when unset.
    title: ?[]const u8 = null,

    pub fn label(self: Profile) []const u8 {
        return self.title orelse self.name;
    }
};

/// One running (or pending) provider instance. The opaque handles let
/// this module stay free of Cocoa + ghostty.h imports — the caller in
/// main.zig casts them back when binding / hiding the surface.
pub const Session = struct {
    profile: Profile,
    /// `?*anyopaque` slot for the ghostty surface (`ghostty_surface_t`).
    /// Null until the session is first activated (lazy spawn).
    surface: ?*anyopaque = null,
    /// `?*anyopaque` slot for the surface_host NSView. Always non-null
    /// after `init` — the host view is created eagerly so layout math
    /// can size it before the surface binds.
    surface_host: ?*anyopaque = null,
    /// True after the first `activate(idx)` call wired a surface to the
    /// host. The caller checks this and only spawns once.
    spawned: bool = false,
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: []Session,
    /// Index into `sessions` for the currently visible surface. Never
    /// out of bounds — `init` ensures at least one session exists.
    active_idx: usize = 0,

    /// Build a SessionManager from the parsed config. When the config
    /// declares no profiles, synthesize a single profile from the flat
    /// `provider` / `provider-command` keys so legacy configs keep
    /// working unchanged.
    pub fn init(allocator: std.mem.Allocator, cfg: *const Config) !SessionManager {
        var sessions = std.ArrayList(Session){};
        errdefer sessions.deinit(allocator);

        if (cfg.profiles.entries.len == 0) {
            // Legacy single-profile path. Synthesize "default" from the
            // flat keys; matches today's behavior bit-for-bit.
            try sessions.append(allocator, .{
                .profile = .{
                    .name = "default",
                    .command = cfg.getProviderCommand(),
                },
            });
        } else {
            for (cfg.profiles.entries) |e| {
                // Per-profile provider / command resolution. If the
                // profile sets `command`, use it verbatim. Else map
                // `provider` through the same shortcut table the flat
                // path uses (claude / codex / aider / gemini /
                // opencode / crush / pi → exact name; anything else
                // → /bin/zsh).
                const cmd = if (e.command) |c| c else providerCommand(e.provider orelse "generic");
                try sessions.append(allocator, .{
                    .profile = .{
                        .name = e.name,
                        .command = cmd,
                        .cwd = e.cwd,
                        .title = e.title,
                    },
                });
            }
        }

        var mgr: SessionManager = .{
            .allocator = allocator,
            .sessions = try sessions.toOwnedSlice(allocator),
            .active_idx = 0,
        };

        // Resolve `default-profile` into an index. Unknown names fall
        // through to index 0 with a warning so the user gets feedback
        // instead of a silent fallback.
        if (cfg.profiles.default) |name| {
            if (mgr.indexOf(name)) |idx| {
                mgr.active_idx = idx;
            } else {
                std.debug.print("warning: default-profile '{s}' not defined; using '{s}'\n", .{ name, mgr.sessions[0].profile.name });
            }
        }

        return mgr;
    }

    pub fn deinit(self: *SessionManager) void {
        self.allocator.free(self.sessions);
    }

    pub fn active(self: *SessionManager) *Session {
        return &self.sessions[self.active_idx];
    }

    pub fn count(self: *const SessionManager) usize {
        return self.sessions.len;
    }

    pub fn indexOf(self: *const SessionManager, name: []const u8) ?usize {
        for (self.sessions, 0..) |s, i| {
            if (std.mem.eql(u8, s.profile.name, name)) return i;
        }
        return null;
    }

    /// Switch to the session at `idx`. No-op if `idx` is out of bounds
    /// or already active. Returns true when a switch actually
    /// happened — callers use this to gate the (expensive) Cocoa
    /// reflow + setHidden setHidden:0 work.
    pub fn switchTo(self: *SessionManager, idx: usize) bool {
        if (idx >= self.sessions.len) return false;
        if (idx == self.active_idx) return false;
        self.active_idx = idx;
        return true;
    }

    pub fn next(self: *SessionManager) bool {
        const idx = self.peekNext() orelse return false;
        return self.switchTo(idx);
    }

    pub fn prev(self: *SessionManager) bool {
        const idx = self.peekPrev() orelse return false;
        return self.switchTo(idx);
    }

    /// Index of the would-be active session after `next()` / `prev()`,
    /// without mutating state. Returns null when there's nothing to
    /// cycle to (single-session setup). UI layers use these to compute
    /// a target index, then hand it to the Cocoa-side `activateSession`
    /// so the modular arithmetic lives in one place.
    pub fn peekNext(self: *const SessionManager) ?usize {
        if (self.sessions.len <= 1) return null;
        return (self.active_idx + 1) % self.sessions.len;
    }

    pub fn peekPrev(self: *const SessionManager) ?usize {
        if (self.sessions.len <= 1) return null;
        return if (self.active_idx == 0) self.sessions.len - 1 else self.active_idx - 1;
    }
};

/// Map provider name → spawn command. Mirrors `Config.getProviderCommand`'s
/// table; broken out so SessionManager can resolve per-profile providers
/// without going through the Config singleton.
fn providerCommand(name: []const u8) []const u8 {
    const map = .{
        .{ "claude", "claude" },
        .{ "codex", "codex" },
        .{ "aider", "aider" },
        .{ "gemini", "gemini" },
        .{ "opencode", "opencode" },
        .{ "crush", "crush" }, // charmbracelet/crush
        .{ "pi", "pi" }, // Pi AI CLI
    };
    inline for (map) |entry| {
        if (eqIgnoreCase(name, entry[0])) return entry[1];
    }
    // Same fallback rationale as Config.getProviderCommand: prefer
    // /bin/zsh over $SHELL; nix dev shells set $SHELL to a sandboxed
    // bash with broken terminfo.
    return "/bin/zsh";
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// Tests --------------------------------------------------------------

test "SessionManager: legacy single-profile path" {
    var cfg = Config{};
    cfg.provider.name = "claude";
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    try std.testing.expectEqualStrings("default", mgr.active().profile.name);
    try std.testing.expectEqualStrings("claude", mgr.active().profile.command);
}

test "SessionManager: profiles + default selection" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "main", .provider = "claude" },
        .{ .name = "side", .provider = "codex" },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;
    cfg.profiles.default = "side";

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqual(@as(usize, 2), mgr.count());
    try std.testing.expectEqualStrings("side", mgr.active().profile.name);
    try std.testing.expectEqualStrings("codex", mgr.active().profile.command);
}

test "SessionManager: command override beats provider shortcut" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "x", .provider = "claude", .command = "/opt/bin/my-claude" },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings("/opt/bin/my-claude", mgr.active().profile.command);
}

test "SessionManager: unknown default-profile falls back to 0" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "main", .provider = "claude" },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;
    cfg.profiles.default = "missing";

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_idx);
}

test "SessionManager: switchTo / next / prev arithmetic" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "a" },
        .{ .name = "b" },
        .{ .name = "c" },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expect(mgr.switchTo(2));
    try std.testing.expectEqualStrings("c", mgr.active().profile.name);
    try std.testing.expect(!mgr.switchTo(2)); // already active
    try std.testing.expect(!mgr.switchTo(99)); // out of bounds
    try std.testing.expect(mgr.next()); // c -> a (wrap)
    try std.testing.expectEqualStrings("a", mgr.active().profile.name);
    try std.testing.expect(mgr.prev()); // a -> c (wrap)
    try std.testing.expectEqualStrings("c", mgr.active().profile.name);
}

test "SessionManager: profile.label falls back to name" {
    var p = Profile{ .name = "main", .command = "claude" };
    try std.testing.expectEqualStrings("main", p.label());
    p.title = "Main Repo";
    try std.testing.expectEqualStrings("Main Repo", p.label());
}
