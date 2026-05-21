//! Multi-profile VTE container backed by GtkStack.
//!
//! Linux analogue of darwin's per-NSView ghostty-surface lifecycle in
//! `src/ghostty/surface_lifecycle.zig`. SessionHost owns one VTE
//! widget per profile, all parented to a single `GtkStack` that shows
//! the visible session and hides the rest. Switching profiles is a
//! `gtk_stack_set_visible_child_name` call + a focus grab on the
//! revealed VTE; nothing reparented, no widget rebuild.
//!
//! Spawn timing matches darwin: the active-at-startup session's VTE
//! is built + spawned eagerly so the first paint shows that profile's
//! shell. Other sessions get their VTE lazily on first `activate(idx)`
//! so a 6-profile config doesn't spend 6× the startup cost on shells
//! the user may never look at.
//!
//! Lifetime / ownership:
//!
//!   - Each `Entry` holds a `Terminal` (which owns argv + command_path
//!     + cwd_path + child-exited handler box) plus a sentinel-
//!     terminated `name` slot used as the GtkStack child name. The
//!     name is `"session-<idx>"` — index-based rather than profile-
//!     name-based — because GtkStack requires C-string ownership for
//!     the name and indexes give us a stable buffer regardless of
//!     what the user types as a profile name.
//!   - `SessionHost` does NOT own the `SessionManager`. main_linux
//!     constructs both side-by-side and the lifetimes are coupled.
//!     SessionHost reads sm.active_idx + profile fields; the active
//!     index is the single source of truth for "which session is
//!     visible".
//!   - VTE widgets parented into the GtkStack are owned by the stack.
//!     `deinit` calls `Terminal.deinit` for each entry to release
//!     argv/handler state; the widget itself is dropped when the
//!     stack drops (via panel destroy chain).
//!
//! What SessionHost doesn't do (deferred):
//!
//!   - Hot-reload reconcile (`addSession` / `removeSession` from a
//!     watcher-driven profile diff). Wired in a follow-up commit so
//!     the initial landing stays minimal.
//!   - Find overlay re-target on switch. SessionHost calls
//!     `find_overlay.setTarget(currentVte())` when the late-stamped
//!     pointer is non-null; the FindOverlay API gain lands alongside.
//!
//! What SessionHost does do: restart-session via `restartActive` —
//! hangs up the active VTE's child and re-spawns into the same widget
//! (Ctrl+R / Ctrl+Shift+R from the keymap). Per-profile window-size
//! memory rides the `on_switch` hook on the main_linux side so the
//! Dispatch can reach Panel + state.json without SessionHost owning
//! either.
//!
//! Switch-event fan-out: `on_switch`, when set, fires once per
//! `activate(idx)` call that actually moved the visible session. Used
//! by the tab strip to re-skin the active chip without tab_strip and
//! session_host depending on each other's types — keeps the cycle
//! broken in the same shape as `find_overlay`'s late-stamped pointer.

const std = @import("std");
const gtk = @import("gtk.zig");
const SessionManager = @import("../../session/manager.zig").SessionManager;
const Terminal = @import("terminal.zig").Terminal;
const TerminalSpawn = @import("terminal.zig").Spawn;
const TerminalHandler = @import("terminal.zig").Handler;
const ThemeOptions = @import("terminal.zig").ThemeOptions;
const FindOverlay = @import("find_overlay.zig").FindOverlay;

const GtkWidget = gtk.GtkWidget;
const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

// ─── GtkStack extern surface ─────────────────────────────────────────
//
// GtkStack is GTK4's "show one of N children" container. It's the
// natural fit for multi-profile: we attach every VTE as a named child
// and switch via `set_visible_child_name`. Transitions are off
// (duration 0) so the profile flip feels instantaneous; a fade would
// just add latency to a UI gesture that should be hard-cut.

const GtkStack = opaque {};
extern "c" fn gtk_stack_new() *GtkWidget;
extern "c" fn gtk_stack_add_named(
    stack: *GtkStack,
    child: *GtkWidget,
    name: [*:0]const u8,
) *anyopaque;
extern "c" fn gtk_stack_set_visible_child_name(stack: *GtkStack, name: [*:0]const u8) void;
extern "c" fn gtk_stack_set_transition_duration(stack: *GtkStack, duration: c_uint) void;
extern "c" fn gtk_stack_remove(stack: *GtkStack, child: *GtkWidget) void;

extern "c" fn gtk_widget_grab_focus(widget: *GtkWidget) gboolean;

// ─── SessionHost ─────────────────────────────────────────────────────

/// Fan-out hook for the "active session changed" event. main_linux
/// stamps a handler that calls `tab_strip.markActive(idx)` so the
/// chip indicator follows every activate path (mouse click, keymap,
/// future palette switcher). Kept as a structural callback rather
/// than a direct `*TabStrip` slot so session_host stays free of the
/// concrete UI module — same shape as the existing `FindOverlay`
/// late-stamped pointer but without the type dependency.
pub const OnSwitch = struct {
    ctx: *anyopaque,
    on_invoke: *const fn (ctx: *anyopaque, idx: usize) void,
};

/// Fan-out hook for "this entry's exited state flipped." Fires once
/// per `markExited` call where the new value actually differs from
/// the old. Caller wires it to `tab_strip.markExited` so the chip
/// gains the `.djinn-tab-exited` class when an inactive session's
/// child dies and loses it when `restartActive` revives the slot.
pub const OnExitChanged = struct {
    ctx: *anyopaque,
    on_invoke: *const fn (ctx: *anyopaque, idx: usize, exited: bool) void,
};

/// Per-session bookkeeping. The `terminal` slot is null until first
/// activate: SessionHost builds the VTE + spawns the shell on demand
/// so a config with many profiles doesn't pay the startup cost for
/// every one.
const Entry = struct {
    /// Stable child name for `gtk_stack_set_visible_child_name`.
    /// Buffer lives on the Entry so the pointer handed to GTK stays
    /// valid for the SessionHost's lifetime — GtkStack copies the
    /// name internally on `add_named`, but the safer story is to own
    /// it ourselves.
    name: [16]u8,
    name_z: [*:0]const u8,
    terminal: ?Terminal = null,
    /// True once this session's shell has exited *without* a
    /// SessionHost-driven restart. Set on every child-exit (active
    /// or inactive; the panel never closes on shell exit), cleared
    /// by `restartActive` after a successful re-spawn. Tab strip
    /// reads the flip via the host's `on_exit_changed` hook to
    /// re-skin the chip (dim + strikethrough). User revives the
    /// session by activating its chip and hitting Ctrl+R.
    exited: bool = false,
};

pub const SessionHost = struct {
    allocator: std.mem.Allocator,
    sm: *SessionManager,
    stack: *GtkWidget,
    entries: std.ArrayList(Entry) = .{},
    /// Captured at init + refreshed by `applyTheme` so a hot-spawn
    /// of a previously-lazy session paints with the current palette
    /// instead of VTE defaults.
    theme_opts: ThemeOptions,
    /// Handler template fanned to every spawned VTE. Each spawn copies
    /// the template and stamps `extra = idx` so the host's
    /// `on_child_exited` callback can tell which session just lost its
    /// shell. The dispatcher flips `entry.exited` and feeds an inline
    /// banner via `terminalAt(idx).?.feedScreen` so the user sees the
    /// session is dead. The shared template's own `extra` field is
    /// unread; SessionHost overwrites it per session.
    handler: ?TerminalHandler,
    /// Late-stamped pointer to the find overlay so each `activate`
    /// can call `setTarget(new_vte)` and keep the find chip's
    /// search target in lockstep with the visible profile. Null
    /// during the brief window between SessionHost.init and the
    /// FindOverlay's own init; the activate path null-checks.
    find_overlay: ?*FindOverlay = null,
    /// Late-stamped switch-event hook. Fires once per `activate`
    /// that actually changed the visible session. Set by main_linux
    /// after the tab strip is constructed; null until then, so
    /// activates during init are silently consumed (the initial
    /// chip state is set by the tab strip's own `buildButtons`).
    on_switch: ?OnSwitch = null,
    /// Late-stamped exit-state hook. Fires once per `markExited`
    /// call that actually flipped a bit. Set by main_linux after the
    /// tab strip is built. Null during init, so any flip before
    /// wiring is silently consumed — none happen in practice
    /// (init's eager spawn doesn't dispatch child-exited).
    on_exit_changed: ?OnExitChanged = null,

    /// Build the stack, eagerly spawn the active-at-startup session,
    /// leave the rest as lazy slots. Returns a SessionHost the caller
    /// embeds into its layout via `widget()`.
    ///
    /// `handler` is shared across every session; SessionHost stamps
    /// per-session `extra = idx` in `handlerFor(idx)` so the
    /// dispatcher can identify the firing session and mark it
    /// exited / paint its banner.
    pub fn init(
        allocator: std.mem.Allocator,
        sm: *SessionManager,
        theme_opts: ThemeOptions,
        handler: ?TerminalHandler,
    ) !SessionHost {
        const stack = gtk_stack_new();
        gtk_stack_set_transition_duration(@ptrCast(stack), 0);

        var entries: std.ArrayList(Entry) = .{};
        errdefer entries.deinit(allocator);
        try entries.ensureTotalCapacity(allocator, sm.count());

        // Allocate name slots up front for every session so the
        // pointers we hand to GtkStack on add_named stay stable
        // regardless of how many appends happen later. Names are
        // index-based to dodge any UTF-8 / shell-meta concerns in
        // user-typed profile names.
        //
        // Write the name + pointer DIRECTLY into the stored Entry's
        // memory — not into a stack-local that's then copied via
        // `appendAssumeCapacity`. The stack-local pattern made
        // `name_z` point at the loop frame's `e.name`, which the next
        // iteration reused, so every stored `name_z` resolved to the
        // last-iteration's name buffer ("session-N-1"). That made
        // `gtk_stack_add_named` collide on every non-eager spawn and
        // `gtk_stack_set_visible_child_name` always select the same
        // (initial) session — switching was visually a no-op.
        var i: usize = 0;
        while (i < sm.count()) : (i += 1) {
            entries.appendAssumeCapacity(.{ .name = undefined, .name_z = undefined });
            const stored: *Entry = &entries.items[i];
            _ = std.fmt.bufPrintZ(&stored.name, "session-{d}", .{i}) catch
                return error.NameBufferTooSmall;
            stored.name_z = @ptrCast(&stored.name[0]);
        }

        var host: SessionHost = .{
            .allocator = allocator,
            .sm = sm,
            .stack = stack,
            .entries = entries,
            .theme_opts = theme_opts,
            .handler = handler,
        };

        // Eagerly spawn just the active session — see `spawnInto` for
        // the lazy fill of others on first activate.
        try host.spawnInto(sm.active_idx);
        // GtkStack tracks visible-child-name; setting it after the
        // eager spawn anchors the panel on the right profile from
        // the first paint.
        const active_name = host.entries.items[sm.active_idx].name_z;
        gtk_stack_set_visible_child_name(@ptrCast(stack), active_name);

        return host;
    }

    pub fn deinit(self: *SessionHost) void {
        for (self.entries.items) |*e| {
            if (e.terminal) |*t| t.deinit();
        }
        self.entries.deinit(self.allocator);
    }

    /// The GtkStack widget. Pass into the GtkPaned (as the start
    /// child, replacing the single VTE that lived there pre-multi-
    /// profile) so the log pane keeps its position to the right.
    pub fn widget(self: *SessionHost) *GtkWidget {
        return self.stack;
    }

    /// VTE widget for the currently-active session, or null if its
    /// spawn slot is still empty (shouldn't happen post-init since
    /// the active session is eager-spawned). Callers that need the
    /// active terminal (find overlay, keymap font / clipboard /
    /// scroll handlers) reach through this getter so they don't
    /// have to track the active index themselves.
    pub fn currentVte(self: *SessionHost) ?*GtkWidget {
        if (self.sm.active_idx >= self.entries.items.len) return null;
        const e = &self.entries.items[self.sm.active_idx];
        if (e.terminal) |*t| return t.widget;
        return null;
    }

    /// Owned Terminal for the currently-active session. Same null
    /// story as `currentVte`. Keymap handlers reach through this for
    /// `fontScaleAdjust` / `clearScrollback` / `copySelection*` /
    /// `paste*` / `scrollPages`.
    pub fn currentTerminal(self: *SessionHost) ?*Terminal {
        if (self.sm.active_idx >= self.entries.items.len) return null;
        const e = &self.entries.items[self.sm.active_idx];
        if (e.terminal) |*t| return t;
        return null;
    }

    /// Switch the visible session to `idx`. Returns true when a
    /// switch actually happened — false when idx is out of bounds,
    /// already-active, or the lazy spawn failed.
    ///
    /// Lazy-spawns the target session's VTE on first activate.
    /// Focus is grabbed on the revealed VTE: GtkStack's visible-
    /// child flip doesn't move keyboard focus on its own, and the
    /// panel-level shortcut controller (MANAGED scope) dispatches
    /// off the focused widget's chain, so without an explicit grab
    /// the new VTE wouldn't receive typing.
    pub fn activate(self: *SessionHost, idx: usize) bool {
        if (idx >= self.entries.items.len) return false;
        if (idx == self.sm.active_idx) {
            // Already active — still re-grab focus in case the user
            // clicked the tab strip from a non-focused state. Cheap.
            if (self.currentVte()) |w| _ = gtk_widget_grab_focus(w);
            return false;
        }

        // Lazy spawn if the target slot is still empty.
        if (self.entries.items[idx].terminal == null) {
            self.spawnInto(idx) catch |err| {
                std.debug.print(
                    "session_host: spawn for profile '{s}' failed: {} — staying on current\n",
                    .{ self.sm.sessions.items[idx].profile.name, err },
                );
                return false;
            };
        }

        // Flip SessionManager's active index AFTER the spawn has
        // either succeeded or been determined unnecessary — failed
        // spawn above already early-returns, so reaching here means
        // we have a live VTE to switch to.
        _ = self.sm.switchTo(idx);

        const target_name = self.entries.items[idx].name_z;
        gtk_stack_set_visible_child_name(@ptrCast(self.stack), target_name);

        if (self.currentVte()) |w| {
            _ = gtk_widget_grab_focus(w);
            // Keep the find overlay's search target in lockstep with
            // the visible profile. Cheap: a regex re-apply + a
            // wrap-around flag flip. The popover anchor stays on
            // the GtkStack, so no reparenting needed.
            if (self.find_overlay) |fo| fo.setTarget(w);
        }
        // Fan the switch event to any registered observer (tab strip
        // today). Runs after the VTE focus grab so a handler that
        // pokes at the widget tree sees the new visible child.
        if (self.on_switch) |hook| hook.on_invoke(hook.ctx, idx);
        return true;
    }

    /// Hangup the active session's child and replace the VTE widget
    /// in place. `override_cmd` non-null swaps the profile's resolved
    /// command — `shell_session` (Ctrl+Shift+R) passes `/bin/zsh` so
    /// the user can drop out of a broken profile script. `null`
    /// keeps the profile's command (`restart_session` Ctrl+R). cwd
    /// is the profile's in both cases.
    ///
    /// Strategy: build the fresh Terminal FIRST (so an OOM doesn't
    /// strand the slot empty), then detach the old's exit signal,
    /// `gtk_stack_remove` the old widget (which finalizes it, VTE
    /// closes the pty, child gets SIGHUP), deinit the old Terminal's
    /// owned strings, and add the new widget under the same stack
    /// name. Same tab, same log pane, same window position; only
    /// the VTE widget under the hood is fresh.
    ///
    /// Why detach the old handler first: the SIGHUP from
    /// `gtk_stack_remove` would otherwise race into
    /// `markExited(idx, true)` just before the new spawn lands,
    /// flickering the chip and painting a stale "Process exited"
    /// banner into a buffer about to be discarded.
    ///
    /// Why widget replacement, not in-place re-spawn:
    /// `vte_terminal_set_pty(t, NULL)` NULL-derefs at +0x18 inside
    /// VTE 0.84's PTY dispose path when the prior spawn's child
    /// watch isn't fully wired. Trying to hangup-then-respawn the
    /// same widget crashed the panel. Tearing the widget down and
    /// building a fresh one sidesteps the whole codepath; matches
    /// what darwin does in `restartSurfaceCallback` (free old
    /// surface, bind a fresh surface to the same NSView).
    pub fn restartActive(self: *SessionHost, override_cmd: ?[]const u8) bool {
        const idx = self.sm.active_idx;
        if (idx >= self.entries.items.len) return false;
        const entry = &self.entries.items[idx];
        if (entry.terminal == null) return false;
        const profile = &self.sm.sessions.items[idx].profile;

        // Build the new Terminal first so a spawn-arg error / OOM
        // doesn't strand the entry empty after we've already torn
        // the old widget down.
        const spawn: TerminalSpawn = if (override_cmd) |c|
            .{ .command = c, .cwd = profile.cwd }
        else
            .{ .command = profile.command, .cwd = profile.cwd };
        const new_term = Terminal.open(self.allocator, self.theme_opts, self.handlerFor(idx), spawn) catch |err| {
            std.debug.print(
                "session_host: restart for profile '{s}' failed: {}\n",
                .{ profile.name, err },
            );
            return false;
        };

        // Commit: detach old handler (so the imminent SIGHUP doesn't
        // race into markExited on the about-to-be-replaced slot),
        // remove old widget (finalize → pty close → child SIGHUP),
        // deinit old Terminal's owned strings.
        var old_term = entry.terminal.?;
        old_term.detachExitHandler();
        gtk_stack_remove(@ptrCast(self.stack), old_term.widget);
        old_term.deinit();

        // Swap the new Terminal into the entry, re-add under the
        // same stack name (now available since we removed the old),
        // re-anchor visibility + focus.
        entry.terminal = new_term;
        _ = gtk_stack_add_named(
            @ptrCast(self.stack),
            new_term.widget,
            entry.name_z,
        );
        gtk_stack_set_visible_child_name(@ptrCast(self.stack), entry.name_z);
        _ = gtk_widget_grab_focus(new_term.widget);
        // Clear the exited bit AFTER the new spawn lands so a partial
        // failure (caught above) leaves the chip showing exited.
        // markExited fans the hook only when the bit actually flips,
        // so a normal "Ctrl+R on a live session" path is a no-op.
        self.markExited(idx, false);
        return true;
    }

    /// Cycle to the next session (with wrap). No-op when sm has < 2
    /// sessions. Used by the `next_tab` keymap action.
    pub fn activateNext(self: *SessionHost) bool {
        const next = self.sm.peekNext() orelse return false;
        return self.activate(next);
    }

    /// Cycle to the previous session (with wrap). Same shape as
    /// `activateNext`. Used by the `prev_tab` keymap action.
    pub fn activatePrev(self: *SessionHost) bool {
        const prev = self.sm.peekPrev() orelse return false;
        return self.activate(prev);
    }

    /// Re-apply theme to every live VTE. Called by the watcher reload
    /// path so a config save flips colors / fonts / palette across
    /// all profiles simultaneously. Lazy-spawn slots pick up the new
    /// theme on first activate via the cached `theme_opts` field.
    pub fn applyTheme(self: *SessionHost, opts: ThemeOptions) void {
        self.theme_opts = opts;
        for (self.entries.items) |*e| {
            if (e.terminal) |*t| t.applyTheme(opts);
        }
    }

    /// Build the VTE for `idx`, spawn its shell, and add it to the
    /// stack under the entry's pre-allocated name. Caller has
    /// verified the slot is empty (`entries[idx].terminal == null`).
    fn spawnInto(self: *SessionHost, idx: usize) !void {
        const profile = &self.sm.sessions.items[idx].profile;
        const term = try Terminal.open(
            self.allocator,
            self.theme_opts,
            self.handlerFor(idx),
            .{
                .command = profile.command,
                .cwd = profile.cwd,
            },
        );
        self.entries.items[idx].terminal = term;
        _ = gtk_stack_add_named(
            @ptrCast(self.stack),
            term.widget,
            self.entries.items[idx].name_z,
        );
    }

    /// Per-session copy of the host's child-exited handler template,
    /// with `extra` stamped to the session index so the dispatcher
    /// can tell which session fired. Null when no template was
    /// supplied (no callers today, but the field is optional).
    fn handlerFor(self: *SessionHost, idx: usize) ?TerminalHandler {
        const tmpl = self.handler orelse return null;
        return .{
            .ctx = tmpl.ctx,
            .extra = idx,
            .on_child_exited = tmpl.on_child_exited,
        };
    }

    /// Flip the entry's exited bit and fan `on_exit_changed` when the
    /// value actually changes. Called by main_linux from the
    /// child-exited dispatcher for inactive sessions, and by
    /// `restartActive` to clear the bit after a successful revive.
    /// Idempotent: same-value calls return without firing.
    pub fn markExited(self: *SessionHost, idx: usize, value: bool) void {
        if (idx >= self.entries.items.len) return;
        if (self.entries.items[idx].exited == value) return;
        self.entries.items[idx].exited = value;
        if (self.on_exit_changed) |hook| hook.on_invoke(hook.ctx, idx, value);
    }

    /// True when the entry at `idx` has its child-exited bit set.
    /// Out-of-bounds idx resolves to false. Used by callers that want
    /// to know without subscribing to `on_exit_changed`.
    pub fn isExited(self: *SessionHost, idx: usize) bool {
        if (idx >= self.entries.items.len) return false;
        return self.entries.items[idx].exited;
    }

    /// Mutable pointer to the Terminal at `idx`, or null when the
    /// slot is lazy (never activated) or `idx` is out of bounds.
    /// Used by the child-exited dispatcher to feed an inline banner
    /// into the VTE that just lost its shell.
    pub fn terminalAt(self: *SessionHost, idx: usize) ?*Terminal {
        if (idx >= self.entries.items.len) return null;
        return if (self.entries.items[idx].terminal) |*t| t else null;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "SessionHost: type compiles" {
    // Runtime exercise requires gtk_init + a display; this just
    // proves the struct + extern declarations type-check. Same
    // pattern as terminal.zig's compile-only smoke test.
    _ = SessionHost;
    _ = Entry;
}
