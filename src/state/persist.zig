const std = @import("std");
const platform = @import("../io/platform.zig");

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
    const home = platform.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/djinn/state.json", .{home});
}

pub fn load(allocator: std.mem.Allocator) ?State {
    const path = statePath(allocator) catch return null;
    defer allocator.free(path);

    return loadAt(allocator, path);
}

fn loadAt(allocator: std.mem.Allocator, path: []const u8) ?State {
    const contents = std.Io.Dir.cwd().readFileAlloc(platform.io(), path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    var arena = allocator.create(std.heap.ArenaAllocator) catch return null;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    var arena_alloc = arena.allocator();

    var s = State{ .arena = arena };
    if (root.object.get("width")) |v| s.width = dimension(v) orelse 0;
    if (root.object.get("height")) |v| s.height = dimension(v) orelse 0;
    if (root.object.get("profiles")) |v| if (v == .object) {
        var list: std.ArrayList(ProfileSize) = .empty;
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const obj = entry.value_ptr.*;
            if (obj != .object) continue;
            const wv = obj.object.get("width") orelse continue;
            const hv = obj.object.get("height") orelse continue;
            const width = dimension(wv) orelse continue;
            const height = dimension(hv) orelse continue;
            const name = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
            list.append(arena_alloc, .{
                .name = name,
                .width = width,
                .height = height,
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

fn dimension(value: std.json.Value) ?u32 {
    if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u16)) return null;
    return @intCast(value.integer);
}

/// Atomically rewrite state.json with the given top-level dims and
/// per-profile map. The map is the source of truth — callers compose
/// it via `updateProfile` rather than writing files directly.
pub fn save(allocator: std.mem.Allocator, width: u32, height: u32, profiles: []const ProfileSize) void {
    const path = statePath(allocator) catch return;
    defer allocator.free(path);

    saveAt(allocator, path, width, height, profiles);
}

fn saveAt(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32, profiles: []const ProfileSize) void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirAbsolute(platform.io(), dir, .default_dir) catch {};
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    writeJson(&buf, allocator, width, height, profiles) catch return;

    const io = platform.io();
    const dir_path = std.fs.path.dirname(path) orelse return;
    const dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return;
    defer dir.close(io);
    var atomic = dir.createFileAtomic(io, std.fs.path.basename(path), .{ .replace = true }) catch return;
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, buf.items) catch return;
    atomic.replace(io) catch {};
}

fn writeJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    profiles: []const ProfileSize,
) !void {
    var allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, buf);
    defer buf.* = allocating.toArrayList();
    const w = &allocating.writer;
    try w.print("{{\"width\":{d},\"height\":{d}", .{ width, height });
    if (profiles.len > 0) {
        try w.writeAll(",\"profiles\":{");
        for (profiles, 0..) |p, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeEscaped(w, p.name);
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

/// Coalesce accepted resize updates through one writer, including updates
/// arriving while it is doing disk IO. Membership/configuration is never saved.
const PendingSave = struct {
    width: u32 = 0,
    height: u32 = 0,
    profile: [128]u8 = @splat(0),
    profile_len: usize = 0,
    has_profile: bool = false,
    dirty: bool = false,
    running: bool = false,
    stopped: bool = false,

    fn queue(self: *PendingSave, width: u32, height: u32, name: ?[]const u8) bool {
        if (self.stopped) return false;
        self.width = width;
        self.height = height;
        self.has_profile = name != null;
        self.profile_len = 0;
        if (name) |n| {
            self.profile_len = @min(n.len, self.profile.len);
            @memcpy(self.profile[0..self.profile_len], n[0..self.profile_len]);
        }
        self.dirty = true;
        if (self.running) return false;
        self.running = true;
        return true;
    }

    fn take(self: *PendingSave) ?PendingSave {
        if (!self.dirty) {
            self.running = false;
            return null;
        }
        const snapshot = self.*;
        self.dirty = false;
        // Keep running=true through the complete load/merge/atomic-write.
        return snapshot;
    }
};

var resize_workers: platform.Workers = .{};
var g_mutex: std.Io.Mutex = .init;
var pending: PendingSave = .{};

pub fn saveDebounced(allocator: std.mem.Allocator, width: u32, height: u32, profile_name: ?[]const u8) void {
    const io = platform.io();
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);
    if (pending.queue(width, height, profile_name)) {
        resize_workers.spawn(debounceWorker, .{allocator}) catch {
            pending.running = false;
        };
    }
}

/// Stop accepting saves, then flush accepted updates before IO/allocator teardown.
pub fn shutdown() void {
    g_mutex.lockUncancelable(platform.io());
    pending.stopped = true;
    g_mutex.unlock(platform.io());
    resize_workers.finish(.drain);
}

pub const joinPendingSave = shutdown;

fn debounceWorker(allocator: std.mem.Allocator) void {
    while (true) {
        platform.sleep(300 * std.time.ns_per_ms);
        g_mutex.lockUncancelable(platform.io());
        const update = pending.take();
        g_mutex.unlock(platform.io());
        const snapshot = update orelse return;
        flushUpdate(allocator, snapshot.width, snapshot.height, if (snapshot.has_profile) snapshot.profile[0..snapshot.profile_len] else null);
    }
}

fn flushUpdate(allocator: std.mem.Allocator, w: u32, h: u32, profile: ?[]const u8) void {
    // Merge with what's on disk so the per-profile map persists across
    // saves that target a different profile.
    var existing = load(allocator);
    defer if (existing) |*e| e.deinit(allocator);

    var merged: std.ArrayList(ProfileSize) = .empty;
    defer merged.deinit(allocator);
    if (existing) |e| {
        merged.appendSlice(allocator, e.profiles) catch {};
    }

    if (profile) |name| {
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

test "State: pending writes stay serialized during a flush" {
    var state: PendingSave = .{};
    try std.testing.expect(state.queue(800, 600, "first"));
    const first = state.take().?;
    try std.testing.expectEqualStrings("first", first.profile[0..first.profile_len]);
    try std.testing.expect(state.running);
    try std.testing.expect(!state.queue(1200, 700, "second"));
    const second = state.take().?;
    try std.testing.expectEqual(@as(u32, 1200), second.width);
    try std.testing.expectEqualStrings("second", second.profile[0..second.profile_len]);
    try std.testing.expect(state.running);
    try std.testing.expect(state.take() == null);
    try std.testing.expect(!state.running);
}

test "State: shutdown gates new updates without dropping accepted state" {
    var state: PendingSave = .{};
    try std.testing.expect(state.queue(800, 600, null));
    state.stopped = true;
    try std.testing.expect(!state.queue(900, 700, "late"));
    try std.testing.expectEqual(@as(u32, 800), state.take().?.width);
    try std.testing.expect(state.take() == null);
}

test "State: saved dimensions reject invalid native geometry" {
    try std.testing.expectEqual(@as(?u32, 800), dimension(.{ .integer = 800 }));
    try std.testing.expect(dimension(.{ .integer = -1 }) == null);
    try std.testing.expect(dimension(.{ .integer = 0 }) == null);
    try std.testing.expect(dimension(.{ .integer = 65536 }) == null);
    try std.testing.expect(dimension(.{ .string = "800" }) == null);
}

test "State: round-trip via load/save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(platform.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "state.json" });
    defer std.testing.allocator.free(path);
    try std.testing.expect(loadAt(std.testing.allocator, path) == null);
    saveAt(std.testing.allocator, path, 1024, 600, &.{.{ .name = "main", .width = 1200, .height = 700 }});
    var state = loadAt(std.testing.allocator, path) orelse return error.TestUnexpectedResult;
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1024), state.width);
    try std.testing.expectEqual(@as(u32, 600), state.height);
    try std.testing.expectEqual(@as(usize, 1), state.profiles.len);
    try std.testing.expectEqualStrings("main", state.profiles[0].name);
    try std.testing.expectEqual(@as(u32, 1200), state.profiles[0].width);
    try std.testing.expectEqual(@as(u32, 700), state.profiles[0].height);
}

test "State: atomic replacement leaves only the complete state file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(platform.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "state.json" });
    defer std.testing.allocator.free(path);
    saveAt(std.testing.allocator, path, 800, 600, &.{});
    saveAt(std.testing.allocator, path, 1200, 700, &.{});
    var state = loadAt(std.testing.allocator, path) orelse return error.TestUnexpectedResult;
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1200), state.width);
    try std.testing.expectEqual(@as(u32, 700), state.height);
    var entries = tmp.dir.iterate();
    const entry = (try entries.next(platform.io())) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("state.json", entry.name);
    try std.testing.expect((try entries.next(platform.io())) == null);
}

test "State: writeJson encodes profile map" {
    var buf: std.ArrayList(u8) = .empty;
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
    var buf: std.ArrayList(u8) = .empty;
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
