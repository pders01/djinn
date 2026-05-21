//! Find overlay for the VTE terminal.
//!
//! Darwin's equivalent is `terminal/find.zig` (NSTextField chip
//! anchored to the top of the panel, Cmd+F to open, Cmd+G /
//! Cmd+Shift+G to step). Linux mirrors the surface: a `GtkPopover`
//! anchored to the VTE widget with a `GtkSearchEntry` + Prev/Next
//! buttons. VTE has first-class search since 0.40 —
//! `vte_terminal_search_set_regex` + `_find_next` / `_find_previous`
//! drive a PCRE2 regex over the scrollback + visible region.
//!
//! Lifetime: the popover + entry + buttons get built once at startup
//! and live as long as the panel does. `currentRegex` is replaced on
//! every entry-text change; the prior regex is unref'd before the
//! pointer rotates. `deinit` disconnects every signal handler before
//! freeing so a dispatch in-flight against torn-down state can't
//! deref the FindOverlay struct.
//!
//! Bindings (wired in `keymap.zig`):
//!   - Ctrl+Shift+F → open the popover + focus the entry
//!   - Ctrl+G       → find next match (search forward through history)
//!   - Ctrl+Shift+G → find previous match (forward toward the bottom)
//!   - Escape inside the popover closes it; the GTK popover dismisses
//!     automatically on focus loss, so no extra wiring needed.
//!
//! Match direction note: VTE's "next" walks toward the BOTTOM (newer
//! output) and "previous" toward the TOP (older). That matches the
//! browser convention — Ctrl+G repeats the current search going
//! forward in the document, which is "older" in the scrollback. We
//! mirror VTE's naming so the API stays unsurprising to readers
//! familiar with the C side.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");

const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;
const GObject = gtk.GObject;

const g_signal_connect_data = gtk.g_signal_connect_data;
const g_signal_handler_disconnect = gtk.g_signal_handler_disconnect;
const g_object_unref = gtk.g_object_unref;

// ─── VTE search externs ──────────────────────────────────────────────

/// VteRegex is an opaque wrapper around PCRE2's compiled pattern.
/// `vte_regex_new_for_search` is the public builder; the regex is
/// reference-counted via `vte_regex_ref` / `_unref`.
const VteRegex = opaque {};

const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

extern "c" fn g_error_free(err: *GError) void;

/// PCRE2 compile flags. We compose at most two: `MULTILINE` so `^`/`$`
/// match line boundaries, and `CASELESS` so the user's lowercase
/// "todo" matches "TODO" without typing each variation. Values from
/// `<pcre2.h>`; ABI-stable.
const PCRE2_CASELESS: u32 = 0x00000008;
const PCRE2_MULTILINE: u32 = 0x00000400;

extern "c" fn vte_regex_new_for_search(
    pattern: [*]const u8,
    pattern_length: isize,
    flags: u32,
    err: ?*?*GError,
) ?*VteRegex;
extern "c" fn vte_regex_unref(regex: *VteRegex) ?*VteRegex;

extern "c" fn vte_terminal_search_set_regex(
    terminal: *VteTerminal,
    regex: ?*VteRegex,
    flags: u32,
) void;
extern "c" fn vte_terminal_search_find_next(terminal: *VteTerminal) gboolean;
extern "c" fn vte_terminal_search_find_previous(terminal: *VteTerminal) gboolean;
extern "c" fn vte_terminal_search_set_wrap_around(terminal: *VteTerminal, wrap: gboolean) void;

// ─── GTK4 popover + search entry surface ─────────────────────────────

const GtkBox = opaque {};
const GtkButton = opaque {};
const GtkPopover = opaque {};
const GtkEntry = opaque {};
const GtkEditable = opaque {};
const GtkPositionType = c_int;
const GtkOrientation = c_int;

const GTK_POS_BOTTOM: GtkPositionType = 3;
const GTK_ORIENTATION_HORIZONTAL: GtkOrientation = 0;

const GdkRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

extern "c" fn gtk_popover_new() *GtkWidget;
extern "c" fn gtk_popover_set_child(popover: *GtkPopover, child: ?*GtkWidget) void;
extern "c" fn gtk_popover_set_position(popover: *GtkPopover, pos: GtkPositionType) void;
extern "c" fn gtk_popover_set_has_arrow(popover: *GtkPopover, has: gboolean) void;
extern "c" fn gtk_popover_set_autohide(popover: *GtkPopover, autohide: gboolean) void;
extern "c" fn gtk_popover_set_pointing_to(popover: *GtkPopover, rect: ?*const GdkRectangle) void;
extern "c" fn gtk_popover_popup(popover: *GtkPopover) void;
extern "c" fn gtk_popover_popdown(popover: *GtkPopover) void;
extern "c" fn gtk_widget_set_parent(widget: *GtkWidget, parent: *GtkWidget) void;
extern "c" fn gtk_widget_unparent(widget: *GtkWidget) void;
extern "c" fn gtk_widget_grab_focus(widget: *GtkWidget) gboolean;
extern "c" fn gtk_widget_get_width(widget: *GtkWidget) c_int;

extern "c" fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) *GtkWidget;
extern "c" fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;

extern "c" fn gtk_search_entry_new() *GtkWidget;
extern "c" fn gtk_editable_get_text(editable: *GtkEditable) [*:0]const u8;
extern "c" fn gtk_editable_set_text(editable: *GtkEditable, text: [*:0]const u8) void;
extern "c" fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;

extern "c" fn gtk_button_new_from_icon_name(icon: [*:0]const u8) *GtkWidget;
extern "c" fn gtk_button_set_label(button: *GtkButton, label: [*:0]const u8) void;
extern "c" fn gtk_widget_set_tooltip_text(widget: *GtkWidget, text: [*:0]const u8) void;

// ─── Public surface ──────────────────────────────────────────────────

pub const FindOverlay = struct {
    terminal: *VteTerminal,
    popover: *GtkWidget,
    /// Parent widget the popover anchors to. Stored so `open()` can
    /// re-read its width on each popup and rebuild the pointing-to
    /// rect against the live panel size. Same idiom as `palette.open`
    /// / `cheatsheet.open`.
    anchor: *GtkWidget,
    entry: *GtkWidget,
    /// Currently-compiled regex (one per non-empty entry text), or
    /// null when the entry is empty / a compile failed. Owned: each
    /// rotation `vte_regex_unref`s the predecessor before stashing
    /// the new pointer.
    current_regex: ?*VteRegex = null,
    /// Signal id for the entry's `search-changed` (debounced 150ms by
    /// GtkSearchEntry), disconnected by `deinit`. The prev/next
    /// button handlers stash their ids too so a teardown mid-click
    /// can't dispatch into freed state.
    search_changed_id: c_ulong = 0,
    activate_id: c_ulong = 0,
    prev_clicked_id: c_ulong = 0,
    next_clicked_id: c_ulong = 0,
    prev_button: *GtkWidget,
    next_button: *GtkWidget,

    /// Build the popover, parented to `anchor` (typically the VTE
    /// widget). Caller stays responsible for `deinit` — the popover
    /// retains its own ref on the parent through `set_parent`, but the
    /// containing widget owns the popover's lifetime, so the unparent
    /// call in `deinit` must run before the panel teardown chain.
    pub fn init(allocator: std.mem.Allocator, anchor: *GtkWidget, terminal: *VteTerminal) !FindOverlay {
        _ = allocator;

        const popover = gtk_popover_new();
        gtk_popover_set_position(@ptrCast(popover), GTK_POS_BOTTOM);
        // No arrow, no autohide — the panel's hide-on-blur path can
        // tear down the window with the popover still up, and an
        // arrow on a top-anchored popover looks visually noisy against
        // a Quake-drop terminal. Match darwin's chrome-less Find chip.
        gtk_popover_set_has_arrow(@ptrCast(popover), 0);
        gtk_popover_set_autohide(@ptrCast(popover), 1);
        gtk_widget_set_parent(popover, anchor);

        // [search entry | prev | next] in a horizontal box.
        const row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        const entry = gtk_search_entry_new();
        gtk_widget_set_hexpand(entry, 1);

        const prev_button = gtk_button_new_from_icon_name("go-up-symbolic");
        gtk_widget_set_tooltip_text(prev_button, "Find previous (Ctrl+Shift+G)");
        const next_button = gtk_button_new_from_icon_name("go-down-symbolic");
        gtk_widget_set_tooltip_text(next_button, "Find next (Ctrl+G)");

        gtk_box_append(@ptrCast(row), entry);
        gtk_box_append(@ptrCast(row), prev_button);
        gtk_box_append(@ptrCast(row), next_button);
        gtk_popover_set_child(@ptrCast(popover), row);

        // Searches wrap around at the buffer edges by default — match
        // browsers / iTerm. Otherwise the first Enter past the last
        // match silently no-ops.
        vte_terminal_search_set_wrap_around(terminal, 1);

        return .{
            .terminal = terminal,
            .popover = popover,
            .anchor = anchor,
            .entry = entry,
            .prev_button = prev_button,
            .next_button = next_button,
        };
    }

    /// Re-target the overlay onto a different VTE widget. SessionHost
    /// calls this on every profile switch so the find chip's needle
    /// follows the visible terminal — the popover itself stays
    /// parented to the GtkStack (so its anchor doesn't move), only
    /// the underlying search target changes. Re-applies the current
    /// regex (if any) so the next Ctrl+G doesn't miss matches under
    /// the new scrollback. Wrap-around is re-asserted because it's
    /// a per-terminal property, not per-regex.
    pub fn setTarget(self: *FindOverlay, new_vte_widget: *GtkWidget) void {
        const new_term: *VteTerminal = @ptrCast(new_vte_widget);
        self.terminal = new_term;
        vte_terminal_search_set_wrap_around(new_term, 1);
        if (self.current_regex) |regex| {
            vte_terminal_search_set_regex(new_term, regex, 0);
        }
    }

    /// Wire signal handlers. Separate from `init` because the
    /// callbacks need the FindOverlay address as user_data and that
    /// address only stabilizes after the caller has moved the value
    /// onto the host's frame (same pattern as Terminal / LogPane).
    pub fn install(self: *FindOverlay) void {
        self.search_changed_id = g_signal_connect_data(
            @ptrCast(self.entry),
            "search-changed",
            @ptrCast(&onSearchChanged),
            @ptrCast(self),
            null,
            0,
        );
        // Enter inside the entry → find next. GtkSearchEntry's
        // `activate` is the analogue of pressing Enter on a normal
        // entry; `next-match` exists too but only fires for the
        // F-keys / Ctrl+G shortcuts inside the entry, which we'd
        // rather route through the panel-level keymap instead.
        self.activate_id = g_signal_connect_data(
            @ptrCast(self.entry),
            "activate",
            @ptrCast(&onEntryActivate),
            @ptrCast(self),
            null,
            0,
        );
        self.prev_clicked_id = g_signal_connect_data(
            @ptrCast(self.prev_button),
            "clicked",
            @ptrCast(&onPrevClicked),
            @ptrCast(self),
            null,
            0,
        );
        self.next_clicked_id = g_signal_connect_data(
            @ptrCast(self.next_button),
            "clicked",
            @ptrCast(&onNextClicked),
            @ptrCast(self),
            null,
            0,
        );
    }

    pub fn deinit(self: *FindOverlay) void {
        if (self.search_changed_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.entry), self.search_changed_id);
        if (self.activate_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.entry), self.activate_id);
        if (self.prev_clicked_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.prev_button), self.prev_clicked_id);
        if (self.next_clicked_id != 0)
            g_signal_handler_disconnect(@ptrCast(self.next_button), self.next_clicked_id);

        if (self.current_regex) |r| {
            _ = vte_regex_unref(r);
            self.current_regex = null;
        }
        // Detach the popover before the VTE widget gets torn down by
        // its parent. `set_parent` retained a ref the GTK destroy
        // chain can't reach without `unparent`.
        gtk_widget_unparent(self.popover);
    }

    /// Pop up the popover + focus the entry. Idempotent — GTK's
    /// `popup` is a no-op when already visible.
    pub fn open(self: *FindOverlay) void {
        // Without `set_pointing_to`, GTK4 anchors against the parent's
        // full bounds + GTK_POS_BOTTOM, which drops the chip below the
        // panel entirely (same bug `palette.open` hit). Aim at a 1x1
        // rect near the top edge so the chip hangs from the top of the
        // terminal area, matching the browser / iTerm find-bar idiom
        // the surrounding comments call for.
        const w = gtk_widget_get_width(self.anchor);
        const rect: GdkRectangle = .{
            .x = @divTrunc(@max(w, 0), 2),
            .y = 12,
            .width = 1,
            .height = 1,
        };
        gtk_popover_set_pointing_to(@ptrCast(self.popover), &rect);
        gtk_popover_popup(@ptrCast(self.popover));
        _ = gtk_widget_grab_focus(self.entry);
    }

    /// Underlying popover widget. Exposed so `panel.trackPopoverGrabs`
    /// can wire its show/closed signals — the panel needs to suppress
    /// hide-on-blur while this popover holds an input grab. Not for
    /// general consumption.
    pub fn popoverWidget(self: *FindOverlay) *GtkWidget {
        return self.popover;
    }

    pub fn findNext(self: *FindOverlay) void {
        if (self.current_regex == null) return;
        _ = vte_terminal_search_find_next(self.terminal);
    }

    pub fn findPrevious(self: *FindOverlay) void {
        if (self.current_regex == null) return;
        _ = vte_terminal_search_find_previous(self.terminal);
    }
};

// ─── Signal handlers ─────────────────────────────────────────────────

/// Recompile the regex from the entry's current text. Empty text →
/// null regex, which tells VTE to drop its search highlight. Compile
/// failures (mid-typing a regex character class, etc.) also drop the
/// regex so the next valid input compiles cleanly. Each successful
/// recompile auto-fires a `find_next` so the user sees the first
/// match without an extra Enter — matches browser behavior.
fn onSearchChanged(entry_ptr: *GObject, user_data: gpointer) callconv(.c) void {
    const self: *FindOverlay = @ptrCast(@alignCast(user_data orelse return));
    const editable: *GtkEditable = @ptrCast(entry_ptr);
    const text_z = gtk_editable_get_text(editable);
    const text = std.mem.span(text_z);

    if (self.current_regex) |old| {
        _ = vte_regex_unref(old);
        self.current_regex = null;
    }

    if (text.len == 0) {
        vte_terminal_search_set_regex(self.terminal, null, 0);
        return;
    }

    var err: ?*GError = null;
    const flags: u32 = PCRE2_CASELESS | PCRE2_MULTILINE;
    const regex = vte_regex_new_for_search(text.ptr, @intCast(text.len), flags, &err) orelse {
        if (err) |e| g_error_free(e);
        vte_terminal_search_set_regex(self.terminal, null, 0);
        return;
    };
    self.current_regex = regex;
    vte_terminal_search_set_regex(self.terminal, regex, 0);
    _ = vte_terminal_search_find_next(self.terminal);
}

fn onEntryActivate(_: *GObject, user_data: gpointer) callconv(.c) void {
    const self: *FindOverlay = @ptrCast(@alignCast(user_data orelse return));
    self.findNext();
}

fn onPrevClicked(_: *GObject, user_data: gpointer) callconv(.c) void {
    const self: *FindOverlay = @ptrCast(@alignCast(user_data orelse return));
    self.findPrevious();
}

fn onNextClicked(_: *GObject, user_data: gpointer) callconv(.c) void {
    const self: *FindOverlay = @ptrCast(@alignCast(user_data orelse return));
    self.findNext();
}

test "FindOverlay struct compiles" {
    if (builtin.os.tag != .linux) return;
    // Pure type check — runtime exercise requires a live GTK + VTE
    // context. The structural smoke is enough to catch a wrong-extern-
    // type regression at build time.
    _ = FindOverlay;
}
