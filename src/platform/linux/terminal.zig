//! VTE-backed terminal widget.
//!
//! Wraps `VteTerminal` — a `GtkWidget` exposing a full terminal
//! emulator (PTY, VT parser, scrollback, selection, IME, mouse,
//! hyperlinks, font handling). VTE is the standard embeddable
//! terminal on Linux; the macOS half of djinn uses ghostty's
//! embeddable surface API for the same role. See the VTE-vs-ghostty
//! tradeoff doc in the port history for why this asymmetry is
//! deliberate rather than aspirational.
//!
//! Surface area is intentionally small: create the widget, spawn the
//! user's shell as the child, expose the widget for embedding. Config
//! translation (font, palette, cursor) lands in a follow-up pass —
//! VTE configures via GObject properties rather than a config file, so
//! mapping djinn's ghostty-format config keys is its own concern
//! separate from the widget lifecycle.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const dragdrop = @import("dragdrop.zig");
const theme = @import("theme.zig");

pub const ThemeOptions = theme.Options;

const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
const GCancellable = gtk.GCancellable;
const gpointer = gtk.gpointer;

// g_signal_connect_data is the macro-free entry point, same pattern
// the rest of the linux platform modules use.
const GClosureNotify = ?*const fn (data: gpointer, closure: ?*anyopaque) callconv(.c) void;
extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: gpointer,
    destroy_data: GClosureNotify,
    connect_flags: c_int,
) c_ulong;
extern "c" fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;

/// Caller-supplied dispatch hook. Invoked on the GLib main thread when
/// VTE emits `child-exited` — i.e. when the shell process the terminal
/// hosts has terminated. The handler typically maps to `panel.quit()`
/// so typing `exit` closes the window.
pub const Handler = struct {
    ctx: *anyopaque,
    on_child_exited: *const fn (ctx: *anyopaque) void,
};

// ─── VTE extern surface ──────────────────────────────────────────────
//
// Only the calls actually used today. Adding a getter or setter is
// mechanical; the upstream header is `<vte/vte.h>`.

extern "c" fn vte_terminal_new() *GtkWidget;

/// `vte_terminal_spawn_async` signature (stable since VTE 0.48).
/// Timeout `-1` selects VTE's default. The callback is optional — we
/// pass null for fire-and-forget. Spawn failure surfaces as a glib
/// warning + visible "spawn failed" text inside the terminal; for
/// richer handling we'd connect to `child-exited`.
extern "c" fn vte_terminal_spawn_async(
    terminal: *VteTerminal,
    pty_flags: c_int,
    working_directory: ?[*:0]const u8,
    argv: [*]const ?[*:0]const u8,
    envv: ?[*]const ?[*:0]const u8,
    spawn_flags: c_int,
    child_setup: ?*const anyopaque,
    child_setup_data: gpointer,
    child_setup_data_destroy: ?*const anyopaque,
    timeout: c_int,
    cancellable: ?*GCancellable,
    callback: ?*const anyopaque,
    user_data: gpointer,
) void;

// Font scale + reset are public VTE API; signatures stable since
// VTE 0.40. Scale multiplies the base font set via
// `vte_terminal_set_font`; default 1.0. `reset` clears scrollback
// (clear_history) and / or tab stops (clear_tabstops); the visible
// screen is preserved either way — that's a separate vt100 reset
// sequence we don't issue.
extern "c" fn vte_terminal_set_font_scale(terminal: *VteTerminal, scale: f64) void;
extern "c" fn vte_terminal_get_font_scale(terminal: *VteTerminal) f64;
extern "c" fn vte_terminal_reset(terminal: *VteTerminal, clear_tabstops: c_int, clear_history: c_int) void;
extern "c" fn vte_terminal_feed_child(terminal: *VteTerminal, data: [*]const u8, length: isize) void;
// VTE 0.74+ removed default copy/paste keybindings; host apps must
// drive these themselves. VteFormat enum starts at 1, not 0 —
// passing 0 trips a g_return_if_fail assertion ("check_enum_value"
// fails) and the clipboard write silently no-ops.
const VTE_FORMAT_TEXT: c_int = 1;
const VTE_FORMAT_HTML: c_int = 2;
extern "c" fn vte_terminal_copy_clipboard_format(terminal: *VteTerminal, format: c_int) void;
extern "c" fn vte_terminal_paste_clipboard(terminal: *VteTerminal) void;

// Spawn flag / pty flag constants. Inline rather than re-declared as
// enums because we only need a couple of values today.
const VTE_PTY_DEFAULT: c_int = 0;
const G_SPAWN_DEFAULT: c_int = 0;
/// VTE-specific bit added to `spawn_flags`. Tells VTE not to ask
/// systemd to create a unit scope for the child. With this OFF (the
/// default), VTE calls `org.freedesktop.systemd1.Manager.StartTransientUnit`
/// over D-Bus to get the child placed in its own scope. That works
/// fine from a top-level terminal app, but when djinn itself is
/// launched from inside another systemd-scope-creating terminal
/// (Ghostty, GNOME Terminal, …), the nested StartTransientUnit call
/// can return a malformed reply whose string field is null. VTE's
/// libfmt-based error reporter then aborts on the null pointer:
///
///   GLib-CRITICAL: g_utf8_make_valid: assertion 'str != NULL' failed
///   terminate called after fmt::v11::format_error: string pointer is null
///
/// Skipping the systemd scope sidesteps that entire path. The child
/// still runs; it just doesn't get its own unit. For djinn's use case
/// — terminal panel + agent shell — we don't need per-shell scopes.
const VTE_SPAWN_NO_SYSTEMD_SCOPE: c_int = 1 << 26;

// ─── Terminal ────────────────────────────────────────────────────────

/// Owned wrapper around a VTE widget.
///
/// `vte_terminal_spawn_async` is genuinely async: it stashes the
/// `argv` pointer for a deferred spawn callback and returns
/// immediately, BEFORE forking the child. Anything argv points at —
/// the array slots themselves AND the string buffers they point to —
/// must outlive the call. If they don't, the eventual fork-and-exec
/// reads freed memory; the visible failure is glib's
/// `g_utf8_make_valid: assertion 'str != NULL' failed` followed by a
/// libfmt format_error abort (VTE's error path tries to render the
/// garbage spawn failure as a terminal message and chokes on the
/// null). We store both on the Terminal so they live until deinit.
pub const Terminal = struct {
    widget: *GtkWidget,
    allocator: std.mem.Allocator,
    shell_path: [:0]u8,
    /// Heap-resident argv handed to VTE. The trailing slot stores the
    /// required null terminator. VTE retains this pointer until the
    /// async child-spawn fires, so Terminal owns it until deinit.
    argv: [*]?[*:0]u8,
    /// Heap-boxed handler the C `child-exited` callback recovers via
    /// `user_data`. Boxed because Terminal lives on the caller's stack
    /// and we can't take its address before `open` returns. Null when
    /// the caller didn't register a handler.
    handler_box: ?*Handler = null,
    /// Signal id for the `child-exited` handler, 0 when no handler
    /// was registered. Stashed so `deinit` can disconnect before
    /// freeing `handler_box` — a pending dispatch in flight at
    /// teardown would otherwise read freed memory through user_data.
    child_exited_handler_id: c_ulong = 0,

    /// Resolve $SHELL falling back to /bin/sh. Returns the dup'd
    /// sentinel-terminated slice. $SHELL is the freedesktop convention;
    /// /bin/sh is the POSIX guarantee, fine as fallback even on
    /// systems where /bin is a symlink to /usr/bin (Arch).
    fn resolveShell(allocator: std.mem.Allocator) ![:0]u8 {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        return try allocator.dupeZ(u8, shell);
    }

    pub fn open(
        allocator: std.mem.Allocator,
        theme_opts: ThemeOptions,
        handler: ?Handler,
    ) !Terminal {
        const widget = vte_terminal_new();
        const terminal: *VteTerminal = @ptrCast(widget);

        // Apply config-driven theme (font, fg/bg/cursor, padding)
        // before the widget is mapped so the first paint already
        // shows djinn's styling instead of VTE's defaults. Each
        // option is no-op-safe when null, so a caller with empty
        // config gets VTE defaults.
        theme.apply(widget, theme_opts);

        // Drag-drop into the terminal. Attaches a GtkDropTarget that
        // converts file-manager drops (text/uri-list) to shell-quoted
        // paths and pastes them through VTE's paste path (bracketed
        // paste mode aware). The controller's lifetime is tied to the
        // widget — no separate handle to manage.
        dragdrop.attach(widget);

        const shell_path = try resolveShell(allocator);
        errdefer allocator.free(shell_path);

        // Heap-allocate argv: [argv0, null]. VTE's C signature is
        // `char **` (mutable strings, mutable array). We back it with
        // `?[*:0]u8` slots so the type system matches. The string the
        // first slot points at is `shell_path.ptr` — owned by `self`.
        const argv = try allocator.alloc(?[*:0]u8, 2);
        errdefer allocator.free(argv);
        argv[0] = @ptrCast(shell_path.ptr);
        argv[1] = null;

        vte_terminal_spawn_async(
            terminal,
            VTE_PTY_DEFAULT,
            null, // working_directory: inherit djinn's cwd
            argv.ptr,
            null, // envv: inherit djinn's env
            G_SPAWN_DEFAULT | VTE_SPAWN_NO_SYSTEMD_SCOPE,
            null,
            null,
            null,
            -1, // default timeout
            null,
            null, // no callback
            null,
        );

        // `child-exited(VteTerminal*, gint status, gpointer)` fires
        // when the spawned shell terminates — e.g. the user types
        // `exit`, the kernel kills it, or it segfaults. Hosts wire the
        // handler to `panel.quit()` so the window goes away with the
        // shell rather than presenting a blank terminal. Status is
        // ignored — djinn doesn't restart shells, and the GUI is
        // tearing down anyway.
        var handler_box: ?*Handler = null;
        var child_exited_id: c_ulong = 0;
        if (handler) |h| {
            const box = try allocator.create(Handler);
            errdefer allocator.destroy(box);
            box.* = h;
            child_exited_id = g_signal_connect_data(
                @ptrCast(terminal),
                "child-exited",
                @ptrCast(&onChildExited),
                @ptrCast(box),
                null,
                0,
            );
            handler_box = box;
        }

        return .{
            .widget = widget,
            .allocator = allocator,
            .shell_path = shell_path,
            .argv = argv.ptr,
            .handler_box = handler_box,
            .child_exited_handler_id = child_exited_id,
        };
    }

    pub fn deinit(self: *Terminal) void {
        // Disconnect the child-exited handler before freeing its
        // user_data box. The widget itself is owned by its parent
        // container (set via panel.attachChild), so a dispatch in
        // flight against the still-live widget would otherwise
        // deref a freed Handler.
        if (self.child_exited_handler_id != 0) {
            g_signal_handler_disconnect(@ptrCast(self.widget), self.child_exited_handler_id);
            self.child_exited_handler_id = 0;
        }
        // Reconstitute the slice from the stored pointer + known length
        // (alloc'd as 2 above) so we can hand it back to the allocator.
        const argv_slice = self.argv[0..2];
        self.allocator.free(argv_slice);
        self.allocator.free(self.shell_path);
        if (self.handler_box) |box| self.allocator.destroy(box);
    }

    /// Re-apply theme.Options to a live widget. Same code path as
    /// startup — VTE setters are idempotent and the global CSS
    /// provider gets reloaded in place. Called by the config watcher
    /// on file change so font / colors / padding / opacity can shift
    /// without a restart.
    pub fn applyTheme(self: *Terminal, opts: ThemeOptions) void {
        theme.apply(self.widget, opts);
    }

    /// Adjust VTE's font-scale multiplier in place. Default scale is
    /// 1.0; `delta = 0.1` zooms in 10%, `delta = -0.1` zooms out 10%.
    /// Clamped to [0.4, 4.0] — outside that range text either
    /// hairline-shrinks below readability or hits VTE's internal
    /// metrics caps and starts rendering oddly. Bound to Ctrl+= /
    /// Ctrl+- from the linux keymap.
    pub fn fontScaleAdjust(self: *Terminal, delta: f64) void {
        const terminal: *VteTerminal = @ptrCast(self.widget);
        const current = vte_terminal_get_font_scale(terminal);
        const next = std.math.clamp(current + delta, 0.4, 4.0);
        vte_terminal_set_font_scale(terminal, next);
    }

    /// Reset the font scale to 1.0. Bound to Ctrl+0 from the keymap.
    pub fn fontScaleReset(self: *Terminal) void {
        const terminal: *VteTerminal = @ptrCast(self.widget);
        vte_terminal_set_font_scale(terminal, 1.0);
    }

    /// Copy the current VTE selection to the system clipboard as
    /// plain text. Bound to Ctrl+Shift+C from the keymap. No-op when
    /// no selection exists — VTE handles that internally.
    pub fn copySelectionToClipboard(self: *Terminal) void {
        const terminal: *VteTerminal = @ptrCast(self.widget);
        vte_terminal_copy_clipboard_format(terminal, VTE_FORMAT_TEXT);
    }

    /// Paste the system clipboard contents into VTE as if typed.
    /// Bound to Ctrl+Shift+V from the keymap. VTE handles bracketed-
    /// paste mode automatically when the shell enables it.
    pub fn pasteFromClipboard(self: *Terminal) void {
        const terminal: *VteTerminal = @ptrCast(self.widget);
        vte_terminal_paste_clipboard(terminal);
    }

    /// Clear scrollback + visible + repaint the shell prompt. Bound
    /// to Ctrl+Shift+K from the keymap; iTerm "Cmd+K" / Ghostty
    /// "clear" idiom.
    ///
    /// Two steps because VTE's `reset` alone clears state but leaves
    /// the user staring at an empty buffer with no prompt — the shell
    /// process hasn't been told anything happened, so PS1 doesn't
    /// re-render. Sending `\x0c` (Ctrl+L) through `feed_child` is
    /// readline's "clear-screen + redraw-prompt" hotkey, so bash /
    /// zsh / fish all paint a fresh prompt at the now-cleared top
    /// (and also redraw any half-typed command line, which the user
    /// would otherwise lose). TUIs that grab the PTY (vim, less,
    /// htop) interpret Ctrl+L as their own redraw, which is the
    /// "right thing" in those contexts too.
    ///
    /// Ordering: reset first so the scrollback drop lands before the
    /// shell's response to Ctrl+L arrives — otherwise the prompt
    /// would render, then the reset would scroll it away briefly
    /// before the next paint cycle.
    pub fn clearScrollback(self: *Terminal) void {
        const terminal: *VteTerminal = @ptrCast(self.widget);
        vte_terminal_reset(terminal, 0, 1);
        const ctrl_l = "\x0c";
        vte_terminal_feed_child(terminal, ctrl_l.ptr, @intCast(ctrl_l.len));
    }
};

fn onChildExited(_: *VteTerminal, _: c_int, user_data: gpointer) callconv(.c) void {
    const h: *Handler = @ptrCast(@alignCast(user_data orelse return));
    h.on_child_exited(h.ctx);
}

test "Terminal type compiles" {
    if (builtin.os.tag != .linux) return;
    // Don't actually instantiate — Terminal.open requires a live GTK
    // context (gtk_init must have been called) and we don't bring up
    // a display in tests. This proves the struct declarations
    // type-check; runtime exercise happens via the smoke binary.
    _ = Terminal;
}
