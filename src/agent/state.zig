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

    pub fn init(allocator: std.mem.Allocator) AgentState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AgentState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.message_owned) self.allocator.free(self.message);
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
