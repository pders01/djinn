const std = @import("std");
const builtin = @import("builtin");

// Borrowed from process startup. Main drains/cancels host workers before
// returning, so none can use this threaded backend after its owner destroys it.
var process_io: ?std.Io = null;

pub fn init(value: std.Io) void {
    std.debug.assert(process_io == null);
    process_io = value;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return process_io orelse @panic("platform.init must precede process IO");
}

/// Borrowed from the process environment; callers must not mutate environ
/// concurrently or retain the result across environment mutations.
pub fn getenv(name: [:0]const u8) ?[:0]const u8 {
    return std.mem.span(std.c.getenv(name.ptr) orelse return null);
}

/// Bounded-lifetime host work, not detached OS threads. Closing the spawn
/// gate precedes joining, so no new task can race with backend teardown.
/// finish() is main-thread-only; spawn() may be called from any thread.
pub const Workers = struct {
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    pub fn spawn(
        self: *Workers,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) (std.Io.ConcurrentError || error{ShuttingDown})!void {
        const backend = io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        if (self.closed) return error.ShuttingDown;
        try self.group.concurrent(backend, function, args);
    }

    pub fn finish(self: *Workers, mode: enum { drain, cancel }) void {
        const backend = io();
        self.mutex.lockUncancelable(backend);
        const was_closed = self.closed;
        self.closed = true;
        self.mutex.unlock(backend);
        if (was_closed) return;
        switch (mode) {
            .cancel => self.group.cancel(backend),
            .drain => {
                // Persistence must finish, not cancel midway through a write.
                const previous = backend.swapCancelProtection(.blocked);
                defer _ = backend.swapCancelProtection(previous);
                self.group.await(backend) catch unreachable;
            },
        }
    }
};

pub fn sleep(ns: u64) void {
    std.Io.sleep(io(), .fromNanoseconds(ns), .awake) catch {};
}

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(io()).toMilliseconds();
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io()).toSeconds();
}

pub fn executablePath(buffer: []u8) ![]u8 {
    const len = try std.process.executablePath(io(), buffer);
    return buffer[0..len];
}

pub fn executablePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    // The stdlib returns a sentinel allocation; the shared API returns an
    // ordinary slice, so copy rather than losing the allocation's sentinel.
    const path = try std.process.executablePathAlloc(io(), allocator);
    defer allocator.free(path);
    return allocator.dupe(u8, path);
}

test "platform: executable path buffer and owned allocation agree" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try executablePath(&buffer);
    const allocated = try executablePathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(allocated);
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expectEqualStrings(path, allocated);
}

test "platform: workers drain before closing and reject subsequent tasks" {
    const Task = struct {
        fn run(completed: *std.atomic.Value(usize)) void {
            _ = completed.fetchAdd(1, .monotonic);
        }
    };
    var workers: Workers = .{};
    defer workers.finish(.drain);
    var completed: std.atomic.Value(usize) = .init(0);
    for (0..4) |_| try workers.spawn(Task.run, .{&completed});
    workers.finish(.drain);
    try std.testing.expectEqual(@as(usize, 4), completed.load(.acquire));
    try std.testing.expectError(error.ShuttingDown, workers.spawn(Task.run, .{&completed}));
    try std.testing.expectEqual(@as(usize, 4), completed.load(.acquire));
}

test "platform: worker cancellation joins and runs deferred cleanup" {
    const Task = struct {
        fn run(started: *std.Io.Event, cleaned: *std.atomic.Value(bool)) void {
            defer cleaned.store(true, .release);
            started.set(io());
            std.Io.sleep(io(), .fromSeconds(60), .awake) catch {};
        }
    };
    var workers: Workers = .{};
    defer workers.finish(.cancel);
    var started: std.Io.Event = .unset;
    var cleaned: std.atomic.Value(bool) = .init(false);
    try workers.spawn(Task.run, .{ &started, &cleaned });
    started.waitUncancelable(io());
    workers.finish(.cancel);
    try std.testing.expect(cleaned.load(.acquire));
    try std.testing.expectError(error.ShuttingDown, workers.spawn(Task.run, .{ &started, &cleaned }));
}

test "platform: wall clock units agree and sleep accepts zero" {
    const before = timestamp();
    const millis = milliTimestamp();
    const after = timestamp();
    try std.testing.expect(@divFloor(millis, 1000) >= before);
    try std.testing.expect(@divFloor(millis, 1000) <= after);
    sleep(0);
}
