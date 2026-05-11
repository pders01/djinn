//! Tier-5 runtime — bridges the full libghostty surface API into djinn.
//!
//! Sits parallel to `terminal.zig`, which wraps the bare `vt-static`
//! parser. This module wraps the higher-level surface API exposed by
//! `ghostty.h` (the embedding API): global init, app lifecycle,
//! surface lifecycle, runtime callbacks. None of it is wired into the
//! view yet — initial scope is just standing up the global state so
//! we know dynamic symbol resolution works at runtime, not just at
//! link time.
//!
//! cImport is in its own scope on purpose. ghostty's `vt.h` and
//! `ghostty.h` both define some of the same opaque handle types (e.g.
//! `ghostty_app_t`, surface state); Zig synthesizes a unique opaque
//! type per `@cImport` block, so cross-module passing of those handles
//! between this file and `terminal.zig` would require pointer casts.
//! For the surface API we don't need the vt types, so the boundary
//! stays clean.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");

pub const c = @cImport({
    @cInclude("ghostty.h");
});

/// What ghostty surface/app callbacks recover when they need to talk
/// back to the host. Reachable via `ghostty_app_userdata(app)` (set on
/// `runtime_config_s.userdata`) and `ghostty_surface_userdata(surf)`
/// (set on `surface_config_s.userdata`). Same pointer for both today —
/// when tabs/splits land, each surface gets its own slot but the type
/// stays the same.
pub const HostContext = struct {
    /// Backreference to the global AppState (`&app.g`). Action handlers
    /// pull terminals, panels, agent state, config from here.
    app_state: *app_mod.AppState,
    /// ghostty_app_t handle. Stashed so the wakeup callback (which only
    /// receives userdata) can call ghostty_app_tick. Set by App.init
    /// after ghostty_app_new returns.
    app_handle: ?c.ghostty_app_t = null,
};

/// Stable storage for the per-process host context. Initialized by
/// `setHost` before `App.init`; outlives the App + surfaces.
pub var host_storage: HostContext = undefined;
var host_inited: bool = false;

/// Wire the global `&app.g` into ghostty's userdata channel. Call once
/// before `App.init`. Idempotent.
pub fn setHost(state: *app_mod.AppState) void {
    host_storage = .{ .app_state = state };
    host_inited = true;
}

/// Recover the host context from a ghostty_app_t. Returns null if the
/// host wasn't wired (init order bug) or ghostty handed back a
/// different userdata pointer.
pub fn hostFromApp(handle: c.ghostty_app_t) ?*HostContext {
    if (!host_inited) return null;
    const ud = c.ghostty_app_userdata(handle);
    if (ud == null) return null;
    return @ptrCast(@alignCast(ud));
}

/// Re-read ~/.config/ghostty/config from disk and push the resulting
/// config to the live app. Picks up cursor-style, font, theme, …
/// without restarting djinn. The previous config is freed once the
/// new one is in place — ghostty clones internally on update.
/// Re-read ~/.config/ghostty/config + push to app + active surface.
/// Picks up font / theme / palette / colors / many keybinding edits
/// without restarting djinn.
///
/// Known not-applied at runtime (ghostty re-reads these only on
/// surface init): cursor-style. The terminal's visual cursor style
/// is a DECSCUSR runtime field, not derived from config post-init —
/// changing `cursor-style` in the file requires opening a fresh
/// surface for it to take effect.
pub fn reloadConfigFromDisk() void {
    if (!host_inited) return;
    const app_handle = host_storage.app_handle orelse return;
    const new_cfg = c.ghostty_config_new() orelse return;
    c.ghostty_config_load_default_files(new_cfg);
    // Re-apply the dual-theme appearance override before finalize.
    // Same rationale as App.init: ghostty's `loadTheme` picks the
    // LIGHT variant of `theme = light:X,dark:Y` at finalize, so on
    // reload we'd revert to LIGHT regardless of the system
    // appearance unless we layer the override on top.
    if (writeAppearanceThemeOverride()) |tmp_path| {
        defer std.heap.page_allocator.free(tmp_path);
        if (std.heap.page_allocator.allocSentinel(u8, tmp_path.len, 0)) |z| {
            defer std.heap.page_allocator.free(z);
            @memcpy(z[0..tmp_path.len], tmp_path);
            c.ghostty_config_load_file(new_cfg, z.ptr);
        } else |_| {}
    }
    c.ghostty_config_finalize(new_cfg);
    c.ghostty_app_update_config(app_handle, new_cfg);
    if (host_storage.app_state.ghostty.surface) |surf_ptr| {
        const surf: c.ghostty_surface_t = @ptrCast(surf_ptr);
        c.ghostty_surface_update_config(surf, new_cfg);
    }
    if (host_storage.app_state.ghostty.config) |old| {
        c.ghostty_config_free(@ptrCast(old));
    }
    host_storage.app_state.ghostty.config = @ptrCast(new_cfg);
}

/// Peek the user's `~/.config/ghostty/config`, find the `theme = ...`
/// line, and (when it's a `light:X,dark:Y` split) write a tmp file
/// containing the variant matching the host's system appearance.
/// Returns the tmp path on success (caller frees + loads via
/// `ghostty_config_load_file` BEFORE `ghostty_config_finalize`); null
/// when there's nothing to override (no theme line, or single-variant
/// theme that ghostty handles correctly already).
fn writeAppearanceThemeOverride() ?[]const u8 {
    const allocator = std.heap.page_allocator;
    const home = std.posix.getenv("HOME") orelse return null;
    const cfg_path = std.fmt.allocPrint(allocator, "{s}/.config/ghostty/config", .{home}) catch return null;
    defer allocator.free(cfg_path);

    const file = std.fs.openFileAbsolute(cfg_path, .{}) catch return null;
    defer file.close();
    const contents = file.readToEndAlloc(allocator, 256 * 1024) catch return null;
    defer allocator.free(contents);

    // Find the last `theme = ...` line (last-one-wins matches ghostty's
    // own load order — later assignments override earlier ones).
    var theme_spec: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, k, "theme")) continue;
        theme_spec = std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    const spec = theme_spec orelse return null;

    // Only intervene for split-variant specs. Plain `theme = X` is
    // handled correctly by ghostty already.
    if (std.mem.indexOfScalar(u8, spec, ',') == null) return null;

    // Detect appearance via NSAppearance and pick the matching variant.
    // Inline lookup so this module stays free of theme.zig deps (theme
    // imports runtime.zig already; circular import otherwise).
    const dark = detectDarkAppearance();
    const picked = pickThemeVariant(spec, dark) orelse return null;

    // Write the override to a tmp file. Path is process-lifetime; the
    // file persists until exit (small text file, ~30 bytes — not worth
    // a cleanup hook).
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    // Fixed filename + truncate-write; no pid suffix needed (and
    // `std.os.linux.getpid` is the wrong namespace for darwin — its
    // value isn't a real macOS pid). Each launch overwrites.
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/djinn-theme-override.conf", .{tmpdir}) catch return null;
    const out = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch {
        allocator.free(tmp_path);
        return null;
    };
    defer out.close();
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "theme = {s}\n", .{picked}) catch {
        allocator.free(tmp_path);
        return null;
    };
    out.writeAll(line) catch {
        allocator.free(tmp_path);
        return null;
    };
    return tmp_path;
}

fn pickThemeVariant(spec: []const u8, dark: bool) ?[]const u8 {
    const target_prefix: []const u8 = if (dark) "dark:" else "light:";
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, trimmed, target_prefix)) {
            return std.mem.trim(u8, trimmed[target_prefix.len..], " \t");
        }
    }
    return null;
}

/// Write a tmp ghostty config file with djinn-side overrides — keys
/// djinn config exposes that map onto ghostty's own keys. Loaded after
/// the user's `~/.config/ghostty/config` so djinn settings win.
/// Returns the tmp path (owned, free with page_allocator) or null when
/// there's nothing to write.
fn writeDjinnGhosttyOverride(scrollback_limit: ?u32) ?[]const u8 {
    if (scrollback_limit == null) return null;

    const allocator = std.heap.page_allocator;
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/djinn-ghostty-override.conf", .{tmpdir}) catch return null;
    const out = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch {
        allocator.free(tmp_path);
        return null;
    };
    defer out.close();
    var buf: [128]u8 = undefined;
    if (scrollback_limit) |n| {
        const line = std.fmt.bufPrint(&buf, "scrollback-limit = {d}\n", .{n}) catch {
            allocator.free(tmp_path);
            return null;
        };
        out.writeAll(line) catch {
            allocator.free(tmp_path);
            return null;
        };
    }
    return tmp_path;
}

fn detectDarkAppearance() bool {
    // NSAppearance lookup. Same logic as theme.detectSystemAppearance,
    // duplicated here to avoid a circular import (theme imports this
    // module already). Falls back to dark on lookup failure (most
    // terminal users prefer dark; matches theme.zig's tie-break).
    const objc = @import("objc");
    const NSApplication = objc.getClass("NSApplication") orelse return true;
    const app_obj = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    const appearance = app_obj.msgSend(objc.Object, "effectiveAppearance", .{});
    if (appearance.value == null) return true;
    const name = appearance.msgSend(objc.Object, "name", .{});
    if (name.value == null) return true;
    const utf8 = name.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8 == null) return true;
    const str = std.mem.sliceTo(utf8, 0);
    return std.mem.indexOf(u8, str, "Dark") != null;
}

/// Initialize ghostty's global state. Must be called before any
/// `ghostty_app_new` / `ghostty_surface_new` call. Sets `std.os.argv`
/// inside ghostty + spins up its allocator/logging/state.
///
/// argv is built from `std.os.argv`; we copy the per-arg pointers
/// into a heap slice so the C signature `[*][*:0]u8` is satisfied
/// without depending on Zig slice-header layout. The slice is owned
/// by the caller — free after this returns (ghostty stores raw
/// pointers, not the outer slice).
pub fn init() !void {
    // Zig 0.15: std.os.argv is `[][*:0]u8` — slice of C-string
    // pointers, not slice of slices. Each element already is the
    // `[*:0]u8` we need. Pass `.ptr` of the slice directly. No
    // allocator needed — ghostty stores its own copy of the
    // pointers, doesn't take ownership.
    const rc = c.ghostty_init(@intCast(std.os.argv.len), @ptrCast(std.os.argv.ptr));
    if (rc != 0) {
        std.debug.print("ghostty_init failed (rc={d})\n", .{rc});
        return error.GhosttyInitFailed;
    }
    std.debug.print("ghostty_init OK (libghostty surface API ready)\n", .{});
}

/// Owns a `ghostty_app_t` plus its config + the runtime config struct
/// kept alive for the lifetime of the app (ghostty stores a pointer
/// to it, so the storage must outlive the app).
pub const App = struct {
    handle: c.ghostty_app_t,
    config: c.ghostty_config_t,
    /// Keep alive — ghostty stores `*const` of this struct.
    runtime_cfg: c.ghostty_runtime_config_s,

    /// Allocate + finalize a default ghostty config and instantiate the
    /// app with stub callbacks. Returns null if any of the C calls
    /// fails — none of the failure modes have rich error messages
    /// (the C API just returns null), so callers should treat null
    /// as "Tier-5 surface unavailable, fall back to vt-static path."
    pub fn init(scrollback_limit: ?u32) ?App {
        const cfg = c.ghostty_config_new() orelse {
            std.debug.print("ghostty_app: config_new returned null\n", .{});
            return null;
        };
        // Pull in defaults from ~/.config/ghostty/config so font /
        // theme / palette match what user already configured for
        // ghostty proper. Failure here is non-fatal in upstream's C
        // API (returns void) — config stays at built-in defaults.
        c.ghostty_config_load_default_files(cfg);

        // ghostty's `loadTheme` picks the LIGHT variant of a
        // `theme = light:X,dark:Y` pair as the default conditional
        // state during finalize. There's no public C API to set the
        // conditional state on a config object before finalize, so
        // peek the user's config ourselves, pick the right variant
        // for the system appearance, and write `theme = <picked>` as
        // a tmp file that overrides the original line. Loaded BEFORE
        // finalize so the right theme file gets merged in.
        if (writeAppearanceThemeOverride()) |tmp_path| {
            defer std.heap.page_allocator.free(tmp_path);
            const z = std.heap.page_allocator.allocSentinel(u8, tmp_path.len, 0) catch return null;
            defer std.heap.page_allocator.free(z);
            @memcpy(z[0..tmp_path.len], tmp_path);
            c.ghostty_config_load_file(cfg, z.ptr);
        }

        // djinn-side overrides for ghostty config keys we surface in
        // djinn's own config file. Currently just `scrollback-size →
        // scrollback-limit`; loaded after the appearance override so
        // either can be patched independently.
        if (writeDjinnGhosttyOverride(scrollback_limit)) |tmp_path| {
            defer std.heap.page_allocator.free(tmp_path);
            const z = std.heap.page_allocator.allocSentinel(u8, tmp_path.len, 0) catch return null;
            defer std.heap.page_allocator.free(z);
            @memcpy(z[0..tmp_path.len], tmp_path);
            c.ghostty_config_load_file(cfg, z.ptr);
        }

        c.ghostty_config_finalize(cfg);

        // userdata channel: every callback that takes `userdata` (wakeup,
        // clipboard, close_surface) receives this pointer. action_cb has no
        // userdata param — it recovers the same pointer via
        // `ghostty_app_userdata(app)`.
        const ud: ?*anyopaque = if (host_inited) @ptrCast(&host_storage) else null;
        var rt_cfg: c.ghostty_runtime_config_s = .{
            .userdata = ud,
            .supports_selection_clipboard = false,
            .wakeup_cb = wakeupStub,
            .action_cb = actionDispatch,
            .read_clipboard_cb = readClipboardImpl,
            .confirm_read_clipboard_cb = confirmReadClipboardStub,
            .write_clipboard_cb = writeClipboardImpl,
            .close_surface_cb = closeSurfaceStub,
        };

        const app_handle = c.ghostty_app_new(&rt_cfg, cfg) orelse {
            std.debug.print("ghostty_app: app_new returned null\n", .{});
            c.ghostty_config_free(cfg);
            return null;
        };
        if (host_inited) host_storage.app_handle = app_handle;

        std.debug.print("ghostty_app_new OK (app + config + stub callbacks)\n", .{});

        return .{
            .handle = app_handle,
            .config = cfg,
            .runtime_cfg = rt_cfg,
        };
    }

    pub fn deinit(self: *App) void {
        c.ghostty_app_free(self.handle);
        // Per upstream: app_free does NOT free the config — caller
        // owns it (ghostty's app keeps a clone for itself).
        c.ghostty_config_free(self.config);
        self.* = undefined;
    }

    /// Create a surface bound to an NSView. Caller owns the returned
    /// handle and must `surfaceFree` it before the app is freed
    /// (`ghostty_surface_free` calls back into the app's surface
    /// registry to unregister).
    ///
    /// `nsview` is a `void*` to an NSView (the C API takes
    /// `ghostty_platform_macos_s.nsview`). Pass `view.value` from a
    /// `objc.Object` wrapper. `scale` is the host display's
    /// backingScaleFactor (1.0 / 2.0 / 3.0).
    ///
    /// Step-3 scope: just exercise the call path. The surface is
    /// not attached to our render pipeline (drawRect / Metal scene
    /// path keeps owning the view). Subsequent steps will switch
    /// the host so the surface's Metal layer takes over.
    pub fn newSurface(
        self: *App,
        nsview: ?*anyopaque,
        scale: f64,
        command: ?[*:0]const u8,
        working_directory: ?[*:0]const u8,
    ) ?c.ghostty_surface_t {
        var opts = c.ghostty_surface_config_new();
        opts.platform_tag = c.GHOSTTY_PLATFORM_MACOS;
        opts.platform.macos = .{ .nsview = nsview };
        opts.scale_factor = scale;
        opts.context = c.GHOSTTY_SURFACE_CONTEXT_WINDOW;
        // wait_after_command=false: when shell exits (Ctrl+D, `exit`)
        // surface closes immediately and fires close_surface_cb. The
        // default true makes the surface print "Process exited. Press
        // any key to close" and wait — wrong UX for a Quake-drop that
        // the user just dropped. Our close_surface_cb hides the panel.
        opts.wait_after_command = false;
        // Same HostContext pointer the app uses across every surface;
        // each session shares the host event channel + action dispatch.
        if (host_inited) opts.userdata = @ptrCast(&host_storage);
        // Provider command (claude, codex, …). Null → ghostty spawns
        // user's default shell. Working directory null → ghostty's
        // own fallback ($HOME).
        if (command) |cmd| opts.command = cmd;
        if (working_directory) |wd| opts.working_directory = wd;

        const surf = c.ghostty_surface_new(self.handle, &opts) orelse {
            std.debug.print("ghostty_surface: surface_new returned null\n", .{});
            return null;
        };
        std.debug.print("ghostty_surface_new OK (surface bound to NSView {*})\n", .{nsview});
        return surf;
    }

    pub fn surfaceFree(_: *App, surface: c.ghostty_surface_t) void {
        c.ghostty_surface_free(surface);
    }
};

// ─── Config introspection ─────────────────────────────────────────
//
// Thin typed wrappers around `ghostty_config_get`. Each helper hides
// the (key_str, key_len) repetition + the out-pointer dance. Returns
// null when ghostty doesn't recognize the key or the field is unset
// (matches ghostty_config_get's bool return).

pub fn configColor(cfg: c.ghostty_config_t, key: []const u8) ?c.ghostty_config_color_s {
    var out: c.ghostty_config_color_s = .{ .r = 0, .g = 0, .b = 0 };
    if (!c.ghostty_config_get(cfg, &out, key.ptr, key.len)) return null;
    return out;
}

pub fn configPalette(cfg: c.ghostty_config_t) ?c.ghostty_config_palette_s {
    var out: c.ghostty_config_palette_s = undefined;
    const key = "palette";
    if (!c.ghostty_config_get(cfg, &out, key.ptr, key.len)) return null;
    return out;
}

/// Read a 32-bit float config key. ghostty's `c_get` branches on the
/// SOURCE field's type and `@alignCast`s the caller's slot to that
/// type, so the slot's storage size must match exactly — passing an
/// `f64*` for an `f32` field corrupts the upper half (writes only 4
/// bytes), and passing an `f32*` for an `f64` field panics on
/// alignment. Use this helper for fields ghostty declares as `f32`
/// (e.g. `font-size`).
pub fn configF32(cfg: c.ghostty_config_t, key: []const u8) ?f32 {
    var out: f32 = 0;
    if (!c.ghostty_config_get(cfg, &out, key.ptr, key.len)) return null;
    return out;
}

/// Read a 64-bit float config key. Use for fields ghostty declares as
/// `f64` (e.g. `background-opacity`). See `configF32` for the
/// rationale behind the type-strict split.
pub fn configF64(cfg: c.ghostty_config_t, key: []const u8) ?f64 {
    var out: f64 = 0;
    if (!c.ghostty_config_get(cfg, &out, key.ptr, key.len)) return null;
    return out;
}

/// Strings come back as `[*:0]const u8` pointing into ghostty's owned
/// string pool. Caller must not free; lifetime tied to the config.
/// Cast through `?*anyopaque` because zig's cImport surfaces
/// `ghostty_config_get`'s second arg as `?*anyopaque` and `&out`
/// would otherwise be a `**[*:0]const u8`.
pub fn configString(cfg: c.ghostty_config_t, key: []const u8) ?[]const u8 {
    var out: [*:0]const u8 = undefined;
    if (!c.ghostty_config_get(cfg, @ptrCast(&out), key.ptr, key.len)) return null;
    return std.mem.sliceTo(out, 0);
}

// ─── Surface lifecycle (step 5) ───────────────────────────────────
//
// Free functions — these only need the surface handle. Callers (view.zig
// resize hooks, panel.zig focus events) shouldn't have to reach for the
// App wrapper.

/// Push pixel-dimension changes to the surface. ghostty resizes its
/// drawable + reflows the terminal grid against `cell_w/cell_h` (set
/// internally from font + DPI). Idempotent — ghostty caches last size.
pub fn surfaceSetSize(surface: c.ghostty_surface_t, width_px: u32, height_px: u32) void {
    c.ghostty_surface_set_size(surface, width_px, height_px);
}

/// Push backingScaleFactor changes (display switch, Retina toggle).
/// Both axes carry the same scalar in practice; ghostty splits them
/// out for completeness.
pub fn surfaceSetContentScale(surface: c.ghostty_surface_t, scale: f64) void {
    c.ghostty_surface_set_content_scale(surface, scale, scale);
}

pub fn surfaceSetFocus(surface: c.ghostty_surface_t, focused: bool) void {
    c.ghostty_surface_set_focus(surface, focused);
}

/// Tell the surface whether it's currently visible. ghostty uses this
/// to throttle CADisplayLink + skip cursor blink work when the surface
/// is fully occluded — e.g. while the Quake panel is slid offscreen.
pub fn surfaceSetOcclusion(surface: c.ghostty_surface_t, visible: bool) void {
    c.ghostty_surface_set_occlusion(surface, visible);
}

/// Tell the surface to schedule a redraw. ghostty drives its own
/// CADisplayLink — refresh is a hint that something host-side changed
/// (theme, font) and the grid should repaint without waiting for the
/// next vsync tick.
pub fn surfaceRefresh(surface: c.ghostty_surface_t) void {
    c.ghostty_surface_refresh(surface);
}

/// Push the system color scheme to ghostty so its conditional state
/// (`theme = light:X,dark:Y`) re-resolves. Pair with
/// `reloadConfigFromDisk` to re-apply the appearance override file
/// when the system flips light↔dark at runtime.
pub fn appSetColorScheme(dark: bool) void {
    if (!host_inited) return;
    const handle = host_storage.app_handle orelse return;
    const scheme: c.ghostty_color_scheme_e = if (dark) c.GHOSTTY_COLOR_SCHEME_DARK else c.GHOSTTY_COLOR_SCHEME_LIGHT;
    c.ghostty_app_set_color_scheme(handle, scheme);
}

// Stub callbacks. None of these do anything yet; ghostty calls them
// when the surface wants to talk to the host runtime. Surface API
// isn't wired in step 2, so the only invocations would be from
// app-level events (none expected during pure init+free). Real
// implementations land alongside surface wiring.

/// Recover the HostContext from a callback's userdata pointer. Returns
/// null if userdata wasn't set (init order) — callers should treat that
/// as a no-op + log.
fn hostFromUserdata(ud: ?*anyopaque) ?*HostContext {
    if (ud == null) return null;
    return @ptrCast(@alignCast(ud));
}

/// ghostty's IO thread pokes us via wakeup_cb whenever it has work for
/// the main thread to process: mailbox messages (child_exited,
/// renderer health, OSC actions), surface state changes, etc. We have
/// to call ghostty_app_tick on main to drain. Without this the surface
/// never fires actions or close callbacks.
fn wakeupStub(_: ?*anyopaque) callconv(.c) void {
    if (!host_inited) return;
    if (host_storage.app_handle) |h| {
        dispatch_async_f(@ptrCast(c_dispatch.dispatch_get_main_queue()), h, &tickAppMain);
    }
}

fn tickAppMain(ctx: ?*anyopaque) callconv(.c) void {
    if (ctx) |raw| {
        const handle: c.ghostty_app_t = @ptrCast(raw);
        c.ghostty_app_tick(handle);
    }
}

fn actionDispatch(
    app: c.ghostty_app_t,
    target: c.ghostty_target_s,
    action: c.ghostty_action_s,
) callconv(.c) bool {
    // Recover host context once per call. Handlers that need surface-
    // specific context can additionally call `ghostty_surface_userdata`
    // on `target.surface` when target.tag = SURFACE.
    const host = hostFromApp(app) orelse {
        std.debug.print("ghostty action: no host context (init order bug?)\n", .{});
        return false;
    };
    inline for (action_table) |entry| {
        if (action.tag == entry.tag) return entry.handler(host, app, target, action);
    }
    // Unknown tag — surface to logs and treat as not-handled. Future
    // ghostty versions adding new tags will hit this branch.
    std.debug.print("ghostty action: unknown tag {d}\n", .{action.tag});
    return false;
}

/// Per-tag handler. Returns true if djinn handled the action, false to
/// let ghostty fall back to its default. Step-8 scope: every handler
/// is a no-op stub returning false — wiring lives here so callers
/// don't need to grow a 40-arm switch later.
const ActionHandler = *const fn (
    host: *HostContext,
    app: c.ghostty_app_t,
    target: c.ghostty_target_s,
    action: c.ghostty_action_s,
) bool;

const ActionEntry = struct {
    tag: c.ghostty_action_tag_e,
    name: []const u8,
    handler: ActionHandler,
};

/// Stub handler factory. The `name` is unused at runtime (action.tag
/// already carries the identity) but kept for `comptime`-side debug
/// printing if we want to log unhandled actions later.
fn stub(comptime _: []const u8) ActionHandler {
    return struct {
        fn h(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, _: c.ghostty_action_s) bool {
            return false;
        }
    }.h;
}

// ─── Real action handlers ───────────────────────────────────────────

/// dispatch a function onto the main queue. ghostty surface callbacks
/// can fire from its IO thread; AppKit calls require main.
extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
const c_dispatch = @cImport({
    @cInclude("dispatch/dispatch.h");
});

/// child_exited: shell exited (Ctrl+D EOF, `exit`, kill, etc).
/// Mark the owning session so the tab strip can reflect the dead-child
/// state, then return true to prevent ghostty from auto-closing the
/// surface. The host handles restart via Cmd+R / Cmd+Shift+R actions.
fn handleChildExited(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    if (host.app_state.session_manager) |sm| {
        if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
            for (sm.sessions.items) |*sess| {
                if (sess.surface) |sp| {
                    const surf: c.ghostty_surface_t = @ptrCast(sp);
                    if (surf == target.target.surface) {
                        sess.exited = true;
                        break;
                    }
                }
            }
        }
    }
    return true;
}

fn closePanelMain(ctx: ?*anyopaque) callconv(.c) void {
    if (ctx) |raw| {
        const panel_mod = @import("../window/panel.zig");
        const p: *panel_mod.Panel = @ptrCast(@alignCast(raw));
        if (p.visible) p.hide();
    }
}

/// ring_bell: audible side via afplay, visual side as a brief alpha
/// dim on the panel. Both are gated independently by config.
fn handleRingBell(host: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    const cfg = host.app_state.config orelse return false;

    // Active profile overrides override the global bell config so a
    // chatter profile (working Claude session) can stay silent while
    // an interactive shell still rings. Each field falls through
    // independently — a profile can mute audible but keep visual.
    const active_profile: ?@import("../session/manager.zig").Profile = blk: {
        const sm = host.app_state.session_manager orelse break :blk null;
        if (sm.sessions.items.len == 0) break :blk null;
        break :blk sm.active().profile;
    };

    const audible = if (active_profile) |p| p.bell_audible orelse cfg.bell.audible else cfg.bell.audible;
    const visual = if (active_profile) |p| p.bell_visual orelse cfg.bell.visual else cfg.bell.visual;
    const sound = if (active_profile) |p| (p.bell_sound orelse cfg.bell.sound) else cfg.bell.sound;

    if (audible) {
        const notify = @import("../notify/darwin.zig");
        const notifier = notify.Notifier{ .enabled = true };
        notifier.playSound(sound);
    }
    if (visual) {
        if (host.app_state.window.panel) |p| p.flashBell();
    }
    return true;
}

fn handleSearchTotal(host: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const total = action.action.search_total.total;
    host.app_state.find.total = if (total < 0) null else @intCast(total);
    @import("../terminal/find.zig").updateCountLabel();
    return true;
}

fn handleSearchSelected(host: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const sel = action.action.search_selected.selected;
    host.app_state.find.selected = if (sel < 0) null else @intCast(sel);
    @import("../terminal/find.zig").updateCountLabel();
    return true;
}

fn handleStartSearch(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    @import("../terminal/find.zig").openOverlayUiOnly();
    return true;
}

fn handleEndSearch(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    @import("../terminal/find.zig").closeOverlayUiOnly();
    return true;
}

/// open_url: NSWorkspace.openURL on the URL ghostty extracted from
/// the OSC 8 hyperlink under cursor (or other open-url action sources).
fn handleOpenUrl(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const u = action.action.open_url;
    if (u.url == null or u.len == 0) return false;
    const url_slice = u.url[0..u.len];
    openUrlInWorkspace(url_slice) catch return false;
    return true;
}

fn openUrlInWorkspace(url: []const u8) !void {
    const objc = @import("objc");
    const NSString = objc.getClass("NSString") orelse return error.NoNSString;
    const NSURL = objc.getClass("NSURL") orelse return error.NoNSURL;
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return error.NoNSWorkspace;

    var buf: [4096]u8 = undefined;
    if (url.len >= buf.len) return error.UrlTooLong;
    @memcpy(buf[0..url.len], url);
    buf[url.len] = 0;

    const ns_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(&buf[0]))});
    if (ns_str.value == null) return error.NoString;
    const ns_url = NSURL.msgSend(objc.Object, "URLWithString:", .{ns_str});
    if (ns_url.value == null) return error.NoURL;
    const ws = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    _ = ws.msgSend(bool, "openURL:", .{ns_url});
}

/// desktop_notification: OSC 9 / OSC 777 forward — surface emits a
/// title + body pair when the shell or a TUI requests an OS-level
/// notification. Route through Notifier.send (NSUserNotification).
/// Notifier already marshals onto main queue.
fn handleDesktopNotification(host: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const n = action.action.desktop_notification;
    const notifier = host.app_state.notifier orelse return false;
    const title = if (n.title) |t| std.mem.span(t) else "";
    const body = if (n.body) |b| std.mem.span(b) else "";
    if (title.len == 0 and body.len == 0) return false;
    notifier.send(title, body);
    return true;
}

/// NSCursor class method dispatch — load a named cursor class method
/// and call `set` on it. AppKit's NSCursor exposes one class method
/// per shape (e.g. `+IBeamCursor`, `+pointingHandCursor`). Falls back
/// to arrowCursor if the requested selector isn't recognized at
/// runtime (older macOS lacks some shapes).
fn setNSCursor(selector: [:0]const u8) void {
    const objc = @import("objc");
    const NSCursor = objc.getClass("NSCursor") orelse return;
    // class method that returns +cursor
    const cls_obj = NSCursor.msgSend(objc.Object, selector, .{});
    if (cls_obj.value == null) {
        const fallback = NSCursor.msgSend(objc.Object, "arrowCursor", .{});
        if (fallback.value != null) fallback.msgSend(void, "set", .{});
        return;
    }
    cls_obj.msgSend(void, "set", .{});
}

/// mouse_shape: ghostty hands the desired cursor (text I-beam, pointing
/// hand on link hover, resize cursors for splits, …). Map to the AppKit
/// equivalent via the NSCursor class methods. Unhandled shapes fall
/// back to the arrow cursor inside setNSCursor.
fn handleMouseShape(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const shape = action.action.mouse_shape;
    const sel: [:0]const u8 = switch (shape) {
        c.GHOSTTY_MOUSE_SHAPE_TEXT, c.GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT => "IBeamCursor",
        c.GHOSTTY_MOUSE_SHAPE_POINTER => "pointingHandCursor",
        c.GHOSTTY_MOUSE_SHAPE_CROSSHAIR => "crosshairCursor",
        c.GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, c.GHOSTTY_MOUSE_SHAPE_NO_DROP => "operationNotAllowedCursor",
        c.GHOSTTY_MOUSE_SHAPE_GRAB => "openHandCursor",
        c.GHOSTTY_MOUSE_SHAPE_GRABBING => "closedHandCursor",
        c.GHOSTTY_MOUSE_SHAPE_COL_RESIZE, c.GHOSTTY_MOUSE_SHAPE_E_RESIZE, c.GHOSTTY_MOUSE_SHAPE_W_RESIZE, c.GHOSTTY_MOUSE_SHAPE_EW_RESIZE => "resizeLeftRightCursor",
        c.GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, c.GHOSTTY_MOUSE_SHAPE_N_RESIZE, c.GHOSTTY_MOUSE_SHAPE_S_RESIZE, c.GHOSTTY_MOUSE_SHAPE_NS_RESIZE => "resizeUpDownCursor",
        c.GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU => "contextualMenuCursor",
        c.GHOSTTY_MOUSE_SHAPE_COPY => "dragCopyCursor",
        c.GHOSTTY_MOUSE_SHAPE_ALIAS => "dragLinkCursor",
        else => "arrowCursor",
    };
    setNSCursor(sel);
    return true;
}

/// mouse_visibility: TUI requested cursor hide / unhide (e.g. video
/// playback inside terminal). NSCursor's hide/unhide stack is
/// reference-counted; pair calls one-for-one.
fn handleMouseVisibility(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const objc = @import("objc");
    const NSCursor = objc.getClass("NSCursor") orelse return false;
    switch (action.action.mouse_visibility) {
        c.GHOSTTY_MOUSE_HIDDEN => NSCursor.msgSend(void, "hide", .{}),
        c.GHOSTTY_MOUSE_VISIBLE => NSCursor.msgSend(void, "unhide", .{}),
        else => return false,
    }
    return true;
}

/// mouse_over_link: surface tells us the cursor sits on (or left) an
/// OSC 8 hyperlink. Show a pointing hand on enter, restore the I-beam
/// on leave. Existing CG/Metal backend has its own Cmd-hover path —
/// that one stays live for non-surface backends.
fn handleMouseOverLink(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const link = action.action.mouse_over_link;
    if (link.url != null and link.len > 0) {
        setNSCursor("pointingHandCursor");
    } else {
        setNSCursor("IBeamCursor");
    }
    return true;
}

/// secure_input: lock keystrokes against keyloggers / screen readers.
/// EnableSecureEventInput is reference-counted (pair Enable/Disable) —
/// ghostty's three-state enum maps cleanly because it never re-asserts
/// the same state.
extern "c" fn EnableSecureEventInput() void;
extern "c" fn DisableSecureEventInput() void;
extern "c" fn IsSecureEventInputEnabled() bool;

fn handleSecureInput(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    switch (action.action.secure_input) {
        c.GHOSTTY_SECURE_INPUT_ON => EnableSecureEventInput(),
        c.GHOSTTY_SECURE_INPUT_OFF => DisableSecureEventInput(),
        c.GHOSTTY_SECURE_INPUT_TOGGLE => {
            if (IsSecureEventInputEnabled()) DisableSecureEventInput() else EnableSecureEventInput();
        },
        else => return false,
    }
    return true;
}

/// pwd: surface reports the shell's current working directory (OSC 7
/// `file://host/path` typically). Logged for now — once prompt-marker
/// integration lands we'll persist the latest cwd onto AppState.
fn handlePwd(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const p = action.action.pwd;
    if (p.pwd) |pwd| {
        std.debug.print("ghostty pwd: {s}\n", .{std.mem.span(pwd)});
        return true;
    }
    return false;
}

/// set_title: surface emitted OSC 0 / OSC 2. Our panel is borderless
/// (LSUIElement, no titlebar) so there's no NSWindow title surface to
/// paint. Logged + acknowledged so ghostty doesn't fall back to its
/// default path.
fn handleSetTitle(_: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const t = action.action.set_title;
    if (t.title) |title| {
        std.debug.print("ghostty set_title: {s}\n", .{std.mem.span(title)});
        return true;
    }
    return false;
}

/// Dispatch table covering every `ghostty_action_tag_e` value as of the
/// vendored ghostty.h. Each entry is `{ tag, name, handler }`. Step 8
/// fills handlers in-place — no caller change needed.
///
/// Order mirrors ghostty.h so a diff against an upstream bump is
/// trivial. `name` is only used for log lines; tag is what dispatch
/// actually compares.
const action_table = [_]ActionEntry{
    .{ .tag = c.GHOSTTY_ACTION_QUIT, .name = "quit", .handler = stub("quit") },
    .{ .tag = c.GHOSTTY_ACTION_NEW_WINDOW, .name = "new_window", .handler = stub("new_window") },
    .{ .tag = c.GHOSTTY_ACTION_NEW_TAB, .name = "new_tab", .handler = stub("new_tab") },
    .{ .tag = c.GHOSTTY_ACTION_CLOSE_TAB, .name = "close_tab", .handler = stub("close_tab") },
    .{ .tag = c.GHOSTTY_ACTION_NEW_SPLIT, .name = "new_split", .handler = stub("new_split") },
    .{ .tag = c.GHOSTTY_ACTION_CLOSE_ALL_WINDOWS, .name = "close_all_windows", .handler = stub("close_all_windows") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_MAXIMIZE, .name = "toggle_maximize", .handler = stub("toggle_maximize") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_FULLSCREEN, .name = "toggle_fullscreen", .handler = stub("toggle_fullscreen") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW, .name = "toggle_tab_overview", .handler = stub("toggle_tab_overview") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS, .name = "toggle_window_decorations", .handler = stub("toggle_window_decorations") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL, .name = "toggle_quick_terminal", .handler = stub("toggle_quick_terminal") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE, .name = "toggle_command_palette", .handler = stub("toggle_command_palette") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_VISIBILITY, .name = "toggle_visibility", .handler = stub("toggle_visibility") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY, .name = "toggle_background_opacity", .handler = stub("toggle_background_opacity") },
    .{ .tag = c.GHOSTTY_ACTION_MOVE_TAB, .name = "move_tab", .handler = stub("move_tab") },
    .{ .tag = c.GHOSTTY_ACTION_GOTO_TAB, .name = "goto_tab", .handler = stub("goto_tab") },
    .{ .tag = c.GHOSTTY_ACTION_GOTO_SPLIT, .name = "goto_split", .handler = stub("goto_split") },
    .{ .tag = c.GHOSTTY_ACTION_GOTO_WINDOW, .name = "goto_window", .handler = stub("goto_window") },
    .{ .tag = c.GHOSTTY_ACTION_RESIZE_SPLIT, .name = "resize_split", .handler = stub("resize_split") },
    .{ .tag = c.GHOSTTY_ACTION_EQUALIZE_SPLITS, .name = "equalize_splits", .handler = stub("equalize_splits") },
    .{ .tag = c.GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM, .name = "toggle_split_zoom", .handler = stub("toggle_split_zoom") },
    .{ .tag = c.GHOSTTY_ACTION_PRESENT_TERMINAL, .name = "present_terminal", .handler = stub("present_terminal") },
    .{ .tag = c.GHOSTTY_ACTION_SIZE_LIMIT, .name = "size_limit", .handler = stub("size_limit") },
    .{ .tag = c.GHOSTTY_ACTION_RESET_WINDOW_SIZE, .name = "reset_window_size", .handler = stub("reset_window_size") },
    .{ .tag = c.GHOSTTY_ACTION_INITIAL_SIZE, .name = "initial_size", .handler = stub("initial_size") },
    .{ .tag = c.GHOSTTY_ACTION_CELL_SIZE, .name = "cell_size", .handler = stub("cell_size") },
    .{ .tag = c.GHOSTTY_ACTION_SCROLLBAR, .name = "scrollbar", .handler = stub("scrollbar") },
    .{ .tag = c.GHOSTTY_ACTION_RENDER, .name = "render", .handler = stub("render") },
    .{ .tag = c.GHOSTTY_ACTION_INSPECTOR, .name = "inspector", .handler = stub("inspector") },
    .{ .tag = c.GHOSTTY_ACTION_SHOW_GTK_INSPECTOR, .name = "show_gtk_inspector", .handler = stub("show_gtk_inspector") },
    .{ .tag = c.GHOSTTY_ACTION_RENDER_INSPECTOR, .name = "render_inspector", .handler = stub("render_inspector") },
    .{ .tag = c.GHOSTTY_ACTION_DESKTOP_NOTIFICATION, .name = "desktop_notification", .handler = handleDesktopNotification },
    .{ .tag = c.GHOSTTY_ACTION_SET_TITLE, .name = "set_title", .handler = handleSetTitle },
    .{ .tag = c.GHOSTTY_ACTION_SET_TAB_TITLE, .name = "set_tab_title", .handler = handleSetTitle },
    .{ .tag = c.GHOSTTY_ACTION_PROMPT_TITLE, .name = "prompt_title", .handler = stub("prompt_title") },
    .{ .tag = c.GHOSTTY_ACTION_PWD, .name = "pwd", .handler = handlePwd },
    .{ .tag = c.GHOSTTY_ACTION_MOUSE_SHAPE, .name = "mouse_shape", .handler = handleMouseShape },
    .{ .tag = c.GHOSTTY_ACTION_MOUSE_VISIBILITY, .name = "mouse_visibility", .handler = handleMouseVisibility },
    .{ .tag = c.GHOSTTY_ACTION_MOUSE_OVER_LINK, .name = "mouse_over_link", .handler = handleMouseOverLink },
    .{ .tag = c.GHOSTTY_ACTION_RENDERER_HEALTH, .name = "renderer_health", .handler = stub("renderer_health") },
    .{ .tag = c.GHOSTTY_ACTION_OPEN_CONFIG, .name = "open_config", .handler = stub("open_config") },
    .{ .tag = c.GHOSTTY_ACTION_QUIT_TIMER, .name = "quit_timer", .handler = stub("quit_timer") },
    .{ .tag = c.GHOSTTY_ACTION_FLOAT_WINDOW, .name = "float_window", .handler = stub("float_window") },
    .{ .tag = c.GHOSTTY_ACTION_SECURE_INPUT, .name = "secure_input", .handler = handleSecureInput },
    .{ .tag = c.GHOSTTY_ACTION_KEY_SEQUENCE, .name = "key_sequence", .handler = stub("key_sequence") },
    .{ .tag = c.GHOSTTY_ACTION_KEY_TABLE, .name = "key_table", .handler = stub("key_table") },
    .{ .tag = c.GHOSTTY_ACTION_COLOR_CHANGE, .name = "color_change", .handler = stub("color_change") },
    .{ .tag = c.GHOSTTY_ACTION_RELOAD_CONFIG, .name = "reload_config", .handler = stub("reload_config") },
    .{ .tag = c.GHOSTTY_ACTION_CONFIG_CHANGE, .name = "config_change", .handler = stub("config_change") },
    .{ .tag = c.GHOSTTY_ACTION_CLOSE_WINDOW, .name = "close_window", .handler = stub("close_window") },
    .{ .tag = c.GHOSTTY_ACTION_RING_BELL, .name = "ring_bell", .handler = handleRingBell },
    .{ .tag = c.GHOSTTY_ACTION_UNDO, .name = "undo", .handler = stub("undo") },
    .{ .tag = c.GHOSTTY_ACTION_REDO, .name = "redo", .handler = stub("redo") },
    .{ .tag = c.GHOSTTY_ACTION_CHECK_FOR_UPDATES, .name = "check_for_updates", .handler = stub("check_for_updates") },
    .{ .tag = c.GHOSTTY_ACTION_OPEN_URL, .name = "open_url", .handler = handleOpenUrl },
    .{ .tag = c.GHOSTTY_ACTION_SHOW_CHILD_EXITED, .name = "show_child_exited", .handler = handleChildExited },
    .{ .tag = c.GHOSTTY_ACTION_PROGRESS_REPORT, .name = "progress_report", .handler = stub("progress_report") },
    .{ .tag = c.GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD, .name = "show_on_screen_keyboard", .handler = stub("show_on_screen_keyboard") },
    .{ .tag = c.GHOSTTY_ACTION_COMMAND_FINISHED, .name = "command_finished", .handler = stub("command_finished") },
    .{ .tag = c.GHOSTTY_ACTION_START_SEARCH, .name = "start_search", .handler = handleStartSearch },
    .{ .tag = c.GHOSTTY_ACTION_END_SEARCH, .name = "end_search", .handler = handleEndSearch },
    .{ .tag = c.GHOSTTY_ACTION_SEARCH_TOTAL, .name = "search_total", .handler = handleSearchTotal },
    .{ .tag = c.GHOSTTY_ACTION_SEARCH_SELECTED, .name = "search_selected", .handler = handleSearchSelected },
    .{ .tag = c.GHOSTTY_ACTION_READONLY, .name = "readonly", .handler = stub("readonly") },
    .{ .tag = c.GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD, .name = "copy_title_to_clipboard", .handler = stub("copy_title_to_clipboard") },
};

/// Surface fired `paste_from_clipboard` (or OSC 52 read). Pull the
/// general pasteboard's text and hand it back via
/// `ghostty_surface_complete_clipboard_request`. Cmd+V on the host
/// short-circuits this path (pasteFromClipboard in view.zig writes
/// directly to the surface), but ghostty-side bindings + OSC 52 reads
/// still come through here.
fn readClipboardImpl(
    userdata: ?*anyopaque,
    clipboard: c.ghostty_clipboard_e,
    state: ?*anyopaque,
) callconv(.c) bool {
    _ = clipboard;
    const surf_ptr = host_storage.app_state.ghostty.surface orelse return false;
    _ = userdata;
    const surf: c.ghostty_surface_t = @ptrCast(surf_ptr);

    const objc = @import("objc");
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return false;
    const NSString = objc.getClass("NSString") orelse return false;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    const type_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.utf8-plain-text")});
    const ns_str = pb.msgSend(objc.Object, "stringForType:", .{type_str});
    if (ns_str.value == null) return false;
    const utf8 = ns_str.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8 == null) return false;
    c.ghostty_surface_complete_clipboard_request(surf, utf8, state, true);
    return true;
}

fn confirmReadClipboardStub(
    userdata: ?*anyopaque,
    text: [*c]const u8,
    state: ?*anyopaque,
    request: c.ghostty_clipboard_request_e,
) callconv(.c) void {
    _ = userdata;
    _ = text;
    _ = state;
    _ = request;
}

/// Surface fired `copy_to_clipboard` (or OSC 52 write). Iterate the
/// content array and push each `text/plain` entry to the macOS general
/// pasteboard. ghostty.app additionally gates OSC 52 writes behind a
/// confirmation dialog when `confirm=true`; we just write through for
/// now — Quake-drop UX, single user, no shared X11-style selection
/// pasteboard to worry about. `clipboard=SELECTION` (Linux primary
/// selection) collapses onto the general pasteboard on macOS.
fn writeClipboardImpl(
    userdata: ?*anyopaque,
    clipboard: c.ghostty_clipboard_e,
    contents: [*c]const c.ghostty_clipboard_content_s,
    contents_len: usize,
    confirm: bool,
) callconv(.c) void {
    _ = userdata;
    _ = clipboard;
    _ = confirm;
    if (contents_len == 0) return;

    const objc = @import("objc");
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    _ = pb.msgSend(c_long, "clearContents", .{});

    var wrote_any = false;
    var i: usize = 0;
    while (i < contents_len) : (i += 1) {
        const entry = contents[i];
        if (entry.mime == null or entry.data == null) continue;
        const mime = std.mem.sliceTo(entry.mime, 0);
        // text/plain → NSPasteboardTypeString. Other mime types (HTML,
        // image) ghostty doesn't currently emit; ignore until needed.
        if (!std.mem.eql(u8, mime, "text/plain")) continue;

        const data_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{entry.data});
        const type_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.utf8-plain-text")});
        _ = pb.msgSend(c_long, "setString:forType:", .{ data_str, type_str });
        wrote_any = true;
    }
    if (!wrote_any) return;
}

fn closeSurfaceStub(userdata: ?*anyopaque, _: bool) callconv(.c) void {
    // Surface requested close — only fires for paths NOT suppressed by
    // handleChildExited (returning true there short-circuits this).
    // Reaches here on app shutdown / forced close. Hide the panel;
    // per-session `exited` state is owned by handleChildExited where
    // target.surface lets us identify the right session.
    const host = hostFromUserdata(userdata) orelse return;
    if (host.app_state.window.panel) |p| {
        dispatch_async_f(@ptrCast(c_dispatch.dispatch_get_main_queue()), p, &closePanelMain);
    }
}
