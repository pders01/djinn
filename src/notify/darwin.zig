const std = @import("std");
const objc = @import("objc");

const c_dispatch = @import("darwin-c");
const platform = @import("../io/platform.zig");

// libdispatch's typed wrappers stumble over the transparent-union dispatch
// types when called from zig (same dance io/dispatch.zig already plays for
// dispatch_resume). dispatch_async_f works in the same shape: hand it the
// main queue, a context pointer, and a C-ABI function. The AppKit call
// sites must run on main; this is the cheapest way to guarantee that
// without dragging in a Grand Central Dispatch wrapper.
extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;

const RateEntry = struct {
    occupied: bool = false,
    source_id: u64 = 0,
    last_ms: i64 = 0,
};

/// Bounded per-source history. New sources FIFO-evict once full; an
/// evicted source may deliver again before its previous window expires.
const rate_buckets: usize = 16;

var audio_workers: platform.Workers = .{};

/// macOS notification sender via NSUserNotification (deprecated in 10.14
/// but functional through current macOS; UNUserNotificationCenter is the
/// modern path but requires a code-signed bundle, entitlements, and Zig
/// extern wrappers for block-based completion handlers — none of which
/// we want to take on yet). This is a transport swap from osascript;
/// behavior is identical.
pub const Notifier = struct {
    enabled: bool = true,
    /// Minimum interval between banners from the same terminal session.
    rate_limit_ms: u64 = 30_000,
    rate_mutex: std.Io.Mutex = .init,
    rate_ring: [rate_buckets]RateEntry = @splat(.{}),
    /// Next FIFO slot to overwrite when all buckets are occupied.
    rate_next_slot: usize = 0,

    /// Play a system sound through an owned background task. NSSound's
    /// AppKit calls must stay on main; afplay avoids AppKit entirely.
    /// `name` semantics:
    ///   - "" or null → no-op
    ///   - "default" → /System/Library/Sounds/Funk.aiff
    ///   - absolute path → must live under /System/Library/Sounds/
    ///     or ~/Library/Sounds/, no `..` segments
    ///   - anything else → /System/Library/Sounds/<name>.aiff
    ///     (short stems must not contain `/`)
    ///
    /// Validation prevents a config-controlled path from reaching
    /// arbitrary files on disk — `afplay` would otherwise open and
    /// attempt to play any file readable by the user, which is a
    /// minor info-disclosure surface (file existence + readability)
    /// when the config originates from an untrusted source.
    pub fn playSound(_: *const Notifier, name: ?[]const u8) void {
        const n = name orelse return;
        if (n.len == 0) return;

        const allocator = std.heap.page_allocator;
        const path: []const u8 = blk: {
            if (n[0] == '/') {
                if (!isAllowedSoundPath(n)) {
                    std.debug.print("warning: sound path '{s}' outside allowed dirs; skipping\n", .{n});
                    return;
                }
                break :blk allocator.dupe(u8, n) catch return;
            }
            // Short stem: must be a bare filename, no path separators.
            // Apple ships sounds with simple names (Tink, Funk, …); a
            // value like `../etc/passwd` would otherwise be glued onto
            // the prefix and escape the sounds dir.
            if (std.mem.indexOfScalar(u8, n, '/') != null) {
                std.debug.print("warning: sound stem '{s}' contains '/'; skipping\n", .{n});
                return;
            }
            const stem = if (std.mem.eql(u8, n, "default")) "Funk" else n;
            break :blk std.fmt.allocPrint(allocator, "/System/Library/Sounds/{s}.aiff", .{stem}) catch return;
        };

        // execAfplay owns the path after a successful spawn.
        audio_workers.spawn(execAfplay, .{path}) catch allocator.free(path);
    }

    /// Main calls this after native callback producers stop, before the
    /// process IO backend goes away. Long sounds must not delay shutdown.
    pub fn shutdownSounds() void {
        audio_workers.finish(.cancel);
    }

    /// Generic terminal notification. Callers own visibility policy; this
    /// transport only gates enabled/rate, copies text, and queues AppKit.
    /// source_id is a stable session ID (all u64 values, including 0, work).
    pub fn send(self: *Notifier, source_id: u64, title: []const u8, body: []const u8) void {
        if (!self.enabled) return;
        if (!self.checkAndBumpRate(source_id, platform.milliTimestamp())) return;
        deliver(title, body);
    }

    /// Explicit timestamps keep rate-policy tests independent of clocks
    /// and sleeps. A backwards wall-clock jump starts a fresh window.
    fn checkAndBumpRate(self: *Notifier, source_id: u64, now: i64) bool {
        const io = platform.io();
        self.rate_mutex.lockUncancelable(io);
        defer self.rate_mutex.unlock(io);

        for (&self.rate_ring) |*entry| {
            if (entry.occupied and entry.source_id == source_id) {
                const elapsed = @as(i128, now) - @as(i128, entry.last_ms);
                if (elapsed >= 0 and elapsed < @as(i128, self.rate_limit_ms)) return false;
                entry.last_ms = now;
                return true;
            }
        }
        for (&self.rate_ring) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .occupied = true, .source_id = source_id, .last_ms = now };
                return true;
            }
        }
        const slot = self.rate_next_slot;
        self.rate_next_slot = (slot + 1) % rate_buckets;
        self.rate_ring[slot] = .{ .occupied = true, .source_id = source_id, .last_ms = now };
        return true;
    }
};

fn deliver(title: []const u8, body: []const u8) void {
    const allocator = std.heap.page_allocator;
    const payload = allocator.create(Payload) catch return;
    // Never retain caller slices across dispatch. Copy bounded, valid
    // UTF-8 prefixes now, including terminators for NSString below.
    copyUtf8Z(&payload.title, title);
    copyUtf8Z(&payload.body, body);

    // NSUserNotificationCenter must run on main, even when the caller
    // is a background terminal callback. deliverOnMain owns the payload.
    const main_queue = c_dispatch.dispatch_get_main_queue();
    dispatch_async_f(@ptrCast(main_queue), payload, &deliverOnMain);
}

const Payload = struct {
    /// Content caps in bytes, plus one NUL. No unbounded text allocation.
    title: [257]u8,
    body: [4097]u8,
};

/// Stop before a partial codepoint, malformed UTF-8, or embedded NUL.
fn copyUtf8Z(dest: []u8, bytes: []const u8) void {
    std.debug.assert(dest.len > 0);
    const limit = @min(bytes.len, dest.len - 1);
    var end: usize = 0;
    while (end < limit and bytes[end] != 0) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[end]) catch break;
        if (len > limit - end) break;
        _ = std.unicode.utf8Decode(bytes[end..][0..len]) catch break;
        end += len;
    }
    @memcpy(dest[0..end], bytes[0..end]);
    dest[end] = 0;
}

fn deliverOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const opaque_ptr = ctx orelse return;
    const payload: *Payload = @ptrCast(@alignCast(opaque_ptr));
    const allocator = std.heap.page_allocator;
    defer allocator.destroy(payload);

    const NSString = objc.getClass("NSString") orelse return;
    const NSUserNotification = objc.getClass("NSUserNotification") orelse return;
    const NSUserNotificationCenter = objc.getClass("NSUserNotificationCenter") orelse return;

    const ns_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(&payload.title))});
    if (ns_title.value == null) return;
    const ns_body = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(&payload.body))});
    if (ns_body.value == null) return;

    const note_alloc = NSUserNotification.msgSend(objc.Object, "alloc", .{});
    const note = note_alloc.msgSend(objc.Object, "init", .{});
    if (note.value == null) return;
    defer note.msgSend(void, "release", .{});

    note.msgSend(void, "setTitle:", .{ns_title});
    note.msgSend(void, "setInformativeText:", .{ns_body});

    const center = NSUserNotificationCenter.msgSend(
        objc.Object,
        "defaultUserNotificationCenter",
        .{},
    );
    if (center.value == null) return;
    center.msgSend(void, "deliverNotification:", .{note});
}

/// Whitelist for absolute sound paths. macOS's bundled sounds live
/// under `/System/Library/Sounds/`; user-installed sounds live under
/// `~/Library/Sounds/`. Anything else (a config that points at
/// `/etc/passwd`, an attacker-controlled symlink, …) is rejected so
/// `afplay` doesn't silently probe random files. `..` segments are
/// rejected before the prefix check so a path like
/// `/System/Library/Sounds/../../../etc/passwd` doesn't slip
/// through.
fn isAllowedSoundPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/../") != null) return false;
    if (std.mem.endsWith(u8, path, "/..")) return false;
    if (std.mem.startsWith(u8, path, "/System/Library/Sounds/")) return true;
    const home = platform.getenv("HOME") orelse return false;
    var buf: [512]u8 = undefined;
    const user_prefix = std.fmt.bufPrint(&buf, "{s}/Library/Sounds/", .{home}) catch return false;
    return std.mem.startsWith(u8, path, user_prefix);
}

fn execAfplay(path: []const u8) void {
    defer std.heap.page_allocator.free(path);
    const io = platform.io();
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/afplay", path },
    }) catch return;
    waitOwnedChild(&child, io);
}

fn waitOwnedChild(child: anytype, io: std.Io) void {
    const id = child.id;
    defer child.kill(io);
    _ = child.wait(io) catch |err| {
        // Zig 0.17.1's POSIX wait clears id even on Canceled, without
        // reaping or killing the process. Only that path retains ownership:
        // cancellation happens before a successful wait syscall. Never
        // restore an id after success/other errors, where it could be reused.
        if (err == error.Canceled) child.id = id;
        return;
    };
}

test "Notifier: canceled POSIX wait preserves child ownership for cleanup" {
    const Child = struct {
        id: ?i32 = 42,
        killed_id: ?i32 = null,
        outcome: enum { success, canceled, failed },

        fn wait(self: *@This(), _: std.Io) error{ Canceled, Unexpected }!void {
            self.id = null; // Zig 0.17.1 consumes the handle on every path.
            switch (self.outcome) {
                .success => {},
                .canceled => return error.Canceled,
                .failed => return error.Unexpected,
            }
        }

        fn kill(self: *@This(), _: std.Io) void {
            self.killed_id = self.id;
            self.id = null;
        }
    };
    var canceled: Child = .{ .outcome = .canceled };
    waitOwnedChild(&canceled, std.testing.io);
    try std.testing.expectEqual(@as(?i32, 42), canceled.killed_id);
    try std.testing.expect(canceled.id == null);
    var completed: Child = .{ .outcome = .success };
    waitOwnedChild(&completed, std.testing.io);
    try std.testing.expect(completed.killed_id == null);
    var failed: Child = .{ .outcome = .failed };
    waitOwnedChild(&failed, std.testing.io);
    try std.testing.expect(failed.killed_id == null);
}

test "Notifier: per-source window, exact boundary, and zero source ID" {
    var n = Notifier{ .rate_limit_ms = 100 };
    try std.testing.expect(n.checkAndBumpRate(0, 0));
    try std.testing.expect(!n.checkAndBumpRate(0, 0));
    try std.testing.expect(!n.checkAndBumpRate(0, 99));
    try std.testing.expect(n.checkAndBumpRate(1, 99));
    // Blocked attempts do not extend the window.
    try std.testing.expect(n.checkAndBumpRate(0, 100));
    try std.testing.expect(!n.checkAndBumpRate(1, 100));
}

test "Notifier: zero interval and backwards clock" {
    var n = Notifier{ .rate_limit_ms = 0 };
    try std.testing.expect(n.checkAndBumpRate(42, 100));
    try std.testing.expect(n.checkAndBumpRate(42, 100));
    n.rate_limit_ms = 100;
    try std.testing.expect(n.checkAndBumpRate(42, 50));
    try std.testing.expect(!n.checkAndBumpRate(42, 51));
    try std.testing.expect(n.checkAndBumpRate(42, 150));
}

test "Notifier: bounded history FIFO-evicts without colliding source IDs" {
    var n = Notifier{ .rate_limit_ms = 1000 };
    for (0..rate_buckets) |id| try std.testing.expect(n.checkAndBumpRate(id, 0));
    try std.testing.expect(!n.checkAndBumpRate(0, 1));
    try std.testing.expect(n.checkAndBumpRate(std.math.maxInt(u64), 1));
    try std.testing.expect(!n.checkAndBumpRate(1, 1));
    try std.testing.expect(n.checkAndBumpRate(0, 1));
    try std.testing.expect(!n.checkAndBumpRate(std.math.maxInt(u64), 2));
}

test "Notifier: full-width timestamp and interval arithmetic" {
    var n = Notifier{ .rate_limit_ms = std.math.maxInt(u64) };
    try std.testing.expect(n.checkAndBumpRate(1, std.math.minInt(i64)));
    try std.testing.expect(!n.checkAndBumpRate(1, std.math.maxInt(i64) - 1));
    try std.testing.expect(n.checkAndBumpRate(1, std.math.maxInt(i64)));
}

test "notification text: bounded UTF-8, malformed input, and owned copy" {
    var buf: [5]u8 = undefined;
    copyUtf8Z(&buf, "a€z");
    try std.testing.expectEqualStrings("a€", std.mem.sliceTo(&buf, 0));
    copyUtf8Z(buf[0..4], "a€");
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&buf, 0));
    copyUtf8Z(&buf, "ok\xffbad");
    try std.testing.expectEqualStrings("ok", std.mem.sliceTo(&buf, 0));
    copyUtf8Z(&buf, "x\x00y");
    try std.testing.expectEqualStrings("x", std.mem.sliceTo(&buf, 0));
    copyUtf8Z(&buf, "");
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&buf, 0));
    var source = [_]u8{ 'o', 'k' };
    copyUtf8Z(&buf, &source);
    source[0] = 'x';
    try std.testing.expectEqualStrings("ok", std.mem.sliceTo(&buf, 0));
}
