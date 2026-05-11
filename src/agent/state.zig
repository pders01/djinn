const std = @import("std");

/// State of an AI agent connected via MCP. Pushed by tool calls; consumed by
/// menubar (Phase 3.3) and log panel (Phase 3.4).
pub const Agent = enum {
    idle,
    working,
    attention,
    done,
    @"error",
};

pub const LogEntry = struct {
    timestamp_ms: i64,
    level: Level,
    message: []const u8,
    /// Optional short label identifying which MCP client emitted the entry.
    /// Derived upstream from the request's User-Agent (6 hex chars). Owned
    /// alongside `message` and freed in deinit.
    client: ?[]const u8 = null,

    pub const Level = enum { info, warn, err };
};

const max_log_entries: usize = 256;

/// Mutex-protected agent state. MCP tool handlers call set/append from any
/// thread; UI consumers (menubar/panel) read snapshots on the main thread.
pub const AgentState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    state: Agent = .idle,
    message: []const u8 = "",
    message_owned: bool = false,
    log: std.ArrayList(LogEntry) = .{},
    /// Latest `attention` message that hasn't been auto-cleared by a
    /// subsequent `done` / `idle` transition or explicitly acked by
    /// the user. Surfaces in the log pane as a sticky banner so a
    /// blocked agent stays visible even when the user wasn't looking
    /// at the panel when the call arrived. Null = nothing pending.
    pinned_attention: ?[]const u8 = null,
    pinned_attention_owned: bool = false,

    pub fn init(allocator: std.mem.Allocator) AgentState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AgentState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.message_owned) self.allocator.free(self.message);
        if (self.pinned_attention_owned) {
            if (self.pinned_attention) |p| self.allocator.free(p);
        }
        for (self.log.items) |entry| {
            self.allocator.free(entry.message);
            if (entry.client) |c| self.allocator.free(c);
        }
        self.log.deinit(self.allocator);
    }

    pub fn setState(self: *AgentState, new_state: Agent, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.message_owned) self.allocator.free(self.message);
        self.message = try self.allocator.dupe(u8, message);
        self.message_owned = true;
        self.state = new_state;

        // Sticky-attention bookkeeping. .attention pins the message;
        // any non-attention transition (working / done / idle / error)
        // clears the pin so the banner doesn't outstay its welcome —
        // the log entry itself still records the event.
        if (new_state == .attention) {
            if (self.pinned_attention_owned) {
                if (self.pinned_attention) |p| self.allocator.free(p);
            }
            self.pinned_attention = try self.allocator.dupe(u8, message);
            self.pinned_attention_owned = true;
        } else {
            if (self.pinned_attention_owned) {
                if (self.pinned_attention) |p| self.allocator.free(p);
            }
            self.pinned_attention = null;
            self.pinned_attention_owned = false;
        }
    }

    /// User-driven clear of the sticky attention banner. Distinct from
    /// the auto-clear that fires on non-attention setState — lets the
    /// user dismiss without waiting for the agent to follow up.
    pub fn ackAttention(self: *AgentState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pinned_attention_owned) {
            if (self.pinned_attention) |p| self.allocator.free(p);
        }
        self.pinned_attention = null;
        self.pinned_attention_owned = false;
    }

    pub fn appendLog(self: *AgentState, level: LogEntry.Level, message: []const u8) !void {
        try self.appendLogFrom(level, message, null);
    }

    /// Variant used by MCP tool handlers — `client` is a short label
    /// (typically 6 hex chars) so log readers can tell concurrent agents
    /// apart. Pass null when the source is djinn itself.
    pub fn appendLogFrom(self: *AgentState, level: LogEntry.Level, message: []const u8, client: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Bounded ring buffer behavior — drop oldest if at cap.
        if (self.log.items.len >= max_log_entries) {
            const oldest = self.log.orderedRemove(0);
            self.allocator.free(oldest.message);
            if (oldest.client) |c| self.allocator.free(c);
        }

        const owned = try self.allocator.dupe(u8, message);
        const client_owned: ?[]const u8 = if (client) |c| try self.allocator.dupe(u8, c) else null;
        try self.log.append(self.allocator, .{
            .timestamp_ms = std.time.milliTimestamp(),
            .level = level,
            .message = owned,
            .client = client_owned,
        });
    }

    pub const Snapshot = struct {
        state: Agent,
        message: []const u8,
    };

    /// Take a read-only snapshot of the current state. Caller must not free
    /// the message — it's a borrow valid until next setState.
    pub fn snapshot(self: *AgentState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .state = self.state, .message = self.message };
    }

    /// Borrow the pinned attention message under the state mutex. Caller
    /// copies into a local buffer before releasing the mutex — the
    /// slice's lifetime ends at the next setState / ackAttention call.
    pub fn pinnedAttention(self: *AgentState, dst: []u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.pinned_attention orelse return null;
        const n = @min(p.len, dst.len);
        @memcpy(dst[0..n], p[0..n]);
        return n;
    }
};

test "AgentState: setState updates" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();

    try s.setState(.working, "compiling");
    const snap = s.snapshot();
    try std.testing.expectEqual(Agent.working, snap.state);
    try std.testing.expectEqualStrings("compiling", snap.message);
}

test "AgentState: appendLog stores entries" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();

    try s.appendLog(.info, "hello");
    try s.appendLog(.warn, "uhoh");
    try std.testing.expectEqual(@as(usize, 2), s.log.items.len);
    try std.testing.expectEqualStrings("hello", s.log.items[0].message);
    try std.testing.expectEqual(LogEntry.Level.warn, s.log.items[1].level);
}

test "AgentState: log bounded at max_log_entries" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();

    var i: usize = 0;
    while (i < max_log_entries + 10) : (i += 1) {
        try s.appendLog(.info, "x");
    }
    try std.testing.expectEqual(max_log_entries, s.log.items.len);
}

test "AgentState: attention pins; done clears; ack clears" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();

    try std.testing.expect(s.pinned_attention == null);
    try s.setState(.attention, "need input");
    try std.testing.expectEqualStrings("need input", s.pinned_attention.?);

    // Latest attention overrides earlier pinned message.
    try s.setState(.attention, "still blocked");
    try std.testing.expectEqualStrings("still blocked", s.pinned_attention.?);

    // .done auto-clears.
    try s.setState(.done, "unstuck");
    try std.testing.expect(s.pinned_attention == null);

    // ack also clears.
    try s.setState(.attention, "again");
    try std.testing.expect(s.pinned_attention != null);
    s.ackAttention();
    try std.testing.expect(s.pinned_attention == null);
}

test "AgentState: pinnedAttention copies into caller buffer" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();

    var buf: [32]u8 = undefined;
    try std.testing.expect(s.pinnedAttention(&buf) == null);

    try s.setState(.attention, "need input");
    const n = s.pinnedAttention(&buf) orelse unreachable;
    try std.testing.expectEqualStrings("need input", buf[0..n]);
}
