const std = @import("std");
const objc = @import("objc");

const c_dispatch = @cImport({
    @cInclude("dispatch/dispatch.h");
});

// libdispatch's typed wrappers stumble over the transparent-union dispatch
// types when called from zig (same dance io/dispatch.zig already plays for
// dispatch_resume). dispatch_async_f works in the same shape: hand it the
// main queue, a context pointer, and a C-ABI function. The AppKit call
// sites must run on main; this is the cheapest way to guarantee that
// without dragging in a Grand Central Dispatch wrapper.
extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;

/// macOS notification sender via NSUserNotification (deprecated in 10.14
/// but functional through current macOS; UNUserNotificationCenter is the
/// modern path but requires a code-signed bundle, entitlements, and Zig
/// extern wrappers for block-based completion handlers — none of which
/// we want to take on yet). This is a transport swap from osascript;
/// behavior is identical.
pub const Notifier = struct {
    enabled: bool = true,

    /// Play a system sound. Always runs via `afplay` in a detached thread
    /// — NSSound's msgSend chain is documented as main-thread-only and
    /// crashes when called from the MCP HTTP thread. afplay has no such
    /// constraint and stays out of AppKit entirely.
    /// `name` semantics:
    ///   - "" or null → no-op
    ///   - "default" → /System/Library/Sounds/Funk.aiff
    ///   - absolute path (starts with "/") → play that file
    ///   - anything else → /System/Library/Sounds/<name>.aiff
    pub fn playSound(_: *const Notifier, name: ?[]const u8) void {
        const n = name orelse return;
        if (n.len == 0) return;

        const allocator = std.heap.page_allocator;
        const path: []const u8 = blk: {
            if (n[0] == '/') break :blk allocator.dupe(u8, n) catch return;
            const stem = if (std.mem.eql(u8, n, "default")) "Funk" else n;
            break :blk std.fmt.allocPrint(allocator, "/System/Library/Sounds/{s}.aiff", .{stem}) catch return;
        };

        // execAfplay owns `path` and frees it after the subprocess exits.
        if (std.Thread.spawn(.{}, execAfplay, .{path})) |t| {
            t.detach();
        } else |_| {
            allocator.free(path);
        }
    }

    pub fn send(self: *const Notifier, title: []const u8, body: []const u8) void {
        if (!self.enabled) return;

        const allocator = std.heap.page_allocator;
        const payload = allocator.create(Payload) catch return;
        payload.title = nulDupe(allocator, title) catch {
            allocator.destroy(payload);
            return;
        };
        payload.body = nulDupe(allocator, body) catch {
            allocator.free(payload.title);
            allocator.destroy(payload);
            return;
        };

        // The hot-path send() is called from MCP HTTP worker threads;
        // AppKit / NSUserNotificationCenter must run on main. dispatch_async_f
        // posts the work to the main queue, which the AppKit run loop
        // drains. payload is freed inside deliverOnMain.
        const main_queue = c_dispatch.dispatch_get_main_queue();
        dispatch_async_f(@ptrCast(main_queue), payload, &deliverOnMain);
    }
};

const Payload = struct {
    /// NUL-terminated UTF-8 — stringWithUTF8String: requires that.
    title: []u8,
    body: []u8,
};

/// Allocate `bytes.len + 1`, copy in, write a trailing NUL. Returns a slice
/// of length `bytes.len + 1` (the NUL is included so free() sees the right
/// size; AppKit only reads up to the first NUL).
fn nulDupe(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf;
}

fn deliverOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const opaque_ptr = ctx orelse return;
    const payload: *Payload = @ptrCast(@alignCast(opaque_ptr));
    const allocator = std.heap.page_allocator;
    defer {
        allocator.free(payload.title);
        allocator.free(payload.body);
        allocator.destroy(payload);
    }

    const NSString = objc.getClass("NSString") orelse return;
    const NSUserNotification = objc.getClass("NSUserNotification") orelse return;
    const NSUserNotificationCenter = objc.getClass("NSUserNotificationCenter") orelse return;

    const ns_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(payload.title.ptr))});
    if (ns_title.value == null) return;
    const ns_body = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(payload.body.ptr))});
    if (ns_body.value == null) return;

    const note_alloc = NSUserNotification.msgSend(objc.Object, "alloc", .{});
    const note = note_alloc.msgSend(objc.Object, "init", .{});
    if (note.value == null) return;

    note.msgSend(void, "setTitle:", .{ns_title});
    note.msgSend(void, "setInformativeText:", .{ns_body});

    const center = NSUserNotificationCenter.msgSend(
        objc.Object,
        "defaultUserNotificationCenter",
        .{},
    );
    if (center.value == null) return;
    center.msgSend(void, "deliverNotification:", .{note});
}

fn execAfplay(path: []const u8) void {
    defer std.heap.page_allocator.free(path);
    var child = std.process.Child.init(
        &.{ "/usr/bin/afplay", path },
        std.heap.page_allocator,
    );
    child.spawn() catch return;
    _ = child.wait() catch {};
}
