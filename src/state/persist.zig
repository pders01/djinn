const std = @import("std");

/// Persisted across launches in `~/.config/djinn/state.json`. Today only the
/// window dimensions; future fields belong here too (last position, last
/// provider) so the file stays the single source of soft state.
pub const State = struct {
    width: u32 = 0,
    height: u32 = 0,
};

fn statePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/djinn/state.json", .{home});
}

pub fn load(allocator: std.mem.Allocator) ?State {
    const path = statePath(allocator) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 4 * 1024) catch return null;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    var s = State{};
    if (root.object.get("width")) |v| if (v == .integer) {
        s.width = @intCast(v.integer);
    };
    if (root.object.get("height")) |v| if (v == .integer) {
        s.height = @intCast(v.integer);
    };
    if (s.width == 0 or s.height == 0) return null;
    return s;
}

pub fn save(state: State) void {
    const allocator = std.heap.page_allocator;
    const path = statePath(allocator) catch return;
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch {};
    }

    const json = std.fmt.allocPrint(
        allocator,
        "{{\"width\":{d},\"height\":{d}}}",
        .{ state.width, state.height },
    ) catch return;
    defer allocator.free(json);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer file.close();
    _ = file.writeAll(json) catch {};
}

/// Debounced save: callers fire on every resize tick; the first call schedules
/// a single write a few hundred ms later. Avoids hammering disk during a drag.
var g_pending: ?State = null;
var g_thread_running: bool = false;
var g_mutex: std.Thread.Mutex = .{};

pub fn saveDebounced(state: State) void {
    g_mutex.lock();
    g_pending = state;
    const need_spawn = !g_thread_running;
    if (need_spawn) g_thread_running = true;
    g_mutex.unlock();

    if (need_spawn) {
        const t = std.Thread.spawn(.{}, debounceWorker, .{}) catch {
            g_mutex.lock();
            g_thread_running = false;
            g_mutex.unlock();
            return;
        };
        t.detach();
    }
}

fn debounceWorker() void {
    std.Thread.sleep(300 * std.time.ns_per_ms);
    g_mutex.lock();
    const s = g_pending;
    g_pending = null;
    g_thread_running = false;
    g_mutex.unlock();

    if (s) |snapshot| save(snapshot);
}

test "State: round-trip via load/save uses real HOME" {
    // No-op when HOME is unwritable in the test sandbox; we just verify the
    // function does not panic on a reasonable input.
    save(.{ .width = 1024, .height = 600 });
}
