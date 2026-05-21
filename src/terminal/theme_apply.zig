//! Centralized theme reapply path. Crosses chrome (panel bg, log
//! pane, find overlay, tab strip) and ghostty (appSetColorScheme +
//! reloadConfigFromDisk), so consolidating the fan-out here makes
//! the dependency surface explicit — every new chrome surface that
//! reskins on appearance flip has exactly one place to register.
//!
//! Triggered by:
//! - `viewDidChangeEffectiveAppearanceImpl` (system light↔dark flip)
//! - `panel.show` via `reapplyIfChanged` (offscreen flips AppKit
//!    suppressed while the panel was hidden)
//! - `actionThemeToggle` via `reload` (manual Cmd+Shift+T cycle)
//! - hot-config reload via `reload` (theme.* fields edited in config)

const app = @import("../app.zig");
const chrome_mod = @import("../chrome.zig");
const ghostty_runtime = @import("../ghostty/runtime.zig");
const theme_mod = @import("../theme/theme.zig");
const find = @import("find.zig");

/// Force a theme re-resolve regardless of the cached appearance tag.
/// Called by the live-config reload path after the user edits theme
/// fields; the appearance comparison can't catch that case since only
/// the config has changed, not the appearance tag.
pub fn reload() void {
    app.g.theme.last_appearance = 0;
    reapply();
}

/// Re-resolve theme only if system appearance has actually changed.
/// Cheap no-op when stable — used by panel show path to recover from
/// system flips that happened while the panel was offscreen and AppKit
/// suppressed `viewDidChangeEffectiveAppearance`.
pub fn reapplyIfChanged() void {
    reapply();
}

/// Re-resolve the theme through the same pipeline main() uses on
/// startup, then reapply colors to terminal, log pane, find overlay,
/// tab strip, and panel. Skips when nothing has changed since the
/// last apply (cheap, the dedup guard at the top is what keeps the
/// panel-show path snappy).
pub fn reapply() void {
    const allocator = app.g.allocator orelse return;
    const config = app.g.config orelse return;

    // Skip when system appearance hasn't actually changed since the
    // last reload. AppKit fires viewDidChangeEffectiveAppearance for
    // many state transitions besides light/dark flips — first
    // window-attach, panel show, layout passes — and re-running
    // theme.resolve (file IO + parse) on every show is the source of
    // the perceived show-time lag.
    // Runtime override (Cmd+Shift+T) wins over system appearance.
    // When null, fall back to NSAppearance probe.
    const current_appearance = app.g.theme.override orelse theme_mod.detectSystemAppearance();
    const current_tag: u8 = switch (current_appearance) {
        .light => 1,
        .dark => 2,
    };
    if (app.g.theme.last_appearance == current_tag) return;

    // Push the new appearance to ghostty + reload its Config BEFORE
    // theme.resolve runs. theme.resolve reads `app.g.ghostty.config`
    // via applyFromGhostty, so the chrome palette is sourced from
    // whichever variant ghostty currently has resolved for `theme =
    // light:X,dark:Y`. If we resolve first, chrome locks onto the
    // pre-flip variant while the surface (which ghostty repaints on
    // its own pipeline) flips correctly — produces the visible
    // tab-strip / panel-bg mismatch reported on light↔dark flips.
    ghostty_runtime.appSetColorScheme(current_appearance == .dark);
    ghostty_runtime.reloadConfigFromDisk();

    var new_theme = theme_mod.resolve(allocator, .{
        .inherit_ghostty_config = config.theme.inherit_ghostty,
        .ghostty_cfg = app.g.ghostty.config,
        .font_family = config.terminal.font_family,
        .font_size = config.terminal.font_size,
        .padding_x = config.terminal.padding_x,
        .padding_y = config.terminal.padding_y,
        .opacity = config.theme.opacity,
        .background = if (config.theme.background) |s| theme_mod.parseColor(s) else null,
        .foreground = if (config.theme.foreground) |s| theme_mod.parseColor(s) else null,
        .cursor_color = if (config.theme.cursor) |s| theme_mod.parseColor(s) else null,
    }) catch return;
    defer new_theme.deinit();

    const new_style = chrome_mod.Style.fromTheme(new_theme);
    app.g.theme.chrome_style = new_style;
    if (app.g.agent.log_view) |lv| lv.applyStyle(new_style);
    find.applyOverlayStyle(new_style);
    @import("../session/tab_strip.zig").applyStyle(new_style);

    if (app.g.window.panel) |p| {
        const bg_r = @as(f64, @floatFromInt(new_theme.background.r)) / 255.0;
        const bg_g = @as(f64, @floatFromInt(new_theme.background.g)) / 255.0;
        const bg_b = @as(f64, @floatFromInt(new_theme.background.b)) / 255.0;
        p.setBackgroundColor(bg_r, bg_g, bg_b, new_theme.opacity);
    }

    // Stamp last_appearance only after a successful apply. Pre-stamping
    // and bailing on theme.resolve failure would poison the guard —
    // every subsequent call would short-circuit until the system
    // flipped a second time.
    app.g.theme.last_appearance = current_tag;
}
