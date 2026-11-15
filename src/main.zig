const std = @import("std");
const platform = @import("io/platform.zig");
const objc = @import("objc");
const hotkey_mod = @import("hotkey/darwin.zig");
const Hotkey = hotkey_mod.Hotkey;
const parseKeybinding = hotkey_mod.parseKeybinding;
const Config = @import("config.zig").Config;
const Notifier = @import("notify/darwin.zig").Notifier;
const Menubar = @import("notify/menubar.zig").Menubar;
const Panel = @import("window/panel.zig").Panel;
const panel_mod = @import("window/panel.zig");
const view_mod = @import("terminal/view.zig");
const TerminalView = view_mod.TerminalView;
const theme_mod = @import("theme/theme.zig");
const persist = @import("state/persist.zig");
const app = @import("app.zig");
const loginitem = @import("system/loginitem.zig");
const dispatch = @import("io/dispatch.zig");
const tis = @import("terminal/tis.zig");
const ghostty_runtime = @import("ghostty/runtime.zig");
const cli = @import("cli.zig");
const Session = @import("session/manager.zig").Session;
const layout = @import("window/layout.zig");
const surface_lifecycle = @import("ghostty/surface_lifecycle.zig");

const c_dispatch = @import("darwin-c");

extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const libc_setenv = setenv;

/// Runs once the main run loop starts pumping. Pulls work off the
/// cold-start critical path that doesn't need to complete before the
/// first hotkey toggle / first paint:
///   - SMAppService login-item sync (XPC round-trip ~50-200ms cold)
///   - FSEventStream setup for live config reload
fn deferredPostLaunchInit(_: ?*anyopaque) callconv(.c) void {
    const cfg = app.g.config orelse return;
    reapDragDropTemps();

    if (cfg.system.open_at_login) {
        loginitem.register() catch |err| {
            std.debug.print("warning: open_at_login register failed ({}); run from Djinn.app\n", .{err});
        };
    } else {
        loginitem.unregister() catch {};
    }

    var djinn_path_buf: [512]u8 = undefined;
    var ghostty_path_buf: [512]u8 = undefined;
    if (platform.getenv("HOME")) |home| {
        const djinn_path = std.fmt.bufPrint(&djinn_path_buf, "{s}/.config/djinn/config", .{home}) catch null;
        const ghostty_path = std.fmt.bufPrint(&ghostty_path_buf, "{s}/.config/ghostty/config", .{home}) catch null;
        if (djinn_path) |dp| {
            const watch_paths = if (ghostty_path) |gp|
                &[_][]const u8{ dp, gp }
            else
                &[_][]const u8{dp};
            _ = dispatch.watchPaths(watch_paths, &onConfigChanged);
        }
    }
}

// Carbon delivers the registered shortcut on AppKit's main event loop.
// No global keyboard monitor is needed. Safe to drive Cocoa from here.
fn toggleCallback() void {
    if (app.g.window.panel) |p| p.toggle();
}

fn onPanelResize(w: u32, h: u32) void {
    const allocator = app.g.allocator orelse return;
    const active_name: ?[]const u8 = if (app.g.session_manager) |sm|
        sm.active().profile.name
    else
        null;
    persist.saveDebounced(allocator, w, h, active_name);
}

// Parsed Config owns its arena. Sessions independently own immutable launch data.
var last_djinn_mtime: ?i128 = null;
var last_ghostty_mtime: ?i128 = null;

fn onConfigChanged() void {
    const allocator = app.g.allocator orelse return;
    const cfg_ptr = app.g.config orelse return;
    if (!configFilesChanged()) return;

    var new_cfg = loadConfigWithRetry(allocator) orelse {
        hostWarn("config reload failed; keeping previous settings", .{});
        return;
    };

    const keybinding = app.g.hotkey_override orelse new_cfg.hotkey.toggle;
    const kb = parseKeybinding(keybinding) catch {
        hostWarn("invalid toggle hotkey; keeping previous settings", .{});
        new_cfg.deinit();
        return;
    };
    if (app.g.hotkey) |*hk| {
        hk.setBinding(kb.keycode, kb.modifiers) catch |err| {
            hostWarn("cannot register hotkey '{s}' ({}); keeping previous binding and settings", .{ keybinding, err });
            new_cfg.deinit();
            return;
        };
    } else {
        app.g.hotkey = Hotkey.init(allocator, kb.keycode, kb.modifiers, &toggleCallback) catch |err| {
            hostWarn("cannot register hotkey '{s}' ({}); keeping previous settings; menubar show/hide remains available", .{ keybinding, err });
            new_cfg.deinit();
            return;
        };
    }
    var old = cfg_ptr.*;
    defer old.deinit();
    if (app.g.window.panel) |p| {
        p.setHideOnBlur(new_cfg.window.hide_on_blur);
        p.setTopmost(new_cfg.window.topmost);
        p.setInstantToggle(new_cfg.window.toggle_style == .instant);
        p.setPosition(@fromBackingInt(@intCast(@backingInt(new_cfg.window.position))), new_cfg.window.position_x, new_cfg.window.position_y);
    }
    if (app.g.notifier) |n| {
        n.enabled = new_cfg.notifications.system_notifications;
        n.rate_limit_ms = new_cfg.notifications.rate_limit_ms;
    }
    if (app.g.menubar) |mb| mb.setEnabled(new_cfg.notifications.menubar_icon);
    if (new_cfg.system.open_at_login != old.system.open_at_login) {
        if (new_cfg.system.open_at_login) loginitem.register() catch {} else loginitem.unregister() catch {};
    }
    if (!std.meta.eql(old.scrollback, new_cfg.scrollback))
        hostWarn("config: scrollback-size change requires restart", .{});
    if (!profilesEqual(old, new_cfg))
        hostWarn("config: profile launch definitions changed; restart Djinn to apply (running sessions unchanged)", .{});

    cfg_ptr.* = new_cfg;
    view_mod.resetBindings();
    applyKeymapOverrides(cfg_ptr);
    view_mod.reloadTheme();
}

fn profilesEqual(a: Config, b: Config) bool {
    if (!eqOptStr(a.profiles.default, b.profiles.default)) return false;
    if (a.profiles.entries.len != b.profiles.entries.len) return false;
    for (a.profiles.entries, b.profiles.entries) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or
            !eqOptStr(x.command, y.command) or !eqOptStr(x.cwd, y.cwd) or
            !eqOptStr(x.title, y.title) or !eqOptStr(x.script, y.script) or
            x.bell_audible != y.bell_audible or x.bell_visual != y.bell_visual or
            !eqOptStr(x.bell_sound, y.bell_sound)) return false;
    }
    return true;
}

/// Ordinary host diagnostics; no activity-log subsystem.
pub fn hostWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("djinn: " ++ fmt ++ "\n", args);
}

fn eqOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Probe djinn + ghostty config mtimes; return true when either
/// changed since the last reload (or on the first call when the
/// cache is unset). Updates the cache so subsequent calls compare
/// against the latest seen values. Missing files (no ghostty
/// config, deleted djinn config mid-edit) compare as null and only
/// trigger a reload when the previously-seen value was non-null
/// (i.e. the file existed and is now gone) — atomic-rename gaps
/// where the file is briefly missing fall through to
/// `loadConfigWithRetry`'s ENOENT retries.
fn configFilesChanged() bool {
    const home = platform.getenv("HOME") orelse return true;
    var djinn_buf: [512]u8 = undefined;
    var ghostty_buf: [512]u8 = undefined;

    const djinn_path = std.fmt.bufPrint(&djinn_buf, "{s}/.config/djinn/config", .{home}) catch return true;
    const ghostty_path = std.fmt.bufPrint(&ghostty_buf, "{s}/.config/ghostty/config", .{home}) catch return true;

    const new_djinn_mt = fileMtime(djinn_path);
    const new_ghostty_mt = fileMtime(ghostty_path);

    const djinn_changed = !optI128Eq(last_djinn_mtime, new_djinn_mt);
    const ghostty_changed = !optI128Eq(last_ghostty_mtime, new_ghostty_mt);

    last_djinn_mtime = new_djinn_mt;
    last_ghostty_mtime = new_ghostty_mt;

    return djinn_changed or ghostty_changed;
}

fn fileMtime(path: []const u8) ?i128 {
    const file = std.Io.Dir.openFileAbsolute(platform.io(), path, .{}) catch return null;
    defer file.close(platform.io());
    const stat = file.stat(platform.io()) catch return null;
    return stat.mtime.nanoseconds;
}

fn optI128Eq(a: ?i128, b: ?i128) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// Reload the djinn config from disk with three short retries.
/// Atomic-write editors (vim, VS Code, Helix) rename a tmp file over
/// the target on save; FSEvents fires in the gap and an open here can
/// hit ENOENT. Returns null if every attempt fails — caller treats
/// that as "skip the reload, keep the previous config" instead of
/// substituting defaults.
fn loadConfigWithRetry(allocator: std.mem.Allocator) ?Config {
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        if (attempt > 0) platform.sleep(20 * std.time.ns_per_ms);
        if (Config.load(allocator)) |cfg| return cfg else |_| {}
    }
    return null;
}

/// Scan /tmp for `djinn-drop-*.png` files older than 1h and
/// remove them. Called once at startup so `/tmp` doesn't grow
/// unboundedly across launches. Failures are silent — a stale
/// temp file is annoying, not breaking, and we don't want to
/// block startup on a /tmp permission glitch.
fn reapDragDropTemps() void {
    var dir = std.Io.Dir.openDirAbsolute(platform.io(), "/tmp", .{ .iterate = true }) catch return;
    defer dir.close(platform.io());
    const now = platform.timestamp();
    const max_age_s: i64 = 3600;
    var it = dir.iterate();
    while (it.next(platform.io()) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "djinn-drop-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
        const stat = dir.statFile(platform.io(), entry.name, .{}) catch continue;
        const mtime_s = @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s);
        if (now - mtime_s < max_age_s) continue;
        dir.deleteFile(platform.io(), entry.name) catch continue;
    }
}

/// Resolve which profile will be active at startup, mirroring
/// `SessionManager.init`'s default-resolution rules. Pulled out so
/// `restoreWindowSize` can pick the per-profile dims before the
/// SessionManager is even built (the panel is created earlier in
/// `main` than the session manager — flipping that order is more
/// invasive than this 6-line helper).
fn resolveStartupProfileName(cfg: *const Config) []const u8 {
    if (cfg.profiles.entries.len == 0) return "default";
    if (cfg.profiles.default) |name| {
        for (cfg.profiles.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.name;
        }
    }
    return cfg.profiles.entries[0].name;
}

/// Restore last-resized window size, clamped to the cursor screen's
/// visibleFrame so a state.json captured on a 4K monitor doesn't paint
/// off-screen on a 13" laptop. Falls back to config defaults; floors at
/// 200×100 so a corrupt state.json doesn't crash AppKit.
/// When `active_profile` is non-null, the per-profile entry in
/// state.json wins over the top-level dims — log-heavy profiles can
/// stay tall+wide while shell profiles stay compact across launches.
fn restoreWindowSize(allocator: std.mem.Allocator, cfg: *const Config, active_profile: ?[]const u8) struct { w: u32, h: u32 } {
    // Priority: explicit config dim → state.json (per-profile, then
    // top-level) → hardcoded default. Explicit config wins so a user
    // editing `window-width = 2000` sees their change immediately,
    // even when state.json holds an older size from a previous launch.
    var maybe_state = persist.load(allocator);
    defer if (maybe_state) |*st| st.deinit(allocator);

    const persisted: ?struct { w: u32, h: u32 } = blk: {
        const st = maybe_state orelse break :blk null;
        if (active_profile) |name| {
            if (st.profileSize(name)) |p| break :blk .{ .w = p.w, .h = p.h };
        }
        if (st.width != 0 and st.height != 0) break :blk .{ .w = st.width, .h = st.height };
        break :blk null;
    };
    var width_i: u32 = cfg.window.width orelse if (persisted) |p| p.w else 800;
    var height_i: u32 = cfg.window.height orelse if (persisted) |p| p.h else 400;

    if (objc.getClass("NSScreen")) |sc| {
        const screen = panel_mod.currentScreen() orelse sc.msgSend(objc.Object, "mainScreen", .{});
        if (screen.value != null) {
            const vf: panel_mod.NSRect = screen.msgSend(panel_mod.NSRect, "visibleFrame", .{});
            const max_w: u32 = @intFromFloat(@max(1.0, vf.size.width));
            const max_h: u32 = @intFromFloat(@max(1.0, vf.size.height));
            if (width_i > max_w) width_i = max_w;
            if (height_i > max_h) height_i = max_h;
            if (width_i < 200) width_i = 200;
            if (height_i < 100) height_i = 100;
        }
    }
    return .{ .w = width_i, .h = height_i };
}

/// Resolve the active theme from ghostty config + djinn overrides. Bails
/// the process on resolution failure; nothing downstream survives a
/// missing theme. Caller owns the returned Theme + must `deinit`.
fn resolveTheme(allocator: std.mem.Allocator, cfg: *const Config, ghostty_cfg_opaque: ?*anyopaque) theme_mod.Theme {
    return theme_mod.resolve(allocator, .{
        .inherit_ghostty_config = true, // Runtime already decides whether user files are inherited.
        .ghostty_cfg = ghostty_cfg_opaque,
        .font_family = cfg.terminal.font_family,
        .font_size = cfg.terminal.font_size,
        .padding_x = cfg.terminal.padding_x,
        .padding_y = cfg.terminal.padding_y,
        .opacity = cfg.theme.opacity,
        .background = if (cfg.theme.background) |s| theme_mod.parseColor(s) else null,
        .foreground = if (cfg.theme.foreground) |s| theme_mod.parseColor(s) else null,
        .cursor_color = if (cfg.theme.cursor) |s| theme_mod.parseColor(s) else null,
    }) catch |err| {
        std.debug.print("error: theme resolve failed: {}\n", .{err});
        std.process.exit(1);
    };
}

/// Apply user keymap overrides to the host action table. Each entry
/// parses via the same hotkey grammar as the global toggle ("cmd+k").
/// Typos warn + skip; not fatal.
fn applyKeymapOverrides(cfg: *const Config) void {
    for (cfg.keymap.entries) |entry| {
        const parsed = parseKeybinding(entry.binding) catch |err| {
            std.debug.print("warning: keymap '{s}' = '{s}' parse failed ({})\n", .{ entry.name, entry.binding, err });
            continue;
        };
        if (!view_mod.rebind(entry.name, parsed.modifiers, parsed.keycode)) {
            std.debug.print("warning: keymap unknown action '{s}'\n", .{entry.name});
        }
    }
}

const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

pub fn main(init: std.process.Init) !void {
    platform.init(init.io);
    // Registered first, so native producers/owners are torn down before
    // their background tasks are joined and process startup destroys IO.
    defer {
        Notifier.shutdownSounds();
        persist.shutdown();
    }
    const allocator = init.gpa;

    // Parse host CLI options before initializing the terminal runtime.
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var parsed_args = cli.Args{};
    switch (cli.parse(&args, &parsed_args)) {
        .run => {},
        .exit_ok => return,
        .exit_err => std.process.exit(1),
    }
    // Diagnostics must not load config, spawn a shell, or sync login items.
    if (parsed_args.diagnose_hotkey) {
        const keybinding = parsed_args.keybinding_override orelse (Config.HotkeyConfig{}).toggle;
        const binding = parseKeybinding(keybinding) catch {
            std.debug.print("error: invalid keybinding '{s}'\n", .{keybinding});
            std.process.exit(1);
        };
        std.debug.print("hotkey diagnostic: binding={s}\n", .{keybinding});
        if (!hotkey_mod.diagnose(allocator, binding.keycode, binding.modifiers)) std.process.exit(1);
        return;
    }
    const keybinding_override = parsed_args.keybinding_override;

    // Startup: missing file is fine (use defaults); any other error
    // surfaces so the user sees what's wrong instead of running with
    // mystery defaults.
    var config = Config.loadOrDefault(allocator) catch |err| {
        std.debug.print("error: config load failed: {}\n", .{err});
        std.process.exit(1);
    };

    defer config.deinit();

    try ghostty_runtime.init();
    app.g.config = &config;
    app.g.allocator = allocator;
    app.g.hotkey_override = keybinding_override;
    ghostty_runtime.setHost(&app.g);
    var ghostty_app_opt = ghostty_runtime.App.init(config.scrollback.size);
    defer {
        app.g.ghostty.app = null;
        app.g.ghostty.config = null;
        if (ghostty_app_opt) |*a| a.deinit();
    }
    // Publish the owner before view attachment can trigger a theme reload.
    if (ghostty_app_opt) |*ga| app.g.ghostty.app = ga else return error.GhosttyAppInitFailed;
    const keybinding = keybinding_override orelse config.hotkey.toggle;

    const binding = parseKeybinding(keybinding) catch {
        std.debug.print("error: invalid keybinding '{s}'\n", .{keybinding});
        std.process.exit(1);
    };

    var notifier = Notifier{ .enabled = config.notifications.system_notifications };
    var menubar = if (config.notifications.menubar_icon) Menubar.init() else Menubar{};
    defer menubar.deinit();
    menubar.setShowHideHandler(&toggleCallback);

    app.g.menubar = &menubar;

    const startup_profile = resolveStartupProfileName(&config);
    const dims = restoreWindowSize(allocator, &config, startup_profile);
    const w: f64 = @floatFromInt(dims.w);
    const h: f64 = @floatFromInt(dims.h);

    // Resolve host chrome from Ghostty's finalized configuration.
    const ghostty_cfg_opaque: ?*anyopaque = if (ghostty_app_opt) |*ga| @ptrCast(ga.config) else null;
    app.g.ghostty.config = ghostty_cfg_opaque;
    var theme = resolveTheme(allocator, &config, ghostty_cfg_opaque);
    defer theme.deinit();

    const bg_r = @as(f64, @floatFromInt(theme.background.r)) / 255.0;
    const bg_g = @as(f64, @floatFromInt(theme.background.g)) / 255.0;
    const bg_b = @as(f64, @floatFromInt(theme.background.b)) / 255.0;
    const blur = theme.blur_radius > 0;

    var panel = Panel.init(w, h, theme.opacity, bg_r, bg_g, bg_b, blur) catch |err| {
        std.debug.print("error: panel init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer {
        app.g.window.panel = null;
        panel.deinit();
    }
    app.g.window.panel = &panel;
    // Theme reloader (viewDidChangeEffectiveAppearance) needs a stable
    // pointer to the config + an allocator. Stash both before the view
    // is created so the first appearance flip can already see them.
    app.g.allocator = allocator;
    app.g.config = &config;
    app.g.notifier = &notifier;
    // Bell now flows through ghostty's RING_BELL action handler, not
    // a Terminal callback (terminal.zig retired in step 10).
    panel.setHideOnBlur(config.window.hide_on_blur);
    panel.setInstantToggle(config.window.toggle_style == .instant);
    panel.setTopmost(config.window.topmost);
    panel.setPosition(
        switch (config.window.position) {
            .top_left => .top_left,
            .top_center => .top_center,
            .top_right => .top_right,
            .center_left => .center_left,
            .center => .center,
            .center_right => .center_right,
            .bottom_left => .bottom_left,
            .bottom_center => .bottom_center,
            .bottom_right => .bottom_right,
        },
        config.window.position_x,
        config.window.position_y,
    );
    panel.setResizeEndHandler(&onPanelResize);

    // With blur on, the panel is fully transparent and the visual-effect view
    // does the blur. The terminal view draws a translucent bg over it. Without
    // blur, the panel itself is alpha-modulated and the terminal bg is opaque.
    const view_bg_alpha: f64 = if (blur) theme.opacity else 1.0;

    // Find and tab chrome follow the terminal theme.
    const chrome_style = @import("chrome.zig").Style.fromTheme(theme);
    app.g.theme.chrome_style = chrome_style;

    // Build terminal view (computes cell metrics from chosen font).
    var view = TerminalView.init(w, h, theme.font_family, theme.font_size, theme.padding_x, theme.padding_y, view_bg_alpha, chrome_style) catch |err| {
        std.debug.print("error: terminal view init failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Prime TIS cache + register distributed-notification observer so
    // keyDownImpl's IME fast-path knows the current keyboard layout
    // without touching AppKit on each keystroke.
    tis.install();

    const session_mod = @import("session/manager.zig");
    var session_manager = session_mod.SessionManager.init(allocator, &config) catch |err| {
        std.debug.print("error: session manager init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer {
        app.g.session_manager = null;
        session_manager.deinit();
    }
    app.g.session_manager = &session_manager;

    // One surface_host NSView per session. All siblings, same frame,
    // same autoresizing mask — only the active one is unhidden. ghostty
    // binds a CAMetalLayer to whichever NSView its `newSurface` call
    // points at, so each session gets its own host.
    const NSView_surface = objc.getClass("NSView") orelse unreachable;
    for (session_manager.sessions.items, 0..) |*s, i| {
        const sh_alloc = NSView_surface.msgSend(objc.Object, "alloc", .{});
        const sh = sh_alloc.msgSend(
            objc.Object,
            "initWithFrame:",
            .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } }},
        );
        sh.msgSend(void, "setHidden:", .{@as(c_int, if (i == session_manager.active_idx) 0 else 1)});
        s.surface_host = sh.value;
    }
    const active_session = session_manager.active();
    const active_host_id: objc.c.id = @ptrCast(@alignCast(active_session.surface_host.?));
    const surface_host = objc.Object.fromId(active_host_id);
    app.g.layout.surface_host_id = active_host_id;

    const container = layout.buildContainer(w, h, &config, view.view, surface_host);
    app.g.layout.container_id = container.value;

    // Slot the inactive surface_hosts in as siblings of the active host,
    // pinned at the same frame + autoresizing mask. NSWindowBelow keeps
    // them under TerminalView so the transparent overlay still captures
    // key + mouse events. Visibility is governed by setHidden:; switching
    // tabs flips it.
    if (session_manager.sessions.items.len > 1) {
        const NSWindowBelow: c_long = -1;
        const term_frame = surface_host.msgSend(NSRect, "frame", .{});
        const term_mask = surface_host.msgSend(c_ulong, "autoresizingMask", .{});
        for (session_manager.sessions.items, 0..) |s, i| {
            if (i == session_manager.active_idx) continue;
            const sh = objc.Object.fromId(s.surface_host.?);
            sh.msgSend(void, "setFrame:", .{term_frame});
            sh.msgSend(void, "setAutoresizingMask:", .{term_mask});
            container.msgSend(void, "addSubview:positioned:relativeTo:", .{ sh, NSWindowBelow, surface_host });
        }
    }

    panel.setContentView(container);
    // makeFirstResponder(container) inside setContentView fails silently
    // because plain NSView returns NO from acceptsFirstResponder. Push
    // it to TerminalView explicitly — that's the view that owns
    // keyDownImpl + the responder-chain wiring.
    _ = panel.ns_panel.msgSend(c_int, "makeFirstResponder:", .{view.view});

    const grid = view.gridSize(w, h);

    // chdir + sync PWD env so the spawned shell starts at $HOME
    // instead of `/` when djinn is launched via `open Djinn.app`
    // (LaunchServices sets both cwd and PWD to `/` for GUI apps).
    // Best-effort — silent skip if HOME isn't set.
    if (platform.getenv("HOME")) |home| {
        std.process.setCurrentPath(platform.io(), home) catch {};
        const home_z = allocator.dupeSentinel(u8, home, 0) catch null;
        if (home_z) |hz| {
            _ = libc_setenv("PWD", hz.ptr, 1);
            allocator.free(hz); // setenv copies the value.
        }
    }

    // Surface owns the child via surface_config; vt-static parser was
    // retired in step 10 alongside CG drawRect. Cursor style + palette
    // come from ghostty's resolved Config (theme.resolve already pushed
    // them into our Theme struct, but the surface reads its own copy).
    view.attach();
    menubar.refresh();

    // Persistent ghostty surface bound to `surface_host`. ghostty owns
    // the visible terminal area: its surface_new flips setWantsLayer
    // + assigns a CAMetalLayer to the host view, and ghostty drives
    // its own CADisplayLink for refresh. TerminalView stays in front
    // (transparent overlay) so it keeps capturing key + mouse events
    // and forwards them via ghostty_surface_key / mouse_*.
    var ghostty_surface_handle: ?ghostty_runtime.c.ghostty_surface_t = null;
    if (ghostty_app_opt) |*ga| {
        app.g.ghostty.app = ga;
        ghostty_surface_handle = surface_lifecycle.bindGhosttySurface(allocator, ga, surface_host, active_session) orelse {
            std.debug.print("error: ghostty surface_new returned null\n", .{});
            std.process.exit(1);
        };
        active_session.surface = @ptrCast(ghostty_surface_handle.?);
        active_session.spawned = true;
        app.g.ghostty.surface = active_session.surface;
    } else {
        std.debug.print("error: ghostty App init failed; cannot continue\n", .{});
        std.process.exit(1);
    }
    // Free every spawned surface before app.deinit (LIFO: app defer was
    // registered earlier). Inactive sessions whose surfaces were never
    // bound are skipped (s.surface = null).
    defer {
        if (ghostty_app_opt) |*ga| {
            _ = ga;
            for (session_manager.sessions.items) |*sess| surface_lifecycle.destroySession(sess);
        }
    }

    applyKeymapOverrides(&config);

    // Register just the toggle shortcut; this does not require Accessibility.
    // Conflicts must not take down the terminal or menubar. Config reload can
    // retry with a different binding if startup registration failed.
    app.g.hotkey = Hotkey.init(allocator, binding.keycode, binding.modifiers, &toggleCallback) catch |err| blk: {
        // A disabled status item plus a rejected shortcut must not strand
        // a hidden LSUIElement app. This fallback never rewrites config.
        menubar.setEnabled(true);
        std.debug.print(
            "warning: cannot register global hotkey '{s}' ({}); quit other Djinn instances or choose another binding. Menubar show/hide remains available.\n",
            .{ keybinding, err },
        );
        break :blk null;
    };
    defer {
        if (app.g.hotkey) |*hk| hk.deinit();
        app.g.hotkey = null;
    }

    notifier.rate_limit_ms = config.notifications.rate_limit_ms;
    std.debug.print("djinn running (hotkey: {s}, registered: {}, profiles: {d}, grid: {d}x{d})\n", .{
        keybinding, app.g.hotkey != null, session_manager.count(), grid.cols, grid.rows,
    });

    // Defer login-item sync (SMAppService XPC) + FSEventStream setup
    // until the run loop starts pumping. Neither is on the path to
    // first hotkey / first paint; running them now just lengthens the
    // cold-start window for no observable user benefit.
    const main_queue = c_dispatch.dispatch_get_main_queue();
    dispatch_async_f(@ptrCast(main_queue), null, &deferredPostLaunchInit);

    // Drive AppKit's main run loop. Blocks until [NSApp stop:] or process exit.
    panel.ns_app.msgSend(void, "run", .{});
}

test {
    _ = @import("cli.zig");
    _ = @import("hotkey/darwin.zig");
    _ = @import("config.zig");
    _ = @import("notify/darwin.zig");
    _ = @import("notify/menubar.zig");
    _ = @import("theme/theme.zig");
    _ = @import("state/persist.zig");
    _ = @import("chrome.zig");
    _ = @import("session/manager.zig");
    _ = @import("terminal/keymap.zig");
    _ = @import("terminal/find.zig");
    _ = @import("terminal/view.zig");
    _ = @import("window/panel.zig");
    _ = @import("ghostty/surface_lifecycle.zig");
    _ = @import("ghostty/runtime.zig");
}
