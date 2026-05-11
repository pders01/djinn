const std = @import("std");
const json = std.json;
const Dispatcher = @import("dispatch.zig").Dispatcher;
const AgentState = @import("../agent/state.zig").AgentState;
const Agent = @import("../agent/state.zig").Agent;
const LogEntry = @import("../agent/state.zig").LogEntry;
const Notifier = @import("../notify/darwin.zig").Notifier;
const app_state = @import("../app.zig");

/// Look up the per-client mute flag. Wired through `app.g.config` so
/// hot-config-reload edits take effect on the next tool call without
/// rebuilding the ToolTable. Anonymous (null) client always passes.
fn clientMuted(client: ?[]const u8) bool {
    const id = client orelse return false;
    const cfg = app_state.g.config orelse return false;
    if (cfg.findClient(id)) |e| return e.mute;
    return false;
}

/// MCP tool surface for djinn. Tools push agent state to the user — they do
/// NOT control the popup window. Window control belongs to the user's
/// hotkey, not to the agent.
pub const ToolTable = struct {
    state: *AgentState,
    /// Mutable — `sendKind` updates the per-(client, kind) rate-limit
    /// ring under an internal mutex.
    notifier: ?*Notifier = null,
    attention_sound: ?[]const u8 = null,
    /// Per-state banner gates. Pushed from `config.notifications.*`
    /// at startup and on hot-config-reload. Defaults match
    /// NotifyConfig so test ToolTables (constructed without a config)
    /// still get attention/error banners.
    notify_on_attention: bool = true,
    notify_on_error: bool = true,
    notify_on_done: bool = false,
    notify_on_progress: bool = false,

    pub fn table(self: *ToolTable) Dispatcher.ToolTable {
        return .{
            .ctx = @ptrCast(self),
            .list_json = listJson,
            .call = callImpl,
        };
    }

    fn listJson(_: *anyopaque, _: std.mem.Allocator) anyerror![]const u8 {
        // Static JSON — tool catalog never changes at runtime.
        return tools_json;
    }

    fn callImpl(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
        args: ?json.Value,
        client: ?[]const u8,
    ) anyerror!Dispatcher.ToolTable.CallResult {
        const self: *ToolTable = @ptrCast(@alignCast(ctx));

        if (std.mem.eql(u8, name, "djinn_attention")) {
            const msg = stringArg(args, "message") orelse "agent needs attention";
            try self.state.setState(.attention, msg);
            try self.state.appendLogFrom(.warn, msg, client);
            if (self.notify_on_attention and !clientMuted(client)) {
                if (self.notifier) |n| {
                    if (n.sendKind(.attention, client, "djinn", msg)) {
                        n.playSound(self.attention_sound);
                    }
                }
            }
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_progress")) {
            const msg = stringArg(args, "message") orelse "working";
            try self.state.setState(.working, msg);
            if (self.notify_on_progress and !clientMuted(client)) {
                if (self.notifier) |n| _ = n.sendKind(.working, client, "djinn", msg);
            }
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_done")) {
            const msg = stringArg(args, "message") orelse "done";
            try self.state.setState(.done, msg);
            try self.state.appendLogFrom(.info, msg, client);
            if (self.notify_on_done and !clientMuted(client)) {
                if (self.notifier) |n| _ = n.sendKind(.done, client, "djinn", msg);
            }
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_error")) {
            const msg = stringArg(args, "message") orelse "error";
            try self.state.setState(.@"error", msg);
            try self.state.appendLogFrom(.err, msg, client);
            if (self.notify_on_error and !clientMuted(client)) {
                if (self.notifier) |n| _ = n.sendKind(.@"error", client, "djinn", msg);
            }
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_log")) {
            const msg = stringArg(args, "message") orelse return .{ .text = "missing message", .is_error = true };
            const level_str = stringArg(args, "level") orelse "info";
            const level: LogEntry.Level = if (std.mem.eql(u8, level_str, "warn"))
                .warn
            else if (std.mem.eql(u8, level_str, "error"))
                .err
            else
                .info;
            try self.state.appendLogFrom(level, msg, client);
            return .{ .text = "ack" };
        }

        // Read tools — agents call these to introspect user-visible
        // state (recent log entries, pinned attention, active profile)
        // and decide whether to push more context or back off. Pairs
        // with the write surface so a multi-agent session can act on
        // what the user is actually seeing.
        if (std.mem.eql(u8, name, "djinn_recent_logs")) {
            const max_n: usize = blk: {
                const v = intArg(args, "count") orelse break :blk 50;
                if (v <= 0) break :blk 50;
                if (v > 256) break :blk 256;
                break :blk @intCast(v);
            };
            const text = try renderRecentLogs(allocator, self.state, max_n);
            return .{ .text = text };
        }

        if (std.mem.eql(u8, name, "djinn_recent_attentions")) {
            const text = try renderRecentAttentions(allocator, self.state);
            return .{ .text = text };
        }

        if (std.mem.eql(u8, name, "djinn_active_profile")) {
            const text = try renderActiveProfile(allocator);
            return .{ .text = text };
        }

        return .{ .text = "unknown tool", .is_error = true };
    }
};

fn stringArg(args: ?json.Value, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn intArg(args: ?json.Value, key: []const u8) ?i64 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

const dispatch_mod = @import("dispatch.zig");

/// Build a JSON array of the last `max_n` log entries. Each entry
/// renders as `{"ts":<i64>,"level":"info|warn|error","message":"…",
/// "client":"…"}`. Message + client are JSON-escaped via
/// `dispatch.jsonEscape`. Caller owns the returned slice; allocator
/// is the per-request arena so freeing is automatic on response.
fn renderRecentLogs(allocator: std.mem.Allocator, state: *AgentState, max_n: usize) ![]const u8 {
    state.mutex.lock();
    defer state.mutex.unlock();

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    const total = state.log.items.len;
    const start = if (total > max_n) total - max_n else 0;

    try w.writeAll("[");
    var first = true;
    for (state.log.items[start..]) |entry| {
        if (!first) try w.writeAll(",");
        first = false;
        const level_str = switch (entry.level) {
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
        const msg_esc = try dispatch_mod.jsonEscape(allocator, entry.message);
        defer allocator.free(msg_esc);
        try w.print("{{\"ts\":{d},\"level\":\"{s}\",\"message\":\"{s}\"", .{
            entry.timestamp_ms,
            level_str,
            msg_esc,
        });
        if (entry.client) |c| {
            const c_esc = try dispatch_mod.jsonEscape(allocator, c);
            defer allocator.free(c_esc);
            try w.print(",\"client\":\"{s}\"", .{c_esc});
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON object describing the current attention surface:
/// `{"pinned":"…"|null,"recent":[<warn-level log entries>]}`. The
/// `recent` array uses the same shape as `djinn_recent_logs` but
/// filtered to warn entries — same source the menubar / banner
/// consume.
fn renderRecentAttentions(allocator: std.mem.Allocator, state: *AgentState) ![]const u8 {
    state.mutex.lock();
    defer state.mutex.unlock();

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.writeAll("{\"pinned\":");
    if (state.pinned_attention) |p| {
        const esc = try dispatch_mod.jsonEscape(allocator, p);
        defer allocator.free(esc);
        try w.print("\"{s}\"", .{esc});
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"recent\":[");
    var first = true;
    for (state.log.items) |entry| {
        if (entry.level != .warn) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const msg_esc = try dispatch_mod.jsonEscape(allocator, entry.message);
        defer allocator.free(msg_esc);
        try w.print("{{\"ts\":{d},\"message\":\"{s}\"", .{ entry.timestamp_ms, msg_esc });
        if (entry.client) |c| {
            const c_esc = try dispatch_mod.jsonEscape(allocator, c);
            defer allocator.free(c_esc);
            try w.print(",\"client\":\"{s}\"", .{c_esc});
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON object describing the active profile:
/// `{"name":"…","label":"…","cwd":"…"|null,"command":"…"}`. Pulls
/// from `app.g.session_manager.active()`.
fn renderActiveProfile(allocator: std.mem.Allocator) ![]const u8 {
    const sm = app_state.g.session_manager orelse return try allocator.dupe(u8, "{\"name\":null}");
    if (sm.sessions.items.len == 0) return try allocator.dupe(u8, "{\"name\":null}");
    const active = sm.active();

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    const name_esc = try dispatch_mod.jsonEscape(allocator, active.profile.name);
    defer allocator.free(name_esc);
    const label_esc = try dispatch_mod.jsonEscape(allocator, active.profile.label());
    defer allocator.free(label_esc);
    const cmd_esc = try dispatch_mod.jsonEscape(allocator, active.profile.command);
    defer allocator.free(cmd_esc);

    try w.print("{{\"name\":\"{s}\",\"label\":\"{s}\",\"command\":\"{s}\"", .{
        name_esc, label_esc, cmd_esc,
    });
    if (active.profile.cwd) |c| {
        const c_esc = try dispatch_mod.jsonEscape(allocator, c);
        defer allocator.free(c_esc);
        try w.print(",\"cwd\":\"{s}\"", .{c_esc});
    } else {
        try w.writeAll(",\"cwd\":null");
    }
    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

const tools_json =
    \\[
    \\  {
    \\    "name": "djinn_attention",
    \\    "description": "Signal that the agent needs the user's attention. Use when blocked on a decision, awaiting input, or hitting a confirmation prompt. Updates djinn's menubar to an attention state.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "message": { "type": "string", "description": "Short description of what's needed" }
    \\      },
    \\      "required": ["message"]
    \\    }
    \\  },
    \\  {
    \\    "name": "djinn_progress",
    \\    "description": "Report ongoing work. Use to surface progress milestones (3/8 files compiled, etc.) so the user can see status without focusing the terminal.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "message": { "type": "string", "description": "Short progress description" }
    \\      },
    \\      "required": ["message"]
    \\    }
    \\  },
    \\  {
    \\    "name": "djinn_done",
    \\    "description": "Mark the current task complete. Sends a notification and returns the menubar to a quiescent state.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "message": { "type": "string", "description": "Summary of what completed" }
    \\      },
    \\      "required": ["message"]
    \\    }
    \\  },
    \\  {
    \\    "name": "djinn_error",
    \\    "description": "Report a failure. Updates the menubar to an error state and notifies the user.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "message": { "type": "string", "description": "Error description" }
    \\      },
    \\      "required": ["message"]
    \\    }
    \\  },
    \\  {
    \\    "name": "djinn_log",
    \\    "description": "Append a structured log entry to djinn's side panel. Use for events that aren't terminal text but matter for the human reviewer (decisions taken, files touched, external API calls).",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "message": { "type": "string", "description": "Log message" },
    \\        "level": { "type": "string", "enum": ["info", "warn", "error"], "description": "Severity (default info)" }
    \\      },
    \\      "required": ["message"]
    \\    }
    \\  },
    \\  {
    \\    "name": "djinn_recent_logs",
    \\    "description": "Read recent log entries from djinn's side panel. Use to introspect what the user has already seen — decide whether to push more context or back off if the panel is already busy. Returns a JSON array of {ts, level, message, client?} objects.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "count": { "type": "integer", "description": "Max entries to return (default 50, max 256)" }
    \\      }
    \\    }
    \\  },
    \\  {
    \\    "name": "djinn_recent_attentions",
    \\    "description": "Read the current attention surface: the pinned message (if any) plus recent warn-level entries. Returns a JSON object {pinned: string|null, recent: [...]}. Use to check whether the user has unacknowledged blocks before queuing another attention.",
    \\    "inputSchema": { "type": "object", "properties": {} }
    \\  },
    \\  {
    \\    "name": "djinn_active_profile",
    \\    "description": "Read the active djinn profile (name, label, cwd, spawn command). Useful for multi-profile setups where the agent's behavior should depend on which session the user is currently looking at.",
    \\    "inputSchema": { "type": "object", "properties": {} }
    \\  }
    \\]
;

test "ToolTable: djinn_progress updates state" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"hi\"}", .{});
    defer parsed.deinit();

    const r = try t.call(t.ctx, std.testing.allocator, "djinn_progress", parsed.value, null);
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(Agent.working, s.snapshot().state);
}

test "ToolTable: unknown tool returns error" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    const r = try t.call(t.ctx, std.testing.allocator, "djinn_nonexistent", null, null);
    try std.testing.expect(r.is_error);
}

test "ToolTable: djinn_attention sets state + appends warn log" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"need input\"}", .{});
    defer parsed.deinit();

    const r = try t.call(t.ctx, std.testing.allocator, "djinn_attention", parsed.value, null);
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(Agent.attention, s.snapshot().state);
    try std.testing.expectEqual(@as(usize, 1), s.log.items.len);
    try std.testing.expectEqual(LogEntry.Level.warn, s.log.items[0].level);
}

test "ToolTable: djinn_done sets state + info log" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"shipped\"}", .{});
    defer parsed.deinit();

    const r = try t.call(t.ctx, std.testing.allocator, "djinn_done", parsed.value, null);
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(Agent.done, s.snapshot().state);
    try std.testing.expectEqual(LogEntry.Level.info, s.log.items[0].level);
}

test "ToolTable: djinn_error sets state + err log" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"boom\"}", .{});
    defer parsed.deinit();

    const r = try t.call(t.ctx, std.testing.allocator, "djinn_error", parsed.value, null);
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(Agent.@"error", s.snapshot().state);
    try std.testing.expectEqual(LogEntry.Level.err, s.log.items[0].level);
}

test "ToolTable: djinn_log level mapping" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var p_info = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"a\"}", .{});
    defer p_info.deinit();
    var p_warn = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"b\",\"level\":\"warn\"}", .{});
    defer p_warn.deinit();
    var p_err = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"c\",\"level\":\"error\"}", .{});
    defer p_err.deinit();
    var p_unk = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"d\",\"level\":\"bogus\"}", .{});
    defer p_unk.deinit();

    _ = try t.call(t.ctx, std.testing.allocator, "djinn_log", p_info.value, null);
    _ = try t.call(t.ctx, std.testing.allocator, "djinn_log", p_warn.value, null);
    _ = try t.call(t.ctx, std.testing.allocator, "djinn_log", p_err.value, null);
    _ = try t.call(t.ctx, std.testing.allocator, "djinn_log", p_unk.value, null);

    try std.testing.expectEqual(@as(usize, 4), s.log.items.len);
    try std.testing.expectEqual(LogEntry.Level.info, s.log.items[0].level);
    try std.testing.expectEqual(LogEntry.Level.warn, s.log.items[1].level);
    try std.testing.expectEqual(LogEntry.Level.err, s.log.items[2].level);
    // Unknown level falls back to info.
    try std.testing.expectEqual(LogEntry.Level.info, s.log.items[3].level);
}

test "ToolTable: djinn_log without message returns error" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();

    const r = try t.call(t.ctx, std.testing.allocator, "djinn_log", parsed.value, null);
    try std.testing.expect(r.is_error);
    try std.testing.expectEqual(@as(usize, 0), s.log.items.len);
}

test "ToolTable: client label flows into log entry" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    var tools = ToolTable{ .state = &s };
    const t = tools.table();

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"message\":\"hi\"}", .{});
    defer parsed.deinit();

    _ = try t.call(t.ctx, std.testing.allocator, "djinn_log", parsed.value, "abc123");
    try std.testing.expectEqualStrings("abc123", s.log.items[0].client.?);
}

test "renderRecentLogs: empty state yields empty array" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    const out = try renderRecentLogs(std.testing.allocator, &s, 10);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "renderRecentLogs: shape + client field" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    try s.appendLog(.info, "hello");
    try s.appendLogFrom(.warn, "need input", "abc123");
    const out = try renderRecentLogs(std.testing.allocator, &s, 10);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"message\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":\"warn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"client\":\"abc123\"") != null);
}

test "renderRecentLogs: count caps tail" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    try s.appendLog(.info, "a");
    try s.appendLog(.info, "b");
    try s.appendLog(.info, "c");
    const out = try renderRecentLogs(std.testing.allocator, &s, 2);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"message\":\"a\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"message\":\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"message\":\"c\"") != null);
}

test "renderRecentAttentions: pinned + recent warn filter" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    try s.setState(.attention, "blocked");
    try s.appendLog(.info, "noise");
    try s.appendLog(.warn, "earlier attention");
    const out = try renderRecentAttentions(std.testing.allocator, &s);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"pinned\":\"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "earlier attention") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "noise") == null);
}

test "renderRecentAttentions: no pin null" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    const out = try renderRecentAttentions(std.testing.allocator, &s);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"pinned\":null,\"recent\":[]}", out);
}

test "renderRecentLogs: escapes quotes in message" {
    var s = AgentState.init(std.testing.allocator);
    defer s.deinit();
    try s.appendLog(.info, "he said \"hi\"");
    const out = try renderRecentLogs(std.testing.allocator, &s, 10);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"hi\\\"") != null);
}
