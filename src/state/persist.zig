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
    // Geometry names come from configuration, not a bounded UI label. An
    // arbitrary file cap would silently lose long names/maps on the next merge.
    const contents = std.Io.Dir.cwd().readFileAlloc(platform.io(), path, allocator, .unlimited) catch return null;
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
/// per-profile map. The resize worker composes the map from its owned
/// per-profile batch; native resize producers must use `saveDebounced`.
pub fn save(allocator: std.mem.Allocator, width: u32, height: u32, profiles: []const ProfileSize) void {
    const path = statePath(allocator) catch return;
    defer allocator.free(path);

    saveAt(allocator, path, width, height, profiles) catch |err| {
        std.log.warn("could not save geometry: {s}", .{@errorName(err)});
    };
}

fn saveAt(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32, profiles: []const ProfileSize) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirAbsolute(platform.io(), dir, .default_dir) catch {};
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try writeJson(&buf, allocator, width, height, profiles);

    const io = platform.io();
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, std.fs.path.basename(path), .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, buf.items);
    try atomic.replace(io);
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

/// An owned, exact-identity batch. Names never borrow configuration memory.
const SaveBatch = struct {
    width: u32 = 0,
    height: u32 = 0,
    profiles: std.ArrayList(ProfileSize) = .empty,

    fn deinit(self: *SaveBatch, allocator: std.mem.Allocator) void {
        for (self.profiles.items) |p| allocator.free(p.name);
        self.profiles.deinit(allocator);
        self.* = .{};
    }
};

/// Periodic coalescing, NOT trailing-edge debounce: the first update starts a
/// 300 ms window. Continuous input may write once per window (plus disk IO).
/// This deliberately checkpoints a long drag instead of postponing all writes
/// indefinitely; it does not promise one write per drag or change host polling.
/// Each profile retains its latest size, while top-level size is last overall.
/// take() transfers ownership and keeps the single-writer gate through IO.
const PendingSave = struct {
    allocator: std.mem.Allocator,
    batch: SaveBatch = .{},
    dirty: bool = false,
    running: bool = false,
    stopped: bool = false,

    fn queue(self: *PendingSave, width: u32, height: u32, name: ?[]const u8) !bool {
        if (self.stopped) return false;
        if (name) |n| {
            var found = false;
            for (self.batch.profiles.items) |*p| {
                if (std.mem.eql(u8, p.name, n)) {
                    p.width = width;
                    p.height = height;
                    found = true;
                    break;
                }
            }
            if (!found) {
                const owned = try self.allocator.dupe(u8, n);
                errdefer self.allocator.free(owned);
                try self.batch.profiles.append(self.allocator, .{ .name = owned, .width = width, .height = height });
            }
        }
        self.batch.width = width;
        self.batch.height = height;
        self.dirty = true;
        if (self.running) return false;
        self.running = true;
        return true;
    }

    fn take(self: *PendingSave) ?SaveBatch {
        if (!self.dirty) {
            self.running = false;
            return null;
        }
        const snapshot = self.batch;
        self.batch = .{};
        self.dirty = false;
        return snapshot;
    }
};

var resize_workers: platform.Workers = .{};
var g_mutex: std.Io.Mutex = .init;
// Queue storage has a stable allocator even if callers replace their config.
var pending: PendingSave = .{ .allocator = std.heap.page_allocator };

/// Historical API name; uses periodic coalescing as documented above.
/// The caller's allocator must remain valid until shutdown() returns.
pub fn saveDebounced(allocator: std.mem.Allocator, width: u32, height: u32, profile_name: ?[]const u8) void {
    const io = platform.io();
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);
    const start = pending.queue(width, height, profile_name) catch |err| {
        std.log.warn("could not queue geometry: {s}", .{@errorName(err)});
        return;
    };
    if (start) {
        resize_workers.spawn(coalescingWorker, .{allocator}) catch {
            // Do not strand accepted work when concurrent execution is unavailable.
            // Keep the mutex through this exceptional synchronous write so shutdown
            // cannot outlive it and no second writer can start.
            var batch = pending.take().?;
            defer batch.deinit(pending.allocator);
            flushBatch(allocator, batch);
            _ = pending.take();
        };
    }
}

/// Main-thread-only, after native resize producers detach. Close acceptance,
/// then drain before IO/allocator teardown. At most one existing 300 ms sleep
/// remains; no further coalescing delays occur after the gate closes. Disk IO
/// itself is not time-bounded, and write/allocation failures are logged.
pub fn shutdown() void {
    g_mutex.lockUncancelable(platform.io());
    pending.stopped = true;
    g_mutex.unlock(platform.io());
    resize_workers.finish(.drain);
}

pub const joinPendingSave = shutdown;

fn coalescingWorker(allocator: std.mem.Allocator) void {
    runCoalescing(allocator, &pending, &g_mutex, struct {
        fn flush(a: std.mem.Allocator, batch: SaveBatch, _: ?*anyopaque) void {
            flushBatch(a, batch);
        }
    }.flush, null);
}

// Inject the destination for fixture tests, never changing HOME or touching the
// user's state. The same worker loop is used for real asynchronous drain tests.
fn runCoalescing(
    allocator: std.mem.Allocator,
    state: *PendingSave,
    mutex: *std.Io.Mutex,
    flush: *const fn (std.mem.Allocator, SaveBatch, ?*anyopaque) void,
    context: ?*anyopaque,
) void {
    while (true) {
        mutex.lockUncancelable(platform.io());
        const delay = !state.stopped and state.dirty;
        mutex.unlock(platform.io());
        if (delay) platform.sleep(300 * std.time.ns_per_ms);
        mutex.lockUncancelable(platform.io());
        const update = state.take();
        mutex.unlock(platform.io());
        var snapshot = update orelse return;
        defer snapshot.deinit(state.allocator);
        flush(allocator, snapshot, context);
    }
}

fn flushBatch(allocator: std.mem.Allocator, batch: SaveBatch) void {
    const path = statePath(allocator) catch |err| {
        std.log.warn("could not locate geometry state: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(path);
    flushBatchAt(allocator, path, batch) catch |err| {
        std.log.warn("could not flush geometry: {s}", .{@errorName(err)});
    };
}

fn flushBatchAt(allocator: std.mem.Allocator, path: []const u8, batch: SaveBatch) !void {
    var existing = loadAt(allocator, path);
    defer if (existing) |*e| e.deinit(allocator);
    var merged: std.ArrayList(ProfileSize) = .empty;
    defer merged.deinit(allocator);
    if (existing) |e| try merged.appendSlice(allocator, e.profiles);
    for (batch.profiles.items) |update| {
        var found = false;
        for (merged.items) |*p| {
            if (std.mem.eql(u8, p.name, update.name)) {
                p.* = update;
                found = true;
                break;
            }
        }
        if (!found) try merged.append(allocator, update);
    }
    try saveAt(allocator, path, batch.width, batch.height, merged.items);
}

test "State: per-profile batches survive updates during flush and shutdown" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(platform.io(), ".", a);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "state.json" });
    defer a.free(path);
    var state: PendingSave = .{ .allocator = a };
    defer state.batch.deinit(a);
    try std.testing.expect(try state.queue(800, 600, "A"));
    try std.testing.expect(!try state.queue(900, 650, "B"));
    try std.testing.expect(!try state.queue(1000, 700, "A"));
    var first = state.take().?;
    defer first.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), first.profiles.items.len);
    try std.testing.expect(state.running);
    // Deterministically hold the writer lease while producers queue more work.
    try std.testing.expect(!try state.queue(1100, 750, "A"));
    try std.testing.expect(!try state.queue(1200, 800, "C"));
    state.stopped = true;
    try std.testing.expect(!try state.queue(1, 1, "late"));
    try flushBatchAt(a, path, first);
    var during = loadAt(a, path).?;
    defer during.deinit(a);
    try std.testing.expectEqual(@as(u32, 1000), during.profileSize("A").?.w);
    try std.testing.expectEqual(@as(u32, 900), during.profileSize("B").?.w);
    var second = state.take().?;
    defer second.deinit(a);
    try std.testing.expect(state.running);
    try flushBatchAt(a, path, second);
    try std.testing.expect(state.take() == null);
    try std.testing.expect(!state.running);
    var saved = loadAt(a, path).?;
    defer saved.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), saved.profiles.len);
    try std.testing.expectEqual(@as(u32, 1100), saved.profileSize("A").?.w);
    try std.testing.expectEqual(@as(u32, 900), saved.profileSize("B").?.w);
    try std.testing.expectEqual(@as(u32, 1200), saved.profileSize("C").?.w);
    try std.testing.expectEqual(@as(u32, 1200), saved.width);
}

test "State: real worker drains fixture updates accepted while flush is blocked" {
    const Fixture = struct {
        allocator: std.mem.Allocator,
        path: []const u8,
        state: PendingSave,
        mutex: std.Io.Mutex = .init,
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        writes: usize = 0,
        failure: ?anyerror = null,

        fn flush(a: std.mem.Allocator, batch: SaveBatch, context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.writes == 0) {
                self.entered.set(platform.io());
                self.release.waitUncancelable(platform.io());
            }
            flushBatchAt(a, self.path, batch) catch |err| {
                self.failure = err;
            };
            self.writes += 1;
        }

        fn run(self: *@This()) void {
            runCoalescing(self.allocator, &self.state, &self.mutex, flush, self);
        }
    };
    const a = std.testing.allocator;
    const io = platform.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "state.json" });
    defer a.free(path);
    var fixture: Fixture = .{ .allocator = a, .path = path, .state = .{ .allocator = a } };
    defer fixture.state.batch.deinit(a);
    var workers: platform.Workers = .{};
    defer workers.finish(.drain);
    // Also unblock on assertion failure, before the deferred worker join.
    defer fixture.release.set(io);
    try std.testing.expect(try fixture.state.queue(800, 600, "A"));
    try workers.spawn(Fixture.run, .{&fixture});
    fixture.entered.waitUncancelable(io);
    {
        fixture.mutex.lockUncancelable(io);
        defer fixture.mutex.unlock(io);
        try std.testing.expect(!try fixture.state.queue(900, 650, "B"));
        try std.testing.expect(!try fixture.state.queue(1000, 700, "A"));
        fixture.state.stopped = true;
        try std.testing.expect(!try fixture.state.queue(1, 1, "late"));
        try std.testing.expect(fixture.state.running);
    }
    fixture.release.set(io);
    workers.finish(.drain);
    if (fixture.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), fixture.writes);
    try std.testing.expect(!fixture.state.running and !fixture.state.dirty);
    var saved = loadAt(a, path) orelse return error.TestUnexpectedResult;
    defer saved.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), saved.profiles.len);
    try std.testing.expectEqual(@as(u32, 1000), saved.profileSize("A").?.w);
    try std.testing.expectEqual(@as(u32, 900), saved.profileSize("B").?.w);
    try std.testing.expectEqual(@as(u32, 1000), saved.width);
}

test "State: null profile preserves queued profiles and allocation failure is transactional" {
    const a = std.testing.allocator;
    var state: PendingSave = .{ .allocator = a };
    defer state.batch.deinit(a);
    try std.testing.expect(try state.queue(800, 600, "A"));
    try std.testing.expect(!try state.queue(900, 700, null));
    try std.testing.expectEqual(@as(usize, 1), state.batch.profiles.items.len);
    try std.testing.expectEqual(@as(u32, 900), state.batch.width);
    var failing: PendingSave = .{ .allocator = std.testing.failing_allocator };
    try std.testing.expectError(error.OutOfMemory, failing.queue(1, 1, "B"));
    try std.testing.expect(!failing.dirty and !failing.running);
    failing.stopped = true;
    try std.testing.expect(!try failing.queue(1, 1, "late"));
}

test "State: pending name and map allocation failures release ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(a: std.mem.Allocator) !void {
            var state: PendingSave = .{ .allocator = a };
            defer state.batch.deinit(a);
            for ([_][]const u8{ "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth" }) |name| {
                _ = try state.queue(800, 600, name);
            }
            var batch = state.take().?;
            defer batch.deinit(a);
            _ = try state.queue(900, 700, "during flush");
        }
    }.check, .{});
}

test "State: exact owned long Unicode names round-trip beyond old file limit" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(platform.io(), ".", a);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "state.json" });
    defer a.free(path);
    // The first multibyte character straddles the old 128-byte cutoff.
    const prefix: [127]u8 = @splat('p');
    const one = try std.fmt.allocPrint(a, "{s}界-one", .{prefix});
    defer a.free(one);
    const two = try std.fmt.allocPrint(a, "{s}界-two", .{prefix});
    defer a.free(two);
    const long = try a.alloc(u8, 72000);
    defer a.free(long);
    for (0..18000) |i| @memcpy(long[i * 4 ..][0..4], "🙂");
    const names = [_][]const u8{ one, two, "", "quote\"\\\n名", long };
    var state: PendingSave = .{ .allocator = a };
    defer state.batch.deinit(a);
    for (names, 0..) |name, i| {
        const borrowed = try a.dupe(u8, name);
        defer a.free(borrowed);
        _ = try state.queue(@intCast(800 + i), 600, borrowed);
        // Simulate config destruction/reuse before the writer runs.
        @memset(borrowed, 'x');
    }
    var batch = state.take().?;
    defer batch.deinit(a);
    try flushBatchAt(a, path, batch);
    var saved = loadAt(a, path) orelse return error.TestUnexpectedResult;
    defer saved.deinit(a);
    try std.testing.expectEqual(names.len, saved.profiles.len);
    for (names, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, saved.profiles[i].name);
        try std.testing.expectEqual(@as(u32, @intCast(800 + i)), saved.profileSize(name).?.w);
    }
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
    try saveAt(std.testing.allocator, path, 1024, 600, &.{.{ .name = "main", .width = 1200, .height = 700 }});
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
    try saveAt(std.testing.allocator, path, 800, 600, &.{});
    try saveAt(std.testing.allocator, path, 1200, 700, &.{});
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
