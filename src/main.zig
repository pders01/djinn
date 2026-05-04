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
    if (app.g.panel) |p| p.toggle();
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
fn onConfigChanged() void {
    const allocator = app.g.allocator orelse return;
    const cfg_ptr = app.g.config orelse return;

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

    if (app.g.panel) |p| p.setHideOnBlur(new_cfg.window.hide_on_blur);

    if (app.g.notifier) |n| n.enabled = new_cfg.notifications.system_notifications;
    if (app.g.tool_table) |tt| tt.attention_sound = new_cfg.notifications.attention_sound;

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

    // Push fresh ghostty config to the surface — picks up the user's
    // ~/.config/ghostty/config edits (cursor-style, font, theme, …).
    ghostty_runtime.reloadConfigFromDisk();

    cfg_ptr.* = new_cfg;
    view_mod.reloadTheme();
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

fn isShell(cmd: []const u8) bool {
    const base = std.fs.path.basename(cmd);
    const shells = [_][]const u8{ "bash", "zsh", "fish", "sh", "dash", "tcsh", "csh", "ksh" };
    for (shells) |s| if (std.mem.eql(u8, base, s)) return true;
    return false;
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

/// Switch the visible session. Hides the previous active surface_host,
/// shows the target one, lazy-spawns its ghostty surface on first use,
/// and re-anchors the keyboard focus. Called by the `tab_N` / `next_tab`
/// / `prev_tab` action handlers in view.zig.
pub fn activateSession(idx: usize) bool {
    const sm = app.g.session_manager orelse return false;
    if (idx >= sm.sessions.len) return false;
    if (idx == sm.active_idx) return false;

    // Capture the old index up front + index by slot so the `old` /
    // `new` references don't shift under our feet when `switchTo`
    // flips `active_idx`. Both slots are reached via explicit array
    // index, never via `sm.active()` after the switch.
    const old_idx = sm.active_idx;
    const old_sess: *Session = &sm.sessions[old_idx];
    if (old_sess.surface_host) |host| {
        objc.Object.fromId(host).msgSend(void, "setHidden:", .{@as(c_int, 1)});
    }
    if (old_sess.surface) |sp| {
        ghostty_runtime.surfaceSetFocus(@ptrCast(sp), false);
    }

    _ = sm.switchTo(idx);
    const new_sess: *Session = &sm.sessions[idx];
    const new_host = objc.Object.fromId(new_sess.surface_host orelse return false);
    new_host.msgSend(void, "setHidden:", .{@as(c_int, 0)});

    // Lazy spawn — only the active-at-startup session was bound during
    // boot. Secondary profiles get their surface here on first activate.
    if (!new_sess.spawned) {
        const ga = app.g.ghostty_app orelse return false;
        const allocator = app.g.allocator orelse return false;
        const surf = bindGhosttySurface(allocator, ga, new_host, new_sess.profile.command, new_sess.profile.cwd) orelse {
            std.debug.print("error: lazy surface spawn failed for profile '{s}'\n", .{new_sess.profile.name});
            return false;
        };
        new_sess.surface = @ptrCast(surf);
        new_sess.spawned = true;
    }

    // Update the global pointer + AppState slot BEFORE re-focus so any
    // re-entrant Cocoa callback fired during setFocus sees the new
    // surface in app.g (reapplyTheme + updateSearchCountLabel both
    // read app.g.ghostty_surface).
    app.g.ghostty_surface = new_sess.surface;
    app.g.surface_host_id = if (new_sess.surface_host) |h| @ptrCast(@alignCast(h)) else null;
    if (new_sess.surface) |sp| {
        ghostty_runtime.surfaceSetFocus(@ptrCast(sp), true);
    }

    // Trigger menubar redraw — its dropdown subtitle reflects the
    // active profile name.
    if (app.g.menubar) |mb| {
        if (app.g.agent_state) |st| {
            const snap = st.snapshot();
            mb.updateState(@enumFromInt(@intFromEnum(snap.state)), snap.message);
        }
    }
    // Tab strip highlights the active idx; redraw to follow.
    @import("session/tab_strip.zig").refresh();
    return true;
}

/// Context for deferred surface re-spawn. Heap-allocated by
/// `restartActiveSession` and freed by `restartSurfaceCallback` —
/// the slices it carries are *borrowed*: cmd is either
/// `active.profile.command` (owned by SessionManager for the
/// program lifetime) or a static literal like "/bin/zsh"; cwd is
/// owned by SessionManager. No string lifetime to manage here.
const RestartCtx = struct {
    cmd: []const u8,
    cwd: ?[]const u8,
};

/// Re-spawn the active session's child process. When `override_cmd` is
/// non-null it replaces the profile's command (used by `shell_session`
/// to force /bin/zsh). The old surface is freed synchronously and the
/// new surface is bound on the next main-queue iteration so ghostty's
/// IO mailbox has a runloop turn to unwind.
pub fn restartActiveSession(override_cmd: ?[]const u8) void {
    const sm = app.g.session_manager orelse return;
    const ga = app.g.ghostty_app orelse return;
    const allocator = app.g.allocator orelse return;
    const active = sm.active();

    // Free the old surface. Null the session slot + global pointer so
    // nothing tries to use a stale handle between now and when the
    // re-spawn callback runs.
    if (active.surface) |sp| {
        ga.surfaceFree(@ptrCast(sp));
        active.surface = null;
        active.spawned = false;
        active.exited = false;
        app.g.ghostty_surface = null;
    }

    const ctx = allocator.create(RestartCtx) catch return;
    ctx.* = .{
        .cmd = override_cmd orelse active.profile.command,
        .cwd = active.profile.cwd,
    };

    // Schedule re-spawn on the next main-queue iteration. The
    // one-turn gap is load-bearing: ghostty's IO mailbox needs a
    // runloop cycle to unwind after surface_free before the same
    // NSView can host a fresh surface.
    const main_queue = c_dispatch.dispatch_get_main_queue();
    dispatch_async_f(@ptrCast(main_queue), ctx, &restartSurfaceCallback);
}

/// Callback fired by dispatch_async_f after a runloop turn. Recovers
/// the active session from global state, re-binds a ghostty surface
/// to its surface_host NSView, and refreshes tab strip + menubar.
fn restartSurfaceCallback(ctx_opaque: ?*anyopaque) callconv(.c) void {
    const ctx: *RestartCtx = @ptrCast(@alignCast(ctx_opaque orelse return));
    const allocator = app.g.allocator orelse return;
    defer allocator.destroy(ctx);

    const ga = app.g.ghostty_app orelse return;
    const sm = app.g.session_manager orelse return;
    const active = sm.active();

    const host_raw = active.surface_host orelse return;
    const host = objc.Object.fromId(host_raw);

    const surf = bindGhosttySurface(allocator, ga, host, ctx.cmd, ctx.cwd) orelse {
        std.debug.print("error: restart surface spawn failed for profile '{s}'\n", .{active.profile.name});
        return;
    };

    active.surface = @ptrCast(surf);
    active.spawned = true;
    active.exited = false;
    app.g.ghostty_surface = active.surface;
    app.g.surface_host_id = if (active.surface_host) |h| @ptrCast(@alignCast(h)) else null;

    // Re-anchor keyboard focus on the new surface's view. Without
    // this, AppKit may have lost the responder chain during the
    // surface_free → newSurface gap.
    if (app.g.view_id) |vid| {
        const term = objc.Object.fromId(vid);
        const window = term.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{term});
        }
    }

    // Tab strip + menubar refresh.
    @import("session/tab_strip.zig").refresh();
    if (app.g.menubar) |mb| {
        if (app.g.agent_state) |st| {
            const snap = st.snapshot();
            mb.updateState(@enumFromInt(@intFromEnum(snap.state)), snap.message);
        }
    }
}

/// Bind a persistent ghostty surface to `surface_host`. Returns null on
/// failure (caller logs + bails — host can't run without a surface).
/// Provider override flows through as argv[0]; a shell command (`zsh`,
/// `bash`, …) maps to null so ghostty applies its own `-i / -l` logic.
/// `cwd` overrides the spawn working directory; null = ghostty default.
pub fn bindGhosttySurface(
    allocator: std.mem.Allocator,
    ga: *ghostty_runtime.App,
    surface_host: objc.Object,
    cmd: []const u8,
    cwd: ?[]const u8,
) ?ghostty_runtime.c.ghostty_surface_t {
    const window_obj = surface_host.msgSend(objc.Object, "window", .{});
    const surface_scale: f64 = if (window_obj.value != null)
        window_obj.msgSend(f64, "backingScaleFactor", .{})
    else
        1.0;

    const surface_cmd: ?[*:0]const u8 = if (isShell(cmd)) null else blk: {
        // Heap-dup so the C side has a stable pointer for the surface
        // lifetime — intentional process-lifetime leak.
        const dup = allocator.dupeZ(u8, cmd) catch break :blk null;
        break :blk dup.ptr;
    };
    const surface_cwd: ?[*:0]const u8 = if (cwd) |w| blk: {
        const dup = allocator.dupeZ(u8, w) catch break :blk null;
        break :blk dup.ptr;
    } else null;

    const surf = ga.newSurface(@ptrCast(surface_host.value), surface_scale, surface_cmd, surface_cwd) orelse return null;

    surface_host.msgSend(void, "setHidden:", .{@as(c_int, 0)});
    const host_bounds = surface_host.msgSend(NSRect, "bounds", .{});
    const px_w: u32 = @intFromFloat(host_bounds.size.width * surface_scale);
    const px_h: u32 = @intFromFloat(host_bounds.size.height * surface_scale);
    ghostty_runtime.surfaceSetContentScale(surf, surface_scale);
    ghostty_runtime.surfaceSetSize(surf, px_w, px_h);
    ghostty_runtime.surfaceSetFocus(surf, true);
    std.debug.print("ghostty: surface bound + foregrounded ({d}x{d}px @ {d:.1}x)\n", .{ px_w, px_h, surface_scale });
    return surf;
}

const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

/// Compute the log pane width for a given panel width. Reads bounds
/// from the active Config so users can tune the fraction + min/max
/// without recompiling.
pub fn computeLogWidth(panel_w: f64, cfg: *const Config) f64 {
    const desired = panel_w * cfg.log_pane.width_fraction;
    return @min(cfg.log_pane.width_max, @max(cfg.log_pane.width_min, desired));
}

/// Plain NSView container with autoresizing-driven layout: terminal flexes
/// to fill, log keeps proportional width on the right edge. NSSplitView's
/// auto-layout glitches inside an NSVisualEffectView during live resize
/// (panes go blank); manual frames + autoresizing flags are robust.
fn buildContainer(
    width: f64,
    height: f64,
    cfg: *const Config,
    terminal: objc.Object,
    log: objc.Object,
    surface_host: objc.Object,
) objc.Object {
    const log_width: f64 = computeLogWidth(width, cfg);

    const NSView = objc.getClass("NSView") orelse unreachable;
    const c_alloc = NSView.msgSend(objc.Object, "alloc", .{});
    const container = c_alloc.msgSend(
        objc.Object,
        "initWithFrame:",
        .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } }},
    );
    container.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});

    const divider_w: f64 = view_mod.divider_width;
    const term_w = @max(1.0, width - log_width - divider_w);

    // Multi-profile tab strip: built when more than one profile is
    // declared. Eats `tab_strip.tab_h` off the top of the container;
    // every below-strip frame uses `term_h = height - tab_h`.
    const tab_strip = @import("session/tab_strip.zig");
    var tab_h: f64 = 0;
    if (app.g.session_manager) |sm| {
        if (sm.sessions.len > 1) tab_h = tab_strip.tab_h;
    }
    const term_h = @max(1.0, height - tab_h);

    // Tier-5 surface host: sibling of `terminal` at the same frame.
    // Added FIRST (z-bottom) so TerminalView sits in front and
    // continues to capture key/mouse events even in surface mode.
    // TerminalView's drawRect early-returns when surface is bound so
    // its (transparent) NSView lets the surface_host CAMetalLayer
    // show through.
    surface_host.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = term_w, .height = term_h },
    }});
    surface_host.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    surface_host.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    container.msgSend(void, "addSubview:", .{surface_host});

    terminal.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = term_w, .height = term_h },
    }});
    // WidthSizable | HeightSizable — terminal absorbs most of the extra space.
    terminal.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    container.msgSend(void, "addSubview:", .{terminal});

    // Vertical divider between terminal + log. Subclassed as
    // `DjinnDivider` so it can host its own mouseDown/Dragged/Up
    // handlers (drag-to-resize) and a resize cursor rect. Width = 4px
    // is wide enough to grab reliably; the visible alpha is kept low
    // so the line still reads as a hairline.
    const divider = view_mod.createDivider(term_w, term_h);
    container.msgSend(void, "addSubview:", .{divider});
    app.g.divider_view_id = divider.value;

    log.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = term_w + divider_w, .y = 0 },
        .size = .{ .width = log_width, .height = term_h },
    }});
    // MinXMargin | HeightSizable — log stays anchored to the right
    // edge with fixed width. Width changes only via the toggle path.
    log.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 0) | (1 << 4))});
    container.msgSend(void, "addSubview:", .{log});

    if (tab_h > 0) {
        const strip = tab_strip.create(width, height);
        container.msgSend(void, "addSubview:", .{strip});
        app.g.tab_strip_id = strip.value;
        if (app.g.chrome_style) |s| tab_strip.applyStyle(s);
    }

    return container;
}

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
    ghostty_runtime.setHost(&app.g);
    var ghostty_app_opt = ghostty_runtime.App.init();
    defer if (ghostty_app_opt) |*a| a.deinit();

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
    app.g.ghostty_config = ghostty_cfg_opaque;
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
    app.g.panel = &panel;
    // Theme reloader (viewDidChangeEffectiveAppearance) needs a stable
    // pointer to the config + an allocator. Stash both before the view
    // is created so the first appearance flip can already see them.
    app.g.allocator = allocator;
    app.g.config = &config;
    app.g.notifier = &notifier;
    // Bell now flows through ghostty's RING_BELL action handler, not
    // a Terminal callback (terminal.zig retired in step 10).
    panel.setHideOnBlur(config.window.hide_on_blur);
    panel.setResizeEndHandler(&onPanelResize);

    // With blur on, the panel is fully transparent and the visual-effect view
    // does the blur. The terminal view draws a translucent bg over it. Without
    // blur, the panel itself is alpha-modulated and the terminal bg is opaque.
    const view_bg_alpha: f64 = if (blur) theme.opacity else 1.0;

    // Active chrome style — derived once from the resolved theme. Find
    // overlay + log pane both read this so host UI surfaces share one
    // visual language. reapplyTheme rebuilds + reskins both on flips.
    const chrome_style = @import("chrome.zig").Style.fromTheme(theme);
    app.g.chrome_style = chrome_style;

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
        computeLogWidth(w, &config),
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
    for (session_manager.sessions, 0..) |*s, i| {
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
    app.g.surface_host_id = active_host_id;

    // Always build the dual-pane container so the runtime toggle
    // (Cmd+/ → toggle_log_pane) only flips visibility, no view-tree
    // rebuild. When log_pane.enabled = false at startup we hide the
    // log column and grow the terminal to fill via setLogPaneHidden.
    // MCP `djinn_log` calls always update AgentState; the log view
    // observes regardless of visibility so reopening shows backlog.
    const container = buildContainer(w, h, &config, view.view, log_view.view, surface_host);

    // Slot the inactive surface_hosts in as siblings of the active host,
    // pinned at the same frame + autoresizing mask. NSWindowBelow keeps
    // them under TerminalView so the transparent overlay still captures
    // key + mouse events. Visibility is governed by setHidden:; switching
    // tabs flips it.
    if (session_manager.sessions.len > 1) {
        const NSWindowBelow: c_long = -1;
        const term_frame = surface_host.msgSend(NSRect, "frame", .{});
        const term_mask = surface_host.msgSend(c_ulong, "autoresizingMask", .{});
        for (session_manager.sessions, 0..) |s, i| {
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
        app.g.ghostty_app = ga;
        ghostty_surface_handle = bindGhosttySurface(allocator, ga, surface_host, cmd, active_session.profile.cwd) orelse {
            std.debug.print("error: ghostty surface_new returned null\n", .{});
            std.process.exit(1);
        };
        active_session.surface = @ptrCast(ghostty_surface_handle.?);
        active_session.spawned = true;
        app.g.ghostty_surface = active_session.surface;
    } else {
        std.debug.print("error: ghostty App init failed; cannot continue\n", .{});
        std.process.exit(1);
    }
    // Free every spawned surface before app.deinit (LIFO: app defer was
    // registered earlier). Inactive sessions whose surfaces were never
    // bound are skipped (s.surface = null).
    defer {
        if (ghostty_app_opt) |*ga| {
            for (session_manager.sessions) |sess| {
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

    // MCP HTTP server.
    var tools = ToolTable{
        .state = &agent_state,
        .notifier = &notifier,
        .attention_sound = config.notifications.attention_sound,
    };
    app.g.tool_table = &tools;
    var dispatcher = Dispatcher{ .tool_table = tools.table() };
    var mcp_server = McpServer.init(allocator, dispatcher.handler()) catch |err| {
        std.debug.print("warning: MCP server init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer mcp_server.deinit();

    writeMcpEndpointInfo(allocator, mcp_server.port, mcp_server.token) catch |err| {
        std.debug.print("warning: failed to write MCP endpoint info: {}\n", .{err});
    };

    const mcp_thread = try std.Thread.spawn(.{}, McpServer.run, .{&mcp_server});
    mcp_thread.detach();

    std.debug.print(
        "djinn running (provider: {s}, hotkey: {s}, grid: {d}x{d}, font: \"{s}\" @ {d:.1}pt, cell: {d:.0}x{d:.0}, mcp: http://127.0.0.1:{d})\n",
        .{
            config.provider.name,
            keybinding,
            grid.cols,
            grid.rows,
            theme.font_family,
            theme.font_size,
            view.cell_w,
            view.cell_h,
            mcp_server.port,
        },
    );

    // Seed the log panel so it isn't empty on first launch — gives users a
    // visible signal that the side panel is wired up before any agent
    // connects. Three separate entries so the same-client grouping reads
    // as one block under a single header instead of one long mid-token-
    // wrapping line joined by `·`.
    {
        agent_state.appendLog(.info, "djinn ready") catch {};
        var mcp_msg: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&mcp_msg, "MCP at 127.0.0.1:{d}", .{mcp_server.port}) catch "MCP up";
        agent_state.appendLog(.info, m) catch {};
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
}
