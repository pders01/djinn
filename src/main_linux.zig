//! Linux terminal-first GTK4/VTE shell with live config reload.
const std = @import("std");
const io = @import("io/platform.zig");
const Config = @import("config.zig").Config;
const platform = @import("platform/linux.zig");
const cli = @import("cli.zig");
const persist = @import("state/persist.zig");
const SessionManager = @import("session/manager.zig").SessionManager;
const gtk = @import("platform/linux/gtk.zig");
extern "c" fn g_unix_signal_add(c_int, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;

const Dispatch = struct {
    allocator: std.mem.Allocator,
    panel: *platform.Panel,
    config: *Config,
    ghostty_colors: *?platform.GhosttyColors,
    keybinding_override: ?[]const u8,
    session_manager: *SessionManager,
    notifier: *platform.Notifier,
    session_host: ?*platform.SessionHost = null,
    tab_strip: ?*platform.TabStrip = null,
    hotkey: ?*?platform.Hotkey = null,
    tray: ?*?platform.Tray = null,
    pending_reload: ?struct { config: Config, hotkey: platform.Hotkey } = null,
    reap_source: c_uint = 0,

    fn discardPending(self: *Dispatch) void {
        if (self.pending_reload) |*pending| {
            std.debug.print("config: discarding pending hotkey attempt {d}; retaining previous config\n", .{pending.hotkey.attemptId()});
            pending.hotkey.deinit(); // detach, never run the shared main loop
            pending.config.deinit();
            self.pending_reload = null;
        }
    }

    fn onRegistration(ctx: *anyopaque, attempt: u64, outcome: platform.hotkey.Outcome) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        var pending = self.pending_reload orelse return;
        if (!registrationMatches(pending.hotkey.attemptId(), attempt)) return;
        if (outcome == .failed) {
            std.debug.print("config: hotkey attempt {d} failed; retaining previous config\n", .{attempt});
            self.discardPending();
            return;
        }
        const slot = self.hotkey orelse {
            self.discardPending();
            return;
        };
        self.pending_reload = null;
        self.commitConfig(pending.config) catch |err| {
            std.debug.print("config: profile reload rejected ({}); retaining previous config and binding\n", .{err});
            pending.hotkey.deinit();
            pending.config.deinit();
            return;
        };
        if (slot.*) |*old| old.deinit();
        slot.* = pending.hotkey;
    }

    fn onCommand(ctx: *anyopaque, command: platform.IpcCommand) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        switch (command) {
            .toggle => if (self.panel.isVisible()) self.panel.hide() else self.showPanel(),
            .show => self.showPanel(),
            .hide => self.panel.hide(),
            .quit => self.panel.quit(),
        }
    }

    fn showPanel(self: *Dispatch) void {
        self.panel.show();
        if (self.session_host) |host| {
            // A transient failure after profile retirement leaves the selected
            // profile without a VTE widget; retry without requiring a config edit.
            if (host.currentVte() == null) host.syncProfileSelection();
        }
    }

    fn onHotkey(ctx: *anyopaque) void {
        onCommand(ctx, .toggle);
    }
    fn onShow(ctx: *anyopaque) void {
        onCommand(ctx, .show);
    }
    fn onHide(ctx: *anyopaque) void {
        onCommand(ctx, .hide);
    }
    fn onQuit(ctx: *anyopaque) void {
        onCommand(ctx, .quit);
    }
    fn onSettings(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        platform.keymap.openSettings(self.allocator);
    }
    fn onToggleLogin(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        const status = platform.AutoStart.status(self.allocator) catch return;
        if (status == .enabled) {
            platform.AutoStart.unregister(self.allocator) catch |err| {
                std.debug.print("autostart: unregister failed: {}\n", .{err});
                return;
            };
        } else platform.AutoStart.register(self.allocator) catch |err| {
            std.debug.print("autostart: register failed: {}\n", .{err});
            return;
        };
        // This is intentionally not config writeback. The explicit menu
        // action changes the XDG entry, not the user's profiles/settings.
        if (self.tray) |slot| if (slot.*) |*tray| tray.notifyMenuChanged();
    }
    fn loginEnabled(ctx: *anyopaque) bool {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        return (platform.AutoStart.status(self.allocator) catch return false) == .enabled;
    }
    fn onBell(ctx: *anyopaque, idx: usize) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (idx >= self.session_manager.count()) return;
        const session = self.session_manager.sessions.items[idx];
        if (session.profile.bell_visual orelse self.config.bell.visual)
            self.panel.flashBell();
        // A standard terminal BEL can request attention without an agent API.
        if (shouldNotifyBell(self.session_manager.active_idx, idx, self.panel.isActive()))
            self.notifier.send(session.id, session.label(), "Terminal bell");
    }
    fn onChildExited(ctx: *anyopaque, idx: usize) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        const host = self.session_host orelse return;
        // Defer terminal destruction until after the VTE callback returns.
        if (self.session_manager.sessions.items[idx].retired) {
            if (self.reap_source == 0) self.reap_source = gtk.g_idle_add(reapRetired, self);
            return;
        }
        // Route using the emitting session, never the selected terminal.
        if (host.terminalAt(idx)) |term|
            term.feedScreen("\r\n\x1b[2m[djinn] Process exited. Ctrl+Alt+R restarts; Ctrl+Shift+R opens a shell.\x1b[0m\r\n");
        host.markExited(idx, true);
    }
    fn reapRetired(ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *Dispatch = @ptrCast(@alignCast(ctx orelse return 0));
        self.reap_source = 0;
        const host = self.session_host orelse return 0;
        var selection_changed = false;
        var idx = self.session_manager.count();
        while (idx > 0) {
            idx -= 1;
            const s = self.session_manager.sessions.items[idx];
            if (!s.retired or !s.exited) continue;
            if (host.removeRetired(idx)) selection_changed = true;
            if (self.tab_strip) |strip| strip.removeAt(idx);
        }
        if (selection_changed) host.syncProfileSelection();
        return 0;
    }

    fn onExitChanged(ctx: *anyopaque, idx: usize, exited: bool) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (self.tab_strip) |strip| strip.markExited(idx, exited);
    }
    fn onSwitched(ctx: *anyopaque, idx: usize) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (self.tab_strip) |strip| strip.markActive(idx);
        self.applyProfileWindowSize(idx);
    }
    fn onTitleChanged(ctx: *anyopaque, idx: usize) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (self.tab_strip) |strip| strip.refreshLabel(idx);
    }
    fn onPanelResize(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        persist.saveDebounced(self.allocator, w, h, self.session_manager.active().profile.name);
    }
    fn applyProfileWindowSize(self: *Dispatch, idx: usize) void {
        if (idx >= self.session_manager.count()) return;
        var state = persist.load(self.allocator);
        defer if (state) |*s| s.deinit(self.allocator);
        const size = (state orelse return).profileSize(self.session_manager.sessions.items[idx].profile.name) orelse return;
        self.panel.setSize(@intCast(self.config.window.width orelse size.w), @intCast(self.config.window.height orelse size.h));
    }
    fn onSignal(data: ?*anyopaque) callconv(.c) c_int {
        onQuit(data orelse return 1);
        return 1;
    }
    fn onAppearanceChanged(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        const host = self.session_host orelse return;
        const colors = loadColors(self.allocator, self.config);
        const opts = buildThemeOptions(self.config, colors);
        host.applyTheme(opts);
        if (self.tab_strip) |strip| strip.applyTheme(opts);
        if (self.ghostty_colors.*) |*old| old.deinit(self.allocator);
        self.ghostty_colors.* = colors;
        if (self.tray) |slot| if (slot.*) |*tray| tray.notifyAppearanceChanged();
    }
    fn onConfigChanged(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (self.session_host == null or self.hotkey == null) return;
        self.discardPending(); // a newer file event supersedes the whole candidate
        var candidate = loadConfigWithRetry(self.allocator) orelse {
            // The watcher also watches Ghostty. With no djinn settings file,
            // keep our current policy but still pick up inherited colors.
            onAppearanceChanged(ctx);
            return;
        };
        // An explicit CLI override remains authoritative on EVERY reload.
        if (self.keybinding_override) |binding| candidate.hotkey.toggle = binding;
        if (!std.mem.eql(u8, self.config.hotkey.toggle, candidate.hotkey.toggle)) {
            const fresh = platform.Hotkey.init(self.allocator, .{ .ctx = self, .on_activated = onHotkey, .on_registration = onRegistration }, candidate.hotkey.toggle) catch |err| {
                std.debug.print("config: hotkey reload rejected ({}); retaining previous config\n", .{err});
                candidate.deinit();
                return;
            };
            self.pending_reload = .{ .config = candidate, .hotkey = fresh };
            std.debug.print("config: awaiting hotkey attempt {d}; previous binding/config remain active\n", .{fresh.attemptId()});
            return;
        }
        self.commitConfig(candidate) catch |err| {
            std.debug.print("config: profile reload rejected ({}); retaining previous config\n", .{err});
            candidate.deinit();
        };
    }

    fn applyProfiles(self: *Dispatch, host: *platform.SessionHost, candidate: *const Config) !void {
        const strip = self.tab_strip orelse unreachable;
        var plan = try self.session_manager.prepareReload(candidate);
        defer plan.deinit();
        var entries = try host.prepareProfileEntries(&plan.preview);
        errdefer entries.deinit(self.allocator);
        const fresh = try platform.TabStrip.init(self.allocator, &plan.preview, strip.on_activate, strip.theme_opts);
        host.applyProfileReload(&plan, entries);
        strip.replaceWith(fresh);
    }

    fn commitConfig(self: *Dispatch, candidate: Config) !void {
        const host = self.session_host orelse unreachable;
        var old = self.config.*;
        const active_id = self.session_manager.active().id;
        if (profilesChanged(&old, &candidate)) try self.applyProfiles(host, &candidate);
        const colors = loadColors(self.allocator, &candidate);
        const opts = buildThemeOptions(&candidate, colors);
        // Every cached borrowed theme string is moved onto candidate storage
        // before releasing old arenas. Sessions own their launch data.
        host.applyTheme(opts);
        host.applyScrollback(candidate.scrollback.size);
        if (self.tab_strip) |strip| strip.applyTheme(opts);
        if (old.window.width != candidate.window.width or old.window.height != candidate.window.height) {
            const current = self.panel.currentSize();
            self.panel.setSize(@intCast(candidate.window.width orelse @as(u32, @intCast(@max(1, current.w)))), @intCast(candidate.window.height orelse @as(u32, @intCast(@max(1, current.h)))));
        }
        self.panel.setHideOnBlur(candidate.window.hide_on_blur);
        self.panel.setTopmost(candidate.window.topmost);
        syncAutostart(self.allocator, candidate.system.open_at_login);
        if (keymapChanged(&old, &candidate))
            std.debug.print("config: keymap changes require restart\n", .{});
        self.panel.setPosition(candidate.window.position, candidate.window.position_x, candidate.window.position_y);
        if (old.notifications.menubar_icon != candidate.notifications.menubar_icon)
            std.debug.print("config: tray visibility changes require restart\n", .{});
        self.notifier.enabled = candidate.notifications.system_notifications;
        self.notifier.rate_limit_ms = candidate.notifications.rate_limit_ms;
        host.bell_audible_default = candidate.bell.audible;
        // Currently spawned VTE audible bell flags are spawn policy.
        if (old.bell.audible != candidate.bell.audible)
            std.debug.print("config: audible bell changes apply on next session restart\n", .{});
        self.config.* = candidate;
        if (self.ghostty_colors.*) |*previous| previous.deinit(self.allocator);
        self.ghostty_colors.* = colors;
        old.deinit();
        if (active_id != self.session_manager.active().id or host.currentVte() == null) host.syncProfileSelection();
        if (self.tray) |slot| if (slot.*) |*tray| {
            tray.notifyAppearanceChanged();
            tray.notifyMenuChanged();
        };
    }
};
fn registrationMatches(pending_attempt: ?u64, source_attempt: u64) bool {
    return if (pending_attempt) |attempt| attempt == source_attempt else false;
}

fn shouldNotifyBell(active_idx: usize, source_idx: usize, focused: bool) bool {
    return active_idx != source_idx or !focused;
}

fn onTabActivate(ctx: *anyopaque, id: u64) bool {
    const host: *platform.SessionHost = @ptrCast(@alignCast(ctx));
    return host.activate(host.sm.indexOfId(id) orelse return false);
}
fn loadConfigWithRetry(allocator: std.mem.Allocator) ?Config {
    for (0..3) |attempt| {
        if (Config.load(allocator)) |config| return config else |err| {
            if (err != error.FileNotFound or attempt == 2) {
                std.debug.print("config: reload failed ({}); keeping previous config\n", .{err});
                return null;
            }
            io.sleep(20 * std.time.ns_per_ms);
        }
    }
    return null;
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}
fn profilesChanged(old: *const Config, new: *const Config) bool {
    if (!optionalEqual(old.profiles.default, new.profiles.default) or old.profiles.entries.len != new.profiles.entries.len) return true;
    for (old.profiles.entries, new.profiles.entries) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or !optionalEqual(a.command, b.command) or !optionalEqual(a.cwd, b.cwd) or !optionalEqual(a.title, b.title) or !optionalEqual(a.script, b.script) or a.bell_audible != b.bell_audible or a.bell_visual != b.bell_visual or !optionalEqual(a.bell_sound, b.bell_sound)) return true;
    }
    return false;
}
fn keymapChanged(old: *const Config, new: *const Config) bool {
    if (old.keymap.entries.len != new.keymap.entries.len) return true;
    for (old.keymap.entries, new.keymap.entries) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.binding, b.binding)) return true;
    }
    return false;
}
fn loadColors(allocator: std.mem.Allocator, config: *const Config) ?platform.GhosttyColors {
    if (!config.theme.inherit_ghostty) return null;
    return platform.ghostty_config.loadFromUserConfig(allocator) catch |err| {
        std.debug.print("ghostty config: load failed ({}); using VTE defaults\n", .{err});
        return null;
    };
}
fn syncAutostart(allocator: std.mem.Allocator, policy: ?bool) void {
    platform.AutoStart.setPolicy(policy);
    platform.AutoStart.syncPolicy(allocator) catch |err| {
        std.debug.print("autostart: policy sync failed: {}\n", .{err});
    };
}
const ColorField = enum { background, foreground, cursor };
fn mergeColor(hex: ?[]const u8, colors: ?platform.GhosttyColors, field: ColorField) ?platform.ghostty_config.Rgb {
    if (hex) |value| if (platform.ghostty_config.parseColor(value)) |color| return color;
    const gc = colors orelse return null;
    return switch (field) {
        .background => gc.background,
        .foreground => gc.foreground,
        .cursor => gc.cursor,
    };
}
fn buildThemeOptions(config: *const Config, colors: ?platform.GhosttyColors) platform.ThemeOptions {
    return .{
        .font_family = config.terminal.font_family orelse if (colors) |gc| gc.font_family else null,
        .font_size = config.terminal.font_size orelse if (colors) |gc| gc.font_size else null,
        .background = mergeColor(config.theme.background, colors, .background),
        .foreground = mergeColor(config.theme.foreground, colors, .foreground),
        .cursor = mergeColor(config.theme.cursor, colors, .cursor),
        .padding_x = config.terminal.padding_x,
        .padding_y = config.terminal.padding_y,
        .opacity = config.theme.opacity,
        .palette = if (colors) |gc| gc.palette else @splat(null),
    };
}

pub fn main(init: std.process.Init) !void {
    io.init(init.io);
    // Registered first: shared-context pumping is legal ONLY after every
    // native owner/producer has detached, while process IO/GPA still live.
    defer {
        platform.Hotkey.shutdown();
        platform.Terminal.shutdown();
    }
    defer persist.shutdown();
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    platform.AutoStart.setLauncherArgv0(args.next());
    var parsed = cli.Args{};
    switch (cli.parse(&args, &parsed)) {
        .run => {},
        .exit_ok => return,
        .exit_err => std.process.exit(1),
    }
    if (parsed.window_action) |action| {
        platform.ipc.send(allocator, switch (action) {
            .toggle => .toggle,
            .show => .show,
            .hide => .hide,
            .quit => .quit,
        }) catch |err| {
            std.debug.print("djinn: window action failed ({}) — is djinn running?\n", .{err});
            std.process.exit(1);
        };
        return;
    }
    var config = try Config.loadOrDefault(allocator);
    defer config.deinit();
    platform.AutoStart.setPolicy(config.system.open_at_login);
    if (parsed.keybinding_override) |binding| config.hotkey.toggle = binding;
    var sm = try SessionManager.init(allocator, &config);
    defer sm.deinit();
    var state = persist.load(allocator);
    defer if (state) |*s| s.deinit(allocator);
    var panel = try platform.Panel.open(.{
        .width = @intCast(config.window.width orelse if (state) |s| if (s.width > 0) s.width else 800 else 800),
        .height = @intCast(config.window.height orelse if (state) |s| if (s.height > 0) s.height else 400 else 400),
        .title = "djinn",
        .position = config.window.position,
        .position_x = config.window.position_x,
        .position_y = config.window.position_y,
    });
    defer panel.deinit();
    var colors = loadColors(allocator, &config);
    defer if (colors) |*c| c.deinit(allocator);
    var notifier = platform.Notifier.init(.{ .enabled = config.notifications.system_notifications, .rate_limit_ms = config.notifications.rate_limit_ms });
    defer notifier.deinit(); // SessionHost callback producers stop first.
    // Final-address, main-frame callback registry. Sources are removed before
    // owners/contexts die; nothing is registered against a returned local.
    var dispatch: Dispatch = .{ .allocator = allocator, .panel = &panel, .config = &config, .ghostty_colors = &colors, .keybinding_override = parsed.keybinding_override, .session_manager = &sm, .notifier = &notifier };
    // Claim IPC before spawning children or changing login state. A second
    // instance fails cleanly instead of stealing the first instance's socket.
    var ipc = try platform.Ipc.init(allocator, .{ .ctx = &dispatch, .on_command = Dispatch.onCommand });
    defer ipc.deinit();
    const opts = buildThemeOptions(&config, colors);
    var host = try platform.SessionHost.init(allocator, &sm, opts, .{ .ctx = &dispatch, .on_child_exited = Dispatch.onChildExited, .on_bell = Dispatch.onBell }, config.bell.audible);
    host.applyScrollback(config.scrollback.size);
    defer {
        dispatch.session_host = null;
        host.deinit();
    }
    dispatch.session_host = &host;
    var strip = try platform.TabStrip.init(allocator, &sm, .{ .ctx = &host, .on_invoke = onTabActivate }, opts);
    defer strip.deinit();
    dispatch.tab_strip = &strip;
    host.on_switch = .{ .ctx = &dispatch, .on_invoke = Dispatch.onSwitched };
    host.on_exit_changed = .{ .ctx = &dispatch, .on_invoke = Dispatch.onExitChanged };
    host.setTitleChangedHandler(.{ .ctx = &dispatch, .on_invoke = Dispatch.onTitleChanged });
    // De-register forwarded UI callbacks before stripping widgets down.
    defer {
        if (dispatch.reap_source != 0) _ = gtk.g_source_remove(dispatch.reap_source);
        host.on_switch = null;
        host.on_exit_changed = null;
        host.setTitleChangedHandler(null);
        dispatch.tab_strip = null;
    }
    panel.attachChild(strip.pairWithChild(host.widget()));
    dispatch.applyProfileWindowSize(sm.active_idx);
    panel.setOnResize(&dispatch, Dispatch.onPanelResize);
    panel.setHideOnBlur(config.window.hide_on_blur);
    panel.setTopmost(config.window.topmost);
    const active_vte = host.currentVte() orelse return error.NoActiveSession;
    var find = try platform.FindOverlay.init(allocator, host.widget(), @ptrCast(active_vte));
    defer find.deinit();
    find.install();
    panel.trackPopoverGrabs(find.popoverWidget());
    host.find_overlay = &find;
    defer host.find_overlay = null;
    var keymap_ctx: platform.KeymapContext = .{ .session_host = &host, .allocator = allocator, .panel = &panel, .config = &config, .reapply_config = .{ .ctx = &dispatch, .on_invoke = Dispatch.onAppearanceChanged }, .popovers = .{ .find_overlay = &find } };
    var shortcuts = platform.keymap.install(&panel, &keymap_ctx);
    defer {
        keymap_ctx.reapply_config = null;
        shortcuts.deinit();
    }
    var hotkey: ?platform.Hotkey = platform.Hotkey.init(allocator, .{ .ctx = &dispatch, .on_activated = Dispatch.onHotkey }, config.hotkey.toggle) catch |err| blk: {
        std.debug.print("hotkey: unavailable ({}); bind `djinn --toggle` in your compositor\n", .{err});
        break :blk null;
    };
    defer {
        dispatch.hotkey = null;
        dispatch.discardPending();
        if (hotkey) |*h| h.deinit();
    }
    dispatch.hotkey = &hotkey;
    var tray: ?platform.Tray = if (config.notifications.menubar_icon) platform.Tray.init(allocator, .{ .ctx = &dispatch, .on_activate = Dispatch.onHotkey, .on_show = Dispatch.onShow, .on_hide = Dispatch.onHide, .on_quit = Dispatch.onQuit, .on_open_settings = Dispatch.onSettings, .on_toggle_login = Dispatch.onToggleLogin, .login_enabled = Dispatch.loginEnabled }) catch |err| blk: {
        std.debug.print("tray: unavailable ({})\n", .{err});
        break :blk null;
    } else null;
    defer {
        dispatch.tray = null;
        if (tray) |*t| t.deinit();
    }
    dispatch.tray = &tray;
    syncAutostart(allocator, config.system.open_at_login);
    const config_path = try Config.defaultConfigPath(allocator);
    defer allocator.free(config_path);
    const home = io.getenv("HOME") orelse "";
    const ghostty_path = try std.fmt.allocPrint(allocator, "{s}/.config/ghostty/config", .{home});
    defer allocator.free(ghostty_path);
    var watcher: ?platform.Watcher = platform.Watcher.init(allocator, &.{ config_path, ghostty_path }, .{ .ctx = &dispatch, .on_changed = Dispatch.onConfigChanged }) catch |err| blk: {
        std.debug.print("config: watcher unavailable ({})\n", .{err});
        break :blk null;
    };
    defer if (watcher) |*w| w.deinit();
    var appearance: ?platform.AppearanceListener = platform.AppearanceListener.init(allocator, .{ .ctx = &dispatch, .on_changed = Dispatch.onAppearanceChanged }) catch null;
    defer if (appearance) |*a| a.deinit();
    const term_source = g_unix_signal_add(15, Dispatch.onSignal, &dispatch);
    defer if (term_source != 0) {
        _ = gtk.g_source_remove(term_source);
    };
    const int_source = g_unix_signal_add(2, Dispatch.onSignal, &dispatch);
    defer if (int_source != 0) {
        _ = gtk.g_source_remove(int_source);
    };
    _ = panel.focusChild(active_vte);
    panel.runLoop();
}

test "registration source attribution rejects failed superseded and retired generations" {
    // A late success/failure from attempt 10 must not commit/discard candidate
    // 11. A retired transaction has no pending attempt at all.
    try std.testing.expect(registrationMatches(11, 11));
    try std.testing.expect(!registrationMatches(11, 10));
    try std.testing.expect(!registrationMatches(null, 11));
}

test {
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("io/platform.zig");
    _ = @import("session/manager.zig");
    _ = @import("state/persist.zig");
    _ = @import("version.zig");
    _ = @import("platform/linux/panel.zig");
    _ = @import("platform/linux/terminal.zig");
    _ = @import("platform/linux/gtk.zig");
    _ = @import("platform/linux/ipc.zig");
    _ = @import("platform/linux/hotkey.zig");
    _ = @import("platform/linux/appearance.zig");
    _ = @import("platform/linux/tray.zig");
    _ = @import("platform/linux/notifier.zig");
    _ = @import("platform/linux/watcher.zig");
    _ = @import("platform/linux/autostart.zig");
    _ = @import("platform/linux/dragdrop.zig");
    _ = @import("platform/linux/theme.zig");
    _ = @import("platform/linux/ghostty_config.zig");
    _ = @import("platform/linux/keymap.zig");
    _ = @import("platform/linux/session_host.zig");
    _ = @import("platform/linux/tab_strip.zig");
}

test "Config: parse + deinit round-trip" {
    var cfg = try Config.parse(std.testing.allocator, "hotkey = ctrl+shift+space\nwindow-width = 1200\nwindow-height = 600\nbackground = #112233\nfont-size = 16\n");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("ctrl+shift+space", cfg.hotkey.toggle);
    try std.testing.expectEqual(@as(?u32, 1200), cfg.window.width);
    try std.testing.expectEqual(@as(?u32, 600), cfg.window.height);
    try std.testing.expectEqualStrings("#112233", cfg.theme.background.?);
    try std.testing.expectEqual(@as(?f64, 16), cfg.terminal.font_size);
}
test "Config: default-constructed deinit is a no-op" {
    var cfg: Config = .{};
    cfg.deinit();
}
test "mergeColor: djinn hex wins over ghostty" {
    const colors: platform.GhosttyColors = .{ .background = .{ .r = 0, .g = 0, .b = 0 } };
    const c = mergeColor("#ff8040", colors, .background).?;
    try std.testing.expectEqual(@as(u8, 0xff), c.r);
    try std.testing.expectEqual(@as(u8, 0x80), c.g);
    try std.testing.expectEqual(@as(u8, 0x40), c.b);
}
test "mergeColor: ghostty fills gaps when djinn is null" {
    const colors: platform.GhosttyColors = .{ .foreground = .{ .r = 0xab, .g = 0xcd, .b = 0xef } };
    const c = mergeColor(null, colors, .foreground).?;
    try std.testing.expectEqual(@as(u8, 0xab), c.r);
    try std.testing.expectEqual(@as(u8, 0xcd), c.g);
    try std.testing.expectEqual(@as(u8, 0xef), c.b);
}
test "mergeColor: returns null when neither source has a value" {
    try std.testing.expect(mergeColor(null, null, .cursor) == null);
    try std.testing.expect(mergeColor(null, platform.GhosttyColors{}, .cursor) == null);
}
test "mergeColor: malformed djinn hex falls through to ghostty" {
    const colors: platform.GhosttyColors = .{ .background = .{ .r = 0x10, .g = 0x20, .b = 0x30 } };
    try std.testing.expectEqual(@as(u8, 0x10), mergeColor("not-a-hex", colors, .background).?.r);
}
test "buildThemeOptions: djinn config wins on every field" {
    var cfg = try Config.parse(std.testing.allocator, "font-family = \"Cascadia Code\"\nfont-size = 13\nbackground = #010203\nforeground = #040506\ncursor-color = #070809\nopacity = 0.75\npadding-x = 8\npadding-y = 4\n");
    defer cfg.deinit();
    const colors: platform.GhosttyColors = .{
        .background = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .cursor = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .font_family = "Ghostty Font",
        .font_size = 99,
    };
    const opts = buildThemeOptions(&cfg, colors);
    try std.testing.expectEqualStrings("Cascadia Code", opts.font_family.?);
    try std.testing.expectEqual(@as(?f64, 13), opts.font_size);
    try std.testing.expectEqual(@as(u8, 1), opts.background.?.r);
    try std.testing.expectEqual(@as(u8, 4), opts.foreground.?.r);
    try std.testing.expectEqual(@as(u8, 7), opts.cursor.?.r);
    try std.testing.expectEqual(@as(?f64, 8), opts.padding_x);
    try std.testing.expectEqual(@as(?f64, 4), opts.padding_y);
    try std.testing.expectEqual(@as(?f64, 0.75), opts.opacity);
}
test "buildThemeOptions: ghostty fills gaps when djinn unset" {
    var cfg = try Config.parse(std.testing.allocator, "");
    defer cfg.deinit();
    var colors: platform.GhosttyColors = .{ .background = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, .font_family = "Inherited", .font_size = 11 };
    colors.palette[3] = .{ .r = 1, .g = 2, .b = 3 };
    const opts = buildThemeOptions(&cfg, colors);
    try std.testing.expectEqualStrings("Inherited", opts.font_family.?);
    try std.testing.expectEqual(@as(?f64, 11), opts.font_size);
    try std.testing.expectEqual(@as(u8, 0xaa), opts.background.?.r);
    // No explicit opacity means native reset, not the legacy window fallback.
    try std.testing.expectEqual(@as(?f64, null), opts.opacity);
    try std.testing.expectEqual(@as(u8, 2), opts.palette[3].?.g);
}
test "buildThemeOptions: no ghostty inheritance" {
    var cfg = try Config.parse(std.testing.allocator, "background = #abcdef\n");
    defer cfg.deinit();
    const opts = buildThemeOptions(&cfg, null);
    try std.testing.expectEqual(@as(u8, 0xab), opts.background.?.r);
    try std.testing.expect(opts.foreground == null);
    try std.testing.expect(opts.font_family == null);
    try std.testing.expectEqual(@as(?f64, null), opts.opacity);
    for (opts.palette) |slot| try std.testing.expect(slot == null);
}
test "buildThemeOptions: opacity removal restores native policy without legacy fallback" {
    var cfg: Config = .{};
    // Legacy window opacity must not fill a removed terminal override.
    cfg.window.opacity = 0.4;
    for ([_]?f64{ 0.75, 0, 1, null }) |opacity| {
        cfg.theme.opacity = opacity;
        for ([_]?platform.GhosttyColors{ .{}, null }) |colors| {
            const opts = buildThemeOptions(&cfg, colors);
            try std.testing.expectEqual(opacity, opts.opacity);
        }
    }
}
test "terminal BEL attention follows emitting source and panel focus" {
    try std.testing.expect(!shouldNotifyBell(0, 0, true));
    try std.testing.expect(shouldNotifyBell(0, 0, false));
    try std.testing.expect(shouldNotifyBell(0, 1, true));
    try std.testing.expect(shouldNotifyBell(0, 1, false));
}

test "optionalEqual: identity" {
    try std.testing.expect(optionalEqual("ctrl+space", "ctrl+space"));
    try std.testing.expect(!optionalEqual("ctrl+space", "alt+space"));
    try std.testing.expect(optionalEqual("", ""));
    try std.testing.expect(optionalEqual(null, null));
    try std.testing.expect(!optionalEqual(null, ""));
}

test "reload launch definitions compare by value, not arena identity" {
    var a = try Config.parseStrict(std.testing.allocator, "profile.work.command = echo hello\n");
    defer a.deinit();
    var b = try Config.parseStrict(std.testing.allocator, "profile.work.command = echo hello\n");
    defer b.deinit();
    try std.testing.expect(!profilesChanged(&a, &b));
    b.profiles.entries = &.{.{ .name = "work", .command = "echo changed" }};
    try std.testing.expect(profilesChanged(&a, &b));
}
