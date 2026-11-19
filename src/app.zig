const std = @import("std");
const objc = @import("objc");
const Menubar = @import("notify/menubar.zig").Menubar;
const Panel = @import("window/panel.zig").Panel;
const Config = @import("config.zig").Config;
const Notifier = @import("notify/darwin.zig").Notifier;
const Hotkey = @import("hotkey/darwin.zig").Hotkey;

/// Single app-level state container. Cocoa method callbacks can't capture
/// Zig context, so the canonical pattern across the codebase was a sea of
/// module-private `g_*` vars. They all live here now: callbacks recover
/// state via the single `g` ref, and adding a new subsystem means adding
/// a field, not a new global.
///
/// Lifetime: owned by main(); the pointer is set once before AppKit's run
/// loop starts and cleared on exit. Reads inside callbacks are safe since
/// the run loop and callbacks share the main thread.
pub const AppState = struct {
    // Terminal view + font/cell metrics ------------------------------
    term: Term = .{},

    // Native status item ---------------------------------------------
    menubar: ?*Menubar = null,

    // Allocator + config pointer used by the theme reloader on
    // system appearance changes. The Config lives in main()'s stack
    // for the lifetime of the process; pointer is stable.
    allocator: ?std.mem.Allocator = null,
    config: ?*Config = null,

    // Theme state ----------------------------------------------------
    theme: Theme = .{},

    // Bell -----------------------------------------------------------
    /// Pointer to Notifier so the bell effect callback can play a
    /// sound (afplay subprocess; thread-safe).
    notifier: ?*Notifier = null,

    // Window / panel -------------------------------------------------
    window: Window = .{},

    // Own the global registration so config reload can also recover a
    // failed startup binding. Native handler userdata is separately stable.
    hotkey: ?Hotkey = null,
    hotkey_override: ?[]const u8 = null,

    // Find on page ----------------------------------------------------
    find: FindState = .{},

    // Native layout and Ghostty --------------------------------------
    layout: Layout = .{},
    ghostty: Ghostty = .{},

    // Sessions -------------------------------------------------------
    /// Multi-profile session manager. Holds one Session per declared
    /// profile (or a single default shell when none are configured).
    /// Switching tabs flips `active_idx` + setHidden on each session's
    /// surface_host. Action handlers in view.zig reach this through
    /// app.g + call back into main.zig for the spawn / focus glue.
    session_manager: ?*@import("session/manager.zig").SessionManager = null,

    // ─── Sub-state types ───────────────────────────────────────────
    // Declared after fields per Zig's container layout rule. Each
    // group is opt-in: callers reach `app.g.find.*`, `app.g.theme.*`,
    // etc. instead of a flat field sea.

    pub const Theme = struct {
        /// Active chrome style — derived from theme on startup + every
        /// reapplyTheme. Find overlay + future host UI surfaces read
        /// this for colors / fonts so host chrome reskins together.
        chrome_style: ?@import("chrome.zig").Style = null,
        /// Cached effective appearance from the last reapplyTheme run.
        /// AppKit calls viewDidChangeEffectiveAppearance at moments
        /// that don't necessarily change appearance (window show /
        /// first move-to-window / ancestry changes); skipping the
        /// reload when the cached value matches keeps the show path
        /// snappy.
        last_appearance: u8 = 0, // 0 = unset, 1 = light, 2 = dark
        /// Runtime appearance override. null = follow system (default).
        /// `theme_toggle` cycles null → light → dark → null and forces
        /// a `reloadTheme` pass on each step. Not persisted — restart
        /// returns to the system-follow default.
        override: ?@import("theme/theme.zig").Appearance = null,
    };

    pub const Window = struct {
        panel: ?*Panel = null,
        /// When true, the panel slides out as soon as another app
        /// takes key focus. Set from config.window.hide_on_blur via
        /// setHideOnBlur.
        hide_on_blur: bool = false,
        /// Resize-end handler — fired by
        /// NSWindowDidEndLiveResizeNotification. Persists the new
        /// window size.
        resize_handler: ?*const fn (u32, u32) void = null,
    };

    pub const Term = struct {
        /// NSView pointer for the terminal surface. Stored as raw id
        /// since callbacks reach for it via objc message dispatch.
        view_id: ?objc.c.id = null,
        /// CTFontRef as opaque pointer — keeping CoreText's `@cImport`
        /// out of app.zig avoids duplicate-opaque-type conflicts.
        /// Callers cast to the cg.CTFontRef alias they already have
        /// in scope.
        font: ?*const anyopaque = null,
        cell_w: f64 = 8,
        cell_h: f64 = 16,
        baseline: f64 = 4,
        padding_x: f64 = 8,
        padding_y: f64 = 8,
        /// Bg alpha for the terminal layer. `< 1.0` when an
        /// NSVisualEffectView blur sits underneath (bg drawn
        /// translucent so the blur shows through); `1.0` otherwise.
        bg_alpha: f64 = 1.0,
    };

    pub const Layout = struct {
        /// Outer container NSView holding terminal, surface hosts, and
        /// the optional profile tab strip. Set when at least two tabs exist.
        container_id: ?objc.c.id = null,
        /// Sibling NSView of `view_id` reserved for ghostty's surface.
        /// ghostty owns this view's CAMetalLayer once a surface is
        /// bound.
        surface_host_id: ?objc.c.id = null,
        /// Optional NSView pointer for the multi-profile tab strip.
        /// Present only when `session_manager.sessions.len >= 2`;
        /// null otherwise. Layout consults
        /// this to decide whether to reserve `tab_strip.tab_h` at
        /// the top.
        tab_strip_id: ?objc.c.id = null,
        /// Pointer to the 1px CALayer-backed subview that paints the
        /// tab strip's bottom hairline. Stable for the strip's
        /// lifetime so `applyStyle` can repaint it on theme flips
        /// without walking the strip's subview list.
        tab_strip_separator_id: ?objc.c.id = null,
    };

    pub const Ghostty = struct {
        /// Stable pointer to the ghostty App so the lazy-spawn path in
        /// the session switcher can call `ga.newSurface` without
        /// re-importing the runtime module from inside view.zig.
        app: ?*@import("ghostty/runtime.zig").App = null,
        /// Persistent ghostty surface handle. Bound to `surface_host_id`
        /// when `render.backend == "ghostty"`. Stored as `?*anyopaque`
        /// to avoid pulling ghostty.h into app.zig (`@cImport`
        /// collisions otherwise force every consumer to re-import).
        surface: ?*anyopaque = null,
        /// `ghostty_config_t` from App.init. Theme reload paths read it
        /// so they can call `ghostty_config_get` without going back
        /// through main(). Same opacity rationale as `surface`.
        config: ?*anyopaque = null,
    };

    pub const FindState = struct {
        /// True while Cmd+F is active. Routes keystrokes from keyDownImpl
        /// into the needle buffer instead of the ghostty surface. Borderless
        /// NSPanel + NSTextField + ghostty surface don't compose into a
        /// working field editor — we own input anyway, so just intercept.
        mode: bool = false,
        /// Current needle. Empty = no active search.
        query_buf: [128]u8 = @splat(0),
        query_len: usize = 0,
        /// Total match count + current selected index, both reported by
        /// ghostty via the search_total / search_selected actions.
        total: ?u32 = null,
        selected: ?u32 = null,
        /// Inline find-overlay NSTextField (read-only, display-only).
        /// Shows the current needle + count. Hidden when find.mode is
        /// false. Stored as id so callback handlers can retrieve it
        /// without capturing closure state (Cocoa C-ABI restriction).
        field_id: ?objc.c.id = null,
    };
};

/// Global handle. Code paths that need app state read this directly.
/// Set in main() before the run loop starts.
pub var g: AppState = .{};
