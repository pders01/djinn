//! Filter + header bookkeeping for the linux log pane.
//!
//! Extracted from `log_pane.zig` to separate the pure-data logic
//! (case-folded filter buffer, last-client tracking for grouped
//! headers) from the widget construction + signal wiring. The
//! widget side calls into this model from its hot paths:
//!
//!   - `pollTick` / `appendRangeLocked` ask `matchesFilter` whether
//!     to skip a row, then `shouldEmitHeader` whether to render a
//!     `{client} · HH:MM` header above it, then `updateLastClient`
//!     once the body row lands.
//!   - `rebuildAll` calls `resetGrouping` so the first row of the
//!     rebuilt list emits a fresh header instead of inheriting the
//!     pre-rebuild client state (ring evicting the oldest entry
//!     would otherwise silently drop the visual group break).
//!   - `onSearchChanged` calls `setFilter` with the GtkSearchEntry's
//!     current text, then triggers a full rebuild.
//!
//! Buffer sizes mirror the AgentState side: client names cap at
//! 128 bytes (covers "claude-code" / "codex" / arbitrary user-typed
//! ids with headroom); filter needles cap at 256 bytes (any longer
//! and the user is probably mis-typing into the wrong field, silent
//! clip is friendlier than a hard reject). Filter text is stored
//! case-folded so the per-entry match is one `mem.indexOf` against
//! a case-folded haystack instead of streaming `ascii.toLower` on
//! both sides.

const std = @import("std");
const LogEntry = @import("../../agent/state.zig").LogEntry;

pub const LogModel = struct {
    /// Active filter needle, case-folded to lowercase at write time.
    /// Empty (`filter_len == 0`) matches everything. 256-byte cap
    /// matches darwin's `LogView.filter_buf`.
    filter_buf: [256]u8 = undefined,
    filter_len: usize = 0,

    /// Client name of the last body row we rendered. Drives
    /// client-grouped header emission via `shouldEmitHeader`.
    /// 128 bytes covers any realistic MCP client name. Mirrors
    /// darwin's `LogView.last_client_*`.
    last_client_buf: [128]u8 = undefined,
    last_client_len: usize = 0,

    /// `false` after a rebuild or any null-client entry breaks the
    /// group — the next non-null client emits a fresh header.
    /// Distinct from `last_client_len == 0` because an empty-string
    /// client (never observed in practice) would otherwise collapse
    /// the "unknown" and "matched empty" cases.
    last_client_known: bool = false,

    /// Case-insensitive substring match against `entry.message +
    /// entry.client`. Empty filter passes everything. Haystack is
    /// built once into a stack buffer so the hot path is a single
    /// `mem.indexOf`. 512 bytes covers the AgentState message cap
    /// plus a long client id; overflow truncates the haystack,
    /// which is the right trade — extreme outliers shouldn't match
    /// the trailing bytes anyway.
    pub fn matchesFilter(self: *const LogModel, entry: LogEntry) bool {
        if (self.filter_len == 0) return true;
        const needle = self.filter_buf[0..self.filter_len];

        var hay_buf: [512]u8 = undefined;
        var hay_len: usize = 0;

        const msg_take = @min(entry.message.len, hay_buf.len - hay_len);
        for (entry.message[0..msg_take]) |c| {
            hay_buf[hay_len] = std.ascii.toLower(c);
            hay_len += 1;
        }

        if (entry.client) |client| {
            if (hay_len < hay_buf.len) {
                hay_buf[hay_len] = ' ';
                hay_len += 1;
            }
            const client_take = @min(client.len, hay_buf.len - hay_len);
            for (client[0..client_take]) |c| {
                hay_buf[hay_len] = std.ascii.toLower(c);
                hay_len += 1;
            }
        }

        return std.mem.indexOf(u8, hay_buf[0..hay_len], needle) != null;
    }

    /// True when the entry needs a `{client} · HH:MM` header above
    /// it: non-null client AND (either no prior client recorded or
    /// the recorded client differs). Null-client entries
    /// (djinn-internal log lines) never trigger a header — they
    /// break the group instead, so the next non-null client gets a
    /// fresh header. Caller emits the header row, then calls
    /// `updateLastClient(entry.client)` after the body row lands.
    pub fn shouldEmitHeader(self: *const LogModel, entry: LogEntry) bool {
        const client = entry.client orelse return false;
        if (!self.last_client_known) return true;
        return !std.mem.eql(u8, client, self.last_client_buf[0..self.last_client_len]);
    }

    /// Stamp the last-client buffer with the just-rendered entry's
    /// client. Non-null clients overwrite the buffer + set
    /// `known=true`; null clients break the group so the next
    /// non-null client emits a fresh header. Mirrors darwin's
    /// `log_view.zig:339` reset-on-null pattern.
    pub fn updateLastClient(self: *LogModel, client: ?[]const u8) void {
        if (client) |c| {
            const n = @min(c.len, self.last_client_buf.len);
            @memcpy(self.last_client_buf[0..n], c[0..n]);
            self.last_client_len = n;
            self.last_client_known = true;
        } else {
            self.last_client_known = false;
            self.last_client_len = 0;
        }
    }

    /// Replace the filter needle with `text`, case-folding to
    /// lowercase as we go. Empty text clears the filter. Caller is
    /// responsible for triggering whatever re-render the new filter
    /// implies — `setFilter` is pure state mutation.
    pub fn setFilter(self: *LogModel, text: []const u8) void {
        const take = @min(text.len, self.filter_buf.len);
        self.filter_len = take;
        for (text[0..take], 0..) |c, i| {
            self.filter_buf[i] = std.ascii.toLower(c);
        }
    }

    /// Drop the last-client state so the next `shouldEmitHeader`
    /// call against a non-null client returns true. Called by the
    /// rebuild branch so a ring-eviction rebuild that happens to
    /// land on the same client as before the evict still emits a
    /// visible group header.
    pub fn resetGrouping(self: *LogModel) void {
        self.last_client_known = false;
        self.last_client_len = 0;
    }

    /// True when an active filter is rejecting some entries (i.e.
    /// the needle is non-empty). Read by the placeholder picker so
    /// "no matches" vs "no activity" reflects the actual state.
    pub fn hasActiveFilter(self: *const LogModel) bool {
        return self.filter_len > 0;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "matchesFilter: empty needle passes everything" {
    var m = LogModel{};
    const entry = LogEntry{
        .timestamp_ms = 0,
        .level = .info,
        .message = "anything goes",
    };
    try std.testing.expect(m.matchesFilter(entry));
}

test "matchesFilter: case-insensitive substring on message" {
    var m = LogModel{};
    m.setFilter("BUILD");
    try std.testing.expect(m.matchesFilter(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "starting build pipeline",
    }));
    try std.testing.expect(!m.matchesFilter(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "unrelated chatter",
    }));
}

test "matchesFilter: client text included in haystack" {
    var m = LogModel{};
    m.setFilter("claude");
    try std.testing.expect(m.matchesFilter(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "request received",
        .client = "claude-code",
    }));
    try std.testing.expect(!m.matchesFilter(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "request received",
        .client = "codex",
    }));
}

test "shouldEmitHeader: first non-null client emits" {
    var m = LogModel{};
    try std.testing.expect(m.shouldEmitHeader(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "hi",
        .client = "claude",
    }));
}

test "shouldEmitHeader: same client suppresses" {
    var m = LogModel{};
    m.updateLastClient("claude");
    try std.testing.expect(!m.shouldEmitHeader(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "hi",
        .client = "claude",
    }));
}

test "shouldEmitHeader: client change emits" {
    var m = LogModel{};
    m.updateLastClient("claude");
    try std.testing.expect(m.shouldEmitHeader(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "hi",
        .client = "codex",
    }));
}

test "shouldEmitHeader: null client never emits" {
    var m = LogModel{};
    m.updateLastClient("claude");
    try std.testing.expect(!m.shouldEmitHeader(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "hi",
        .client = null,
    }));
}

test "resetGrouping: forces fresh header on next non-null client" {
    var m = LogModel{};
    m.updateLastClient("claude");
    m.resetGrouping();
    try std.testing.expect(m.shouldEmitHeader(.{
        .timestamp_ms = 0,
        .level = .info,
        .message = "hi",
        .client = "claude",
    }));
}

test "setFilter: case-folds to lowercase" {
    var m = LogModel{};
    m.setFilter("MixedCase");
    try std.testing.expectEqualStrings("mixedcase", m.filter_buf[0..m.filter_len]);
    try std.testing.expect(m.hasActiveFilter());
}

test "setFilter: empty text clears the filter" {
    var m = LogModel{};
    m.setFilter("set");
    m.setFilter("");
    try std.testing.expect(!m.hasActiveFilter());
}
