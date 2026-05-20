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
//! heap-allocated CoalesceState that owns the debounce timer and
//! the user's Handler. `deinit` cancels each monitor, removes a
//! pending timeout if any, then frees the boxes — no callbacks can
//! fire after deinit because the GLib main loop will have already
//! drained any pending sources (the panel exits its main loop
//! before deinit chains run).
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

extern "c" fn g_free(mem: ?*anyopaque) void;
extern "c" fn g_object_unref(object: *anyopaque) void;
extern "c" fn g_error_free(err: *GError) void;

// g_signal_connect is a macro; we call its underlying function
// directly the same way panel.zig does.
const GClosureNotify = ?*const fn (data: gpointer, closure: ?*anyopaque) callconv(.c) void;
extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: gpointer,
    destroy_data: GClosureNotify,
    connect_flags: c_int,
) c_ulong;

// Debounce-timer externs. `g_timeout_add` returns the source id;
// the callback returns G_SOURCE_REMOVE (0) to make it one-shot.
// `g_source_remove` is a no-op when the source has already fired
// (returns FALSE in that case), which is the post-fire state we
// rely on so deinit doesn't have to track "is the timer alive?"
// beyond the timeout_id == 0 sentinel.
const G_SOURCE_REMOVE: c_int = 0;
const GSourceFunc = *const fn (user_data: gpointer) callconv(.c) c_int;
extern "c" fn g_timeout_add(interval_ms: c_uint, function: GSourceFunc, user_data: gpointer) c_uint;
extern "c" fn g_source_remove(tag: c_uint) c_int;

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
        coalesce.* = .{ .handler = handler, .timeout_id = 0 };

        const entries = try allocator.alloc(Entry, files.len);
        errdefer allocator.free(entries);

        // Track how many entries have been successfully initialized
        // so an error mid-loop can tear down only the live ones.
        var built: usize = 0;
        errdefer {
            for (entries[0..built]) |*e| destroyEntry(allocator, e);
        }

        for (files, 0..) |path, i| {
            entries[i] = try buildEntry(allocator, path, coalesce);
            built += 1;
        }

        return .{ .allocator = allocator, .entries = entries, .coalesce = coalesce };
    }

    pub fn deinit(self: *Watcher) void {
        // Drop a pending debounce timer before tearing down the
        // entries so its fire callback can't dispatch into a
        // half-freed CoalesceState. `g_source_remove` is a no-op
        // (returns FALSE) if the source already fired, so it's safe
        // either way.
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
/// Handler the user supplied + the active `g_timeout_add` source
/// id. Entries share one CoalesceState so saves that ripple across
/// `djinn/config` and `ghostty/config` simultaneously coalesce into
/// a single fire instead of two.
const CoalesceState = struct {
    handler: Handler,
    /// Active debounce timer id, or 0 if none is scheduled. Set by
    /// `schedule`, cleared by `fire` (after the timeout runs once
    /// and is removed via the G_SOURCE_REMOVE return) and by
    /// `Watcher.deinit` (after an explicit `g_source_remove`).
    timeout_id: c_uint,

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
};

const EntryContext = struct {
    coalesce: *CoalesceState,
    /// Owned NUL-terminated basename, e.g. "config". Comparison
    /// happens against the GLib-allocated basename returned by
    /// `g_file_get_basename` (we span it to a slice, no terminator
    /// reliance).
    basename: [:0]u8,
    /// Owned parent-dir path, kept for diagnostic logging only.
    /// Convenient when a user runs `RUST_LOG=djinn=trace` -equivalent
    /// debug printing and needs to know which dir fired.
    parent: [:0]u8,
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

    const parent = try allocator.dupeZ(u8, parent_slice);
    errdefer allocator.free(parent);
    const basename = try allocator.dupeZ(u8, basename_slice);
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
    errdefer _ = g_file_monitor_cancel(monitor);
    errdefer g_object_unref(monitor);

    const ctx = try allocator.create(EntryContext);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .coalesce = coalesce,
        .basename = basename,
        .parent = parent,
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

fn destroyEntry(allocator: std.mem.Allocator, entry: *Watcher.Entry) void {
    // Cancel before unref so an in-flight event can't dispatch into a
    // half-freed EntryContext. GLib serializes source dispatches on
    // the main thread, so once cancel returns the callback won't fire
    // again for this monitor.
    _ = g_file_monitor_cancel(entry.monitor);
    g_object_unref(entry.monitor);
    g_object_unref(entry.gfile);

    allocator.free(entry.ctx.basename);
    allocator.free(entry.ctx.parent);
    allocator.destroy(entry.ctx);
}

// ─── Signal callback ─────────────────────────────────────────────────

fn onChanged(
    _: *GFileMonitor,
    file: ?*GFile,
    _: ?*GFile,
    event_type: GFileMonitorEvent,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *EntryContext = @ptrCast(@alignCast(user_data orelse return));

    const interesting = switch (event_type) {
        G_FILE_MONITOR_EVENT_CHANGED,
        G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT,
        G_FILE_MONITOR_EVENT_CREATED,
        G_FILE_MONITOR_EVENT_RENAMED,
        G_FILE_MONITOR_EVENT_MOVED_IN,
        => true,
        else => false,
    };
    if (!interesting) return;

    const f = file orelse return;
    const basename_z = g_file_get_basename(f) orelse return;
    defer g_free(@ptrCast(basename_z));

    const basename = std.mem.span(basename_z);
    if (!std.mem.eql(u8, basename, ctx.basename)) return;

    ctx.coalesce.schedule();
}

// ─── Tests ───────────────────────────────────────────────────────────

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
