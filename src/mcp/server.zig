const std = @import("std");
const net = std.net;
const posix = std.posix;
const json = std.json;

/// Minimal MCP HTTP server. Binds 127.0.0.1, requires bearer token auth,
/// dispatches JSON-RPC over POST. Single connection thread per accept.
///
/// Streamable HTTP transport (MCP spec, March 2025): client sends JSON-RPC
/// request as POST body, server responds with single JSON-RPC response. SSE
/// streaming for server-initiated messages is deferred to Phase 4.
pub const McpServer = struct {
    allocator: std.mem.Allocator,
    listener: net.Server,
    port: u16,
    token: []const u8,
    handler: Handler,
    stop_flag: std.atomic.Value(bool),

    pub const Handler = struct {
        ctx: *anyopaque,
        dispatch: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: ?json.Value, id: ?json.Value, client: ?[]const u8) DispatchResult,
    };

    pub const DispatchResult = struct {
        /// JSON-encoded "result" value, or null for notifications.
        result: ?[]const u8 = null,
        /// JSON-RPC error code if dispatch failed (0 = no error).
        err_code: i32 = 0,
        err_message: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, handler: Handler) !McpServer {
        const addr = try net.Address.parseIp("127.0.0.1", 0);
        var listener = try addr.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        const bound_addr = listener.listen_address;
        const port = bound_addr.in.getPort();

        const token = try loadOrGenerateToken(allocator);

        return .{
            .allocator = allocator,
            .listener = listener,
            .port = port,
            .token = token,
            .handler = handler,
            .stop_flag = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *McpServer) void {
        self.stop_flag.store(true, .release);
        self.listener.deinit();
        self.allocator.free(self.token);
    }

    /// Accept loop — run on its own thread.
    ///
    /// Backoff schedule: doubles 1ms → 2 → 4 → … → 200ms after each
    /// `accept()` failure that isn't a listener teardown. Resets on
    /// any successful accept. Without this, a persistent failure (fd
    /// exhaustion, kernel hiccup) busy-loops the thread at ~100% CPU
    /// and floods stderr if we logged each one.
    pub fn run(self: *McpServer) void {
        var backoff_ms: u64 = 1;
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.listener.accept() catch |err| switch (err) {
                error.SocketNotListening => return,
                else => {
                    std.debug.print("warning: mcp accept failed: {} (backoff {d}ms)\n", .{ err, backoff_ms });
                    std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                    backoff_ms = @min(backoff_ms * 2, 200);
                    continue;
                },
            };
            backoff_ms = 1;
            self.handleConnection(conn);
        }
    }

    fn handleConnection(self: *McpServer, conn: net.Server.Connection) void {
        defer conn.stream.close();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf: [16 * 1024]u8 = undefined;
        const head_end = readHead(conn.stream, &buf) catch return;
        const head = buf[0..head_end];

        const req = parseRequest(head) orelse {
            writeStatus(conn.stream, 400, "Bad Request", "");
            return;
        };

        if (!std.ascii.eqlIgnoreCase(req.method, "POST")) {
            writeStatus(conn.stream, 405, "Method Not Allowed", "");
            return;
        }

        if (!checkAuth(head, self.token)) {
            writeStatus(conn.stream, 401, "Unauthorized", "");
            return;
        }

        // Read body. Content-Length parsed from headers; rest already in buf
        // after head_end.
        const cl = parseContentLength(head) orelse {
            writeStatus(conn.stream, 411, "Length Required", "");
            return;
        };
        if (cl > 1024 * 1024) {
            writeStatus(conn.stream, 413, "Payload Too Large", "");
            return;
        }

        const body = alloc.alloc(u8, cl) catch {
            writeStatus(conn.stream, 500, "Internal Server Error", "");
            return;
        };

        const already = buf.len - head_end;
        const initial = @min(already, cl);
        @memcpy(body[0..initial], buf[head_end .. head_end + initial]);
        var read_total: usize = initial;
        while (read_total < cl) {
            const n = conn.stream.read(body[read_total..]) catch return;
            if (n == 0) break;
            read_total += n;
        }
        if (read_total < cl) {
            writeStatus(conn.stream, 400, "Bad Request", "incomplete body");
            return;
        }

        // Short client tag derived from User-Agent (6 hex of SHA-256). Lets
        // log consumers distinguish concurrent agents without leaking the
        // full UA string.
        var client_buf: [6]u8 = undefined;
        const client: ?[]const u8 = if (parseHeader(head, "User-Agent")) |ua|
            shortClientId(ua, &client_buf)
        else
            null;

        const response = self.dispatchJsonRpc(alloc, body, client) catch {
            writeStatus(conn.stream, 500, "Internal Server Error", "");
            return;
        };

        writeJsonResponse(conn.stream, response) catch return;
    }

    fn dispatchJsonRpc(self: *McpServer, allocator: std.mem.Allocator, body: []const u8, client: ?[]const u8) ![]const u8 {
        var parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
            return formatError(allocator, null, -32700, "parse error");
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return formatError(allocator, null, -32600, "invalid request");

        const method_v = root.object.get("method") orelse return formatError(allocator, null, -32600, "missing method");
        if (method_v != .string) return formatError(allocator, null, -32600, "method not string");
        const id = root.object.get("id");
        const params = root.object.get("params");

        const result = self.handler.dispatch(self.handler.ctx, allocator, method_v.string, params, id, client);
        if (result.err_code != 0) {
            return formatError(allocator, id, result.err_code, result.err_message);
        }
        return formatResult(allocator, id, result.result orelse "null");
    }

    fn readHead(stream: net.Stream, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try stream.read(buf[total..]);
            if (n == 0) return error.UnexpectedEof;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                return idx + 4;
            }
        }
        return error.HeadTooLarge;
    }
};

const Request = struct {
    method: []const u8,
    path: []const u8,
};

fn parseRequest(head: []const u8) ?Request {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    const line = head[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const path = it.next() orelse return null;
    return .{ .method = method, .path = path };
}

fn parseContentLength(head: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, val, 10) catch null;
    }
    return null;
}

/// Look up a header by case-insensitive name. Returns the trimmed value, or
/// null if missing.
fn parseHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// Short stable id for a client: first 6 hex chars of SHA-256(User-Agent).
/// Stable across requests from the same client — different clients land in
/// different buckets with very high probability.
fn shortClientId(ua: []const u8, out: *[6]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ua, &digest, .{});
    const hex = "0123456789abcdef";
    for (0..3) |i| {
        out[i * 2] = hex[digest[i] >> 4];
        out[i * 2 + 1] = hex[digest[i] & 0x0F];
    }
    return out[0..];
}

fn checkAuth(head: []const u8, token: []const u8) bool {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(name, "Authorization")) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, val, prefix)) return false;
        return constantTimeEql(val[prefix.len..], token);
    }
    return false;
}

/// Constant-time byte-slice equality. Length mismatch short-circuits
/// (length is not secret); content compare folds every byte into the
/// accumulator before returning, so the loop's wall time depends only
/// on `min(a.len, b.len)`. `std.mem.eql` short-circuits on first
/// mismatch — fine for general use, leaks position to a local timing
/// observer when used on bearer tokens.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn writeStatus(stream: net.Stream, code: u16, reason: []const u8, body: []const u8) void {
    var buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ code, reason, body.len },
    ) catch return;
    _ = stream.writeAll(head) catch {};
    _ = stream.writeAll(body) catch {};
}

fn writeJsonResponse(stream: net.Stream, body: []const u8) !void {
    var buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    );
    try stream.writeAll(head);
    try stream.writeAll(body);
}

fn formatResult(allocator: std.mem.Allocator, id: ?json.Value, result_json: []const u8) ![]const u8 {
    var id_buf: [64]u8 = undefined;
    const id_str = formatIdJson(&id_buf, id);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_str, result_json },
    );
}

fn formatError(allocator: std.mem.Allocator, id: ?json.Value, code: i32, message: []const u8) ![]const u8 {
    var id_buf: [64]u8 = undefined;
    const id_str = formatIdJson(&id_buf, id);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id_str, code, message },
    );
}

fn formatIdJson(buf: []u8, id: ?json.Value) []const u8 {
    const v = id orelse return "null";
    return switch (v) {
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "null",
        .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s}) catch "null",
        else => "null",
    };
}

/// Generate 32 random bytes, hex-encode → 64-char token.
fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = try allocator.alloc(u8, 64);
    const charset = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0F];
    }
    return hex;
}

/// Load the persisted bearer token from `~/.config/djinn/token` or
/// generate + persist a new one. Token rotation per launch had a real
/// downside: every restart broke `.mcp.json` indirection in clients
/// (Claude Code etc.) since the bearer baked into the project file
/// went stale. Localhost-only listener + 0600 file perms means
/// keeping the token across launches is no weaker than rotating it.
fn loadOrGenerateToken(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return generateToken(allocator);
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.config/djinn", .{home});
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const file_path = try std.fmt.allocPrint(allocator, "{s}/token", .{dir_path});
    defer allocator.free(file_path);

    if (std.fs.cwd().openFile(file_path, .{})) |file| {
        defer file.close();
        const contents = file.readToEndAlloc(allocator, 256) catch return generateAndPersist(allocator, file_path);
        defer allocator.free(contents);
        const trimmed = std.mem.trim(u8, contents, " \t\n\r");
        if (trimmed.len == 64 and isHexLower(trimmed)) {
            return try allocator.dupe(u8, trimmed);
        }
    } else |_| {}

    return generateAndPersist(allocator, file_path);
}

fn generateAndPersist(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const token = try generateToken(allocator);
    if (std.fs.cwd().createFile(file_path, .{ .mode = 0o600 })) |file| {
        defer file.close();
        file.writeAll(token) catch {};
    } else |_| {}
    return token;
}

fn isHexLower(s: []const u8) bool {
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Write the MCP endpoint info to ~/.config/djinn/mcp.json so users can
/// paste it into Claude Code's `.mcp.json`. Permissions 0600 (token is
/// effectively a credential).
pub fn writeEndpointInfo(allocator: std.mem.Allocator, port: u16, token: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.config/djinn", .{home});
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const file_path = try std.fmt.allocPrint(allocator, "{s}/mcp.json", .{dir_path});
    defer allocator.free(file_path);

    const content = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "mcpServers": {{
        \\    "djinn": {{
        \\      "type": "http",
        \\      "url": "http://127.0.0.1:{d}",
        \\      "headers": {{
        \\        "Authorization": "Bearer {s}"
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\
    ,
        .{ port, token },
    );
    defer allocator.free(content);

    var file = try std.fs.cwd().createFile(file_path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);
}

// Tests
test "parseRequest: POST line" {
    const head = "POST / HTTP/1.1\r\nHost: x\r\n\r\n";
    const req = parseRequest(head).?;
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/", req.path);
}

test "parseContentLength: present" {
    const head = "POST / HTTP/1.1\r\nContent-Length: 42\r\nFoo: bar\r\n";
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength(head));
}

test "parseContentLength: missing" {
    const head = "POST / HTTP/1.1\r\nFoo: bar\r\n";
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(head));
}

test "checkAuth: matching bearer" {
    const head = "POST / HTTP/1.1\r\nAuthorization: Bearer abc123\r\n";
    try std.testing.expect(checkAuth(head, "abc123"));
}

test "checkAuth: wrong token" {
    const head = "POST / HTTP/1.1\r\nAuthorization: Bearer abc123\r\n";
    try std.testing.expect(!checkAuth(head, "different"));
}

test "checkAuth: no header" {
    const head = "POST / HTTP/1.1\r\n";
    try std.testing.expect(!checkAuth(head, "abc"));
}

test "checkAuth: case-insensitive header name" {
    const head = "POST / HTTP/1.1\r\nauthorization: Bearer xyz\r\n";
    try std.testing.expect(checkAuth(head, "xyz"));
}

test "shortClientId: stable + 6 hex chars" {
    var buf1: [6]u8 = undefined;
    var buf2: [6]u8 = undefined;
    const a = shortClientId("claude-code/0.1.0", &buf1);
    const b = shortClientId("claude-code/0.1.0", &buf2);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(usize, 6), a.len);
    for (a) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));

    var buf3: [6]u8 = undefined;
    const c = shortClientId("codex/2.0.0", &buf3);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "parseHeader: case insensitive name lookup" {
    const head = "POST / HTTP/1.1\r\nUser-Agent: claude/1\r\nFoo: bar\r\n";
    try std.testing.expectEqualStrings("claude/1", parseHeader(head, "user-agent").?);
    try std.testing.expectEqualStrings("bar", parseHeader(head, "Foo").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeader(head, "missing"));
}

test "generateToken: 64 hex chars" {
    const t = try generateToken(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 64), t.len);
    for (t) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}
