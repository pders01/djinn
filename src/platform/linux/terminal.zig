//! GTK4/VTE terminal. VTE owns rendering, PTY input, selection and IME.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../../io/platform.zig");
const gtk = @import("gtk.zig");
const dragdrop = @import("dragdrop.zig");
const theme = @import("theme.zig");
pub const ThemeOptions = theme.Options;
const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
const gpointer = gtk.gpointer;

pub const Spawn = struct {
    /// An unchanged shell expression. null means an ordinary interactive shell.
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    audible_bell: bool = true,
    /// null restores the VTE property default; zero retains no scrollback.
    scrollback_lines: ?u32 = null,
};

pub const Handler = struct {
    ctx: *anyopaque,
    extra: usize = 0,
    on_child_exited: *const fn (*anyopaque, usize) void,
    on_bell: ?*const fn (*anyopaque, usize) void = null,
    on_title_changed: ?*const fn (*anyopaque, usize, []const u8) void = null,
};

const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };
extern "c" fn vte_terminal_new() *GtkWidget;
extern "c" fn vte_terminal_spawn_async(*VteTerminal, c_int, ?[*:0]const u8, [*]const ?[*:0]const u8, ?[*]const ?[*:0]const u8, c_int, ?*const anyopaque, gpointer, ?*const anyopaque, c_int, ?*gtk.GCancellable, ?*const fn (?*VteTerminal, c_int, ?*GError, gpointer) callconv(.c) void, gpointer) void;
extern "c" fn g_cancellable_new() *gtk.GCancellable;
extern "c" fn g_cancellable_cancel(*gtk.GCancellable) void;
extern "c" fn g_object_ref_sink(*anyopaque) *anyopaque;
extern "c" fn vte_terminal_set_font_scale(*VteTerminal, f64) void;
extern "c" fn vte_terminal_get_font_scale(*VteTerminal) f64;
extern "c" fn vte_terminal_reset(*VteTerminal, c_int, c_int) void;
extern "c" fn vte_terminal_feed_child(*VteTerminal, [*]const u8, isize) void;
extern "c" fn vte_terminal_feed(*VteTerminal, [*]const u8, isize) void;
extern "c" fn vte_terminal_set_audible_bell(*VteTerminal, c_int) void;
extern "c" fn vte_terminal_get_scrollback_lines(*VteTerminal) c_long;
extern "c" fn vte_terminal_set_scrollback_lines(*VteTerminal, c_long) void;

fn scrollbackLines(lines: ?u32, native_default: c_long) c_long {
    return if (lines) |n| @intCast(n) else native_default;
}
extern "c" fn vte_terminal_copy_clipboard_format(*VteTerminal, c_int) void;
extern "c" fn vte_terminal_paste_clipboard(*VteTerminal) void;
extern "c" fn vte_terminal_paste_text(*VteTerminal, [*:0]const u8) void;
extern "c" fn vte_terminal_get_window_title(*VteTerminal) ?[*:0]const u8;
const GtkAdjustment = opaque {};
const GtkScrollable = opaque {};
extern "c" fn gtk_scrollable_get_vadjustment(*GtkScrollable) ?*GtkAdjustment;
extern "c" fn gtk_adjustment_get_value(*GtkAdjustment) f64;
extern "c" fn gtk_adjustment_get_page_size(*GtkAdjustment) f64;
extern "c" fn gtk_adjustment_set_value(*GtkAdjustment, f64) void;

/// A heap box shared by the Terminal owner and the pending spawn completion.
/// No C callback points at the returned/movable Terminal value. On teardown,
/// disconnect signals and clear handler BEFORE cancelling; the deferred callback
/// can then only release its own reference, never touch a destroyed host.
// Main-thread-only registry: cancelled spawn callbacks must finish even when
// startup fails before portal initialization or its independent drain is empty.
var pending_launches: ?*Launch = null;

const Launch = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    handler: ?Handler,
    shell: [:0]u8,
    expression: ?[:0]u8,
    cwd: ?[:0]u8,
    argv: [4]?[*:0]const u8 = @splat(null),
    cancellable: *gtk.GCancellable,
    main_context: *gtk.GMainContext,
    pending_next: ?*Launch = null,
    completed_exit: bool = false,
    retired: bool = false,

    fn create(a: std.mem.Allocator, spawn: Spawn, handler: ?Handler, shell: []const u8) !*Launch {
        try validateValue(shell);
        if (spawn.command) |s| try validateValue(s);
        if (spawn.cwd) |s| try validateValue(s);
        const shell_z = try a.dupeSentinel(u8, shell, 0);
        errdefer a.free(shell_z);
        const expression = if (spawn.command) |s| try a.dupeSentinel(u8, s, 0) else null;
        errdefer if (expression) |s| a.free(s);
        const cwd = if (spawn.cwd) |s| try a.dupeSentinel(u8, s, 0) else null;
        errdefer if (cwd) |s| a.free(s);
        const box = try a.create(Launch);
        box.* = .{
            .allocator = a,
            .handler = handler,
            .shell = shell_z,
            .expression = expression,
            .cwd = cwd,
            .cancellable = g_cancellable_new(),
            .main_context = gtk.g_main_context_ref_thread_default(),
        };
        // Explicit commands are shell expressions, NOT executable filenames.
        // No splitting, escaping, or fallback on failure. Default is interactive
        // (including when the parent process was launched without a terminal).
        box.argv = launchArgv(box.shell.ptr, if (box.expression) |expr| expr.ptr else null);
        return box;
    }

    fn beginSpawn(self: *Launch) void {
        self.refs += 1;
        self.pending_next = pending_launches;
        pending_launches = self;
    }

    fn completeSpawn(self: *Launch) void {
        self.unlinkSpawn();
        self.release();
    }

    fn unlinkSpawn(self: *Launch) void {
        var link = &pending_launches;
        while (link.*) |entry| {
            if (entry == self) {
                link.* = self.pending_next;
                self.pending_next = null;
                return;
            }
            link = &entry.pending_next;
        }
        unreachable; // each queued spawn completes exactly once
    }

    fn dropLease(self: *Launch) bool {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        return self.refs == 0;
    }

    fn release(self: *Launch) void {
        if (!self.dropLease()) return;
        const a = self.allocator;
        gtk.g_object_unref(@ptrCast(self.cancellable));
        gtk.g_main_context_unref(self.main_context);
        a.free(self.shell);
        if (self.expression) |s| a.free(s);
        if (self.cwd) |s| a.free(s);
        a.destroy(self);
    }

    fn exited(self: *Launch) void {
        if (self.completed_exit) return;
        self.completed_exit = true;
        if (self.handler) |h| h.on_child_exited(h.ctx, h.extra);
    }
};

fn launchArgv(shell: [*:0]const u8, expression: ?[*:0]const u8) [4]?[*:0]const u8 {
    return .{ shell, if (expression != null) "-lc" else "-i", expression, null };
}

fn validateValue(value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.EmptyLaunchValue;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidLaunchValue;
}

pub const Terminal = struct {
    widget: *GtkWidget,
    allocator: std.mem.Allocator,
    launch: *Launch,
    child_exited_handler_id: c_ulong = 0,
    bell_handler_id: c_ulong = 0,
    title_handler_id: c_ulong = 0,
    /// Captured before the first override, never from a previously themed VTE.
    default_scrollback_lines: c_long,

    pub fn open(allocator: std.mem.Allocator, opts: ThemeOptions, handler: ?Handler, spawn: ?Spawn) !Terminal {
        const options: Spawn = spawn orelse .{};
        const launch = try Launch.create(allocator, options, handler, platform.getenv("SHELL") orelse "/bin/sh");
        const widget = vte_terminal_new();
        // A separate owned reference keeps widget valid even if the stack has
        // removed it. Host must deinit wrappers before destroying its stack.
        _ = g_object_ref_sink(@ptrCast(widget));
        const vte: *VteTerminal = @ptrCast(widget);
        theme.apply(widget, opts);
        vte_terminal_set_audible_bell(vte, @intFromBool(options.audible_bell));
        dragdrop.attach(widget);
        var term = Terminal{ .widget = widget, .allocator = allocator, .launch = launch, .default_scrollback_lines = vte_terminal_get_scrollback_lines(vte) };
        term.applyScrollback(options.scrollback_lines);
        term.child_exited_handler_id = gtk.g_signal_connect_data(@ptrCast(widget), "child-exited", @ptrCast(&onChildExited), launch, null, 0);
        term.bell_handler_id = gtk.g_signal_connect_data(@ptrCast(widget), "bell", @ptrCast(&onBell), launch, null, 0);
        term.title_handler_id = gtk.g_signal_connect_data(@ptrCast(widget), "window-title-changed", @ptrCast(&onTitleChanged), launch, null, 0);
        launch.beginSpawn();
        vte_terminal_spawn_async(vte, 0, if (launch.cwd) |s| s.ptr else null, &launch.argv, null, 1 << 26, null, null, null, -1, launch.cancellable, &onSpawnComplete, launch);
        return term;
    }

    pub fn detachExitHandler(self: *Terminal) void {
        self.launch.retired = true;
        self.launch.handler = null;
        if (self.child_exited_handler_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(self.widget), self.child_exited_handler_id);
        if (self.bell_handler_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(self.widget), self.bell_handler_id);
        if (self.title_handler_id != 0) gtk.g_signal_handler_disconnect(@ptrCast(self.widget), self.title_handler_id);
        self.child_exited_handler_id = 0;
        self.bell_handler_id = 0;
        self.title_handler_id = 0;
    }

    pub fn deinit(self: *Terminal) void {
        self.detachExitHandler();
        g_cancellable_cancel(self.launch.cancellable);
        gtk.g_object_unref(@ptrCast(self.widget));
        self.launch.release();
    }

    /// Final entrypoint teardown only, after EVERY native owner/producer has
    /// detached. Never pump the shared context during terminal replacement.
    pub fn shutdown() void {
        while (pending_launches) |launch| {
            std.debug.assert(launch.retired and launch.handler == null);
            launch.refs += 1; // callback can release its last completion lease
            _ = gtk.g_main_context_iteration(launch.main_context, 1);
            launch.release();
        }
    }

    /// VTE applies this live (including inactive terminals). Lowering a limit
    /// may discard retained history; raising/removing it cannot recover history.
    pub fn applyScrollback(self: *Terminal, lines: ?u32) void {
        vte_terminal_set_scrollback_lines(@ptrCast(self.widget), scrollbackLines(lines, self.default_scrollback_lines));
    }

    pub fn applyTheme(self: *Terminal, opts: ThemeOptions) void {
        theme.apply(self.widget, opts);
    }
    pub fn fontScaleAdjust(self: *Terminal, delta: f64) void {
        const vte: *VteTerminal = @ptrCast(self.widget);
        vte_terminal_set_font_scale(vte, std.math.clamp(vte_terminal_get_font_scale(vte) + delta, 0.4, 4.0));
    }
    pub fn fontScaleReset(self: *Terminal) void {
        vte_terminal_set_font_scale(@ptrCast(self.widget), 1.0);
    }
    pub fn copySelectionToClipboard(self: *Terminal) void {
        vte_terminal_copy_clipboard_format(@ptrCast(self.widget), 1);
    }
    pub fn pasteFromClipboard(self: *Terminal) void {
        vte_terminal_paste_clipboard(@ptrCast(self.widget));
    }
    /// Explicit text insertion uses VTE's bracketed-paste-aware API, not keys.
    pub fn pasteText(self: *Terminal, text: []const u8) !void {
        if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
        const z = try self.allocator.dupeSentinel(u8, text, 0);
        defer self.allocator.free(z);
        vte_terminal_paste_text(@ptrCast(self.widget), z.ptr);
    }
    pub fn clearScrollback(self: *Terminal) void {
        const vte: *VteTerminal = @ptrCast(self.widget);
        vte_terminal_reset(vte, 0, 1);
        vte_terminal_feed_child(vte, "\x0c", 1);
    }
    pub fn feedScreen(self: *Terminal, data: []const u8) void {
        if (data.len != 0) vte_terminal_feed(@ptrCast(self.widget), data.ptr, @intCast(data.len));
    }
    pub fn scrollPages(self: *Terminal, pages: f64) void {
        const adj = gtk_scrollable_get_vadjustment(@ptrCast(self.widget)) orelse return;
        gtk_adjustment_set_value(adj, gtk_adjustment_get_value(adj) + gtk_adjustment_get_page_size(adj) * pages);
    }
};

fn onSpawnComplete(terminal: ?*VteTerminal, _: c_int, err: ?*GError, data: gpointer) callconv(.c) void {
    const box: *Launch = @ptrCast(@alignCast(data orelse return));
    defer box.completeSpawn();
    if (err) |e| {
        // GError is borrowed. Never inject its untrusted message into the PTY
        // or terminal parser. Retired launches deliberately do not notify.
        if (!box.retired) {
            std.debug.print("terminal: session {d} spawn failed: {s}\n", .{ if (box.handler) |h| h.extra else 0, if (e.message) |m| std.mem.span(m) else "unknown error" });
            if (terminal) |vte| {
                const message = "\r\n[djinn: launch failed; check command/cwd and restart]\r\n";
                vte_terminal_feed(vte, message.ptr, message.len);
            }
            box.exited();
        }
    }
}
fn onChildExited(_: *VteTerminal, _: c_int, data: gpointer) callconv(.c) void {
    const box: *Launch = @ptrCast(@alignCast(data orelse return));
    box.exited();
}
fn onBell(_: *VteTerminal, data: gpointer) callconv(.c) void {
    const box: *Launch = @ptrCast(@alignCast(data orelse return));
    const h = box.handler orelse return;
    if (h.on_bell) |cb| cb(h.ctx, h.extra);
}
fn onTitleChanged(vte: *VteTerminal, data: gpointer) callconv(.c) void {
    const box: *Launch = @ptrCast(@alignCast(data orelse return));
    const h = box.handler orelse return;
    if (h.on_title_changed) |cb| cb(h.ctx, h.extra, if (vte_terminal_get_window_title(vte)) |s| std.mem.span(s) else "");
}

test "pending spawns remain tracked independently until each completion" {
    try std.testing.expect(pending_launches == null);
    defer pending_launches = null;
    // Synthetic owner leases keep cleanup native-free; only registry and
    // completion ownership are exercised here, never fake GTK objects.
    var first: Launch = .{ .allocator = undefined, .refs = 2, .handler = null, .shell = undefined, .expression = null, .cwd = null, .cancellable = undefined, .main_context = undefined };
    var second = first;
    first.beginSpawn();
    second.beginSpawn();
    try std.testing.expect(pending_launches == &second);
    first.unlinkSpawn();
    try std.testing.expect(!first.dropLease());
    try std.testing.expect(pending_launches == &second and second.pending_next == null);
    try std.testing.expectEqual(@as(usize, 2), first.refs);
    second.unlinkSpawn();
    try std.testing.expect(!second.dropLease());
    try std.testing.expect(pending_launches == null);
    try std.testing.expectEqual(@as(usize, 2), second.refs);
}

test "scrollback limits are lines and removal restores the captured VTE default" {
    try std.testing.expectEqual(@as(c_long, 512), scrollbackLines(null, 512));
    try std.testing.expectEqual(@as(c_long, 0), scrollbackLines(0, 512));
    try std.testing.expectEqual(@as(c_long, 100000), scrollbackLines(100000, 512));
    try std.testing.expectEqual(@as(c_long, 4294967295), scrollbackLines(std.math.maxInt(u32), 512));
    // A backend with an unlimited native default must preserve that sentinel.
    try std.testing.expectEqual(@as(c_long, -1), scrollbackLines(null, -1));
}

test "Terminal type compiles" {
    if (builtin.os.tag != .linux) return;
    _ = Terminal;
}
test "launch argv preserves shell expression and default is interactive" {
    const expression = "  FOO='a b' /bin/tool --arg=\"$HOME\"; echo done  ";
    const command = launchArgv("/bin/fish", expression);
    try std.testing.expectEqualStrings("/bin/fish", std.mem.span(command[0].?));
    try std.testing.expectEqualStrings("-lc", std.mem.span(command[1].?));
    try std.testing.expectEqualStrings(expression, std.mem.span(command[2].?));
    try std.testing.expect(command[3] == null);
    const shell = launchArgv("/bin/zsh", null);
    try std.testing.expectEqualStrings("/bin/zsh", std.mem.span(shell[0].?));
    try std.testing.expectEqualStrings("-i", std.mem.span(shell[1].?));
    try std.testing.expect(shell[2] == null and shell[3] == null);
    const fish = launchArgv("/bin/fish", null);
    try std.testing.expectEqualStrings("/bin/fish", std.mem.span(fish[0].?));
    try std.testing.expectEqualStrings("-i", std.mem.span(fish[1].?));
    // Recovery must never ask fish to interpret a POSIX ${SHELL:-...} command.
    try std.testing.expect(fish[2] == null and fish[3] == null);
}

test "explicit launch rejects empty and NUL rather than falling back" {
    try std.testing.expectError(error.EmptyLaunchValue, validateValue(" \t"));
    try std.testing.expectError(error.InvalidLaunchValue, validateValue("echo\x00ignored"));
    try validateValue("  FOO='a b' tool --arg=\"$HOME\"; echo done  ");
}
