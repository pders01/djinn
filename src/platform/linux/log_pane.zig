//! Linux log pane.
//!
//! Right-hand column of the panel showing a chronological stream of
//! `AgentState.log` entries. Linux analogue of darwin's
//! `agent/log_view.zig`, but trimmed to MVP scope: scrolling list of
//! rows, per-level color, auto-scroll to newest. The richer surface
//! (sticky-attention chip, free-text filter, client-grouped headers)
//! lives on darwin's NSTextView and lands on linux as follow-ups —
//! basic append is the first slice.
//!
//! Widget tree:
//!
//!   GtkBox (vertical)              ← `widget()` returns this
//!     ├─ GtkButton                 ← sticky-attention chip (hidden by default)
//!     │    └─ GtkLabel
//!     ├─ GtkScrolledWindow
//!     │    └─ GtkListBox           ← rows appended here
//!     │         └─ GtkListBoxRow ✕ N
//!     │              └─ GtkLabel   ← "{client} [LEVEL] message"
//!     └─ GtkSearchEntry            ← case-insensitive substring filter
//!
//! Caller wraps `widget()` inside a GtkPaned with the VteTerminal as
//! the start child; `main_linux.zig` owns that composition because the
//! divider position depends on `config.window.width` which the log
//! pane doesn't see.
//!
//! The attention chip pins the latest `AgentState.attention` message
//! at the top of the pane and clears on click (`ackAttention`). It
//! lives outside the scrolledwindow so a long log doesn't push it out
//! of view — same behavior as darwin's `attention_banner` overlay.
//!
//! Poll model: same shape as `tray.zig::observeAgentState` — a 250ms
//! `g_timeout_add` source ticks on the GLib main thread, snapshots
//! `AgentState.log.items.len` + the first entry's timestamp under the
//! state mutex, then diffs against last-seen. Three outcomes:
//!
//!   - count + first_ts both unchanged → no-op
//!   - count grew + first_ts unchanged → append new rows
//!   - anything else                   → rebuild from scratch
//!
//! The rebuild branch catches ring-buffer eviction (oldest entry got
//! dropped, shifting timestamps) and the initial snapshot. Realistic
//! agent workloads append a handful of entries per second, so the
//! delta path is the hot one and the rebuild is rare.
//!
//! Styling: a module-local `GtkCssProvider` paints the background
//! with the resolved theme color and assigns per-level colors via
//! `.djinn-log-{info,warn,err}` CSS classes on each row's label.
//! Kept separate from `theme.zig`'s shared provider — that one is
//! tuned for the VTE widget; mixing log rules in would couple the
//! modules without payoff.
//!
//! CSS-node gotcha: GtkListBox's CSS node is `list`, NOT `listbox`
//! (mirrors GtkListView's `list` and matches GTK4's convention of
//! short element-style names). Selectors like `listbox.foo` silently
//! never match — easy to lose hours to.

const std = @import("std");
const gtk = @import("gtk.zig");
const AgentState = @import("../../agent/state.zig").AgentState;
const LogEntry = @import("../../agent/state.zig").LogEntry;
const ThemeOptions = @import("terminal.zig").ThemeOptions;
const LogModel = @import("log_model.zig").LogModel;

const GtkWidget = gtk.GtkWidget;
const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

// ─── GTK4 / GLib extern surface ──────────────────────────────────────

const GtkListBox = opaque {};
const GtkListBoxRow = opaque {};
const GtkScrolledWindow = opaque {};
const GtkAdjustment = opaque {};
const GtkLabel = opaque {};
const GtkPaned = opaque {};
const GtkBox = opaque {};
const GtkButton = opaque {};
const GtkSearchEntry = opaque {};
const GtkEditable = opaque {};
const GtkCssProvider = gtk.GtkCssProvider;
const GdkDisplay = gtk.GdkDisplay;
const GObject = gtk.GObject;

// GtkPolicyType: GTK_POLICY_ALWAYS=0, AUTOMATIC=1, NEVER=2, EXTERNAL=3.
const GTK_POLICY_AUTOMATIC: c_int = 1;
const GTK_POLICY_NEVER: c_int = 2;
// GtkSelectionMode: NONE=0, SINGLE=1, …
const GTK_SELECTION_NONE: c_int = 0;
// GtkOrientation: HORIZONTAL=0, VERTICAL=1.
const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
// Matches GTK_STYLE_PROVIDER_PRIORITY_APPLICATION — above theme.
const STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;
// GSource return codes for g_timeout_add callback.
const G_SOURCE_CONTINUE: c_int = 1;

extern "c" fn gtk_scrolled_window_new() *GtkWidget;
extern "c" fn gtk_scrolled_window_set_child(sw: *GtkScrolledWindow, child: ?*GtkWidget) void;
extern "c" fn gtk_scrolled_window_set_policy(sw: *GtkScrolledWindow, h: c_int, v: c_int) void;
extern "c" fn gtk_scrolled_window_get_vadjustment(sw: *GtkScrolledWindow) *GtkAdjustment;

extern "c" fn gtk_adjustment_get_upper(adj: *GtkAdjustment) f64;
extern "c" fn gtk_adjustment_get_page_size(adj: *GtkAdjustment) f64;
extern "c" fn gtk_adjustment_set_value(adj: *GtkAdjustment, value: f64) void;

extern "c" fn gtk_list_box_new() *GtkWidget;
extern "c" fn gtk_list_box_append(box: *GtkListBox, child: *GtkWidget) void;
extern "c" fn gtk_list_box_remove_all(box: *GtkListBox) void;
extern "c" fn gtk_list_box_set_selection_mode(box: *GtkListBox, mode: c_int) void;

extern "c" fn gtk_label_new(str: ?[*:0]const u8) *GtkWidget;
extern "c" fn gtk_label_set_xalign(label: *GtkLabel, xalign: f32) void;
extern "c" fn gtk_label_set_wrap(label: *GtkLabel, wrap: gboolean) void;
extern "c" fn gtk_label_set_selectable(label: *GtkLabel, selectable: gboolean) void;
extern "c" fn gtk_label_get_text(label: *GtkLabel) [*:0]const u8;

// GtkGestureClick: a GtkEventController subclass that fires
// `pressed(n_press, x, y)` on button-down. We attach one per log
// row to power right-click "copy entry". `set_button(3)` restricts
// to the secondary button so left-click + drag selection on the
// label's text (gtk_label_set_selectable) still works as expected.
const GtkGesture = gtk.GtkEventController;
extern "c" fn gtk_gesture_click_new() *gtk.GtkEventController;
extern "c" fn gtk_gesture_single_set_button(gesture: *GtkGesture, button: c_uint) void;
extern "c" fn gtk_event_controller_get_widget(controller: *gtk.GtkEventController) ?*GtkWidget;
extern "c" fn gtk_widget_get_display(widget: *GtkWidget) ?*GdkDisplay;

// Clipboard surface — same pattern as `keymap.zig::mcp_copy_endpoint`.
const GdkClipboard = opaque {};
extern "c" fn gdk_display_get_clipboard(display: *GdkDisplay) ?*GdkClipboard;
extern "c" fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;

const GDK_BUTTON_SECONDARY: c_uint = 3;

extern "c" fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, w: c_int, h: c_int) void;
extern "c" fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
const gtk_widget_set_visible = gtk.gtk_widget_set_visible;
const gtk_widget_get_visible = gtk.gtk_widget_get_visible;
const gtk_widget_add_controller = gtk.gtk_widget_add_controller;

extern "c" fn gtk_paned_new(orientation: c_int) *GtkWidget;
extern "c" fn gtk_paned_set_start_child(paned: *GtkPaned, child: *GtkWidget) void;
extern "c" fn gtk_paned_set_end_child(paned: *GtkPaned, child: *GtkWidget) void;
extern "c" fn gtk_paned_set_position(paned: *GtkPaned, position: c_int) void;
extern "c" fn gtk_paned_get_position(paned: *GtkPaned) c_int;

extern "c" fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
extern "c" fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;

extern "c" fn gtk_button_new_with_label(label: [*:0]const u8) *GtkWidget;
extern "c" fn gtk_button_set_label(button: *GtkButton, label: [*:0]const u8) void;

extern "c" fn gtk_search_entry_new() *GtkWidget;
extern "c" fn gtk_editable_get_text(editable: *GtkEditable) [*:0]const u8;
extern "c" fn gtk_editable_set_text(editable: *GtkEditable, text: [*:0]const u8) void;

// Shared GLib / GTK helpers — see gtk.zig for the canonical declarations.
const g_signal_connect_data = gtk.g_signal_connect_data;
const g_signal_handler_disconnect = gtk.g_signal_handler_disconnect;
const g_timeout_add = gtk.g_timeout_add;
const g_source_remove = gtk.g_source_remove;
const g_idle_add = gtk.g_idle_add;
const g_object_unref = gtk.g_object_unref;
const gtk_css_provider_new = gtk.gtk_css_provider_new;
const gtk_css_provider_load_from_string = gtk.gtk_css_provider_load_from_string;
const gtk_style_context_add_provider_for_display = gtk.gtk_style_context_add_provider_for_display;
const gdk_display_get_default = gtk.gdk_display_get_default;

// ─── Public surface ──────────────────────────────────────────────────

/// Which placeholder row, if any, sits in the listbox in place of
/// real entries. `.no_activity` is the initial state until the first
/// MCP-driven log append; `.no_matches` replaces it when the user
/// has typed a filter that rejects every existing entry. The two
/// have distinct text so the failure mode is unambiguous — a user
/// looking at an empty pane needs to know whether their filter is
/// too narrow vs. their agent is just quiet.
const Placeholder = enum { none, no_activity, no_matches };

/// Caller-supplied handler for divider drags. Fires on each
/// `notify::position` emission from the paned — typically ~60Hz
/// during an interactive drag. `position` is the start-child width
/// in pixels (matches `gtk_paned_get_position`'s units). main_linux
/// routes this to `persist.saveDividerDebounced` so the 300ms worker
/// flattens the burst into one disk write per gesture.
pub const DividerHandler = struct {
    ctx: *anyopaque,
    on_change: *const fn (ctx: *anyopaque, position: i32) void,
};

/// The log pane is constructed once at startup and lives until the
/// panel does. `container` is the outer vertical box the caller hands
/// to GtkPaned (so `setVisible` collapses both chip + list together);
/// `scrolled` is kept for adjustment access and `list_box` for
/// append/rebuild paths. `attention_button` is the sticky-attention
/// chip pinned at the top of the column (hidden until
/// `AgentState.pinned_attention` is non-null). `provider` is held so
/// it can be unref'd on deinit even though GTK retains its own ref
/// through `add_provider_for_display`.
pub const LogPane = struct {
    allocator: std.mem.Allocator,
    container: *GtkWidget,
    attention_button: *GtkWidget,
    scrolled: *GtkWidget,
    list_box: *GtkWidget,
    search_entry: *GtkWidget,
    provider: *GtkCssProvider,

    /// Set by `observeAgentState`. Null until observation starts.
    /// Also read by `onAttentionClicked` to call `ackAttention` —
    /// the button is hidden until pinned_attention is non-null,
    /// which can only happen after observation starts, so the
    /// click path is implicitly gated.
    observed_state: ?*AgentState = null,
    /// `g_timeout_add` tag for the poll loop; 0 means unset.
    poll_source_id: c_uint = 0,
    /// Signal ids for the attention-chip `clicked` and search-entry
    /// `search-changed` handlers wired in `observeAgentState`. Both
    /// stay 0 until first observation; `deinit` disconnects each
    /// before unref'ing the CSS provider so a dispatch in flight
    /// against torn-down state doesn't deref freed memory through
    /// user_data (each captures `self`).
    attention_clicked_id: c_ulong = 0,
    search_changed_id: c_ulong = 0,
    /// Number of log entries the pane has materialized into rows.
    /// Compared against the live state count to decide append vs
    /// rebuild on each tick.
    last_seen_count: usize = 0,
    /// Timestamp of the oldest entry the pane has seen. When the live
    /// ring evicts, the first entry's timestamp changes — that's the
    /// signal to rebuild rather than append.
    last_seen_first_ts: i64 = 0,
    /// Tracks whether `last_seen_*` has been initialized at least
    /// once. Distinguishes "first tick, log already non-empty" from
    /// "log was just appended to" in the diff branches.
    initialized: bool = false,
    /// Which placeholder row is currently showing, if any. Drives
    /// `refreshPlaceholder` — distinguishes the "fresh pane, no MCP
    /// traffic yet" message from the "filter matched nothing"
    /// message. `.none` while real entry rows are visible.
    placeholder: Placeholder = .none,
    /// Number of real (non-placeholder) rows currently in the list.
    /// Bumped on append, reset on full clear. Combined with
    /// `model.hasActiveFilter()` + `last_seen_count`, this is what
    /// `refreshPlaceholder` reads to pick the right placeholder.
    rendered_count: usize = 0,
    /// Local copy of the currently-rendered attention message so the
    /// poll tick can no-op when the pinned message hasn't changed.
    /// Mirrors darwin `LogView.attention_buf` / `attention_len`.
    attention_buf: [256]u8 = undefined,
    attention_len: usize = 0,
    /// Pure-data model: filter needle + last-client tracking for
    /// client-grouped headers. Extracted into its own file so the
    /// hot-path logic is unit-testable without GTK init. Methods on
    /// `LogModel` are called inline from the tick / rebuild paths
    /// below; see `log_model.zig` for the contract.
    model: LogModel = .{},
    /// Cached GtkPaned built by `pairWithSibling`. Null until that
    /// method runs. `setOnDividerChange` reads it to connect the
    /// `notify::position` signal so divider drags can persist to
    /// state.json without main_linux.zig holding its own paned
    /// pointer.
    paned: ?*GtkPaned = null,
    divider_handler: ?DividerHandler = null,
    /// `notify::position` signal id (0 = unwired), disconnected by
    /// `deinit` before the paned drops.
    divider_signal_id: c_ulong = 0,

    pub fn init(allocator: std.mem.Allocator) !LogPane {
        // Outer scrolled window. Horizontal scrollbar never appears
        // (wrapped labels handle width); vertical is automatic so it
        // only shows when content overflows.
        //
        // No `gtk_widget_set_size_request` here: an explicit min-width
        // combined with the start-child being hidden trips a
        // `GtkGizmo (slider) reported min width -2` warning out of
        // GtkPaned's measure pass. GtkPaned already drives our width
        // via `set_position`, so the explicit min was redundant.
        const scrolled = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(
            @ptrCast(scrolled),
            GTK_POLICY_NEVER,
            GTK_POLICY_AUTOMATIC,
        );

        const list_box = gtk_list_box_new();
        // No row selection — log is read-only. SINGLE mode would
        // highlight rows on click, which looks like interactivity we
        // don't actually offer.
        gtk_list_box_set_selection_mode(@ptrCast(list_box), GTK_SELECTION_NONE);
        gtk_widget_add_css_class(list_box, "djinn-log");
        gtk_widget_add_css_class(scrolled, "djinn-log-scroller");
        // Stretch the listbox to fill the scrolled window's content
        // area. Without this, the listbox sizes to the height of its
        // rows (~30px for the placeholder alone) and the empty area
        // below shows the viewport background — which falls back to
        // the GTK theme default (opaque dark) on KDE / layer-shell
        // and renders as a black band beneath the rows. With
        // vexpand, the listbox covers the entire pane area and our
        // themed background paints across the whole column.
        gtk_widget_set_vexpand(list_box, 1);
        gtk_scrolled_window_set_child(@ptrCast(scrolled), list_box);

        // Sticky-attention chip. Lives above the scrolled window so a
        // long log can't push it out of view. Hidden by default;
        // `refreshAttentionChip` shows it the first time
        // `AgentState.pinned_attention` is non-null. GtkButton chosen
        // over plain GtkLabel + GtkGestureClick so we get hover/focus
        // states and standard accessibility for free.
        const attention_button = gtk_button_new_with_label("");
        gtk_widget_add_css_class(attention_button, "djinn-log-attention");
        gtk_widget_set_visible(attention_button, 0);

        // Free-text filter entry. GtkSearchEntry instead of bare
        // GtkEntry because it ships with a magnifier icon (visual
        // affordance — no placeholder text needed), a built-in 150ms
        // debounce on `search-changed` (no manual coalescing of fast
        // typing), and Escape-to-clear semantics that match what most
        // users expect from a filter field.
        const search_entry = gtk_search_entry_new();
        gtk_widget_add_css_class(search_entry, "djinn-log-filter");

        // Outer container: vertical box holds chip on top, scrolled
        // log in the middle, filter entry on the bottom. Spacing 0 —
        // chip + filter own padding/margin (set in CSS) handles
        // separation from the list.
        const container = gtk_box_new(@as(c_int, 1), @as(c_int, 0)); // VERTICAL
        gtk_widget_add_css_class(container, "djinn-log-container");
        gtk_box_append(@ptrCast(container), attention_button);
        gtk_box_append(@ptrCast(container), scrolled);
        gtk_box_append(@ptrCast(container), search_entry);
        // Scrolled window fills the remainder of the box once the chip
        // + entry have taken their natural heights. Without vexpand on
        // `scrolled` here, the box would split height proportionally
        // and the chip could swell when the list is short — locking
        // both fixed siblings to their natural heights keeps the
        // layout predictable.
        gtk_widget_set_vexpand(scrolled, 1);

        // Module-local CSS provider. Reload-in-place pattern mirrors
        // theme.zig — stacking new providers on each apply leaves
        // orphan rules behind, so we re-load the same provider's
        // content instead. Initial load uses GTK theme defaults; the
        // caller follows up with `applyTheme(opts)` once resolved
        // colors are known.
        const provider = gtk_css_provider_new();
        if (gdk_display_get_default()) |display| {
            gtk_style_context_add_provider_for_display(
                display,
                @ptrCast(provider),
                STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }

        var self: LogPane = .{
            .allocator = allocator,
            .container = container,
            .attention_button = attention_button,
            .scrolled = scrolled,
            .list_box = list_box,
            .search_entry = search_entry,
            .provider = provider,
        };
        self.applyTheme(.{}); // defaults; caller may re-apply
        self.showPlaceholder(.no_activity);
        return self;
    }

    /// Reload the log pane CSS from `opts`. Mirrors
    /// `Terminal.applyTheme` so the watcher's config-change handler
    /// can drive both at once. Background + foreground come from the
    /// resolved theme (djinn config overrides ghostty inheritance);
    /// nulls fall back to GTK theme named colors so the pane stays
    /// legible even with no ghostty inheritance.
    ///
    /// Reload-in-place via `gtk_css_provider_load_from_string` —
    /// stacking new providers across reloads would leave orphan
    /// rules behind (same trap theme.zig avoids).
    pub fn applyTheme(self: *LogPane, opts: ThemeOptions) void {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        writeThemedCss(self.allocator, &buf, opts) catch |err| {
            std.debug.print("log_pane: CSS build failed: {} — keeping previous styles\n", .{err});
            return;
        };
        gtk_css_provider_load_from_string(
            self.provider,
            @ptrCast(buf.items.ptr),
        );
    }

    /// Drop a dim italic placeholder row into an otherwise-empty
    /// list. Without this, a freshly-opened pane with no MCP traffic
    /// (or a too-narrow filter) reads as broken — the user sees an
    /// empty box and can't tell whether it's hidden, unstyled, or
    /// just quiet. Idempotent: re-asking for the same kind is a
    /// no-op so we don't churn rows on every poll tick.
    fn showPlaceholder(self: *LogPane, kind: Placeholder) void {
        if (kind == .none) return;
        if (self.placeholder == kind) return;
        if (self.placeholder != .none) self.clearPlaceholder();

        const text: [*:0]const u8 = switch (kind) {
            .none => unreachable,
            .no_activity => "no agent activity yet",
            .no_matches => "no matches for filter",
        };
        const label = gtk_label_new(text);
        gtk_label_set_xalign(@ptrCast(label), 0.0);
        gtk_widget_add_css_class(label, "djinn-log-empty");
        gtk_list_box_append(@ptrCast(self.list_box), label);
        self.placeholder = kind;
    }

    fn clearPlaceholder(self: *LogPane) void {
        if (self.placeholder == .none) return;
        // The placeholder is always the only row when present (real
        // appends call clearPlaceholder first), so remove_all is the
        // correct one-shot — no risk of nuking real rows.
        gtk_list_box_remove_all(@ptrCast(self.list_box));
        self.placeholder = .none;
    }

    /// Pick the right placeholder for the current state and show it
    /// (or hide whichever was up). Called after every list mutation
    /// so the empty state never sits with a stale message. Decision
    /// table:
    ///
    ///   rendered_count > 0          → no placeholder
    ///   last_seen_count == 0        → "no agent activity yet"
    ///   model.hasActiveFilter()     → "no matches for filter"
    ///   else (defensive default)    → "no agent activity yet"
    ///
    /// The defensive branch covers a degenerate snapshot where
    /// `last_seen_count > 0` but no rows landed (e.g. a future
    /// non-filter row-rejection path) — better to fall back to the
    /// generic empty message than to lie about a filter that isn't
    /// active.
    fn refreshPlaceholder(self: *LogPane) void {
        if (self.rendered_count > 0) {
            self.clearPlaceholder();
            return;
        }
        if (self.last_seen_count == 0) {
            self.showPlaceholder(.no_activity);
        } else if (self.model.hasActiveFilter()) {
            self.showPlaceholder(.no_matches);
        } else {
            self.showPlaceholder(.no_activity);
        }
    }

    pub fn deinit(self: *LogPane) void {
        if (self.poll_source_id != 0) {
            _ = g_source_remove(self.poll_source_id);
            self.poll_source_id = 0;
        }
        // Disconnect the chip + filter handlers before any further
        // teardown. Both captured `self` as user_data; the parent
        // GtkPaned destroy will eventually drop these widgets, but a
        // dispatch already queued on the GLib main loop would fire
        // against a freed LogPane.
        if (self.attention_clicked_id != 0) {
            g_signal_handler_disconnect(@ptrCast(self.attention_button), self.attention_clicked_id);
            self.attention_clicked_id = 0;
        }
        if (self.search_changed_id != 0) {
            g_signal_handler_disconnect(@ptrCast(self.search_entry), self.search_changed_id);
            self.search_changed_id = 0;
        }
        if (self.divider_signal_id != 0) {
            if (self.paned) |p|
                g_signal_handler_disconnect(@ptrCast(p), self.divider_signal_id);
            self.divider_signal_id = 0;
        }
        // Widgets are owned by their parent (GtkPaned → GtkWindow);
        // GTK reclaims them when the window is destroyed. We only
        // own the CSS provider's local ref beyond what
        // add_provider_for_display retained.
        g_object_unref(@ptrCast(self.provider));
    }

    /// The widget to embed in the parent layout. Caller passes this
    /// to `gtk_paned_set_end_child` (or wherever the log column
    /// belongs). Returns the outer box, not the scrolled window —
    /// hiding the box collapses chip + log together.
    pub fn widget(self: *LogPane) *GtkWidget {
        return self.container;
    }

    /// Show or hide the log pane. GtkPaned collapses a hidden child
    /// automatically — the start child (VTE) reclaims the full width
    /// without an explicit position reset.
    pub fn setVisible(self: *LogPane, visible: bool) void {
        gtk_widget_set_visible(self.container, if (visible) 1 else 0);
    }

    pub fn isVisible(self: *LogPane) bool {
        return gtk_widget_get_visible(self.container) != 0;
    }

    /// Flip visibility. GtkPaned preserves the divider position
    /// across the visibility flip, so the pane reappears at the
    /// same width it was hidden at (or whatever main_linux.zig
    /// configured at startup if it never appeared before). Bound
    /// to Ctrl+/ from the keymap.
    pub fn toggleVisible(self: *LogPane) void {
        self.setVisible(!self.isVisible());
    }

    /// Start polling `state` every 250ms. Idempotent — re-calling
    /// replaces the previous source (we drop the old tag first so
    /// GLib doesn't leak a handler). `state` must outlive the pane;
    /// the caller (main_linux.zig) keeps both on the same stack
    /// frame so this is implicit.
    ///
    /// Wires the attention chip's click handler + the filter entry's
    /// search-changed handler on the same call, stashing `self` as
    /// user_data. Both handlers read `self.observed_state` — wiring
    /// here (not in init) keeps them from firing before
    /// `observed_state` is set, and the `was_unobserved` gate makes
    /// re-calls idempotent so duplicate handlers don't stack.
    /// Best-effort info-log append on the observed AgentState. No-op
    /// when `observeAgentState` hasn't been called yet — used by
    /// keymap actions (theme_toggle today) that want to surface a
    /// status line in the log pane without threading a separate
    /// AgentState pointer through Context. The OOM path is swallowed
    /// because callers are typically running on the GLib main thread
    /// and would have nothing better to do with the error.
    pub fn appendInfo(self: *LogPane, message: []const u8) void {
        const state = self.observed_state orelse return;
        state.appendLog(.info, message) catch {};
    }

    pub fn observeAgentState(self: *LogPane, state: *AgentState) void {
        if (self.poll_source_id != 0) _ = g_source_remove(self.poll_source_id);
        const was_unobserved = self.observed_state == null;
        self.observed_state = state;
        self.poll_source_id = g_timeout_add(250, pollTick, @ptrCast(self));
        if (was_unobserved) {
            self.attention_clicked_id = g_signal_connect_data(
                @ptrCast(self.attention_button),
                "clicked",
                @ptrCast(&onAttentionClicked),
                @ptrCast(self),
                null,
                0,
            );
            self.search_changed_id = g_signal_connect_data(
                @ptrCast(self.search_entry),
                "search-changed",
                @ptrCast(&onSearchChanged),
                @ptrCast(self),
                null,
                0,
            );
        }
    }

    /// Wrap `left_child` (the VTE widget) and this pane into a
    /// horizontal `GtkPaned`. `divider_position` is the start child's
    /// width in pixels — the log pane gets whatever's left. Returns
    /// the GtkPaned widget for the caller to hand to
    /// `panel.attachChild`.
    ///
    /// Uses GtkPaned's defaults (`resize` and `shrink` both true for
    /// both children) — explicit `set_shrink_*_child(false)` was
    /// deprecated in GTK 4.10 and, when paired with a start-hidden
    /// end child, triggered a `GtkGizmo (slider) reported min width
    /// -2` warning on every launch. Defaults let GtkPaned size the
    /// children freely; the divider position is what actually
    /// controls layout. If a user drag becomes too aggressive (one
    /// side shrunk to nothing), add explicit min sizes via
    /// `gtk_widget_set_size_request` on each child rather than
    /// reaching for the deprecated shrink properties.
    pub fn pairWithSibling(
        self: *LogPane,
        left_child: *GtkWidget,
        divider_position: c_int,
    ) *GtkWidget {
        const paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
        gtk_paned_set_start_child(@ptrCast(paned), left_child);
        // end_child must be `self.container` (the outer vertical box
        // holding attention chip + scrolled list + search entry), NOT
        // `self.scrolled`. `scrolled` is already a child of
        // `self.container` from init; passing it here trips a
        // `gtk_paned_set_end_child: assertion ... gtk_widget_get_parent
        // (child) == NULL' failed` Gtk-CRITICAL and either silently
        // no-ops the assignment OR reparents scrolled out of container.
        // Either outcome leaves `self.container` (the widget that
        // `setVisible`/`toggleVisible` toggle) orphaned outside the
        // widget tree; Ctrl+/ then does nothing visible.
        gtk_paned_set_end_child(@ptrCast(paned), self.container);
        gtk_paned_set_position(@ptrCast(paned), divider_position);
        self.paned = @ptrCast(paned);
        return paned;
    }

    /// Connect a handler that fires on every GtkPaned `notify::position`
    /// emission — main_linux uses this to forward divider drags into
    /// the persist worker. Must be called AFTER `pairWithSibling` so
    /// the paned exists. Idempotent: a second call replaces the prior
    /// handler so a hypothetical re-wire (e.g. config-driven persist
    /// disable) doesn't stack subscriptions. Stores the signal id so
    /// `deinit` can disconnect before the paned drops.
    pub fn setOnDividerChange(self: *LogPane, handler: DividerHandler) void {
        const paned = self.paned orelse return;
        if (self.divider_signal_id != 0) {
            g_signal_handler_disconnect(@ptrCast(paned), self.divider_signal_id);
            self.divider_signal_id = 0;
        }
        self.divider_handler = handler;
        self.divider_signal_id = g_signal_connect_data(
            @ptrCast(paned),
            "notify::position",
            @ptrCast(&onPanedNotifyPosition),
            @ptrCast(self),
            null,
            0,
        );
    }
};

/// GObject `notify::<prop>` signal shape: `(instance, pspec, user_data)`.
/// We don't need the pspec (we only subscribed to `position`), so it's
/// ignored. The handler reads the live position from the paned and
/// fans out to the caller's debounce hook.
fn onPanedNotifyPosition(
    paned_ptr: *GObject,
    _: ?*anyopaque,
    user_data: gpointer,
) callconv(.c) void {
    const self: *LogPane = @ptrCast(@alignCast(user_data orelse return));
    const handler = self.divider_handler orelse return;
    const paned: *GtkPaned = @ptrCast(paned_ptr);
    const pos = gtk_paned_get_position(paned);
    handler.on_change(handler.ctx, @intCast(pos));
}

// ─── Implementation ──────────────────────────────────────────────────

/// Themed CSS builder. Extracted to `log_pane_css.zig` to keep this
/// module focused on widget lifecycle + signal wiring. See that
/// module's file-doc for selector inventory and the palette/theme
/// fallback rules.
const writeThemedCss = @import("log_pane_css.zig").writeThemedCss;

fn pollTick(user_data: gpointer) callconv(.c) c_int {
    const self: *LogPane = @ptrCast(@alignCast(user_data orelse return G_SOURCE_CONTINUE));
    const state = self.observed_state orelse return G_SOURCE_CONTINUE;

    // Sticky-attention chip refresh runs every tick regardless of
    // log activity — attention pins/unpins independently of log
    // appends (a `djinn_request_attention` MCP call doesn't always
    // log, and `djinn_ack` or `setState(.done)` may unpin without
    // a log append either).
    refreshAttentionChip(self, state);

    // Hold state.mutex across the snapshot AND the row builds — the
    // entry slices we read (entry.message / entry.client) are owned
    // by AgentState and only stable while the lock is held. The prior
    // shape released the lock between snapshot and appendRange's
    // re-lock; a concurrent `appendLog` eviction in that gap shifted
    // the `[from..from+count]` window onto different entries than
    // the snapshot intended (corrupt row text, dangling slices on
    // the freed string). GTK calls happen under the lock, but the
    // tick is bounded: pollTick fires every 250ms and the typical
    // append is 0-few rows; MCP worker threads only block when both
    // hit the mutex inside the same ~ms window.
    state.mutex.lock();
    defer state.mutex.unlock();

    var action: TickAction = .no_op;
    var append_from: usize = 0;
    var append_count: usize = 0;
    const snapshot_count: usize = state.log.items.len;
    const snapshot_first_ts: i64 = if (snapshot_count > 0)
        state.log.items[0].timestamp_ms
    else
        0;

    if (!self.initialized) {
        action = if (snapshot_count == 0) .no_op else .rebuild;
    } else if (snapshot_count == self.last_seen_count and
        snapshot_first_ts == self.last_seen_first_ts)
    {
        action = .no_op;
    } else if (snapshot_count > self.last_seen_count and
        snapshot_first_ts == self.last_seen_first_ts)
    {
        action = .append;
        append_from = self.last_seen_count;
        append_count = snapshot_count - self.last_seen_count;
    } else {
        // Ring evicted (first_ts changed) or shrank somehow.
        action = .rebuild;
    }

    if (action == .no_op) {
        self.initialized = true;
        return G_SOURCE_CONTINUE;
    }

    if (action == .rebuild) {
        // Drop everything (real rows + placeholder) and walk the ring
        // through the active filter.
        gtk_list_box_remove_all(@ptrCast(self.list_box));
        self.placeholder = .none;
        self.rendered_count = 0;
        // Reset client-grouping state so the first row of the
        // rebuilt list gets a fresh header — without this, a
        // ring-evict rebuild that happens to start with the same
        // client as before the evict would silently lose the header.
        self.model.resetGrouping();
        appendRangeLocked(self, state, 0, snapshot_count) catch |err| {
            std.debug.print("log_pane: rebuild failed: {}\n", .{err});
        };
    } else {
        // Append branch — appendRangeLocked lazy-clears the
        // placeholder on the first matching entry, so an
        // all-filter-rejected tick leaves the "no matches"
        // placeholder visible without churn.
        appendRangeLocked(self, state, append_from, append_count) catch |err| {
            std.debug.print("log_pane: append failed: {}\n", .{err});
        };
    }

    self.last_seen_count = snapshot_count;
    self.last_seen_first_ts = snapshot_first_ts;
    self.initialized = true;

    // Pick the right placeholder for the new state — "no matches"
    // if filter is active and rendered_count fell to zero, "no
    // activity" if the ring is empty, otherwise hide whatever was
    // up. Has to run after `last_seen_count` is set so the decision
    // table reads the post-mutation counts.
    self.refreshPlaceholder();

    // Auto-scroll to newest. Defer to an idle callback so GTK has
    // measured the freshly-appended rows before we ask for the
    // adjustment's upper bound — querying immediately returns the
    // pre-append height and scrolls to a stale position.
    _ = g_idle_add(scrollToBottomIdle, @ptrCast(self));

    return G_SOURCE_CONTINUE;
}

const TickAction = enum { no_op, append, rebuild };

/// Build a row for each of `state.log.items[from..from+count]` and
/// append it to the list box, skipping entries the active filter
/// rejects. **Caller must hold `state.mutex`** — the entry slices
/// we read (entry.message / entry.client) are owned by AgentState
/// and only stable while the lock is held.
fn appendRangeLocked(self: *LogPane, state: *AgentState, from: usize, count: usize) !void {
    // Defensive clamp: callers compute count from a snapshot taken
    // under the same mutex acquisition, so this should never trim,
    // but a stale `from` arg (e.g. from a future refactor) would
    // otherwise read past the slice's end.
    const end = @min(from + count, state.log.items.len);
    if (from >= end) return;

    for (state.log.items[from..end]) |entry| {
        if (!self.model.matchesFilter(entry)) continue;
        // Lazy-clear: a tick where every new entry was filtered out
        // shouldn't churn the "no matches" placeholder. Clear only
        // when we have a real row about to land.
        if (self.placeholder != .none) self.clearPlaceholder();

        // Group transition? Emit a `{client} · HH:MM` header before
        // the body row so the reader can see who's speaking. Header
        // is emitted only here (right before its matching body row)
        // so a filter that hides every body in a group also hides
        // the orphan header — no degenerate "header with no rows
        // under it" state.
        if (self.model.shouldEmitHeader(entry)) {
            const hdr = buildHeaderRow(self.allocator, entry) catch |err| {
                std.debug.print("log_pane: header build failed: {}\n", .{err});
                continue;
            };
            gtk_list_box_append(@ptrCast(self.list_box), hdr);
            self.rendered_count += 1;
        }
        self.model.updateLastClient(entry.client);

        const row = try buildRow(self.allocator, entry);
        gtk_list_box_append(@ptrCast(self.list_box), row);
        self.rendered_count += 1;
    }
}

/// Clear the list and re-walk every state entry through the active
/// filter. Used by both the pollTick `.rebuild` branch (ring evicted
/// the oldest entry, so the offset diff is wrong) and the filter-
/// changed signal (filter needle moved; every row needs re-evaluation
/// against the new predicate). Resets `last_seen_*` to reflect the
/// fresh snapshot so the next append tick computes the right delta.
fn rebuildAll(self: *LogPane) void {
    const state = self.observed_state orelse return;

    gtk_list_box_remove_all(@ptrCast(self.list_box));
    self.placeholder = .none;
    self.rendered_count = 0;

    // Hold state.mutex across the snapshot + the row builds. Same
    // reason as pollTick: appendRangeLocked reads entry slices owned
    // by AgentState and only stable under the lock. A concurrent
    // appendLog eviction between snapshot and row-build would
    // otherwise shift the window onto different entries.
    state.mutex.lock();
    defer state.mutex.unlock();
    const len = state.log.items.len;
    const first_ts: i64 = if (len > 0) state.log.items[0].timestamp_ms else 0;

    if (len > 0) {
        appendRangeLocked(self, state, 0, len) catch |err| {
            std.debug.print("log_pane: rebuild failed: {}\n", .{err});
        };
    }

    self.last_seen_count = len;
    self.last_seen_first_ts = first_ts;
    self.initialized = true;

    // Decide which placeholder (if any) belongs in the cleared list.
    // Three cases collapse into refreshPlaceholder's table:
    // ring-empty → "no activity"; filter rejected every entry →
    // "no matches"; otherwise → nothing.
    self.refreshPlaceholder();

    // Defer scroll-to-bottom one frame so GTK's measured upper bound
    // reflects the new row set — same idle deferral pollTick uses.
    _ = g_idle_add(scrollToBottomIdle, @ptrCast(self));
}

/// GtkSearchEntry `search-changed` signal — user typed (or cleared)
/// the filter. Hand the text to the model (case-folds + stores),
/// then force a full rebuild. GtkSearchEntry's built-in 150ms
/// debounce keeps this from firing on every keystroke during fast
/// typing, so the rebuild cost stays bounded even on a 256-entry log.
fn onSearchChanged(entry: *GtkSearchEntry, user_data: gpointer) callconv(.c) void {
    const self: *LogPane = @ptrCast(@alignCast(user_data orelse return));
    const text_z = gtk_editable_get_text(@ptrCast(entry));
    self.model.setFilter(std.mem.span(text_z));
    rebuildAll(self);
}

/// Compose a single row's label text and wrap it in a GtkLabel.
/// Text shape: `[LVL] message`. The client name is NOT in the body
/// — it lives in the `{client} · HH:MM` header row above the group
/// (see `buildHeaderRow`). The level prefix is always present so
/// width is predictable across rows.
fn buildRow(allocator: std.mem.Allocator, entry: LogEntry) !*GtkWidget {
    const lvl_prefix: []const u8 = switch (entry.level) {
        .info => "[INF]",
        .warn => "[WRN]",
        .err => "[ERR]",
    };

    const text = try std.fmt.allocPrintSentinel(
        allocator,
        "{s} {s}",
        .{ lvl_prefix, entry.message },
        0,
    );
    defer allocator.free(text);

    const label = gtk_label_new(text.ptr);
    gtk_label_set_xalign(@ptrCast(label), 0.0); // left-align
    gtk_label_set_wrap(@ptrCast(label), 1);
    gtk_label_set_selectable(@ptrCast(label), 1);
    gtk_widget_add_css_class(label, switch (entry.level) {
        .info => "djinn-log-info",
        .warn => "djinn-log-warn",
        .err => "djinn-log-err",
    });

    // Right-click "Copy entry": GtkGestureClick → pressed handler
    // reads the label's text (which carries the `[LVL] ` prefix the
    // row was built with), strips it, writes the body to the
    // system clipboard. No user_data needed; the handler reaches
    // back through the gesture → widget chain to find the label.
    const click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(click, GDK_BUTTON_SECONDARY);
    _ = g_signal_connect_data(
        @ptrCast(click),
        "pressed",
        @ptrCast(&onRowRightClick),
        null,
        null,
        0,
    );
    gtk_widget_add_controller(label, click);

    return label;
}

/// GtkGestureClick `pressed` handler for log-row right-click.
/// Signature matches GTK 4: `(gesture, n_press, x, y, user_data)`.
/// Resolves the originating label via the gesture's widget, reads
/// its displayed text, strips the leading `[LVL] ` prefix, and
/// writes the message body to the system clipboard. No-op when
/// any leg of the lookup fails (no display, no clipboard,
/// orphaned controller).
fn onRowRightClick(
    gesture: *gtk.GtkEventController,
    _: c_int,
    _: f64,
    _: f64,
    _: gpointer,
) callconv(.c) void {
    const widget = gtk_event_controller_get_widget(gesture) orelse return;
    const display = gtk_widget_get_display(widget) orelse return;
    const clipboard = gdk_display_get_clipboard(display) orelse return;
    const text_z = gtk_label_get_text(@ptrCast(widget));
    const text = std.mem.span(text_z);
    const PREFIX_LEN: usize = 6;
    const has_prefix = text.len > PREFIX_LEN and (std.mem.startsWith(u8, text, "[INF] ") or
        std.mem.startsWith(u8, text, "[WRN] ") or
        std.mem.startsWith(u8, text, "[ERR] "));
    if (has_prefix) {
        // `text_z + PREFIX_LEN` stays NUL-terminated since the
        // backing buffer's sentinel sits at text.len > PREFIX_LEN.
        gdk_clipboard_set_text(clipboard, text_z + PREFIX_LEN);
    } else {
        gdk_clipboard_set_text(clipboard, text_z);
    }
}

/// Build the dim group-header label: `{client} · HH:MM` in UTC.
/// Mirrors darwin's `formatEntryHeader` byte-for-byte so the two
/// surfaces read the same to a user comparing them side-by-side.
/// UTC (not local) because `std.time.milliTimestamp` is UTC and the
/// header stays stable across DST transitions on the host — a
/// minor cosmetic loss in exchange for predictability.
fn buildHeaderRow(allocator: std.mem.Allocator, entry: LogEntry) !*GtkWidget {
    const client = entry.client orelse "";
    var time_buf: [16]u8 = undefined;
    const time_str = formatHeaderTime(&time_buf, entry.timestamp_ms);

    const text = try std.fmt.allocPrintSentinel(
        allocator,
        "{s} · {s}",
        .{ client, time_str },
        0,
    );
    defer allocator.free(text);

    const label = gtk_label_new(text.ptr);
    gtk_label_set_xalign(@ptrCast(label), 0.0);
    gtk_label_set_wrap(@ptrCast(label), 0);
    gtk_label_set_selectable(@ptrCast(label), 0);
    gtk_widget_add_css_class(label, "djinn-log-header");
    return label;
}

/// `HH:MM` in UTC. Buffer must be at least 5 bytes; the slice
/// returned is the formatted prefix. `bufPrint` is infallible
/// against a 16-byte caller buffer (max output is 5 bytes), but a
/// future caller could shrink the buffer below 5 bytes and trip
/// `error.NoSpace`. Return an empty slice on overflow instead of
/// `unreachable` so the header row degrades gracefully (the row
/// loses its `HH:MM` suffix but the layout doesn't abort).
fn formatHeaderTime(buf: []u8, timestamp_ms: i64) []const u8 {
    const seconds: i64 = @divFloor(timestamp_ms, 1000);
    const hr: u32 = @intCast(@mod(@divFloor(seconds, 3600), 24));
    const min: u32 = @intCast(@mod(@divFloor(seconds, 60), 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hr, min }) catch "";
}

/// Walk backward from `cap` to the start of the UTF-8 code point
/// that `bytes[cap..]` would otherwise begin in the middle of. A
/// continuation byte is `10xxxxxx`; ASCII and the first byte of a
/// multi-byte sequence both clear that pattern, so the loop stops
/// at the codepoint boundary nearest to (but not past) `cap`.
/// Returns `cap` unchanged when it's at or past the end of `bytes`
/// (caller is asking for "no truncation").
fn utf8FloorBoundary(bytes: []const u8, cap: usize) usize {
    if (cap >= bytes.len) return cap;
    var i: usize = cap;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

test "utf8FloorBoundary: snaps back from mid-codepoint" {
    // "é" = 0xC3 0xA9. Cap=1 lands on continuation byte; floor → 0.
    try std.testing.expectEqual(@as(usize, 0), utf8FloorBoundary("é", 1));
    // cap == bytes.len means caller doesn't want truncation; pass through.
    try std.testing.expectEqual(@as(usize, 2), utf8FloorBoundary("é", 2));
    // ASCII byte stays put.
    try std.testing.expectEqual(@as(usize, 3), utf8FloorBoundary("abc", 3));
    // Mid-sequence cap in a longer string: "éé" cap=3 → 2 (after first 'é').
    try std.testing.expectEqual(@as(usize, 2), utf8FloorBoundary("éé", 3));
}

/// Read the pinned attention message and sync the chip's label +
/// visibility. Diff against `attention_buf` so a stable pinned
/// message doesn't relabel the button on every tick (label updates
/// invalidate GtkButton's measure cache; cheap, but noisy in any
/// future GTK trace).
///
/// `pinnedAttention` copies into our local buffer under
/// AgentState's mutex; the slice we read after unlock is our own
/// memory, so there's no lifetime question crossing the GTK call.
fn refreshAttentionChip(self: *LogPane, state: *AgentState) void {
    var local_buf: [256]u8 = undefined;
    const maybe_len = state.pinnedAttention(&local_buf);

    if (maybe_len) |len| {
        const same = (len == self.attention_len) and
            std.mem.eql(u8, local_buf[0..len], self.attention_buf[0..self.attention_len]);
        if (same) return;

        @memcpy(self.attention_buf[0..len], local_buf[0..len]);
        self.attention_len = len;

        // Prefix with ⚠ to match darwin's chip semantic. 256-byte
        // local buf + 4-byte prefix fits in 260; we cap text at
        // 252 so the null sentinel slot is preserved. Truncation
        // snaps back to a UTF-8 code-point boundary so a split
        // multi-byte sequence doesn't surface as a tofu glyph on
        // the chip label (GTK renders invalid UTF-8 as `?` or U+FFFD
        // depending on Pango's run).
        const max_text: usize = 252;
        var clipped: usize = @min(len, max_text);
        if (clipped < len) clipped = utf8FloorBoundary(local_buf[0..len], clipped);
        var labeled: [260]u8 = undefined;
        const prefix = "\xE2\x9A\xA0  "; // U+26A0 WARNING SIGN + 2 spaces
        @memcpy(labeled[0..prefix.len], prefix);
        @memcpy(labeled[prefix.len..][0..clipped], local_buf[0..clipped]);
        labeled[prefix.len + clipped] = 0;

        gtk_button_set_label(
            @ptrCast(self.attention_button),
            @ptrCast(&labeled),
        );
        gtk_widget_set_visible(self.attention_button, 1);
    } else {
        if (self.attention_len == 0) return;
        self.attention_len = 0;
        gtk_widget_set_visible(self.attention_button, 0);
    }
}

/// GtkButton `clicked` signal — user dismissed the sticky-attention
/// chip. Calls `AgentState.ackAttention`; the next pollTick will see
/// `pinned_attention == null` and hide the button. Doing the hide
/// from the poll path (not synchronously here) keeps a single source
/// of truth for chip visibility and matches the auto-clear path
/// (which also flows through pollTick).
fn onAttentionClicked(_: *GtkButton, user_data: gpointer) callconv(.c) void {
    const self: *LogPane = @ptrCast(@alignCast(user_data orelse return));
    const state = self.observed_state orelse return;
    state.ackAttention();
}

fn scrollToBottomIdle(user_data: gpointer) callconv(.c) c_int {
    const self: *LogPane = @ptrCast(@alignCast(user_data orelse return 0));
    const adj = gtk_scrolled_window_get_vadjustment(@ptrCast(self.scrolled));
    const upper = gtk_adjustment_get_upper(adj);
    const page = gtk_adjustment_get_page_size(adj);
    const target = if (upper > page) upper - page else 0;
    gtk_adjustment_set_value(adj, target);
    // Return 0 to remove this idle source — one-shot per tick.
    return 0;
}

test "log_pane: module compiles" {
    // Type-only check; live GTK calls would require gtk_init.
    _ = LogPane;
    _ = pollTick;
    _ = buildRow;
}

test "log_pane: formatHeaderTime — epoch zero is 00:00 UTC" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", formatHeaderTime(&buf, 0));
}

test "log_pane: formatHeaderTime — wraps modulo 24h" {
    // 1778852700000 ms = 1778852700 s = 494125 h 45 m past epoch.
    // 494125 mod 24 = 13, remainder mod 60 = 45. HH:MM = 13:45.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("13:45", formatHeaderTime(&buf, 1778852700000));
}




