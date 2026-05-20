//! System notification delivery via `org.freedesktop.Notifications`.
//!
//! Mirrors `src/notify/darwin.zig`'s surface — same `Kind` enum, same
//! rate-limit ring, same `send` / `sendKind` / `playSound` methods —
//! so any caller written against the darwin Notifier compiles
//! unchanged on linux once the platform abstraction routes through
//! here. That's the lever the MCP-wiring task (TODO #2) will use to
//! drop `mcp/tools.zig`'s direct `notify/darwin.zig` import.
//!
//! Delivery path: `g_dbus_connection_call` (async, null callback —
//! we don't need the returned notification id) to
//! `org.freedesktop.Notifications.Notify` on `/org/freedesktop/Notifications`.
//! Every desktop with a notification daemon implements this interface:
//! KDE (plasmashell), GNOME (gnome-shell), XFCE (xfce4-notifyd),
//! dunst, mako, etc.
//!
//! Connection lifecycle: the session bus connection is acquired lazily
//! on first `deliver` under `conn_mutex` and cached on the Notifier
//! for the rest of the process. `deinit` unrefs it. Earlier the
//! delivery path called `g_bus_get_sync` per send, relying on GLib's
//! internal connection cache — but that cache is keyed under an
//! internal global lock, and `deliver` runs from the MCP server
//! worker thread once per agent transition. Holding our own ref
//! keeps the hot path mutex-free past the (one-time) acquire.
//!
//! Sound playback piggybacks on the notification: we set the
//! `sound-name` hint to a freedesktop sound-naming-spec entry per
//! Kind, and the notification daemon plays the sound. No separate
//! subprocess for the common path. `playSound` (the
//! terminal-bell-driven path that darwin uses for `bell-sound`) is a
//! stub-with-warning: the implicit per-kind sound-name hint already
//! fires through `deliver`, so attention events DO play a sound on
//! linux — but a user's `bell-sound` config override is ignored.
//! `playSound` logs the override name on first call so the gap is
//! visible (`tools.zig` invokes it whenever `sendKind` succeeds,
//! once per 30s per (kind, client) bucket by rate-limit default).
//! The proper wiring lands when VTE's `bell` signal is connected:
//! either send a second notification with the user-supplied
//! sound-name, or call libcanberra's `ca_context_play_full`.
//!
//! Rate-limit logic is duplicated from `notify/darwin.zig` rather
//! than DRY'd into a shared file: `src/notify/` is on the don't-touch
//! list during the linux port. A later refactor can pull the ring +
//! Kind enum into `src/notify/core.zig`; for now the duplication
//! costs ~40 lines and keeps the darwin path byte-for-byte intact.

const std = @import("std");
const builtin = @import("builtin");
const gdbus = @import("gdbus.zig");

/// Single-shot latch for `playSound`'s first-call warning. Module
/// scope (not per-Notifier) because the message describes a
/// platform-wide capability gap, not a per-instance state — and the
/// `playSound` signature takes `*const Notifier`, matching darwin,
/// so per-instance mutation isn't available without a wider API
/// change.
var play_sound_stub_logged: std.atomic.Value(bool) = .init(false);

const GVariant = gdbus.GVariant;
const GVariantBuilder = gdbus.GVariantBuilder;
const GVariantType = gdbus.GVariantType;
const GError = gdbus.GError;
const G_BUS_TYPE_SESSION = gdbus.G_BUS_TYPE_SESSION;
const G_DBUS_CALL_FLAGS_NONE = gdbus.G_DBUS_CALL_FLAGS_NONE;

inline fn vt(comptime spec: [:0]const u8) *const GVariantType {
    return @ptrCast(spec.ptr);
}

// ─── Public surface ──────────────────────────────────────────────────

/// Match darwin's Kind verbatim so callers stay portable. Used as both
/// a urgency hint (attention/error → critical) and a rate-limit
/// bucket key.
pub const Kind = enum { attention, working, done, @"error" };

const RateEntry = struct {
    key: u64 = 0,
    last_ms: i64 = 0,
};

const rate_buckets: usize = 16;

pub const Options = struct {
    enabled: bool = true,
    rate_limit_ms: u64 = 30_000,
};

pub const Notifier = struct {
    enabled: bool = true,
    rate_limit_ms: u64 = 30_000,
    rate_mutex: std.Thread.Mutex = .{},
    rate_ring: [rate_buckets]RateEntry = [_]RateEntry{.{}} ** rate_buckets,
    rate_next_slot: usize = 0,

    /// Cached session bus connection. Acquired lazily on first
    /// `deliver` under `conn_mutex` and held for the Notifier's
    /// lifetime. Each `g_bus_get_sync` call acquires GLib's internal
    /// global bus-table lock; doing it per-`deliver` would contend
    /// with every other module that talks D-Bus (hotkey, tray) on a
    /// shot the MCP server worker thread fires for every agent
    /// transition. `deinit` unrefs the connection. `null` while we
    /// haven't tried yet AND after a failed acquire (we retry next
    /// `deliver`; transient bus-unavailable shouldn't strand the
    /// notifier permanently).
    connection: ?*gdbus.GDBusConnection = null,
    conn_mutex: std.Thread.Mutex = .{},

    /// Construct a Notifier with the runtime options. Direct
    /// `Notifier{...}` construction bypasses zero-init for the mutexes
    /// (they survive default-init by accident under Zig 0.15 but the
    /// contract isn't documented); `init` makes the zero-init contract
    /// explicit, in one place, and matches the
    /// `deliver`/`deinit` pairing.
    pub fn init(opts: Options) Notifier {
        return .{
            .enabled = opts.enabled,
            .rate_limit_ms = opts.rate_limit_ms,
        };
    }

    /// Drop the cached bus connection. Safe to call without a prior
    /// `init` (the `null` connection path is a no-op) so a teardown
    /// race during early-startup-failure paths can't crash.
    pub fn deinit(self: *Notifier) void {
        self.conn_mutex.lock();
        defer self.conn_mutex.unlock();
        if (self.connection) |c| {
            gdbus.g_object_unref(c);
            self.connection = null;
        }
    }

    /// Same shape as darwin: stateless from the caller's POV. The
    /// cached `connection` is an implementation detail behind
    /// `conn_mutex`; callers don't need to know about it.
    pub fn send(self: *Notifier, title: []const u8, body: []const u8) void {
        if (!self.enabled) return;
        deliver(self, title, body, .normal, null);
    }

    /// Rate-limited variant. Returns true when a banner was delivered;
    /// false when the (client, kind) bucket is still cooling down.
    pub fn sendKind(
        self: *Notifier,
        kind: Kind,
        client_label: ?[]const u8,
        title: []const u8,
        body: []const u8,
    ) bool {
        if (!self.enabled) return false;
        if (!self.checkAndBumpRate(kind, client_label)) return false;
        deliver(self, title, body, urgencyFor(kind), soundFor(kind));
        return true;
    }

    /// Standalone sound playback. Used by darwin for terminal-bell
    /// (`bell-sound` config). On linux the implicit per-kind hint
    /// already plays through the notification daemon's `sound-name`
    /// path; a user's `bell-sound` override is currently ignored.
    /// Log once per process so the gap is visible — `tools.zig`
    /// invokes this after every successful `sendKind`, so the call
    /// rate is bounded by the Notifier's rate-limit ring (30s
    /// default per (kind, client) bucket). Returns silently
    /// thereafter to keep stderr quiet for the rest of the session.
    /// Surface matches darwin so callers compile across platforms.
    pub fn playSound(_: *const Notifier, name: ?[]const u8) void {
        if (play_sound_stub_logged.swap(true, .seq_cst)) return;
        const requested = name orelse "(none)";
        std.debug.print(
            "notifier: playSound(\"{s}\") ignored on linux — bell-sound override " ++
                "needs VTE bell-signal wiring; the per-kind notification " ++
                "sound-name hint still fires through deliver()\n",
            .{requested},
        );
    }

    /// Acquire (or return the cached) session bus connection.
    /// Returns null if the bus is unavailable — caller treats that as
    /// "drop this notification" rather than a hard error. A failed
    /// acquire leaves `connection = null` so the next call retries;
    /// transient bus loss (e.g. dbus-daemon restart) recovers on its
    /// own without needing a Notifier teardown.
    fn ensureConnection(self: *Notifier) ?*gdbus.GDBusConnection {
        self.conn_mutex.lock();
        defer self.conn_mutex.unlock();
        if (self.connection) |c| return c;
        var err: ?*GError = null;
        const conn = gdbus.g_bus_get_sync(G_BUS_TYPE_SESSION, null, &err);
        if (conn == null) {
            if (err) |e| {
                const msg = if (e.message) |m| std.mem.span(m) else "(no message)";
                std.debug.print("notifier: g_bus_get_sync failed: {s}\n", .{msg});
                gdbus.g_error_free(e);
            }
            return null;
        }
        self.connection = conn;
        return conn;
    }

    fn checkAndBumpRate(self: *Notifier, kind: Kind, client_label: ?[]const u8) bool {
        const now = std.time.milliTimestamp();
        const key = makeRateKey(kind, client_label);

        self.rate_mutex.lock();
        defer self.rate_mutex.unlock();

        for (&self.rate_ring) |*entry| {
            if (entry.key == key) {
                if (now - entry.last_ms < @as(i64, @intCast(self.rate_limit_ms))) return false;
                entry.last_ms = now;
                return true;
            }
        }
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

// ─── Internal delivery ───────────────────────────────────────────────

const Urgency = enum(u8) {
    low = 0,
    normal = 1,
    critical = 2,
};

fn urgencyFor(kind: Kind) Urgency {
    return switch (kind) {
        .attention, .@"error" => .critical,
        .working, .done => .normal,
    };
}

/// freedesktop sound-naming-spec entries. Daemons that honor the
/// `sound-name` hint play these; others ignore the hint silently. We
/// pick names that exist in every theme we've seen (Plasma's default,
/// Sound Theme Spec compliant themes).
fn soundFor(kind: Kind) ?[:0]const u8 {
    return switch (kind) {
        .attention => "dialog-warning",
        .@"error" => "dialog-error",
        .done => "complete",
        .working => null,
    };
}

/// Build + dispatch the `Notify` D-Bus call. Title + body are NOT
/// expected to be NUL-terminated — we dup them into bounded buffers
/// because GVariant string constructors require sentinel terminators
/// and the caller's slices typically come from non-terminated config /
/// agent output.
///
/// Truncates at 1023 bytes (title) and 4095 bytes (body) — these are
/// well above any sane banner length and below the freedesktop spec's
/// suggested limits. Past that, the body content was never going to
/// fit in a notification anyway, so silently truncating beats
/// allocator-busy slow paths.
fn deliver(
    self: *Notifier,
    title: []const u8,
    body: []const u8,
    urgency: Urgency,
    sound_name: ?[:0]const u8,
) void {
    const conn = self.ensureConnection() orelse return;

    var title_buf: [1024]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    const title_z = ztrunc(&title_buf, title);
    const body_z = ztrunc(&body_buf, body);

    const params = buildNotifyParams(title_z, body_z, urgency, sound_name);

    gdbus.g_dbus_connection_call(
        conn,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        params,
        null,
        G_DBUS_CALL_FLAGS_NONE,
        -1,
        null,
        null, // no callback — we don't need the returned id
        null,
    );
}

/// Copy `bytes` into `buf`, truncating to len-1 and writing the
/// trailing NUL. Returns a sentinel-terminated slice pointing into
/// `buf` — caller is responsible for the buffer's lifetime.
///
/// Truncation snaps backward to a UTF-8 code-point boundary so a
/// multi-byte char isn't split mid-sequence. The freedesktop
/// `Notify` body field is documented as UTF-8; a half-byte tail
/// produces an invalid-encoding error on KDE / GNOME notification
/// daemons and the banner silently disappears.
fn ztrunc(buf: []u8, bytes: []const u8) [:0]u8 {
    const max = buf.len - 1;
    var n = @min(bytes.len, max);
    if (n < bytes.len) n = utf8FloorBoundary(bytes, n);
    @memcpy(buf[0..n], bytes[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

/// Walk backward from `cap` to the start of the UTF-8 code point
/// that `bytes[cap..]` would otherwise begin in the middle of. A
/// continuation byte has the form `10xxxxxx`; the leading byte of a
/// multi-byte sequence is `11xxxxxx`. Both ASCII (`0xxxxxxx`) and
/// "we're at a leader" land cleanly at `cap`. Walks at most three
/// bytes (longest UTF-8 sequence is 4 bytes — leader + 3 conts).
/// Returns `cap` unchanged when it's at or past `bytes.len` (caller
/// is asking for "no truncation"; the byte-index access below would
/// otherwise read past the slice).
fn utf8FloorBoundary(bytes: []const u8, cap: usize) usize {
    if (cap >= bytes.len) return cap;
    var i: usize = cap;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

test "ztrunc: ascii truncates byte-exact" {
    var buf: [8]u8 = undefined;
    const out = ztrunc(&buf, "hello world");
    try std.testing.expectEqualStrings("hello w", out);
}

test "ztrunc: utf-8 snap back from mid-codepoint" {
    var buf: [4]u8 = undefined; // capacity 3 bytes + NUL
    // "é" = 0xC3 0xA9 (2 bytes). With cap=3 we'd land on byte 3 of
    // "éé" (0xC3 0xA9 0xC3 | 0xA9), splitting the second codepoint.
    // Floor snaps back to byte 2 — the start of the second 'é'.
    const out = ztrunc(&buf, "éé");
    try std.testing.expectEqualStrings("é", out);
}

test "ztrunc: empty input" {
    var buf: [4]u8 = undefined;
    const out = ztrunc(&buf, "");
    try std.testing.expectEqualStrings("", out);
}

/// Notify signature:
///   (s app_name, u replaces_id, s app_icon, s summary, s body,
///    as actions, a{sv} hints, i expire_timeout) → u id
fn buildNotifyParams(
    summary: [:0]u8,
    body: [:0]u8,
    urgency: Urgency,
    sound_name: ?[:0]const u8,
) *GVariant {
    // hints dict
    const hints = gdbus.g_variant_builder_new(vt("a{sv}"));
    addByteEntry(hints, "urgency", @intFromEnum(urgency));
    if (sound_name) |s| addStringEntry(hints, "sound-name", s.ptr);
    const hints_v = gdbus.g_variant_builder_end(hints);
    gdbus.g_variant_builder_unref(hints);

    const tup = gdbus.g_variant_builder_new(vt("(susssasa{sv}i)"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string("djinn"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_uint32(0)); // replaces_id
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string("utilities-terminal"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string(summary.ptr));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string(body.ptr));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_array(vt("s"), null, 0)); // actions
    gdbus.g_variant_builder_add_value(tup, hints_v);
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_int32(-1)); // expire_timeout: daemon default
    const params = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return params;
}

fn addStringEntry(builder: *GVariantBuilder, key: [*:0]const u8, value: [*:0]const u8) void {
    const wrapped = gdbus.g_variant_new_variant(gdbus.g_variant_new_string(value));
    const entry = gdbus.g_variant_new_dict_entry(gdbus.g_variant_new_string(key), wrapped);
    gdbus.g_variant_builder_add_value(builder, entry);
}

fn addByteEntry(builder: *GVariantBuilder, key: [*:0]const u8, value: u8) void {
    const wrapped = gdbus.g_variant_new_variant(gdbus.g_variant_new_byte(value));
    const entry = gdbus.g_variant_new_dict_entry(gdbus.g_variant_new_string(key), wrapped);
    gdbus.g_variant_builder_add_value(builder, entry);
}

// ─── Rate-limit key derivation ───────────────────────────────────────

fn makeRateKey(kind: Kind, client_label: ?[]const u8) u64 {
    var h: u64 = std.hash.Wyhash.hash(0xD711, client_label orelse "");
    h ^= @as(u64, @intFromEnum(kind)) << 56;
    if (h == 0) h = 1;
    return h;
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Notifier: rate limit blocks repeat within window" {
    if (builtin.os.tag != .linux) return;
    var n = Notifier.init(.{ .enabled = true, .rate_limit_ms = 60_000 });
    defer n.deinit();
    try std.testing.expect(n.checkAndBumpRate(.attention, "A"));
    try std.testing.expect(!n.checkAndBumpRate(.attention, "A"));
    try std.testing.expect(n.checkAndBumpRate(.@"error", "A"));
    try std.testing.expect(n.checkAndBumpRate(.attention, "B"));
    try std.testing.expect(n.checkAndBumpRate(.attention, null));
}

test "Notifier: rate limit clears after window" {
    if (builtin.os.tag != .linux) return;
    var n = Notifier.init(.{ .enabled = true, .rate_limit_ms = 1 });
    defer n.deinit();
    try std.testing.expect(n.checkAndBumpRate(.attention, "X"));
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(n.checkAndBumpRate(.attention, "X"));
}

test "Notifier: deinit on never-connected notifier is a no-op" {
    if (builtin.os.tag != .linux) return;
    var n = Notifier.init(.{});
    // No delivery, so `connection` stays null. `deinit` must not
    // crash on the null-connection path — early teardown paths
    // (e.g. config parse error before MCP startup) rely on this.
    n.deinit();
}

test "urgencyFor maps kinds correctly" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqual(Urgency.critical, urgencyFor(.attention));
    try std.testing.expectEqual(Urgency.critical, urgencyFor(.@"error"));
    try std.testing.expectEqual(Urgency.normal, urgencyFor(.working));
    try std.testing.expectEqual(Urgency.normal, urgencyFor(.done));
}

test "ztrunc nul-terminates within buffer" {
    if (builtin.os.tag != .linux) return;
    var buf: [16]u8 = undefined;
    const out = ztrunc(&buf, "hello");
    try std.testing.expectEqualStrings("hello", out);
    try std.testing.expectEqual(@as(u8, 0), buf[5]);

    // Truncation case: 32-char input into 16-byte buffer → 15 bytes
    // copied + NUL at index 15.
    const long_in = "0123456789abcdefghij";
    const out2 = ztrunc(&buf, long_in);
    try std.testing.expectEqual(@as(usize, 15), out2.len);
    try std.testing.expectEqual(@as(u8, 0), buf[15]);
}
