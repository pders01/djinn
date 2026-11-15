//! Local, same-UID window controls for compositor bindings and the CLI.
//! One newline- or EOF-terminated command per connection; never agent RPC.
const std = @import("std");
const io = @import("../../io/platform.zig");
const gtk = @import("gtk.zig");
const c = std.c;
pub const Command = enum { toggle, show, hide, quit };
pub const Handler = struct {
    ctx: *anyopaque,
    on_command: *const fn (*anyopaque, Command) void,
};
const IN = 1;
const ERR = 8;
const HUP = 16;
const NVAL = 32;
extern "c" fn g_unix_fd_add(c_int, c_uint, *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;

pub const Ipc = struct {
    ctx: *Context,
    pub fn init(allocator: std.mem.Allocator, handler: Handler) !Ipc {
        const path = try resolveSocketPath(allocator);
        errdefer allocator.free(path);
        const lock_path = try std.fmt.allocPrintSentinel(allocator, "{s}.lock", .{path}, 0);
        defer allocator.free(lock_path);
        // Serialize stale-socket cleanup with every djinn instance. Never
        // unlink the lock inode: doing so permits two simultaneous owners.
        const lock_fd = c.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
        if (lock_fd < 0) return error.LockFailed;
        errdefer _ = c.close(lock_fd);
        if (c.flock(lock_fd, 2 | 4) != 0) return error.AlreadyRunning;
        const addr = try address(path);
        const fd = try socket(true);
        errdefer _ = c.close(fd);
        // Do not remove a live legacy instance's socket (it may predate
        // our lock). A refused connect is the only stale-socket case.
        const probe = try socket(true);
        defer _ = c.close(probe);
        if (c.connect(probe, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) == 0) return error.AlreadyRunning;
        switch (c.errno(-1)) {
            .NOENT => {},
            .AGAIN, .INPROGRESS => return error.AlreadyRunning,
            .CONNREFUSED => {
                const stat = try std.Io.Dir.cwd().statFile(io.io(), path, .{ .follow_symlinks = false });
                if (stat.kind != .unix_domain_socket) return error.UnsafeSocketPath;
                if (c.unlink(path) != 0) return error.UnlinkFailed;
            },
            else => return error.ConnectFailed,
        }
        // bind is the only operation that needs the restrictive umask.
        const old_mask = c.umask(0o077);
        const rc = c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        _ = c.umask(old_mask);
        if (rc != 0) return error.BindFailed;
        errdefer _ = c.unlink(path);
        if (c.listen(fd, 8) != 0) return error.ListenFailed;
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .allocator = allocator, .handler = handler, .fd = fd, .lock_fd = lock_fd, .path = path };
        ctx.source = g_unix_fd_add(fd, IN | ERR | HUP | NVAL, listenReady, ctx);
        if (ctx.source == 0) return error.SourceFailed;
        return .{ .ctx = ctx };
    }
    pub fn deinit(self: *Ipc) void {
        const ctx = self.ctx;
        if (ctx.source != 0) _ = gtk.g_source_remove(ctx.source);
        while (ctx.clients) |client| client.destroy();
        _ = c.close(ctx.fd);
        _ = c.unlink(ctx.path);
        _ = c.close(ctx.lock_fd);
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }
};
const Context = struct {
    allocator: std.mem.Allocator,
    handler: Handler,
    fd: c_int,
    lock_fd: c_int,
    path: [:0]u8,
    source: c_uint = 0,
    clients: ?*Client = null,
    client_count: usize = 0,
};
const Client = struct {
    parent: *Context,
    next: ?*Client,
    fd: c_int,
    source: c_uint = 0,
    timeout: c_uint = 0,
    buffer: [64]u8 = undefined,
    len: usize = 0,
    fn destroy(self: *Client) void {
        const parent = self.parent;
        if (self.source != 0) _ = gtk.g_source_remove(self.source);
        if (self.timeout != 0) _ = gtk.g_source_remove(self.timeout);
        _ = c.close(self.fd);
        var link = &parent.clients;
        while (link.*) |entry| {
            if (entry == self) {
                link.* = entry.next;
                break;
            }
            link = &entry.next;
        }
        parent.client_count -= 1;
        parent.allocator.destroy(self);
    }
    fn dispatch(self: *Client) void {
        const command = parseCommand(self.buffer[0..self.len]);
        const handler = self.parent.handler;
        self.destroy();
        if (command) |cmd| handler.on_command(handler.ctx, cmd);
    }
};
fn listenReady(fd: c_int, condition: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return 0));
    if (condition & (ERR | HUP | NVAL) != 0) {
        ctx.source = 0;
        return 0;
    }
    for (0..32) |_| {
        const peer = c.accept4(fd, null, null, c.SOCK.NONBLOCK | c.SOCK.CLOEXEC);
        if (peer < 0) break;
        const Cred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };
        var cred: Cred = undefined;
        var len: c.socklen_t = @sizeOf(Cred);
        if (ctx.client_count >= 32 or c.getsockopt(peer, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0 or cred.uid != c.getuid()) {
            _ = c.close(peer);
            continue;
        }
        const client = ctx.allocator.create(Client) catch {
            _ = c.close(peer);
            continue;
        };
        client.* = .{ .parent = ctx, .next = ctx.clients, .fd = peer };
        ctx.clients = client;
        ctx.client_count += 1;
        client.source = g_unix_fd_add(peer, IN | ERR | HUP | NVAL, clientReady, client);
        client.timeout = gtk.g_timeout_add(1000, clientExpired, client);
        if (client.source == 0 or client.timeout == 0) client.destroy();
    }
    return 1;
}
fn clientReady(fd: c_int, condition: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(data orelse return 0));
    if (condition & (ERR | NVAL) != 0) {
        client.source = 0;
        client.destroy();
        return 0;
    }
    while (client.len < client.buffer.len) {
        const n = c.recv(fd, client.buffer[client.len..].ptr, client.buffer.len - client.len, 0);
        if (n == 0) {
            client.source = 0;
            client.dispatch();
            return 0;
        }
        if (n < 0) switch (c.errno(n)) {
            .INTR => continue,
            .AGAIN => return 1,
            else => {
                client.source = 0;
                client.destroy();
                return 0;
            },
        };
        client.len += @intCast(n);
        if (std.mem.indexOfScalar(u8, client.buffer[0..client.len], '\n') != null) {
            client.source = 0;
            client.dispatch();
            return 0;
        }
    }
    // Oversized commands are rejected, not silently truncated.
    client.source = 0;
    client.destroy();
    return 0;
}
fn clientExpired(data: ?*anyopaque) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(data orelse return 0));
    client.timeout = 0;
    client.destroy();
    return 0;
}
fn socket(nonblocking: bool) !c_int {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC | (if (nonblocking) @as(u32, c.SOCK.NONBLOCK) else 0), 0);
    if (fd < 0) return error.SocketFailed;
    return fd;
}
fn address(path: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = @splat(0) };
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}
pub fn send(allocator: std.mem.Allocator, command: Command) !void {
    const path = try resolveSocketPath(allocator);
    defer allocator.free(path);
    const addr = try address(path);
    const fd = try socket(false);
    defer _ = c.close(fd);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.NotRunning;
    const message = switch (command) {
        .toggle => "toggle\n",
        .show => "show\n",
        .hide => "hide\n",
        .quit => "quit\n",
    };
    var offset: usize = 0;
    while (offset < message.len) {
        const n = c.send(fd, message.ptr + offset, message.len - offset, c.MSG.NOSIGNAL);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.SendFailed;
        }
        if (n == 0) return error.SendFailed;
        offset += @intCast(n);
    }
}
fn resolveSocketPath(allocator: std.mem.Allocator) ![:0]u8 {
    if (io.getenv("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0 and std.fs.path.isAbsolute(dir))
            return std.fmt.allocPrintSentinel(allocator, "{s}/djinn.sock", .{dir}, 0);
    }
    return std.fmt.allocPrintSentinel(allocator, "/tmp/djinn-{d}.sock", .{c.getuid()}, 0);
}
fn parseCommand(bytes: []const u8) ?Command {
    var it = std.mem.tokenizeAny(u8, bytes, &std.ascii.whitespace);
    const token = it.next() orelse return null;
    if (std.mem.eql(u8, token, "toggle")) return .toggle;
    if (std.mem.eql(u8, token, "show")) return .show;
    if (std.mem.eql(u8, token, "hide")) return .hide;
    if (std.mem.eql(u8, token, "quit")) return .quit;
    return null;
}
test "parseCommand recognises core verbs" {
    try std.testing.expectEqual(@as(?Command, .toggle), parseCommand("toggle\n"));
    try std.testing.expectEqual(@as(?Command, .toggle), parseCommand("  toggle  "));
    try std.testing.expectEqual(@as(?Command, .show), parseCommand("show"));
    try std.testing.expectEqual(@as(?Command, .hide), parseCommand("hide extra args ignored"));
    try std.testing.expectEqual(@as(?Command, .quit), parseCommand("quit"));
    try std.testing.expectEqual(@as(?Command, null), parseCommand("flarp"));
    try std.testing.expectEqual(@as(?Command, null), parseCommand(""));
}
