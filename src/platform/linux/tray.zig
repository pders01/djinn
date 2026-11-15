//! Terminal StatusNotifierItem + dbusmenu. Event driven; no status polling.
const std = @import("std");
const db = @import("gdbus.zig");
const V = db.GVariant;
const B = db.GVariantBuilder;
const Connection = db.GDBusConnection;
const Error = db.GError;
const Node = opaque {};
const Interface = opaque {};
const Invocation = opaque {};
const Method = *const fn (*Connection, ?[*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, *V, *Invocation, ?*anyopaque) callconv(.c) void;
const Property = *const fn (*Connection, ?[*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*?*Error, ?*anyopaque) callconv(.c) ?*V;
const VTable = extern struct { method_call: ?Method, get_property: ?Property, set_property: ?*const anyopaque = null, padding: [8]?*anyopaque = @splat(null) };
extern "c" fn g_dbus_node_info_new_for_xml([*:0]const u8, ?*?*Error) ?*Node;
extern "c" fn g_dbus_node_info_lookup_interface(*Node, [*:0]const u8) ?*Interface;
extern "c" fn g_dbus_node_info_unref(*Node) void;
extern "c" fn g_dbus_connection_register_object(*Connection, [*:0]const u8, *Interface, *const VTable, ?*anyopaque, ?*const anyopaque, ?*?*Error) c_uint;
extern "c" fn g_dbus_connection_unregister_object(*Connection, c_uint) c_int;
extern "c" fn g_dbus_method_invocation_return_value(*Invocation, ?*V) void;
extern "c" fn g_dbus_method_invocation_return_error_literal(*Invocation, u32, c_int, [*:0]const u8) void;
extern "c" fn g_dbus_connection_emit_signal(*Connection, ?[*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*V, ?*?*Error) c_int;
extern "c" fn g_quark_from_static_string([*:0]const u8) u32;

const sni_xml =
    \\<node><interface name="org.kde.StatusNotifierItem">
    \\<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
    \\<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
    \\<property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
    \\<property name="IconPixmap" type="a(iiay)" access="read"/><property name="OverlayIconName" type="s" access="read"/>
    \\<property name="OverlayIconPixmap" type="a(iiay)" access="read"/><property name="AttentionIconName" type="s" access="read"/>
    \\<property name="AttentionIconPixmap" type="a(iiay)" access="read"/><property name="AttentionMovieName" type="s" access="read"/>
    \\<property name="ToolTip" type="(sa(iiay)ss)" access="read"/><property name="ItemIsMenu" type="b" access="read"/>
    \\<property name="Menu" type="o" access="read"/>
    \\<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    \\<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    \\<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    \\<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
    \\<signal name="NewTitle"/><signal name="NewIcon"/><signal name="NewAttentionIcon"/><signal name="NewToolTip"/>
    \\<signal name="NewStatus"><arg type="s"/></signal>
    \\</interface></node>
;
const menu_xml =
    \\<node><interface name="com.canonical.dbusmenu">
    \\<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
    \\<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
    \\<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
    \\<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
    \\<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    \\<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
    \\<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
    \\<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
    \\<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
    \\<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
    \\<signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
    \\</interface></node>
;

pub const Handler = struct {
    ctx: *anyopaque,
    on_activate: *const fn (*anyopaque) void,
    on_show: *const fn (*anyopaque) void,
    on_hide: *const fn (*anyopaque) void,
    on_quit: *const fn (*anyopaque) void,
    on_open_settings: *const fn (*anyopaque) void,
    on_toggle_login: *const fn (*anyopaque) void,
    login_enabled: *const fn (*anyopaque) bool,
};
const Context = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    handler: Handler,
    sni_info: *Node,
    menu_info: *Node,
    sni_id: c_uint = 0,
    menu_id: c_uint = 0,
    watcher_id: c_uint = 0,
    revision: u32 = 1,
};
pub const Tray = struct {
    ctx: *Context,
    pub fn init(a: std.mem.Allocator, handler: Handler) !Tray {
        var err: ?*Error = null;
        defer if (err) |e| {
            logErr("initialization", e);
            db.g_error_free(e);
        };
        const connection = db.g_bus_get_sync(db.G_BUS_TYPE_SESSION, null, &err) orelse return error.SessionBusUnavailable;
        errdefer db.g_object_unref(connection);
        const sni = g_dbus_node_info_new_for_xml(sni_xml, &err) orelse return error.InvalidSniXml;
        errdefer g_dbus_node_info_unref(sni);
        const menu = g_dbus_node_info_new_for_xml(menu_xml, &err) orelse return error.InvalidMenuXml;
        errdefer g_dbus_node_info_unref(menu);
        const ctx = try a.create(Context);
        errdefer a.destroy(ctx);
        ctx.* = .{ .allocator = a, .connection = connection, .handler = handler, .sni_info = sni, .menu_info = menu };
        const sni_interface = g_dbus_node_info_lookup_interface(sni, "org.kde.StatusNotifierItem") orelse return error.MissingInterface;
        const menu_interface = g_dbus_node_info_lookup_interface(menu, "com.canonical.dbusmenu") orelse return error.MissingInterface;
        ctx.sni_id = g_dbus_connection_register_object(connection, "/StatusNotifierItem", sni_interface, &sni_vtable, ctx, null, &err);
        if (ctx.sni_id == 0) return error.RegisterFailed;
        errdefer _ = g_dbus_connection_unregister_object(connection, ctx.sni_id);
        ctx.menu_id = g_dbus_connection_register_object(connection, "/MenuBar", menu_interface, &menu_vtable, ctx, null, &err);
        if (ctx.menu_id == 0) return error.RegisterFailed;
        ctx.watcher_id = db.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", "org.kde.StatusNotifierWatcher", 0, watcherChanged, ctx, null);
        register(ctx);
        return .{ .ctx = ctx };
    }
    pub fn deinit(self: *Tray) void {
        const ctx = self.ctx;
        if (ctx.watcher_id != 0) db.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.watcher_id);
        _ = g_dbus_connection_unregister_object(ctx.connection, ctx.menu_id);
        _ = g_dbus_connection_unregister_object(ctx.connection, ctx.sni_id);
        g_dbus_node_info_unref(ctx.sni_info);
        g_dbus_node_info_unref(ctx.menu_info);
        db.g_object_unref(ctx.connection);
        ctx.allocator.destroy(ctx);
    }
    pub fn notifyAppearanceChanged(self: *Tray) void {
        emit(self.ctx, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon", null);
        emit(self.ctx, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewToolTip", null);
    }
    pub fn notifyMenuChanged(self: *Tray) void {
        self.ctx.revision +%= 1;
        emit(self.ctx, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated", tuple(&.{ db.g_variant_new_uint32(self.ctx.revision), db.g_variant_new_int32(0) }));
    }
};
const sni_vtable = VTable{ .method_call = sniMethod, .get_property = sniProperty };
const menu_vtable = VTable{ .method_call = menuMethod, .get_property = menuProperty };
const Item = struct { id: i32, label: [:0]const u8 };
const items = [_]Item{
    .{ .id = 1, .label = "Show djinn" },
    .{ .id = 2, .label = "Hide djinn" },
    .{ .id = 3, .label = "Settings…" },
    .{ .id = 4, .label = "Launch at Login" },
    .{ .id = 5, .label = "Quit djinn" },
};
fn sniMethod(_: *Connection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, name: [*:0]const u8, _: *V, invocation: *Invocation, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return));
    const method = std.mem.span(name);
    if (eq(method, "Activate") or eq(method, "SecondaryActivate")) ctx.handler.on_activate(ctx.handler.ctx) else if (!eq(method, "ContextMenu") and !eq(method, "Scroll")) {
        unknown(invocation);
        return;
    }
    g_dbus_method_invocation_return_value(invocation, null);
}
fn sniProperty(_: *Connection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, name: [*:0]const u8, _: ?*?*Error, _: ?*anyopaque) callconv(.c) ?*V {
    const p = std.mem.span(name);
    if (eq(p, "Category")) return string("ApplicationStatus");
    if (eq(p, "Id") or eq(p, "Title")) return string("djinn");
    if (eq(p, "Status")) return string("Active");
    if (eq(p, "WindowId")) return db.g_variant_new_int32(0);
    if (eq(p, "IconName") or eq(p, "AttentionIconName")) return string("utilities-terminal");
    if (eq(p, "OverlayIconName") or eq(p, "AttentionMovieName")) return string("");
    if (eq(p, "IconPixmap") or eq(p, "OverlayIconPixmap") or eq(p, "AttentionIconPixmap")) return empty("(iiay)");
    if (eq(p, "ItemIsMenu")) return boolean(false);
    if (eq(p, "Menu")) return db.g_variant_new_object_path("/MenuBar");
    if (eq(p, "ToolTip")) return tuple(&.{ string("utilities-terminal"), empty("(iiay)"), string("djinn"), string("Drop-down terminal") });
    return null;
}
fn menuMethod(_: *Connection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, name: [*:0]const u8, parameters: *V, invocation: *Invocation, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return));
    const method = std.mem.span(name);
    var reply: ?*V = null;
    if (eq(method, "GetLayout")) {
        const parent = childInt(parameters, 0);
        if (parent == 0) {
            const children = builder("av");
            for (items) |item| db.g_variant_builder_add_value(children, db.g_variant_new_variant(layoutItem(ctx, item)));
            const props = builder("a{sv}");
            dict(props, "children-display", string("submenu"));
            reply = tuple(&.{ db.g_variant_new_uint32(ctx.revision), tuple(&.{ db.g_variant_new_int32(0), end(props), end(children) }) });
        } else {
            for (items) |item| if (item.id == parent) {
                reply = tuple(&.{ db.g_variant_new_uint32(ctx.revision), layoutItem(ctx, item) });
                break;
            };
            if (reply == null) {
                unknown(invocation);
                return;
            }
        }
    } else if (eq(method, "GetGroupProperties")) {
        const ids = db.g_variant_get_child_value(parameters, 0);
        defer db.g_variant_unref(ids);
        const arr = builder("a(ia{sv})");
        for (items) |item| {
            var wanted = db.g_variant_n_children(ids) == 0;
            for (0..db.g_variant_n_children(ids)) |i| {
                if (childInt(ids, i) == item.id) wanted = true;
            }
            if (wanted) db.g_variant_builder_add_value(arr, tuple(&.{ db.g_variant_new_int32(item.id), itemProperties(ctx, item) }));
        }
        reply = tuple(&.{end(arr)});
    } else if (eq(method, "GetProperty")) {
        const id = childInt(parameters, 0);
        const prop = db.g_variant_get_child_value(parameters, 1);
        defer db.g_variant_unref(prop);
        const p = std.mem.span(db.g_variant_get_string(prop, null));
        for (items) |item| if (item.id == id) {
            const value: *V = if (eq(p, "label")) string(item.label.ptr) else if (eq(p, "enabled") or eq(p, "visible")) boolean(true) else if (eq(p, "toggle-type") and id == 4) string("checkmark") else if (eq(p, "toggle-state") and id == 4) db.g_variant_new_int32(if (ctx.handler.login_enabled(ctx.handler.ctx)) 1 else 0) else string("");
            reply = tuple(&.{db.g_variant_new_variant(value)});
            break;
        };
        if (reply == null) {
            unknown(invocation);
            return;
        }
    } else if (eq(method, "Event")) {
        event(ctx, parameters);
    } else if (eq(method, "EventGroup")) {
        const events = db.g_variant_get_child_value(parameters, 0);
        defer db.g_variant_unref(events);
        for (0..db.g_variant_n_children(events)) |i| {
            const ev = db.g_variant_get_child_value(events, i);
            defer db.g_variant_unref(ev);
            event(ctx, ev);
        }
        reply = tuple(&.{empty("i")});
    } else if (eq(method, "AboutToShow")) {
        reply = tuple(&.{boolean(false)});
    } else if (eq(method, "AboutToShowGroup")) {
        reply = tuple(&.{ empty("i"), empty("i") });
    } else {
        unknown(invocation);
        return;
    }
    g_dbus_method_invocation_return_value(invocation, reply);
}
fn menuProperty(_: *Connection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, name: [*:0]const u8, _: ?*?*Error, _: ?*anyopaque) callconv(.c) ?*V {
    const p = std.mem.span(name);
    if (eq(p, "Version")) return db.g_variant_new_uint32(3);
    if (eq(p, "TextDirection")) return string("ltr");
    if (eq(p, "Status")) return string("normal");
    if (eq(p, "IconThemePath")) return empty("s");
    return null;
}
fn event(ctx: *Context, ev: *V) void {
    const name = db.g_variant_get_child_value(ev, 1);
    defer db.g_variant_unref(name);
    if (!eq(std.mem.span(db.g_variant_get_string(name, null)), "clicked")) return;
    switch (childInt(ev, 0)) {
        1 => ctx.handler.on_show(ctx.handler.ctx),
        2 => ctx.handler.on_hide(ctx.handler.ctx),
        3 => ctx.handler.on_open_settings(ctx.handler.ctx),
        4 => ctx.handler.on_toggle_login(ctx.handler.ctx),
        5 => ctx.handler.on_quit(ctx.handler.ctx),
        else => {},
    }
}
fn itemProperties(ctx: *Context, item: Item) *V {
    const props = builder("a{sv}");
    dict(props, "label", string(item.label.ptr));
    dict(props, "enabled", boolean(true));
    dict(props, "visible", boolean(true));
    if (item.id == 4) {
        dict(props, "toggle-type", string("checkmark"));
        dict(props, "toggle-state", db.g_variant_new_int32(if (ctx.handler.login_enabled(ctx.handler.ctx)) 1 else 0));
    }
    return end(props);
}
fn layoutItem(ctx: *Context, item: Item) *V {
    return tuple(&.{ db.g_variant_new_int32(item.id), itemProperties(ctx, item), empty("v") });
}
fn register(ctx: *Context) void {
    const name = db.g_dbus_connection_get_unique_name(ctx.connection) orelse return;
    // Completion deliberately receives NO Context. GIO retains source_object
    // through completion, so a pending reply cannot touch a destroyed Tray.
    db.g_dbus_connection_call(ctx.connection, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem", tuple(&.{string(name)}), null, 0, 3000, null, registerReply, null);
}
fn registerReply(source: ?*anyopaque, result: *db.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const connection: *Connection = @ptrCast(source orelse return);
    var err: ?*Error = null;
    if (db.g_dbus_connection_call_finish(connection, result, &err)) |reply| db.g_variant_unref(reply);
    if (err) |e| {
        logErr("StatusNotifierWatcher registration", e);
        db.g_error_free(e);
    }
}
fn watcherChanged(_: *Connection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, parameters: *V, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return));
    const owner = db.g_variant_get_child_value(parameters, 2);
    defer db.g_variant_unref(owner);
    if (std.mem.span(db.g_variant_get_string(owner, null)).len > 0) register(ctx);
}
fn emit(ctx: *Context, path: [*:0]const u8, iface: [*:0]const u8, signal: [*:0]const u8, params: ?*V) void {
    var err: ?*Error = null;
    _ = g_dbus_connection_emit_signal(ctx.connection, null, path, iface, signal, params, &err);
    if (err) |e| {
        logErr("emit signal", e);
        db.g_error_free(e);
    }
}
fn unknown(invocation: *Invocation) void {
    g_dbus_method_invocation_return_error_literal(invocation, g_quark_from_static_string("djinn.tray"), 0, "Unknown menu method or item");
}
fn logErr(label: []const u8, err: *Error) void {
    std.debug.print("tray: {s}: {s}\n", .{ label, if (err.message) |m| std.mem.span(m) else "unknown error" });
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn vt(comptime spec: [:0]const u8) *const db.GVariantType {
    return @ptrCast(spec.ptr);
}
fn builder(comptime spec: [:0]const u8) *B {
    return db.g_variant_builder_new(vt(spec));
}
fn end(b: *B) *V {
    const v = db.g_variant_builder_end(b);
    db.g_variant_builder_unref(b);
    return v;
}
fn string(s: [*:0]const u8) *V {
    return db.g_variant_new_string(s);
}
fn boolean(b: bool) *V {
    return db.g_variant_new_boolean(if (b) 1 else 0);
}
fn empty(comptime child_type: [:0]const u8) *V {
    return db.g_variant_new_array(vt(child_type), null, 0);
}
fn tuple(values: []const *V) *V {
    return db.g_variant_new_tuple(values.ptr, values.len);
}
fn dict(b: *B, key: [*:0]const u8, value: *V) void {
    db.g_variant_builder_add_value(b, db.g_variant_new_dict_entry(string(key), db.g_variant_new_variant(value)));
}
fn childInt(v: *V, idx: usize) i32 {
    const child = db.g_variant_get_child_value(v, idx);
    defer db.g_variant_unref(child);
    return db.g_variant_get_int32(child);
}

test "Tray type compiles" {
    _ = Tray;
    _ = sni_vtable;
    _ = menu_vtable;
}
test "menu item ids stay distinct" {
    for (items, 0..) |a, i| {
        try std.testing.expect(a.id != 0);
        for (items[i + 1 ..]) |b| try std.testing.expect(a.id != b.id);
    }
}
test "terminal tray exposes settings, login, show/hide and quit only" {
    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqualStrings("Launch at Login", items[3].label);
    try std.testing.expect(std.mem.indexOf(u8, sni_xml, "name=\"ItemIsMenu\" type=\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu_xml, "type=\"a(isvu)\"") != null);
    for (items) |item| try std.testing.expect(std.mem.indexOf(u8, item.label, "MCP") == null);
}
