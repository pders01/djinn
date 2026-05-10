const std = @import("std");
const objc = @import("objc");
const Hotkey = @import("hotkey/darwin.zig").Hotkey;
const parseKeybinding = @import("hotkey/darwin.zig").parseKeybinding;
const Config = @import("config.zig").Config;
const Notifier = @import("notify/darwin.zig").Notifier;
const Menubar = @import("notify/menubar.zig").Menubar;
const Panel = @import("window/panel.zig").Panel;
const panel_mod = @import("window/panel.zig");
const view_mod = @import("terminal/view.zig");
const TerminalView = view_mod.TerminalView;
const McpServer = @import("mcp/server.zig").McpServer;
const writeMcpEndpointInfo = @import("mcp/server.zig").writeEndpointInfo;
const Dispatcher = @import("mcp/dispatch.zig").Dispatcher;
const ToolTable = @import("mcp/tools.zig").ToolTable;
const AgentState = @import("agent/state.zig").AgentState;
const LogView = @import("agent/log_view.zig").LogView;
const theme_mod = @import("theme/theme.zig");
const persist = @import("state/persist.zig");
const app = @import("app.zig");
const loginitem = @import("system/loginitem.zig");
const dispatch = @import("io/dispatch.zig");
const tis = @import("terminal/tis.zig");
const ghostty_runtime = @import("ghostty/runtime.zig");
const cli = @import("cli.zig");
const Session = @import("session/manager.zig").Session;
const session_live = @import("session/live.zig");
const layout = @import("window/layout.zig");
const surface_lifecycle = @import("ghostty/surface_lifecycle.zig");

const c_dispatch = @cImport({
    @cInclude("dispatch/dispatch.h");
});

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

    if (cfg.system.open_at_login) {
        loginitem.register() catch |err| {
            std.debug.print("warning: open_at_login register failed ({}); run from Djinn.app\n", .{err});
        };
    } else {
        loginitem.unregister() catch {};
    }

    var djinn_path_buf: [512]u8 = undefined;
    var ghostty_path_buf: [512]u8 = undefined;
    if (std.posix.getenv("HOME")) |home| {
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

// Hotkey callback runs on the main thread (CGEventTap source is added to the
// main run loop at hotkey init time). Safe to drive Cocoa from here.
fn toggleCallback() void {
    if (app.g.window.panel) |p| p.toggle();
}

fn onPanelResize(w: u32, h: u32) void {
    persist.saveDebounced(.{ .width = w, .height = h });
}

/// FSEvent fan-in handler. Re-loads config from disk and pushes deltas
/// into every subsystem that can absorb them at runtime. Settings that
/// require process-restart (scrollback size, log_pane visibility,
/// provider command, font metrics) are skipped — the user-visible
/// surface is a one-line warning to the log pane.
///
/// Memory: old config strings leak. Reload is rare (user-edit cadence)
/// and the strings are small (~hundreds of bytes). Avoiding the leak
/// would mean tracking every duped slice, which the surrounding code
/// doesn't need today.
/// mtime cache for the two watched config files. The dispatch
/// watch is parent-dir-granular (atomic-rename safe), so unrelated
/// writes in the same dir — most notably djinn's own
/// `~/.config/djinn/state.json` rewrites on every panel resize —
/// also fire the FSEvents callback. Comparing against the
/// previously-seen mtimes lets us short-circuit those before
/// re-parsing the files + rebuilding chrome / ghostty config.
var last_djinn_mtime: ?i128 = null;
var last_ghostty_mtime: ?i128 = null;

fn onConfigChanged() void {
    const allocator = app.g.allocator orelse return;
    const cfg_ptr = app.g.config orelse return;

    // mtime guard: if neither config file has changed since the last
    // reload, this FSEvent fired for a sibling write (state.json on
    // resize is the common case). Bail before doing any work.
    if (!configFilesChanged()) return;

    const old = cfg_ptr.*;

    // FSEvents may fire mid-rename when an atomic-write editor saves
    // (vim, VS Code, Helix). Retry a few times with a short sleep so
    // transient ENOENT / partial-read doesn't push a default Config{}
    // into the running app + clobber user settings.
    const new_cfg = loadConfigWithRetry(allocator) orelse {
        std.debug.print("warning: config reload failed (3 retries); keeping previous config\n", .{});
        return;
    };

    if (parseKeybinding(new_cfg.hotkey.toggle)) |kb| {
        if (app.g.hotkey) |hk| hk.setBinding(kb.keycode, kb.modifiers);
    } else |_| {}

    if (app.g.window.panel) |p| {
        p.setHideOnBlur(new_cfg.window.hide_on_blur);
        p.setTopmost(new_cfg.window.topmost);
        p.setInstantToggle(new_cfg.window.toggle_style == .instant);
    }

    if (app.g.notifier) |n| n.enabled = new_cfg.notifications.system_notifications;
    if (app.g.tool_table) |tt| tt.attention_sound = new_cfg.notifications.attention_sound;
    if (app.g.agent.menubar) |mb| mb.setEnabled(new_cfg.notifications.menubar_icon);

    // Log-pane visibility: only re-apply when the config value
    // actually changed. `toggle_log_pane` (Cmd+/) flips the same
    // state at runtime; resetting on every save would clobber the
    // user's hotkey override every time they edit any unrelated
    // config field.
    if (new_cfg.log_pane.enabled != old.log_pane.enabled) {
        view_mod.setLogPaneHidden(!new_cfg.log_pane.enabled);
    }

    if (new_cfg.system.open_at_login) {
        loginitem.register() catch {};
    } else {
        loginitem.unregister() catch {};
    }

    // Keymap overrides. Bindings removed from config since last reload
    // stay on their old override — view_mod.rebind has no "reset to
    // default" path and adding one isn't worth the complexity. Users
    // who want to revert bindings should restart djinn.
    for (new_cfg.keymap.entries) |entry| {
        const parsed = parseKeybinding(entry.binding) catch continue;
        _ = view_mod.rebind(entry.name, parsed.modifiers, parsed.keycode);
    }

    warnRestartRequired(old, new_cfg);
    session_live.reconcileProfiles(old, new_cfg);

    cfg_ptr.* = new_cfg;
    // reloadTheme → reapplyTheme already calls
    // ghostty_runtime.reloadConfigFromDisk + appSetColorScheme as
    // part of its path (see view.zig:reapplyTheme). Calling it
    // explicitly here too would do the same file-read + parse twice
    // on every save.
    view_mod.reloadTheme();
}

/// Emit one stderr warning per restart-required key whose value
/// changed. These are config keys with no live-apply path today —
/// users would otherwise edit + save + see no effect with no
/// indication why. Stderr surfaces in `Console.app` for `.app`
/// launches and the launching terminal for `just run`.
fn warnRestartRequired(old: Config, new_cfg: Config) void {
    if (old.mcp.enabled != new_cfg.mcp.enabled) {
        hostWarn("config: 'mcp-enabled' change requires restart", .{});
    }
    if (!eqOptStr(old.mcp.socket_path, new_cfg.mcp.socket_path)) {
        hostWarn("config: 'mcp-socket-path' change requires restart", .{});
    }
    if (!eqOptU32(old.scrollback.size, new_cfg.scrollback.size)) {
        hostWarn("config: 'scrollback-size' change requires restart", .{});
    }
    if (!std.mem.eql(u8, old.provider.name, new_cfg.provider.name) or
        !eqOptStr(old.provider.command, new_cfg.provider.command))
    {
        hostWarn("config: 'provider' / 'provider-command' change requires restart", .{});
    }
    if (!eqOptStr(old.profiles.default, new_cfg.profiles.default)) {
        hostWarn("config: 'default-profile' change requires restart", .{});
    }
    // Crossing legacy↔multi-profile boundaries is restart-required.
    // Mid-multi-profile add/remove is handled live by
    // reconcileProfiles, so no warning fires for that case.
    const legacy_old = old.profiles.entries.len == 0;
    const legacy_new = new_cfg.profiles.entries.len == 0;
    if (legacy_old != legacy_new) {
        hostWarn("config: switching between legacy single-profile and multi-profile mode requires restart", .{});
    }
}

/// Fan a warning to stderr (Console.app for `.app`, terminal for
/// `just run`) AND to the agent log pane so users running the bundle
/// — who typically don't watch Console.app — see the message in the
/// already-open side panel. Bounded 256-byte format buffer; longer
/// formats truncate. Caller-side: if the log append fails (OOM in
/// AgentState's bounded ring), we still emitted on stderr.
pub fn hostWarn(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    std.debug.print("{s}\n", .{msg});
    if (app.g.agent.state) |st| st.appendLog(.warn, msg) catch {};
}

fn eqOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn eqOptU32(a: ?u32, b: ?u32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
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
    const home = std.posix.getenv("HOME") orelse return true;
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
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    return stat.mtime;
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
        if (attempt > 0) std.Thread.sleep(20 * std.time.ns_per_ms);
        if (Config.load(allocator)) |cfg| return cfg else |_| {}
    }
    return null;
}

/// Restore last-resized window size, clamped to the cursor screen's
/// visibleFrame so a state.json captured on a 4K monitor doesn't paint
/// off-screen on a 13" laptop. Falls back to config defaults; floors at
/// 200×100 so a corrupt state.json doesn't crash AppKit.
fn restoreWindowSize(allocator: std.mem.Allocator, cfg: *const Config) struct { w: u32, h: u32 } {
    // Priority: explicit config dim → state.json → hardcoded default.
    // Explicit config wins so a user editing `window-width = 2000`
    // sees their change immediately, even when state.json holds an
    // older size from a previous launch. state.json fills in only when
    // the user hasn't pinned the dim in config (their resize lives on
    // across restarts).
    const persisted = persist.load(allocator);
    var width_i: u32 = cfg.window.width orelse if (persisted) |st| st.width else 800;
    var height_i: u32 = cfg.window.height orelse if (persisted) |st| st.height else 400;

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
        .inherit_ghostty_config = cfg.theme.inherit_ghostty,
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


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Tier-5 step 1: smoke-init the libghostty surface API. Sets
    // ghostty's global state + std.os.argv. Failures log + bail
    // because anything downstream (Tier-5 surface wiring) needs the
    // global state present. Pre-Tier-5 features still work even if
    // this fails — call `try` after we trust it.
    ghostty_runtime.init() catch |err| {
        std.debug.print("warning: ghostty_runtime.init failed ({}); continuing without surface API\n", .{err});
    };

    // Tier-5 step 2: stand up an App with stub callbacks. Confirms
    // ghostty_app_new + config_new + runtime_config plumbing are
    // reachable + don't crash on a default config. App handle is
    // freed at process exit; nothing is wired into the view yet.
    //
    // setHost wires `&app.g` into ghostty's userdata channel so
    // action callbacks can recover host state via
    // `ghostty_app_userdata`. Must run before App.init (which copies
    // the userdata pointer into runtime_config_s).
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var parsed_args = cli.Args{};
    switch (cli.parse(&args, &parsed_args)) {
        .run => {},
        .exit_ok => return,
        .exit_err => std.process.exit(1),
    }
    const keybinding_override = parsed_args.keybinding_override;
    const provider_override = parsed_args.provider_override;

    // Startup: missing file is fine (use defaults); any other error
    // surfaces so the user sees what's wrong instead of running with
    // mystery defaults.
    var config = Config.loadOrDefault(allocator) catch |err| {
        std.debug.print("error: config load failed: {}\n", .{err});
        std.process.exit(1);
    };

    ghostty_runtime.setHost(&app.g);
    var ghostty_app_opt = ghostty_runtime.App.init(config.scrollback.size);
    defer if (ghostty_app_opt) |*a| a.deinit();
    const keybinding = keybinding_override orelse config.hotkey.toggle;

    const binding = parseKeybinding(keybinding) catch {
        std.debug.print("error: invalid keybinding '{s}'\n", .{keybinding});
        std.process.exit(1);
    };

    var notifier = Notifier{ .enabled = config.notifications.system_notifications };
    var menubar = if (config.notifications.menubar_icon) Menubar.init() else Menubar{};
    defer menubar.deinit();
    menubar.setShowHideHandler(&toggleCallback);

    // Agent state — pushed by MCP tools, consumed by menubar (Phase 3.3) and
    // log panel (Phase 3.4). Declared early so all consumers can reference it.
    var agent_state = AgentState.init(allocator);
    defer agent_state.deinit();

    const dims = restoreWindowSize(allocator, &config);
    const w: f64 = @floatFromInt(dims.w);
    const h: f64 = @floatFromInt(dims.h);

    // Resolve theme: ghostty config (if inherited) → djinn config overrides
    // → system appearance fallback.
    // Tier-5 step 9: when ghostty backend is live, hand the resolved
    // ghostty_config_t to theme.resolve so the log_pane / menubar
    // palette tracks the surface palette without a separate file
    // re-parse. ghostty already loaded + finalized the config during
    // App.init.
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
    defer panel.deinit();
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

    // Active chrome style — derived once from the resolved theme. Find
    // overlay + log pane both read this so host UI surfaces share one
    // visual language. reapplyTheme rebuilds + reskins both on flips.
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

    // Build side log panel and wrap both in an NSSplitView (terminal left, log right).
    // Log uses opaque bg + theme palette colors so contrast inherits the
    // user's ghostty theme aesthetic.
    var log_view = LogView.init(
        layout.computeLogWidth(w, &config),
        h,
        chrome_style,
    ) catch |err| {
        std.debug.print("error: log view init failed: {}\n", .{err});
        std.process.exit(1);
    };
    // SessionManager — one Session per declared profile (or one
    // synthesized "default" for legacy configs that only set
    // `provider`). `--provider` CLI override mutates config.provider
    // BEFORE init so the synthesized default picks it up; explicitly
    // declared profiles ignore it (override has no profile name to
    // target). Warn the user when both are present so the silent
    // drop doesn't surprise them.
    if (provider_override) |name| {
        config.provider.name = name;
        if (config.profiles.entries.len > 0) {
            std.debug.print("warning: --provider override has no effect when `profile.*` keys are configured; ignoring '{s}'\n", .{name});
        }
    }
    const session_mod = @import("session/manager.zig");
    var session_manager = session_mod.SessionManager.init(allocator, &config) catch |err| {
        std.debug.print("error: session manager init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer session_manager.deinit();
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

    // Always build the dual-pane container so the runtime toggle
    // (Cmd+/ → toggle_log_pane) only flips visibility, no view-tree
    // rebuild. When log_pane.enabled = false at startup we hide the
    // log column and grow the terminal to fill via setLogPaneHidden.
    // MCP `djinn_log` calls always update AgentState; the log view
    // observes regardless of visibility so reopening shows backlog.
    const container = layout.buildContainer(w, h, &config, view.view, log_view.view, surface_host);
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
    view.observeLog(&log_view);
    if (!config.log_pane.enabled) view_mod.setLogPaneHidden(true);

    const grid = view.gridSize(w, h);

    // The legacy `provider` / `provider-command` resolution moved into
    // SessionManager.init — `cmd` here is the active session's
    // resolved spawn command.
    const cmd = active_session.profile.command;

    // chdir + sync PWD env so the spawned shell starts at $HOME
    // instead of `/` when djinn is launched via `open Djinn.app`
    // (LaunchServices sets both cwd and PWD to `/` for GUI apps).
    // Best-effort — silent skip if HOME isn't set.
    if (std.posix.getenv("HOME")) |home| {
        std.posix.chdir(home) catch {};
        const home_z = allocator.dupeZ(u8, home) catch null;
        if (home_z) |hz| {
            _ = libc_setenv("PWD", hz.ptr, 1);
            // Leak intentionally — env value lives until process exit
            // and libc may keep the pointer; freeing would dangle.
        }
    }

    // Surface owns the child via surface_config; vt-static parser was
    // retired in step 10 alongside CG drawRect. Cursor style + palette
    // come from ghostty's resolved Config (theme.resolve already pushed
    // them into our Theme struct, but the surface reads its own copy).
    view.attach();
    view.observeAgent(&agent_state, &menubar);

    // Persistent ghostty surface bound to `surface_host`. ghostty owns
    // the visible terminal area: its surface_new flips setWantsLayer
    // + assigns a CAMetalLayer to the host view, and ghostty drives
    // its own CADisplayLink for refresh. TerminalView stays in front
    // (transparent overlay) so it keeps capturing key + mouse events
    // and forwards them via ghostty_surface_key / mouse_*.
    var ghostty_surface_handle: ?ghostty_runtime.c.ghostty_surface_t = null;
    if (ghostty_app_opt) |*ga| {
        app.g.ghostty.app = ga;
        ghostty_surface_handle = surface_lifecycle.bindGhosttySurface(allocator, ga, surface_host, cmd, active_session.profile.cwd) orelse {
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
            for (session_manager.sessions.items) |sess| {
                if (sess.surface) |sp| ga.surfaceFree(@ptrCast(sp));
            }
        }
    }

    applyKeymapOverrides(&config);

    // Soft-fail on Accessibility denial. After a fresh install, the
    // bundle's signature differs from the prior copy in TCC's database,
    // so CGEventTap install raises a TCC prompt asynchronously and the
    // first call returns an error. Hard-exiting here makes the app die
    // before macOS can show the prompt — users see Djinn.app launch
    // and immediately quit, with no path forward. Falling through lets
    // the menubar click + the TCC prompt take over; once the user
    // grants permission and relaunches, the hotkey lights up.
    var hotkey_storage: Hotkey = undefined;
    var hotkey_active: bool = false;
    if (Hotkey.init(binding.keycode, binding.modifiers, &toggleCallback)) |hk| {
        hotkey_storage = hk;
        hotkey_active = true;
        app.g.hotkey = &hotkey_storage;
    } else |err| {
        std.debug.print(
            "warning: global hotkey failed ({}); System Settings → Privacy & Security → Accessibility → enable Djinn, then relaunch. Menubar click still toggles the panel.\n",
            .{err},
        );
    }
    defer if (hotkey_active) hotkey_storage.deinit();

    // MCP HTTP server. Gated on `mcp-enabled`; when off, the ToolTable
    // and Dispatcher still build (cheap, harmless) but no socket binds
    // and no accept thread spawns — and ~/.config/djinn/mcp.json isn't
    // touched, so stale endpoint info from a previous run isn't left
    // pointing at a port nothing's listening on.
    var tools = ToolTable{
        .state = &agent_state,
        .notifier = &notifier,
        .attention_sound = config.notifications.attention_sound,
    };
    app.g.tool_table = &tools;
    var dispatcher = Dispatcher{ .tool_table = tools.table() };
    var mcp_server_opt: ?McpServer = null;
    if (config.mcp.enabled) {
        mcp_server_opt = McpServer.init(allocator, dispatcher.handler()) catch |err| {
            std.debug.print("warning: MCP server init failed: {}\n", .{err});
            std.process.exit(1);
        };
    }
    defer if (mcp_server_opt) |*s| s.deinit();

    if (mcp_server_opt) |*s| {
        writeMcpEndpointInfo(allocator, s.port, s.token) catch |err| {
            std.debug.print("warning: failed to write MCP endpoint info: {}\n", .{err});
        };
        const mcp_thread = try std.Thread.spawn(.{}, McpServer.run, .{s});
        mcp_thread.detach();
    }

    var mcp_label_buf: [40]u8 = undefined;
    const mcp_label: []const u8 = if (mcp_server_opt) |s|
        std.fmt.bufPrint(&mcp_label_buf, "http://127.0.0.1:{d}", .{s.port}) catch "?"
    else
        "disabled";
    std.debug.print(
        "djinn running (provider: {s}, hotkey: {s}, grid: {d}x{d}, font: \"{s}\" @ {d:.1}pt, cell: {d:.0}x{d:.0}, mcp: {s})\n",
        .{
            config.provider.name,
            keybinding,
            grid.cols,
            grid.rows,
            theme.font_family,
            theme.font_size,
            view.cell_w,
            view.cell_h,
            mcp_label,
        },
    );

    // Seed the log panel so it isn't empty on first launch — gives users a
    // visible signal that the side panel is wired up before any agent
    // connects. Three separate entries so the same-client grouping reads
    // as one block under a single header instead of one long mid-token-
    // wrapping line joined by `·`.
    {
        agent_state.appendLog(.info, "djinn ready") catch {};
        if (mcp_server_opt) |s| {
            var mcp_msg: [64]u8 = undefined;
            const m = std.fmt.bufPrint(&mcp_msg, "MCP at 127.0.0.1:{d}", .{s.port}) catch "MCP up";
            agent_state.appendLog(.info, m) catch {};
        } else {
            agent_state.appendLog(.info, "MCP disabled") catch {};
        }
        agent_state.appendLog(.info, "waiting for agents") catch {};
    }

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
    _ = @import("hotkey/darwin.zig");
    _ = @import("config.zig");
    _ = @import("notify/darwin.zig");
    _ = @import("notify/menubar.zig");
    _ = @import("mcp/server.zig");
    _ = @import("mcp/tools.zig");
    _ = @import("agent/state.zig");
    _ = @import("agent/log_view.zig");
    _ = @import("theme/theme.zig");
    _ = @import("state/persist.zig");
    _ = @import("chrome.zig");
    _ = @import("mcp/dispatch.zig");
    _ = @import("session/manager.zig");
    _ = @import("terminal/keymap.zig");
}
