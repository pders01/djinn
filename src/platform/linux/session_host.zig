//! Fixed-membership, lazy GTK4/VTE session stack. No profile writeback.
const std = @import("std");
const gtk = @import("gtk.zig");
const manager = @import("../../session/manager.zig");
const SessionManager = manager.SessionManager;
const terminal = @import("terminal.zig");
const Terminal = terminal.Terminal;
const TerminalHandler = terminal.Handler;
const ThemeOptions = terminal.ThemeOptions;
const FindOverlay = @import("find_overlay.zig").FindOverlay;
const GtkWidget = gtk.GtkWidget;
const GtkStack = opaque {};
extern "c" fn gtk_stack_new() *GtkWidget;
extern "c" fn gtk_stack_add_named(*GtkStack, *GtkWidget, [*:0]const u8) *anyopaque;
extern "c" fn gtk_stack_set_visible_child_name(*GtkStack, [*:0]const u8) void;
extern "c" fn gtk_stack_set_transition_duration(*GtkStack, c_uint) void;
extern "c" fn gtk_stack_remove(*GtkStack, *GtkWidget) void;
extern "c" fn gtk_widget_grab_focus(*GtkWidget) gtk.gboolean;
extern "c" fn g_object_ref_sink(*anyopaque) *anyopaque;

pub const OnSwitch = struct { ctx: *anyopaque, on_invoke: *const fn (*anyopaque, usize) void };
pub const OnExitChanged = struct { ctx: *anyopaque, on_invoke: *const fn (*anyopaque, usize, bool) void };
pub const OnTitleChanged = struct { ctx: *anyopaque, on_invoke: *const fn (*anyopaque, usize) void };

/// Every C callback uses a separately allocated incarnation, never &host or an
/// ArrayList element. Membership is immutable; id + generation also guard the
/// source against retired widgets and future lifecycle changes.
const Source = struct {
    sm: *SessionManager,
    idx: usize,
    id: u64,
    generation: u64,
    forwarded: ?TerminalHandler,
    title_hook: ?OnTitleChanged,
    armed: bool = false,
    pending_exit: bool = false,
    pending_title: [256]u8 = @splat(0),
    pending_title_len: ?usize = null,

    fn current(self: *const Source) bool {
        return sourceMatches(self.sm, self.idx, self.id, self.generation);
    }
    fn handler(self: *Source) TerminalHandler {
        return .{ .ctx = self, .extra = self.idx, .on_child_exited = childExited, .on_bell = bell, .on_title_changed = titleChanged };
    }
};

fn sourceMatches(sm: *const SessionManager, idx: usize, id: u64, generation: u64) bool {
    if (idx >= sm.count()) return false;
    const s = sm.sessions.items[idx];
    return s.id == id and s.surface_generation == generation;
}

/// A direct recovery shell is not an expression interpreted by $SHELL -lc.
/// Keep it distinct from .profile, whose null command also means a shell.
const LaunchChoice = union(enum) {
    profile,
    expression: []const u8,
    default_shell,

    fn command(self: LaunchChoice, profile: manager.Profile) ?[]const u8 {
        return switch (self) {
            .profile => profile.command,
            .expression => |value| value,
            .default_shell => null,
        };
    }
};

const Entry = struct {
    // No interior pointer to this buffer survives a move of the Entry.
    name: [40:0]u8 = @splat(0),
    terminal: ?Terminal = null,
    source: ?*Source = null,
};

pub const SessionHost = struct {
    allocator: std.mem.Allocator,
    sm: *SessionManager,
    stack: *GtkWidget,
    entries: std.ArrayList(Entry) = .empty,
    theme_opts: ThemeOptions,
    scrollback_lines: ?u32 = null,
    handler: ?TerminalHandler,
    find_overlay: ?*FindOverlay = null,
    on_switch: ?OnSwitch = null,
    on_exit_changed: ?OnExitChanged = null,
    title_hook: ?OnTitleChanged = null,
    bell_audible_default: bool,

    pub fn init(a: std.mem.Allocator, sm: *SessionManager, opts: ThemeOptions, handler: ?TerminalHandler, audible: bool) !SessionHost {
        const stack = gtk_stack_new();
        _ = g_object_ref_sink(@ptrCast(stack));
        gtk_stack_set_transition_duration(@ptrCast(stack), 0);
        var host = SessionHost{ .allocator = a, .sm = sm, .stack = stack, .theme_opts = opts, .handler = handler, .bell_audible_default = audible };
        errdefer host.deinit();
        try host.entries.resize(a, sm.count());
        for (host.entries.items) |*e| e.* = .{};
        for (host.entries.items, sm.sessions.items) |*e, s| {
            _ = try std.fmt.bufPrint(&e.name, "session-{d}\x00", .{s.id});
        }
        try host.spawnInto(sm.active_idx);
        gtk_stack_set_visible_child_name(@ptrCast(stack), &host.entries.items[sm.active_idx].name);
        return host;
    }

    /// Run before SessionManager and the panel are destroyed. The owned stack
    /// ref and Terminal refs keep disconnect targets valid throughout teardown.
    pub fn deinit(self: *SessionHost) void {
        for (self.entries.items, 0..) |*e, idx| {
            if (e.terminal) |*t| {
                t.detachExitHandler();
                self.sm.sessions.items[idx].surface_generation +%= 1;
                gtk_stack_remove(@ptrCast(self.stack), t.widget);
                t.deinit();
                self.sm.sessions.items[idx].spawned = false;
            }
            if (e.source) |s| self.allocator.destroy(s);
        }
        self.entries.deinit(self.allocator);
        gtk.g_object_unref(@ptrCast(self.stack));
    }
    pub fn widget(self: *SessionHost) *GtkWidget {
        return self.stack;
    }
    pub fn currentVte(self: *SessionHost) ?*GtkWidget {
        const t = self.currentTerminal() orelse return null;
        return t.widget;
    }
    pub fn currentTerminal(self: *SessionHost) ?*Terminal {
        return self.terminalAt(self.sm.active_idx);
    }
    pub fn terminalAt(self: *SessionHost, idx: usize) ?*Terminal {
        if (idx >= self.entries.items.len) return null;
        return if (self.entries.items[idx].terminal) |*t| t else null;
    }

    pub fn activate(self: *SessionHost, idx: usize) bool {
        if (idx >= self.entries.items.len) return false;
        if (idx == self.sm.active_idx) {
            if (self.currentVte()) |w| _ = gtk_widget_grab_focus(w);
            return false;
        }
        if (self.entries.items[idx].terminal == null) self.spawnInto(idx) catch |err| {
            std.debug.print("session_host: launch '{s}' failed: {}\n", .{ self.sm.sessions.items[idx].profile.name, err });
            return false;
        };
        _ = self.sm.switchTo(idx);
        gtk_stack_set_visible_child_name(@ptrCast(self.stack), &self.entries.items[idx].name);
        if (self.currentVte()) |w| {
            if (self.find_overlay) |fo| fo.setTarget(w);
            _ = gtk_widget_grab_focus(w);
        }
        if (self.on_switch) |h| h.on_invoke(h.ctx, idx);
        return true;
    }
    pub fn activateNext(self: *SessionHost) bool {
        return self.activate(self.sm.peekNext() orelse return false);
    }
    pub fn activatePrev(self: *SessionHost) bool {
        return self.activate(self.sm.peekPrev() orelse return false);
    }

    /// null restarts the profile (whose command may itself be null = shell).
    /// A non-null override is an explicit shell expression and never silently
    /// falls back. Validate cwd again even for a previously successful launch.
    pub fn restartActive(self: *SessionHost, override_cmd: ?[]const u8) bool {
        return self.restartWithChoice(if (override_cmd) |cmd| .{ .expression = cmd } else .profile);
    }

    /// Ignore the retained profile command/script without mutating it. Terminal
    /// launches $SHELL directly with -i (including fish), never via POSIX syntax.
    pub fn openShellActive(self: *SessionHost) bool {
        return self.restartWithChoice(.default_shell);
    }

    fn restartWithChoice(self: *SessionHost, choice: LaunchChoice) bool {
        const idx = self.sm.active_idx;
        if (self.terminalAt(idx) == null) return false;
        self.replace(idx, choice) catch |err| {
            std.debug.print("session_host: restart '{s}' failed: {}\n", .{ self.sm.sessions.items[idx].profile.name, err });
            return false;
        };
        gtk_stack_set_visible_child_name(@ptrCast(self.stack), &self.entries.items[idx].name);
        if (self.currentVte()) |w| _ = gtk_widget_grab_focus(w);
        return true;
    }

    fn spawnInto(self: *SessionHost, idx: usize) !void {
        try self.replace(idx, .profile);
    }

    fn replace(self: *SessionHost, idx: usize, choice: LaunchChoice) !void {
        const session = &self.sm.sessions.items[idx];
        // Shared validation currently checks cwd only. Retain it for EVERY
        // launch choice: recovery must never silently change explicit cwd.
        try session.validateLaunch();
        const source = try self.allocator.create(Source);
        errdefer self.allocator.destroy(source);
        source.* = .{ .sm = self.sm, .idx = idx, .id = session.id, .generation = session.surface_generation +% 1, .forwarded = self.handler, .title_hook = self.title_hook };
        const fresh = try Terminal.open(self.allocator, self.theme_opts, source.handler(), self.spawnOptions(session.profile, choice));
        const entry = &self.entries.items[idx];
        // Everything fallible is done. Retire the old source before releasing
        // its callback box. Pending async spawn completion has handler=null.
        if (entry.terminal) |*old| {
            old.detachExitHandler();
            // Retarget while BOTH widgets are alive: find clears old highlights.
            if (idx == self.sm.active_idx) {
                if (self.find_overlay) |fo| fo.setTarget(fresh.widget);
            }
            gtk_stack_remove(@ptrCast(self.stack), old.widget);
            old.deinit();
        }
        if (entry.source) |old| self.allocator.destroy(old);
        session.surface_generation = source.generation;
        session.spawned = true;
        session.exited = false;
        session.terminal_title_len = 0;
        entry.source = source;
        entry.terminal = fresh;
        _ = gtk_stack_add_named(@ptrCast(self.stack), fresh.widget, &entry.name);
        self.markExited(idx, false);
        if (self.title_hook) |h| h.on_invoke(h.ctx, idx);
        // Even a synchronously delivered spawn failure must be attributed to
        // the NEW committed entry, never the widget being replaced.
        source.armed = true;
        if (source.pending_title_len) |n| titleChanged(source, idx, source.pending_title[0..n]);
        if (source.pending_exit) childExited(source, idx);
    }

    fn spawnOptions(self: *const SessionHost, profile: manager.Profile, choice: LaunchChoice) terminal.Spawn {
        return .{
            .command = choice.command(profile),
            .cwd = profile.cwd,
            .audible_bell = profile.bell_audible orelse self.bell_audible_default,
            .scrollback_lines = self.scrollback_lines,
        };
    }

    /// Call after init and on every accepted config reload. Updates ALL live
    /// terminals and stores the policy for lazy, restarted and recovery shells.
    /// null restores each VTE's captured native default, not the previous limit.
    pub fn applyScrollback(self: *SessionHost, lines: ?u32) void {
        self.applyScrollbackWith(lines, Terminal.applyScrollback);
    }

    fn applyScrollbackWith(self: *SessionHost, lines: ?u32, comptime apply: fn (*Terminal, ?u32) void) void {
        self.scrollback_lines = lines;
        for (self.entries.items) |*e| if (e.terminal) |*t| apply(t, lines);
    }

    pub fn applyTheme(self: *SessionHost, opts: ThemeOptions) void {
        self.applyThemeWith(opts, Terminal.applyTheme);
    }

    fn applyThemeWith(self: *SessionHost, opts: ThemeOptions, comptime apply: fn (*Terminal, ThemeOptions) void) void {
        self.theme_opts = opts;
        for (self.entries.items) |*e| if (e.terminal) |*t| apply(t, opts);
    }
    pub fn markExited(self: *SessionHost, idx: usize, value: bool) void {
        if (idx >= self.entries.items.len) return;
        self.sm.sessions.items[idx].exited = value;
        // Source callbacks update shared state before forwarding to main. GTK
        // class updates are idempotent, so don't suppress the notification by
        // comparing against the already-updated manager (or an init-only bit).
        if (self.on_exit_changed) |h| h.on_invoke(h.ctx, idx, value);
    }
    pub fn isExited(self: *SessionHost, idx: usize) bool {
        return idx < self.sm.count() and self.sm.sessions.items[idx].exited;
    }
    /// Wire to TabStrip.refreshLabel after both returned values have reached
    /// their final caller-owned addresses. No host pointer is captured here.
    pub fn setTitleChangedHandler(self: *SessionHost, hook: ?OnTitleChanged) void {
        self.title_hook = hook;
        for (self.entries.items) |*e| if (e.source) |s| {
            s.title_hook = hook;
        };
    }
};

fn childExited(ctx: *anyopaque, _: usize) void {
    const s: *Source = @ptrCast(@alignCast(ctx));
    if (!s.armed) {
        s.pending_exit = true;
        return;
    }
    if (!s.current()) return;
    s.sm.sessions.items[s.idx].exited = true;
    if (s.forwarded) |h| h.on_child_exited(h.ctx, s.idx);
}
fn bell(ctx: *anyopaque, _: usize) void {
    const s: *Source = @ptrCast(@alignCast(ctx));
    if (!s.armed or !s.current()) return;
    if (s.forwarded) |h| if (h.on_bell) |cb| cb(h.ctx, s.idx);
}
fn titleChanged(ctx: *anyopaque, _: usize, title: []const u8) void {
    const s: *Source = @ptrCast(@alignCast(ctx));
    if (!s.armed) {
        s.pending_title_len = copyTitle(&s.pending_title, title);
        return;
    }
    if (!s.current()) return;
    const session = &s.sm.sessions.items[s.idx];
    session.terminal_title_len = copyTitle(&session.terminal_title, title);
    const idx = s.idx;
    const hook = s.title_hook;
    const forwarded = s.forwarded;
    if (hook) |h| h.on_invoke(h.ctx, idx);
    if (forwarded) |h| if (h.on_title_changed) |cb| cb(h.ctx, idx, title);
}

/// Titles are untrusted terminal output. Reject binary/control titles and
/// truncate at a UTF-8 boundary, never in the middle of a displayed codepoint.
fn copyTitle(dest: []u8, title: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(title)) return 0;
    var it = (std.unicode.Utf8View.initUnchecked(title)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return 0;
    }
    var n = @min(dest.len, title.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(title[0..n])) : (n -= 1) {}
    @memcpy(dest[0..n], title[0..n]);
    return n;
}

test "recovery shell ignores command and resolved script without modifying profile" {
    for ([_][]const u8{ "tool --interactive", "'/tmp/profile script'" }) |command| {
        const profile = manager.Profile{ .name = "tool", .command = command, .cwd = "/explicit/cwd" };
        try std.testing.expect(@as(LaunchChoice, .default_shell).command(profile) == null);
        try std.testing.expectEqualStrings(command, @as(LaunchChoice, .profile).command(profile).?);
        try std.testing.expectEqualStrings("explicit override", (LaunchChoice{ .expression = "explicit override" }).command(profile).?);
        try std.testing.expectEqualStrings(command, profile.command.?);
        try std.testing.expectEqualStrings("/explicit/cwd", profile.cwd.?);
    }
}

test "recovery retains explicit cwd validation and never falls back" {
    // Pure pre-filesystem failures establish that even the recovery path must
    // reject invalid retained cwd, rather than silently launch in the default.
    const session = manager.Session{ .id = 1, .profile = .{ .name = "tool", .command = "broken", .cwd = "relative" } };
    try std.testing.expect(@as(LaunchChoice, .default_shell).command(session.profile) == null);
    try std.testing.expectError(error.NotAbsolutePath, session.validateLaunch());
}

test "latest scrollback policy reaches lazy restart and recovery spawn options" {
    // Pure stand-ins at the VTE setter boundary: entries 0 and 2 model active
    // and inactive terminals, entry 1 is still lazy. Never dereference GTK.
    const Recorder = struct {
        limit: ?u32 = null,
        calls: usize = 0,
        fn apply(t: *Terminal, lines: ?u32) void {
            const record: *@This() = @ptrCast(@alignCast(t.widget));
            record.limit = lines;
            record.calls += 1;
        }
    };
    var records: [2]Recorder = @splat(.{});
    var entries: [3]Entry = @splat(.{});
    for ([_]usize{ 0, 2 }, &records) |idx, *record| {
        entries[idx].terminal = .{ .widget = @ptrCast(record), .allocator = std.testing.allocator, .launch = undefined, .default_scrollback_lines = 512 };
    }
    var host = SessionHost{
        .allocator = std.testing.allocator,
        .sm = undefined,
        .stack = undefined,
        .theme_opts = .{},
        .handler = null,
        .bell_audible_default = true,
    };
    host.entries.items = &entries;
    host.entries.capacity = entries.len;
    const profile = manager.Profile{ .name = "test", .command = "tool" };
    for ([_]?u32{ null, 0, 70000, null }) |limit| {
        host.applyScrollbackWith(limit, Recorder.apply);
        for (records) |record| try std.testing.expectEqual(limit, record.limit);
        try std.testing.expect(entries[1].terminal == null);
        for ([_]LaunchChoice{ .profile, .profile, .default_shell, .{ .expression = "override" } }) |choice| {
            try std.testing.expectEqual(limit, host.spawnOptions(profile, choice).scrollback_lines);
        }
    }
    for (records) |record| try std.testing.expectEqual(@as(usize, 4), record.calls);
}

test "appearance replacement covers active inactive and future session options" {
    const Recorder = struct {
        opts: ThemeOptions = .{},
        calls: usize = 0,
        fn apply(t: *Terminal, opts: ThemeOptions) void {
            const record: *@This() = @ptrCast(@alignCast(t.widget));
            record.opts = opts;
            record.calls += 1;
        }
    };
    var records: [2]Recorder = @splat(.{});
    var entries: [3]Entry = @splat(.{});
    for ([_]usize{ 0, 2 }, &records) |idx, *record| {
        entries[idx].terminal = .{ .widget = @ptrCast(record), .allocator = std.testing.allocator, .launch = undefined, .default_scrollback_lines = 512 };
    }
    var host = SessionHost{ .allocator = std.testing.allocator, .sm = undefined, .stack = undefined, .theme_opts = .{}, .handler = null, .bell_audible_default = true };
    host.entries.items = &entries;
    host.entries.capacity = entries.len;
    var full = ThemeOptions{
        .font_family = "Fixture Mono",
        .font_size = 14,
        .background = .{ .r = 1, .g = 2, .b = 3 },
        .foreground = .{ .r = 4, .g = 5, .b = 6 },
        .cursor = .{ .r = 7, .g = 8, .b = 9 },
        .padding_x = 12,
        .padding_y = 7,
        .opacity = 0.5,
    };
    full.palette[4] = .{ .r = 10, .g = 11, .b = 12 };
    // Theme/appearance transitions and inheritance removal use the same full
    // replacement path. replace() uses this exact retained theme_opts value
    // when creating a lazy, restarted or recovery terminal.
    for ([_]ThemeOptions{ full, .{ .background = .{ .r = 250, .g = 250, .b = 250 } }, .{} }) |opts| {
        host.applyThemeWith(opts, Recorder.apply);
        try std.testing.expectEqualDeep(opts, host.theme_opts);
        for (records) |record| try std.testing.expectEqualDeep(opts, record.opts);
        try std.testing.expect(entries[1].terminal == null);
    }
    for (records) |record| try std.testing.expectEqual(@as(usize, 3), record.calls);
}

test "SessionHost: type compiles" {
    _ = SessionHost;
    _ = Entry;
}
test "source attribution rejects retired generation and wrong id" {
    var sm = try SessionManager.init(std.testing.allocator, &@import("../../config.zig").Config{});
    defer sm.deinit();
    try std.testing.expect(sourceMatches(&sm, 0, 1, 0));
    sm.active().surface_generation = 2;
    try std.testing.expect(!sourceMatches(&sm, 0, 1, 0));
    try std.testing.expect(!sourceMatches(&sm, 0, 2, 2));
    try std.testing.expect(!sourceMatches(&sm, 1, 1, 2));
    try std.testing.expect(sourceMatches(&sm, 0, 1, 2));
}
test "callbacks update emitting inactive session and ignore retired sources" {
    const entries = [_]@import("../../config.zig").Config.ProfileEntry{ .{ .name = "one" }, .{ .name = "two" } };
    const cfg = @import("../../config.zig").Config{ .profiles = .{ .entries = &entries } };
    var sm = try SessionManager.init(std.testing.allocator, &cfg);
    defer sm.deinit();
    var source = Source{ .sm = &sm, .idx = 1, .id = sm.sessions.items[1].id, .generation = 0, .forwarded = null, .title_hook = null };
    childExited(&source, 0);
    try std.testing.expect(source.pending_exit);
    try std.testing.expect(!sm.sessions.items[1].exited);
    source.armed = true;
    childExited(&source, 0);
    titleChanged(&source, 0, "tool title");
    try std.testing.expect(sm.sessions.items[1].exited);
    try std.testing.expect(!sm.active().exited);
    try std.testing.expectEqualStrings("tool title", sm.sessions.items[1].label());
    sm.sessions.items[1].surface_generation += 1;
    sm.sessions.items[1].exited = false;
    childExited(&source, 0);
    titleChanged(&source, 0, "stale title");
    try std.testing.expect(!sm.sessions.items[1].exited);
    try std.testing.expectEqualStrings("tool title", sm.sessions.items[1].label());
}

test "title copy is bounded valid UTF8 and rejects control bytes" {
    var dest: [4]u8 = undefined;
    const n = copyTitle(&dest, "ab€tail");
    try std.testing.expectEqualStrings("ab", dest[0..n]);
    try std.testing.expectEqual(@as(usize, 0), copyTitle(&dest, "bad\x1b"));
    try std.testing.expectEqual(@as(usize, 0), copyTitle(&dest, "\xff"));
}
