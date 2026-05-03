const std = @import("std");
const json = std.json;
const Dispatcher = @import("dispatch.zig").Dispatcher;
const AgentState = @import("../agent/state.zig").AgentState;
const Agent = @import("../agent/state.zig").Agent;
const LogEntry = @import("../agent/state.zig").LogEntry;
const Notifier = @import("../notify/darwin.zig").Notifier;

/// MCP tool surface for djinn. Tools push agent state to the user — they do
/// NOT control the popup window. Window control belongs to the user's
/// hotkey, not to the agent.
pub const ToolTable = struct {
    state: *AgentState,
    notifier: ?*const Notifier = null,
    attention_sound: ?[]const u8 = null,

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
            if (self.notifier) |n| {
                n.send("djinn", msg);
                n.playSound(self.attention_sound);
            }
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_progress")) {
            const msg = stringArg(args, "message") orelse "working";
            try self.state.setState(.working, msg);
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_done")) {
            const msg = stringArg(args, "message") orelse "done";
            try self.state.setState(.done, msg);
            try self.state.appendLogFrom(.info, msg, client);
            return .{ .text = "ack" };
        }

        if (std.mem.eql(u8, name, "djinn_error")) {
            const msg = stringArg(args, "message") orelse "error";
            try self.state.setState(.@"error", msg);
            try self.state.appendLogFrom(.err, msg, client);
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

        _ = allocator;
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
