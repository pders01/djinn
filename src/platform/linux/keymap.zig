//! GTK4-backed keyboard shortcut wiring for djinn's panel + terminal.
//!
//! Linux analogue of darwin's `terminal/keymap.zig`: a small table of
//! named (accel, handler) pairs that get installed onto the panel
//! window via `GtkShortcutController`. Each shortcut runs at the
//! CAPTURE propagation phase so it takes precedence over VTE's
//! internal bindings (we want Ctrl+= to zoom the font without also
//! reaching the shell as a stray keypress).
//!
//! Current action set:
//!   - font_inc / font_dec / font_reset  (Ctrl+=, Ctrl+-, Ctrl+0)
//!   - clear_scrollback                   (Ctrl+Shift+K)
//!   - restart_session / shell_session    (Ctrl+R / Ctrl+Shift+R)
//!   - open_settings                      (Ctrl+,)
//!   - mcp_copy_endpoint                  (Ctrl+Shift+M)
//!   - copy / paste                       (Ctrl+Shift+C / Ctrl+Shift+V)
//!   - toggle_log_pane                    (Ctrl+/)
//!
//! Copy/paste are app-level not VTE-level because VTE 0.74+ removed
//! its built-in default keybindings — the host application is
//! expected to wire copy/paste itself. Without these entries, a user
//! on a current VTE has no way to copy text out of the terminal.
//!
//! The larger keymap that darwin's `view.zig::actions` carries
//! (palette / tabs / find / theme toggle / etc.) is gated on linux
//! features that don't exist yet (multi-profile, find overlay,
//! palette UI). Those entries land as their backing features do.
//!
//! Deliberately NOT bound:
//!   - hide_panel (Escape) — Esc at CAPTURE phase would eat the
//!     keypress before VTE sees it, regressing every TUI that uses
//!     Esc (vim insert-mode exit, less quit, htop quit, …). Needs
//!     a design that's safe-by-default (chord, opt-in config flag,
//!     or focus-aware gating) before it lands.

const std = @import("std");
const gtk = @import("gtk.zig");
const Config = @import("../../config.zig").Config;
const Panel = @import("panel.zig").Panel;
const Terminal = @import("terminal.zig").Terminal;
const SessionHost = @import("session_host.zig").SessionHost;
const LogPane = @import("log_pane.zig").LogPane;
const FindOverlay = @import("find_overlay.zig").FindOverlay;
const Cheatsheet = @import("cheatsheet.zig").Cheatsheet;
const Palette = @import("palette.zig").Palette;
const ghostty_config = @import("ghostty_config.zig");

const GtkWidget = gtk.GtkWidget;
const GtkWindow = gtk.GtkWindow;
const gpointer = gtk.gpointer;

// GtkShortcutController API — public since GTK 4.0. Externs are
// listed here rather than in gtk.zig so the dependency graph stays
// localized: the rest of the linux platform doesn't reference these.
const GtkEventController = gtk.GtkEventController;
const GtkShortcutController = opaque {};
const GtkShortcut = opaque {};
const GtkShortcutTrigger = opaque {};
const GtkShortcutAction = opaque {};
const GVariant = opaque {};
const GdkDisplay = gtk.GdkDisplay;
const GdkClipboard = opaque {};

// Clipboard surface. `gdk_clipboard_set_text` copies the text
// internally; the caller's buffer can be freed on return.
const gdk_display_get_default = gtk.gdk_display_get_default;
extern "c" fn gdk_display_get_clipboard(display: *GdkDisplay) ?*GdkClipboard;
extern "c" fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;

// GtkPropagationPhase: GTK_PHASE_NONE=0, CAPTURE=1, BUBBLE=2, TARGET=3.
const GTK_PHASE_CAPTURE: c_int = 1;
// GtkShortcutScope: LOCAL=0, MANAGED=1, GLOBAL=2.
const GTK_SHORTCUT_SCOPE_MANAGED: c_int = 1;

extern "c" fn gtk_shortcut_controller_new() *GtkEventController;
extern "c" fn gtk_shortcut_controller_set_scope(controller: *GtkEventController, scope: c_int) void;
extern "c" fn gtk_shortcut_controller_add_shortcut(controller: *GtkEventController, shortcut: *GtkShortcut) void;
extern "c" fn gtk_event_controller_set_propagation_phase(controller: *GtkEventController, phase: c_int) void;
const gtk_widget_add_controller = gtk.gtk_widget_add_controller;

extern "c" fn gtk_shortcut_trigger_parse_string(s: [*:0]const u8) ?*GtkShortcutTrigger;
extern "c" fn gtk_callback_action_new(
    callback: *const fn (widget: *GtkWidget, args: ?*GVariant, user_data: gpointer) callconv(.c) c_int,
    data: gpointer,
    destroy: ?*const anyopaque,
) *GtkShortcutAction;
extern "c" fn gtk_shortcut_new(trigger: *GtkShortcutTrigger, action: *GtkShortcutAction) *GtkShortcut;

/// Late-stamped popover pointers. All three popovers are constructed
/// on `runWithIpc`'s frame *after* the keymap Context literal is
/// initialized, so the slots default to null and main_linux stamps
/// them right after each popover's `init` returns. Handlers no-op
/// when the slot is null instead of crashing on a partial-init
/// dispatch.
///
/// The cluster lives in its own struct because (a) all three share
/// the late-stamp lifetime story and (b) the rest of the Context
/// fields are non-null at panel-open time — separating them makes
/// the "what's guaranteed vs. what's optional" distinction visible
/// at a glance instead of buried in field-level docs.
pub const Popovers = struct {
    find_overlay: ?*FindOverlay = null,
    cheatsheet: ?*Cheatsheet = null,
    /// Multi-profile palette switcher (Ctrl+Shift+P). Also gated by
    /// `predHasMultipleProfiles` so single-profile setups propagate
    /// Ctrl+Shift+P unchanged regardless of whether the slot is
    /// stamped — belt-and-suspenders against a future reorder
    /// dropping the palette from the wiring.
    palette: ?*Palette = null,
};

/// Service registry passed to every shortcut callback. Held by the
/// caller for the lifetime of the panel — `install` stamps the
/// address into every shortcut's user_data slot. Address must be
/// stable; `main_linux.zig` keeps it on `runWithIpc`'s frame.
///
/// Treated as a registry, not a god-object: each handler reaches
/// for exactly the slot(s) it needs (visible via the `ctx.<slot>`
/// access). Adding a new shortcut that depends on a new subsystem
/// is a one-line field addition here plus a one-line stamp in
/// main_linux. Per-action `*anyopaque` user_data was considered
/// but the type-erasure cost (every handler casts back to its
/// concrete dep type) didn't justify the structural split at
/// today's row count.
///
/// Field-usage map (so a reader knows which actions each slot
/// touches without grepping the whole file):
///   - `session_host`        — every VTE-driven action (font,
///                             scroll, clear, restart, shell, copy/
///                             paste, tab switching). `activeTerminal`
///                             reaches through it for the visible VTE.
///   - `allocator`           — `open_settings`, `mcp_copy_endpoint`.
///   - `log_pane`            — `toggle_log_pane`, `theme_toggle`
///                             (logs the new override).
///   - `panel`               — `hide_panel`.
///   - `config`              — `predHideOnEscape`, `open_settings`.
///   - `reapply_config`      — `theme_toggle` (re-run config-apply
///                             chain after cycling the override).
///   - `popovers.*`          — `find_*`, `cheatsheet_open`,
///                             `palette_open`.
pub const Context = struct {
    /// Multi-profile container. Handlers that need the visible VTE
    /// (font scale, clipboard, scrollback, scroll) reach via
    /// `session_host.currentTerminal()` so they always operate on
    /// the currently-visible session rather than a captured Terminal
    /// pointer that would silently address the wrong profile after
    /// a switch.
    session_host: *SessionHost,
    allocator: std.mem.Allocator,
    log_pane: *LogPane,
    panel: *Panel,
    config: *const Config,
    reapply_config: ?ReapplyHook = null,
    popovers: Popovers = .{},
};

/// Helper for handlers that operate on the active session's Terminal.
/// Returns null when the active session's VTE isn't spawned yet
/// (should never happen post-init — the active-at-startup session is
/// eagerly spawned). Wrapping the unwrap here keeps the per-handler
/// code shape `const t = activeTerminal(ctx) orelse return;` clean.
fn activeTerminal(ctx: *Context) ?*Terminal {
    return ctx.session_host.currentTerminal();
}

/// Callback shape main_linux.zig uses to wire `Dispatch.onConfigChanged`
/// into `onThemeToggle`. Mirrors `watcher.Handler` deliberately so
/// the same dispatch function services both file-save events and
/// runtime appearance flips.
pub const ReapplyHook = struct {
    ctx: *anyopaque,
    on_invoke: *const fn (ctx: *anyopaque) void,
};

/// One row of the linux action table. `accel` follows GTK's
/// `gtk_accelerator_parse` syntax — e.g. "<Control>equal",
/// "<Control><Shift>k". Wiring is at install-time; the table itself
/// is comptime-known so adding an entry is one line.
///
/// `display` is the human-readable form of `accel` ("Ctrl+=", "Esc")
/// rendered by the cheatsheet; kept alongside the GTK parse string
/// rather than derived at runtime so the cheatsheet doesn't have to
/// re-implement GTK's accel→label transform for our small set.
/// `description` is the short one-line phrase the cheatsheet shows.
/// Both default to empty for rows we don't want surfaced (mostly
/// font_inc_shift, which is a layout-coverage dup of font_inc).
///
/// `predicate`, when set, gates whether the row fires for a given
/// keypress: returning false skips the handler AND tells GTK the
/// event wasn't consumed, so it continues to bubble (VTE / shell get
/// it). Used by `hide_panel` so the Escape binding only swallows the
/// key when `config.window.hide_on_escape` is on — without that gate,
/// every TUI in the terminal (vim, less, htop, …) breaks.
pub const Action = struct {
    name: []const u8,
    accel: [*:0]const u8,
    handler: *const fn (ctx: *Context) void,
    predicate: ?*const fn (ctx: *Context) bool = null,
    display: []const u8 = "",
    description: []const u8 = "",
};

/// Public surface for the cheatsheet — `cheatsheet.zig` walks this
/// to render the popover content. Filter rule: drop rows whose
/// `description` is empty so the table can include rows we don't
/// want surfaced (the font_inc_shift dup).
pub fn actionList() []const Action {
    return &actions;
}

const actions = [_]Action{
    .{
        .name = "font_inc",
        .accel = "<Control>equal",
        .display = "Ctrl+=",
        .description = "Increase font size",
        .handler = onFontInc,
    },
    // Ctrl+Shift+= (Ctrl++) — keyboards put '+' on the shifted '='
    // key, so the unshifted Ctrl+= binding doesn't reliably fire on
    // layouts where the user presses Shift to type '+'. Two bindings
    // cover both muscle-memory patterns. Cheatsheet skips this row
    // (empty description) since it's a layout-dup of the previous.
    .{ .name = "font_inc_shift", .accel = "<Control><Shift>equal", .handler = onFontInc },
    .{
        .name = "font_dec",
        .accel = "<Control>minus",
        .display = "Ctrl+-",
        .description = "Decrease font size",
        .handler = onFontDec,
    },
    .{
        .name = "font_reset",
        .accel = "<Control>0",
        .display = "Ctrl+0",
        .description = "Reset font size",
        .handler = onFontReset,
    },
    .{
        .name = "clear_scrollback",
        .accel = "<Control><Shift>k",
        .display = "Ctrl+Shift+K",
        .description = "Clear scrollback + redraw prompt",
        .handler = onClearScrollback,
    },
    .{
        .name = "restart_session",
        .accel = "<Control>r",
        .display = "Ctrl+R",
        .description = "Restart active session",
        .handler = onRestartSession,
    },
    .{
        .name = "shell_session",
        .accel = "<Control><Shift>r",
        .display = "Ctrl+Shift+R",
        .description = "Restart active session as /bin/zsh",
        .handler = onShellSession,
    },
    .{
        .name = "open_settings",
        .accel = "<Control>comma",
        .display = "Ctrl+,",
        .description = "Open ~/.config/djinn/config in editor",
        .handler = onOpenSettings,
    },
    .{
        .name = "mcp_copy_endpoint",
        .accel = "<Control><Shift>m",
        .display = "Ctrl+Shift+M",
        .description = "Copy MCP endpoint JSON to clipboard",
        .handler = onMcpCopyEndpoint,
    },
    .{
        .name = "copy",
        .accel = "<Control><Shift>c",
        .display = "Ctrl+Shift+C",
        .description = "Copy selection to clipboard",
        .handler = onCopy,
    },
    .{
        .name = "paste",
        .accel = "<Control><Shift>v",
        .display = "Ctrl+Shift+V",
        .description = "Paste from clipboard",
        .handler = onPaste,
    },
    .{
        .name = "toggle_log_pane",
        .accel = "<Control>slash",
        .display = "Ctrl+/",
        .description = "Toggle agent log pane",
        .handler = onToggleLogPane,
    },
    .{
        .name = "scroll_page_up",
        .accel = "<Shift>Page_Up",
        .display = "Shift+PgUp",
        .description = "Scroll one page up",
        .handler = onScrollPageUp,
    },
    .{
        .name = "scroll_page_down",
        .accel = "<Shift>Page_Down",
        .display = "Shift+PgDn",
        .description = "Scroll one page down",
        .handler = onScrollPageDown,
    },
    .{
        .name = "theme_toggle",
        .accel = "<Control><Shift>t",
        .display = "Ctrl+Shift+T",
        .description = "Cycle theme override (system → light → dark)",
        .handler = onThemeToggle,
    },
    .{
        .name = "find_open",
        .accel = "<Control><Shift>f",
        .display = "Ctrl+Shift+F",
        .description = "Open find overlay",
        .handler = onFindOpen,
    },
    .{
        .name = "find_next",
        .accel = "<Control>g",
        .display = "Ctrl+G",
        .description = "Find next match",
        .handler = onFindNext,
    },
    .{
        .name = "find_prev",
        .accel = "<Control><Shift>g",
        .display = "Ctrl+Shift+G",
        .description = "Find previous match",
        .handler = onFindPrev,
    },
    .{
        .name = "cheatsheet_open",
        .accel = "<Control><Shift>question",
        .display = "Ctrl+?",
        .description = "Open cheatsheet (this popover)",
        .handler = onCheatsheetOpen,
    },
    .{
        .name = "hide_panel",
        .accel = "Escape",
        .display = "Esc",
        .description = "Hide panel (when hide_on_escape = true)",
        .handler = onHidePanel,
        .predicate = predHideOnEscape,
    },
    // ─── Multi-profile switching (gated on count() > 1) ──────────
    .{
        .name = "palette_open",
        .accel = "<Control><Shift>p",
        .display = "Ctrl+Shift+P",
        .description = "Open profile palette (type to switch)",
        .handler = onPaletteOpen,
        .predicate = predHasMultipleProfiles,
    },
    .{
        .name = "next_tab",
        .accel = "<Control>Tab",
        .display = "Ctrl+Tab",
        .description = "Switch to next profile",
        .handler = onNextTab,
        .predicate = predHasMultipleProfiles,
    },
    .{
        .name = "prev_tab",
        .accel = "<Control><Shift>Tab",
        .display = "Ctrl+Shift+Tab",
        .description = "Switch to previous profile",
        .handler = onPrevTab,
        .predicate = predHasMultipleProfiles,
    },
    .{ .name = "tab_1", .accel = "<Alt>1", .display = "Alt+1", .description = "Switch to profile 1", .handler = makeTabHandler(1), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_2", .accel = "<Alt>2", .display = "Alt+2", .description = "Switch to profile 2", .handler = makeTabHandler(2), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_3", .accel = "<Alt>3", .display = "Alt+3", .description = "Switch to profile 3", .handler = makeTabHandler(3), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_4", .accel = "<Alt>4", .display = "Alt+4", .description = "Switch to profile 4", .handler = makeTabHandler(4), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_5", .accel = "<Alt>5", .display = "Alt+5", .description = "Switch to profile 5", .handler = makeTabHandler(5), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_6", .accel = "<Alt>6", .display = "Alt+6", .description = "Switch to profile 6", .handler = makeTabHandler(6), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_7", .accel = "<Alt>7", .display = "Alt+7", .description = "Switch to profile 7", .handler = makeTabHandler(7), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_8", .accel = "<Alt>8", .display = "Alt+8", .description = "Switch to profile 8", .handler = makeTabHandler(8), .predicate = predHasMultipleProfiles },
    .{ .name = "tab_9", .accel = "<Alt>9", .display = "Alt+9", .description = "Switch to profile 9", .handler = makeTabHandler(9), .predicate = predHasMultipleProfiles },
};

/// Install every shortcut from the action table onto the panel
/// window. Idempotent in spirit — `gtk_widget_add_controller`
/// appends a fresh controller each call, so callers should run this
/// exactly once at startup. Failures (bad accel string, allocator
/// hiccup) log and skip the offending row rather than aborting the
/// whole table; one broken entry shouldn't disable every other
/// shortcut.
pub fn install(panel: *Panel, ctx: *Context) void {
    const controller = gtk_shortcut_controller_new();
    gtk_shortcut_controller_set_scope(controller, GTK_SHORTCUT_SCOPE_MANAGED);
    // CAPTURE phase means our handler runs before the focused widget
    // (VTE) gets to claim the event. Without this, VTE swallows
    // Ctrl+= as a normal keypress and forwards it to the shell.
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);

    var added: usize = 0;
    inline for (actions) |a| {
        // `inline for` makes `continue` comptime, which conflicts
        // with the runtime parse-failure branch — use if/else
        // instead. The else branch logs + skips this row; the
        // controller is still attached so other rows take effect.
        if (gtk_shortcut_trigger_parse_string(a.accel)) |trigger| {
            const action = gtk_callback_action_new(
                makeCallback(a.handler, a.predicate),
                @ptrCast(ctx),
                null,
            );
            const shortcut = gtk_shortcut_new(trigger, action);
            gtk_shortcut_controller_add_shortcut(controller, shortcut);
            added += 1;
        } else {
            std.debug.print(
                "keymap: invalid accel \"{s}\" for action {s} — skipping\n",
                .{ a.accel, a.name },
            );
        }
    }

    gtk_widget_add_controller(@ptrCast(panel.window), controller);
    std.debug.print(
        "keymap: installed {d}/{d} shortcuts on panel window\n",
        .{ added, actions.len },
    );
}

/// Wrap a Zig-native handler into the C ABI GtkCallbackAction wants.
/// The handler ignores `widget` + `args` — actions are scoped to the
/// terminal handle on `ctx`, not the firing widget.
///
/// When `predicate` is non-null and returns false, the callback
/// returns 0 (event not handled) so GTK continues propagation — VTE
/// or the shell get the keypress. This is the escape hatch for
/// gated shortcuts like `hide_panel`: predicate off → Esc reaches
/// the TUI in the terminal; predicate on → we consume and hide.
fn makeCallback(
    comptime handler: *const fn (ctx: *Context) void,
    comptime predicate: ?*const fn (ctx: *Context) bool,
) *const fn (
    widget: *GtkWidget,
    args: ?*GVariant,
    user_data: gpointer,
) callconv(.c) c_int {
    return &struct {
        fn cb(_: *GtkWidget, _: ?*GVariant, user_data: gpointer) callconv(.c) c_int {
            const ctx: *Context = @ptrCast(@alignCast(user_data orelse return 0));
            if (predicate) |p| {
                if (!p(ctx)) return 0;
            }
            handler(ctx);
            // Returning TRUE consumes the event so VTE doesn't
            // also see the keypress as terminal input.
            return 1;
        }
    }.cb;
}

fn onFontInc(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.fontScaleAdjust(0.1);
}

fn onFontDec(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.fontScaleAdjust(-0.1);
}

fn onFontReset(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.fontScaleReset();
}

fn onClearScrollback(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.clearScrollback();
}

/// Hangup the active session's shell and re-spawn the same profile's
/// command. Mirrors darwin's `Cmd+R` — escape hatch when a profile
/// script wedges (config reload doesn't fix it because the broken
/// child is still occupying the PTY) without losing the tab strip,
/// log pane, or window position.
fn onRestartSession(ctx: *Context) void {
    _ = ctx.session_host.restartActive(null);
}

/// Hangup the active session's shell and re-spawn into `/bin/zsh`.
/// Mirrors darwin's `Cmd+Shift+R` — escape hatch for when the
/// configured profile script itself is broken (typo, missing
/// dependency) so even `restart_session` would spawn the same broken
/// process. `/bin/zsh` matches darwin's literal; users on systems
/// without zsh fall through to whatever zsh shim ships, or this fails
/// visibly with a VTE spawn error and the user can switch profiles
/// to a working shell.
fn onShellSession(ctx: *Context) void {
    _ = ctx.session_host.restartActive("/bin/zsh");
}

fn onCopy(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.copySelectionToClipboard();
}

fn onPaste(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.pasteFromClipboard();
}

fn onToggleLogPane(ctx: *Context) void {
    ctx.log_pane.toggleVisible();
}

fn onScrollPageUp(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.scrollPages(-1.0);
}

fn onScrollPageDown(ctx: *Context) void {
    if (activeTerminal(ctx)) |t| t.scrollPages(1.0);
}

/// Cycle the appearance override (null → light → dark → null) and
/// trigger the same theme apply chain a config save would. Mirrors
/// darwin's `actionThemeToggle`. The visible chrome flip only happens
/// when the user's ghostty config has `theme = light:X,dark:Y`;
/// without that split the override is applied internally but the
/// palette doesn't change, so we surface the new state in the log
/// pane to keep the action observable in both cases.
fn onThemeToggle(ctx: *Context) void {
    const new_override = ghostty_config.cycleAppearanceOverride();
    if (ctx.reapply_config) |hook| hook.on_invoke(hook.ctx);

    const label: []const u8 = if (new_override) |o| switch (o) {
        .light => "theme override → light",
        .dark => "theme override → dark",
    } else "theme override cleared (follow system)";
    ctx.log_pane.appendInfo(label);
}

fn onFindOpen(ctx: *Context) void {
    if (ctx.popovers.find_overlay) |fo| fo.open();
}

fn onFindNext(ctx: *Context) void {
    if (ctx.popovers.find_overlay) |fo| fo.findNext();
}

fn onFindPrev(ctx: *Context) void {
    if (ctx.popovers.find_overlay) |fo| fo.findPrevious();
}

fn onCheatsheetOpen(ctx: *Context) void {
    if (ctx.popovers.cheatsheet) |cs| cs.toggle();
}

/// Hide the panel on Escape — Raycast/Spotlight muscle memory.
/// Gated by `predHideOnEscape`: only fires when the user opted in
/// via `hide-on-escape = true`. Without the gate, Esc at CAPTURE
/// phase would swallow the key before VTE sees it, breaking every
/// TUI that uses Esc (vim insert-mode exit, less quit, htop quit,
/// fzf cancel, …).
fn onHidePanel(ctx: *Context) void {
    ctx.panel.hide();
}

/// Predicate for `hide_panel`. Reads the config flag at firing
/// time, so a watcher-driven config reload (which swaps
/// `*ctx.config` in `Dispatch.onConfigChanged`) live-applies with no
/// keymap rebind — the shortcut stays installed but becomes a
/// no-op-with-propagation when the flag flips off.
fn predHideOnEscape(ctx: *Context) bool {
    return ctx.config.window.hide_on_escape;
}

/// Predicate for the tab-switch family (`next_tab`, `prev_tab`,
/// `tab_1..9`). Returns false (= propagate) on single-profile setups
/// so the keys reach VTE / the shell unchanged — gnome-terminal /
/// konsole convention is to bind these only in multi-tab contexts,
/// and eating Alt+N from readline in single-profile mode would break
/// shell history-prefix gestures.
fn predHasMultipleProfiles(ctx: *Context) bool {
    return ctx.session_host.sm.count() > 1;
}

fn onPaletteOpen(ctx: *Context) void {
    if (ctx.popovers.palette) |p| p.toggle();
}

fn onNextTab(ctx: *Context) void {
    _ = ctx.session_host.activateNext();
}

fn onPrevTab(ctx: *Context) void {
    _ = ctx.session_host.activatePrev();
}

/// Comptime factory for `tab_N` handlers. Each call returns a fresh
/// fn that calls `session_host.activate(N - 1)`. `SessionHost.activate`
/// already bounds-checks, so `tab_9` with only 3 profiles is a quiet
/// no-op (the predicate path consumes the event regardless — see
/// `predHasMultipleProfiles` for the trade-off).
fn makeTabHandler(comptime n: usize) *const fn (ctx: *Context) void {
    return struct {
        fn handle(ctx: *Context) void {
            _ = ctx.session_host.activate(n - 1);
        }
    }.handle;
}

/// Open `~/.config/djinn/config` in the desktop-registered text
/// editor. Mirrors darwin's `notify/menubar.zig::openSettings`.
/// Creates the parent dir and the file itself when missing so the
/// spawned editor always has something to open.
///
/// Preference order:
///   1. `xdg-open` — desktop MIME default (Kate on KDE, gnome-text-
///      editor on GNOME, etc.). The right call in a GUI context.
///   2. `$EDITOR` — fallback for headless / minimal setups where
///      xdg-open isn't installed.
///
/// `$EDITOR` is the fallback, not the primary, because a typical
/// linux user has `$EDITOR=vim` (or nvim / helix / nano) — TTY
/// editors. We spawn with `.Ignore` stdio so a TTY editor can't
/// steal djinn's stderr; the practical effect is that the TTY
/// editor exec succeeds, then immediately exits because it has no
/// controlling terminal. From the user's perspective, "Ctrl+, did
/// nothing." `xdg-open` first sidesteps that whole class of bug.
/// Users who insist on $EDITOR can unset xdg-utils or set $VISUAL
/// to a GUI editor in a future iteration.
///
/// Spawned child is NOT waited on: GUI editors fork+exec their real
/// process and the spawned shim exits immediately, leaving at most
/// one zombie per invocation until djinn exits. A `Child.wait()` on
/// the GLib main thread would block the panel; spawning a reaper
/// thread per invocation is overkill for a key the user fires a
/// handful of times per session. Accept the trivial zombie cost.
fn onOpenSettings(ctx: *Context) void {
    const home = std.posix.getenv("HOME") orelse return;
    const dir = std.fmt.allocPrint(
        ctx.allocator,
        "{s}/.config/djinn",
        .{home},
    ) catch return;
    defer ctx.allocator.free(dir);
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "{s}/config",
        .{dir},
    ) catch return;
    defer ctx.allocator.free(path);

    // makePath is idempotent (EEXIST → success). createFile with
    // .exclusive omitted overwrites; we want create-if-missing-else-
    // leave-alone, so access first and only create on ENOENT.
    std.fs.cwd().makePath(dir) catch |err| {
        // ENOSPC / EACCES used to vanish here, surfacing later as
        // a confusing "could not create" with no hint that the
        // parent directory was the actual problem.
        std.debug.print(
            "open_settings: makePath {s} failed: {} — config dir may be missing\n",
            .{ dir, err },
        );
    };
    std.fs.accessAbsolute(path, .{}) catch {
        if (std.fs.createFileAbsolute(path, .{})) |f| f.close() else |err| {
            std.debug.print(
                "open_settings: could not create {s}: {} — aborting\n",
                .{ path, err },
            );
            return;
        }
    };

    // Try xdg-open first. If it's not installed (NotFound), fall
    // back to $EDITOR. Any other spawn error logs and gives up —
    // those are weirder failures we'd want to know about than
    // silently retry with another exe.
    const xdg = [_][]const u8{ "xdg-open", path };
    if (trySpawnDetached(ctx.allocator, &xdg)) {
        std.debug.print("open_settings: spawned xdg-open {s}\n", .{path});
        return;
    }

    if (std.posix.getenv("EDITOR")) |editor| {
        const argv = [_][]const u8{ editor, path };
        if (trySpawnDetached(ctx.allocator, &argv)) {
            std.debug.print("open_settings: spawned {s} {s}\n", .{ editor, path });
            return;
        }
    }

    std.debug.print(
        "open_settings: no usable opener — install xdg-utils or set $EDITOR to a GUI editor\n",
        .{},
    );
}

/// GLib's child-reaping watcher. Internally installs a SIGCHLD
/// handler that calls `waitpid(pid, …, WNOHANG)` and dispatches the
/// callback when the child exits — so we don't have to. Without
/// this, every `trySpawnDetached` call (xdg-open, $EDITOR fallback)
/// leaves a zombie attached to djinn until process exit. The
/// callback is a no-op; the reap happens inside GLib regardless of
/// what we do here.
extern "c" fn g_child_watch_add(
    pid: c_int,
    function: *const fn (pid: c_int, status: c_int, user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) c_uint;

fn onChildExited(_: c_int, _: c_int, _: ?*anyopaque) callconv(.c) void {}

/// Spawn `argv` with stdio detached, don't wait. Returns true on
/// successful exec, false on any error (typically NotFound when the
/// requested binary isn't on $PATH). Logs the underlying error so
/// debugging from a journal is straightforward. The spawned child
/// is registered with `g_child_watch_add` so its exit is reaped
/// automatically — no zombie accumulation.
fn trySpawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        std.debug.print(
            "open_settings: spawn \"{s}\" failed: {}\n",
            .{ argv[0], err },
        );
        return false;
    };
    _ = g_child_watch_add(child.id, onChildExited, null);
    return true;
}

/// Copy `~/.config/djinn/mcp.json` to the system clipboard so the
/// user can paste it into Claude Code's `.mcp.json`. The file is
/// authoritative: matches darwin's `copyMcpConfigImpl`, and reading
/// the file means we don't have to thread the running McpServer's
/// port + token through Context.
///
/// Silently no-ops when the file is absent (MCP disabled or server
/// init failed). A stderr log line points to the cause so debugging
/// from a journal is straightforward.
fn onMcpCopyEndpoint(ctx: *Context) void {
    const home = std.posix.getenv("HOME") orelse return;
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "{s}/.config/djinn/mcp.json",
        .{home},
    ) catch return;
    defer ctx.allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        std.debug.print(
            "mcp_copy_endpoint: open {s} failed: {} — is mcp-enabled set?\n",
            .{ path, err },
        );
        return;
    };
    defer file.close();

    // 64 KiB ceiling matches darwin's read in notify/menubar.zig;
    // realistic mcp.json is < 1 KiB so the cap is purely defensive.
    // Sentinel 0 so the buffer is directly usable as [*:0]const u8
    // for the C clipboard call.
    const contents = file.readToEndAllocOptions(
        ctx.allocator,
        64 * 1024,
        null,
        .of(u8),
        0,
    ) catch |err| {
        std.debug.print("mcp_copy_endpoint: read failed: {}\n", .{err});
        return;
    };
    defer ctx.allocator.free(contents);

    const display = gdk_display_get_default() orelse {
        std.debug.print("mcp_copy_endpoint: no default GdkDisplay\n", .{});
        return;
    };
    const clipboard = gdk_display_get_clipboard(display) orelse {
        std.debug.print("mcp_copy_endpoint: no clipboard on display\n", .{});
        return;
    };
    gdk_clipboard_set_text(clipboard, contents.ptr);
    std.debug.print("mcp_copy_endpoint: copied mcp.json ({d} bytes)\n", .{contents.len});
}

test "keymap action table compiles" {
    // Table is comptime-known; this just exercises the types. The
    // GTK externs themselves can't be invoked without a live GTK
    // context (gtk_init must have run), same as panel/terminal tests.
    _ = actions;
    _ = install;
}
