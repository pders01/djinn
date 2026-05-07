const std = @import("std");
const Config = @import("../config.zig").Config;

/// Resolved profile — config defaults applied, ready to spawn. The
/// session layer hands one of these to the Cocoa wiring (in main.zig)
/// when a surface needs to be created. UI layers (keybind switcher
/// today, tab strip / palette later) only see profile names + active
/// index; they don't reach into the spawn payload.
pub const Profile = struct {
    name: []const u8,
    /// Effective command to spawn. Already resolved through the
    /// `script` > `command` > `provider` shortcut chain, so the
    /// caller hands this to ghostty without further interpretation.
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
    /// True after the child process exits. The tab strip can use this
    /// to show a restart hint; Cmd+R / Cmd+Shift+R restarts the session.
    exited: bool = false,
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: []Session,
    /// Index into `sessions` for the currently visible surface. Never
    /// out of bounds — `init` ensures at least one session exists.
    active_idx: usize = 0,
    /// Strings the manager allocated during resolve (e.g. tilde-
    /// expanded script paths). Freed in `deinit` so callers don't
    /// have to track each allocation separately.
    owned_strings: std.ArrayList([]u8) = .{},

    /// Build a SessionManager from the parsed config. When the config
    /// declares no profiles, synthesize a single profile from the flat
    /// `provider` / `provider-command` keys so legacy configs keep
    /// working unchanged.
    pub fn init(allocator: std.mem.Allocator, cfg: *const Config) !SessionManager {
        var sessions = std.ArrayList(Session){};
        errdefer sessions.deinit(allocator);

        var owned: std.ArrayList([]u8) = .{};
        errdefer {
            for (owned.items) |s| allocator.free(s);
            owned.deinit(allocator);
        }

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
                try sessions.append(allocator, .{ .profile = resolveEntry(allocator, &e, &owned) });
            }
        }

        var mgr: SessionManager = .{
            .allocator = allocator,
            .sessions = try sessions.toOwnedSlice(allocator),
            .active_idx = 0,
            .owned_strings = owned,
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
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
    }

    /// Append a new Session resolved from `entry`. Used by hot-config-
    /// reload's profile diff to add a profile at runtime. The returned
    /// pointer is valid until the next mutation (callers should fill
    /// `surface_host` immediately, then drop the pointer — re-fetch
    /// via index for any later access).
    pub fn appendEntry(self: *SessionManager, entry: Config.ProfileEntry) !*Session {
        const profile = resolveEntry(self.allocator, &entry, &self.owned_strings);
        const new_len = self.sessions.len + 1;
        self.sessions = try self.allocator.realloc(self.sessions, new_len);
        self.sessions[new_len - 1] = .{ .profile = profile };
        return &self.sessions[new_len - 1];
    }

    /// Pop the session at `idx`, shifting tail entries down. Returns
    /// the removed Session by value so the caller can free its
    /// ghostty surface + surface_host NSView outside this module
    /// (lifecycle of those handles isn't owned here). Adjusts
    /// `active_idx` so it keeps pointing at the *same* logical
    /// session it pointed at before — caller is responsible for
    /// driving the visible-surface switch via `switchTo` *before*
    /// removing the active entry; otherwise active_idx gets
    /// clamped into the new bounds and the still-resident surface
    /// pointer mismatches what the UI shows.
    pub fn removeAt(self: *SessionManager, idx: usize) ?Session {
        if (idx >= self.sessions.len) return null;
        const removed = self.sessions[idx];
        if (idx + 1 < self.sessions.len) {
            std.mem.copyForwards(
                Session,
                self.sessions[idx .. self.sessions.len - 1],
                self.sessions[idx + 1 ..],
            );
        }
        const new_len = self.sessions.len - 1;
        if (new_len == 0) {
            self.allocator.free(self.sessions);
            self.sessions = &.{};
        } else {
            // realloc-shrink is allowed to fail; the original slice
            // still owns `new_len` valid Sessions (we already shifted),
            // so on failure we reslice in place and accept a small
            // over-allocation until the next mutation.
            self.sessions = self.allocator.realloc(self.sessions, new_len) catch self.sessions[0..new_len];
        }
        // Adjust active_idx to track the same logical session.
        // Removed below active → tail shifted down by 1.
        // Removed at active → caller should have switched first; clamp
        //   to len-1 as a last-resort safety net.
        // Removed above active → no change.
        if (idx < self.active_idx) {
            self.active_idx -= 1;
        } else if (idx == self.active_idx and self.active_idx >= self.sessions.len and self.sessions.len > 0) {
            self.active_idx = self.sessions.len - 1;
        }
        return removed;
    }

    /// Re-point a profile's display fields (`title`, `cwd`) without
    /// touching the spawn-side state. Used by hot-config-reload when
    /// a matched-by-name profile entry has only display-affecting
    /// changes — no surface restart needed. The slices must outlive
    /// the SessionManager (config strings leak on reload, so pointers
    /// into the new Config remain valid for the process).
    pub fn updateProfileDisplay(self: *SessionManager, idx: usize, title: ?[]const u8, cwd: ?[]const u8) void {
        if (idx >= self.sessions.len) return;
        self.sessions[idx].profile.title = title;
        self.sessions[idx].profile.cwd = cwd;
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

/// Resolve a `ProfileEntry` (parsed from config) into a runtime
/// `Profile`. Spawn-command precedence: `script` > `command` >
/// `provider` shortcut > /bin/zsh fallback. Script paths run through
/// `resolveScript` which expands `~/` and verifies execute-bit; on
/// failure the resolution warns and falls through, so a typo in
/// `script` doesn't break the whole profile — the user still gets a
/// working terminal. Tilde-expanded paths are appended to `owned`
/// so the manager frees them on deinit.
fn resolveEntry(
    allocator: std.mem.Allocator,
    e: *const Config.ProfileEntry,
    owned: *std.ArrayList([]u8),
) Profile {
    const cmd = blk: {
        if (e.script) |s| {
            if (resolveScript(allocator, s, owned)) |path| break :blk path else |err| {
                std.debug.print(
                    "warning: profile '{s}' script '{s}' unusable ({}); falling back\n",
                    .{ e.name, s, err },
                );
            }
        }
        if (e.command) |c| break :blk c;
        break :blk providerCommand(e.provider orelse "generic");
    };
    return .{
        .name = e.name,
        .command = cmd,
        .cwd = e.cwd,
        .title = e.title,
    };
}

/// Expand a leading `~/` against `$HOME`, then stat the file and
/// verify it's executable. Returns the resolved (possibly newly
/// allocated) path on success; the path is appended to `owned` so
/// SessionManager.deinit can free it. On any failure (missing $HOME
/// for tilde, file not found, not executable) returns the underlying
/// error and the caller falls through to the next spawn-command
/// layer.
fn resolveScript(
    allocator: std.mem.Allocator,
    raw: []const u8,
    owned: *std.ArrayList([]u8),
) ![]const u8 {
    const path: []const u8 = if (std.mem.startsWith(u8, raw, "~/")) blk: {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        const expanded = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw[2..] });
        // Hand off ownership to `owned` immediately. A function-scope
        // `errdefer allocator.free(expanded)` would still fire after
        // a later error (e.g. statFile below), and the caller's
        // errdefer drains `owned` on the same error → double-free.
        owned.append(allocator, expanded) catch |e| {
            allocator.free(expanded);
            return e;
        };
        break :blk expanded;
    } else raw;

    // Stat checks both existence and accessibility. The `IXUSR | IXGRP
    // | IXOTH` mask catches "file is there but the user forgot
    // chmod +x" — the most common script setup mistake.
    const stat = try std.fs.cwd().statFile(path);
    if (stat.kind != .file) return error.NotARegularFile;
    if (stat.mode & 0o111 == 0) return error.NotExecutable;
    return path;
}

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

test "SessionManager: script wins over command + provider" {
    // Use the build's own zig binary as a known-executable file.
    // Picking something stable across nix shell + host shell so the
    // test isn't sensitive to which env runs it.
    const tmp_path = try makeTempExecutable(std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const entries = [_]Config.ProfileEntry{
        .{
            .name = "main",
            .provider = "claude",
            .command = "/opt/bin/my-claude",
            .script = tmp_path,
        },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings(tmp_path, mgr.active().profile.command);
}

test "SessionManager: missing script falls through to command" {
    const entries = [_]Config.ProfileEntry{
        .{
            .name = "main",
            .command = "/opt/bin/my-claude",
            .script = "/nonexistent/path/that/should/not/be/here.sh",
        },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings("/opt/bin/my-claude", mgr.active().profile.command);
}

test "SessionManager: non-executable script falls through to provider" {
    // Create a regular file with no execute bit.
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/djinn-test-script-{d}.txt", .{std.time.microTimestamp()});
    defer std.testing.allocator.free(tmp_path);
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o644 });
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const entries = [_]Config.ProfileEntry{
        .{ .name = "main", .provider = "codex", .script = tmp_path },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;

    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();
    try std.testing.expectEqualStrings("codex", mgr.active().profile.command);
}

fn makeTempExecutable(allocator: std.mem.Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/djinn-test-script-{d}.sh", .{std.time.microTimestamp()});
    errdefer allocator.free(path);
    const f = try std.fs.cwd().createFile(path, .{ .mode = 0o755 });
    defer f.close();
    try f.writeAll("#!/bin/sh\nexec /bin/zsh\n");
    return path;
}

test "SessionManager: profile.label falls back to name" {
    var p = Profile{ .name = "main", .command = "claude" };
    try std.testing.expectEqualStrings("main", p.label());
    p.title = "Main Repo";
    try std.testing.expectEqualStrings("Main Repo", p.label());
}

test "SessionManager: appendEntry grows slice + resolves command" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "a", .provider = "claude" },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();

    const new_entry = Config.ProfileEntry{ .name = "b", .provider = "codex" };
    const sess = try mgr.appendEntry(new_entry);
    try std.testing.expectEqual(@as(usize, 2), mgr.count());
    try std.testing.expectEqualStrings("b", sess.profile.name);
    try std.testing.expectEqualStrings("codex", sess.profile.command);
    try std.testing.expectEqualStrings("b", mgr.sessions[1].profile.name);
}

test "SessionManager: removeAt shrinks + clamps active_idx" {
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
    const removed = mgr.removeAt(2) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("c", removed.profile.name);
    try std.testing.expectEqual(@as(usize, 2), mgr.count());
    try std.testing.expectEqual(@as(usize, 1), mgr.active_idx);

    // Remove from the middle: tail shifts down.
    _ = mgr.removeAt(0) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    try std.testing.expectEqualStrings("b", mgr.sessions[0].profile.name);
}

test "SessionManager: removeAt out of bounds returns null" {
    const entries = [_]Config.ProfileEntry{ .{ .name = "a" } };
    var cfg = Config{};
    cfg.profiles.entries = &entries;
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();

    try std.testing.expect(mgr.removeAt(5) == null);
    try std.testing.expectEqual(@as(usize, 1), mgr.count());
}

test "SessionManager: updateProfileDisplay re-points title + cwd" {
    const entries = [_]Config.ProfileEntry{
        .{ .name = "main", .title = "Old Title" },
    };
    var cfg = Config{};
    cfg.profiles.entries = &entries;
    var mgr = try SessionManager.init(std.testing.allocator, &cfg);
    defer mgr.deinit();

    try std.testing.expectEqualStrings("Old Title", mgr.sessions[0].profile.title.?);
    mgr.updateProfileDisplay(0, "New Title", "/tmp");
    try std.testing.expectEqualStrings("New Title", mgr.sessions[0].profile.title.?);
    try std.testing.expectEqualStrings("/tmp", mgr.sessions[0].profile.cwd.?);
}
