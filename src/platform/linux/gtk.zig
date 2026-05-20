//! Shared GTK / GLib opaque types + common externs.
//!
//! Each `opaque {}` declaration in Zig produces a distinct type, even
//! when two files use the same name. Without a shared declaration,
//! `*GtkWidget` from panel.zig wouldn't be assignable to `*GtkWidget`
//! from terminal.zig — the compiler reports them as different opaque
//! types with the same spelling. This module is the single canonical
//! home so cross-module widget passing just works.
//!
//! Per-feature externs (gtk_window_new, vte_terminal_*, gtk_paned_*,
//! pango_*, gtk_layer_*) stay in their consumer modules. The functions
//! exposed here are the GLib / GTK helpers that 3+ modules need:
//! signal connect/disconnect, source add/remove, GObject ref ops,
//! display + visibility, controller attachment, CSS provider helpers.
//! Same shape as `gdbus.zig` for D-Bus surface. Reconciles
//! `g_source_remove`'s previously-divergent return type onto
//! `gboolean` (the canonical GLib spelling) so callers don't have to
//! pick between `c_int` and `gboolean` per-module.

pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GMainLoop = opaque {};
pub const GMainContext = opaque {};
pub const GObject = opaque {};
pub const VteTerminal = opaque {};
pub const GCancellable = opaque {};
pub const GdkDisplay = opaque {};
pub const GtkEventController = opaque {};
pub const GtkCssProvider = opaque {};

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;

/// Callback types for the helpers below. Kept here so consumers
/// don't redeclare them per-file (previously redeclared in 5+ files
/// with identical signatures).
pub const GSourceFunc = *const fn (user_data: gpointer) callconv(.c) c_int;
pub const GClosureNotify = ?*const fn (data: gpointer, closure: ?*anyopaque) callconv(.c) void;
pub const GConnectFlags = c_int;

// ─── GLib / GObject ──────────────────────────────────────────────────

pub extern "c" fn g_object_unref(object: *anyopaque) void;
pub extern "c" fn g_free(mem: ?*anyopaque) void;

pub extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: gpointer,
    destroy_data: GClosureNotify,
    connect_flags: GConnectFlags,
) c_ulong;

pub extern "c" fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;

pub extern "c" fn g_timeout_add(
    interval_ms: c_uint,
    function: GSourceFunc,
    user_data: gpointer,
) c_uint;

pub extern "c" fn g_idle_add(function: GSourceFunc, user_data: gpointer) c_uint;

pub extern "c" fn g_source_remove(tag: c_uint) gboolean;

// ─── GTK widget basics ───────────────────────────────────────────────

pub extern "c" fn gdk_display_get_default() ?*GdkDisplay;
pub extern "c" fn gtk_widget_set_visible(widget: *GtkWidget, visible: gboolean) void;
pub extern "c" fn gtk_widget_get_visible(widget: *GtkWidget) gboolean;
pub extern "c" fn gtk_widget_add_controller(widget: *GtkWidget, controller: *GtkEventController) void;

// ─── CSS provider attach ─────────────────────────────────────────────

pub extern "c" fn gtk_css_provider_new() *GtkCssProvider;
pub extern "c" fn gtk_css_provider_load_from_string(provider: *GtkCssProvider, css: [*:0]const u8) void;
pub extern "c" fn gtk_style_context_add_provider_for_display(
    display: *GdkDisplay,
    provider: *GtkCssProvider,
    priority: c_uint,
) void;
