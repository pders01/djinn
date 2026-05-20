//! Portal-based global hotkey registration.
//!
//! Talks to `org.freedesktop.portal.GlobalShortcuts` over the session
//! bus so the panel's toggle binding works on every Wayland compositor
//! that ships a portal backend (KDE, Hyprland via
//! xdg-desktop-portal-hyprland, sway via xdg-desktop-portal-wlr, GNOME).
//! The compositor — not djinn — owns the keypress; the portal then
//! tells us via D-Bus when our shortcut fired. No CGEventTap analogue
//! is needed, and we don't have to be the focused window to hear about
//! the binding the way an X11 grab would require.
//!
//! Flow:
//!   1. `gdbus.g_bus_get_sync(G_BUS_TYPE_SESSION)` → GDBusConnection.
//!   2. Subscribe to the Activated signal upfront (it'll start firing
//!      once BindShortcuts lands).
//!   3. Subscribe to the Response signal on the predicted Request
//!      object path, then call `CreateSession` (async). The portal
//!      pre-creates the Request object before returning; subscribing
//!      first dodges a race where the Response fires before the
//!      subscription registers.
//!   4. Inside the CreateSession Response handler, pull `session_handle`
//!      out of the results dict and call `BindShortcuts`. On the very
//!      first launch KDE pops a confirmation dialog; subsequent launches
//!      reuse the user's choice as long as the .desktop app-id stays
//!      stable.
//!   5. Activated fires on every trigger from then on; we forward it to
//!      the caller's handler, which currently maps it to `panel.toggle()`.
//!
//! The IPC bridge (`ipc.zig`) is still useful as a scripted toggle and
//! as a fallback when the portal is unavailable, so we don't remove it.
//! `Hotkey.init` returning an error is non-fatal — the panel and the
//! IPC stay up; the user just won't have an auto-registered binding.
//!
//! Linkage: GDBus lives in gio-2.0. Listed explicitly in build.zig
//! even though gtk4's pkg-config Requires already pulls gio
//! transitively, because the linkage is load-bearing for this module
//! in particular.
//!
//! GVariant marshalling deliberately avoids variadic `g_variant_new`
//! and `g_variant_builder_add`. Those take printf-style format strings
//! that are easy to mis-type through Zig externs, and a mismatched
//! format string produces an immediate abort rather than a return
//! error. Each value is built explicitly via the typed `g_variant_new_*`
//! helpers and assembled with `g_variant_builder_add_value`.

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");
const gdbus = @import("gdbus.zig");

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
const G_DBUS_SIGNAL_FLAGS_NONE = gdbus.G_DBUS_SIGNAL_FLAGS_NONE;
const GAsyncReadyCallback = gdbus.GAsyncReadyCallback;

// ─── Type-string helpers ─────────────────────────────────────────────
//
// GVariantType is an opaque newtype layout-equivalent to a NUL-terminated
// type-string. The `G_VARIANT_TYPE()` macro in glib/gvariant.h literally
// casts a string to `(const GVariantType *)`. We do the same thing in
// Zig — no allocation, no per-call construction, just a pointer cast
// of a string literal.

inline fn vt(comptime spec: [:0]const u8) *const GVariantType {
    return @ptrCast(spec.ptr);
}

/// Per-call timeout for portal method invocations, in milliseconds.
/// 30 seconds is generous for a confirmation dialog the user has to
/// click (KDE prompts on first launch) but short enough that a stuck
/// xdg-desktop-portal daemon stops pegging the subscription until
/// process exit. -1 (infinite) was the prior shape and gave no
/// recovery path short of restart.
const PORTAL_CALL_TIMEOUT_MS: c_int = 30_000;

// ─── Public surface ──────────────────────────────────────────────────

/// Caller-supplied dispatch hook. Invoked on the GLib main thread when
/// the portal reports that the bound shortcut fired.
pub const Handler = struct {
    ctx: *anyopaque,
    on_activated: *const fn (ctx: *anyopaque) void,
};

/// Owns the portal-side session for the entire djinn process lifetime.
/// `init` kicks off async D-Bus traffic and returns immediately — the
/// shortcut isn't bound yet when this returns. The handler starts
/// receiving callbacks once BindShortcuts succeeds; on first launch
/// that follows a user-visible confirmation dialog on KDE.
pub const Hotkey = struct {
    ctx: *Context,

    pub fn init(
        allocator: std.mem.Allocator,
        handler: Handler,
        djinn_trigger: []const u8,
    ) !Hotkey {
        var err: ?*GError = null;
        const connection = gdbus.g_bus_get_sync(G_BUS_TYPE_SESSION, null, &err) orelse {
            const detail = if (err) |e| gerrorMessage(e) else "(no message)";
            reportSyncFailure("session bus unavailable: {s}", .{detail});
            if (err) |e| gdbus.g_error_free(e);
            return error.SessionBusUnavailable;
        };
        errdefer gdbus.g_object_unref(connection);

        const unique_name_z = gdbus.g_dbus_connection_get_unique_name(connection) orelse {
            reportSyncFailure("no D-Bus unique name on session bus", .{});
            return error.NoUniqueName;
        };
        const unique_name = std.mem.span(unique_name_z);

        const trigger = translateTrigger(allocator, djinn_trigger) catch |e| {
            reportSyncFailure("invalid trigger \"{s}\" ({})", .{ djinn_trigger, e });
            return error.InvalidTrigger;
        };
        errdefer allocator.free(trigger);

        const pid = std.os.linux.getpid();

        const session_handle_token = try std.fmt.allocPrintSentinel(
            allocator,
            "djinn_session_{d}",
            .{pid},
            0,
        );
        errdefer allocator.free(session_handle_token);

        const handle_token_create = try std.fmt.allocPrintSentinel(
            allocator,
            "djinn_create_{d}",
            .{pid},
            0,
        );
        errdefer allocator.free(handle_token_create);

        const handle_token_bind = try std.fmt.allocPrintSentinel(
            allocator,
            "djinn_bind_{d}",
            .{pid},
            0,
        );
        errdefer allocator.free(handle_token_bind);

        const create_request_path = try computeRequestPath(
            allocator,
            unique_name,
            handle_token_create,
        );
        errdefer allocator.free(create_request_path);

        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .allocator = allocator,
            .connection = connection,
            .handler = handler,
            .trigger = trigger,
            .session_handle_token = session_handle_token,
            .handle_token_create = handle_token_create,
            .handle_token_bind = handle_token_bind,
            .create_request_path = create_request_path,
            .bind_request_path = null,
            .session_handle = null,
            .activated_sub_id = 0,
            .create_response_sub_id = 0,
            .bind_response_sub_id = 0,
            .outcome_reported = false,
        };

        // Activated catches every shortcut firing for the lifetime of
        // the connection. We registered just one id ("toggle"), so we
        // don't need to dispatch on the signal's `shortcut_id` arg.
        ctx.activated_sub_id = gdbus.g_dbus_connection_signal_subscribe(
            connection,
            "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            "Activated",
            null,
            null,
            0,
            &onActivated,
            ctx,
            null,
        );

        // Subscribe before we call. The portal pre-creates the Request
        // object so its Response signal CAN fire as soon as the method
        // dispatches; the predicted path computation matches the portal's
        // own scheme: /org/freedesktop/portal/desktop/request/<sender>/<token>
        // where <sender> is the unique bus name with leading `:` stripped
        // and `.` replaced by `_`.
        ctx.create_response_sub_id = gdbus.g_dbus_connection_signal_subscribe(
            connection,
            "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.Request",
            "Response",
            create_request_path.ptr,
            null,
            0,
            &onCreateSessionResponse,
            ctx,
            null,
        );

        const create_params = buildCreateSessionParams(
            handle_token_create,
            session_handle_token,
        );
        gdbus.g_dbus_connection_call(
            connection,
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            "CreateSession",
            create_params,
            vt("(o)"),
            0,
            PORTAL_CALL_TIMEOUT_MS,
            null,
            &onCreateSessionReply,
            ctx,
        );

        std.debug.print(
            "hotkey: portal session requested (trigger=\"{s}\")\n",
            .{trigger},
        );

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Hotkey) void {
        const ctx = self.ctx;
        // Order matters: unsubscribe signals first so no callback can
        // observe a half-freed context if a queued event sneaks through
        // before we tear down the connection ref.
        if (ctx.activated_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.activated_sub_id);
        if (ctx.create_response_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.create_response_sub_id);
        if (ctx.bind_response_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.bind_response_sub_id);

        gdbus.g_object_unref(ctx.connection);

        if (ctx.session_handle) |h| ctx.allocator.free(h);
        if (ctx.bind_request_path) |p| ctx.allocator.free(p);
        ctx.allocator.free(ctx.create_request_path);
        ctx.allocator.free(ctx.handle_token_bind);
        ctx.allocator.free(ctx.handle_token_create);
        ctx.allocator.free(ctx.session_handle_token);
        ctx.allocator.free(ctx.trigger);
        ctx.allocator.destroy(ctx);
    }
};

// ─── Async chain context ─────────────────────────────────────────────

const Context = struct {
    allocator: std.mem.Allocator,
    connection: *GDBusConnection,
    handler: Handler,
    /// Portal-format trigger string ("CTRL+space"). Owned.
    trigger: [:0]u8,
    /// Caller-chosen tokens. Portal echoes them into request/session
    /// path computation so we can predict the Request object paths.
    session_handle_token: [:0]u8,
    handle_token_create: [:0]u8,
    handle_token_bind: [:0]u8,
    /// Predicted request paths. The Response signal fires on these.
    create_request_path: [:0]u8,
    bind_request_path: ?[:0]u8,
    /// Portal-returned session_handle. Set when CreateSession's Response
    /// arrives. Used as the first arg to BindShortcuts.
    session_handle: ?[:0]u8,
    /// GDBus subscription ids. Zero means "not subscribed" (the typical
    /// state after a one-shot Response handler unsubscribes itself).
    activated_sub_id: c_uint,
    create_response_sub_id: c_uint,
    bind_response_sub_id: c_uint,
    /// Single-shot latch for the aggregate "portal active / portal
    /// unavailable" outcome log. The portal flow has several places it
    /// can succeed or fail (sync init, CreateSession reply, CreateSession
    /// Response status, BindShortcuts reply, BindShortcuts Response
    /// status). Without a latch, transient handlers fire multiple log
    /// lines for the same logical attempt; with it, the user sees one
    /// definitive outcome per `Hotkey.init` call.
    outcome_reported: bool,
};

// ─── Outcome reporters ───────────────────────────────────────────────
//
// Every terminal point in the portal handshake flows through one of
// these. The pre-Context sync failures (session-bus / unique-name /
// trigger parse) use `reportSyncFailure`; once Context exists, async
// callbacks use `reportSuccess` / `reportFailure` which dedupe against
// `ctx.outcome_reported`.

fn reportSuccess(ctx: *Context) void {
    if (ctx.outcome_reported) return;
    ctx.outcome_reported = true;
    std.debug.print(
        "hotkey: portal active — trigger \"{s}\"\n",
        .{ctx.trigger},
    );
}

fn reportFailure(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    if (ctx.outcome_reported) return;
    ctx.outcome_reported = true;
    std.debug.print("hotkey: portal unavailable — " ++ fmt ++ "\n", args);
}

fn reportSyncFailure(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("hotkey: portal unavailable — " ++ fmt ++ "\n", args);
}

fn gerrorMessage(e: *GError) []const u8 {
    return if (e.message) |m| std.mem.span(m) else "(no message)";
}

// ─── Signal / reply callbacks ────────────────────────────────────────

/// Method-reply callback for CreateSession. The reply carries the
/// canonical Request object path — we reconcile it against the locally-
/// predicted path so a KDE rename of the request segment doesn't leave
/// the Response signal firing on a path we're not subscribed to.
fn onCreateSessionReply(
    _: ?*anyopaque,
    res: *GAsyncResult,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    var err: ?*GError = null;
    const reply = gdbus.g_dbus_connection_call_finish(ctx.connection, res, &err);
    if (reply) |r| {
        defer gdbus.g_variant_unref(r);
        reconcileRequestPath(
            ctx,
            r,
            "CreateSession",
            &ctx.create_request_path,
            &ctx.create_response_sub_id,
            &onCreateSessionResponse,
        );
        return;
    }
    if (err) |e| {
        reportFailure(ctx, "CreateSession method failed: {s}", .{gerrorMessage(e)});
        gdbus.g_error_free(e);
        // No portal backend present (or GlobalShortcuts not implemented
        // in this compositor's portal). Drop the create-Response watch
        // so it doesn't leak — Activated stays subscribed harmlessly
        // (it'll never fire without a session) and gets cleaned up in
        // deinit.
        if (ctx.create_response_sub_id != 0) {
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.create_response_sub_id);
            ctx.create_response_sub_id = 0;
        }
    }
}

/// One-shot CreateSession Response handler. Extracts `session_handle`
/// from the results dict and kicks off BindShortcuts.
fn onCreateSessionResponse(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    parameters: *GVariant,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));

    // Response signal signature: (u status, a{sv} results).
    const status_v = gdbus.g_variant_get_child_value(parameters, 0);
    defer gdbus.g_variant_unref(status_v);
    const status = gdbus.g_variant_get_uint32(status_v);

    // One-shot — unsubscribe before we do anything that could fail, so
    // we don't accidentally observe the same response twice if the
    // caller redrives.
    if (ctx.create_response_sub_id != 0) {
        gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.create_response_sub_id);
        ctx.create_response_sub_id = 0;
    }

    if (status != 0) {
        reportFailure(ctx, "CreateSession refused by portal (status {d})", .{status});
        return;
    }

    const results_v = gdbus.g_variant_get_child_value(parameters, 1);
    defer gdbus.g_variant_unref(results_v);

    const session_handle_v = gdbus.g_variant_lookup_value(results_v, "session_handle", vt("s")) orelse {
        reportFailure(ctx, "CreateSession response missing session_handle", .{});
        return;
    };
    defer gdbus.g_variant_unref(session_handle_v);

    const session_str = std.mem.span(gdbus.g_variant_get_string(session_handle_v, null));
    ctx.session_handle = ctx.allocator.dupeZ(u8, session_str) catch |e| {
        reportFailure(ctx, "dup session_handle failed: {}", .{e});
        return;
    };

    bindShortcut(ctx) catch |e| {
        reportFailure(ctx, "BindShortcuts dispatch failed: {}", .{e});
    };
}

/// Method-reply callback for BindShortcuts. Same canonical-path
/// reconciliation as CreateSession — the success/failure detail comes
/// via the Response signal on the (possibly relabeled) Request path.
fn onBindShortcutsReply(
    _: ?*anyopaque,
    res: *GAsyncResult,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    var err: ?*GError = null;
    const reply = gdbus.g_dbus_connection_call_finish(ctx.connection, res, &err);
    if (reply) |r| {
        defer gdbus.g_variant_unref(r);
        if (ctx.bind_request_path) |*bind_path| {
            reconcileRequestPath(
                ctx,
                r,
                "BindShortcuts",
                bind_path,
                &ctx.bind_response_sub_id,
                &onBindShortcutsResponse,
            );
        }
        return;
    }
    if (err) |e| {
        reportFailure(ctx, "BindShortcuts method failed: {s}", .{gerrorMessage(e)});
        gdbus.g_error_free(e);
    }
}

/// Parse the canonical Request `(o)` path out of a portal method reply
/// and swap the Response subscription onto it when it differs from the
/// path we predicted locally. xdg-desktop-portal documents the path
/// scheme but KDE has historically renamed segments — the predicted
/// path is a fallback, the canonical path from the reply is authoritative.
/// The Request body executes after the method reply, so the Response
/// signal hasn't fired yet by the time we get here — there's no race
/// between unsubscribing the old path and subscribing the canonical one.
fn reconcileRequestPath(
    ctx: *Context,
    reply: *GVariant,
    label: []const u8,
    path_slot: *[:0]u8,
    sub_id_slot: *c_uint,
    callback: gdbus.GDBusSignalCallback,
) void {
    const path_v = gdbus.g_variant_get_child_value(reply, 0);
    defer gdbus.g_variant_unref(path_v);
    const canonical_z = gdbus.g_variant_get_string(path_v, null);
    const canonical = std.mem.span(canonical_z);

    if (std.mem.eql(u8, canonical, path_slot.*)) return;

    std.debug.print(
        "hotkey: {s} request path renamed by portal — predicted \"{s}\", canonical \"{s}\"; re-subscribing\n",
        .{ label, path_slot.*, canonical },
    );

    if (sub_id_slot.* != 0) {
        gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, sub_id_slot.*);
        sub_id_slot.* = 0;
    }

    const owned = ctx.allocator.dupeZ(u8, canonical) catch |e| {
        std.debug.print("hotkey: failed to dup canonical {s} path: {} — Response signal will be missed\n", .{ label, e });
        return;
    };
    ctx.allocator.free(path_slot.*);
    path_slot.* = owned;

    sub_id_slot.* = gdbus.g_dbus_connection_signal_subscribe(
        ctx.connection,
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        path_slot.*.ptr,
        null,
        0,
        callback,
        ctx,
        null,
    );
}

/// One-shot BindShortcuts Response handler. Logs success; future
/// Activated signals are already wired.
fn onBindShortcutsResponse(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    parameters: *GVariant,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));

    if (ctx.bind_response_sub_id != 0) {
        gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.bind_response_sub_id);
        ctx.bind_response_sub_id = 0;
    }

    const status_v = gdbus.g_variant_get_child_value(parameters, 0);
    defer gdbus.g_variant_unref(status_v);
    const status = gdbus.g_variant_get_uint32(status_v);

    if (status == 0) {
        reportSuccess(ctx);
    } else {
        reportFailure(
            ctx,
            "BindShortcuts refused (status {d}) — user may have declined or trigger unavailable",
            .{status},
        );
    }
}

/// Activated signal handler. Single shortcut id, so we don't bother
/// extracting `shortcut_id` from the parameters tuple.
fn onActivated(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: *GVariant,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    ctx.handler.on_activated(ctx.handler.ctx);
}

// ─── BindShortcuts driver ────────────────────────────────────────────

fn bindShortcut(ctx: *Context) !void {
    const unique_name_z = gdbus.g_dbus_connection_get_unique_name(ctx.connection) orelse
        return error.NoUniqueName;
    const unique_name = std.mem.span(unique_name_z);
    const bind_request_path = try computeRequestPath(
        ctx.allocator,
        unique_name,
        ctx.handle_token_bind,
    );
    ctx.bind_request_path = bind_request_path;

    ctx.bind_response_sub_id = gdbus.g_dbus_connection_signal_subscribe(
        ctx.connection,
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        bind_request_path.ptr,
        null,
        0,
        &onBindShortcutsResponse,
        ctx,
        null,
    );

    const session_handle = ctx.session_handle orelse return error.NoSessionHandle;
    const params = buildBindShortcutsParams(
        session_handle,
        ctx.trigger,
        ctx.handle_token_bind,
    );

    gdbus.g_dbus_connection_call(
        ctx.connection,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.GlobalShortcuts",
        "BindShortcuts",
        params,
        vt("(o)"),
        0,
        PORTAL_CALL_TIMEOUT_MS,
        null,
        &onBindShortcutsReply,
        ctx,
    );
}

// ─── GVariant construction helpers ───────────────────────────────────

/// Append a `{sv}` dict entry. Both key and value are string-shaped;
/// the value gets the mandatory variant wrapper. The builder must have
/// element type `a{sv}` (i.e. VARDICT).
fn addStringDictEntry(
    builder: *GVariantBuilder,
    key: [*:0]const u8,
    value: [*:0]const u8,
) void {
    const wrapped = gdbus.g_variant_new_variant(gdbus.g_variant_new_string(value));
    const entry = gdbus.g_variant_new_dict_entry(gdbus.g_variant_new_string(key), wrapped);
    gdbus.g_variant_builder_add_value(builder, entry);
}

fn buildCreateSessionParams(
    handle_token: [:0]u8,
    session_handle_token: [:0]u8,
) *GVariant {
    const opts = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(opts, "handle_token", handle_token.ptr);
    addStringDictEntry(opts, "session_handle_token", session_handle_token.ptr);
    const opts_v = gdbus.g_variant_builder_end(opts);
    gdbus.g_variant_builder_unref(opts);

    const tuple = gdbus.g_variant_builder_new(vt("(a{sv})"));
    gdbus.g_variant_builder_add_value(tuple, opts_v);
    const params = gdbus.g_variant_builder_end(tuple);
    gdbus.g_variant_builder_unref(tuple);
    return params;
}

fn buildBindShortcutsParams(
    session_handle: [:0]u8,
    trigger: [:0]u8,
    handle_token: [:0]u8,
) *GVariant {
    // Properties dict for the single shortcut entry: description +
    // preferred trigger. The user sees "description" if their compositor
    // shows a shortcuts-editor UI (KDE does); preferred_trigger is the
    // initial suggestion, the user can still rebind.
    const props = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(props, "description", "Toggle djinn panel");
    addStringDictEntry(props, "preferred_trigger", trigger.ptr);
    const props_v = gdbus.g_variant_builder_end(props);
    gdbus.g_variant_builder_unref(props);

    // Shortcut tuple: (id, properties).
    const shortcut = gdbus.g_variant_builder_new(vt("(sa{sv})"));
    gdbus.g_variant_builder_add_value(shortcut, gdbus.g_variant_new_string("toggle"));
    gdbus.g_variant_builder_add_value(shortcut, props_v);
    const shortcut_v = gdbus.g_variant_builder_end(shortcut);
    gdbus.g_variant_builder_unref(shortcut);

    // Array of shortcut tuples — only one for now. The portal handles
    // larger arrays the same way; we'd grow this once a second binding
    // (e.g. quit, find) lands.
    const shortcuts = gdbus.g_variant_builder_new(vt("a(sa{sv})"));
    gdbus.g_variant_builder_add_value(shortcuts, shortcut_v);
    const shortcuts_v = gdbus.g_variant_builder_end(shortcuts);
    gdbus.g_variant_builder_unref(shortcuts);

    // Options dict — just the handle_token so we can correlate the
    // Response signal.
    const opts = gdbus.g_variant_builder_new(vt("a{sv}"));
    addStringDictEntry(opts, "handle_token", handle_token.ptr);
    const opts_v = gdbus.g_variant_builder_end(opts);
    gdbus.g_variant_builder_unref(opts);

    // BindShortcuts signature: (o session, a(sa{sv}) shortcuts, s parent_window, a{sv} options).
    // parent_window is empty: we don't have a GtkWindow exported handle
    // and the portal's confirmation dialog falls back to a free-floating
    // window when this is "".
    const tuple = gdbus.g_variant_builder_new(vt("(oa(sa{sv})sa{sv})"));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_object_path(session_handle.ptr));
    gdbus.g_variant_builder_add_value(tuple, shortcuts_v);
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string(""));
    gdbus.g_variant_builder_add_value(tuple, opts_v);
    const params = gdbus.g_variant_builder_end(tuple);
    gdbus.g_variant_builder_unref(tuple);
    return params;
}

// ─── Path + trigger derivation ───────────────────────────────────────

/// Replicate the portal's Request-path scheme:
///   /org/freedesktop/portal/desktop/request/<sender>/<handle_token>
/// where `<sender>` is the unique bus name with the leading `:` stripped
/// and every `.` rewritten to `_`. Documented under "The Request object"
/// in the portal spec.
fn computeRequestPath(
    allocator: std.mem.Allocator,
    unique_name: []const u8,
    handle_token: []const u8,
) ![:0]u8 {
    const start: usize = if (unique_name.len > 0 and unique_name[0] == ':') 1 else 0;
    const trimmed = unique_name[start..];

    var underscored = try allocator.alloc(u8, trimmed.len);
    defer allocator.free(underscored);
    for (trimmed, 0..) |ch, i| {
        underscored[i] = if (ch == '.') '_' else ch;
    }

    return try std.fmt.allocPrintSentinel(
        allocator,
        "/org/freedesktop/portal/desktop/request/{s}/{s}",
        .{ underscored, handle_token },
        0,
    );
}

/// Translate djinn's config-format trigger ("ctrl+space", "alt+grave")
/// to the portal's preferred_trigger format. Per the XDG Shortcuts
/// spec, modifiers are uppercase names joined with `+`, key is the
/// lower-case keysym name. We map djinn's macOS-leaning aliases
/// (cmd / opt) onto the linux-side equivalents (LOGO / ALT) so the
/// same config works cross-platform.
fn translateTrigger(allocator: std.mem.Allocator, djinn_trigger: []const u8) ![:0]u8 {
    var token_count: usize = 0;
    {
        var counter = std.mem.splitScalar(u8, djinn_trigger, '+');
        while (counter.next()) |piece| {
            const t = std.mem.trim(u8, piece, &std.ascii.whitespace);
            if (t.len == 0) return error.EmptyToken;
            token_count += 1;
        }
    }
    if (token_count == 0) return error.EmptyTrigger;

    var buf: [128]u8 = undefined;
    var len: usize = 0;

    var it = std.mem.splitScalar(u8, djinn_trigger, '+');
    var idx: usize = 0;
    while (it.next()) |raw| : (idx += 1) {
        const piece = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (idx > 0) {
            if (len >= buf.len) return error.TriggerTooLong;
            buf[len] = '+';
            len += 1;
        }

        const is_key = (idx == token_count - 1);
        if (is_key) {
            // Lowercase keysym names match GTK/XKB conventions ("space",
            // "grave", "f1"). Letters work either case but lowercase is
            // the convention.
            for (piece) |ch| {
                if (len >= buf.len) return error.TriggerTooLong;
                buf[len] = std.ascii.toLower(ch);
                len += 1;
            }
        } else {
            const mapped = mapModifier(piece);
            const writeable = if (mapped) |m| m else piece;
            if (len + writeable.len > buf.len) return error.TriggerTooLong;
            if (mapped) |m| {
                @memcpy(buf[len .. len + m.len], m);
                len += m.len;
            } else {
                // Unknown modifier — uppercase passthrough as a
                // best-effort. The portal will reject the bind if the
                // string is unparseable, and the user sees the failure
                // status in the log.
                for (piece) |ch| {
                    buf[len] = std.ascii.toUpper(ch);
                    len += 1;
                }
            }
        }
    }

    return try allocator.dupeZ(u8, buf[0..len]);
}

/// Case-insensitive modifier name → portal canonical form. Returns null
/// for anything we don't recognize; the caller passthroughs uppercased.
fn mapModifier(name: []const u8) ?[]const u8 {
    var lower_buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > lower_buf.len) return null;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..name.len];

    if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control")) return "CTRL";
    if (std.mem.eql(u8, lower, "shift")) return "SHIFT";
    if (std.mem.eql(u8, lower, "alt") or std.mem.eql(u8, lower, "opt") or std.mem.eql(u8, lower, "option")) return "ALT";
    if (std.mem.eql(u8, lower, "cmd") or std.mem.eql(u8, lower, "command") or std.mem.eql(u8, lower, "super") or std.mem.eql(u8, lower, "meta") or std.mem.eql(u8, lower, "logo") or std.mem.eql(u8, lower, "win")) return "LOGO";
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────

test "translateTrigger maps modifiers and lowercases key" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;

    const t1 = try translateTrigger(a, "ctrl+space");
    defer a.free(t1);
    try std.testing.expectEqualStrings("CTRL+space", t1);

    const t2 = try translateTrigger(a, "Alt+Grave");
    defer a.free(t2);
    try std.testing.expectEqualStrings("ALT+grave", t2);

    const t3 = try translateTrigger(a, "cmd+shift+a");
    defer a.free(t3);
    try std.testing.expectEqualStrings("LOGO+SHIFT+a", t3);

    // Single-key trigger (no modifier) — the key passes through as-is.
    const t4 = try translateTrigger(a, "F12");
    defer a.free(t4);
    try std.testing.expectEqualStrings("f12", t4);
}

test "translateTrigger rejects empty tokens" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyToken, translateTrigger(a, "ctrl++space"));
    try std.testing.expectError(error.EmptyToken, translateTrigger(a, "+space"));
    try std.testing.expectError(error.EmptyToken, translateTrigger(a, ""));
}

test "computeRequestPath strips colon and rewrites dots" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    const path = try computeRequestPath(a, ":1.234", "tok42");
    defer a.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_234/tok42",
        path,
    );
}

test "computeRequestPath tolerates a name without leading colon" {
    if (builtin.os.tag != .linux) return;
    const a = std.testing.allocator;
    const path = try computeRequestPath(a, "org.example.Foo", "x");
    defer a.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/org_example_Foo/x",
        path,
    );
}
