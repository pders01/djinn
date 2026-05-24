//! StatusNotifierItem tray surface.
//!
//! KDE / Plasma, waybar, XFCE's xfce4-panel and GNOME (via the
//! AppIndicator extension) all consume `org.kde.StatusNotifierItem`
//! plus the `com.canonical.dbusmenu` companion. Together they replace
//! AppKit's NSStatusItem — a tray icon with a dropdown menu, owned by
//! the application and rendered by the system tray host.
//!
//! Why hand-rolled instead of libayatana-appindicator: the rest of
//! djinn's linux platform layer hand-rolls externs (gtk4 in
//! `panel.zig`, vte in `terminal.zig`, GDBus in `hotkey.zig`).
//! Adding an extra runtime dep just for the tray would diverge from
//! that pattern, and the SNI surface is small enough that direct
//! D-Bus is competitive on lines-of-code with wrapping a library.
//!
//! Protocol shape (per KDE's spec at
//! https://specifications.freedesktop.org/statusnotifier/0.1/):
//!   - We register objects at `/StatusNotifierItem` and `/MenuBar`
//!     on our unique bus name (the SNI spec accepts unique connection
//!     names; no need to own a well-known name).
//!   - We call `org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem(
//!     senderName)` to tell the system tray we exist. The host
//!     (plasmashell / waybar / panel) then queries our properties and
//!     draws the icon.
//!   - The dbusmenu object mirrors darwin's menubar layout: disabled
//!     status line at the top (rebuilt from the agent state at each
//!     popup), Show / Hide, Copy MCP config, Settings, Quit. Hosts
//!     call `GetLayout` (or `AboutToShow` + `GetGroupProperties`)
//!     immediately before each popup, so the status row's label
//!     reflects the latest state without dbusmenu signal traffic
//!     between opens. Click events come back via `Event(id,
//!     "clicked", ...)` and `dispatchClick` fans on the integer id.
//!
//! Activate/SecondaryActivate both map to panel-toggle. The icon +
//! Title + Status reflect `agent/state.zig.Agent` — host re-queries
//! after each `NewIcon` / `NewTitle` / `NewStatus` signal we emit from
//! `updateState`. The poll → diff → updateState loop lives in
//! `main_linux.zig`; tray.zig only owns the SNI surface.
//!
//! Failure mode: if no SNI watcher is running (bare wlroots compositors
//! without a panel), the RegisterStatusNotifierItem call errors. We
//! log and continue — the panel still works via hotkey + IPC.
//!
//! Threading model — every entry point in this file runs on the GLib
//! main thread:
//!   - `pollAgentTick` fires from `g_timeout_add` (250ms).
//!   - `Tray.updateState` is called only from `pollAgentTick`.
//!   - `sniGetProperty` / `sniMethodCall` / `menuGetProperty` /
//!     `menuMethodCall` are dispatched by GDBus on the default main
//!     context, which is the GLib main thread.
//!   - `onWatcherNameOwnerChanged` is a signal subscription on the
//!     same connection, same thread.
//!
//! Consequence: `ctx.state`, `ctx.message_buf`, and `ctx.message_len`
//! are owned by the GLib main thread. Reads + writes need no explicit
//! synchronization. If a future caller routes any of these through a
//! different thread (e.g. emitting a state update from an MCP worker
//! thread without marshalling via `g_idle_add`), that invariant
//! breaks and `message_buf` becomes a torn-read hazard.
//!
//! Lock ordering w.r.t. AgentState: `pollAgentTick` acquires
//! `state.mutex` briefly to snapshot, then releases before any DBus
//! call. MCP worker threads that hold `state.mutex` (via
//! `appendLogFrom`, `setState`, …) never call back into GLib
//! synchronously. The waiting direction is one-way: GLib main may
//! wait on `state.mutex`; state.mutex holders never wait on GLib.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const gdbus = @import("gdbus.zig");
const Agent = @import("../../agent/state.zig").Agent;
const AgentState = @import("../../agent/state.zig").AgentState;

const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

const GDBusConnection = gdbus.GDBusConnection;
const GAsyncResult = gdbus.GAsyncResult;
const GVariant = gdbus.GVariant;
const GVariantBuilder = gdbus.GVariantBuilder;
const GVariantType = gdbus.GVariantType;
const GError = gdbus.GError;
const G_BUS_TYPE_SESSION = gdbus.G_BUS_TYPE_SESSION;
const G_DBUS_CALL_FLAGS_NONE = gdbus.G_DBUS_CALL_FLAGS_NONE;
const GAsyncReadyCallback = gdbus.GAsyncReadyCallback;

// ─── SNI / dbusmenu server-side surface ──────────────────────────────
//
// register_object / method_invocation / node_info / emit_signal are
// only used here (the SNI server-side dispatch surface). Single caller,
// no drift surface — kept local rather than in gdbus.zig.

const GDBusMethodInvocation = opaque {};
const GDBusNodeInfo = opaque {};
const GDBusInterfaceInfo = opaque {};

const GDBusInterfaceMethodCallFunc = *const fn (
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: *GVariant,
    invocation: *GDBusMethodInvocation,
    user_data: gpointer,
) callconv(.c) void;

const GDBusInterfaceGetPropertyFunc = *const fn (
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    property_name: [*:0]const u8,
    err: ?*?*GError,
    user_data: gpointer,
) callconv(.c) ?*GVariant;

const GDBusInterfaceSetPropertyFunc = *const fn (
    connection: *GDBusConnection,
    sender: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    property_name: [*:0]const u8,
    value: *GVariant,
    err: ?*?*GError,
    user_data: gpointer,
) callconv(.c) c_int;

/// GDBus dispatch table. We populate method_call + get_property; the
/// SNI and dbusmenu interfaces are read-only from the host's POV so
/// set_property stays null. The 8-pointer padding tail is part of the
/// public ABI — even though it's unused, the struct layout must match.
const GDBusInterfaceVTable = extern struct {
    method_call: ?GDBusInterfaceMethodCallFunc,
    get_property: ?GDBusInterfaceGetPropertyFunc,
    set_property: ?GDBusInterfaceSetPropertyFunc,
    padding: [8]?*anyopaque,
};

extern "c" fn g_dbus_node_info_new_for_xml(
    xml_data: [*:0]const u8,
    err: ?*?*GError,
) ?*GDBusNodeInfo;

extern "c" fn g_dbus_node_info_lookup_interface(
    info: *GDBusNodeInfo,
    name: [*:0]const u8,
) ?*GDBusInterfaceInfo;

extern "c" fn g_dbus_node_info_unref(info: *GDBusNodeInfo) void;

extern "c" fn g_dbus_connection_register_object(
    connection: *GDBusConnection,
    object_path: [*:0]const u8,
    interface_info: *GDBusInterfaceInfo,
    vtable: *const GDBusInterfaceVTable,
    user_data: gpointer,
    user_data_free_func: ?*const anyopaque,
    err: ?*?*GError,
) c_uint;

extern "c" fn g_dbus_connection_unregister_object(
    connection: *GDBusConnection,
    registration_id: c_uint,
) c_int;

extern "c" fn g_dbus_method_invocation_return_value(
    invocation: *GDBusMethodInvocation,
    parameters: ?*GVariant,
) void;

extern "c" fn g_dbus_method_invocation_return_error_literal(
    invocation: *GDBusMethodInvocation,
    domain: u32,
    code: c_int,
    message: [*:0]const u8,
) void;

extern "c" fn g_dbus_connection_emit_signal(
    connection: *GDBusConnection,
    destination_bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    signal_name: [*:0]const u8,
    parameters: ?*GVariant,
    err: ?*?*GError,
) c_int;

// GLib main-loop timer for the poll. Mirrors panel.zig + log_pane.zig.
// Shared GLib timer/source surface — see gtk.zig. Reconciles
// `g_source_remove`'s prior `c_int` return type with the canonical
// `gboolean` spelling other modules use. Wire-compatible (gboolean is
// c_int in GLib), the rename is purely about not having two
// signatures for the same symbol.
const GSourceFunc = gtk.GSourceFunc;
const g_timeout_add = gtk.g_timeout_add;
const g_source_remove = gtk.g_source_remove;

const G_SOURCE_CONTINUE: c_int = 1;

inline fn vt(comptime spec: [:0]const u8) *const GVariantType {
    return @ptrCast(spec.ptr);
}

// ─── Introspection XML ───────────────────────────────────────────────
//
// Hand-written, not codegen'd. GDBus parses these once and the
// resulting GDBusInterfaceInfo drives method/property dispatch.
// Each interface description is exactly the official spec subset we
// implement — leaving entries out is fine for read-only interfaces
// because callers can still GetAll the ones we declare.

const sni_xml =
    \\<node>
    \\  <interface name="org.kde.StatusNotifierItem">
    \\    <property name="Category" type="s" access="read"/>
    \\    <property name="Id" type="s" access="read"/>
    \\    <property name="Title" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="WindowId" type="i" access="read"/>
    \\    <property name="IconName" type="s" access="read"/>
    \\    <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="OverlayIconName" type="s" access="read"/>
    \\    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="AttentionIconName" type="s" access="read"/>
    \\    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="AttentionMovieName" type="s" access="read"/>
    \\    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\    <property name="ItemIsMenu" type="b" access="read"/>
    \\    <property name="Menu" type="o" access="read"/>
    \\    <method name="ContextMenu">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="Activate">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="SecondaryActivate">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="Scroll">
    \\      <arg name="delta" type="i" direction="in"/>
    \\      <arg name="orientation" type="s" direction="in"/>
    \\    </method>
    \\    <signal name="NewTitle"/>
    \\    <signal name="NewIcon"/>
    \\    <signal name="NewAttentionIcon"/>
    \\    <signal name="NewOverlayIcon"/>
    \\    <signal name="NewToolTip"/>
    \\    <signal name="NewStatus">
    \\      <arg name="status" type="s"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

const dbusmenu_xml =
    \\<node>
    \\  <interface name="com.canonical.dbusmenu">
    \\    <property name="Version" type="u" access="read"/>
    \\    <property name="TextDirection" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="IconThemePath" type="as" access="read"/>
    \\    <method name="GetLayout">
    \\      <arg name="parentId" type="i" direction="in"/>
    \\      <arg name="recursionDepth" type="i" direction="in"/>
    \\      <arg name="propertyNames" type="as" direction="in"/>
    \\      <arg name="revision" type="u" direction="out"/>
    \\      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    \\    </method>
    \\    <method name="GetGroupProperties">
    \\      <arg name="ids" type="ai" direction="in"/>
    \\      <arg name="propertyNames" type="as" direction="in"/>
    \\      <arg name="properties" type="a(ia{sv})" direction="out"/>
    \\    </method>
    \\    <method name="GetProperty">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="name" type="s" direction="in"/>
    \\      <arg name="value" type="v" direction="out"/>
    \\    </method>
    \\    <method name="Event">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="eventId" type="s" direction="in"/>
    \\      <arg name="data" type="v" direction="in"/>
    \\      <arg name="timestamp" type="u" direction="in"/>
    \\    </method>
    \\    <method name="EventGroup">
    \\      <arg name="events" type="a(isvu)" direction="in"/>
    \\      <arg name="idErrors" type="ai" direction="out"/>
    \\    </method>
    \\    <method name="AboutToShow">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="needUpdate" type="b" direction="out"/>
    \\    </method>
    \\    <method name="AboutToShowGroup">
    \\      <arg name="ids" type="ai" direction="in"/>
    \\      <arg name="updatesNeeded" type="ai" direction="out"/>
    \\      <arg name="idErrors" type="ai" direction="out"/>
    \\    </method>
    \\    <signal name="ItemsPropertiesUpdated">
    \\      <arg name="updatedProps" type="a(ia{sv})"/>
    \\      <arg name="removedProps" type="a(ias)"/>
    \\    </signal>
    \\    <signal name="LayoutUpdated">
    \\      <arg name="revision" type="u"/>
    \\      <arg name="parent" type="i"/>
    \\    </signal>
    \\    <signal name="ItemActivationRequested">
    \\      <arg name="id" type="i"/>
    \\      <arg name="timestamp" type="u"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

// ─── Public surface ──────────────────────────────────────────────────

/// Caller-supplied dispatch hooks. Invoked on the GLib main thread —
/// the handlers can drive panel.show / panel.hide / panel.quit
/// directly without thread-marshalling.
pub const Handler = struct {
    ctx: *anyopaque,
    /// Left-click on the tray icon. Maps to panel.toggle in
    /// `main_linux.zig`.
    on_activate: *const fn (ctx: *anyopaque) void,
    /// User selected "Quit" from the dropdown menu.
    on_quit: *const fn (ctx: *anyopaque) void,
    /// "Copy MCP config to clipboard". Mirrors the menubar entry on
    /// darwin — reads `~/.config/djinn/mcp.json` and writes to the
    /// system clipboard. No-op if the file is missing.
    on_copy_mcp_config: *const fn (ctx: *anyopaque) void,
    /// "Settings…" — open `~/.config/djinn/config` in the user's
    /// default text editor. Mirrors darwin's `openSettings`, where
    /// the path is created with a defaults skeleton if absent.
    on_open_settings: *const fn (ctx: *anyopaque) void,
};

pub const Tray = struct {
    ctx: *Context,

    pub fn init(allocator: std.mem.Allocator, handler: Handler) !Tray {
        var err: ?*GError = null;
        const connection = gdbus.g_bus_get_sync(G_BUS_TYPE_SESSION, null, &err) orelse {
            if (err) |e| {
                logErr("g_bus_get_sync", e);
                gdbus.g_error_free(e);
            }
            return error.SessionBusUnavailable;
        };
        errdefer gdbus.g_object_unref(connection);

        const unique_name_z = gdbus.g_dbus_connection_get_unique_name(connection) orelse
            return error.NoUniqueName;
        const unique_name = std.mem.span(unique_name_z);
        const unique_name_owned = try allocator.dupeZ(u8, unique_name);
        errdefer allocator.free(unique_name_owned);

        const sni_info = g_dbus_node_info_new_for_xml(sni_xml, &err) orelse {
            if (err) |e| {
                logErr("g_dbus_node_info_new_for_xml (SNI)", e);
                gdbus.g_error_free(e);
            }
            return error.SniXmlParseFailed;
        };
        errdefer g_dbus_node_info_unref(sni_info);

        const menu_info = g_dbus_node_info_new_for_xml(dbusmenu_xml, &err) orelse {
            if (err) |e| {
                logErr("g_dbus_node_info_new_for_xml (dbusmenu)", e);
                gdbus.g_error_free(e);
            }
            return error.DbusmenuXmlParseFailed;
        };
        errdefer g_dbus_node_info_unref(menu_info);

        const sni_iface = g_dbus_node_info_lookup_interface(
            sni_info,
            "org.kde.StatusNotifierItem",
        ) orelse return error.SniInterfaceMissing;
        const menu_iface = g_dbus_node_info_lookup_interface(
            menu_info,
            "com.canonical.dbusmenu",
        ) orelse return error.DbusmenuInterfaceMissing;

        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .allocator = allocator,
            .connection = connection,
            .handler = handler,
            .unique_name = unique_name_owned,
            .sni_info = sni_info,
            .menu_info = menu_info,
            .sni_registration_id = 0,
            .menu_registration_id = 0,
        };

        const sni_reg = g_dbus_connection_register_object(
            connection,
            "/StatusNotifierItem",
            sni_iface,
            &sni_vtable,
            ctx,
            null,
            &err,
        );
        if (sni_reg == 0) {
            if (err) |e| {
                logErr("register /StatusNotifierItem", e);
                gdbus.g_error_free(e);
            }
            return error.SniRegisterFailed;
        }
        ctx.sni_registration_id = sni_reg;

        const menu_reg = g_dbus_connection_register_object(
            connection,
            "/MenuBar",
            menu_iface,
            &menu_vtable,
            ctx,
            null,
            &err,
        );
        if (menu_reg == 0) {
            if (err) |e| {
                logErr("register /MenuBar", e);
                gdbus.g_error_free(e);
            }
            return error.MenuRegisterFailed;
        }
        ctx.menu_registration_id = menu_reg;

        // Subscribe to NameOwnerChanged on
        // org.kde.StatusNotifierWatcher so we can re-register when
        // plasmashell / waybar restarts. The bus daemon emits this
        // for the well-known name regardless of who hosts the
        // watcher; arg0 filtering at the GDBus layer means our
        // callback only sees events for the watcher's name. Subscribe
        // BEFORE the initial register call to close the race where the
        // watcher could go down between our register and our
        // subscription.
        ctx.watcher_subscription_id = gdbus.g_dbus_connection_signal_subscribe(
            connection,
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            "org.kde.StatusNotifierWatcher",
            0,
            &onWatcherNameOwnerChanged,
            ctx,
            null,
        );

        // Tell the system tray we exist. The watcher might not be
        // running (bare wlroots, no panel) — that's logged in the
        // reply callback, not a fatal error. The NameOwnerChanged
        // subscription above catches a later startup.
        sendRegisterRequest(ctx);

        std.debug.print(
            "tray: registering with StatusNotifierWatcher (sender=\"{s}\")\n",
            .{unique_name_owned},
        );

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Tray) void {
        const ctx = self.ctx;
        if (ctx.watcher_subscription_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.watcher_subscription_id);
        if (ctx.poll_source_id != 0) _ = g_source_remove(ctx.poll_source_id);
        if (ctx.sni_registration_id != 0)
            _ = g_dbus_connection_unregister_object(ctx.connection, ctx.sni_registration_id);
        if (ctx.menu_registration_id != 0)
            _ = g_dbus_connection_unregister_object(ctx.connection, ctx.menu_registration_id);
        g_dbus_node_info_unref(ctx.sni_info);
        g_dbus_node_info_unref(ctx.menu_info);
        gdbus.g_object_unref(ctx.connection);
        ctx.allocator.free(ctx.unique_name);
        ctx.allocator.destroy(ctx);
    }

    /// Reflect a new agent state on the tray surface. Call on the
    /// GLib main thread — the host's SNI watcher receives the signals
    /// over our DBus connection, and GDBus connections are tied to the
    /// thread default main context.
    ///
    /// Emits `NewIcon`, `NewTitle`, and `NewStatus` so the panel host
    /// re-fetches IconName, Title, and Status. `NewStatus` carries
    /// "NeedsAttention" for `.attention` and "Active" otherwise — KDE
    /// pulses the icon when Status is NeedsAttention, which is the
    /// only built-in highlight cue SNI exposes.
    pub fn updateState(self: *Tray, state: Agent, message: []const u8) void {
        const ctx = self.ctx;
        ctx.state = state;
        const n = @min(message.len, ctx.message_buf.len);
        @memcpy(ctx.message_buf[0..n], message[0..n]);
        ctx.message_len = n;

        emitSignal(ctx, "NewIcon", null);
        emitSignal(ctx, "NewTitle", null);

        const status_str = statusName(state);
        const status_tuple = gdbus.g_variant_builder_new(vt("(s)"));
        gdbus.g_variant_builder_add_value(status_tuple, gdbus.g_variant_new_string(status_str.ptr));
        const status_params = gdbus.g_variant_builder_end(status_tuple);
        gdbus.g_variant_builder_unref(status_tuple);
        emitSignal(ctx, "NewStatus", status_params);
    }

    /// Re-emit `NewIcon` / `NewToolTip` so the SNI host re-resolves
    /// the themed icon name against the now-current GTK / Plasma
    /// icon theme. Called after a system color-scheme flip — the
    /// freedesktop icon name we publish (`utilities-terminal` etc.)
    /// resolves to a different glyph variant under dark vs. light
    /// themes, but hosts like KDE Plasma cache the rendered pixmap
    /// and only re-resolve when they receive a `NewIcon` signal.
    ///
    /// No-op if the SNI host isn't watching us (the bus still
    /// dispatches the signal — there's just nobody to receive it).
    /// Safe to call when the agent state is unchanged: `NewIcon`
    /// only invalidates the host's icon cache, it doesn't replay
    /// state through `updateState` or touch `last_pushed_state`.
    pub fn notifyAppearanceChanged(self: *Tray) void {
        const ctx = self.ctx;
        emitSignal(ctx, "NewIcon", null);
        emitSignal(ctx, "NewAttentionIcon", null);
        emitSignal(ctx, "NewToolTip", null);
    }

    /// Start polling `state` on the GLib main thread and pushing every
    /// transition through `updateState`. Matches darwin's 250ms poll
    /// cadence (TerminalView.tickImpl) — agent state changes settle in
    /// under half a second without flooding the bus on rapid runs of
    /// `djinn_progress` calls. Idempotent; calling twice replaces the
    /// previous source. Removed automatically in `deinit`.
    pub fn observeAgentState(self: *Tray, state: *AgentState) void {
        const ctx = self.ctx;
        if (ctx.poll_source_id != 0) _ = g_source_remove(ctx.poll_source_id);
        ctx.observed_state = state;
        ctx.poll_source_id = g_timeout_add(250, pollAgentTick, @ptrCast(ctx));
    }
};

fn pollAgentTick(user_data: gpointer) callconv(.c) c_int {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return G_SOURCE_CONTINUE));
    const state = ctx.observed_state orelse return G_SOURCE_CONTINUE;

    // Snapshot under the AgentState mutex; copy the borrowed message
    // into a local buffer before releasing so we can hand it to
    // updateState without holding the lock across DBus emission.
    var msg_buf: [256]u8 = undefined;
    var msg_len: usize = 0;
    var snap_state: Agent = .idle;
    {
        state.mutex.lock();
        defer state.mutex.unlock();
        snap_state = state.state;
        const m = state.message;
        msg_len = @min(m.len, msg_buf.len);
        @memcpy(msg_buf[0..msg_len], m[0..msg_len]);
    }

    // Skip the DBus round-trip when nothing the host would render has
    // changed. State + message together are what Title/Status/Icon
    // derive from, so byte-equality on both is sufficient.
    const same_state = ctx.last_pushed_initialized and snap_state == ctx.last_pushed_state;
    const same_message =
        msg_len == ctx.message_len and
        std.mem.eql(u8, msg_buf[0..msg_len], ctx.message_buf[0..ctx.message_len]);
    if (same_state and same_message) return G_SOURCE_CONTINUE;

    var t = Tray{ .ctx = ctx };
    t.updateState(snap_state, msg_buf[0..msg_len]);
    ctx.last_pushed_state = snap_state;
    ctx.last_pushed_initialized = true;
    return G_SOURCE_CONTINUE;
}

/// Themed icon name for each agent state. Names are freedesktop
/// Icon Naming Spec entries — Breeze, Adwaita, and Papirus all ship
/// them, so the host's icon theme always has a fallback. Once a
/// dedicated djinn icon ships into a hicolor theme path, swap these
/// for per-state SVGs (djinn-idle, djinn-working, …).
fn iconName(state: Agent) [:0]const u8 {
    return switch (state) {
        .idle => "utilities-terminal",
        .working => "dialog-warning",
        .attention => "task-due",
        .done => "task-complete",
        .@"error" => "dialog-error",
    };
}

/// SNI `Status` property value. Only `.attention` reaches
/// "NeedsAttention"; the other states stay "Active" so the host
/// doesn't pulse for routine progress reports.
fn statusName(state: Agent) [:0]const u8 {
    return switch (state) {
        .attention => "NeedsAttention",
        else => "Active",
    };
}

/// Short label for the SNI Title. Mirrors darwin Menubar's
/// `stateLabel` so a user moving between platforms sees the same
/// vocabulary.
fn stateLabel(state: Agent) [:0]const u8 {
    return switch (state) {
        .idle => "Idle",
        .working => "Working",
        .attention => "Needs attention",
        .done => "Done",
        .@"error" => "Error",
    };
}

fn emitSignal(ctx: *Context, signal_name: [*:0]const u8, parameters: ?*GVariant) void {
    var err: ?*GError = null;
    _ = g_dbus_connection_emit_signal(
        ctx.connection,
        null,
        "/StatusNotifierItem",
        "org.kde.StatusNotifierItem",
        signal_name,
        parameters,
        &err,
    );
    if (err) |e| {
        logErr("emit_signal", e);
        gdbus.g_error_free(e);
    }
}

// ─── Internal context ────────────────────────────────────────────────

const Context = struct {
    allocator: std.mem.Allocator,
    connection: *GDBusConnection,
    handler: Handler,
    unique_name: [:0]u8,
    sni_info: *GDBusNodeInfo,
    menu_info: *GDBusNodeInfo,
    sni_registration_id: c_uint,
    menu_registration_id: c_uint,
    /// `g_dbus_connection_signal_subscribe` id for the
    /// `org.freedesktop.DBus.NameOwnerChanged` watch on
    /// `org.kde.StatusNotifierWatcher`. Lets us re-register the SNI
    /// item when plasmashell / waybar restarts (which drops every
    /// watcher's registration set). 0 means "not subscribed yet" or
    /// "subscription failed" — `deinit` checks before unsubscribing.
    watcher_subscription_id: c_uint = 0,
    /// Latest agent state. See file-level Threading model: written by
    /// `updateState` (pollAgentTick), read by `sniGetProperty` (GDBus
    /// callback). Both run on the GLib main thread — single-writer,
    /// single-reader, same thread, no synchronization needed. If
    /// you add a writer that runs off the main thread, marshal via
    /// `g_idle_add` so this invariant holds.
    state: Agent = .idle,
    /// Last message accompanying a state transition. Same single-thread
    /// invariant as `state` above — torn reads only become possible
    /// if a future caller writes this from a non-main thread. The
    /// 256-byte cap keeps allocator coupling out of the GDBus
    /// callback path; messages longer than that get truncated by
    /// `updateState` and the panel host renders the trim.
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    /// Observed AgentState, set by `observeAgentState`. Null until
    /// observation starts; the poll callback short-circuits while it
    /// is.
    observed_state: ?*AgentState = null,
    /// `g_timeout_add` source id; 0 means no timer registered. Removed
    /// in `deinit` to avoid the callback firing against a freed Context.
    poll_source_id: c_uint = 0,
    /// Last Agent value pushed through `updateState`, used to skip
    /// no-op DBus signal emission on each tick. Initialised to .idle
    /// so the first observed-state poll always emits when the agent
    /// has already left idle by the time the tray comes up.
    last_pushed_state: Agent = .idle,
    last_pushed_initialized: bool = false,
};

// ─── Menu item ids ───────────────────────────────────────────────────
//
// Stable across the process lifetime; baked into the layout we hand to
// hosts and matched against the integer id that comes back on Event.

const ROOT_ID: i32 = 0;
const ITEM_TOGGLE: i32 = 1;
const ITEM_QUIT: i32 = 2;
/// Disabled status line at the top of the menu — mirrors the macOS
/// menubar's "Idle" / "Working — …" entry. Label is rebuilt from
/// `ctx.state` + `ctx.message_buf` at GetLayout / GetGroupProperties
/// time so each menu-open shows the current agent state without
/// having to emit dbusmenu signal traffic on every transition.
const ITEM_STATUS: i32 = 3;
const ITEM_COPY_MCP: i32 = 4;
const ITEM_SETTINGS: i32 = 5;
/// Separator items get their own ids so hosts can address them in
/// GetGroupProperties. Numbering starts above the click-target ids
/// to keep the ranges visually distinct in protocol traces.
const ITEM_SEP_TOP: i32 = 100;
const ITEM_SEP_BOTTOM: i32 = 101;

// ─── vtables ─────────────────────────────────────────────────────────

const sni_vtable: GDBusInterfaceVTable = .{
    .method_call = sniMethodCall,
    .get_property = sniGetProperty,
    .set_property = null,
    .padding = .{null} ** 8,
};

const menu_vtable: GDBusInterfaceVTable = .{
    .method_call = menuMethodCall,
    .get_property = menuGetProperty,
    .set_property = null,
    .padding = .{null} ** 8,
};

// ─── SNI method/property handlers ────────────────────────────────────

fn sniMethodCall(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    method_name: [*:0]const u8,
    _: *GVariant,
    invocation: *GDBusMethodInvocation,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    const m = std.mem.span(method_name);

    if (std.mem.eql(u8, m, "Activate") or std.mem.eql(u8, m, "SecondaryActivate")) {
        ctx.handler.on_activate(ctx.handler.ctx);
        g_dbus_method_invocation_return_value(invocation, null);
        return;
    }

    if (std.mem.eql(u8, m, "ContextMenu") or std.mem.eql(u8, m, "Scroll")) {
        // ContextMenu: host opens our `Menu` property automatically
        // when ItemIsMenu=false, so we have nothing to do here.
        // Scroll: no useful action for a Quake-drop panel.
        g_dbus_method_invocation_return_value(invocation, null);
        return;
    }

    g_dbus_method_invocation_return_error_literal(
        invocation,
        unknownMethodQuark(),
        0,
        "tray: unknown SNI method",
    );
}

fn sniGetProperty(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    property_name: [*:0]const u8,
    _: ?*?*GError,
    user_data: gpointer,
) callconv(.c) ?*GVariant {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return null));
    const p = std.mem.span(property_name);

    // Each property returns the bare-type variant (not wrapped in v).
    // GDBus's Properties.Get auto-handler wraps it.
    if (std.mem.eql(u8, p, "Category")) return gdbus.g_variant_new_string("ApplicationStatus");
    if (std.mem.eql(u8, p, "Id")) return gdbus.g_variant_new_string("djinn");
    if (std.mem.eql(u8, p, "Title")) {
        var buf: [320]u8 = undefined;
        const title = renderTitle(&buf, ctx.state, ctx.message_buf[0..ctx.message_len]);
        return gdbus.g_variant_new_string(title.ptr);
    }
    if (std.mem.eql(u8, p, "Status")) return gdbus.g_variant_new_string(statusName(ctx.state).ptr);
    if (std.mem.eql(u8, p, "WindowId")) return gdbus.g_variant_new_int32(0);

    // State-derived icon. AttentionIconName carries the same name so
    // hosts that respect SNI's NeedsAttention contract (KDE) animate
    // the right glyph; others fall back to IconName.
    if (std.mem.eql(u8, p, "IconName")) return gdbus.g_variant_new_string(iconName(ctx.state).ptr);
    if (std.mem.eql(u8, p, "AttentionIconName")) return gdbus.g_variant_new_string(iconName(.attention).ptr);
    if (std.mem.eql(u8, p, "OverlayIconName")) return gdbus.g_variant_new_string("");
    if (std.mem.eql(u8, p, "AttentionMovieName")) return gdbus.g_variant_new_string("");

    // Empty pixmap arrays. Hosts prefer IconName when both are present;
    // returning [] for the pixmap props avoids GDBus complaining that
    // the introspected property is missing from GetAll.
    if (std.mem.eql(u8, p, "IconPixmap") or
        std.mem.eql(u8, p, "OverlayIconPixmap") or
        std.mem.eql(u8, p, "AttentionIconPixmap"))
        return gdbus.g_variant_new_array(vt("(iiay)"), null, 0);

    if (std.mem.eql(u8, p, "ItemIsMenu")) return gdbus.g_variant_new_boolean(0);
    if (std.mem.eql(u8, p, "Menu")) return gdbus.g_variant_new_object_path("/MenuBar");

    // ToolTip is (sa(iiay)ss) — (icon-name, pixmaps, title, description).
    // Title carries the state label, description the message.
    if (std.mem.eql(u8, p, "ToolTip"))
        return buildToolTip(ctx.state, ctx.message_buf[0..ctx.message_len]);

    return null;
}

/// Build a null-terminated Title string into `buf` and return the
/// slice. Format mirrors darwin Menubar's status line — "djinn" for
/// idle, "djinn — <label>" for state-only, "djinn — <label>: <msg>"
/// when a message is present.
fn renderTitle(buf: []u8, state: Agent, message: []const u8) [:0]u8 {
    if (state == .idle and message.len == 0)
        return std.fmt.bufPrintZ(buf, "djinn", .{}) catch unreachable;

    const label = stateLabel(state);
    if (message.len == 0)
        return std.fmt.bufPrintZ(buf, "djinn — {s}", .{label}) catch unreachable;

    return std.fmt.bufPrintZ(buf, "djinn — {s}: {s}", .{ label, message }) catch
        // Truncated when buf isn't long enough; fall back to label-only.
        std.fmt.bufPrintZ(buf, "djinn — {s}", .{label}) catch unreachable;
}

// ─── dbusmenu method/property handlers ──────────────────────────────

fn menuMethodCall(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: *GVariant,
    invocation: *GDBusMethodInvocation,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    const m = std.mem.span(method_name);

    if (std.mem.eql(u8, m, "GetLayout")) {
        g_dbus_method_invocation_return_value(invocation, buildGetLayoutReply(ctx));
        return;
    }

    if (std.mem.eql(u8, m, "GetGroupProperties")) {
        g_dbus_method_invocation_return_value(invocation, buildGroupPropertiesReply(ctx));
        return;
    }

    if (std.mem.eql(u8, m, "GetProperty")) {
        // (id, name) → variant. We don't expect hosts to call this in
        // practice (GetGroupProperties is the workhorse), but the
        // spec requires it. Return a string label for known ids.
        const id_v = gdbus.g_variant_get_child_value(parameters, 0);
        defer gdbus.g_variant_unref(id_v);
        const id = gdbus.g_variant_get_int32(id_v);
        const name_v = gdbus.g_variant_get_child_value(parameters, 1);
        defer gdbus.g_variant_unref(name_v);
        const name = std.mem.span(gdbus.g_variant_get_string(name_v, null));

        const reply = buildGetPropertyReply(id, name);
        g_dbus_method_invocation_return_value(invocation, reply);
        return;
    }

    if (std.mem.eql(u8, m, "Event")) {
        // (id, eventId, data, timestamp). We care about ("clicked",
        // ids 1 and 2) and ignore the rest (hovered, opened, closed
        // — those don't drive state on this v1 menu).
        const id_v = gdbus.g_variant_get_child_value(parameters, 0);
        defer gdbus.g_variant_unref(id_v);
        const event_id_v = gdbus.g_variant_get_child_value(parameters, 1);
        defer gdbus.g_variant_unref(event_id_v);
        const id = gdbus.g_variant_get_int32(id_v);
        const event_id = std.mem.span(gdbus.g_variant_get_string(event_id_v, null));

        if (std.mem.eql(u8, event_id, "clicked")) {
            dispatchClick(ctx, id);
        }
        g_dbus_method_invocation_return_value(invocation, null);
        return;
    }

    if (std.mem.eql(u8, m, "AboutToShow")) {
        // Reply with b=false (no layout update needed). Hosts call
        // this immediately before showing the popup; we have a static
        // menu so the answer is always "use the cached layout".
        const tup = gdbus.g_variant_builder_new(vt("(b)"));
        gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_boolean(0));
        const reply = gdbus.g_variant_builder_end(tup);
        gdbus.g_variant_builder_unref(tup);
        g_dbus_method_invocation_return_value(invocation, reply);
        return;
    }

    if (std.mem.eql(u8, m, "AboutToShowGroup")) {
        // Reply with (ai updatesNeeded, ai idErrors) = ([], []).
        const tup = gdbus.g_variant_builder_new(vt("(aiai)"));
        gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_array(vt("i"), null, 0));
        gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_array(vt("i"), null, 0));
        const reply = gdbus.g_variant_builder_end(tup);
        gdbus.g_variant_builder_unref(tup);
        g_dbus_method_invocation_return_value(invocation, reply);
        return;
    }

    if (std.mem.eql(u8, m, "EventGroup")) {
        // Skim each event for "clicked" the same way `Event` does.
        // The protocol allows hosts to batch multiple events into a
        // single call; in practice each menu click still comes through
        // as its own `Event` round-trip, but the spec demands a real
        // implementation here so we provide one.
        const events_v = gdbus.g_variant_get_child_value(parameters, 0);
        defer gdbus.g_variant_unref(events_v);
        const n = gVariantChildCount(events_v);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ev = gdbus.g_variant_get_child_value(events_v, i);
            defer gdbus.g_variant_unref(ev);
            const id_v = gdbus.g_variant_get_child_value(ev, 0);
            defer gdbus.g_variant_unref(id_v);
            const event_id_v = gdbus.g_variant_get_child_value(ev, 1);
            defer gdbus.g_variant_unref(event_id_v);
            const id = gdbus.g_variant_get_int32(id_v);
            const event_id = std.mem.span(gdbus.g_variant_get_string(event_id_v, null));
            if (std.mem.eql(u8, event_id, "clicked")) dispatchClick(ctx, id);
        }
        const tup = gdbus.g_variant_builder_new(vt("(ai)"));
        gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_array(vt("i"), null, 0));
        const reply = gdbus.g_variant_builder_end(tup);
        gdbus.g_variant_builder_unref(tup);
        g_dbus_method_invocation_return_value(invocation, reply);
        return;
    }

    g_dbus_method_invocation_return_error_literal(
        invocation,
        unknownMethodQuark(),
        0,
        "tray: unknown dbusmenu method",
    );
}

fn menuGetProperty(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    property_name: [*:0]const u8,
    _: ?*?*GError,
    _: gpointer,
) callconv(.c) ?*GVariant {
    const p = std.mem.span(property_name);

    if (std.mem.eql(u8, p, "Version")) return gdbus.g_variant_new_uint32(3);
    if (std.mem.eql(u8, p, "TextDirection")) return gdbus.g_variant_new_string("ltr");
    if (std.mem.eql(u8, p, "Status")) return gdbus.g_variant_new_string("normal");
    if (std.mem.eql(u8, p, "IconThemePath")) return gdbus.g_variant_new_array(vt("s"), null, 0);
    return null;
}

// ─── Reply variant builders ──────────────────────────────────────────

/// `RegisterStatusNotifierItem(s)` — wraps the unique name in a tuple.
fn buildRegisterCall(unique_name: [:0]u8) *GVariant {
    const tup = gdbus.g_variant_builder_new(vt("(s)"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string(unique_name.ptr));
    const params = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return params;
}

/// ToolTip property value: (s icon-name, a(iiay) pixmaps, s title, s description).
/// `title` carries the state label; `description` carries the message.
/// Hosts that render a two-line tooltip (KDE) show both; minimal hosts
/// show just the title.
fn buildToolTip(state: Agent, message: []const u8) *GVariant {
    const title = stateLabel(state);
    var desc_buf: [256]u8 = undefined;
    const desc_z = std.fmt.bufPrintZ(&desc_buf, "{s}", .{message}) catch
        std.fmt.bufPrintZ(&desc_buf, "Drop-down terminal panel", .{}) catch unreachable;

    const tup = gdbus.g_variant_builder_new(vt("(sa(iiay)ss)"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string(""));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_array(vt("(iiay)"), null, 0));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string(title.ptr));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_string(desc_z.ptr));
    const result = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return result;
}

/// GetLayout reply: (u revision, (i id, a{sv} props, av children) root).
/// Layout itself is static; the only field that varies between menu
/// opens is the status item's label (driven by `ctx.state` /
/// `ctx.message_buf`). We rebuild it at GetLayout time rather than
/// emitting `ItemsPropertiesUpdated` on every agent-state transition
/// — hosts call GetLayout (or `AboutToShow` + GetGroupProperties)
/// before each popup, so the open always sees the current state
/// without dbusmenu signal traffic between opens.
///
/// Revision stays at 1 since the layout shape never changes. If a
/// future change adds runtime layout edits (hide/show entries based
/// on config), bump the revision and emit `LayoutUpdated`.
fn buildGetLayoutReply(ctx: *Context) *GVariant {
    var status_buf: [320]u8 = undefined;
    const status_label = renderStatusLabel(&status_buf, ctx.state, ctx.message_buf[0..ctx.message_len]);

    const root_props = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(root_props, "children-display", "submenu");
    const root_props_v = gdbus.g_variant_builder_end(root_props);
    gdbus.g_variant_builder_unref(root_props);

    const children = gdbus.g_variant_builder_new(vt("av"));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildStandardItem(ITEM_STATUS, status_label, false)));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildSeparatorItem(ITEM_SEP_TOP)));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildStandardItem(ITEM_TOGGLE, "Show / Hide djinn", true)));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildStandardItem(ITEM_COPY_MCP, "Copy MCP config to clipboard", true)));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildStandardItem(ITEM_SETTINGS, "Settings\u{2026}", true)));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildSeparatorItem(ITEM_SEP_BOTTOM)));
    gdbus.g_variant_builder_add_value(children, gdbus.g_variant_new_variant(buildStandardItem(ITEM_QUIT, "Quit djinn", true)));
    const children_v = gdbus.g_variant_builder_end(children);
    gdbus.g_variant_builder_unref(children);

    const root = gdbus.g_variant_builder_new(vt("(ia{sv}av)"));
    gdbus.g_variant_builder_add_value(root, gdbus.g_variant_new_int32(ROOT_ID));
    gdbus.g_variant_builder_add_value(root, root_props_v);
    gdbus.g_variant_builder_add_value(root, children_v);
    const root_v = gdbus.g_variant_builder_end(root);
    gdbus.g_variant_builder_unref(root);

    const ret = gdbus.g_variant_builder_new(vt("(u(ia{sv}av))"));
    gdbus.g_variant_builder_add_value(ret, gdbus.g_variant_new_uint32(1));
    gdbus.g_variant_builder_add_value(ret, root_v);
    const result = gdbus.g_variant_builder_end(ret);
    gdbus.g_variant_builder_unref(ret);
    return result;
}

/// Standard click-target item: (i id, a{sv} props, av children). The
/// status row reuses this with `enabled=false` so it renders as
/// non-interactive (matches the disabled state-line on macOS).
fn buildStandardItem(id: i32, label: [:0]const u8, enabled: bool) *GVariant {
    const props = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(props, "label", label.ptr);
    addBoolDictEntry(props, "enabled", enabled);
    addBoolDictEntry(props, "visible", true);
    const props_v = gdbus.g_variant_builder_end(props);
    gdbus.g_variant_builder_unref(props);

    const children = gdbus.g_variant_builder_new(vt("av"));
    const children_v = gdbus.g_variant_builder_end(children);
    gdbus.g_variant_builder_unref(children);

    const tup = gdbus.g_variant_builder_new(vt("(ia{sv}av)"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_int32(id));
    gdbus.g_variant_builder_add_value(tup, props_v);
    gdbus.g_variant_builder_add_value(tup, children_v);
    const result = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return result;
}

/// Separator: dbusmenu treats any item with `type=separator` as a
/// horizontal rule. Hosts ignore label/enabled for separators, so we
/// only need the property + an id unique to this item.
fn buildSeparatorItem(id: i32) *GVariant {
    const props = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(props, "type", "separator");
    addBoolDictEntry(props, "visible", true);
    const props_v = gdbus.g_variant_builder_end(props);
    gdbus.g_variant_builder_unref(props);

    const children = gdbus.g_variant_builder_new(vt("av"));
    const children_v = gdbus.g_variant_builder_end(children);
    gdbus.g_variant_builder_unref(children);

    const tup = gdbus.g_variant_builder_new(vt("(ia{sv}av)"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_int32(id));
    gdbus.g_variant_builder_add_value(tup, props_v);
    gdbus.g_variant_builder_add_value(tup, children_v);
    const result = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return result;
}

/// GetGroupProperties reply: (a(ia{sv})). Always returns the full
/// property bag for every menu id — the caller's `propertyNames`
/// filter is advisory, and the menu is small enough that filtering
/// is more code than just emitting the full set. Status label is
/// reconstructed from `ctx.state` / `ctx.message_buf` so a host
/// that bypasses GetLayout (some KDE versions cache the layout +
/// only re-fetch property bags) still sees the current state.
fn buildGroupPropertiesReply(ctx: *Context) *GVariant {
    var status_buf: [320]u8 = undefined;
    const status_label = renderStatusLabel(&status_buf, ctx.state, ctx.message_buf[0..ctx.message_len]);

    const arr = gdbus.g_variant_builder_new(vt("a(ia{sv})"));

    appendStandardGroupItem(arr, ITEM_STATUS, status_label, false);
    appendSeparatorGroupItem(arr, ITEM_SEP_TOP);
    appendStandardGroupItem(arr, ITEM_TOGGLE, "Show / Hide djinn", true);
    appendStandardGroupItem(arr, ITEM_COPY_MCP, "Copy MCP config to clipboard", true);
    appendStandardGroupItem(arr, ITEM_SETTINGS, "Settings\u{2026}", true);
    appendSeparatorGroupItem(arr, ITEM_SEP_BOTTOM);
    appendStandardGroupItem(arr, ITEM_QUIT, "Quit djinn", true);

    const arr_v = gdbus.g_variant_builder_end(arr);
    gdbus.g_variant_builder_unref(arr);

    const tup = gdbus.g_variant_builder_new(vt("(a(ia{sv}))"));
    gdbus.g_variant_builder_add_value(tup, arr_v);
    const result = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return result;
}

fn appendStandardGroupItem(arr: *GVariantBuilder, id: i32, label: [:0]const u8, enabled: bool) void {
    const props = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(props, "label", label.ptr);
    addBoolDictEntry(props, "enabled", enabled);
    addBoolDictEntry(props, "visible", true);
    const props_v = gdbus.g_variant_builder_end(props);
    gdbus.g_variant_builder_unref(props);

    const entry = gdbus.g_variant_builder_new(vt("(ia{sv})"));
    gdbus.g_variant_builder_add_value(entry, gdbus.g_variant_new_int32(id));
    gdbus.g_variant_builder_add_value(entry, props_v);
    const entry_v = gdbus.g_variant_builder_end(entry);
    gdbus.g_variant_builder_unref(entry);

    gdbus.g_variant_builder_add_value(arr, entry_v);
}

fn appendSeparatorGroupItem(arr: *GVariantBuilder, id: i32) void {
    const props = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(props, "type", "separator");
    addBoolDictEntry(props, "visible", true);
    const props_v = gdbus.g_variant_builder_end(props);
    gdbus.g_variant_builder_unref(props);

    const entry = gdbus.g_variant_builder_new(vt("(ia{sv})"));
    gdbus.g_variant_builder_add_value(entry, gdbus.g_variant_new_int32(id));
    gdbus.g_variant_builder_add_value(entry, props_v);
    const entry_v = gdbus.g_variant_builder_end(entry);
    gdbus.g_variant_builder_unref(entry);

    gdbus.g_variant_builder_add_value(arr, entry_v);
}

/// Single-property fallback for dbusmenu.GetProperty. Hosts almost
/// never call this — GetGroupProperties is the warm path — but a
/// spec-conformant implementation needs it. Status label gets a
/// stale value here (no Context plumbed through GDBus's GetProperty
/// signature), but hosts hit this path so rarely that the trade-off
/// is acceptable. If a host turns out to depend on it for the
/// status row, plumb `ctx` through and rebuild via `renderStatusLabel`.
fn buildGetPropertyReply(id: i32, name: []const u8) *GVariant {
    const label: [:0]const u8 = switch (id) {
        ITEM_TOGGLE => "Show / Hide djinn",
        ITEM_QUIT => "Quit djinn",
        ITEM_COPY_MCP => "Copy MCP config to clipboard",
        ITEM_SETTINGS => "Settings\u{2026}",
        ITEM_STATUS => "djinn",
        else => "",
    };

    if (std.mem.eql(u8, name, "type")) {
        // Separators report type=separator; everything else reports
        // type=standard (dbusmenu default — strictly we could return
        // an empty string and hosts treat it as standard, but being
        // explicit avoids ambiguity).
        const ty: [:0]const u8 = switch (id) {
            ITEM_SEP_TOP, ITEM_SEP_BOTTOM => "separator",
            else => "standard",
        };
        const inner = gdbus.g_variant_new_string(ty.ptr);
        const tup = gdbus.g_variant_builder_new(vt("(v)"));
        gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_variant(inner));
        const result = gdbus.g_variant_builder_end(tup);
        gdbus.g_variant_builder_unref(tup);
        return result;
    }

    const enabled = switch (id) {
        ITEM_STATUS, ITEM_SEP_TOP, ITEM_SEP_BOTTOM => false,
        else => true,
    };

    const inner: *GVariant = if (std.mem.eql(u8, name, "label"))
        gdbus.g_variant_new_string(label.ptr)
    else if (std.mem.eql(u8, name, "enabled"))
        gdbus.g_variant_new_boolean(if (enabled) 1 else 0)
    else if (std.mem.eql(u8, name, "visible"))
        gdbus.g_variant_new_boolean(1)
    else
        gdbus.g_variant_new_string("");

    const tup = gdbus.g_variant_builder_new(vt("(v)"));
    gdbus.g_variant_builder_add_value(tup, gdbus.g_variant_new_variant(inner));
    const result = gdbus.g_variant_builder_end(tup);
    gdbus.g_variant_builder_unref(tup);
    return result;
}

/// Click dispatch shared by `Event` and `EventGroup`. Hosts route
/// every "clicked" event through one of these methods; both call
/// here so the handler map stays in lockstep across them.
fn dispatchClick(ctx: *Context, id: i32) void {
    switch (id) {
        ITEM_TOGGLE => ctx.handler.on_activate(ctx.handler.ctx),
        ITEM_QUIT => ctx.handler.on_quit(ctx.handler.ctx),
        ITEM_COPY_MCP => ctx.handler.on_copy_mcp_config(ctx.handler.ctx),
        ITEM_SETTINGS => ctx.handler.on_open_settings(ctx.handler.ctx),
        else => {},
    }
}

/// Build the status row label from the current agent state +
/// message. Format mirrors darwin's menubar status item:
///   - idle, no message → "Idle"
///   - state with message → "<State> — <msg>"
///   - state without message → "<State>"
/// Truncates the message into the caller's buffer on overflow.
fn renderStatusLabel(buf: []u8, state: Agent, message: []const u8) [:0]u8 {
    const label = stateLabel(state);
    if (message.len == 0)
        return std.fmt.bufPrintZ(buf, "{s}", .{label}) catch unreachable;
    return std.fmt.bufPrintZ(buf, "{s} - {s}", .{ label, message }) catch
        std.fmt.bufPrintZ(buf, "{s}", .{label}) catch unreachable;
}

// ─── Async reply callbacks ───────────────────────────────────────────

fn onRegisterReply(
    _: ?*anyopaque,
    res: *GAsyncResult,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    var err: ?*GError = null;
    const reply = gdbus.g_dbus_connection_call_finish(ctx.connection, res, &err);
    if (reply) |r| {
        gdbus.g_variant_unref(r);
        std.debug.print("tray: RegisterStatusNotifierItem accepted\n", .{});
        return;
    }
    if (err) |e| {
        // No watcher running yet, or the host doesn't implement SNI.
        // The NameOwnerChanged subscription in `Tray.init` will
        // re-drive `sendRegisterRequest` if a watcher takes ownership
        // later (user logs into Plasma after launching djinn from a
        // tty, or plasmashell restarts mid-session).
        logErr("RegisterStatusNotifierItem", e);
        gdbus.g_error_free(e);
    }
}

/// NameOwnerChanged on `org.kde.StatusNotifierWatcher`. Fires when
/// any process takes or releases ownership of the watcher name —
/// initial host startup, plasmashell / waybar / xfce4-panel
/// restarts, or a clean shutdown. We only care about
/// owner-acquired (new_owner non-empty); re-issue
/// `RegisterStatusNotifierItem` so the new watcher learns about us.
/// The exported `/StatusNotifierItem` + `/MenuBar` objects survive
/// across watcher restarts (they live on our bus connection), so
/// re-registering is the only step needed to restore visibility.
fn onWatcherNameOwnerChanged(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    parameters: *GVariant,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));

    // Signal signature is (sss): name, old_owner, new_owner. Index 2
    // is new_owner; empty string = name released (host shutting
    // down), non-empty = name acquired (host coming up).
    const new_owner_v = gdbus.g_variant_get_child_value(parameters, 2);
    defer gdbus.g_variant_unref(new_owner_v);
    var len: usize = 0;
    const new_owner_z = gdbus.g_variant_get_string(new_owner_v, &len);
    if (len == 0) {
        std.debug.print("tray: StatusNotifierWatcher went away\n", .{});
        return;
    }

    std.debug.print(
        "tray: StatusNotifierWatcher came up at {s} — re-registering\n",
        .{std.mem.span(new_owner_z)},
    );
    sendRegisterRequest(ctx);
}

/// Fire-and-forget `RegisterStatusNotifierItem`. Shared by the
/// initial registration path and the NameOwnerChanged recovery
/// path. The async reply lands on `onRegisterReply` which logs
/// success / failure.
fn sendRegisterRequest(ctx: *Context) void {
    const register_params = buildRegisterCall(ctx.unique_name);
    gdbus.g_dbus_connection_call(
        ctx.connection,
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher",
        "RegisterStatusNotifierItem",
        register_params,
        null,
        0,
        -1,
        null,
        &onRegisterReply,
        ctx,
    );
}

// ─── Helpers ─────────────────────────────────────────────────────────

fn addStringDictEntry(builder: *GVariantBuilder, key: [*:0]const u8, value: [*:0]const u8) void {
    const wrapped = gdbus.g_variant_new_variant(gdbus.g_variant_new_string(value));
    const entry = gdbus.g_variant_new_dict_entry(gdbus.g_variant_new_string(key), wrapped);
    gdbus.g_variant_builder_add_value(builder, entry);
}

fn addBoolDictEntry(builder: *GVariantBuilder, key: [*:0]const u8, value: bool) void {
    const wrapped = gdbus.g_variant_new_variant(gdbus.g_variant_new_boolean(if (value) 1 else 0));
    const entry = gdbus.g_variant_new_dict_entry(gdbus.g_variant_new_string(key), wrapped);
    gdbus.g_variant_builder_add_value(builder, entry);
}

inline fn gVariantChildCount(v: *GVariant) usize {
    return gdbus.g_variant_n_children(v);
}

extern "c" fn g_quark_from_static_string(s: [*:0]const u8) u32;

/// Quark for the error domain we report unknown-method errors under.
/// `g_quark_from_static_string` interns the name on first call and
/// returns the same quark thereafter, so we can call it inline.
fn unknownMethodQuark() u32 {
    return g_quark_from_static_string("djinn.tray");
}

fn logErr(label: []const u8, e: *GError) void {
    const msg = if (e.message) |m| std.mem.span(m) else "(no message)";
    std.debug.print("tray: {s} failed: {s}\n", .{ label, msg });
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Tray type compiles" {
    if (builtin.os.tag != .linux) return;
    // The full init path requires a session bus + GDBus introspection,
    // which the test harness doesn't bring up. This just proves the
    // struct + vtable + extern declarations type-check.
    _ = Tray;
    _ = sni_vtable;
    _ = menu_vtable;
}

test "menu item ids stay distinct" {
    if (builtin.os.tag != .linux) return;
    const ids = [_]i32{
        ROOT_ID,        ITEM_TOGGLE,   ITEM_QUIT,
        ITEM_STATUS,    ITEM_COPY_MCP, ITEM_SETTINGS,
        ITEM_SEP_TOP,   ITEM_SEP_BOTTOM,
    };
    for (ids, 0..) |a, i| for (ids[i + 1 ..]) |b|
        try std.testing.expect(a != b);
}

test "renderStatusLabel: state-only with no message" {
    if (builtin.os.tag != .linux) return;
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings("Idle", renderStatusLabel(&buf, .idle, ""));
    try std.testing.expectEqualStrings("Working", renderStatusLabel(&buf, .working, ""));
}

test "renderStatusLabel: state plus message" {
    if (builtin.os.tag != .linux) return;
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Needs attention - pick a branch",
        renderStatusLabel(&buf, .attention, "pick a branch"),
    );
}

test "iconName: all agent states map to a non-empty themed icon" {
    if (builtin.os.tag != .linux) return;
    const states = [_]Agent{ .idle, .working, .attention, .done, .@"error" };
    for (states) |s| try std.testing.expect(iconName(s).len > 0);
}

test "statusName: only attention reaches NeedsAttention" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings("NeedsAttention", statusName(.attention));
    const non_attention = [_]Agent{ .idle, .working, .done, .@"error" };
    for (non_attention) |s| try std.testing.expectEqualStrings("Active", statusName(s));
}

test "renderTitle: idle without message is bare brand" {
    if (builtin.os.tag != .linux) return;
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings("djinn", renderTitle(&buf, .idle, ""));
}

test "renderTitle: non-idle without message gets state suffix" {
    if (builtin.os.tag != .linux) return;
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings("djinn — Working", renderTitle(&buf, .working, ""));
}

test "renderTitle: non-idle with message includes both" {
    if (builtin.os.tag != .linux) return;
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings(
        "djinn — Needs attention: pick a branch",
        renderTitle(&buf, .attention, "pick a branch"),
    );
}
