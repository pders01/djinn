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
const LogPane = @import("log_pane.zig").LogPane;

const GtkWidget = gtk.GtkWidget;
const GtkWindow = gtk.GtkWindow;
const gpointer = gtk.gpointer;

// GtkShortcutController API — public since GTK 4.0. Externs are
// listed here rather than in gtk.zig so the dependency graph stays
// localized: the rest of the linux platform doesn't reference these.
const GtkEventController = opaque {};
const GtkShortcutController = opaque {};
const GtkShortcut = opaque {};
const GtkShortcutTrigger = opaque {};
const GtkShortcutAction = opaque {};
const GVariant = opaque {};
const GdkDisplay = opaque {};
const GdkClipboard = opaque {};

// Clipboard surface. `gdk_clipboard_set_text` copies the text
// internally; the caller's buffer can be freed on return.
extern "c" fn gdk_display_get_default() ?*GdkDisplay;
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
extern "c" fn gtk_widget_add_controller(widget: *GtkWidget, controller: *GtkEventController) void;

extern "c" fn gtk_shortcut_trigger_parse_string(s: [*:0]const u8) ?*GtkShortcutTrigger;
extern "c" fn gtk_callback_action_new(
    callback: *const fn (widget: *GtkWidget, args: ?*GVariant, user_data: gpointer) callconv(.c) c_int,
    data: gpointer,
    destroy: ?*const anyopaque,
) *GtkShortcutAction;
extern "c" fn gtk_shortcut_new(trigger: *GtkShortcutTrigger, action: *GtkShortcutAction) *GtkShortcut;

/// Dispatch context passed to each shortcut callback. Held by the
/// caller for the lifetime of the panel — `install` stamps the
/// address into every shortcut's user_data slot so the callbacks can
/// reach Terminal without a global. Address must be stable; the
/// caller (`main_linux.zig`) keeps it on `runWithIpc`'s frame.
///
/// `allocator` is used by `open_settings` (compose the config path,
/// spawn the editor) and `mcp_copy_endpoint` (read mcp.json into a
/// heap buffer). `log_pane` is used by `toggle_log_pane`. `panel` +
/// `config` are used by `hide_panel` (gated on
/// `config.window.hide_on_escape`). The font/scrollback/copy/paste
/// handlers ignore the rest.
pub const Context = struct {
    terminal: *Terminal,
    allocator: std.mem.Allocator,
    log_pane: *LogPane,
    panel: *Panel,
    config: *const Config,
};

/// One row of the linux action table. `accel` follows GTK's
/// `gtk_accelerator_parse` syntax — e.g. "<Control>equal",
/// "<Control><Shift>k". Wiring is at install-time; the table itself
/// is comptime-known so adding an entry is one line.
///
/// `predicate`, when set, gates whether the row fires for a given
/// keypress: returning false skips the handler AND tells GTK the
/// event wasn't consumed, so it continues to bubble (VTE / shell get
/// it). Used by `hide_panel` so the Escape binding only swallows the
/// key when `config.window.hide_on_escape` is on — without that gate,
/// every TUI in the terminal (vim, less, htop, …) breaks.
const Action = struct {
    name: []const u8,
    accel: [*:0]const u8,
    handler: *const fn (ctx: *Context) void,
    predicate: ?*const fn (ctx: *Context) bool = null,
};

const actions = [_]Action{
    .{ .name = "font_inc", .accel = "<Control>equal", .handler = onFontInc },
    // Ctrl+Shift+= (Ctrl++) — keyboards put '+' on the shifted '='
    // key, so the unshifted Ctrl+= binding doesn't reliably fire on
    // layouts where the user presses Shift to type '+'. Two bindings
    // cover both muscle-memory patterns.
    .{ .name = "font_inc_shift", .accel = "<Control><Shift>equal", .handler = onFontInc },
    .{ .name = "font_dec", .accel = "<Control>minus", .handler = onFontDec },
    .{ .name = "font_reset", .accel = "<Control>0", .handler = onFontReset },
    .{ .name = "clear_scrollback", .accel = "<Control><Shift>k", .handler = onClearScrollback },
    .{ .name = "open_settings", .accel = "<Control>comma", .handler = onOpenSettings },
    .{ .name = "mcp_copy_endpoint", .accel = "<Control><Shift>m", .handler = onMcpCopyEndpoint },
    .{ .name = "copy", .accel = "<Control><Shift>c", .handler = onCopy },
    .{ .name = "paste", .accel = "<Control><Shift>v", .handler = onPaste },
    .{ .name = "toggle_log_pane", .accel = "<Control>slash", .handler = onToggleLogPane },
    .{
        .name = "hide_panel",
        .accel = "Escape",
        .handler = onHidePanel,
        .predicate = predHideOnEscape,
    },
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
    ctx.terminal.fontScaleAdjust(0.1);
}

fn onFontDec(ctx: *Context) void {
    ctx.terminal.fontScaleAdjust(-0.1);
}

fn onFontReset(ctx: *Context) void {
    ctx.terminal.fontScaleReset();
}

fn onClearScrollback(ctx: *Context) void {
    ctx.terminal.clearScrollback();
}

fn onCopy(ctx: *Context) void {
    ctx.terminal.copySelectionToClipboard();
}

fn onPaste(ctx: *Context) void {
    ctx.terminal.pasteFromClipboard();
}

fn onToggleLogPane(ctx: *Context) void {
    ctx.log_pane.toggleVisible();
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
    std.fs.cwd().makePath(dir) catch {};
    std.fs.accessAbsolute(path, .{}) catch {
        if (std.fs.createFileAbsolute(path, .{})) |f| f.close() else |_| {
            std.debug.print(
                "open_settings: could not create {s} — aborting\n",
                .{path},
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

/// Spawn `argv` with stdio detached, don't wait. Returns true on
/// successful exec, false on any error (typically NotFound when the
/// requested binary isn't on $PATH). Logs the underlying error so
/// debugging from a journal is straightforward.
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
