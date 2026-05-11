const std = @import("std");
const objc = @import("objc");

const c_dispatch = @cImport({
    @cInclude("dispatch/dispatch.h");
});

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

/// State a notification carries. Mirrors `agent.state.Agent` minus
/// `idle`. Used as the rate-limit bucket key alongside client label
/// so different states from the same client get their own first
/// banner immediately (an `attention` doesn't suppress a follow-up
/// `error` even within the rate window).
pub const Kind = enum { attention, working, done, @"error" };

const RateEntry = struct {
    /// Hash of `client_label` (0 for anonymous / null) + Kind tag.
    /// Combined into one u64 so the lookup is a flat scan over a tiny
    /// fixed array — no allocator, no eviction policy beyond LRU on
    /// the ring.
    key: u64 = 0,
    /// Wall-clock ms of last banner delivery for this bucket.
    last_ms: i64 = 0,
};

/// Per-(client, kind) rate-limit ring. Sized for the realistic upper
/// bound (a handful of agents × four kinds) — overflow falls through
/// to the LRU slot with no warning, which just means the oldest
/// bucket's rate-limit memory is wiped. Cheaper than a hash table for
/// the expected ≤16 active entries.
const rate_buckets: usize = 16;

/// macOS notification sender via NSUserNotification (deprecated in 10.14
/// but functional through current macOS; UNUserNotificationCenter is the
/// modern path but requires a code-signed bundle, entitlements, and Zig
/// extern wrappers for block-based completion handlers — none of which
/// we want to take on yet). This is a transport swap from osascript;
/// behavior is identical.
pub const Notifier = struct {
    enabled: bool = true,
    /// Minimum interval between banners for the same (client, kind)
    /// tuple. Set from `notifications.rate_limit_ms`.
    rate_limit_ms: u64 = 30_000,
    rate_mutex: std.Thread.Mutex = .{},
    rate_ring: [rate_buckets]RateEntry = [_]RateEntry{.{}} ** rate_buckets,
    /// Next slot to overwrite on miss-after-full. Wraps mod
    /// rate_buckets — pure FIFO eviction; good enough for ≤16
    /// concurrent clients.
    rate_next_slot: usize = 0,

    /// Play a system sound. Always runs via `afplay` in a detached thread
    /// — NSSound's msgSend chain is documented as main-thread-only and
    /// crashes when called from the MCP HTTP thread. afplay has no such
    /// constraint and stays out of AppKit entirely.
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

        // execAfplay owns `path` and frees it after the subprocess exits.
        if (std.Thread.spawn(.{}, execAfplay, .{path})) |t| {
            t.detach();
        } else |_| {
            allocator.free(path);
        }
    }

    /// Backwards-compatible send: no rate limit, no kind/client
    /// bucketing. Internal hosts (config-reload warnings, etc.) use
    /// this path. MCP tool handlers should call `sendKind` so the
    /// rate-limit ring engages.
    pub fn send(self: *const Notifier, title: []const u8, body: []const u8) void {
        if (!self.enabled) return;
        deliver(title, body);
    }

    /// Rate-limited variant for agent-driven notifications. Returns
    /// true when a banner was delivered; false when the rate window
    /// for this (client, kind) tuple is still cooling down. The
    /// menubar + log surfaces always update regardless — this gate is
    /// purely about the noisy OS-level banner.
    pub fn sendKind(self: *Notifier, kind: Kind, client_label: ?[]const u8, title: []const u8, body: []const u8) bool {
        if (!self.enabled) return false;
        if (!self.checkAndBumpRate(kind, client_label)) return false;
        deliver(title, body);
        return true;
    }

    fn checkAndBumpRate(self: *Notifier, kind: Kind, client_label: ?[]const u8) bool {
        const now = std.time.milliTimestamp();
        const key = makeRateKey(kind, client_label);

        self.rate_mutex.lock();
        defer self.rate_mutex.unlock();

        // Hit: existing bucket — bump only when the window expired.
        for (&self.rate_ring) |*entry| {
            if (entry.key == key) {
                if (now - entry.last_ms < @as(i64, @intCast(self.rate_limit_ms))) return false;
                entry.last_ms = now;
                return true;
            }
        }
        // Miss: claim a free slot, else FIFO-evict.
        for (&self.rate_ring) |*entry| {
            if (entry.key == 0) {
                entry.key = key;
                entry.last_ms = now;
                return true;
            }
        }
        const slot = self.rate_next_slot;
        self.rate_next_slot = (slot + 1) % rate_buckets;
        self.rate_ring[slot] = .{ .key = key, .last_ms = now };
        return true;
    }
};

fn makeRateKey(kind: Kind, client_label: ?[]const u8) u64 {
    var h: u64 = std.hash.Wyhash.hash(0xD711, client_label orelse "");
    h ^= @as(u64, @intFromEnum(kind)) << 56;
    // Reserve 0 as the "empty slot" sentinel — flip away from it if
    // we land there exactly.
    if (h == 0) h = 1;
    return h;
}

fn deliver(title: []const u8, body: []const u8) void {
    const allocator = std.heap.page_allocator;
    const payload = allocator.create(Payload) catch return;
    payload.title = nulDupe(allocator, title) catch {
        allocator.destroy(payload);
        return;
    };
    payload.body = nulDupe(allocator, body) catch {
        allocator.free(payload.title);
        allocator.destroy(payload);
        return;
    };

    // Hot path called from MCP HTTP worker threads; AppKit /
    // NSUserNotificationCenter must run on main. dispatch_async_f
    // posts work to the main queue, which the AppKit run loop
    // drains. Payload is freed inside deliverOnMain.
    const main_queue = c_dispatch.dispatch_get_main_queue();
    dispatch_async_f(@ptrCast(main_queue), payload, &deliverOnMain);
}

const Payload = struct {
    /// NUL-terminated UTF-8 — stringWithUTF8String: requires that.
    title: []u8,
    body: []u8,
};

/// Allocate `bytes.len + 1`, copy in, write a trailing NUL. Returns a slice
/// of length `bytes.len + 1` (the NUL is included so free() sees the right
/// size; AppKit only reads up to the first NUL).
fn nulDupe(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf;
}

fn deliverOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const opaque_ptr = ctx orelse return;
    const payload: *Payload = @ptrCast(@alignCast(opaque_ptr));
    const allocator = std.heap.page_allocator;
    defer {
        allocator.free(payload.title);
        allocator.free(payload.body);
        allocator.destroy(payload);
    }

    const NSString = objc.getClass("NSString") orelse return;
    const NSUserNotification = objc.getClass("NSUserNotification") orelse return;
    const NSUserNotificationCenter = objc.getClass("NSUserNotificationCenter") orelse return;

    const ns_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(payload.title.ptr))});
    if (ns_title.value == null) return;
    const ns_body = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(payload.body.ptr))});
    if (ns_body.value == null) return;

    const note_alloc = NSUserNotification.msgSend(objc.Object, "alloc", .{});
    const note = note_alloc.msgSend(objc.Object, "init", .{});
    if (note.value == null) return;

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
    const home = std.posix.getenv("HOME") orelse return false;
    var buf: [512]u8 = undefined;
    const user_prefix = std.fmt.bufPrint(&buf, "{s}/Library/Sounds/", .{home}) catch return false;
    return std.mem.startsWith(u8, path, user_prefix);
}

fn execAfplay(path: []const u8) void {
    defer std.heap.page_allocator.free(path);
    var child = std.process.Child.init(
        &.{ "/usr/bin/afplay", path },
        std.heap.page_allocator,
    );
    child.spawn() catch return;
    _ = child.wait() catch {};
}

test "Notifier: rate limit blocks repeat within window" {
    var n = Notifier{ .enabled = true, .rate_limit_ms = 60_000 };
    // First call for (client=A, kind=attention) passes the gate.
    try std.testing.expect(n.checkAndBumpRate(.attention, "A"));
    // Repeat within window blocked.
    try std.testing.expect(!n.checkAndBumpRate(.attention, "A"));
    // Different kind for same client gets its own bucket.
    try std.testing.expect(n.checkAndBumpRate(.@"error", "A"));
    // Different client also passes.
    try std.testing.expect(n.checkAndBumpRate(.attention, "B"));
    // Null client (= internal hosts) has its own bucket distinct
    // from any labeled client.
    try std.testing.expect(n.checkAndBumpRate(.attention, null));
}

test "Notifier: rate limit clears after window" {
    var n = Notifier{ .enabled = true, .rate_limit_ms = 1 };
    try std.testing.expect(n.checkAndBumpRate(.attention, "X"));
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(n.checkAndBumpRate(.attention, "X"));
}
