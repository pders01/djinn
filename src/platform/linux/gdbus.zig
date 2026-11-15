//! Shared GDBus / GVariant surface.
//!
//! Single canonical home for the GDBus types, constants, and externs
//! that `hotkey.zig`, `tray.zig`, `notifier.zig`, and
//! `ghostty_config.zig::detectAppearance` all rely on. Mirrors
//! `gtk.zig`'s opaque-types role but covers a broader surface — types
//! AND function externs — because four modules redeclaring the same
//! ~25 externs left room for signature drift (in particular the
//! `g_dbus_connection_call` / `_call_finish` / `_call_sync` family,
//! the `g_variant_*` primitive constructors, and the `GError` struct
//! layout). Server-side scaffolding that only `tray.zig` uses
//! (`g_dbus_method_invocation_*`, `g_dbus_node_info_*`,
//! `g_dbus_connection_register_object` / `_emit_signal`, the vtable
//! typedefs) stays local to tray — single caller, no drift surface.
//!
//! Each `opaque {}` in Zig produces a distinct type even when two
//! files spell it the same way, so the cross-module passing convention
//! is the same as gtk.zig: declare once here, alias locally in each
//! consumer via `const GVariant = gdbus.GVariant;` so call sites read
//! naturally.

const gtk = @import("gtk.zig");

pub const gpointer = gtk.gpointer;
pub const gboolean = gtk.gboolean;

// ─── Opaque types ────────────────────────────────────────────────────

pub const GDBusConnection = opaque {};
pub const GAsyncResult = opaque {};
pub const GVariant = opaque {};
pub const GVariantBuilder = opaque {};
pub const GVariantType = opaque {};
pub const GCancellable = opaque {};

// GError is the standard glib error reporting struct. ABI is stable
// since GLib 2.x; layout is `(GQuark domain, gint code, gchar *message)`
// where GQuark is a u32. All four consumer modules previously declared
// this identically, so the consolidation is mechanical.
pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

// ─── Bus + call constants ────────────────────────────────────────────

pub const GBusType = c_int;
pub const G_BUS_TYPE_SESSION: GBusType = 2;

pub const GDBusCallFlags = c_int;
pub const G_DBUS_CALL_FLAGS_NONE: GDBusCallFlags = 0;

pub const GDBusSignalFlags = c_int;
pub const G_DBUS_SIGNAL_FLAGS_NONE: GDBusSignalFlags = 0;

// ─── Callback signatures ─────────────────────────────────────────────

pub const GAsyncReadyCallback = *const fn (
    source_object: ?*anyopaque,
    res: *GAsyncResult,
    user_data: gpointer,
) callconv(.c) void;

pub const GDBusSignalCallback = *const fn (
    connection: *GDBusConnection,
    sender_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    signal_name: [*:0]const u8,
    parameters: *GVariant,
    user_data: gpointer,
) callconv(.c) void;

// ─── Cancellation ────────────────────────────────────────────────────

pub extern "c" fn g_cancellable_new() *GCancellable;
pub extern "c" fn g_cancellable_cancel(cancellable: *GCancellable) void;

// ─── Bus + connection ────────────────────────────────────────────────

pub extern "c" fn g_bus_get_sync(
    bus_type: GBusType,
    cancellable: ?*GCancellable,
    err: ?*?*GError,
) ?*GDBusConnection;

pub extern "c" fn g_dbus_connection_get_unique_name(
    connection: *GDBusConnection,
) ?[*:0]const u8;

pub extern "c" fn g_dbus_connection_call(
    connection: *GDBusConnection,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*GVariant,
    reply_type: ?*const GVariantType,
    flags: GDBusCallFlags,
    timeout_msec: c_int,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: gpointer,
) void;

pub extern "c" fn g_dbus_connection_call_sync(
    connection: *GDBusConnection,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*GVariant,
    reply_type: ?*const GVariantType,
    flags: GDBusCallFlags,
    timeout_msec: c_int,
    cancellable: ?*GCancellable,
    err: ?*?*GError,
) ?*GVariant;

pub extern "c" fn g_dbus_connection_call_finish(
    connection: *GDBusConnection,
    res: *GAsyncResult,
    err: ?*?*GError,
) ?*GVariant;

pub extern "c" fn g_dbus_connection_signal_subscribe(
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    interface_name: ?[*:0]const u8,
    member: ?[*:0]const u8,
    object_path: ?[*:0]const u8,
    arg0: ?[*:0]const u8,
    flags: GDBusSignalFlags,
    callback: GDBusSignalCallback,
    user_data: gpointer,
    user_data_free_func: ?*const anyopaque,
) c_uint;

pub extern "c" fn g_dbus_connection_signal_unsubscribe(
    connection: *GDBusConnection,
    subscription_id: c_uint,
) void;

// ─── GObject + error ─────────────────────────────────────────────────

pub extern "c" fn g_object_unref(object: *anyopaque) void;
pub extern "c" fn g_error_free(err: *GError) void;

// ─── GVariant — constructors ─────────────────────────────────────────

pub extern "c" fn g_variant_new_string(s: [*:0]const u8) *GVariant;
pub extern "c" fn g_variant_new_object_path(path: [*:0]const u8) *GVariant;
pub extern "c" fn g_variant_new_int32(value: i32) *GVariant;
pub extern "c" fn g_variant_new_uint32(value: u32) *GVariant;
pub extern "c" fn g_variant_new_byte(value: u8) *GVariant;
pub extern "c" fn g_variant_new_boolean(value: c_int) *GVariant;
pub extern "c" fn g_variant_new_variant(value: *GVariant) *GVariant;
pub extern "c" fn g_variant_new_dict_entry(key: *GVariant, value: *GVariant) *GVariant;
pub extern "c" fn g_variant_new_tuple(children: [*]const *GVariant, n: usize) *GVariant;
pub extern "c" fn g_variant_new_array(
    child_type: ?*const GVariantType,
    children: ?[*]const *GVariant,
    n_children: usize,
) *GVariant;

// ─── GVariant — readers ──────────────────────────────────────────────

pub extern "c" fn g_variant_unref(value: *GVariant) void;
pub extern "c" fn g_variant_get_child_value(value: *GVariant, index: usize) *GVariant;
pub extern "c" fn g_variant_get_variant(value: *GVariant) *GVariant;
pub extern "c" fn g_variant_get_int32(value: *GVariant) i32;
pub extern "c" fn g_variant_get_uint32(value: *GVariant) u32;
pub extern "c" fn g_variant_get_string(value: *GVariant, length: ?*usize) [*:0]const u8;
pub extern "c" fn g_variant_is_of_type(value: *GVariant, t: *const GVariantType) c_int;
pub extern "c" fn g_variant_n_children(value: *GVariant) usize;
pub extern "c" fn g_variant_lookup_value(
    dictionary: *GVariant,
    key: [*:0]const u8,
    expected_type: ?*const GVariantType,
) ?*GVariant;

// ─── GVariant — builder ──────────────────────────────────────────────

pub extern "c" fn g_variant_builder_new(type: *const GVariantType) *GVariantBuilder;
pub extern "c" fn g_variant_builder_add_value(builder: *GVariantBuilder, value: *GVariant) void;
pub extern "c" fn g_variant_builder_end(builder: *GVariantBuilder) *GVariant;
pub extern "c" fn g_variant_builder_unref(builder: *GVariantBuilder) void;
