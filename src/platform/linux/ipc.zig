//! Unix-socket IPC trigger.
//!
//! Provides a single-direction command channel from outside the
//! process to the running panel. djinn listens on
//! `$XDG_RUNTIME_DIR/djinn.sock` (falling back to `/tmp/djinn-<uid>.sock`
//! when the runtime dir is unset). Each connecting client writes one
//! of a small set of commands — `toggle`, `show`, `hide`, `quit` —
//! and disconnects. The first whitespace-trimmed token is enough; the
//! rest of the message is ignored.
//!
//! This is the bridge the compositor's native hotkey binding talks to
//! today. Examples:
//!
//!   # Hyprland (hyprland.conf):
//!   bind = ALT, space, exec, printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock
//!
//!   # KDE: System Settings → Shortcuts → Custom Shortcuts → New
//!   #   Trigger: ALT+space
//!   #   Action:  sh -c 'printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock'
//!
//! The IPC layer is intentionally smaller than a full RPC: there's no
//! reply, no auth (the socket lives under the user's runtime dir,
//! which is mode 0700 — only the owning UID can connect), no schema
//! versioning. Anything richer than "toggle" should land on a real
//! protocol surface (D-Bus, MCP) rather than growing this file.
//!
//! Integration with GLib: the listening fd is watched via
//! `g_unix_fd_add`, so accept-and-read happens on the main loop
//! without an extra thread. Per-connection reads are short and
//! non-blocking — we accept, recv up to 64 bytes, dispatch, close.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");

const gpointer = gtk.gpointer;

// `g_unix_fd_add` lives in libgio (gio-2.0). Listed in build.zig's
// link line so we don't need a separate linkSystemLibrary call here.
const GIOCondition = c_uint;
const G_IO_IN: GIOCondition = 1;
const G_IO_ERR: GIOCondition = 8;
const G_IO_HUP: GIOCondition = 16;
const G_IO_NVAL: GIOCondition = 32;

const GUnixFDSourceFunc = *const fn (fd: c_int, condition: GIOCondition, user_data: gpointer) callconv(.c) c_int;

extern "c" fn g_unix_fd_add(fd: c_int, condition: GIOCondition, function: GUnixFDSourceFunc, user_data: gpointer) c_uint;
const g_source_remove = gtk.g_source_remove;

/// Commands the IPC accepts. Anything else is ignored with a log line.
pub const Command = enum {
    toggle,
    show,
    hide,
    quit,
};

/// Caller-supplied dispatcher. Invoked on the GLib main thread.
pub const Handler = struct {
    ctx: *anyopaque,
    on_command: *const fn (ctx: *anyopaque, command: Command) void,
};

pub const Ipc = struct {
    fd: c_int,
    source_id: c_uint,
    socket_path: [:0]u8,
    allocator: std.mem.Allocator,
    handler: Handler,
    /// Heap-boxed callback context; freed in deinit. The GLib source
    /// holds the pointer via user_data — we must outlive that source.
    ctx_box: *Context,

    /// Bind the socket and register the main-loop watch. The Panel
    /// must be open (GLib main loop initialized) by the time this is
    /// called — `g_unix_fd_add` schedules the watch on the default
    /// main context.
    ///
    /// Path resolution: `$XDG_RUNTIME_DIR/djinn.sock` if set, else
    /// `/tmp/djinn-<uid>.sock`. We unlink any existing file at the
    /// path before bind — a stale socket from a previous launch
    /// (e.g. SIGKILL) would otherwise block bind with EADDRINUSE.
    pub fn init(allocator: std.mem.Allocator, handler: Handler) !Ipc {
        const path = try resolveSocketPath(allocator);
        errdefer allocator.free(path);

        // Best-effort unlink of any stale socket. ENOENT is the
        // clean-start case and stays silent. Other errors — EACCES
        // (someone else owns it), EISDIR (the path is a dir, user
        // misconfigured XDG_RUNTIME_DIR), permission-denied parent
        // — get a one-liner so the user knows why `bind` is about
        // to fail with a less-informative `AddressInUse` /
        // `AccessDenied`.
        std.posix.unlink(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.debug.print("ipc: unlink {s} failed: {} — bind may fail\n", .{ path, err }),
        };

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(fd);

        var addr = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };
        // sockaddr_un.path is fixed-length (108 on linux); ensure we
        // can fit the chosen path plus the nul terminator.
        if (path.len + 1 > addr.path.len) return error.SocketPathTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        // Narrow umask to 0077 around bind so the socket inode is
        // created with mode 0600 atomically — race-free protection
        // against any local user `nc -U`-ing the verb stream. Without
        // this the inode would inherit the process umask (typically
        // 0022 → mode 0644) and any same-machine user could drive
        // `quit`. The XDG_RUNTIME_DIR path is normally inside a
        // 0700-protected dir, but the /tmp fallback (no
        // $XDG_RUNTIME_DIR, common on systemd-less or misconfigured
        // sessions) is world-traversable. Restore the previous umask
        // immediately so unrelated file ops elsewhere don't inherit
        // the narrow mask.
        const prev_umask = std.c.umask(0o077);
        defer _ = std.c.umask(prev_umask);

        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try std.posix.listen(fd, 4);

        // Stash a pointer to ourselves on the heap so the C callback
        // can recover the Zig context. Box the Handler so its lifetime
        // matches the GLib source registration (until deinit).
        const ctx_box = try allocator.create(Context);
        errdefer allocator.destroy(ctx_box);
        ctx_box.* = .{ .fd = fd, .handler = handler };

        const source_id = g_unix_fd_add(
            fd,
            G_IO_IN | G_IO_ERR | G_IO_HUP,
            onListenReady,
            @ptrCast(ctx_box),
        );

        return .{
            .fd = fd,
            .source_id = source_id,
            .socket_path = path,
            .allocator = allocator,
            .handler = handler,
            .ctx_box = ctx_box,
        };
    }

    pub fn deinit(self: *Ipc) void {
        // Order matters: remove the GLib source first so the callback
        // can't fire against a freed ctx_box mid-teardown.
        _ = g_source_remove(self.source_id);
        std.posix.close(self.fd);
        std.posix.unlink(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self.ctx_box);
    }
};

/// Heap-resident state the GLib callback can recover from `user_data`.
/// Separate struct because the Ipc struct itself lives on the caller's
/// stack and we can't take its address before init returns.
const Context = struct {
    fd: c_int,
    handler: Handler,
};

/// `g_unix_fd_add` callback. Returns `1` to stay subscribed, `0` to
/// remove the source. We always return 1 — the only reason to drop
/// the watch is shutdown, which deinit handles via g_source_remove.
fn onListenReady(fd: c_int, condition: GIOCondition, user_data: gpointer) callconv(.c) c_int {
    if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL) != 0) {
        // Listener fd should never close while we own it. If it
        // does, drop the watch so we don't spin on a dead fd.
        return 0;
    }

    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return 1));

    // Accept loop. The watch fires once per pending connection but
    // SOCK_NONBLOCK means we can drain backlogged connects in one go.
    //
    // Bounded by `max_iters` per dispatch — a same-UID client
    // `connect()`-ing in a tight loop on the abstract socket would
    // otherwise starve the GLib main loop (no panel updates, no
    // hotkey, no tray polls). 32 lets a legitimate burst (a script
    // firing 5–10 toggles in quick succession) drain in one tick;
    // a malicious peer hitting the cap just gets serviced over
    // multiple ticks at ~32 commands per ~ms — same throughput but
    // GLib keeps breathing.
    const max_iters: usize = 32;
    var iters: usize = 0;
    while (iters < max_iters) : (iters += 1) {
        const client_fd = std.posix.accept(fd, null, null, std.posix.SOCK.CLOEXEC) catch |err| switch (err) {
            error.WouldBlock => return 1,
            else => return 1,
        };
        defer std.posix.close(client_fd);

        var buf: [64]u8 = undefined;
        // EINTR is expected (signal during the syscall); other
        // errors (EBADF after close, EFAULT on a bad buf, EIO)
        // shouldn't recur but are worth logging — silent
        // `catch continue` made all of them indistinguishable
        // from a benign restart.
        const n = std.posix.read(client_fd, &buf) catch |err| switch (err) {
            error.Unexpected, error.WouldBlock => continue,
            else => {
                std.debug.print("ipc: read from client failed: {}\n", .{err});
                continue;
            },
        };
        if (n == 0) continue;

        const cmd = parseCommand(buf[0..n]) orelse continue;
        ctx.handler.on_command(ctx.handler.ctx, cmd);
    }
    // Hit the per-dispatch cap. The watch stays subscribed (return 1)
    // so the next GLib tick services the remaining backlog.
    return 1;
}

/// Pick the first whitespace-trimmed token off the message and map it
/// to a Command. Unknown tokens (typos, future-extension probes,
/// junk from another tool) return null and the caller skips them.
fn parseCommand(bytes: []const u8) ?Command {
    const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const tok = it.next() orelse return null;
    if (std.mem.eql(u8, tok, "toggle")) return .toggle;
    if (std.mem.eql(u8, tok, "show")) return .show;
    if (std.mem.eql(u8, tok, "hide")) return .hide;
    if (std.mem.eql(u8, tok, "quit")) return .quit;
    return null;
}

/// `$XDG_RUNTIME_DIR/djinn.sock` if set, else `/tmp/djinn-<uid>.sock`.
/// The runtime-dir path is the spec-correct location; /tmp is the
/// universal fallback (the only situation we'd hit it in practice is
/// a misconfigured systemd-less session). Allocator owns the slice.
fn resolveSocketPath(allocator: std.mem.Allocator) ![:0]u8 {
    // sockaddr_un.path is 108 bytes; staying well under that with 256
    // keeps any printed path representable. Anything longer would
    // fail bind() anyway, so failing the format here is fine.
    var buf: [256]u8 = undefined;
    const formatted = if (std.posix.getenv("XDG_RUNTIME_DIR")) |dir|
        try std.fmt.bufPrint(&buf, "{s}/djinn.sock", .{dir})
    else blk: {
        const uid = std.os.linux.getuid();
        break :blk try std.fmt.bufPrint(&buf, "/tmp/djinn-{d}.sock", .{uid});
    };
    return try allocator.dupeZ(u8, formatted);
}

test "parseCommand recognises core verbs" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqual(@as(?Command, .toggle), parseCommand("toggle\n"));
    try std.testing.expectEqual(@as(?Command, .toggle), parseCommand("  toggle  "));
    try std.testing.expectEqual(@as(?Command, .show), parseCommand("show"));
    try std.testing.expectEqual(@as(?Command, .hide), parseCommand("hide extra args ignored"));
    try std.testing.expectEqual(@as(?Command, null), parseCommand("flarp"));
    try std.testing.expectEqual(@as(?Command, null), parseCommand(""));
}
