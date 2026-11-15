//! Terminal-window shortcuts. No agent actions or mutable profile controls.
const std = @import("std");
const io = @import("../../io/platform.zig");
const gtk = @import("gtk.zig");
const Config = @import("../../config.zig").Config;
const Panel = @import("panel.zig").Panel;
const SessionHost = @import("session_host.zig").SessionHost;
const FindOverlay = @import("find_overlay.zig").FindOverlay;
const ghostty_config = @import("ghostty_config.zig");

const GtkShortcut = opaque {};
const GtkShortcutTrigger = opaque {};
const GtkShortcutAction = opaque {};
const GVariant = opaque {};
extern "c" fn gtk_shortcut_controller_new() *gtk.GtkEventController;
extern "c" fn gtk_shortcut_controller_set_scope(*gtk.GtkEventController, c_int) void;
extern "c" fn gtk_event_controller_set_propagation_phase(*gtk.GtkEventController, c_int) void;
extern "c" fn gtk_shortcut_trigger_parse_string([*:0]const u8) ?*GtkShortcutTrigger;
extern "c" fn gtk_callback_action_new(*const fn (*gtk.GtkWidget, ?*GVariant, gtk.gpointer) callconv(.c) c_int, gtk.gpointer, ?*const fn (gtk.gpointer) callconv(.c) void) *GtkShortcutAction;
extern "c" fn gtk_shortcut_new(*GtkShortcutTrigger, *GtkShortcutAction) *GtkShortcut;
extern "c" fn gtk_shortcut_controller_add_shortcut(*gtk.GtkEventController, *GtkShortcut) void;
extern "c" fn gtk_widget_remove_controller(*gtk.GtkWidget, *gtk.GtkEventController) void;
const GtkRoot = opaque {};
extern "c" fn gtk_widget_get_root(*gtk.GtkWidget) ?*GtkRoot;
extern "c" fn gtk_root_get_focus(*GtkRoot) ?*gtk.GtkWidget;
extern "c" fn gtk_editable_get_type() c_ulong;
extern "c" fn g_type_check_instance_is_a(*anyopaque, c_ulong) gtk.gboolean;
extern "c" fn gtk_widget_activate_action_variant(*gtk.GtkWidget, [*:0]const u8, ?*GVariant) gtk.gboolean;

pub const ReapplyHook = struct {
    ctx: *anyopaque,
    on_invoke: *const fn (*anyopaque) void,
};
pub const Popovers = struct { find_overlay: ?*FindOverlay = null };
pub const Context = struct {
    session_host: *SessionHost,
    allocator: std.mem.Allocator,
    panel: *Panel,
    config: *const Config,
    reapply_config: ?ReapplyHook = null,
    popovers: Popovers = .{},
};
pub const Action = struct {
    name: []const u8,
    accel: [*:0]const u8,
    handler: *const fn (*Context) void,
    multiple: bool = false,
    /// Destructive or PTY-writing actions must not escape a focused editor.
    terminal_only: bool = false,
};
const actions = [_]Action{
    .{ .name = "font_inc", .accel = "<Control>equal", .handler = fontInc },
    .{ .name = "font_inc_shift", .accel = "<Control><Shift>equal", .handler = fontInc },
    .{ .name = "font_dec", .accel = "<Control>minus", .handler = fontDec },
    .{ .name = "font_reset", .accel = "<Control>0", .handler = fontReset },
    .{ .name = "clear_scrollback", .accel = "<Control><Shift>k", .handler = clear, .terminal_only = true },
    .{ .name = "restart_session", .accel = "<Control><Alt>r", .handler = restart, .terminal_only = true },
    .{ .name = "shell_session", .accel = "<Control><Shift>r", .handler = shell, .terminal_only = true },
    .{ .name = "open_settings", .accel = "<Control>comma", .handler = settings },
    .{ .name = "copy", .accel = "<Control><Shift>c", .handler = copy },
    .{ .name = "paste", .accel = "<Control><Shift>v", .handler = paste },
    .{ .name = "scroll_page_up", .accel = "<Shift>Page_Up", .handler = scrollUp },
    .{ .name = "scroll_page_down", .accel = "<Shift>Page_Down", .handler = scrollDown },
    .{ .name = "theme_toggle", .accel = "<Control><Shift>t", .handler = themeToggle },
    .{ .name = "find_open", .accel = "<Control><Shift>f", .handler = findOpen },
    .{ .name = "find_next", .accel = "<Control>g", .handler = findNext },
    .{ .name = "find_prev", .accel = "<Control><Shift>g", .handler = findPrev },
    .{ .name = "next_tab", .accel = "<Control>Tab", .handler = next, .multiple = true },
    .{ .name = "prev_tab", .accel = "<Control><Shift>Tab", .handler = prev, .multiple = true },
    .{ .name = "tab_1", .accel = "<Alt>1", .handler = tab(0), .multiple = true },
    .{ .name = "tab_2", .accel = "<Alt>2", .handler = tab(1), .multiple = true },
    .{ .name = "tab_3", .accel = "<Alt>3", .handler = tab(2), .multiple = true },
    .{ .name = "tab_4", .accel = "<Alt>4", .handler = tab(3), .multiple = true },
    .{ .name = "tab_5", .accel = "<Alt>5", .handler = tab(4), .multiple = true },
    .{ .name = "tab_6", .accel = "<Alt>6", .handler = tab(5), .multiple = true },
    .{ .name = "tab_7", .accel = "<Alt>7", .handler = tab(6), .multiple = true },
    .{ .name = "tab_8", .accel = "<Alt>8", .handler = tab(7), .multiple = true },
    .{ .name = "tab_9", .accel = "<Alt>9", .handler = tab(8), .multiple = true },
};

/// Explicit ownership: remove the controller before Context or host teardown.
/// GTK destroys the callbacks synchronously when this controller is removed.
pub const Installed = struct {
    panel: *Panel,
    controller: *gtk.GtkEventController,
    pub fn deinit(self: *Installed) void {
        gtk_widget_remove_controller(@ptrCast(self.panel.window), self.controller);
    }
};

pub fn install(panel: *Panel, ctx: *Context) Installed {
    const controller = gtk_shortcut_controller_new();
    gtk_shortcut_controller_set_scope(controller, 1); // managed
    gtk_event_controller_set_propagation_phase(controller, 1); // capture
    inline for (actions) |a| {
        var override: ?[]const u8 = null;
        for (ctx.config.keymap.entries) |entry| {
            if (std.mem.eql(u8, entry.name, a.name)) override = entry.binding;
        }
        const disabled = if (override) |binding| std.ascii.eqlIgnoreCase(binding, "none") else false;
        if (!disabled) {
            const converted = if (override) |binding| normalizeAccel(ctx.allocator, binding) catch |err| blk: {
                std.debug.print("keymap: invalid override for {s} ({}); retaining default\n", .{ a.name, err });
                break :blk null;
            } else null;
            defer if (converted) |text| ctx.allocator.free(text);
            const trigger = if (converted) |text| gtk_shortcut_trigger_parse_string(text.ptr) orelse blk: {
                std.debug.print("keymap: GTK rejected override for {s}; retaining default\n", .{a.name});
                break :blk gtk_shortcut_trigger_parse_string(a.accel);
            } else gtk_shortcut_trigger_parse_string(a.accel);
            if (trigger) |t| {
                const action = gtk_callback_action_new(callback(a), ctx, null);
                gtk_shortcut_controller_add_shortcut(controller, gtk_shortcut_new(t, action));
            }
        }
    }
    gtk.gtk_widget_add_controller(@ptrCast(panel.window), controller);
    return .{ .panel = panel, .controller = controller };
}
/// Shared config uses modifier+key spelling; GTK uses <Modifier>key.
/// Return an owned string consumed only during installation, not a borrowed
/// pointer into Config's arena. GTK converts this string into numeric keyvals.
fn normalizeAccel(allocator: std.mem.Allocator, binding: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var parts = std.mem.splitScalar(u8, binding, '+');
    while (parts.next()) |raw| {
        const token = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (token.len == 0 or std.mem.indexOfScalar(u8, token, 0) != null) return error.InvalidBinding;
        if (parts.index != null) {
            const mod: []const u8 = if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) "<Control>" else if (std.ascii.eqlIgnoreCase(token, "shift")) "<Shift>" else if (std.ascii.eqlIgnoreCase(token, "alt") or std.ascii.eqlIgnoreCase(token, "opt") or std.ascii.eqlIgnoreCase(token, "option")) "<Alt>" else if (std.ascii.eqlIgnoreCase(token, "super") or std.ascii.eqlIgnoreCase(token, "cmd") or std.ascii.eqlIgnoreCase(token, "command") or std.ascii.eqlIgnoreCase(token, "meta")) "<Super>" else return error.UnknownModifier;
            try out.appendSlice(allocator, mod);
        } else {
            const aliases = .{
                .{ "esc", "Escape" },          .{ "escape", "Escape" },       .{ "enter", "Return" },    .{ "return", "Return" },
                .{ "tab", "Tab" },             .{ "backspace", "BackSpace" }, .{ "delete", "Delete" },   .{ "home", "Home" },
                .{ "end", "End" },             .{ "up", "Up" },               .{ "down", "Down" },       .{ "left", "Left" },
                .{ "right", "Right" },         .{ "pageup", "Page_Up" },      .{ "page_up", "Page_Up" }, .{ "pagedown", "Page_Down" },
                .{ "page_down", "Page_Down" }, .{ "=", "equal" },             .{ "-", "minus" },         .{ ",", "comma" },
                .{ ".", "period" },            .{ "/", "slash" },             .{ "\\", "backslash" },    .{ "[", "bracketleft" },
                .{ "]", "bracketright" },      .{ ";", "semicolon" },         .{ "'", "apostrophe" },    .{ "`", "grave" },
            };
            var key: []const u8 = token;
            inline for (aliases) |alias| if (std.ascii.eqlIgnoreCase(token, alias[0])) {
                key = alias[1];
            };
            const start = out.items.len;
            try out.appendSlice(allocator, key);
            if (key.len == 1) out.items[start] = std.ascii.toLower(key[0]);
            if (key.len > 1 and (key[0] == 'f' or key[0] == 'F') and std.ascii.isDigit(key[1])) out.items[start] = 'F';
        }
    }
    if (out.items.len == 0) return error.InvalidBinding;
    return allocator.dupeSentinel(u8, out.items, 0);
}

fn callback(comptime a: Action) *const fn (*gtk.GtkWidget, ?*GVariant, gtk.gpointer) callconv(.c) c_int {
    return struct {
        fn run(_: *gtk.GtkWidget, _: ?*GVariant, data: gtk.gpointer) callconv(.c) c_int {
            const ctx: *Context = @ptrCast(@alignCast(data orelse return 0));
            if (a.multiple and ctx.session_host.sm.count() < 2) return 0;
            // Consume blocked host shortcuts too: never turn a failed host
            // action into input for the terminal behind the focused editor.
            if (a.terminal_only and clipboardDestination(ctx).route != .terminal) return 1;
            a.handler(ctx);
            return 1;
        }
    }.run;
}
fn fontInc(ctx: *Context) void {
    if (ctx.session_host.currentTerminal()) |t| t.fontScaleAdjust(0.1);
}
fn fontDec(ctx: *Context) void {
    if (ctx.session_host.currentTerminal()) |t| t.fontScaleAdjust(-0.1);
}
fn fontReset(ctx: *Context) void {
    if (ctx.session_host.currentTerminal()) |t| t.fontScaleReset();
}
fn clear(ctx: *Context) void {
    if (ctx.session_host.currentTerminal()) |t| t.clearScrollback();
}
fn restart(ctx: *Context) void {
    _ = ctx.session_host.restartActive(null);
}
fn shell(ctx: *Context) void {
    _ = ctx.session_host.openShellActive();
}
fn settings(ctx: *Context) void {
    openSettings(ctx.allocator);
}
const ClipboardRoute = enum { terminal, editable, ignore };
fn clipboardRoute(terminal_focused: bool, editable_focused: bool) ClipboardRoute {
    if (editable_focused) return .editable;
    return if (terminal_focused) .terminal else .ignore;
}
fn clipboardDestination(ctx: *Context) struct { route: ClipboardRoute, focus: ?*gtk.GtkWidget = null } {
    const root = gtk_widget_get_root(@ptrCast(ctx.panel.window)) orelse return .{ .route = .ignore };
    const focus = gtk_root_get_focus(root) orelse return .{ .route = .ignore };
    return .{
        .route = clipboardRoute(focus == ctx.session_host.currentVte(), g_type_check_instance_is_a(@ptrCast(focus), gtk_editable_get_type()) != 0),
        .focus = focus,
    };
}
fn copy(ctx: *Context) void {
    const dest = clipboardDestination(ctx);
    switch (dest.route) {
        .terminal => if (ctx.session_host.currentTerminal()) |t| t.copySelectionToClipboard(),
        .editable => _ = gtk_widget_activate_action_variant(dest.focus.?, "clipboard.copy", null),
        .ignore => {},
    }
}
fn paste(ctx: *Context) void {
    const dest = clipboardDestination(ctx);
    switch (dest.route) {
        .terminal => if (ctx.session_host.currentTerminal()) |t| t.pasteFromClipboard(),
        // GTK owns async clipboard lifetime and emits insert-text on GtkText
        // (the SearchEntry delegate), preserving find validation. Rejection or
        // an unavailable action is final: NEVER fall back to the PTY.
        .editable => _ = gtk_widget_activate_action_variant(dest.focus.?, "clipboard.paste", null),
        .ignore => {},
    }
}
fn scrollUp(ctx: *Context) void {
    if (ctx.session_host.currentTerminal()) |t| t.scrollPages(-1);
}
fn scrollDown(ctx: *Context) void {
    if (ctx.session_host.currentTerminal()) |t| t.scrollPages(1);
}
fn themeToggle(ctx: *Context) void {
    _ = ghostty_config.cycleAppearanceOverride();
    if (ctx.reapply_config) |hook| hook.on_invoke(hook.ctx);
}
fn findOpen(ctx: *Context) void {
    if (ctx.popovers.find_overlay) |f| f.open();
}
fn findNext(ctx: *Context) void {
    if (ctx.popovers.find_overlay) |f| f.findNext();
}
fn findPrev(ctx: *Context) void {
    if (ctx.popovers.find_overlay) |f| f.findPrevious();
}
fn next(ctx: *Context) void {
    _ = ctx.session_host.activateNext();
}
fn prev(ctx: *Context) void {
    _ = ctx.session_host.activatePrev();
}
fn tab(comptime idx: usize) *const fn (*Context) void {
    return struct {
        fn run(ctx: *Context) void {
            _ = ctx.session_host.activate(idx);
        }
    }.run;
}

const settings_skeleton =
    \\# djinn — terminal settings (key = value)
    \\hotkey = ctrl+shift+space
    \\inherit-ghostty = true
    \\open-at-login = false
    \\# profile.work.command = ssh example.org
    \\# profile.work.cwd = ~/projects
    \\# Profile membership and launch definitions require a restart.
    \\
;

/// Only an intentional Settings action creates config. Exclusive creation
/// avoids truncating an existing file, including an editor's concurrent save.
pub fn openSettings(allocator: std.mem.Allocator) void {
    const path = Config.defaultConfigPath(allocator) catch return;
    defer allocator.free(path);
    const backend = io.io();
    const dir = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| dir.createDirPath(backend, parent) catch |err| {
        std.debug.print("settings: create directory failed: {}\n", .{err});
        return;
    };
    if (dir.createFile(backend, path, .{ .exclusive = true })) |file| {
        defer file.close(backend);
        file.writeStreamingAll(backend, settings_skeleton) catch |err| {
            std.debug.print("settings: write failed: {}\n", .{err});
            return;
        };
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("settings: create failed: {}\n", .{err});
            return;
        },
    }
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(path_z);
    // GIO launches the desktop opener asynchronously; no child wait or
    // background task can retain path or a pointer into the caller's frame.
    const argv = [_:null]?[*:0]const u8{ "xdg-open", path_z.ptr };
    if (g_spawn_async(null, &argv, null, 4 | 8 | 16, null, null, null, null) == 0)
        std.debug.print("settings: could not launch xdg-open\n", .{});
}
extern "c" fn g_spawn_async(?[*:0]const u8, [*:null]const ?[*:0]const u8, ?[*:null]const ?[*:0]const u8, c_uint, ?*const fn (?*anyopaque) callconv(.c) void, ?*anyopaque, ?*c_int, ?*?*anyopaque) c_int;

test "keymap config spelling normalizes without GTK or config writes" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "ctrl+shift+c", "<Control><Shift>c" }, .{ "cmd+comma", "<Super>comma" },
        .{ "alt+1", "<Alt>1" },                   .{ "ctrl+pageup", "<Control>Page_Up" },
        .{ "shift+f12", "<Shift>F12" },           .{ "ctrl+,", "<Control>comma" },
    };
    inline for (cases) |case| {
        const text = try normalizeAccel(a, case[0]);
        defer a.free(text);
        try std.testing.expectEqualStrings(case[1], text);
    }
    try std.testing.expectError(error.InvalidBinding, normalizeAccel(a, "ctrl++c"));
    try std.testing.expectError(error.UnknownModifier, normalizeAccel(a, "bogus+c"));
}

test "capture clipboard routing never targets PTY behind an editor or unfocused window" {
    try std.testing.expectEqual(ClipboardRoute.terminal, clipboardRoute(true, false));
    try std.testing.expectEqual(ClipboardRoute.editable, clipboardRoute(false, true));
    try std.testing.expectEqual(ClipboardRoute.ignore, clipboardRoute(false, false));
    // Even an inconsistent focus report must prefer the editor, with no PTY
    // fallback if its native copy/paste action is unavailable or rejected.
    try std.testing.expectEqual(ClipboardRoute.editable, clipboardRoute(true, true));
    inline for (actions) |a| {
        if (std.mem.eql(u8, a.name, "clear_scrollback") or
            std.mem.eql(u8, a.name, "restart_session") or
            std.mem.eql(u8, a.name, "shell_session")) try std.testing.expect(a.terminal_only);
    }
}

test "keymap action table compiles" {
    _ = actions;
    _ = install;
}
test "terminal defaults leave Ctrl R reverse search to the child" {
    inline for (actions) |action| {
        try std.testing.expect(!std.mem.eql(u8, std.mem.span(action.accel), "<Control>r"));
    }
}

test "keymap retains terminal actions only and unique names" {
    inline for (actions, 0..) |a, i| {
        try std.testing.expect(!std.mem.startsWith(u8, a.name, "mcp"));
        try std.testing.expect(!std.mem.eql(u8, a.name, "palette_open"));
        inline for (actions[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}
