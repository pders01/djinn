const std = @import("std");

const c = @cImport({
    @cInclude("dispatch/dispatch.h");
});

// ─── FSEventStream — config file watcher ─────────────────────────────
//
// FSEventStreamCreate + SetDispatchQueue is the modern pattern for
// watching a small set of files on the main thread. Coalescing latency
// is set to 0.5s so atomic-rename saves (editor → temp → rename) only
// fire one callback. The handler is fan-in — we don't inspect which
// path changed, we just re-apply the whole config; that keeps the
// surface tiny and avoids per-flag plumbing.

const cf = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

extern "c" fn FSEventStreamCreate(
    allocator: ?*anyopaque,
    callback: ?*const fn (?*anyopaque, ?*anyopaque, usize, ?*anyopaque, [*c]const u32, [*c]const u64) callconv(.c) void,
    context: ?*anyopaque,
    paths_to_watch: ?*anyopaque,
    since_when: u64,
    latency: f64,
    flags: u32,
) ?*anyopaque;
extern "c" fn FSEventStreamSetDispatchQueue(stream: ?*anyopaque, queue: ?*anyopaque) void;
extern "c" fn FSEventStreamStart(stream: ?*anyopaque) c_int;

const fs_event_id_since_now: u64 = 0xFFFFFFFFFFFFFFFF;
const fs_flag_file_events: u32 = 0x10;

var fs_handler: ?*const fn () void = null;

fn fsEventCallback(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: usize,
    _: ?*anyopaque,
    _: [*c]const u32,
    _: [*c]const u64,
) callconv(.c) void {
    if (fs_handler) |h| h();
}

/// Watch a small list of absolute file paths and call `handler` on the
/// main queue when any of them change. Returns the stream pointer
/// (caller doesn't need it for liveness — the stream stays scheduled
/// until process exit). Returns null on any setup failure; callers
/// should treat that as "live reload disabled" and continue.
///
/// Internally watches the *parent directory* of each path (deduped),
/// not the file path itself. FSEventStreamCreate resolves paths to
/// (device, inode) at create time; atomic-rename saves (vim/VSCode/
/// Helix write a tmp file then rename over the target) swap the
/// inode at the file path, and event delivery on the original
/// per-file watch can stop after the first save. Parent-dir watch is
/// on the dir's inode, which is stable across child rename-replace,
/// so reloads keep firing on every save. Reload itself is fan-in +
/// idempotent, so dir-granular events are fine — handler ignores
/// which path actually changed.
pub fn watchPaths(paths: []const []const u8, handler: *const fn () void) ?*anyopaque {
    if (paths.len == 0 or paths.len > 8) return null;
    fs_handler = handler;

    // Strip filename → parent dir, dedup. Two paths under the same
    // dir collapse to one watch.
    var parent_storage: [8][512]u8 = undefined;
    var parents: [8][]const u8 = undefined;
    var parent_count: usize = 0;
    outer: for (paths) |p| {
        const sep = std.mem.lastIndexOfScalar(u8, p, '/') orelse return null;
        const parent = p[0..sep];
        if (parent.len == 0 or parent.len >= parent_storage[0].len) return null;
        for (parents[0..parent_count]) |existing| {
            if (std.mem.eql(u8, existing, parent)) continue :outer;
        }
        if (parent_count >= parents.len) return null;
        @memcpy(parent_storage[parent_count][0..parent.len], parent);
        parents[parent_count] = parent_storage[parent_count][0..parent.len];
        parent_count += 1;
    }

    var cf_strs: [8]?*anyopaque = .{null} ** 8;
    var path_buf: [1024]u8 = undefined;
    for (parents[0..parent_count], 0..) |p, i| {
        if (p.len >= path_buf.len) return null;
        @memcpy(path_buf[0..p.len], p);
        path_buf[p.len] = 0;
        const s = cf.CFStringCreateWithCString(null, &path_buf, cf.kCFStringEncodingUTF8) orelse return null;
        cf_strs[i] = @ptrCast(@constCast(s));
    }

    const arr = cf.CFArrayCreate(
        null,
        @ptrCast(&cf_strs),
        @intCast(parent_count),
        &cf.kCFTypeArrayCallBacks,
    ) orelse return null;

    const stream = FSEventStreamCreate(
        null,
        &fsEventCallback,
        null,
        @ptrCast(@constCast(arr)),
        fs_event_id_since_now,
        0.5,
        fs_flag_file_events,
    ) orelse return null;

    FSEventStreamSetDispatchQueue(stream, c.dispatch_get_main_queue());
    if (FSEventStreamStart(stream) == 0) return null;
    return stream;
}
