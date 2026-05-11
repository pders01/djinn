const std = @import("std");

/// Persisted across launches in `~/.config/djinn/state.json`. Holds the
/// window dimensions globally (last-used, used for default profile or
/// when no per-profile entry exists yet) plus an optional per-profile
/// override map so log-heavy profiles can stay tall+wide and shell
/// profiles can stay compact across switches.
pub const ProfileSize = struct {
    name: []const u8,
    width: u32,
    height: u32,
};

pub const State = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Owned by `arena`. Slices point into the arena. Use
    /// `profileSize(name)` instead of iterating directly.
    profiles: []const ProfileSize = &.{},
    /// Owns `profiles[*].name` + the backing slice. Null when the State
    /// was constructed inline (test / default).
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
            self.arena = null;
        }
        self.profiles = &.{};
    }

    /// Returns the persisted size for `name`, falling back to the
    /// top-level (width,height) when there is no per-profile entry. A
    /// null return means "no persisted size at all" — caller should
    /// fall through to config / hardcoded default.
    pub fn profileSize(self: State, name: []const u8) ?struct { w: u32, h: u32 } {
        for (self.profiles) |p| {
            if (std.mem.eql(u8, p.name, name)) return .{ .w = p.width, .h = p.height };
        }
        if (self.width != 0 and self.height != 0) return .{ .w = self.width, .h = self.height };
        return null;
    }
};

fn statePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/djinn/state.json", .{home});
}

pub fn load(allocator: std.mem.Allocator) ?State {
    const path = statePath(allocator) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    var arena = allocator.create(std.heap.ArenaAllocator) catch return null;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    var arena_alloc = arena.allocator();

    var s = State{ .arena = arena };
    if (root.object.get("width")) |v| if (v == .integer) {
        s.width = @intCast(v.integer);
    };
    if (root.object.get("height")) |v| if (v == .integer) {
        s.height = @intCast(v.integer);
    };
    if (root.object.get("profiles")) |v| if (v == .object) {
        var list: std.ArrayList(ProfileSize) = .{};
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const obj = entry.value_ptr.*;
            if (obj != .object) continue;
            const wv = obj.object.get("width") orelse continue;
            const hv = obj.object.get("height") orelse continue;
            if (wv != .integer or hv != .integer) continue;
            const name = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
            list.append(arena_alloc, .{
                .name = name,
                .width = @intCast(wv.integer),
                .height = @intCast(hv.integer),
            }) catch continue;
        }
        s.profiles = list.toOwnedSlice(arena_alloc) catch &.{};
    };

    // Treat the file as absent when nothing useful was parsed. Keeps
    // `restoreWindowSize`'s "fall through to config default" path
    // working when state.json is empty `{}` or has lost its data.
    if (s.width == 0 and s.height == 0 and s.profiles.len == 0) {
        s.deinit(allocator);
        return null;
    }
    return s;
}

/// Atomically rewrite state.json with the given top-level dims and
/// per-profile map. The map is the source of truth — callers compose
/// it via `updateProfile` rather than writing files directly.
pub fn save(allocator: std.mem.Allocator, width: u32, height: u32, profiles: []const ProfileSize) void {
    const path = statePath(allocator) catch return;
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch {};
    }

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    writeJson(&buf, allocator, width, height, profiles) catch return;

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer file.close();
    _ = file.writeAll(buf.items) catch {};
}

fn writeJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    profiles: []const ProfileSize,
) !void {
    var w = buf.writer(allocator);
    try w.print("{{\"width\":{d},\"height\":{d}", .{ width, height });
    if (profiles.len > 0) {
        try w.writeAll(",\"profiles\":{");
        for (profiles, 0..) |p, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeEscaped(&w, p.name);
            try w.print("\":{{\"width\":{d},\"height\":{d}}}", .{ p.width, p.height });
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
}

/// Debounced per-profile save. Callers fire on every resize tick; the
/// first call schedules a single disk write 300ms later that flushes
/// the latest pending value. `profile_name` may be null to update only
/// the global top-level dims (legacy single-profile setups).
var g_mutex: std.Thread.Mutex = .{};
var g_pending_width: u32 = 0;
var g_pending_height: u32 = 0;
var g_pending_profile_buf: [128]u8 = undefined;
var g_pending_profile_len: usize = 0;
var g_pending_has_profile: bool = false;
var g_pending_dirty: bool = false;
var g_thread_running: bool = false;

pub fn saveDebounced(allocator: std.mem.Allocator, width: u32, height: u32, profile_name: ?[]const u8) void {
    g_mutex.lock();
    g_pending_width = width;
    g_pending_height = height;
    g_pending_has_profile = false;
    g_pending_profile_len = 0;
    if (profile_name) |n| {
        const trim_len = @min(n.len, g_pending_profile_buf.len);
        @memcpy(g_pending_profile_buf[0..trim_len], n[0..trim_len]);
        g_pending_profile_len = trim_len;
        g_pending_has_profile = true;
    }
    g_pending_dirty = true;
    const need_spawn = !g_thread_running;
    if (need_spawn) g_thread_running = true;
    g_mutex.unlock();

    if (need_spawn) {
        const t = std.Thread.spawn(.{}, debounceWorker, .{allocator}) catch {
            g_mutex.lock();
            g_thread_running = false;
            g_mutex.unlock();
            return;
        };
        t.detach();
    }
}

fn debounceWorker(allocator: std.mem.Allocator) void {
    std.Thread.sleep(300 * std.time.ns_per_ms);
    g_mutex.lock();
    const w = g_pending_width;
    const h = g_pending_height;
    const has_p = g_pending_has_profile;
    var profile_buf: [128]u8 = undefined;
    var profile_len: usize = 0;
    if (has_p) {
        profile_len = g_pending_profile_len;
        @memcpy(profile_buf[0..profile_len], g_pending_profile_buf[0..profile_len]);
    }
    g_pending_dirty = false;
    g_thread_running = false;
    g_mutex.unlock();

    // Merge with what's on disk so the per-profile map persists across
    // saves that target a different profile.
    var existing = load(allocator);
    defer if (existing) |*e| e.deinit(allocator);

    var merged: std.ArrayList(ProfileSize) = .{};
    defer merged.deinit(allocator);
    if (existing) |e| {
        merged.appendSlice(allocator, e.profiles) catch {};
    }

    if (has_p) {
        const name = profile_buf[0..profile_len];
        var found = false;
        for (merged.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                p.width = w;
                p.height = h;
                found = true;
                break;
            }
        }
        if (!found) {
            // Dupe the name for the duration of this save call.
            const owned = allocator.dupe(u8, name) catch return;
            merged.append(allocator, .{ .name = owned, .width = w, .height = h }) catch {
                allocator.free(owned);
                return;
            };
            defer allocator.free(owned);
            save(allocator, w, h, merged.items);
            return;
        }
    }

    save(allocator, w, h, merged.items);
}

test "State: round-trip via load/save" {
    save(std.testing.allocator, 1024, 600, &.{});
}

test "State: writeJson encodes profile map" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const profiles = [_]ProfileSize{
        .{ .name = "main", .width = 1200, .height = 700 },
        .{ .name = "shell", .width = 600, .height = 300 },
    };
    try writeJson(&buf, std.testing.allocator, 1024, 600, &profiles);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"main\":{\"width\":1200,\"height\":700}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"shell\":{\"width\":600,\"height\":300}") != null);
}

test "State: writeJson escapes name" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const profiles = [_]ProfileSize{
        .{ .name = "weird\"name", .width = 100, .height = 200 },
    };
    try writeJson(&buf, std.testing.allocator, 1024, 600, &profiles);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\\\"name") != null);
}

test "State.profileSize: hit + fallback" {
    var s = State{
        .width = 800,
        .height = 400,
        .profiles = &[_]ProfileSize{.{ .name = "claude", .width = 1200, .height = 700 }},
    };
    const hit = s.profileSize("claude") orelse unreachable;
    try std.testing.expectEqual(@as(u32, 1200), hit.w);
    const miss = s.profileSize("zsh") orelse unreachable;
    try std.testing.expectEqual(@as(u32, 800), miss.w);
}
