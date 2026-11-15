//! Ordinary terminal notifications over org.freedesktop.Notifications.
//! Callers own visibility policy. This transport gates enabled/rate by
//! stable session ID and copies bounded UTF-8 text before queueing GDBus.
//! No agent kinds, state API, subprocesses, or detached IO workers.

const std = @import("std");
const platform = @import("../../io/platform.zig");
const gtk = @import("gtk.zig");
const gdbus = @import("gdbus.zig");

const RateEntry = struct {
    occupied: bool = false,
    source_id: u64 = 0,
    last_ms: i64 = 0,
};

/// Bounded FIFO history, matching macOS. An evicted source may deliver
/// again before its previous window expires. All u64 IDs, including 0,
/// are valid; occupancy is not encoded in the ID.
const rate_buckets: usize = 16;

pub const Options = struct {
    enabled: bool = true,
    rate_limit_ms: u64 = 30_000,
};

pub const Notifier = struct {
    enabled: bool = true,
    rate_limit_ms: u64 = 30_000,
    rate_mutex: std.Io.Mutex = .init,
    rate_ring: [rate_buckets]RateEntry = @splat(.{}),
    rate_next_slot: usize = 0,
    connection: ?*gdbus.GDBusConnection = null,
    conn_mutex: std.Io.Mutex = .init,
    stopped: bool = false,

    pub fn init(opts: Options) Notifier {
        return .{ .enabled = opts.enabled, .rate_limit_ms = opts.rate_limit_ms };
    }

    /// Entry stops callback producers before deinit and destroys process IO
    /// afterward. The connection lock also prevents send/teardown overlap.
    /// GDBus owns the queued call; it retains no Notifier or caller slices.
    pub fn deinit(self: *Notifier) void {
        const io = platform.io();
        self.conn_mutex.lockUncancelable(io);
        defer self.conn_mutex.unlock(io);
        self.stopped = true;
        if (self.connection) |connection| gdbus.g_object_unref(connection);
        self.connection = null;
    }

    /// Same terminal-first surface as macOS: stable session ID, title, body.
    pub fn send(self: *Notifier, session_id: u64, title: []const u8, body: []const u8) void {
        if (!self.enabled) return;
        if (!self.checkAndBumpRate(session_id, platform.milliTimestamp())) return;
        self.deliver(title, body);
    }

    /// Compatibility for callers handling BEL on the GTK main thread.
    /// Prefer VTE's ordinary audible bell. Custom macOS sound names are
    /// not interpreted as filesystem paths on Linux; use the display bell.
    pub fn playSound(_: *const Notifier, name: ?[]const u8) void {
        const requested = name orelse return;
        if (requested.len == 0) return;
        if (gtk.gdk_display_get_default()) |display| gtk.gdk_display_beep(display);
    }

    /// API parity only: the native display bell owns no background IO.
    pub fn shutdownSounds() void {}

    /// Explicit time makes policy tests deterministic, without sleeping or
    /// delivering notifications. Backward wall-clock jumps reset a window.
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

    fn deliver(self: *Notifier, title: []const u8, body: []const u8) void {
        const io = platform.io();
        self.conn_mutex.lockUncancelable(io);
        defer self.conn_mutex.unlock(io);
        if (self.stopped) return;
        const connection = self.ensureConnection() orelse return;

        var title_buf: [257]u8 = undefined;
        var body_buf: [4097]u8 = undefined;
        const params = buildNotifyParams(ztrunc(&title_buf, title), ztrunc(&body_buf, body));
        gdbus.g_dbus_connection_call(
            connection,
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "Notify",
            params,
            null,
            gdbus.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            null,
            null,
        );
    }

    /// Called with conn_mutex held. Retry a failed acquire on the next send.
    fn ensureConnection(self: *Notifier) ?*gdbus.GDBusConnection {
        if (self.connection) |connection| return connection;
        var err: ?*gdbus.GError = null;
        self.connection = gdbus.g_bus_get_sync(gdbus.G_BUS_TYPE_SESSION, null, &err);
        if (err) |e| {
            const message = if (e.message) |m| std.mem.span(m) else "(no message)";
            std.debug.print("notifier: session bus unavailable: {s}\n", .{message});
            gdbus.g_error_free(e);
        }
        return self.connection;
    }
};

inline fn vt(comptime spec: [:0]const u8) *const gdbus.GVariantType {
    return @ptrCast(spec.ptr);
}

/// Copy only valid, complete UTF-8 codepoints and stop at embedded NUL.
/// GVariant strings must be UTF-8; malformed terminal output must not
/// reach GLib's string assertions or split a multibyte tail.
fn ztrunc(buf: []u8, bytes: []const u8) [:0]u8 {
    std.debug.assert(buf.len > 0);
    const limit = @min(bytes.len, buf.len - 1);
    var end: usize = 0;
    while (end < limit and bytes[end] != 0) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[end]) catch break;
        if (len > limit - end) break;
        _ = std.unicode.utf8Decode(bytes[end..][0..len]) catch break;
        end += len;
    }
    @memcpy(buf[0..end], bytes[0..end]);
    buf[end] = 0;
    return buf[0..end :0];
}

/// Notify(s app, u replaces_id, s icon, s title, s body, as actions,
///        a{sv} hints, i timeout). Ordinary notifications use normal urgency.
fn buildNotifyParams(summary: [:0]const u8, body: [:0]const u8) *gdbus.GVariant {
    const hints = gdbus.g_variant_builder_new(vt("a{sv}"));
    const urgency = gdbus.g_variant_new_variant(gdbus.g_variant_new_byte(1));
    const entry = gdbus.g_variant_new_dict_entry(gdbus.g_variant_new_string("urgency"), urgency);
    gdbus.g_variant_builder_add_value(hints, entry);
    const hints_v = gdbus.g_variant_builder_end(hints);
    gdbus.g_variant_builder_unref(hints);

    const tuple = gdbus.g_variant_builder_new(vt("(susssasa{sv}i)"));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string("djinn"));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_uint32(0));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string("utilities-terminal"));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string(summary.ptr));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string(body.ptr));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_array(vt("s"), null, 0));
    gdbus.g_variant_builder_add_value(tuple, hints_v);
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_int32(-1));
    const params = gdbus.g_variant_builder_end(tuple);
    gdbus.g_variant_builder_unref(tuple);
    return params;
}

test "Notifier native API compiles without notification delivery" {
    std.testing.refAllDecls(Notifier);
}

test "Notifier: stable session IDs have independent rate windows" {
    var n = Notifier.init(.{ .rate_limit_ms = 100 });
    try std.testing.expect(n.checkAndBumpRate(0, 1000));
    try std.testing.expect(!n.checkAndBumpRate(0, 1099));
    try std.testing.expect(n.checkAndBumpRate(1, 1099));
    try std.testing.expect(n.checkAndBumpRate(std.math.maxInt(u64), 1099));
    try std.testing.expect(n.checkAndBumpRate(0, 1100));
}

test "Notifier: zero interval, clock rollback and full-width interval" {
    var n = Notifier.init(.{ .rate_limit_ms = 100 });
    try std.testing.expect(n.checkAndBumpRate(42, 1000));
    try std.testing.expect(n.checkAndBumpRate(42, 900));
    try std.testing.expect(!n.checkAndBumpRate(42, 999));
    try std.testing.expect(n.checkAndBumpRate(42, 1000));
    n.rate_limit_ms = 0;
    try std.testing.expect(n.checkAndBumpRate(42, 1000));
    n.rate_limit_ms = std.math.maxInt(u64);
    try std.testing.expect(!n.checkAndBumpRate(42, std.math.maxInt(i64)));
}

test "Notifier: bounded history FIFO-evicts the oldest source" {
    var n = Notifier.init(.{ .rate_limit_ms = 100 });
    for (0..rate_buckets) |id| try std.testing.expect(n.checkAndBumpRate(id, 1000));
    try std.testing.expect(!n.checkAndBumpRate(0, 1001));
    try std.testing.expect(n.checkAndBumpRate(rate_buckets, 1001));
    try std.testing.expect(!n.checkAndBumpRate(1, 1001));
    try std.testing.expect(n.checkAndBumpRate(0, 1001));
}

test "ztrunc: ascii truncates byte-exact and nul-terminates" {
    var buf: [8]u8 = undefined;
    const out = ztrunc(&buf, "hello world");
    try std.testing.expectEqualStrings("hello w", out);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
}

test "ztrunc: utf-8 snap back from mid-codepoint" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("é", ztrunc(&buf, "éé"));
}

test "ztrunc: empty, malformed and embedded NUL input" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", ztrunc(&buf, ""));
    try std.testing.expectEqualStrings("ok", ztrunc(&buf, "ok\x00rest"));
    try std.testing.expectEqualStrings("ok", ztrunc(&buf, "ok\xffrest"));
    try std.testing.expectEqualStrings("ok", ztrunc(&buf, "ok\xe2\x82"));
}

test "Notifier: disabled send never acquires a bus connection" {
    var n = Notifier.init(.{ .enabled = false });
    // The enabled gate precedes even bus discovery. No native delivery.
    n.send(0, "fixture", "disabled");
    try std.testing.expect(!n.enabled);
    try std.testing.expect(n.connection == null);
    try std.testing.expect(!n.rate_ring[0].occupied);
}

test "Notifier: deinit on never-connected notifier is idempotent" {
    var n = Notifier.init(.{});
    n.deinit();
    n.deinit();
    try std.testing.expect(n.stopped);
    try std.testing.expect(n.connection == null);
}
