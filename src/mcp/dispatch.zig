const std = @import("std");
const json = std.json;
const McpServer = @import("server.zig").McpServer;

/// MCP protocol dispatcher. Implements the JSON-RPC methods the MCP spec
/// requires (initialize, tools/list, tools/call). Tool execution is
/// delegated to a tool table — empty in Phase 3.1, populated in Phase 3.2.
pub const Dispatcher = struct {
    tool_table: ToolTable,

    pub const ToolTable = struct {
        ctx: *anyopaque,
        list_json: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
        call: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, args: ?json.Value, client: ?[]const u8) anyerror!CallResult,

        pub const CallResult = struct {
            text: []const u8 = "ok",
            is_error: bool = false,
        };
    };

    pub fn handler(self: *Dispatcher) McpServer.Handler {
        return .{
            .ctx = @ptrCast(self),
            .dispatch = dispatchImpl,
        };
    }

    fn dispatchImpl(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: ?json.Value,
        id: ?json.Value,
        client: ?[]const u8,
    ) McpServer.DispatchResult {
        const self: *Dispatcher = @ptrCast(@alignCast(ctx));

        if (std.mem.eql(u8, method, "initialize")) {
            const result = std.fmt.allocPrint(
                allocator,
                "{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"djinn\",\"version\":\"{s}\"}}}}",
                .{@import("../version.zig").string},
            ) catch return errorResult(-32603, "internal");
            return .{ .result = result };
        }

        if (std.mem.eql(u8, method, "notifications/initialized")) {
            // Notification — no response (id should be null).
            _ = id;
            return .{ .result = null };
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            const list = self.tool_table.list_json(self.tool_table.ctx, allocator) catch return errorResult(-32603, "list failed");
            const result = std.fmt.allocPrint(allocator, "{{\"tools\":{s}}}", .{list}) catch return errorResult(-32603, "internal");
            return .{ .result = result };
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            const p = params orelse return errorResult(-32602, "missing params");
            if (p != .object) return errorResult(-32602, "params not object");
            const name_v = p.object.get("name") orelse return errorResult(-32602, "missing name");
            if (name_v != .string) return errorResult(-32602, "name not string");
            const args = p.object.get("arguments");

            const call_result = self.tool_table.call(self.tool_table.ctx, allocator, name_v.string, args, client) catch return errorResult(-32603, "tool call failed");

            const is_err: []const u8 = if (call_result.is_error) "true" else "false";
            // Escape the text content so tools can return JSON-shaped
            // payloads (read tools do this) without breaking the
            // enclosing JSON-RPC envelope.
            const escaped = jsonEscape(allocator, call_result.text) catch return errorResult(-32603, "internal");
            defer allocator.free(escaped);
            const result = std.fmt.allocPrint(
                allocator,
                "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":{s}}}",
                .{ escaped, is_err },
            ) catch return errorResult(-32603, "internal");
            return .{ .result = result };
        }

        return errorResult(-32601, "method not found");
    }
};

fn errorResult(code: i32, msg: []const u8) McpServer.DispatchResult {
    return .{ .err_code = code, .err_message = msg };
}

/// Escape a string for safe inclusion as a JSON string literal.
/// Caller owns the returned slice. Handles ", \, control chars per
/// RFC 8259 §7. Worst case ~6× expansion (control byte → \uXXXX);
/// preallocated upper bound covers it.
pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, s.len * 6 + 1);
    var n: usize = 0;
    for (s) |c| switch (c) {
        '"' => { buf[n] = '\\'; buf[n + 1] = '"'; n += 2; },
        '\\' => { buf[n] = '\\'; buf[n + 1] = '\\'; n += 2; },
        '\n' => { buf[n] = '\\'; buf[n + 1] = 'n'; n += 2; },
        '\r' => { buf[n] = '\\'; buf[n + 1] = 'r'; n += 2; },
        '\t' => { buf[n] = '\\'; buf[n + 1] = 't'; n += 2; },
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            const hex = "0123456789abcdef";
            buf[n + 0] = '\\';
            buf[n + 1] = 'u';
            buf[n + 2] = '0';
            buf[n + 3] = '0';
            buf[n + 4] = hex[(c >> 4) & 0xF];
            buf[n + 5] = hex[c & 0xF];
            n += 6;
        },
        else => {
            buf[n] = c;
            n += 1;
        },
    };
    return try allocator.realloc(buf, n);
}

test "jsonEscape: passthrough + escape" {
    const a = std.testing.allocator;
    const e1 = try jsonEscape(a, "hello");
    defer a.free(e1);
    try std.testing.expectEqualStrings("hello", e1);

    const e2 = try jsonEscape(a, "he said \"hi\"");
    defer a.free(e2);
    try std.testing.expectEqualStrings("he said \\\"hi\\\"", e2);

    const e3 = try jsonEscape(a, "line1\nline2");
    defer a.free(e3);
    try std.testing.expectEqualStrings("line1\\nline2", e3);
}

test "Dispatcher: initialize returns protocol envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "initialize", null, null, null);
    try std.testing.expectEqual(@as(i32, 0), r.err_code);
    try std.testing.expect(r.result != null);
    try std.testing.expect(std.mem.indexOf(u8, r.result.?, "\"protocolVersion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.result.?, "\"djinn\"") != null);
}

test "Dispatcher: notifications/initialized has null result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "notifications/initialized", null, null, null);
    try std.testing.expectEqual(@as(i32, 0), r.err_code);
    try std.testing.expect(r.result == null);
}

test "Dispatcher: tools/list wraps tool catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "tools/list", null, null, null);
    try std.testing.expectEqual(@as(i32, 0), r.err_code);
    try std.testing.expectEqualStrings("{\"tools\":[]}", r.result.?);
}

test "Dispatcher: tools/call missing params errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "tools/call", null, null, null);
    try std.testing.expectEqual(@as(i32, -32602), r.err_code);
}

test "Dispatcher: tools/call non-object params errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try json.parseFromSlice(json.Value, arena.allocator(), "[1,2,3]", .{});
    defer parsed.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "tools/call", parsed.value, null, null);
    try std.testing.expectEqual(@as(i32, -32602), r.err_code);
}

test "Dispatcher: tools/call missing name errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try json.parseFromSlice(json.Value, arena.allocator(), "{\"arguments\":{}}", .{});
    defer parsed.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "tools/call", parsed.value, null, null);
    try std.testing.expectEqual(@as(i32, -32602), r.err_code);
}

test "Dispatcher: tools/call dispatches into table + wraps content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try json.parseFromSlice(json.Value, arena.allocator(), "{\"name\":\"x\",\"arguments\":{}}", .{});
    defer parsed.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "tools/call", parsed.value, null, null);
    try std.testing.expectEqual(@as(i32, 0), r.err_code);
    // Empty table returns is_error=true with text "no tools registered".
    try std.testing.expect(std.mem.indexOf(u8, r.result.?, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.result.?, "no tools registered") != null);
}

test "Dispatcher: unknown method returns -32601" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = EmptyToolTable{};
    var d = Dispatcher{ .tool_table = empty.table() };
    const h = d.handler();

    const r = h.dispatch(h.ctx, arena.allocator(), "bogus/method", null, null, null);
    try std.testing.expectEqual(@as(i32, -32601), r.err_code);
}

/// Empty tool table — Phase 3.1 placeholder until Phase 3.2 adds real tools.
pub const EmptyToolTable = struct {
    pub fn table(self: *EmptyToolTable) Dispatcher.ToolTable {
        return .{
            .ctx = @ptrCast(self),
            .list_json = listJson,
            .call = callImpl,
        };
    }

    fn listJson(_: *anyopaque, _: std.mem.Allocator) anyerror![]const u8 {
        return "[]";
    }

    fn callImpl(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?json.Value, _: ?[]const u8) anyerror!Dispatcher.ToolTable.CallResult {
        return .{ .text = "no tools registered", .is_error = true };
    }
};
