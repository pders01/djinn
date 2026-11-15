//! Native host bridge for the pinned libghostty embedding API.

const std = @import("std");
const app_mod = @import("../app.zig");
const Session = @import("../session/manager.zig").Session;
const platform = @import("../io/platform.zig");

pub const c = @import("darwin-c");

/// App callbacks use HostContext; surface callbacks use a stable Session pointer.
pub const HostContext = struct {
    /// Backreference to the global AppState (`&app.g`). Action handlers
    /// pull terminal, panel, and configuration state from here.
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

/// Host-owned references only. Never infer ownership from process-global OS
/// state: another component may also hold Secure Input or a cursor hide.
const HostInputState = struct {
    secure: bool = false,
    cursor_hidden: bool = false,
    cursor_selector: ?[:0]const u8 = null,
};
var host_input: HostInputState = .{};

fn inputStateForSession(source: ?*const Session) HostInputState {
    const session = source orelse return .{};
    if (session.surface == null or !session.surface_focused or !session.surface_visible) return .{};
    return .{
        .secure = session.requested_secure_input,
        .cursor_hidden = session.requested_cursor_hidden,
        .cursor_selector = if (session.mouse_over_link) "pointingHandCursor" else session.requested_cursor_shape,
    };
}

fn sameCursor(a: ?[:0]const u8, b: ?[:0]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const HostInputChanges = struct {
    secure: ?bool,
    cursor_hidden: ?bool,
    cursor_shape: bool,
};

fn inputChanges(current: HostInputState, next: HostInputState) HostInputChanges {
    return .{
        .secure = if (current.secure != next.secure) next.secure else null,
        .cursor_hidden = if (current.cursor_hidden != next.cursor_hidden) next.cursor_hidden else null,
        .cursor_shape = !sameCursor(current.cursor_selector, next.cursor_selector),
    };
}

fn applyHostInput(next: HostInputState) void {
    const changes = inputChanges(host_input, next);
    if (changes.secure) |enabled| {
        const status = if (enabled) EnableSecureEventInput() else DisableSecureEventInput();
        if (status == 0) {
            host_input.secure = enabled;
        } else {
            std.debug.print("warning: cannot {s} Secure Event Input (OSStatus {d})\n", .{ if (enabled) "enable" else "disable", status });
        }
    }
    if (changes.cursor_hidden) |hidden| {
        const objc = @import("objc");
        if (objc.getClass("NSCursor")) |cursor| {
            if (hidden) cursor.msgSend(void, "hide", .{}) else cursor.msgSend(void, "unhide", .{});
            host_input.cursor_hidden = hidden;
        }
    }
    if (changes.cursor_shape) {
        setNSCursor(next.cursor_selector orelse "arrowCursor");
        host_input.cursor_selector = next.cursor_selector;
    }
}

fn reconcileHostInput() void {
    if (!host_inited) return;
    const sm = host_storage.app_state.session_manager orelse {
        applyHostInput(.{});
        return;
    };
    applyHostInput(inputStateForSession(sm.active()));
}

/// Release this incarnation's requests BEFORE clearing its source pointer.
/// Later destruction callbacks cannot acquire a new host-owned reference.
pub fn releaseSessionInput(session: *Session) void {
    clearSessionInput(session);
    reconcileHostInput();
}

fn clearSessionInput(session: *Session) void {
    session.surface_focused = false;
    session.surface_visible = false;
    session.requested_secure_input = false;
    session.requested_cursor_hidden = false;
    session.requested_cursor_shape = "IBeamCursor";
    session.mouse_over_link = false;
}

/// Only synchronous construction-time title callbacks may use this fallback.
/// Pinned embedded.Surface.init installs userdata before core_surface.init.
const PendingConstruction = struct {
    session: *Session,
    generation: u64,

    fn matches(self: PendingConstruction, sessions: []Session, userdata: ?*anyopaque) ?*Session {
        for (sessions) |*session| {
            if (session == self.session and userdata == @as(*anyopaque, @ptrCast(session)) and
                session.surface == null and session.surface_generation == self.generation) return session;
        }
        return null;
    }
};
var pending_construction: ?PendingConstruction = null;

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
    if (ud != @as(*anyopaque, @ptrCast(&host_storage))) return null;
    return &host_storage;
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
/// surface for it to take effect. Ghostty 1.4 also initializes both scrollback
/// caps when constructing Termio: new/lazy/restarted surfaces pick up a changed
/// line cap, but existing surfaces retain their original cap. Its independent
/// scrollback-limit-bytes (50 MB by default) can evict history before the line cap.
pub fn reloadConfigFromDisk() void {
    if (!host_inited) return;
    const app_handle = host_storage.app_handle orelse return;
    const new_cfg = c.ghostty_config_new() orelse return;
    const scrollback = if (host_storage.app_state.config) |cfg| cfg.scrollback.size else null;
    loadConfigFiles(new_cfg, scrollback) catch {
        c.ghostty_config_free(new_cfg);
        return;
    };
    c.ghostty_config_finalize(new_cfg);
    c.ghostty_app_update_config(app_handle, new_cfg);
    if (host_storage.app_state.session_manager) |sm| {
        for (sm.sessions.items) |session| {
            if (session.surface) |sp| c.ghostty_surface_update_config(@ptrCast(sp), new_cfg);
        }
    }
    if (host_storage.app_state.ghostty.config) |old| {
        c.ghostty_config_free(@ptrCast(old));
    }
    host_storage.app_state.ghostty.config = @ptrCast(new_cfg);
    if (host_storage.app_state.ghostty.app) |app| app.config = new_cfg;
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
    const home = platform.getenv("HOME") orelse return null;
    const cfg_path = std.fmt.allocPrint(allocator, "{s}/.config/ghostty/config", .{home}) catch return null;
    defer allocator.free(cfg_path);

    const file = std.Io.Dir.openFileAbsolute(platform.io(), cfg_path, .{}) catch return null;
    defer file.close(platform.io());
    var reader = file.reader(platform.io(), &.{});
    const contents = reader.interface.allocRemaining(allocator, .limited(256 * 1024)) catch return null;
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

    // Detect appearance: prefer the runtime override (`Cmd+Shift+T`
    // cycle stored in `app.g.theme.override`), fall back to the
    // NSAppearance system probe. Without the override branch, the
    // theme override action would set internal djinn state but the
    // ghostty config reload would still pick the system variant on
    // every reload — leaving the visible theme stuck on system
    // appearance even after the user explicitly overrode it.
    const dark: bool = blk: {
        const app = @import("../app.zig");
        if (app.g.theme.override) |ov| break :blk (ov == .dark);
        break :blk detectDarkAppearance();
    };
    const picked = pickThemeVariant(spec, dark) orelse return null;

    // Write the override to a tmp file. Path is process-lifetime; the
    // file persists until exit (small text file, ~30 bytes — not worth
    // a cleanup hook).
    const tmpdir = platform.getenv("TMPDIR") orelse "/tmp";
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/djinn-theme-{x}.conf", .{ tmpdir, temporaryFileNonce() }) catch return null;
    const out = std.Io.Dir.createFileAbsolute(platform.io(), tmp_path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch {
        allocator.free(tmp_path);
        return null;
    };
    defer out.close(platform.io());
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "theme = {s}\n", .{picked}) catch {
        allocator.free(tmp_path);
        return null;
    };
    out.writeStreamingAll(platform.io(), line) catch {
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
    const allocator = std.heap.page_allocator;
    const config = if (host_inited) host_storage.app_state.config else null;
    const tmpdir = platform.getenv("TMPDIR") orelse "/tmp";
    const path = std.fmt.allocPrint(allocator, "{s}/djinn-ghostty-{x}.conf", .{ tmpdir, temporaryFileNonce() }) catch return null;
    const file = std.Io.Dir.createFileAbsolute(platform.io(), path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch {
        allocator.free(path);
        return null;
    };
    defer file.close(platform.io());
    var success = false;
    defer if (!success) {
        std.Io.Dir.deleteFileAbsolute(platform.io(), path) catch {};
        allocator.free(path);
    };
    var scrollback_buf: [96]u8 = undefined;
    const scrollback_text = formatScrollbackOverride(&scrollback_buf, scrollback_limit) catch return null;
    file.writeStreamingAll(platform.io(), scrollback_text) catch return null;
    if (config) |cfg| {
        const Entry = struct { key: []const u8, value: ?[]const u8 };
        for ([_]Entry{
            .{ .key = "font-family", .value = cfg.terminal.font_family },
            .{ .key = "background", .value = cfg.theme.background },
            .{ .key = "foreground", .value = cfg.theme.foreground },
            .{ .key = "cursor-color", .value = cfg.theme.cursor },
        }) |entry| {
            if (entry.value) |value| {
                file.writeStreamingAll(platform.io(), entry.key) catch return null;
                file.writeStreamingAll(platform.io(), " = ") catch return null;
                file.writeStreamingAll(platform.io(), value) catch return null;
                file.writeStreamingAll(platform.io(), "\n") catch return null;
            }
        }
        if (cfg.terminal.font_size) |value| writeNumericOverride(file, "font-size", value) catch return null;
        if (cfg.terminal.padding_x) |value| writeNumericOverride(file, "window-padding-x", value) catch return null;
        if (cfg.terminal.padding_y) |value| writeNumericOverride(file, "window-padding-y", value) catch return null;
        if (cfg.theme.opacity) |value| writeNumericOverride(file, "background-opacity", value) catch return null;
    }
    success = true;
    return path;
}

fn loadConfigFiles(cfg: c.ghostty_config_t, scrollback: ?u32) !void {
    const allocator = std.heap.page_allocator;
    const inherit = if (host_inited) blk: {
        const host_cfg = host_storage.app_state.config orelse break :blk true;
        break :blk host_cfg.theme.inherit_ghostty;
    } else true;
    if (inherit) {
        c.ghostty_config_load_default_files(cfg);
        if (writeAppearanceThemeOverride()) |path| {
            defer allocator.free(path);
            defer std.Io.Dir.deleteFileAbsolute(platform.io(), path) catch {};
            const z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(z);
            c.ghostty_config_load_file(cfg, z.ptr);
        }
    }
    if (writeDjinnGhosttyOverride(scrollback)) |path| {
        defer allocator.free(path);
        defer std.Io.Dir.deleteFileAbsolute(platform.io(), path) catch {};
        const z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(z);
        c.ghostty_config_load_file(cfg, z.ptr);
    }
}

fn temporaryFileNonce() u64 {
    var nonce: u64 = undefined;
    platform.io().random(std.mem.asBytes(&nonce));
    return nonce;
}

/// Ghostty 1.4's legacy scrollback-limit alias is BYTES, never lines.
/// Omission preserves inherited/default line AND byte caps; zero disables
/// retained scrollback. Do not override the independent byte cap here.
fn formatScrollbackOverride(buffer: []u8, lines: ?u32) ![]const u8 {
    const limit = lines orelse return "";
    return std.fmt.bufPrint(buffer, "scrollback-limit-lines = {d}\n", .{limit});
}

test "scrollback override omits unset and writes zero or positive as lines only" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("", try formatScrollbackOverride(&buffer, null));
    try std.testing.expectEqualStrings("scrollback-limit-lines = 0\n", try formatScrollbackOverride(&buffer, 0));
    try std.testing.expectEqualStrings("scrollback-limit-lines = 100000\n", try formatScrollbackOverride(&buffer, 100000));
}

fn writeNumericOverride(file: std.Io.File, key: []const u8, value: anytype) !void {
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{s} = {d}\n", .{ key, value });
    try file.writeStreamingAll(platform.io(), text);
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
/// `ghostty_app_new` / `ghostty_surface_new` call. Spins up Ghostty's
/// allocator/logging/state with the process-lifetime Darwin argument vector.
/// Zig no longer exposes std.os.argv; these libc accessors borrow the same
/// original arguments without allocating or transferring their ownership.
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*:null]?[*:0]u8;

pub fn init() !void {
    configureResources();
    const rc = c.ghostty_init(@intCast(_NSGetArgc().*), @ptrCast(_NSGetArgv().*));
    if (rc != 0) {
        std.debug.print("ghostty_init failed (rc={d})\n", .{rc});
        return error.GhosttyInitFailed;
    }
    std.debug.print("ghostty_init OK (libghostty surface API ready)\n", .{});
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Prefer our own resources over a GHOSTTY_RESOURCES_DIR inherited from the
/// launching terminal. This works for both .app and zig-out/bin layouts.
fn configureResources() void {
    const allocator = std.heap.page_allocator;
    const exe = platform.executablePathAlloc(allocator) catch return;
    defer allocator.free(exe);
    const directory = std.fs.path.dirname(exe) orelse return;
    for ([_][]const u8{ "../Resources", "../share" }) |relative| {
        const root = std.fs.path.resolve(allocator, &.{ directory, relative }) catch continue;
        defer allocator.free(root);
        const sentinel = std.fs.path.join(allocator, &.{ root, "terminfo", "78", "xterm-ghostty" }) catch continue;
        defer allocator.free(sentinel);
        std.Io.Dir.accessAbsolute(platform.io(), sentinel, .{}) catch continue;
        const resources = std.fs.path.joinZ(allocator, &.{ root, "ghostty" }) catch continue;
        defer allocator.free(resources);
        _ = setenv("GHOSTTY_RESOURCES_DIR", resources.ptr, 1);
        return;
    }
}

/// Owns a `ghostty_app_t` plus its config. The pinned embedded App copies
/// runtime options by value; callback userdata (not this struct) must outlive it.
pub const App = struct {
    handle: c.ghostty_app_t,
    config: c.ghostty_config_t,
    /// Retained for introspection; Ghostty copies these options by value.
    runtime_cfg: c.ghostty_runtime_config_s,

    /// Load terminal configuration and instantiate the embedded app.
    pub fn init(scrollback_limit: ?u32) ?App {
        const cfg = c.ghostty_config_new() orelse {
            std.debug.print("ghostty_app: config_new returned null\n", .{});
            return null;
        };
        loadConfigFiles(cfg, scrollback_limit) catch {
            c.ghostty_config_free(cfg);
            return null;
        };

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

        std.debug.print("ghostty_app_new OK\n", .{});

        return .{
            .handle = app_handle,
            .config = cfg,
            .runtime_cfg = rt_cfg,
        };
    }

    pub fn deinit(self: *App) void {
        // Queued wakeups resolve the live handle on main, never a captured
        // pointer that may outlive this owner. Clear it before native teardown.
        if (host_inited and host_storage.app_handle == self.handle) host_storage.app_handle = null;
        applyHostInput(.{});
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
        session: *Session,
    ) ?c.ghostty_surface_t {
        var opts = c.ghostty_surface_config_new();
        opts.platform_tag = c.GHOSTTY_PLATFORM_MACOS;
        opts.platform.macos = .{ .nsview = nsview };
        opts.scale_factor = scale;
        opts.context = c.GHOSTTY_SURFACE_CONTEXT_WINDOW;
        // The pinned API forces wait-after-command for every explicit
        // command (false cannot override it). Keep its exit/error output and
        // native press-any-key-to-close semantics; never force-close it here.
        // A null command inherits Ghostty's ordinary shell/config policy.
        opts.wait_after_command = command != null;
        // The static session array never reallocates. Userdata remains valid
        // until all its surfaces have been destroyed at shutdown.
        opts.userdata = session;
        // Null command delegates to Ghostty; explicit commands are unchanged.
        if (command) |cmd| opts.command = cmd;
        if (working_directory) |wd| opts.working_directory = wd;

        std.debug.assert(pending_construction == null);
        pending_construction = .{ .session = session, .generation = session.surface_generation };
        defer pending_construction = null;
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

// ─── Surface lifecycle ───────────────────────────────────
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
    if (host_inited) {
        if (host_storage.app_state.session_manager) |sm| {
            if (sessionForSurface(sm.sessions.items, @ptrCast(surface))) |session| session.surface_focused = focused;
        }
    }
    reconcileHostInput();
    c.ghostty_surface_set_focus(surface, focused);
}

/// Tell the surface whether it's currently visible. ghostty uses this
/// to throttle CADisplayLink + skip cursor blink work when the surface
/// is fully occluded — e.g. while the Quake panel is slid offscreen.
pub fn surfaceSetOcclusion(surface: c.ghostty_surface_t, visible: bool) void {
    if (host_inited) {
        if (host_storage.app_state.session_manager) |sm| {
            if (sessionForSurface(sm.sessions.items, @ptrCast(surface))) |session| session.surface_visible = visible;
        }
    }
    reconcileHostInput();
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

/// Validate callback userdata before dereferencing it. Profile membership is
/// fixed for the application's lifetime, including during config reload.
fn sessionFromUserdata(ud: ?*anyopaque) ?*Session {
    const raw = ud orelse return null;
    if (!host_inited) return null;
    const sm = host_storage.app_state.session_manager orelse return null;
    for (sm.sessions.items) |*session| {
        if (@as(*anyopaque, @ptrCast(session)) == raw and session.surface != null) return session;
    }
    return null;
}

fn sessionFromTarget(host: *HostContext, target: c.ghostty_target_s) ?*Session {
    if (target.tag != c.GHOSTTY_TARGET_SURFACE) return null;
    const sm = host.app_state.session_manager orelse return null;
    return sessionForSurface(sm.sessions.items, @ptrCast(target.target.surface));
}

fn sessionForSurface(sessions: []Session, surface: ?*anyopaque) ?*Session {
    const handle = surface orelse return null;
    for (sessions) |*session| {
        if (session.surface == handle) return session;
    }
    return null;
}

fn isActiveTarget(host: *HostContext, target: c.ghostty_target_s) bool {
    const session = sessionFromTarget(host, target) orelse return false;
    const sm = host.app_state.session_manager orelse return false;
    return sm.active().id == session.id;
}

/// ghostty's IO thread pokes us via wakeup_cb whenever it has work for
/// the main thread to process: mailbox messages (child_exited,
/// renderer health, OSC actions), surface state changes, etc. We have
/// to call ghostty_app_tick on main to drain. Without this the surface
/// never fires actions or close callbacks.
fn wakeupStub(_: ?*anyopaque) callconv(.c) void {
    // This callback may run on an IO thread. Do not read mutable host state
    // here or retain a raw app handle across the asynchronous boundary.
    dispatch_async_f(@ptrCast(c_dispatch.dispatch_get_main_queue()), null, &tickAppMain);
}

fn tickAppMain(_: ?*anyopaque) callconv(.c) void {
    if (!host_inited) return;
    const handle = host_storage.app_handle orelse return;
    c.ghostty_app_tick(handle);
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
    // Window managers, splits, progress UI, and other unsupported
    // embedding actions are intentionally outside this host's scope.
    return false;
}

/// Supported embedding actions; everything else is left unhandled.
const ActionHandler = *const fn (
    host: *HostContext,
    app: c.ghostty_app_t,
    target: c.ghostty_target_s,
    action: c.ghostty_action_s,
) bool;

const ActionEntry = struct {
    tag: c.ghostty_action_tag_e,
    handler: ActionHandler,
};

// ─── Real action handlers ───────────────────────────────────────────

/// Dispatch known IO-thread wakeups and deferred lifecycle work onto main.
/// All other native surface callbacks run on main.
extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
const c_dispatch = c;

/// Record the source session's exit without pretending to show a native dialog.
fn handleChildExited(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    const session = sessionFromTarget(host, target) orelse return false;
    session.exited = true;
    @import("../session/tab_strip.zig").refresh();
    // We did not show a native exit dialog. Let Ghostty paint its exit/error
    // message, and request close according to its command policy. The close
    // callback is source-attributed; an inactive child cannot hide this panel.
    return false;
}

/// ring_bell: audible side via afplay, visual side as a brief alpha
/// dim on the panel. Both are gated independently by config.
fn handleRingBell(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    const cfg = host.app_state.config orelse return false;
    const session = sessionFromTarget(host, target) orelse return false;
    const profile = session.profile;
    if (profile.bell_audible orelse cfg.bell.audible) {
        if (host.app_state.notifier) |notifier| notifier.playSound(profile.bell_sound orelse cfg.bell.sound);
    }
    if (profile.bell_visual orelse cfg.bell.visual) {
        const sm = host.app_state.session_manager orelse return true;
        if (sm.active().id == session.id) {
            if (host.app_state.window.panel) |p| p.flashBell();
        }
    }
    return true;
}

fn handleSearchTotal(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    if (!isActiveTarget(host, target)) return false;
    const total = action.action.search_total.total;
    host.app_state.find.total = if (total < 0) null else @intCast(total);
    @import("../terminal/find.zig").updateCountLabel();
    return true;
}

fn handleSearchSelected(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    if (!isActiveTarget(host, target)) return false;
    const sel = action.action.search_selected.selected;
    host.app_state.find.selected = if (sel < 0) null else @intCast(sel);
    @import("../terminal/find.zig").updateCountLabel();
    return true;
}

fn handleStartSearch(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    if (!isActiveTarget(host, target)) return false;
    // Ghostty frees search_selection's temporary needle after this callback.
    const needle = if (action.action.start_search.needle) |p| std.mem.span(p) else null;
    @import("../terminal/find.zig").startSearchFromGhostty(needle);
    return true;
}

fn handleEndSearch(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    if (!isActiveTarget(host, target)) return false;
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
fn handleDesktopNotification(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const n = action.action.desktop_notification;
    const notifier = host.app_state.notifier orelse return false;
    const title = if (n.title) |t| std.mem.span(t) else "";
    const body = if (n.body) |b| std.mem.span(b) else "";
    if (title.len == 0 and body.len == 0) return false;
    const session = sessionFromTarget(host, target) orelse return false;
    if (host.app_state.window.panel) |panel| {
        if (isActiveTarget(host, target) and panel.visible and panel.ns_app.msgSend(bool, "isActive", .{})) return true;
    }
    notifier.send(session.id, title, body);
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
fn handleMouseShape(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const session = sessionFromTarget(host, target) orelse return false;
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
    session.requested_cursor_shape = sel;
    reconcileHostInput();
    return true;
}

/// mouse_visibility: TUI requested cursor hide / unhide (e.g. video
/// playback inside terminal). NSCursor's hide/unhide stack is
/// reference-counted; pair calls one-for-one.
fn handleMouseVisibility(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const session = sessionFromTarget(host, target) orelse return false;
    session.requested_cursor_hidden = switch (action.action.mouse_visibility) {
        c.GHOSTTY_MOUSE_HIDDEN => true,
        c.GHOSTTY_MOUSE_VISIBLE => false,
        else => return false,
    };
    reconcileHostInput();
    return true;
}

/// mouse_over_link: surface tells us the cursor sits on (or left) an
/// OSC 8 hyperlink. Show a pointing hand on enter, restore the I-beam
/// on leave. Store this per source so an inactive session's link events
/// cannot overwrite the active session's cursor.
fn handleMouseOverLink(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const session = sessionFromTarget(host, target) orelse return false;
    const link = action.action.mouse_over_link;
    session.mouse_over_link = link.url != null and link.len > 0;
    reconcileHostInput();
    return true;
}

/// secure_input: lock keystrokes against keyloggers / screen readers.
/// Pair only our own successful Enable/Disable calls, never global OS state.
extern "c" fn EnableSecureEventInput() i32;
extern "c" fn DisableSecureEventInput() i32;

fn secureInputRequest(previous: bool, request: c.ghostty_action_secure_input_e) ?bool {
    return switch (request) {
        c.GHOSTTY_SECURE_INPUT_ON => true,
        c.GHOSTTY_SECURE_INPUT_OFF => false,
        c.GHOSTTY_SECURE_INPUT_TOGGLE => !previous,
        else => null,
    };
}

fn handleSecureInput(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const session = sessionFromTarget(host, target) orelse return false;
    session.requested_secure_input = secureInputRequest(session.requested_secure_input, action.action.secure_input) orelse return false;
    reconcileHostInput();
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
/// (LSUIElement, no titlebar); retain the source title for tabs and the
/// menubar, including synchronous construction-time configuration titles.
fn handleSetTitle(host: *HostContext, _: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    const session = sessionFromTarget(host, target) orelse pending: {
        if (target.tag != c.GHOSTTY_TARGET_SURFACE or target.target.surface == null) return false;
        const pending = pending_construction orelse return false;
        const sm = host.app_state.session_manager orelse return false;
        // Do not attribute an arbitrary unknown handle to the active tab.
        const userdata = c.ghostty_surface_userdata(target.target.surface);
        break :pending pending.matches(sm.sessions.items, userdata) orelse return false;
    };
    const payload = if (action.tag == c.GHOSTTY_ACTION_SET_TAB_TITLE) action.action.set_tab_title else action.action.set_title;
    const title = std.mem.span(payload.title orelse return false);
    setSessionTitle(session, title);
    @import("../session/tab_strip.zig").refresh();
    if (host.app_state.menubar) |mb| mb.refresh();
    return true;
}

fn setSessionTitle(session: *Session, title: []const u8) void {
    var len = @min(title.len, session.terminal_title.len);
    while (len > 0 and !std.unicode.utf8ValidateSlice(title[0..len])) len -= 1;
    for (title[0..len], 0..) |byte, i| {
        session.terminal_title[i] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
    }
    session.terminal_title_len = len;
}

fn handleQuit(host: *HostContext, _: c.ghostty_app_t, _: c.ghostty_target_s, _: c.ghostty_action_s) bool {
    const panel = host.app_state.window.panel orelse return false;
    panel.ns_app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
    return true;
}

/// Only actions this small host actually implements belong in the table.
const action_table = [_]ActionEntry{
    .{ .tag = c.GHOSTTY_ACTION_QUIT, .handler = handleQuit },
    .{ .tag = c.GHOSTTY_ACTION_DESKTOP_NOTIFICATION, .handler = handleDesktopNotification },
    .{ .tag = c.GHOSTTY_ACTION_SET_TITLE, .handler = handleSetTitle },
    .{ .tag = c.GHOSTTY_ACTION_SET_TAB_TITLE, .handler = handleSetTitle },
    .{ .tag = c.GHOSTTY_ACTION_PWD, .handler = handlePwd },
    .{ .tag = c.GHOSTTY_ACTION_MOUSE_SHAPE, .handler = handleMouseShape },
    .{ .tag = c.GHOSTTY_ACTION_MOUSE_VISIBILITY, .handler = handleMouseVisibility },
    .{ .tag = c.GHOSTTY_ACTION_MOUSE_OVER_LINK, .handler = handleMouseOverLink },
    .{ .tag = c.GHOSTTY_ACTION_SECURE_INPUT, .handler = handleSecureInput },
    .{ .tag = c.GHOSTTY_ACTION_RING_BELL, .handler = handleRingBell },
    .{ .tag = c.GHOSTTY_ACTION_OPEN_URL, .handler = handleOpenUrl },
    .{ .tag = c.GHOSTTY_ACTION_SHOW_CHILD_EXITED, .handler = handleChildExited },
    .{ .tag = c.GHOSTTY_ACTION_START_SEARCH, .handler = handleStartSearch },
    .{ .tag = c.GHOSTTY_ACTION_END_SEARCH, .handler = handleEndSearch },
    .{ .tag = c.GHOSTTY_ACTION_SEARCH_TOTAL, .handler = handleSearchTotal },
    .{ .tag = c.GHOSTTY_ACTION_SEARCH_SELECTED, .handler = handleSearchSelected },
};

const clipboard_text_mime: [*:0]const u8 = "text/plain";

/// Only the standard pasteboard exists in this host. Never alias an
/// unsupported primary/selection request to the user's general pasteboard.
fn supportsClipboard(clipboard: c.ghostty_clipboard_e) bool {
    return clipboard == c.GHOSTTY_CLIPBOARD_STANDARD;
}

fn clipboardRequestsText(mimes: [*c]const [*c]const u8, mimes_len: usize) bool {
    if (mimes == null) return false;
    for (mimes[0..mimes_len]) |mime| {
        if (mime != null and std.mem.eql(u8, std.mem.sliceTo(mime, 0), "text/plain")) return true;
    }
    return false;
}

/// The C payload is length-delimited, not a C string. Bound the slice before
/// forming it, preserve interior NULs, and reject malformed UTF-8 rather than
/// letting NSString conversion truncate or silently replace clipboard text.
fn clipboardText(entry: c.ghostty_clipboard_content_s) ?[]const u8 {
    if (entry.mime == null or !std.mem.eql(u8, std.mem.sliceTo(entry.mime, 0), "text/plain")) return null;
    if (entry.len > std.math.maxInt(isize)) return null;
    if (entry.len == 0) return "";
    if (entry.data == null) return null;
    const bytes = entry.data[0..entry.len];
    return if (std.unicode.utf8ValidateSlice(bytes)) bytes else null;
}

/// Serve text only when requested. Listing MIME types must not read any
/// representation. Ghostty borrows the completion arrays and bytes only for
/// this call, and takes ownership of state only when we return STARTED.
fn readClipboardImpl(
    userdata: ?*anyopaque,
    clipboard: c.ghostty_clipboard_e,
    state: ?*anyopaque,
    mimes: [*c]const [*c]const u8,
    mimes_len: usize,
    list: bool,
) callconv(.c) c.ghostty_clipboard_read_result_e {
    if (!supportsClipboard(clipboard)) return c.GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
    const session = sessionFromUserdata(userdata) orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const surf: c.ghostty_surface_t = @ptrCast(session.surface.?);
    const want_text = clipboardRequestsText(mimes, mimes_len);
    if (!want_text and !list) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;

    const objc = @import("objc");
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const NSString = objc.getClass("NSString") orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    if (pb.value == null) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const type_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.utf8-plain-text")});
    if (type_str.value == null) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const types = pb.msgSend(objc.Object, "types", .{});
    const has_text = types.value != null and types.msgSend(bool, "containsObject:", .{type_str});
    if (!has_text and !list) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;

    var contents: [1]c.ghostty_clipboard_content_s = undefined;
    var contents_len: usize = 0;
    if (want_text and has_text) {
        const ns_str = pb.msgSend(objc.Object, "stringForType:", .{type_str});
        if (ns_str.value == null) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
        const len = ns_str.msgSend(c_ulong, "lengthOfBytesUsingEncoding:", .{@as(c_ulong, 4)});
        if (len > std.math.maxInt(isize)) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
        const utf8 = ns_str.msgSend([*c]const u8, "UTF8String", .{});
        if (utf8 == null) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
        contents[0] = .{ .mime = clipboard_text_mime, .data = utf8, .len = len };
        contents_len = 1;
    }
    const available = [_][*c]const u8{clipboard_text_mime};
    const complete: c.ghostty_clipboard_complete_s = .{
        .contents = if (contents_len > 0) &contents else null,
        .contents_len = contents_len,
        .available = if (list and has_text) &available else null,
        .available_len = if (list and has_text) 1 else 0,
        .confirmed = false,
        .remember = false,
    };
    c.ghostty_surface_complete_clipboard_request(surf, &complete, state);
    return c.GHOSTTY_CLIPBOARD_READ_STARTED;
}

fn confirmReadClipboardStub(
    userdata: ?*anyopaque,
    payload: [*c]const c.ghostty_clipboard_confirm_s,
    state: ?*anyopaque,
    request: c.ghostty_clipboard_request_e,
) callconv(.c) void {
    _ = payload;
    _ = request;
    // No permission UI: explicitly DENY, never complete with confirmed=true.
    // This also sends protocol denial replies and releases request ownership.
    const session = sessionFromUserdata(userdata) orelse return;
    c.ghostty_surface_deny_clipboard_request(@ptrCast(session.surface.?), state);
}

/// Normal text copy/OSC 52 write remains supported. Confirmation-required
/// writes fail closed, and unsupported/binary representations leave the
/// pasteboard untouched. Kitty writes requiring permission enter the confirm
/// callback above before Ghostty invokes this write callback.
fn writeClipboardImpl(
    userdata: ?*anyopaque,
    clipboard: c.ghostty_clipboard_e,
    contents: [*c]const c.ghostty_clipboard_content_s,
    contents_len: usize,
    confirm: bool,
) callconv(.c) void {
    _ = sessionFromUserdata(userdata) orelse return;
    if (confirm or !supportsClipboard(clipboard) or contents == null or contents_len == 0) return;

    const objc = @import("objc");
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    if (pb.value == null) return;
    const type_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.utf8-plain-text")});
    if (type_str.value == null) return;

    var cleared = false;
    for (contents[0..contents_len]) |entry| {
        const bytes = clipboardText(entry) orelse continue;
        const data_str = NSString.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithBytes:length:encoding:", .{ bytes.ptr, @as(c_ulong, bytes.len), @as(c_ulong, 4) });
        if (data_str.value == null) continue;
        defer data_str.msgSend(void, "release", .{});
        if (!cleared) {
            _ = pb.msgSend(c_long, "clearContents", .{});
            cleared = true;
        }
        _ = pb.msgSend(bool, "setString:forType:", .{ data_str, type_str });
    }
}

fn closeSurfaceStub(userdata: ?*anyopaque, _: bool) callconv(.c) void {
    const session = sessionFromUserdata(userdata) orelse return;
    const lifecycle = @import("surface_lifecycle.zig");
    const allocator = host_storage.app_state.allocator orelse return;
    const ticket = allocator.create(lifecycle.Ticket) catch return;
    ticket.* = .{ .session_id = session.id, .generation = session.surface_generation };
    dispatch_async_f(@ptrCast(c_dispatch.dispatch_get_main_queue()), ticket, &closeSessionMain);
}

test "clipboard text uses explicit byte lengths and preserves interior NULs" {
    const data = [_]u8{ 'a', 0, 0xc3, 0xa9, 'z', 0xff };
    const entry: c.ghostty_clipboard_content_s = .{
        .mime = "text/plain",
        .data = &data,
        .len = 5,
    };
    try std.testing.expectEqualSlices(u8, data[0..5], clipboardText(entry).?);
    var partial = entry;
    partial.len = 3; // Mid-codepoint: reject rather than truncate or replace.
    try std.testing.expect(clipboardText(partial) == null);
    partial.len = data.len; // Invalid trailing byte must not be ignored.
    try std.testing.expect(clipboardText(partial) == null);
    partial.len = 1;
    try std.testing.expectEqualStrings("a", clipboardText(partial).?);
}

test "clipboard text rejects invalid payloads without reading past the declared length" {
    var entry: c.ghostty_clipboard_content_s = .{ .mime = "text/plain", .data = null, .len = 0 };
    try std.testing.expectEqualStrings("", clipboardText(entry).?);
    entry.len = 1;
    try std.testing.expect(clipboardText(entry) == null);
    entry.data = @ptrFromInt(16);
    entry.len = @as(usize, std.math.maxInt(isize)) + 1;
    try std.testing.expect(clipboardText(entry) == null); // No dereference.
    entry.len = 0;
    entry.mime = null;
    try std.testing.expect(clipboardText(entry) == null);
    entry.mime = "image/png";
    try std.testing.expect(clipboardText(entry) == null);
}

test "clipboard requests serve only standard text and list-only requests do not select data" {
    try std.testing.expect(supportsClipboard(c.GHOSTTY_CLIPBOARD_STANDARD));
    try std.testing.expect(!supportsClipboard(c.GHOSTTY_CLIPBOARD_SELECTION));
    try std.testing.expect(!supportsClipboard(c.GHOSTTY_CLIPBOARD_PRIMARY));
    const mixed = [_][*c]const u8{ "image/png", null, "text/plain" };
    try std.testing.expect(clipboardRequestsText(&mixed, mixed.len));
    try std.testing.expect(!clipboardRequestsText(&mixed, 2));
    try std.testing.expect(!clipboardRequestsText(&mixed, 0));
    try std.testing.expect(!clipboardRequestsText(null, 0));
    try std.testing.expect(!clipboardRequestsText(null, 1));
}

test "host input transitions balance only the active visible focused source" {
    // Simulate the SAME transition planner used by the native bridge, without
    // calling privacy APIs or AppKit. Count only edges, not repeated requests.
    const Recorder = struct {
        state: HostInputState = .{},
        enables: usize = 0,
        disables: usize = 0,
        hides: usize = 0,
        unhides: usize = 0,

        fn apply(self: *@This(), source: ?*const Session) void {
            const next = inputStateForSession(source);
            const changes = inputChanges(self.state, next);
            if (changes.secure) |on| {
                if (on) self.enables += 1 else self.disables += 1;
            }
            if (changes.cursor_hidden) |hidden| {
                if (hidden) self.hides += 1 else self.unhides += 1;
            }
            self.state = next;
        }
    };
    var a: Session = .{ .id = 1, .profile = .{ .name = "a" }, .surface = @ptrFromInt(16) };
    var b: Session = .{ .id = 2, .profile = .{ .name = "b" }, .surface = @ptrFromInt(32) };
    var recorder: Recorder = .{};
    a.requested_secure_input = true;
    a.requested_cursor_hidden = true;
    recorder.apply(&a); // new surfaces begin hidden/unfocused
    try std.testing.expectEqual(@as(usize, 0), recorder.enables);
    a.surface_focused = true;
    recorder.apply(&a); // focus alone is insufficient
    try std.testing.expectEqual(@as(usize, 0), recorder.hides);
    a.surface_visible = true;
    recorder.apply(&a);
    recorder.apply(&a); // duplicate ON/hidden must not stack references
    try std.testing.expectEqual(@as(usize, 1), recorder.enables);
    try std.testing.expectEqual(@as(usize, 1), recorder.hides);
    b.requested_secure_input = true;
    b.requested_cursor_hidden = true;
    b.mouse_over_link = true;
    recorder.apply(&a); // inactive source cannot change the host cursor
    try std.testing.expectEqualStrings("IBeamCursor", recorder.state.cursor_selector.?);
    a.surface_focused = false; // blur releases, requests remain session-owned
    recorder.apply(&a);
    try std.testing.expectEqual(@as(usize, 1), recorder.disables);
    try std.testing.expectEqual(@as(usize, 1), recorder.unhides);
    a.surface_focused = true;
    recorder.apply(&a);
    a.surface_visible = false; // occlusion also releases despite stale focus
    recorder.apply(&a);
    b.surface_visible = true;
    b.surface_focused = true;
    recorder.apply(&b); // active source switched
    try std.testing.expectEqualStrings("pointingHandCursor", recorder.state.cursor_selector.?);
    a.surface_visible = true;
    recorder.apply(&a); // handoff between two ON sources needs no extra acquire
    try std.testing.expectEqualStrings("IBeamCursor", recorder.state.cursor_selector.?);
    recorder.apply(&b);
    try std.testing.expectEqual(@as(usize, 3), recorder.enables);
    try std.testing.expectEqual(@as(usize, 3), recorder.hides);
    clearSessionInput(&a); // destroying inactive a cannot release b's references
    recorder.apply(&b);
    try std.testing.expect(recorder.state.secure);
    clearSessionInput(&b); // destroy must release BEFORE surface is cleared
    recorder.apply(&b);
    try std.testing.expect(b.surface != null);
    try std.testing.expect(recorder.state.cursor_selector == null);
    try std.testing.expect(!b.requested_secure_input and !b.requested_cursor_hidden);
    b.surface = null;
    recorder.apply(&b);
    b.surface = @ptrFromInt(48); // restart cannot inherit old requests
    b.surface_visible = true;
    b.surface_focused = true;
    recorder.apply(&b);
    recorder.apply(null); // app teardown is idempotent
    recorder.apply(null);
    try std.testing.expectEqual(@as(usize, 3), recorder.enables);
    try std.testing.expectEqual(recorder.enables, recorder.disables);
    try std.testing.expectEqual(@as(usize, 3), recorder.hides);
    try std.testing.expectEqual(recorder.hides, recorder.unhides);
}

test "secure input ON OFF and TOGGLE are session-local and idempotent" {
    try std.testing.expect(secureInputRequest(false, c.GHOSTTY_SECURE_INPUT_ON).?);
    try std.testing.expect(secureInputRequest(true, c.GHOSTTY_SECURE_INPUT_ON).?);
    try std.testing.expect(!secureInputRequest(true, c.GHOSTTY_SECURE_INPUT_OFF).?);
    try std.testing.expect(!secureInputRequest(false, c.GHOSTTY_SECURE_INPUT_OFF).?);
    try std.testing.expect(secureInputRequest(false, c.GHOSTTY_SECURE_INPUT_TOGGLE).?);
    try std.testing.expect(!secureInputRequest(true, c.GHOSTTY_SECURE_INPUT_TOGGLE).?);
    const current: HostInputState = .{ .secure = true, .cursor_hidden = true, .cursor_selector = "IBeamCursor" };
    const changes = inputChanges(current, current);
    try std.testing.expect(changes.secure == null and changes.cursor_hidden == null and !changes.cursor_shape);
}

test "pending construction title routing requires member userdata and generation" {
    var sessions = [_]Session{
        .{ .id = 1, .profile = .{ .name = "active" }, .surface = @ptrFromInt(16) },
        .{ .id = 2, .profile = .{ .name = "constructing" }, .surface_generation = 4 },
    };
    const pending: PendingConstruction = .{ .session = &sessions[1], .generation = 4 };
    try std.testing.expect(pending.matches(&sessions, null) == null);
    try std.testing.expect(pending.matches(&sessions, &sessions[0]) == null);
    try std.testing.expect(pending.matches(&sessions, @ptrFromInt(48)) == null);
    try std.testing.expect(pending.matches(&sessions, &sessions[1]) == &sessions[1]);
    setSessionTitle(pending.matches(&sessions, &sessions[1]).?, "initial title");
    try std.testing.expectEqualStrings("initial title", sessions[1].label());
    try std.testing.expectEqualStrings("active", sessions[0].label());
    sessions[1].surface_generation += 1;
    try std.testing.expect(pending.matches(&sessions, &sessions[1]) == null);
    sessions[1].surface_generation = 4;
    sessions[1].surface = @ptrFromInt(32);
    try std.testing.expect(pending.matches(&sessions, &sessions[1]) == null);
    sessions[1].surface = null;
    try std.testing.expect(pending.matches(sessions[0..1], &sessions[1]) == null);
}

test "surface routing preserves source and rejects absent or replaced handles" {
    const a: *anyopaque = @ptrFromInt(0x1000);
    const b: *anyopaque = @ptrFromInt(0x2000);
    var sessions = [_]Session{
        .{ .id = 1, .profile = .{ .name = "shell" }, .surface = a },
        .{ .id = 2, .profile = .{ .name = "tools" }, .surface = b },
    };
    try std.testing.expectEqual(@as(u64, 2), sessionForSurface(&sessions, b).?.id);
    try std.testing.expectEqual(@as(u64, 1), sessionForSurface(&sessions, a).?.id);
    try std.testing.expect(sessionForSurface(&sessions, null) == null);
    sessions[1].surface = @ptrFromInt(0x3000);
    try std.testing.expect(sessionForSurface(&sessions, b) == null);
}

test "terminal titles are bounded display text with intact UTF-8" {
    var session: Session = .{ .id = 1, .profile = .{ .name = "shell" } };
    setSessionTitle(&session, "task\nready\x1b");
    try std.testing.expectEqualStrings("task ready ", session.label());
    const long: [200][2]u8 = @splat("é".*);
    setSessionTitle(&session, std.mem.asBytes(&long));
    try std.testing.expectEqual(@as(usize, 256), session.terminal_title_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(session.label()));
    setSessionTitle(&session, "bad\xff");
    try std.testing.expectEqualStrings("bad", session.label());
    session.profile.title = "Pinned";
    try std.testing.expectEqualStrings("Pinned", session.label());
}

fn closeSessionMain(raw: ?*anyopaque) callconv(.c) void {
    const lifecycle = @import("surface_lifecycle.zig");
    const ticket: *lifecycle.Ticket = @ptrCast(@alignCast(raw orelse return));
    const allocator = host_storage.app_state.allocator orelse return;
    defer allocator.destroy(ticket);
    lifecycle.closeRequested(ticket.*);
}
