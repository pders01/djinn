//! Linux entry point.
//!
//! djinn was born on macOS as a libghostty-surface host wrapped in an
//! NSPanel + AppKit chrome. The Linux port replaces that chrome with a
//! GTK4 borderless window driven by `gtk4-layer-shell` for Quake-drop
//! semantics on KDE / Hyprland / sway / wlroots-likes (plain toplevel
//! fallback on GNOME). The terminal area is a VTE widget — ghostty's
//! embeddable surface API is darwin-only, so the Linux build uses
//! Linux's standard embeddable terminal instead. Same MCP server,
//! same agent state, same config; different chrome and terminal engine.
//!
//! This is the build-system `root_source_file` when the target is
//! linux. It deliberately does NOT import `main.zig` — that pulls in
//! zig-objc + AppKit + CGEventTap modules that don't compile outside
//! darwin. Per-target roots keep the darwin path byte-for-byte intact
//! while the Linux side grows in `src/platform/linux/*`.
//!
//! Current scope: config load, capability probe (gtk4 / layer-shell /
//! Wayland), open layer-shell panel, embed VTE terminal with the user
//! shell. Not yet wired: MCP server, global hotkey, tray icon, agent
//! log pane, drag-drop, config file watcher, autostart. Each lands as
//! its own subsystem under `platform/linux/`.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
// Direct import of the linux platform aggregator — `platform.zig` is
// the cross-OS narrow surface (just `Notifier` + `NotifyKind` for
// `mcp/tools.zig` today). Linux-only consumers (panel, terminal,
// hotkey, tray, watcher, autostart, log_pane, ghostty_config, keymap)
// would have to detour through `platform.zig`'s comptime switch +
// darwin-stub branches with no caller-visible benefit. Darwin's
// `src/main.zig` follows the same convention — it goes directly to
// `hotkey/darwin.zig`, `notify/menubar.zig`, etc. The result is a
// platform.zig that's truly minimal and not a kitchen sink of
// abstractions that don't pay rent.
const platform = @import("platform/linux.zig");
const AgentState = @import("agent/state.zig").AgentState;
const ToolTable = @import("mcp/tools.zig").ToolTable;
const Dispatcher = @import("mcp/dispatch.zig").Dispatcher;
const McpServer = @import("mcp/server.zig").McpServer;
const writeMcpEndpointInfo = @import("mcp/server.zig").writeEndpointInfo;
const cli = @import("cli.zig");
const persist = @import("state/persist.zig");
const SessionManager = @import("session/manager.zig").SessionManager;

/// `g_unix_signal_add` lives in libgio (gio-2.0); routes a POSIX
/// signal onto the GLib main loop, freeing us from sigaction-style
/// async-signal-safety constraints. The handler runs synchronously
/// from the loop after the kernel marks the signal pending. Returning
/// 1 keeps the source alive; 0 removes it (we'd want 0 only if we
/// re-armed on each delivery, which we don't need for SIGTERM).
const GSourceFunc = *const fn (user_data: ?*anyopaque) callconv(.c) c_int;
extern "c" fn g_unix_signal_add(signum: c_int, function: GSourceFunc, user_data: ?*anyopaque) c_uint;

/// `g_timeout_add` callback shape: returns 1 to keep the source
/// firing on its interval, 0 to remove it after this dispatch.
/// Used by the recurring drag-drop reaper. Same shape as
/// `GSourceFunc` above but the body returns a constant 1 instead of
/// re-arming bookkeeping.
const G_SOURCE_CONTINUE: c_int = 1;
extern "c" fn g_timeout_add(interval_ms: c_uint, function: GSourceFunc, user_data: ?*anyopaque) c_uint;

/// Cadence for the periodic reaper, in milliseconds. 30 minutes is
/// short enough that a long-running session keeps /tmp tidy, long
/// enough that the cost (one /tmp scan) stays negligible. The age
/// threshold inside the reaper is still 1h — the periodic schedule
/// just bounds how long a stale temp lingers past that threshold.
const dragdrop_reap_interval_ms: c_uint = 1_800_000;

/// `g_timeout_add` body for the periodic reaper. Mirrors the
/// startup call's behavior — best-effort, never surfaces errors.
/// Returns `G_SOURCE_CONTINUE` so the source stays armed across
/// the session.
fn reapDragDropTempsTick(_: ?*anyopaque) callconv(.c) c_int {
    reapDragDropTemps();
    return G_SOURCE_CONTINUE;
}

/// Scan /tmp for `djinn-drop-*.png` files older than 1h and remove
/// them. Called at startup AND every `dragdrop_reap_interval_ms`
/// thereafter so a long-running session doesn't accumulate temps
/// indefinitely — the image-drop path in `dragdrop.zig` writes here
/// with random-suffix filenames and never cleans up its own trail
/// (pasting the path means a downstream consumer may still be
/// reading the file). Mirrors `reapDragDropTemps` in main.zig:309.
/// Failures are silent; a stale temp is annoying, not breaking.
fn reapDragDropTemps() void {
    var dir = std.fs.openDirAbsolute("/tmp", .{ .iterate = true }) catch return;
    defer dir.close();
    const now = std.time.timestamp();
    const max_age_s: i64 = 3600;
    var it = dir.iterate();
    // Skip past iteration errors instead of returning — `dir.iterate`'s
    // `next` can fail per-entry on a transient permission or stat
    // race in /tmp (other users' files), and the previous shape
    // abandoned the rest of the directory at the first such hiccup
    // and left valid djinn-drop temps unreaped. Hard failures
    // (closed fd, OOM in the iterator) keep recurring on the next
    // tick — best-effort, log nothing because /tmp noise from other
    // users isn't actionable.
    while (true) {
        const maybe_entry = it.next() catch continue;
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "djinn-drop-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
        const stat = dir.statFile(entry.name) catch continue;
        const mtime_s = @divTrunc(stat.mtime, std.time.ns_per_s);
        if (now - mtime_s < max_age_s) continue;
        dir.deleteFile(entry.name) catch continue;
    }
}

/// IPC dispatch glue. Lives at file scope (not inside `main`) so the
/// stable address survives Ipc's registration — the GLib watch holds
/// the handler.ctx pointer for the lifetime of the source.
///
/// Extras beyond the panel pointer (allocator, terminal widget,
/// mutable config + ghostty colors) exist for `onConfigChanged`:
/// re-loading config and re-applying theme needs all of them. They
/// stay on the dispatch even when IPC-only handlers don't touch
/// them so the live-apply path has a single rendezvous point.
const Dispatch = struct {
    allocator: std.mem.Allocator,
    panel: *platform.Panel,
    config: *Config,
    ghostty_colors: *?platform.GhosttyColors,
    /// Late-stamped subsystems. Default to null because Dispatch's
    /// address is taken before these exist — SessionHost, LogPane,
    /// Hotkey, McpServer, ToolTable, and Notifier each receive
    /// `&g_dispatch` as a callback ctx during their own construction,
    /// so the struct lives at a stable address before any of them
    /// could be folded in as values. Each handler that reads a
    /// late-stamped field null-checks first; a callback firing
    /// mid-init bails cleanly instead of dereferencing `undefined`.
    /// `onConfigChanged` is the only handler that touches more than
    /// `panel`/`allocator`, so the unwraps cluster at its head.
    session_host: ?*platform.SessionHost = null,
    session_manager: ?*SessionManager = null,
    /// Tab strip late-stamp. Watcher's `onConfigChanged` calls
    /// `applyTheme` here alongside session_host + log_pane so the
    /// chip row's CSS stays in lockstep with the VTE / log paint.
    /// Null until `runWithIpc` constructs the strip; the unwrap in
    /// `onConfigChanged` bails cleanly if a config save races init.
    tab_strip: ?*platform.TabStrip = null,
    /// Profile palette (Ctrl+Shift+P) late-stamp. Same `applyTheme`
    /// fan-out story as `tab_strip`. The palette popover's chrome
    /// (background mirrors the VTE bg) needs to track theme reloads
    /// even when the popover is hidden, so the next open paints
    /// with the current colors instead of stale ones.
    palette: ?*platform.Palette = null,
    hotkey: ?*?platform.Hotkey = null,
    mcp_server: ?*?McpServer = null,
    mcp_handler: ?McpServer.Handler = null,
    log_pane: ?*platform.LogPane = null,
    /// ToolTable + Notifier slots — `onConfigChanged` refreshes
    /// their cached attention_sound / rate-limit / per-state gate
    /// fields BEFORE the old Config arena is deinited so the MCP
    /// worker thread's reads through `tool_table.attention_sound`
    /// don't dangle. Mirrors the eager-refresh pattern darwin uses.
    tool_table: ?*ToolTable = null,
    notifier: ?*platform.Notifier = null,

    /// Read the persisted size for the profile at `idx` and resize the
    /// panel to match. Mirrors darwin's `applyProfileWindowSize` in
    /// `src/ghostty/surface_lifecycle.zig`. Config-pinned dims
    /// short-circuit so a user who wrote `window-width = N` keeps the
    /// same N across all profiles; state.json holds *implicit* sizes
    /// from the user dragging the panel edge, only relevant when the
    /// config doesn't pin a global size.
    ///
    /// `profileSize` falls through to the top-level dims when no
    /// per-profile entry exists — matches darwin's behavior. A profile
    /// that's never been resized while active inherits whatever the
    /// last globally-saved size was; once the user resizes while it's
    /// active, `onPanelResize` writes an entry under the profile name
    /// (the producer side was already wired) and subsequent switches
    /// land on its own dims.
    fn applyProfileWindowSize(self: *Dispatch, idx: usize) void {
        if (self.config.window.width != null and self.config.window.height != null) return;
        const sm = self.session_manager orelse return;
        if (idx >= sm.sessions.items.len) return;
        const profile_name = sm.sessions.items[idx].profile.name;

        var maybe_state = persist.load(self.allocator);
        defer if (maybe_state) |*st| st.deinit(self.allocator);
        const st = maybe_state orelse return;
        const dims = st.profileSize(profile_name) orelse return;

        self.panel.setSize(@intCast(dims.w), @intCast(dims.h));
    }

    fn onCommand(ctx: *anyopaque, command: platform.IpcCommand) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        switch (command) {
            .toggle => self.panel.toggle(),
            .show => self.panel.show(),
            .hide => self.panel.hide(),
            .quit => self.panel.quit(),
        }
    }

    fn onHotkey(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        self.panel.toggle();
    }

    fn onTrayActivate(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        self.panel.toggle();
    }

    fn onTrayQuit(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        self.panel.quit();
    }

    /// VTE `bell`: the PTY emitted BEL (0x07). Audible bell is
    /// already handled inside VTE itself via the per-VTE
    /// `set_audible_bell` flag we stamped at spawn from
    /// `profile.bell_audible orelse cfg.bell.audible`, so this
    /// callback only drives the visual side. `idx` is the firing
    /// session; the firing profile's `bell_visual` override wins
    /// over the global default, letting a chatter profile keep
    /// its visual bell quiet while interactive profiles still
    /// flash.
    fn onBell(ctx: *anyopaque, idx: usize) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        const sm = self.session_manager orelse return;
        if (idx >= sm.sessions.items.len) return;
        const profile = &sm.sessions.items[idx].profile;
        const visual = profile.bell_visual orelse self.config.bell.visual;
        if (visual) self.panel.flashBell();
    }

    /// VTE `child-exited`: the spawned shell terminated (typed
    /// `exit`, was killed, etc.). `idx` carries the session index
    /// (SessionHost stamps it into Terminal.Handler.extra at spawn
    /// time). Flips `entry.exited`, which fans through
    /// `on_exit_changed` into `tab_strip.markExited` so the dead
    /// session's chip dims + gains a strikethrough. Also feeds a
    /// dim inline banner into the VTE so single-profile setups (tab
    /// strip hidden) still get a visible cue. User revives the
    /// session via Ctrl+R (`restart_session`); `restartActive`
    /// clears the bit through the same hook.
    ///
    /// Mirrors darwin's `handleChildExited`: the panel never quits
    /// on child exit. The window close-request path remains the
    /// canonical way to terminate djinn.
    fn onChildExited(ctx: *anyopaque, idx: usize) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        const host = self.session_host orelse return;
        if (host.terminalAt(idx)) |term| {
            const banner = "\r\n\x1b[2m[djinn] Process exited. Press Ctrl+R to restart, Ctrl+Shift+R for a fresh shell.\x1b[0m\r\n";
            term.feedScreen(banner);
        }
        host.markExited(idx, true);
    }

    /// SessionHost.on_exit_changed hook. Re-skins the chip for `idx`
    /// when its exited bit flips — true on inactive child-exited,
    /// false on a successful restartActive. tab_strip is the only
    /// observer today; future agent-state visualizations on the chip
    /// would fan from the same callback.
    fn onSessionExitChanged(ctx: *anyopaque, idx: usize, exited: bool) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (self.tab_strip) |strip| strip.markExited(idx, exited);
    }

    /// Panel size changed (user dragged the window edge, or the
    /// initial GTK measure pass settled with non-default dims).
    /// Persists via `saveDebounced` so a continuous drag emits a
    /// single disk write 300ms after the user stops. `profile_name`
    /// goes into `state.json`'s `profiles[<name>].{width,height}`
    /// slot so the next activate of this profile (or the next launch
    /// while it's active) restores its specific dims via
    /// `applyProfileWindowSize`.
    fn onPanelResize(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        const profile_name: ?[]const u8 = if (self.session_manager) |sm|
            sm.active().profile.name
        else
            null;
        persist.saveDebounced(self.allocator, w, h, profile_name);
    }

    /// Log-pane GtkPaned divider drag. Fires at ~60Hz during a user
    /// gesture; the 300ms persist worker cycle flattens the burst to
    /// one disk write per release. Position is the start-child width
    /// in pixels (VTE side of the split). Negative values aren't
    /// reachable from a drag but the cast guards against them anyway.
    fn onDividerChanged(ctx: *anyopaque, position: i32) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        if (position <= 0) return;
        persist.saveDividerDebounced(self.allocator, @intCast(position));
    }

    /// SIGTERM via `g_unix_signal_add`. Matches the existing SIGINT
    /// path (GLib's signal-fd watch) so `systemctl --user stop djinn`
    /// or a packager-supplied unit's StopOnExit doesn't have to
    /// SIGKILL to get a clean shutdown. Signature matches GSourceFunc;
    /// returning 1 keeps the source registered, but the loop is about
    /// to exit anyway so it's a wash.
    fn onSigterm(user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Dispatch = @ptrCast(@alignCast(user_data orelse return 1));
        self.panel.quit();
        return 1;
    }

    /// Config-file change handler. Fires on the GLib main thread when
    /// `~/.config/djinn/config` or `~/.config/ghostty/config` is
    /// rewritten. Re-loads djinn config (with retry to ride out the
    /// atomic-rename ENOENT gap that vim / Helix / VS Code produce on
    /// save), refreshes ghostty inheritance when enabled, re-applies
    /// theme + window size + hide-on-blur + topmost + hotkey binding
    /// + MCP server + autostart entry in place. `warnUnliveable` is
    /// the canonical list of what still requires a restart; if a
    /// field's not listed there and not handled here, it's a bug.
    fn onConfigChanged(ctx: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));

        // Readiness gate. Every late-stamped subsystem must be
        // wired before the reload can proceed. Today the watcher
        // is constructed after all of them, so this never short-
        // circuits at startup — the check protects against future
        // reorders or a new earlier-firing callback dragging the
        // watcher ahead of one of these slots.
        const session_host = self.session_host orelse return logDispatchUnready("session_host");
        const log_pane = self.log_pane orelse return logDispatchUnready("log_pane");
        const hotkey_slot = self.hotkey orelse return logDispatchUnready("hotkey");
        const mcp_server_slot = self.mcp_server orelse return logDispatchUnready("mcp_server");
        const mcp_handler = self.mcp_handler orelse return logDispatchUnready("mcp_handler");
        const tool_table = self.tool_table orelse return logDispatchUnready("tool_table");
        const notifier = self.notifier orelse return logDispatchUnready("notifier");

        const new_config = loadConfigWithRetry(self.allocator) orelse {
            std.debug.print("config: reload failed after retries — keeping previous config\n", .{});
            return;
        };

        // Shallow value-copy preserves the old arena pointer so we
        // can defer its deinit until after the swap. All comparisons
        // below read from `old`; the strings they touch remain live
        // until `old.deinit()` runs at the end.
        var old = self.config.*;

        // Ghostty colors: re-parse on every reload when inheritance
        // is on. Cheaper than tracking which file changed (the
        // watcher doesn't tell us) and the parse is fast — file
        // I/O bound, < 1ms in practice.
        const new_ghostty: ?platform.GhosttyColors = if (new_config.theme.inherit_ghostty)
            platform.ghostty_config.loadFromUserConfig(self.allocator) catch |err| blk: {
                std.debug.print("config: ghostty reload failed: {} — VTE defaults for inherited fields\n", .{err});
                break :blk null;
            }
        else
            null;

        // Apply theme: cheap and idempotent. font, fg/bg/cursor,
        // padding, palette, opacity all flow through VTE setters /
        // the reloaded CSS provider. Same code path used at startup.
        // `applyTheme` fans across every spawned VTE inside the
        // SessionHost; lazy-spawn slots pick the new theme up on
        // first activate via the cached `theme_opts`.
        const opts = buildThemeOptions(&new_config, new_ghostty);
        session_host.applyTheme(opts);
        log_pane.applyTheme(opts);
        if (self.tab_strip) |ts| ts.applyTheme(opts);
        if (self.palette) |pal| pal.applyTheme(opts);

        // Window size: layer-shell may clip, but on non-layer-shell
        // (GNOME) the resize takes effect immediately. Only fire the
        // setter when the resolved size actually changed so we don't
        // re-request the same dimensions every save.
        const old_w: u32 = old.window.width orelse 800;
        const old_h: u32 = old.window.height orelse 400;
        const new_w: u32 = new_config.window.width orelse 800;
        const new_h: u32 = new_config.window.height orelse 400;
        if (old_w != new_w or old_h != new_h) {
            self.panel.setSize(@intCast(new_w), @intCast(new_h));
        }

        if (old.window.hide_on_blur != new_config.window.hide_on_blur) {
            self.panel.setHideOnBlur(new_config.window.hide_on_blur);
        }

        if (old.window.topmost != new_config.window.topmost) {
            self.panel.setTopmost(new_config.window.topmost);
        }

        // Hotkey rebind. Init-new-before-deinit-old so a malformed
        // trigger leaves the working binding in place — same logic
        // as startup ("portal init failed → IPC bridge still
        // active"). KDE re-prompts for approval on each rebind; no
        // way to suppress short of caching the portal session, and
        // the user changing their hotkey is intentional anyway.
        if (!strOptEql(old.hotkey.toggle, new_config.hotkey.toggle)) {
            if (platform.Hotkey.init(
                self.allocator,
                .{ .ctx = @ptrCast(&g_dispatch), .on_activated = Dispatch.onHotkey },
                new_config.hotkey.toggle,
            )) |new_hotkey| {
                if (hotkey_slot.*) |*old_hotkey| old_hotkey.deinit();
                hotkey_slot.* = new_hotkey;
                std.debug.print(
                    "config: hotkey rebound to \"{s}\"\n",
                    .{new_config.hotkey.toggle},
                );
            } else |_| {
                // hotkey.zig already printed the aggregate
                // "portal unavailable — <reason>" line. Note that
                // the previous binding survives because we only
                // deinit the old slot on the success branch above.
                std.debug.print(
                    "config: previous hotkey binding still active\n",
                    .{},
                );
            }
        }

        // MCP server toggle. Start/stop the listener thread; the
        // endpoint-info file under $XDG_RUNTIME_DIR gets rewritten
        // on each start so a fresh port lands for any agent that
        // reads it. Stale-after-stop is best-effort — the file stays
        // pointing at the dead port until the next start. Agents
        // generally re-read on connect failure, and the alternative
        // (unlinking on stop) races with concurrent reads.
        if (old.mcp.enabled != new_config.mcp.enabled) {
            if (new_config.mcp.enabled) {
                startMcpServer(self.allocator, mcp_handler, mcp_server_slot);
            } else {
                stopMcpServer(mcp_server_slot);
            }
        }

        // Autostart: same idempotent register/unregister pair the
        // startup path uses. Failures logged but non-fatal.
        if (old.system.open_at_login != new_config.system.open_at_login) {
            if (new_config.system.open_at_login) {
                platform.AutoStart.register(self.allocator) catch |err| {
                    std.debug.print("config: autostart register failed: {}\n", .{err});
                };
            } else {
                platform.AutoStart.unregister(self.allocator) catch |err| {
                    std.debug.print("config: autostart unregister failed: {}\n", .{err});
                };
            }
        }

        // Log pane visibility. Divider position was set at startup
        // to the configured width regardless of enabled, so showing
        // a previously-hidden pane reveals it at the right size
        // without needing to re-set position here.
        if (old.log_pane.enabled != new_config.log_pane.enabled) {
            log_pane.setVisible(new_config.log_pane.enabled);
        }

        warnUnliveable(&old, &new_config);

        // Refresh ToolTable + Notifier caches to the new strings
        // BEFORE the swap+deinit so the MCP worker thread's reads
        // through `tool_table.attention_sound` don't dangle when the
        // old arena drops. Booleans + ints are stale-data-but-safe
        // either way; included here so a single touch keeps every
        // cached field in lockstep with the live config.
        tool_table.attention_sound = new_config.notifications.attention_sound;
        tool_table.notify_on_attention = new_config.notifications.notify_on_attention;
        tool_table.notify_on_error = new_config.notifications.notify_on_error;
        tool_table.notify_on_done = new_config.notifications.notify_on_done;
        tool_table.notify_on_progress = new_config.notifications.notify_on_progress;
        notifier.enabled = new_config.notifications.system_notifications;
        notifier.rate_limit_ms = new_config.notifications.rate_limit_ms;

        // Commit. Swap ghostty colors + config, THEN release the old
        // Config's arena — the MCP worker thread reaches `clientMuted`
        // through `tool_table.config.*`, so freeing the old arena
        // before the swap would race that read into freed memory. The
        // window between swap and `old.deinit()` is the same torn-read
        // window darwin already accepts on its own reload path.
        if (self.ghostty_colors.*) |*c| c.deinit(self.allocator);
        self.ghostty_colors.* = new_ghostty;
        self.config.* = new_config;
        old.deinit();

        std.debug.print("config: reloaded — theme + size applied live\n", .{});
    }
};
var g_dispatch: Dispatch = undefined;

/// Log a skipped config reload because a late-stamped dispatch field
/// is still null. Today's startup order ensures the watcher is the
/// last subsystem constructed, so this banner never prints under
/// normal operation — it surfaces only if a future reorder lets the
/// watcher fire before another subsystem is wired in.
fn logDispatchUnready(field: []const u8) void {
    std.debug.print(
        "config: reload skipped — dispatch field '{s}' not yet wired\n",
        .{field},
    );
}

/// Tab-strip click handler. The chip carries a session index in its
/// user_data; this callback routes that through `SessionHost.activate`
/// which handles bounds-checking, focus-grab, and the on_switch
/// fan-out back to the strip. Returns whatever `activate` returns so
/// the strip's hook signature stays useful for future palette wiring.
fn onTabActivate(ctx: *anyopaque, idx: usize) bool {
    const host: *platform.SessionHost = @ptrCast(@alignCast(ctx));
    return host.activate(idx);
}

/// SessionHost.on_switch hook fired after every successful activate.
/// Two responsibilities folded into one callback so the activate path
/// has a single fan-out site:
///
///   1. Update the tab strip's active-row CSS class.
///   2. Restore the per-profile persisted window size, when one is
///      saved in state.json AND the user hasn't pinned a global size
///      via config (config always wins so editing the file takes
///      effect immediately).
///
/// Keymap-driven switches (Ctrl+Tab / Alt+N / Ctrl+Shift+P) all reach
/// `host.activate` so they share this code path.
fn onSessionSwitched(ctx: *anyopaque, idx: usize) void {
    const self: *Dispatch = @ptrCast(@alignCast(ctx));
    if (self.tab_strip) |strip| strip.markActive(idx);
    self.applyProfileWindowSize(idx);
}

/// Try `Config.load` a handful of times with a short sleep between
/// attempts. Atomic-rename editors (vim, VS Code, Helix) write a
/// temp file then rename it over the target on save; the watcher
/// can fire in the gap between the unlink of the old file and the
/// rename landing the new one, and an immediate open hits ENOENT.
/// Three attempts at 20ms cover practical editor latencies; if all
/// three fail the caller keeps the previous config in place.
fn loadConfigWithRetry(allocator: std.mem.Allocator) ?Config {
    var attempt: u8 = 0;
    var first_err: ?anyerror = null;
    while (attempt < 3) : (attempt += 1) {
        if (attempt > 0) std.Thread.sleep(20 * std.time.ns_per_ms);
        if (Config.load(allocator)) |cfg| return cfg else |err| {
            if (first_err == null) first_err = err;
        }
    }
    // EACCES, malformed UTF-8, parse errors all looked identical
    // to a transient atomic-rename ENOENT under the prior shape, so
    // the retries burned silently on a permanent failure. Log the
    // first error before giving up — the user staring at the
    // generic "reload failed after retries" line then has a clue
    // whether it's worth investigating.
    if (first_err) |e| std.debug.print("config: load failed: {}\n", .{e});
    return null;
}

/// Log a one-line warning for each field that changed but doesn't
/// have a linux live-apply path yet. The user sees exactly which
/// edits will need a restart to take effect — and which got applied
/// silently. Kept as a single function so adding a new field is a
/// one-line edit instead of scattering checks across the handler.
///
/// Currently empty: `hotkey.toggle`, `mcp.enabled`, and
/// `system.open_at_login` all moved into `onConfigChanged` as live
/// applies. Left in place so the next cold-path field that lands
/// has an obvious home.
fn warnUnliveable(old: *const Config, new: *const Config) void {
    _ = old;
    _ = new;
}

/// Start the MCP server in `slot` and spawn its accept thread.
/// Caller has verified `slot.* == null` is the intent (cold start
/// or post-`stopMcpServer`); does nothing if the server is already
/// running — re-entering with the same handler would just rebind
/// a fresh port and orphan the old one. Failures are logged and
/// the slot stays null so the next config reload can retry.
fn startMcpServer(
    allocator: std.mem.Allocator,
    handler: McpServer.Handler,
    slot: *?McpServer,
) void {
    if (slot.* != null) return;
    const server = McpServer.init(allocator, handler) catch |err| {
        std.debug.print(
            "mcp server init failed: {} — agent tools disabled until next retry\n",
            .{err},
        );
        return;
    };
    writeMcpEndpointInfo(allocator, server.port, server.token) catch |err| {
        std.debug.print("mcp endpoint info write failed: {}\n", .{err});
    };
    // Move `server` into the slot first so the thread's `*McpServer`
    // argument points at its permanent home rather than this stack
    // frame. Spawn-fail path then deinits via the slot.
    slot.* = server;
    const slot_ptr = &slot.*.?;
    slot_ptr.thread = std.Thread.spawn(.{}, McpServer.run, .{slot_ptr}) catch |err| {
        std.debug.print("mcp thread spawn failed: {} — tearing down listener\n", .{err});
        slot_ptr.deinit();
        slot.* = null;
        return;
    };
    std.debug.print(
        "mcp server listening on 127.0.0.1:{d}\n",
        .{slot_ptr.port},
    );
}

/// Stop the MCP server in `slot` and wait for its accept thread.
/// `McpServer.deinit` joins the thread (it was registered onto
/// `server.thread` by `startMcpServer`) which closes the
/// use-after-free window on the bearer token.
fn stopMcpServer(slot: *?McpServer) void {
    if (slot.*) |*s| {
        s.deinit();
        slot.* = null;
        std.debug.print("mcp server stopped\n", .{});
    }
}

fn strOptEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// One field of `Colors` (background / foreground / cursor) selected
/// by the caller via the field enum. Splitting it out keeps the
/// `theme_opts` builder readable — three near-identical merge
/// expressions inline would obscure the data flow.
const ColorField = enum { background, foreground, cursor };

/// Resolve a single theme color: djinn config (hex string) wins;
/// ghostty config (already-parsed Rgb) is the fallback when djinn
/// didn't set the field. Returns null when neither source has a
/// value, leaving VTE on its built-in default.
fn mergeColor(
    djinn_hex: ?[]const u8,
    ghostty_opt: ?platform.GhosttyColors,
    field: ColorField,
) ?platform.ghostty_config.Rgb {
    if (djinn_hex) |s| {
        if (platform.ghostty_config.parseColor(s)) |c| return c;
    }
    const gc = ghostty_opt orelse return null;
    return switch (field) {
        .background => gc.background,
        .foreground => gc.foreground,
        .cursor => gc.cursor,
    };
}

/// Compose theme.Options from djinn config + optional ghostty
/// inheritance. djinn config wins on every field; ghostty fills the
/// gaps; palette is ghostty-only because djinn config doesn't expose
/// palette entries. Shared by startup and the watcher reload path so
/// the merge rules can't drift between them.
fn buildThemeOptions(
    config: *const Config,
    ghostty_opt: ?platform.GhosttyColors,
) platform.ThemeOptions {
    return .{
        .font_family = config.terminal.font_family orelse
            if (ghostty_opt) |gc| gc.font_family else null,
        .font_size = config.terminal.font_size orelse
            if (ghostty_opt) |gc| gc.font_size else null,
        .background = mergeColor(config.theme.background, ghostty_opt, .background),
        .foreground = mergeColor(config.theme.foreground, ghostty_opt, .foreground),
        .cursor = mergeColor(config.theme.cursor, ghostty_opt, .cursor),
        .padding_x = config.terminal.padding_x,
        .padding_y = config.terminal.padding_y,
        // theme.opacity is the modern key; window.opacity is the legacy
        // one (defaulted to 0.95). Honor the modern key when explicitly
        // set; otherwise fall back to the legacy default so users with
        // either form get the same result.
        .opacity = config.theme.opacity orelse config.window.opacity,
        .palette = if (ghostty_opt) |gc| gc.palette else .{null} ** 16,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // Join the persist debounce worker before the allocator drops so
    // a mid-sleep writer doesn't dereference freed gpa state.
    // Defers fire LIFO — this runs before `gpa.deinit` above.
    defer persist.joinPendingSave();
    const allocator = gpa.allocator();

    // CLI argv parsing first, before the startup banner — so
    // `djinn --version` and `djinn --help` print their output and
    // exit cleanly without the "djinn linux — port WIP (...)" line
    // muddying stdout. Same shape as main.zig (darwin) at the
    // equivalent entry. `--hotkey` / `--provider` overrides are
    // parsed but not yet applied on linux; wiring them into the
    // config-merge path is a follow-up.
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var parsed_args = cli.Args{};
    switch (cli.parse(&args, &parsed_args)) {
        .run => {},
        .exit_ok => return,
        .exit_err => std.process.exit(1),
    }

    // `std.debug.print` matches the rest of the codebase — main.zig
    // (darwin) does all its host-side reporting via this path too. Goes
    // to stderr, fine for a startup banner with no piped consumer.
    std.debug.print(
        "djinn linux — port WIP (zig {s}, target {s}-{s})\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
        },
    );

    // Config owns its duped strings via an internal arena (see
    // `config.zig::Config.deinit`). Lives in a `var` because the
    // watcher reload path swaps the whole struct through
    // `Dispatch.config`. `defer config.deinit()` releases whichever
    // arena is in place when main exits — the original one if no
    // reload fired, or the most recently swapped-in one otherwise.
    var config: Config = Config.loadOrDefault(allocator) catch |err| {
        std.debug.print("config load failed: {}\n", .{err});
        return err;
    };
    defer config.deinit();

    // CLI overrides land before the banner so logged values reflect
    // what's actually active. Override strings live inside the
    // ArgIterator's heap allocations; the arena does NOT own them, so
    // `Config.deinit` leaves them alone. The original parse-duped
    // value that the override displaces stays inside the arena (now
    // unreferenced) and is freed by the same arena-drop sweep.
    // `defer args.deinit()` runs AFTER `defer config.deinit()` (defers
    // fire in reverse registration order), so the override storage
    // outlives every Config read by construction.
    if (parsed_args.keybinding_override) |s| config.hotkey.toggle = s;
    if (parsed_args.provider_override) |s| config.provider.name = s;

    std.debug.print(
        "config OK — provider={s} hotkey={s} mcp_enabled={} log_pane={}\n",
        .{
            config.provider.name,
            config.hotkey.toggle,
            config.mcp.enabled,
            config.log_pane.enabled,
        },
    );
    std.debug.print(
        "window — width={?} height={?} pos={s} hide_on_blur={} topmost={}\n",
        .{
            config.window.width,
            config.window.height,
            @tagName(config.window.position),
            config.window.hide_on_blur,
            config.window.topmost,
        },
    );

    // Probe the runtime libraries the GTK4 host shell will need. This
    // is the first call into the new platform abstraction (src/platform/)
    // and it has a concrete user-facing effect today: we can already
    // tell whether the compositor will give us Quake-drop semantics or
    // whether we'll have to fall back to a plain toplevel window.
    var probe_arena = std.heap.ArenaAllocator.init(allocator);
    defer probe_arena.deinit();
    const caps = platform.Panel.detect(probe_arena.allocator()) catch |err| {
        std.debug.print("host probe failed: {}\n", .{err});
        return err;
    };

    std.debug.print(
        "host probe — wayland={} gtk4={} layer_shell={} desktop=\"{s}\"\n",
        .{ caps.wayland, caps.gtk4, caps.layer_shell, caps.desktop },
    );
    if (caps.quakeDropAvailable()) {
        std.debug.print("→ Quake-drop available (gtk4-layer-shell on Wayland).\n", .{});
    } else if (!caps.wayland) {
        std.debug.print("→ no Wayland session ($WAYLAND_DISPLAY unset); X11 not supported.\n", .{});
    } else if (!caps.gtk4) {
        std.debug.print("→ libgtk-4.so.1 not resolvable; install gtk4 to continue.\n", .{});
    } else {
        std.debug.print(
            "→ no gtk4-layer-shell on this compositor (likely GNOME); will fall back to plain toplevel.\n",
            .{},
        );
    }

    if (!caps.gtk4) {
        std.debug.print("\nrefusing to open panel — libgtk-4 not resolvable.\n", .{});
        return error.MissingGtk;
    }

    // Sweep stale image-drop temp files from a previous session
    // before the user can produce new ones. Best-effort; permission
    // errors on /tmp just leave the entries lying around. See the
    // reaper function for the naming + age cutoff. The recurring
    // `g_timeout_add` below keeps /tmp tidy across long-running
    // sessions — a 9-hour workday with 100 image drops would
    // otherwise let those temps accumulate until djinn restarts.
    reapDragDropTemps();
    _ = g_timeout_add(dragdrop_reap_interval_ms, reapDragDropTempsTick, null);

    // Open the borderless panel. Layer-shell anchors it to the top of
    // the screen when available; otherwise it's a plain undecorated
    // toplevel the user moves manually (GNOME path).
    //
    // Width/height priority (matches darwin's `restoreWindowSize`):
    //   explicit config → persisted `state.json` → 800/400 default.
    // Explicit config wins so a user edit to `window-width = 2000`
    // takes effect immediately even if the persisted size is older;
    // persisted dims rescue a user who has resized via drag (only
    // possible on the plain-toplevel path) but hasn't touched config.
    //
    // No clamping to screen bounds yet — gtk4-layer-shell handles
    // overflow by clipping at anchor edges, and the plain-toplevel
    // path on GNOME is rare enough that the screen-fit pass darwin
    // does (`NSScreen.visibleFrame`) isn't worth the GdkMonitor /
    // GdkDisplay round-trip here.
    var persisted_state = persist.load(allocator);
    defer if (persisted_state) |*st| st.deinit(allocator);
    const persisted_size: ?struct { w: u32, h: u32 } = blk: {
        const st = persisted_state orelse break :blk null;
        if (st.width != 0 and st.height != 0) break :blk .{ .w = st.width, .h = st.height };
        break :blk null;
    };

    const width: c_int = @intCast(config.window.width orelse
        if (persisted_size) |p| p.w else @as(u32, 800));
    const height: c_int = @intCast(config.window.height orelse
        if (persisted_size) |p| p.h else @as(u32, 400));

    var panel = platform.Panel.open(.{
        .width = width,
        .height = height,
        .title = "djinn",
    }) catch |err| {
        std.debug.print("panel open failed: {}\n", .{err});
        return err;
    };
    defer panel.deinit();

    // Embed a VTE terminal as the panel's child. VTE owns the PTY,
    // VT parsing, font rendering, IME, selection, scrollback,
    // hyperlink hover. Spawn the user's shell as the terminal's
    // child process; `Dispatch.onChildExited` (wired below) closes
    // the panel when the shell exits.
    //
    // Theme assembly: djinn config wins on every field. When
    // `inherit_ghostty` is set, gaps fall back to the user's ghostty
    // config (colors, palette, font). Palette is ghostty-only —
    // djinn doesn't expose palette entries in its own config.
    var ghostty_colors_opt: ?platform.GhosttyColors = if (config.theme.inherit_ghostty)
        platform.ghostty_config.loadFromUserConfig(allocator) catch |err| blk: {
            std.debug.print("ghostty config: load failed: {} — VTE defaults\n", .{err});
            break :blk null;
        }
    else
        null;
    defer if (ghostty_colors_opt) |*c| c.deinit(allocator);

    const theme_opts = buildThemeOptions(&config, ghostty_colors_opt);
    // g_dispatch needs a stable address before Terminal.open's signal
    // connect — initialize it here so child-exited / watcher / hotkey
    // / tray callbacks all share one rendezvous. The late-stamped
    // fields (terminal / log_pane / hotkey / mcp_* / tool_table /
    // notifier) default to null inside the struct definition; each
    // gets a non-null pointer right after its backing storage is
    // built. `onConfigChanged` null-checks them so a future reorder
    // that fires the watcher mid-init bails cleanly instead of
    // dereferencing undefined memory.
    g_dispatch = .{
        .allocator = allocator,
        .panel = &panel,
        .config = &config,
        .ghostty_colors = &ghostty_colors_opt,
    };

    // Persist window dims on resize. Safe to wire here (g_dispatch's
    // address is stable from this point on). The callback fires on
    // the GLib main thread; saveDebounced spawns a worker thread for
    // the actual disk write so it's non-blocking. No-op on layer-
    // shell where the compositor pins the size, useful on plain
    // toplevel (GNOME / DJINN_NO_LAYER_SHELL=1).
    panel.setOnResize(@ptrCast(&g_dispatch), Dispatch.onPanelResize);

    // SessionManager resolves config's `profile.*` entries into a list
    // of spawn-ready Profiles. With no profile lines, it synthesizes a
    // single "default" profile from the flat `provider` / `provider-
    // command` keys — legacy single-shell configs keep working. The
    // manager survives until shutdown; SessionHost reaches into it
    // for the active index + per-profile spawn payload.
    var session_manager = SessionManager.init(allocator, &config) catch |err| {
        std.debug.print("session manager init failed: {}\n", .{err});
        return err;
    };
    defer session_manager.deinit();
    g_dispatch.session_manager = &session_manager;

    // Snap the panel to the active-at-startup profile's persisted
    // dims. The earlier `panel.open` only knew the global state.json
    // slot since SessionManager didn't exist yet; now that the active
    // profile name is resolvable, apply its specific entry if any.
    // Subsequent profile switches go through the `on_switch` hook
    // (see `onSessionSwitched`).
    g_dispatch.applyProfileWindowSize(session_manager.active_idx);

    std.debug.print(
        "sessions — {d} profile(s), active='{s}'\n",
        .{ session_manager.count(), session_manager.active().profile.name },
    );

    // SessionHost owns one VTE per profile, hosted in a GtkStack. The
    // active-at-startup session is spawned eagerly so the first paint
    // shows that profile's shell; the rest are lazy until first
    // activate. `Dispatch.onChildExited` closes the panel when any
    // session's shell exits — matches today's single-shell semantics.
    var host = platform.SessionHost.init(allocator, &session_manager, theme_opts, .{
        .ctx = @ptrCast(&g_dispatch),
        .on_child_exited = Dispatch.onChildExited,
        .on_bell = Dispatch.onBell,
    }, config.bell.audible) catch |err| {
        std.debug.print("session host init failed: {}\n", .{err});
        return err;
    };
    defer host.deinit();
    g_dispatch.session_host = &host;

    // Log pane lives to the right of the VTE inside a horizontal
    // GtkPaned. Wrapped + attached even when `log_pane.enabled = false`
    // so the future Ctrl+/ toggle is a frame flip rather than a widget
    // rebuild — same shape darwin uses (`log_view` always exists; its
    // frame goes to zero width when hidden).
    var log_pane = platform.LogPane.init(allocator) catch |err| {
        std.debug.print("log pane init failed: {}\n", .{err});
        return err;
    };
    defer log_pane.deinit();
    log_pane.applyTheme(theme_opts);
    log_pane.setVisible(config.log_pane.enabled);
    g_dispatch.log_pane = &log_pane;

    // Divider position = VTE width = panel width minus log width.
    // Log width comes from the configured fraction clamped to
    // [width_min, width_max] — same math darwin's view.zig does.
    // Set unconditionally (not gated on enabled) so that toggling
    // the pane on at runtime via Ctrl+/ reveals it at the configured
    // width — GtkPaned preserves the position across visibility
    // flips, so we only need to set it once at construction.
    //
    // Priority: persisted state.divider (last user drag) →
    // config-derived fraction → default. The persisted value wins so
    // a user who has manually tuned the divider doesn't lose it on
    // restart, matching how `state.width/height` shadow the config
    // default for window dims.
    const divider_position: c_int = blk: {
        if (persisted_state) |st| {
            if (st.divider != 0) break :blk @intCast(st.divider);
        }
        const log_width: f64 = inner_blk: {
            const desired = @as(f64, @floatFromInt(width)) * config.log_pane.width_fraction;
            const clamped = std.math.clamp(
                desired,
                config.log_pane.width_min,
                config.log_pane.width_max,
            );
            break :inner_blk clamped;
        };
        break :blk width - @as(c_int, @intFromFloat(log_width));
    };

    // Pair the SessionHost's GtkStack (the multi-VTE container) with
    // the log pane inside a horizontal GtkPaned. Pre-multi-profile
    // this passed `term.widget` directly; the stack is a drop-in
    // replacement (any GtkWidget can sit as the start child).
    const paned = log_pane.pairWithSibling(host.widget(), divider_position);

    // Tab strip above the paned. Hidden when `sm.count() < 2`, so
    // single-profile setups look identical to pre-multi-profile.
    // `pairWithChild` wraps (strip, paned) into a vertical GtkBox so
    // the strip takes its natural height and the paned gets the
    // remainder. Mouse clicks reach `host.activate(idx)` via the
    // OnActivate callback; the reverse direction (re-skin the chip
    // when a keymap-driven switch lands) flows through SessionHost's
    // `on_switch` hook below.
    var tab_strip = platform.TabStrip.init(
        allocator,
        &session_manager,
        .{
            .ctx = @ptrCast(&host),
            .on_invoke = onTabActivate,
        },
        theme_opts,
    ) catch |err| {
        std.debug.print("tab strip init failed: {}\n", .{err});
        return err;
    };
    defer tab_strip.deinit();
    g_dispatch.tab_strip = &tab_strip;
    // The `on_switch` hook routes through Dispatch (not the tab strip
    // directly) so the same callback can fan to both the chip refresh
    // AND the per-profile window-size restore — both need to fire
    // after every successful activate. `&tab_strip` reachable via
    // `g_dispatch.tab_strip` inside the handler.
    host.on_switch = .{
        .ctx = @ptrCast(&g_dispatch),
        .on_invoke = onSessionSwitched,
    };
    // `on_exit_changed` fires when an entry's exited bit flips —
    // child-exit on an inactive session (true) or restartActive
    // success on a previously-exited session (false). Dispatch fans
    // the call to `tab_strip.markExited` so the chip dims + gains a
    // strikethrough (or reverts). Late-stamped so the watcher's
    // readiness gate doesn't fire before tab_strip is built.
    host.on_exit_changed = .{
        .ctx = @ptrCast(&g_dispatch),
        .on_invoke = Dispatch.onSessionExitChanged,
    };

    const root = tab_strip.pairWithChild(paned);
    panel.attachChild(root);

    // Persist divider drags through the same debounce worker that
    // handles window dims. `notify::position` fires at ~60Hz during a
    // drag; the worker's 300ms cycle flattens the burst to one disk
    // write per gesture. Independent dirty bit in persist.zig means
    // a divider-only save preserves window dims from disk and vice
    // versa.
    log_pane.setOnDividerChange(.{
        .ctx = @ptrCast(&g_dispatch),
        .on_change = Dispatch.onDividerChanged,
    });

    // Force initial keyboard focus onto the active VTE. Without this,
    // the surrounding GtkPaned can hold focus by default (its divider
    // is keyboard-navigable with arrow keys), which routes every key
    // event into the paned's handlers instead of VTE — including
    // VTE's own Ctrl+Shift+C/V and our window-level shortcuts via
    // GtkShortcutController(MANAGED scope), which dispatch off the
    // currently-focused widget's manager chain. GtkStack doesn't
    // forward focus to its visible child on its own either, so we
    // reach into the active session via `host.currentVte()`.
    if (host.currentVte()) |vte| {
        if (!panel.focusChild(vte)) {
            std.debug.print("warning: failed to grab initial focus on VTE\n", .{});
        }
    }

    // Pick up `window-hide-on-blur` from config — Raycast / Spotlight
    // semantics. Connects a notify::is-active handler on the window;
    // when the user clicks away the panel hides itself, ready to be
    // re-summoned by the hotkey. Off by default; users opt in.
    panel.setHideOnBlur(config.window.hide_on_blur);

    // Map `window-topmost` onto the layer-shell layer. The panel
    // opens with LAYER_OVERLAY by default; setTopmost(false) drops
    // it to LAYER_TOP so a fullscreen video or screen-locker can
    // cover the Quake-drop. No-op on non-layer-shell compositors.
    panel.setTopmost(config.window.topmost);

    // Install panel-window keyboard shortcuts (font zoom + clear
    // scrollback + open_settings + mcp_copy_endpoint + copy/paste
    // + toggle_log_pane). Context address must outlive the panel —
    // placed on this frame, same lifetime as `host`, `panel`, and
    // `log_pane`. CAPTURE phase keeps the bindings ahead of VTE's
    // internal shortcut set.
    //
    // Find overlay (Ctrl+Shift+F). Anchored on the GtkStack (the
    // SessionHost's container) rather than a single VTE so the
    // popover survives profile switches; SessionHost.find_overlay
    // is stamped below so each `activate(idx)` retargets the search
    // onto the new visible VTE. Initial target = currently active
    // VTE.
    const active_vte = host.currentVte() orelse {
        std.debug.print("session host: no active VTE after init — aborting\n", .{});
        return error.NoActiveSession;
    };
    var find = platform.FindOverlay.init(allocator, host.widget(), @ptrCast(active_vte)) catch |err| {
        std.debug.print("find overlay init failed: {} — Ctrl+Shift+F unavailable\n", .{err});
        return err;
    };
    defer find.deinit();
    find.install();
    // Suppress hide-on-blur while the find popover holds an input
    // grab: KWin Wayland's `autohide` grab flips the parent
    // toplevel's `is-active` to false the moment the popover pops
    // up, which without this guard fires hide-on-blur and yanks
    // djinn out from under the user's Ctrl+Shift+F.
    panel.trackPopoverGrabs(find.popoverWidget());
    host.find_overlay = &find;

    // Cheatsheet popover (Ctrl+?). Anchored to the GtkStack so it's
    // reachable regardless of which VTE is currently visible — the
    // popover content (the keymap reference) is profile-agnostic.
    var cheatsheet = platform.Cheatsheet.init(allocator, host.widget()) catch |err| {
        std.debug.print("cheatsheet init failed: {} — Ctrl+? unavailable\n", .{err});
        return err;
    };
    defer cheatsheet.deinit();

    // Profile palette (Ctrl+Shift+P). Same anchor story as the find
    // overlay + cheatsheet: parent on the GtkStack so the popover
    // doesn't reparent across profile switches. Reuses `onTabActivate`
    // as its activate handler. Both surfaces route into
    // `SessionHost.activate`, so the chip-update fan-out via
    // `on_switch` (already wired to the tab strip above) runs for
    // palette-driven switches too.
    var palette = platform.Palette.init(
        allocator,
        &session_manager,
        .{ .ctx = @ptrCast(&host), .on_invoke = onTabActivate },
        host.widget(),
        theme_opts,
    ) catch |err| {
        std.debug.print("palette init failed: {}; Ctrl+Shift+P unavailable\n", .{err});
        return err;
    };
    defer palette.deinit();
    palette.install();
    // Same hide-on-blur suppression as the find overlay — the
    // palette popover also uses `autohide=true` for click-outside
    // dismissal, and without this guard Ctrl+Shift+P flashes the
    // popover and hides djinn.
    panel.trackPopoverGrabs(palette.popoverWidget());
    g_dispatch.palette = &palette;

    var keymap_ctx = platform.KeymapContext{
        .session_host = &host,
        .allocator = allocator,
        .log_pane = &log_pane,
        .panel = &panel,
        .config = &config,
        // theme_toggle reapply hook. Cycles the appearance override
        // in `ghostty_config`, then needs the same theme apply chain
        // a config save would invoke so the new
        // `theme = light:X,dark:Y` variant gets baked in. Routes
        // through `Dispatch.onConfigChanged` — wasteful by ~1ms (re-
        // reads djinn config too) but reuses one path instead of
        // duplicating the apply sequence.
        .reapply_config = .{
            .ctx = @ptrCast(&g_dispatch),
            .on_invoke = Dispatch.onConfigChanged,
        },
        .popovers = .{
            .find_overlay = &find,
            .cheatsheet = &cheatsheet,
            .palette = &palette,
        },
    };
    platform.keymap.install(&panel, &keymap_ctx);

    // SIGTERM → panel.quit. SIGINT already drops through GLib's
    // default signal-fd watch (no extra wiring needed for it).
    // Packagers wiring djinn as a systemd user service stop the unit
    // with SIGTERM, so without this handler the kill escalates to
    // SIGKILL after TimeoutStopSec.
    _ = g_unix_signal_add(std.posix.SIG.TERM, Dispatch.onSigterm, @ptrCast(&g_dispatch));

    // IPC trigger. Listens on $XDG_RUNTIME_DIR/djinn.sock for
    // `toggle` / `show` / `hide` / `quit` commands. The user binds
    // their compositor's hotkey (KDE Custom Shortcuts / Hyprland
    // `bind = ...`) to a one-shot client that writes the verb. This
    // is the bridge while portal-based auto-registration is unbuilt
    // — see TODO.md for the handoff plan. g_dispatch is already
    // initialized above (so Terminal's child-exited handler can use
    // it); the IPC just borrows the same context.
    var ipc = platform.Ipc.init(allocator, .{
        .ctx = @ptrCast(&g_dispatch),
        .on_command = Dispatch.onCommand,
    }) catch |err| {
        std.debug.print("ipc init failed: {} — proceeding without external toggle\n", .{err});
        return runWithoutIpc(&panel);
    };
    defer ipc.deinit();

    // Auto-register the global hotkey via xdg-desktop-portal.GlobalShortcuts.
    // First-time runs on KDE pop a confirmation dialog; subsequent launches
    // are silent. Failure here is non-fatal — the IPC bridge above keeps
    // scripted toggles working, and the user can still bind their
    // compositor's native hotkey to the same socket if the portal isn't
    // available (no portal backend installed, GlobalShortcuts not
    // implemented by this compositor's portal, etc.).
    // Sync failure paths inside `Hotkey.init` print their own
    // "hotkey: portal unavailable — <reason>" log via the aggregate
    // reporter; the IPC bridge above keeps scripted toggles working
    // either way. Don't re-log here — duplicate lines obscure which
    // outcome was the definitive one.
    var maybe_hotkey: ?platform.Hotkey = platform.Hotkey.init(
        allocator,
        .{ .ctx = @ptrCast(&g_dispatch), .on_activated = Dispatch.onHotkey },
        config.hotkey.toggle,
    ) catch null;
    defer if (maybe_hotkey) |*h| h.deinit();
    g_dispatch.hotkey = &maybe_hotkey;

    // System tray surface (StatusNotifierItem + dbusmenu). Tray hosts
    // are KDE's plasmashell, waybar, xfce4-panel, and GNOME's
    // AppIndicator extension. If no host is running (bare wlroots,
    // i3-on-X11-equivalent), the watcher registration fails and the
    // tray is silently absent — the panel itself is unaffected.
    var maybe_tray: ?platform.Tray = platform.Tray.init(
        allocator,
        .{
            .ctx = @ptrCast(&g_dispatch),
            .on_activate = Dispatch.onTrayActivate,
            .on_quit = Dispatch.onTrayQuit,
        },
    ) catch |err| blk: {
        std.debug.print("tray init failed: {} — proceeding without tray\n", .{err});
        break :blk null;
    };
    defer if (maybe_tray) |*t| t.deinit();

    // Config-file watcher. Mirrors darwin's FSEventStream setup —
    // parent-dir granularity for atomic-rename safety, basename
    // filtering inside the watcher to ignore unrelated writes
    // (state.json on resize, ghostty's cached files, …). The
    // watched-files slice is built on a stack buffer because the
    // watcher dupes its own copies internally; the buffer can go
    // out of scope as soon as init returns.
    var path_buf_djinn: [256]u8 = undefined;
    var path_buf_ghostty: [256]u8 = undefined;
    var watched_paths_buf: [2][]const u8 = undefined;
    var watched_paths: []const []const u8 = watched_paths_buf[0..0];

    if (std.posix.getenv("HOME")) |home| {
        const djinn_path = std.fmt.bufPrint(
            &path_buf_djinn,
            "{s}/.config/djinn/config",
            .{home},
        ) catch null;
        const ghostty_path = std.fmt.bufPrint(
            &path_buf_ghostty,
            "{s}/.config/ghostty/config",
            .{home},
        ) catch null;

        var n: usize = 0;
        if (djinn_path) |p| {
            watched_paths_buf[n] = p;
            n += 1;
        }
        if (ghostty_path) |p| {
            watched_paths_buf[n] = p;
            n += 1;
        }
        watched_paths = watched_paths_buf[0..n];
    }

    var maybe_watcher: ?platform.Watcher = if (watched_paths.len > 0)
        platform.Watcher.init(
            allocator,
            watched_paths,
            .{ .ctx = @ptrCast(&g_dispatch), .on_changed = Dispatch.onConfigChanged },
        ) catch |err| blk: {
            std.debug.print("config watcher init failed: {}\n", .{err});
            break :blk null;
        }
    else
        null;
    defer if (maybe_watcher) |*w| w.deinit();

    // Apply autostart preference. Idempotent on both branches —
    // register overwrites an existing entry with current Exec path,
    // unregister treats ENOENT as success. Failures are logged but
    // non-fatal; the user's config preference is best-effort.
    if (config.system.open_at_login) {
        platform.AutoStart.register(allocator) catch |err| {
            std.debug.print("autostart register failed: {}\n", .{err});
        };
    } else {
        platform.AutoStart.unregister(allocator) catch |err| {
            std.debug.print("autostart unregister failed: {}\n", .{err});
        };
    }

    // ─── MCP server ─────────────────────────────────────────────────
    //
    // Same wiring shape as darwin's `main.zig`: AgentState → Notifier →
    // ToolTable → Dispatcher → McpServer on a detached thread.
    // SessionManager is now wired on linux (built above), so
    // `djinn_active_profile` returns real {name, label, cwd, command}
    // for the currently-active profile. Notify-on-mute still works
    // identically via the client.<id>.mute config lookup.
    var agent_state = AgentState.init(allocator);
    defer agent_state.deinit();

    // Drive the tray icon off agent-state transitions. Polled at
    // 250ms — matches darwin's TerminalView.tickImpl cadence; see
    // tray.zig:observeAgentState for the diff-and-emit details.
    // Wired only when the tray came up; without a tray host there's
    // nothing to observe for.
    if (maybe_tray) |*t| t.observeAgentState(&agent_state);

    // Log pane mirrors the same poll cadence. Independent source
    // from the tray's — both watch AgentState directly, so a single
    // shared poller would only save a g_timeout slot at the cost of
    // coupling two subsystems with different lifetimes (tray is
    // optional; log pane always exists).
    log_pane.observeAgentState(&agent_state);

    var notifier = platform.Notifier.init(.{
        .enabled = config.notifications.system_notifications,
        .rate_limit_ms = config.notifications.rate_limit_ms,
    });
    defer notifier.deinit();

    var tools = ToolTable{
        .state = &agent_state,
        .notifier = &notifier,
        .attention_sound = config.notifications.attention_sound,
        .notify_on_attention = config.notifications.notify_on_attention,
        .notify_on_error = config.notifications.notify_on_error,
        .notify_on_done = config.notifications.notify_on_done,
        .notify_on_progress = config.notifications.notify_on_progress,
        .config = &config,
        .session_manager = &session_manager,
    };
    var dispatcher = Dispatcher{ .tool_table = tools.table() };

    var mcp_server_opt: ?McpServer = null;
    defer if (mcp_server_opt) |*s| s.deinit();
    const mcp_handler = dispatcher.handler();
    g_dispatch.mcp_server = &mcp_server_opt;
    g_dispatch.mcp_handler = mcp_handler;
    g_dispatch.tool_table = &tools;
    g_dispatch.notifier = &notifier;

    if (config.mcp.enabled) {
        startMcpServer(allocator, mcp_handler, &mcp_server_opt);
    }

    std.debug.print(
        "\npanel + terminal open. Toggle from any shell with:\n" ++
            "    printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock\n" ++
            "Close the window or SIGINT to exit.\n",
        .{},
    );

    panel.runLoop();
}

/// IPC-less main-loop drive. The panel still runs; the user just has
/// no external way to toggle it short of closing the window. We hit
/// this when bind/listen fail (e.g. socket path unavailable, fd
/// exhaustion). Keeping the panel up beats aborting on the cold path.
fn runWithoutIpc(panel: *platform.Panel) void {
    std.debug.print(
        "\npanel open without IPC. Close the window or SIGINT to exit.\n",
        .{},
    );
    panel.runLoop();
}

test {
    // Re-export the platform-agnostic tests so `zig build test` from a
    // linux target still exercises the same module surface that the
    // darwin test target runs. As linux-specific modules land they'll
    // get added here.
    _ = @import("config.zig");
    _ = @import("agent/state.zig");
    _ = @import("state/persist.zig");
    _ = @import("mcp/dispatch.zig");
    _ = @import("version.zig");
    _ = @import("platform/linux/panel.zig");
    _ = @import("platform/linux/terminal.zig");
    _ = @import("platform/linux/gtk.zig");
    _ = @import("platform/linux/ipc.zig");
    _ = @import("platform/linux/hotkey.zig");
    _ = @import("platform/linux/tray.zig");
    _ = @import("platform/linux/notifier.zig");
    _ = @import("platform/linux/watcher.zig");
    _ = @import("platform/linux/autostart.zig");
    _ = @import("platform/linux/dragdrop.zig");
    _ = @import("platform/linux/theme.zig");
    _ = @import("platform/linux/ghostty_config.zig");
    _ = @import("platform/linux/keymap.zig");
    _ = @import("platform/linux/log_pane.zig");
    _ = @import("platform/linux/session_host.zig");
    _ = @import("platform/linux/tab_strip.zig");
    _ = @import("platform/linux/palette.zig");
}

// ─── main_linux smoke tests ──────────────────────────────────────────
//
// The watcher reload path (`Dispatch.onConfigChanged`) drives GTK on
// the main thread, so the full flow can't run under `zig build test`.
// What CAN be tested without a GTK display is the pure-data plumbing
// the reload depends on:
//
//   - Config parse + deinit round-trip — proves the live-reload swap
//     can drop a Config without leaks.
//   - buildThemeOptions merge order — proves djinn config wins over
//     ghostty inheritance on every field (regressing this would
//     silently make ghostty's palette override the user's explicit
//     `theme.background = …` on every save).
//   - mergeColor priority — same property at the leaf.
//
// These are the smoke tests called out as priority #2 in TODO.md's
// "Code review backlog". The full GTK-bound `onConfigChanged` flow
// stays covered by manual smoke runs on a Wayland session.

test "Config: parse + deinit round-trip" {
    const a = std.testing.allocator;
    const src =
        \\hotkey = ctrl+shift+space
        \\window-width = 1200
        \\window-height = 600
        \\background = #112233
        \\font-size = 16
        \\
    ;
    var cfg = try Config.parse(a, src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("ctrl+shift+space", cfg.hotkey.toggle);
    try std.testing.expectEqual(@as(?u32, 1200), cfg.window.width);
    try std.testing.expectEqual(@as(?u32, 600), cfg.window.height);
    try std.testing.expectEqualStrings("#112233", cfg.theme.background.?);
    try std.testing.expectEqual(@as(?f64, 16), cfg.terminal.font_size);
}

test "Config: default-constructed deinit is a no-op" {
    // The live-reload path swaps in a freshly-loaded Config and
    // deinit's the prior one. The very first Config in `main_linux.zig`
    // comes from `loadOrDefault`, which returns `Config{}` when no
    // file exists. Deinit on that default value must be safe.
    var cfg: Config = .{};
    cfg.deinit();
}

test "mergeColor: djinn hex wins over ghostty" {
    const ghostty: ?platform.GhosttyColors = .{
        .background = .{ .r = 0, .g = 0, .b = 0 },
    };
    const c = mergeColor("#ff8040", ghostty, .background).?;
    try std.testing.expectEqual(@as(u8, 0xff), c.r);
    try std.testing.expectEqual(@as(u8, 0x80), c.g);
    try std.testing.expectEqual(@as(u8, 0x40), c.b);
}

test "mergeColor: ghostty fills gaps when djinn is null" {
    const ghostty: ?platform.GhosttyColors = .{
        .foreground = .{ .r = 0xab, .g = 0xcd, .b = 0xef },
    };
    const c = mergeColor(null, ghostty, .foreground).?;
    try std.testing.expectEqual(@as(u8, 0xab), c.r);
    try std.testing.expectEqual(@as(u8, 0xcd), c.g);
    try std.testing.expectEqual(@as(u8, 0xef), c.b);
}

test "mergeColor: returns null when neither source has a value" {
    try std.testing.expect(mergeColor(null, null, .cursor) == null);
    const ghostty: ?platform.GhosttyColors = .{};
    try std.testing.expect(mergeColor(null, ghostty, .cursor) == null);
}

test "mergeColor: malformed djinn hex falls through to ghostty" {
    // Reload safety: a user typo in `theme.background` shouldn't blank
    // the panel — fall back to whatever ghostty resolved.
    const ghostty: ?platform.GhosttyColors = .{
        .background = .{ .r = 0x10, .g = 0x20, .b = 0x30 },
    };
    const c = mergeColor("not-a-hex", ghostty, .background).?;
    try std.testing.expectEqual(@as(u8, 0x10), c.r);
}

test "buildThemeOptions: djinn config wins on every field" {
    const a = std.testing.allocator;
    const src =
        \\font-family = "Cascadia Code"
        \\font-size = 13
        \\background = #010203
        \\foreground = #040506
        \\cursor-color = #070809
        \\opacity = 0.75
        \\padding-x = 8
        \\padding-y = 4
        \\
    ;
    var cfg = try Config.parse(a, src);
    defer cfg.deinit();

    // Ghostty values present for every field — djinn config should
    // shadow them.
    const ghostty: ?platform.GhosttyColors = .{
        .background = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .cursor = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .font_family = "Ghostty Font",
        .font_size = 99,
    };

    const opts = buildThemeOptions(&cfg, ghostty);
    try std.testing.expectEqualStrings("Cascadia Code", opts.font_family.?);
    try std.testing.expectEqual(@as(?f64, 13), opts.font_size);
    try std.testing.expectEqual(@as(u8, 0x01), opts.background.?.r);
    try std.testing.expectEqual(@as(u8, 0x04), opts.foreground.?.r);
    try std.testing.expectEqual(@as(u8, 0x07), opts.cursor.?.r);
    try std.testing.expectEqual(@as(?f64, 8), opts.padding_x);
    try std.testing.expectEqual(@as(?f64, 4), opts.padding_y);
    try std.testing.expectEqual(@as(?f64, 0.75), opts.opacity);
}

test "buildThemeOptions: ghostty fills gaps when djinn unset" {
    const a = std.testing.allocator;
    var cfg = try Config.parse(a, "");
    defer cfg.deinit();

    const ghostty: ?platform.GhosttyColors = .{
        .background = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        .font_family = "Inherited",
        .font_size = 11,
        .palette = blk: {
            var p: [16]?platform.ghostty_config.Rgb = .{null} ** 16;
            p[3] = .{ .r = 1, .g = 2, .b = 3 };
            break :blk p;
        },
    };

    const opts = buildThemeOptions(&cfg, ghostty);
    try std.testing.expectEqualStrings("Inherited", opts.font_family.?);
    try std.testing.expectEqual(@as(?f64, 11), opts.font_size);
    try std.testing.expectEqual(@as(u8, 0xaa), opts.background.?.r);
    // theme-opacity unset, window.opacity defaults to 0.95.
    try std.testing.expectEqual(@as(?f64, 0.95), opts.opacity);
    // Palette is ghostty-only.
    try std.testing.expectEqual(@as(u8, 2), opts.palette[3].?.g);
}

test "buildThemeOptions: no ghostty inheritance" {
    const a = std.testing.allocator;
    var cfg = try Config.parse(a, "background = #abcdef\n");
    defer cfg.deinit();

    const opts = buildThemeOptions(&cfg, null);
    try std.testing.expectEqual(@as(u8, 0xab), opts.background.?.r);
    try std.testing.expect(opts.foreground == null);
    try std.testing.expect(opts.font_family == null);
    // Palette stays all-null when ghostty isn't inherited.
    for (opts.palette) |slot| try std.testing.expect(slot == null);
}

test "strOptEql: identity" {
    try std.testing.expect(strOptEql("ctrl+space", "ctrl+space"));
    try std.testing.expect(!strOptEql("ctrl+space", "alt+space"));
    try std.testing.expect(strOptEql("", ""));
}
