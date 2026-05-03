const std = @import("std");
const objc = @import("objc");
const AgentState = @import("agent/state.zig").AgentState;
const Agent = @import("agent/state.zig").Agent;
const Menubar = @import("notify/menubar.zig").Menubar;
const LogView = @import("agent/log_view.zig").LogView;
const Panel = @import("window/panel.zig").Panel;
const Config = @import("config.zig").Config;
const Notifier = @import("notify/darwin.zig").Notifier;
const Hotkey = @import("hotkey/darwin.zig").Hotkey;
const ToolTable = @import("mcp/tools.zig").ToolTable;

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
    // IO -------------------------------------------------------------
    /// NSView pointer for the terminal surface. Stored as raw id since
    /// callbacks reach for it via objc message dispatch.
    view_id: ?objc.c.id = null,

    // Font + cell metrics --------------------------------------------
    /// CTFontRef as opaque pointer — keeping CoreText's `@cImport` out of
    /// app.zig avoids duplicate-opaque-type conflicts. Callers cast to
    /// the cg.CTFontRef alias they already have in scope.
    font: ?*const anyopaque = null,
    /// Family name slice, lifetime owned by config (lives for app duration).
    /// Empty default; set in TerminalView.init so font-resize can rebuild.
    font_family: []const u8 = "",
    /// Initial size from config. Surface owns runtime mutation via
    /// `increase_font_size`/`decrease_font_size` actions; this stays
    /// frozen at boot value (used only for chrome metric fallback).
    font_size: f64 = 13,
    cell_w: f64 = 8,
    cell_h: f64 = 16,
    baseline: f64 = 4,
    padding_x: f64 = 8,
    padding_y: f64 = 8,
    /// Bg alpha for the terminal layer. `< 1.0` when an NSVisualEffectView
    /// blur sits underneath (bg drawn translucent so the blur shows
    /// through); `1.0` otherwise.
    bg_alpha: f64 = 1.0,

    // Agent surface observers ----------------------------------------
    agent_state: ?*AgentState = null,
    menubar: ?*Menubar = null,
    log_view: ?*LogView = null,
    last_state: Agent = .idle,
    tick_count: u32 = 0,

    // Theme reload ---------------------------------------------------
    /// Allocator + config pointer used by the theme reloader on
    /// system appearance changes. The Config lives in main()'s stack
    /// for the lifetime of the process; pointer is stable.
    allocator: ?std.mem.Allocator = null,
    config: ?*Config = null,
    /// Cached effective appearance from the last reapplyTheme run.
    /// AppKit calls viewDidChangeEffectiveAppearance at moments that
    /// don't necessarily change appearance (window show / first
    /// move-to-window / ancestry changes); skipping the reload when
    /// the cached value matches keeps the show path snappy.
    last_appearance: u8 = 0, // 0 = unset, 1 = light, 2 = dark

    // Bell -----------------------------------------------------------
    /// Pointer to Notifier so the bell effect callback can play a
    /// sound (afplay subprocess; thread-safe).
    notifier: ?*Notifier = null,

    // Window / panel -------------------------------------------------
    panel: ?*Panel = null,
    /// When true, the panel slides out as soon as another app takes
    /// key focus. Set from config.window.hide_on_blur via setHideOnBlur.
    hide_on_blur: bool = false,
    /// Resize-end handler — fired by NSWindowDidEndLiveResizeNotification.
    /// Persists the new window size.
    resize_handler: ?*const fn (u32, u32) void = null,

    // Live-reload targets — set by main() so the FSEvent watcher can
    // mutate runtime state without taking a closure (Cocoa callbacks
    // don't capture). hotkey rebinds via setBinding; tool_table updates
    // its attention_sound slice on notifications.attention_sound flip.
    hotkey: ?*Hotkey = null,
    tool_table: ?*ToolTable = null,

    // Find on page ----------------------------------------------------
    /// True while Cmd+F is active. Routes keystrokes from keyDownImpl
    /// into the needle buffer instead of the ghostty surface. Borderless
    /// NSPanel + NSTextField + ghostty surface don't compose into a
    /// working field editor — we own input anyway, so just intercept.
    find_mode: bool = false,
    /// Current needle. Empty = no active search.
    search_query_buf: [128]u8 = [_]u8{0} ** 128,
    search_query_len: usize = 0,
    /// Total match count + current selected index, both reported by
    /// ghostty via the search_total / search_selected actions.
    search_total: ?u32 = null,
    search_selected: ?u32 = null,
    /// Inline find-overlay NSTextField (read-only, display-only).
    /// Shows the current needle + count. Hidden when find_mode is
    /// false. Stored as id so callback handlers can retrieve it
    /// without capturing closure state (Cocoa C-ABI restriction).
    search_field_id: ?objc.c.id = null,

    // Chrome ---------------------------------------------------------
    /// Active chrome style — derived from theme on startup + every
    /// reapplyTheme. Find overlay + future host UI surfaces read this
    /// for colors / fonts so they reskin in lockstep with the log
    /// pane on appearance flips.
    chrome_style: ?@import("chrome.zig").Style = null,

    // Tier-5 surface migration --------------------------------------
    /// Sibling NSView of `view_id` reserved for ghostty's surface.
    /// ghostty owns this view's CAMetalLayer once a surface is bound.
    /// Hidden when `render.backend != "ghostty"`. Step 4a allocates
    /// the view but doesn't bind a surface yet — that's step 4b.
    surface_host_id: ?objc.c.id = null,
    /// Thin vertical divider between terminal and log pane. Stashed
    /// here so the log-toggle path can resize/hide it without going
    /// through container.subviews[idx], which is fragile (the index
    /// shifts whenever buildContainer's subview order changes).
    divider_view_id: ?objc.c.id = null,
    /// Persistent ghostty surface handle. Bound to `surface_host_id`
    /// when `render.backend == "ghostty"`. Step 4b sets this; step 5
    /// drives its render trigger. Stored as `?*anyopaque` to avoid
    /// pulling ghostty.h into app.zig (`@cImport` collisions).
    ghostty_surface: ?*anyopaque = null,
    /// `ghostty_config_t` from App.init. Theme reload paths read it so
    /// they can call `ghostty_config_get` without going back through
    /// main(). Same opacity rationale as `ghostty_surface`.
    ghostty_config: ?*anyopaque = null,

    // Sessions -------------------------------------------------------
    /// Multi-profile session manager. Holds one Session per declared
    /// profile (or a single synthesized "default" for legacy configs).
    /// Switching tabs flips `active_idx` + setHidden on each session's
    /// surface_host. Action handlers in view.zig reach this through
    /// app.g + call back into main.zig for the spawn / focus glue.
    session_manager: ?*@import("session/manager.zig").SessionManager = null,
    /// Optional NSView pointer for the multi-profile tab strip.
    /// Present only when `session_manager.sessions.len >= 2`; null
    /// otherwise. Action handlers + applyLogLayout consult this to
    /// decide whether to reserve `tab_strip.tab_h` at the top.
    tab_strip_id: ?objc.c.id = null,
    /// Stable pointer to the ghostty App so the lazy-spawn path in the
    /// session switcher can call `ga.newSurface` without re-importing
    /// the runtime module from inside view.zig.
    ghostty_app: ?*@import("ghostty/runtime.zig").App = null,
};

/// Global handle. Code paths that need app state read this directly.
/// Set in main() before the run loop starts.
pub var g: AppState = .{};
