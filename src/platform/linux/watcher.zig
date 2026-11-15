//! Config-file watcher.
//!
//! Wraps `GFileMonitor` so the linux side gets the same fan-in
//! semantics darwin's FSEventStream provides for `onConfigChanged`.
//! Watches the *parent directory* of each input path — that's the
//! atomic-rename-safe granularity. Editors like vim, Helix, VS Code
//! save by writing a tmp file and renaming it over the target; a
//! file-direct monitor on the target loses its watch when the inode
//! gets unlinked, while a directory monitor sees the rename land.
//!
//! Filtering by basename keeps the firing rate honest: every save in
//! `~/.config/djinn/` (state.json on resize, scrollback dumps,
//! whatever) hits the GFileMonitor, and we only forward the events
//! that matched one of the inputs.
//!
//! Lifetime: the GFileMonitor + signal subscription run for the
//! Watcher's lifetime. Each entry owns its GFile, GFileMonitor,
//! basename slice, and a heap-allocated EntryContext that the GLib
//! callback recovers from `user_data`. All entries share a single
//! heap-allocated CoalesceState that owns the debounce timer, the
//! recurring inode-health timer, and the user's Handler. `deinit`
//! cancels each monitor, removes pending timeouts if any, then frees
//! the boxes — no callbacks can fire after deinit because the GLib
//! main loop will have already drained any pending sources (the
//! panel exits its main loop before deinit chains run).
//!
//! Inode-health recheck: same-filesystem `mv` keeps inodes intact,
//! so a `mv ~/.config/djinn ~/.config/djinn.bak` round-trip leaves
//! our inotify watch valid on the surviving inode. The breakage
//! case is destroy-and-recreate — `rm -rf ~/.config/djinn; mkdir
//! ~/.config/djinn` (or an editor that wipes the dir mid-write).
//! A 5-second GLib timeout compares each entry's parent
//! `st_ino` against the value cached at init / last rebuild; on
//! mismatch the entry's GFile + GFileMonitor + signal subscription
//! get rebuilt in place against the current path, the cached inode
//! updates, and a coalesce fire triggers so the caller's
//! `on_changed` re-reads through the new inode. Stat failure (path
//! gone) is a no-op — the next tick retries once the parent is
//! re-created.
//!
//! Handler design: caller-supplied `on_changed` is called once per
//! debounce window across ALL watched files. GFileMonitor fires
//! 5+ events for a single atomic-rename save (vim, Helix, VS Code)
//! and was triggering the caller's retry/reload loop on each one;
//! coalescing on a 100ms timer cuts the per-save fan-out from
//! ~5–10 invocations to exactly 1. Handlers should still be
//! idempotent — re-saves outside the window get separate fires —
//! but the per-fire cost can be amortized without main-thread
//! starvation. mtime/atomic-write semantics live on the caller
//! side (mirror darwin's split between `onConfigChanged` and
//! `configFilesChanged` + `loadConfigWithRetry`).

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const platform = @import("../../io/platform.zig");

const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

// ─── GLib / GIO opaque types ─────────────────────────────────────────

const GFile = opaque {};
const GFileMonitor = opaque {};
const GCancellable = opaque {};
const GObject = opaque {};

const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

// ─── GLib enums ──────────────────────────────────────────────────────

const GFileMonitorFlags = c_int;
/// `WATCH_MOVES` (8) makes the monitor surface `RENAMED` events as
/// `RENAMED` rather than DELETED+CREATED pairs. Atomic-rename editors
/// produce exactly this case; without the flag we'd see two
/// uninteresting events and miss the basename-match window if the
/// new file's CREATED slipped through before our filter.
const G_FILE_MONITOR_NONE: GFileMonitorFlags = 0;
const G_FILE_MONITOR_WATCH_MOVES: GFileMonitorFlags = 8;

const GFileMonitorEvent = c_int;
const G_FILE_MONITOR_EVENT_CHANGED: GFileMonitorEvent = 0;
const G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT: GFileMonitorEvent = 1;
const G_FILE_MONITOR_EVENT_DELETED: GFileMonitorEvent = 2;
const G_FILE_MONITOR_EVENT_CREATED: GFileMonitorEvent = 3;
const G_FILE_MONITOR_EVENT_RENAMED: GFileMonitorEvent = 8;
const G_FILE_MONITOR_EVENT_MOVED_IN: GFileMonitorEvent = 9;

// ─── GLib / GIO extern surface ───────────────────────────────────────

extern "c" fn g_file_new_for_path(path: [*:0]const u8) *GFile;
extern "c" fn g_file_monitor_directory(
    file: *GFile,
    flags: GFileMonitorFlags,
    cancellable: ?*GCancellable,
    err: ?*?*GError,
) ?*GFileMonitor;
extern "c" fn g_file_monitor_cancel(monitor: *GFileMonitor) c_int;
extern "c" fn g_file_get_basename(file: *GFile) ?[*:0]u8;

extern "c" fn g_error_free(err: *GError) void;

// Shared GLib helpers (g_signal_connect_data, g_source_remove,
// g_timeout_add, g_object_unref, g_free) live in gtk.zig.
//
// Debounce semantics: `g_timeout_add` returns the source id; the
// callback returns G_SOURCE_REMOVE (0) to make it one-shot.
// `g_source_remove` is a no-op when the source has already fired
// (returns FALSE in that case), which is the post-fire state we
// rely on so deinit doesn't have to track "is the timer alive?"
// beyond the timeout_id == 0 sentinel.
const G_SOURCE_REMOVE: c_int = 0;
/// Returned from a `GSourceFunc` to keep the source firing on its
/// interval. Inverse of `G_SOURCE_REMOVE`. Used by `healthTick`,
/// which is recurring rather than one-shot.
const G_SOURCE_CONTINUE: c_int = 1;
const GSourceFunc = gtk.GSourceFunc;
const g_signal_connect_data = gtk.g_signal_connect_data;
const g_timeout_add = gtk.g_timeout_add;
const g_source_remove = gtk.g_source_remove;
const g_object_unref = gtk.g_object_unref;
const g_free = gtk.g_free;

// ─── Public surface ──────────────────────────────────────────────────

pub const Handler = struct {
    ctx: *anyopaque,
    /// Fires on the GLib main thread once per debounce window
    /// (100ms) when at least one watched file's basename has
    /// plausibly changed. Idempotent semantics — re-saves that
    /// straddle the window get separate fires, so handlers must
    /// still compare mtimes or content hashes if they care about
    /// real changes vs. noise.
    on_changed: *const fn (ctx: *anyopaque) void,
};

/// Debounce window length, in milliseconds. Sized to cover the
/// ~10–30ms burst that atomic-rename editors produce on save while
/// still feeling instant to a user editing config interactively.
const debounce_ms: c_uint = 100;

/// Recheck cadence for the parent-inode health probe. 5s is the
/// upper bound on how long a `rm -rf ~/.config/djinn; mkdir
/// ~/.config/djinn` flow can leave the watcher pointed at a freed
/// inode. Cheap: one `fstatat` per entry per tick.
const health_check_ms: c_uint = 5_000;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    coalesce: *CoalesceState,

    /// One per input file. Each owns its GFile, GFileMonitor, signal
    /// subscription, basename buffer, parent-path buffer, and the
    /// heap-allocated context the GLib callback recovers from
    /// user_data.
    const Entry = struct {
        gfile: *GFile,
        monitor: *GFileMonitor,
        signal_id: c_ulong,
        ctx: *EntryContext,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        files: []const []const u8,
        handler: Handler,
    ) !Watcher {
        const coalesce = try allocator.create(CoalesceState);
        errdefer allocator.destroy(coalesce);
        coalesce.* = .{
            .handler = handler,
            .timeout_id = 0,
            .entries = &.{},
            .health_timer_id = 0,
        };

        const entries = try allocator.alloc(Entry, files.len);
        errdefer allocator.free(entries);

        // Track how many entries have been successfully initialized
        // so an error mid-loop can tear down only the live ones.
        // `built` is the next-write index AND the live count — this
        // single-variable shape makes "is slot N tracked by the
        // errdefer?" trivially equivalent to "is N < built?". The
        // alternative pattern (`for (files, 0..) |path, i|` writing
        // `entries[i]` then `built += 1`) lets the two counters drift
        // if a future edit inserts a fallible step between the
        // assignment and the count update.
        var built: usize = 0;
        errdefer {
            for (entries[0..built]) |*e| destroyEntry(allocator, e);
        }

        for (files) |path| {
            entries[built] = try buildEntry(allocator, path, coalesce);
            built += 1;
        }

        // Wire the periodic inode-health probe last so the slice it
        // sees is fully populated. g_timeout_add returns >0 on
        // success and is effectively infallible (no IO); if it ever
        // returns 0 we log and degrade gracefully — the watcher
        // still works for the inode-stable case.
        coalesce.entries = entries;
        coalesce.health_timer_id = g_timeout_add(
            health_check_ms,
            CoalesceState.healthTick,
            @ptrCast(coalesce),
        );
        if (coalesce.health_timer_id == 0) {
            std.debug.print(
                "watcher: g_timeout_add for health probe returned 0 — config-dir-vanish recovery disabled\n",
                .{},
            );
        }

        return .{ .allocator = allocator, .entries = entries, .coalesce = coalesce };
    }

    pub fn deinit(self: *Watcher) void {
        // Drop pending timers before tearing down the entries so
        // their fire callbacks can't dispatch into a half-freed
        // state. `g_source_remove` is a no-op (returns FALSE) if the
        // source already fired or was never created (id == 0
        // sentinel guards against that).
        if (self.coalesce.health_timer_id != 0) {
            _ = g_source_remove(self.coalesce.health_timer_id);
            self.coalesce.health_timer_id = 0;
        }
        if (self.coalesce.timeout_id != 0) {
            _ = g_source_remove(self.coalesce.timeout_id);
            self.coalesce.timeout_id = 0;
        }
        for (self.entries) |*e| destroyEntry(self.allocator, e);
        self.allocator.free(self.entries);
        self.allocator.destroy(self.coalesce);
    }
};

/// Shared state across all entries of a single Watcher. Owns the
/// Handler the user supplied, the debounce timer, the recurring
/// inode-health timer, and a back-reference to the entries slice
/// so the health tick can walk + rebuild without a separate
/// Watcher pointer. Entries share one CoalesceState so saves that
/// ripple across `djinn/config` and `ghostty/config` simultaneously
/// coalesce into a single fire instead of two.
const CoalesceState = struct {
    handler: Handler,
    /// Active debounce timer id, or 0 if none is scheduled. Set by
    /// `schedule`, cleared by `fire` (after the timeout runs once
    /// and is removed via the G_SOURCE_REMOVE return) and by
    /// `Watcher.deinit` (after an explicit `g_source_remove`).
    timeout_id: c_uint,
    /// Entries slice header; the underlying buffer is owned by
    /// `Watcher`. `Watcher.deinit` cancels `health_timer_id` before
    /// freeing entries, so this slice can never outlive its backing.
    entries: []Watcher.Entry,
    /// Recurring `health_check_ms` timer id, or 0 if scheduling
    /// failed at init. Cleared by `Watcher.deinit`.
    health_timer_id: c_uint,

    fn schedule(self: *CoalesceState) void {
        // Leading-edge debounce: the first event in a quiet window
        // arms the timer; subsequent events while it's pending are
        // no-ops. Editor bursts (5+ events in ~10ms) collapse into
        // the single fire at the end of the window.
        if (self.timeout_id != 0) return;
        self.timeout_id = g_timeout_add(debounce_ms, fire, @ptrCast(self));
    }

    fn fire(user_data: gpointer) callconv(.c) c_int {
        const self: *CoalesceState = @ptrCast(@alignCast(user_data));
        self.timeout_id = 0;
        self.handler.on_changed(self.handler.ctx);
        return G_SOURCE_REMOVE;
    }

    /// Recurring `health_check_ms` callback. Walks each entry,
    /// checks whether the cached parent inode still matches the
    /// path's current inode, and rebuilds the GFile +
    /// GFileMonitor + signal subscription in place when it
    /// doesn't. On successful rebuild also schedules a coalesce
    /// fire so the caller's `on_changed` sees the post-recreate
    /// state. Returning `G_SOURCE_CONTINUE` keeps the source
    /// firing every `health_check_ms`.
    fn healthTick(user_data: gpointer) callconv(.c) c_int {
        const self: *CoalesceState = @ptrCast(@alignCast(user_data));
        for (self.entries) |*e| recheckEntry(e);
        return G_SOURCE_CONTINUE;
    }
};

const EntryContext = struct {
    coalesce: *CoalesceState,
    /// Owned NUL-terminated basename, e.g. "config". Comparison
    /// happens against the GLib-allocated basename returned by
    /// `g_file_get_basename` (we span it to a slice, no terminator
    /// reliance).
    basename: [:0]u8,
    /// Owned parent-dir path, kept for diagnostic logging AND for
    /// the periodic inode-health probe to stat against. NUL-
    /// terminated so we can hand it straight to `g_file_new_for_path`
    /// on rebuild without re-duping.
    parent: [:0]u8,
    /// Cached `st_ino` of `parent` as observed at the last
    /// successful build / rebuild. Compared against fresh stat
    /// results by `recheckEntry`; on mismatch the entry's monitor
    /// gets torn down and rebuilt. 0 means "unknown" — when the
    /// init-time stat failed, recheck never fires (since the
    /// comparison would always say "differs" and lead to a futile
    /// rebuild loop).
    parent_ino: u64,
};

// ─── Entry build / teardown ──────────────────────────────────────────

fn buildEntry(
    allocator: std.mem.Allocator,
    path: []const u8,
    coalesce: *CoalesceState,
) !Watcher.Entry {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return error.InvalidPath;
    if (slash == 0) return error.InvalidPath; // path like "/foo" — empty parent
    if (slash + 1 >= path.len) return error.InvalidPath; // trailing slash

    const parent_slice = path[0..slash];
    const basename_slice = path[slash + 1 ..];

    const parent = try allocator.dupeSentinel(u8, parent_slice, 0);
    errdefer allocator.free(parent);
    const basename = try allocator.dupeSentinel(u8, basename_slice, 0);
    errdefer allocator.free(basename);

    const gfile = g_file_new_for_path(parent.ptr);
    errdefer g_object_unref(gfile);

    var err: ?*GError = null;
    const monitor = g_file_monitor_directory(
        gfile,
        G_FILE_MONITOR_WATCH_MOVES,
        null,
        &err,
    ) orelse {
        if (err) |e| {
            const msg = if (e.message) |m| std.mem.span(m) else "(no message)";
            std.debug.print("watcher: monitor directory \"{s}\" failed: {s}\n", .{ parent, msg });
            g_error_free(e);
        }
        return error.MonitorFailed;
    };
    errdefer {
        _ = g_file_monitor_cancel(monitor);
        g_object_unref(monitor);
    }

    const ctx = try allocator.create(EntryContext);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .coalesce = coalesce,
        .basename = basename,
        .parent = parent,
        .parent_ino = readParentInode(parent),
    };

    const signal_id = g_signal_connect_data(
        @ptrCast(monitor),
        "changed",
        @ptrCast(&onChanged),
        @ptrCast(ctx),
        null,
        0,
    );
    if (signal_id == 0) {
        // Should never happen for a live monitor; documented for
        // completeness so the cleanup chain stays auditable.
        return error.SignalConnectFailed;
    }

    return .{
        .gfile = gfile,
        .monitor = monitor,
        .signal_id = signal_id,
        .ctx = ctx,
    };
}

/// `stat` the parent path and return its inode, or 0 if the call
/// fails. 0 doubles as a "disable the recheck for this entry"
/// sentinel — recheckEntry skips entries whose cached inode is 0
/// because there's no stable baseline to compare against.
fn readParentInode(parent: [:0]const u8) u64 {
    const st = std.Io.Dir.cwd().statFile(platform.io(), parent, .{}) catch return 0;
    return st.inode;
}

fn destroyEntry(allocator: std.mem.Allocator, entry: *Watcher.Entry) void {
    // Cancel before unref so an in-flight event can't dispatch into a
    // half-freed EntryContext. GLib serializes source dispatches on
    // the main thread, so once cancel returns the callback won't fire
    // again for this monitor.
    if (entry.signal_id != 0) {
        gtk.g_signal_handler_disconnect(entry.monitor, entry.signal_id);
        entry.signal_id = 0;
    }
    _ = g_file_monitor_cancel(entry.monitor);
    g_object_unref(entry.monitor);
    g_object_unref(entry.gfile);

    allocator.free(entry.ctx.basename);
    allocator.free(entry.ctx.parent);
    allocator.destroy(entry.ctx);
}

// ─── Inode-health recheck (config-dir-vanish recovery) ───────────────

/// Called on each `health_check_ms` tick for every entry. Stats the
/// cached parent path; if the inode differs from the value we cached
/// at init / last rebuild, the user has destroy-and-recreated the
/// parent (`rm -rf ~/.config/djinn; mkdir ~/.config/djinn`, an editor
/// that did the same, or a config-rotation script). Our existing
/// inotify watch is pinned to the freed inode, so future writes to
/// the new dir would never fire. Rebuild the GFile + GFileMonitor +
/// signal subscription in place, then schedule a coalesce fire so
/// the caller's `on_changed` re-reads through the new inode.
fn recheckEntry(entry: *Watcher.Entry) void {
    if (entry.ctx.parent_ino == 0) return; // init-time stat failed; no baseline
    const st = std.Io.Dir.cwd().statFile(platform.io(), entry.ctx.parent, .{}) catch return;
    if (st.inode == entry.ctx.parent_ino) return;

    rebuildMonitor(entry) catch |err| {
        std.debug.print(
            "watcher: rebuild monitor for \"{s}\" failed: {s} — retry on next tick\n",
            .{ entry.ctx.parent, @errorName(err) },
        );
        return;
    };
    entry.ctx.parent_ino = st.inode;
    entry.ctx.coalesce.schedule();
}

/// Build a fresh GFile + GFileMonitor + signal subscription against
/// the cached parent path and swap them onto `entry`, then tear down
/// the predecessors. Built-then-swap (rather than swap-then-build)
/// keeps the entry pointing at a live monitor for the entire path so
/// a partial failure leaves the prior monitor running.
fn rebuildMonitor(entry: *Watcher.Entry) !void {
    const new_gfile = g_file_new_for_path(entry.ctx.parent.ptr);
    errdefer g_object_unref(new_gfile);

    var err: ?*GError = null;
    const new_monitor = g_file_monitor_directory(
        new_gfile,
        G_FILE_MONITOR_WATCH_MOVES,
        null,
        &err,
    ) orelse {
        if (err) |e| {
            const msg = if (e.message) |m| std.mem.span(m) else "(no message)";
            std.debug.print(
                "watcher: monitor directory \"{s}\" failed during rebuild: {s}\n",
                .{ entry.ctx.parent, msg },
            );
            g_error_free(e);
        }
        return error.MonitorFailed;
    };
    errdefer {
        _ = g_file_monitor_cancel(new_monitor);
        g_object_unref(new_monitor);
    }

    const new_signal_id = g_signal_connect_data(
        @ptrCast(new_monitor),
        "changed",
        @ptrCast(&onChanged),
        @ptrCast(entry.ctx),
        null,
        0,
    );
    if (new_signal_id == 0) return error.SignalConnectFailed;

    // Success — install the new triple, then tear down the old.
    const old_monitor = entry.monitor;
    const old_gfile = entry.gfile;
    const old_signal_id = entry.signal_id;

    entry.gfile = new_gfile;
    entry.monitor = new_monitor;
    entry.signal_id = new_signal_id;

    if (old_signal_id != 0) gtk.g_signal_handler_disconnect(old_monitor, old_signal_id);
    _ = g_file_monitor_cancel(old_monitor);
    g_object_unref(old_monitor);
    g_object_unref(old_gfile);
}

// ─── Signal callback ─────────────────────────────────────────────────

fn onChanged(
    _: *GFileMonitor,
    file: ?*GFile,
    other_file: ?*GFile,
    event_type: GFileMonitorEvent,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *EntryContext = @ptrCast(@alignCast(user_data orelse return));

    const interesting = switch (event_type) {
        G_FILE_MONITOR_EVENT_CHANGED,
        G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT,
        G_FILE_MONITOR_EVENT_DELETED,
        G_FILE_MONITOR_EVENT_CREATED,
        G_FILE_MONITOR_EVENT_RENAMED,
        G_FILE_MONITOR_EVENT_MOVED_IN,
        => true,
        else => false,
    };
    if (!interesting) return;

    // RENAMED carries the destination in other_file. An editor saving
    // .config.tmp -> config must match that side as well as the source.
    for ([_]?*GFile{ file, other_file }) |candidate| {
        const f = candidate orelse continue;
        const basename_z = g_file_get_basename(f) orelse continue;
        defer g_free(@ptrCast(basename_z));
        if (std.mem.eql(u8, std.mem.span(basename_z), ctx.basename)) {
            ctx.coalesce.schedule();
            return;
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Watcher native API compiles without starting a monitor" {
    std.testing.refAllDecls(Watcher);
}

test "Watcher owns signal subscriptions across rebuild and deinit" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    const io = platform.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "watched", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "watched/config" });
    defer a.free(path);
    var fired: usize = 0;
    var watcher = try Watcher.init(a, &.{path}, .{
        .ctx = &fired,
        .on_changed = struct {
            fn cb(ctx: *anyopaque) void {
                const count: *usize = @ptrCast(@alignCast(ctx));
                count.* += 1;
            }
        }.cb,
    });
    var live = true;
    defer if (live) watcher.deinit();
    const entry = &watcher.entries[0];
    const original_ctx = entry.ctx;
    const old_monitor = entry.monitor;
    const old_signal = entry.signal_id;
    _ = gtk.g_object_ref(old_monitor);
    defer g_object_unref(old_monitor);
    try std.testing.expect(gtk.g_signal_handler_is_connected(old_monitor, old_signal) != 0);
    const old_inode = entry.ctx.parent_ino;
    try std.testing.expect(old_inode != 0);

    // Keep the old inode alive under a different name so filesystems
    // cannot immediately recycle it for the replacement directory.
    try tmp.dir.rename("watched", tmp.dir, "retired", io);
    try tmp.dir.createDir(io, "watched", .default_dir);
    recheckEntry(entry);
    try std.testing.expect(entry.ctx == original_ctx);
    try std.testing.expect(entry.ctx.parent_ino != old_inode);
    try std.testing.expectEqual(readParentInode(entry.ctx.parent), entry.ctx.parent_ino);
    try std.testing.expect(entry.monitor != old_monitor);
    try std.testing.expect(gtk.g_signal_handler_is_connected(old_monitor, old_signal) == 0);
    try std.testing.expect(gtk.g_signal_handler_is_connected(entry.monitor, entry.signal_id) != 0);
    try std.testing.expect(watcher.coalesce.timeout_id != 0);

    // An atomic rename matches its destination, and multiple events
    // preserve a single pending debounce source.
    const scheduled = watcher.coalesce.timeout_id;
    const target_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(target_z);
    const target = g_file_new_for_path(target_z.ptr);
    defer g_object_unref(target);
    onChanged(entry.monitor, null, target, G_FILE_MONITOR_EVENT_RENAMED, entry.ctx);
    try std.testing.expectEqual(scheduled, watcher.coalesce.timeout_id);
    _ = g_source_remove(scheduled);
    watcher.coalesce.timeout_id = 0;
    onChanged(entry.monitor, null, target, G_FILE_MONITOR_EVENT_RENAMED, entry.ctx);
    try std.testing.expect(watcher.coalesce.timeout_id != 0);
    try std.testing.expectEqual(@as(usize, 0), fired);

    const monitor = entry.monitor;
    const signal_id = entry.signal_id;
    _ = gtk.g_object_ref(monitor);
    defer g_object_unref(monitor);
    watcher.deinit();
    live = false;
    try std.testing.expect(gtk.g_signal_handler_is_connected(monitor, signal_id) == 0);
}

test "Watcher rejects malformed paths" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    const handler = Handler{
        .ctx = @ptrFromInt(@alignOf(u8)),
        .on_changed = struct {
            fn cb(_: *anyopaque) void {}
        }.cb,
    };
    // No slash at all.
    try std.testing.expectError(error.InvalidPath, Watcher.init(a, &.{"config"}, handler));
    // Path that's a root file — empty parent.
    try std.testing.expectError(error.InvalidPath, Watcher.init(a, &.{"/config"}, handler));
    // Trailing slash — no basename.
    try std.testing.expectError(error.InvalidPath, Watcher.init(a, &.{"/etc/"}, handler));
}

test "readParentInode reports stable inode and 0 for missing path" {
    const a = std.testing.allocator;

    // Stage a unique tmpdir for this test so concurrent runs don't
    // collide on /tmp/djinn-watcher-test.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub_name = "djinn-watcher-recheck";
    const io = platform.io();
    try tmp.dir.createDir(io, sub_name, .default_dir);

    const sub_path = try tmp.dir.realPathFileAlloc(io, sub_name, a);
    defer a.free(sub_path);

    const sub_path_z = try a.dupeSentinel(u8, sub_path, 0);
    defer a.free(sub_path_z);

    const ino_before = readParentInode(sub_path_z);
    try std.testing.expect(ino_before != 0);

    // Same-FS rename keeps the inode invariant. The recheck relies on
    // this so mv-round-trip flows don't trigger a spurious rebuild.
    const renamed_name = "djinn-watcher-recheck.bak";
    try tmp.dir.rename(sub_name, tmp.dir, renamed_name, io);
    try tmp.dir.rename(renamed_name, tmp.dir, sub_name, io);
    const ino_after_rename = readParentInode(sub_path_z);
    try std.testing.expectEqual(ino_before, ino_after_rename);

    // Recreate after destroy must still resolve to a non-zero inode
    // so the recheck can compare against the cached value. Whether
    // it differs from `ino_before` is filesystem-allocator dependent
    // (Azure's CI tmpfs reuses inodes immediately, ext4 typically
    // doesn't); the recheck path treats either outcome correctly,
    // so the test only asserts the non-zero post-condition.
    try tmp.dir.deleteDir(io, sub_name);
    try tmp.dir.createDir(io, sub_name, .default_dir);
    const ino_after_recreate = readParentInode(sub_path_z);
    try std.testing.expect(ino_after_recreate != 0);

    // Missing path returns 0 — the recheck treats this as "wait
    // for parent to reappear" and skips this tick.
    try tmp.dir.deleteDir(io, sub_name);
    const ino_missing = readParentInode(sub_path_z);
    try std.testing.expectEqual(@as(u64, 0), ino_missing);
}
