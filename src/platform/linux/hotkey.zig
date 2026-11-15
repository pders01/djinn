//! Portal-based global hotkey registration.
//!
//! Talks to `org.freedesktop.portal.GlobalShortcuts` over the session
//! bus when the desktop's portal backend implements GlobalShortcuts and
//! accepts the binding. An installed portal backend alone is insufficient:
//! interface support and approval vary by desktop/backend version.
//! The desktop/compositor — not Djinn — owns the keypress; the portal
//! tells us via D-Bus when our shortcut fired. Djinn need not be focused
//! and does not monitor raw keyboard input to implement this binding.
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
//!      out of the results dict and call `BindShortcuts`. The
//!      backend may request user confirmation. Remembered approval and
//!      app-identity matching are backend policy, not guaranteed by Djinn.
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
pub const Outcome = enum { bound, failed };

pub const Handler = struct {
    ctx: *anyopaque,
    on_activated: *const fn (ctx: *anyopaque) void,
    /// Single-shot, asynchronous; the attempt id identifies the source even
    /// when a reload supersedes an outstanding registration.
    on_registration: ?*const fn (ctx: *anyopaque, attempt: u64, outcome: Outcome) void = null,
};

// GLib-main-thread only. Never reuse an attempt within a process, even when
// an older portal session or Request is still live.
var next_attempt: u64 = 0;
var contexts: ?*Context = null;

fn allocateAttempt() !u64 {
    next_attempt = std.math.add(u64, next_attempt, 1) catch return error.AttemptsExhausted;
    return next_attempt;
}

const References = struct {
    count: usize = 1,

    fn retain(self: *References) void {
        std.debug.assert(self.count != 0);
        self.count += 1;
    }

    /// True only when the last owner/completion/frame releases its lease.
    fn release(self: *References) bool {
        std.debug.assert(self.count != 0);
        self.count -= 1;
        return self.count == 0;
    }
};

const TokenKind = enum { session, create, bind };

fn makeToken(allocator: std.mem.Allocator, kind: TokenKind, pid: u64, attempt: u64) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "djinn_{s}_{d}_{d}", .{ @tagName(kind), pid, attempt }, 0);
}

const Registration = struct {
    outcome: ?Outcome = null,
    retired: bool = false,

    fn finish(self: *Registration, outcome: Outcome) bool {
        if (self.retired or self.outcome != null) return false;
        self.outcome = outcome;
        return true;
    }
};

/// Owns one portal registration attempt/session; reloads may overlap.
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
        const attempt = try allocateAttempt();

        const session_handle_token = try makeToken(allocator, .session, @intCast(pid), attempt);
        errdefer allocator.free(session_handle_token);

        const handle_token_create = try makeToken(allocator, .create, @intCast(pid), attempt);
        errdefer allocator.free(handle_token_create);

        const handle_token_bind = try makeToken(allocator, .bind, @intCast(pid), attempt);
        errdefer allocator.free(handle_token_bind);

        const create_request_path = try computeRequestPath(
            allocator,
            unique_name,
            handle_token_create,
        );
        errdefer allocator.free(create_request_path);

        // Predict the session too, so cancellation before Create's Response
        // still closes a session the portal may already have created.
        const predicted_session = try computeObjectPath(allocator, "session", unique_name, session_handle_token);
        errdefer allocator.free(predicted_session);

        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .allocator = allocator,
            .connection = connection,
            .handler = handler,
            .trigger = trigger,
            .unique_name = unique_name,
            .session_handle_token = session_handle_token,
            .handle_token_create = handle_token_create,
            .handle_token_bind = handle_token_bind,
            .create_request_path = create_request_path,
            .bind_request_path = null,
            .session_handle = predicted_session,
            .activated_sub_id = 0,
            .create_response_sub_id = 0,
            .bind_response_sub_id = 0,
            .attempt = attempt,
            .cancellable = gdbus.g_cancellable_new(),
            .main_context = gtk.g_main_context_ref_thread_default(),
        };

        ctx.next = contexts;
        if (contexts) |head| head.previous = ctx;
        contexts = ctx;
        // Bound the whole handshake, not just the method acknowledgements:
        // the portal may acknowledge a request and never send its Response.
        const timeout = gtk.g_timeout_source_new(PORTAL_CALL_TIMEOUT_MS);
        ctx.timeout_source = timeout;
        gtk.g_source_set_callback(timeout, onTimeout, ctx.retain(), releaseData);
        _ = gtk.g_source_attach(timeout, ctx.main_context);

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
            ctx.retain(),
            @ptrCast(&releaseData),
        );
        errdefer if (ctx.activated_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.activated_sub_id);

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
            ctx.retain(),
            @ptrCast(&releaseData),
        );
        errdefer if (ctx.create_response_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.create_response_sub_id);

        const create_params = buildCreateSessionParams(
            handle_token_create,
            session_handle_token,
        );
        _ = ctx.retain();
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
            ctx.cancellable,
            &onCreateSessionReply,
            ctx,
        );

        std.debug.print(
            "hotkey: portal session requested (trigger=\"{s}\")\n",
            .{trigger},
        );

        return .{ .ctx = ctx };
    }

    pub fn attemptId(self: Hotkey) u64 {
        return self.ctx.attempt;
    }

    /// Called only by the entrypoint's final native teardown defer, after
    /// every callback producer/owner (including shortcut controllers) detached.
    /// No application handlers can run here. Keep allocator and IO alive.
    pub fn shutdown() void {
        while (contexts) |ctx| {
            std.debug.assert(ctx.registration.retired);
            // Hold the context across iteration: its last completion may free it.
            const main_context = ctx.main_context;
            _ = ctx.retain();
            _ = gtk.g_main_context_iteration(main_context, 1);
            ctx.release();
        }
    }

    /// GLib-main-thread only. Retirement NEVER pumps the shared main context.
    pub fn deinit(self: *Hotkey) void {
        const ctx = self.ctx;
        ctx.registration.retired = true;
        ctx.stopTimeout();
        // Order matters: unsubscribe signals first so no callback can
        // observe a half-freed context if a queued event sneaks through
        // before we tear down the connection ref.
        if (ctx.activated_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.activated_sub_id);
        if (ctx.create_response_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.create_response_sub_id);
        if (ctx.bind_response_sub_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.bind_response_sub_id);

        // The shared GLib session-bus cache can outlive this Hotkey.
        // Explicitly close our portal objects rather than relying on the
        // bus connection's final unref to release the registered binding.
        if (ctx.create_response_sub_id != 0)
            closePortalObject(ctx, ctx.create_request_path, "org.freedesktop.portal.Request");
        if (ctx.bind_response_sub_id != 0) {
            if (ctx.bind_request_path) |path|
                closePortalObject(ctx, path, "org.freedesktop.portal.Request");
        }
        if (ctx.session_handle) |path|
            closePortalObject(ctx, path, "org.freedesktop.portal.Session");
        ctx.activated_sub_id = 0;
        ctx.create_response_sub_id = 0;
        ctx.bind_response_sub_id = 0;
        gdbus.g_cancellable_cancel(ctx.cancellable);
        ctx.release(); // owner; subscriptions, calls and callback frames retain
        self.* = undefined;
    }
};

// ─── Async chain context ─────────────────────────────────────────────

const Context = struct {
    allocator: std.mem.Allocator,
    connection: *GDBusConnection,
    handler: Handler,
    /// Portal-format trigger string ("CTRL+space"). Owned.
    trigger: [:0]u8,
    /// Our session-bus unique name (e.g. `:1.42`). Cached at init time
    /// because `g_dbus_connection_get_unique_name` would otherwise be
    /// re-called from `bindShortcut` — the value is connection-stable
    /// for the connection's lifetime, so caching is safe. The backing
    /// string is owned by the connection (per glib docs); the slice
    /// stays valid until the final context release, strictly after every
    /// callback, signal destroy notify and method completion that reads it.
    unique_name: []const u8,
    /// Caller-chosen tokens. Portal echoes them into request/session
    /// path computation so we can predict the Request object paths.
    session_handle_token: [:0]u8,
    handle_token_create: [:0]u8,
    handle_token_bind: [:0]u8,
    /// Predicted request paths. The Response signal fires on these.
    create_request_path: [:0]u8,
    bind_request_path: ?[:0]u8,
    /// Predicted session path until CreateSession's Response replaces it
    /// with the canonical handle. Used as the first arg to BindShortcuts.
    session_handle: ?[:0]u8,
    /// GDBus subscription ids. Zero means "not subscribed" (the typical
    /// state after a one-shot Response handler unsubscribes itself).
    activated_sub_id: c_uint,
    create_response_sub_id: c_uint,
    bind_response_sub_id: c_uint,
    /// Single-shot outcome and retirement gate for both logging and handlers.
    registration: Registration = .{},
    attempt: u64,
    cancellable: *gdbus.GCancellable,
    main_context: *gtk.GMainContext,
    timeout_source: ?*gtk.GSource = null,
    references: References = .{}, // public owner
    next: ?*Context = null,
    previous: ?*Context = null,

    fn retain(self: *Context) *Context {
        self.references.retain();
        return self;
    }

    fn stopTimeout(self: *Context) void {
        if (self.timeout_source) |source| {
            self.timeout_source = null;
            gtk.g_source_destroy(source);
            gtk.g_source_unref(source);
        }
    }

    fn release(self: *Context) void {
        if (!self.references.release()) return;
        std.debug.assert(self.registration.retired);
        if (self.previous) |p| p.next = self.next else contexts = self.next;
        if (self.next) |n| n.previous = self.previous;
        gtk.g_main_context_unref(self.main_context);
        gdbus.g_object_unref(self.cancellable);
        gdbus.g_object_unref(self.connection);
        if (self.session_handle) |h| self.allocator.free(h);
        if (self.bind_request_path) |p| self.allocator.free(p);
        self.allocator.free(self.create_request_path);
        self.allocator.free(self.handle_token_bind);
        self.allocator.free(self.handle_token_create);
        self.allocator.free(self.session_handle_token);
        self.allocator.free(self.trigger);
        self.allocator.destroy(self);
    }
};

fn releaseData(data: gpointer) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return));
    ctx.release();
}

fn onTimeout(data: gpointer) callconv(.c) c_int {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return 0));
    _ = ctx.retain();
    defer ctx.release();
    if (ctx.timeout_source) |source| {
        ctx.timeout_source = null;
        gtk.g_source_unref(source); // main context owns it through dispatch
    }
    reportFailure(ctx, "registration timed out", .{});
    return 0;
}

fn closePortalObject(ctx: *Context, path: [:0]const u8, interface: [*:0]const u8) void {
    // Track even cleanup IO until call_finish: process IO/allocator must not
    // disappear while GDBus still owns a completion.
    gdbus.g_dbus_connection_call(ctx.connection, "org.freedesktop.portal.Desktop", path.ptr, interface, "Close", null, null, 0, PORTAL_CALL_TIMEOUT_MS, null, onCloseReply, ctx.retain());
}

// ─── Outcome reporters ───────────────────────────────────────────────
//
// Every terminal point in the portal handshake flows through one of
// these. The pre-Context sync failures (session-bus / unique-name /
// trigger parse) use `reportSyncFailure`; once Context exists, async
// callbacks use `reportSuccess` / `reportFailure` which dedupe against
// `ctx.registration`.

fn onCloseReply(_: ?*anyopaque, res: *GAsyncResult, data: gpointer) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(data orelse return));
    defer ctx.release();
    var err: ?*GError = null;
    if (gdbus.g_dbus_connection_call_finish(ctx.connection, res, &err)) |reply|
        gdbus.g_variant_unref(reply);
    if (err) |e| gdbus.g_error_free(e);
}

fn reportSuccess(ctx: *Context) void {
    if (!ctx.registration.finish(.bound)) return;
    ctx.stopTimeout();
    std.debug.print(
        "hotkey: portal active (attempt {d}) — trigger \"{s}\"\n",
        .{ ctx.attempt, ctx.trigger },
    );
    if (ctx.handler.on_registration) |callback| callback(ctx.handler.ctx, ctx.attempt, .bound);
}

fn reportFailure(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    if (!ctx.registration.finish(.failed)) return;
    ctx.stopTimeout();
    std.debug.print("hotkey: portal unavailable (attempt {d}) — " ++ fmt ++ "\n", .{ctx.attempt} ++ args);
    if (ctx.handler.on_registration) |callback| callback(ctx.handler.ctx, ctx.attempt, .failed);
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
    defer ctx.release();
    var err: ?*GError = null;
    const reply = gdbus.g_dbus_connection_call_finish(ctx.connection, res, &err);
    if (ctx.registration.retired or ctx.registration.outcome != null) {
        if (reply) |r| gdbus.g_variant_unref(r);
        if (err) |e| gdbus.g_error_free(e);
        return;
    }
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
        defer gdbus.g_error_free(e);
        reportFailure(ctx, "CreateSession method failed: {s}", .{gerrorMessage(e)});
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
    _ = ctx.retain(); // the handler may retire its owner and subscriptions
    defer ctx.release();
    if (ctx.registration.retired or ctx.registration.outcome != null or ctx.create_response_sub_id == 0) return;

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
    const owned_session = ctx.allocator.dupeSentinel(u8, session_str, 0) catch |e| {
        reportFailure(ctx, "dup session_handle failed: {}", .{e});
        return;
    };
    if (ctx.session_handle) |old| ctx.allocator.free(old);
    ctx.session_handle = owned_session;

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
    defer ctx.release();
    var err: ?*GError = null;
    const reply = gdbus.g_dbus_connection_call_finish(ctx.connection, res, &err);
    if (ctx.registration.retired or ctx.registration.outcome != null) {
        if (reply) |r| gdbus.g_variant_unref(r);
        if (err) |e| gdbus.g_error_free(e);
        return;
    }
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
    if (sub_id_slot.* == 0) return; // Response already consumed before ack
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

    const owned = ctx.allocator.dupeSentinel(u8, canonical, 0) catch |e| {
        reportFailure(ctx, "failed to dup canonical {s} path: {}", .{ label, e });
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
        ctx.retain(),
        @ptrCast(&releaseData),
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
    _ = ctx.retain();
    defer ctx.release();
    if (ctx.registration.retired or ctx.registration.outcome != null or ctx.bind_response_sub_id == 0) return;

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

/// The session bus connection is shared. Only dispatch our session's
/// "toggle" signal, never another application's or a stale session's.
fn onActivated(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    parameters: *GVariant,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return));
    _ = ctx.retain();
    defer ctx.release();
    if (ctx.registration.retired or ctx.registration.outcome != .bound) return;
    const session = ctx.session_handle orelse return;
    if (gdbus.g_variant_is_of_type(parameters, vt("(osta{sv})")) == 0) return;
    const session_v = gdbus.g_variant_get_child_value(parameters, 0);
    defer gdbus.g_variant_unref(session_v);
    const shortcut_v = gdbus.g_variant_get_child_value(parameters, 1);
    defer gdbus.g_variant_unref(shortcut_v);
    if (!std.mem.eql(u8, std.mem.span(gdbus.g_variant_get_string(session_v, null)), session)) return;
    if (!std.mem.eql(u8, std.mem.span(gdbus.g_variant_get_string(shortcut_v, null)), "toggle")) return;
    ctx.handler.on_activated(ctx.handler.ctx);
}

// ─── BindShortcuts driver ────────────────────────────────────────────

fn bindShortcut(ctx: *Context) !void {
    const bind_request_path = try computeRequestPath(
        ctx.allocator,
        ctx.unique_name,
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
        ctx.retain(),
        @ptrCast(&releaseData),
    );

    const session_handle = ctx.session_handle orelse return error.NoSessionHandle;
    const params = buildBindShortcutsParams(
        session_handle,
        ctx.trigger,
        ctx.handle_token_bind,
    );

    _ = ctx.retain();
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
        ctx.cancellable,
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
    return computeObjectPath(allocator, "request", unique_name, handle_token);
}

fn computeObjectPath(
    allocator: std.mem.Allocator,
    kind: []const u8,
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
        "/org/freedesktop/portal/desktop/{s}/{s}/{s}",
        .{ kind, underscored, handle_token },
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

    return try allocator.dupeSentinel(u8, buf[0..len], 0);
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

test "registration delivers only one outcome and nothing after retirement" {
    var success = Registration{};
    try std.testing.expect(success.finish(.bound));
    try std.testing.expect(!success.finish(.failed));
    var failure = Registration{};
    try std.testing.expect(failure.finish(.failed));
    try std.testing.expect(!failure.finish(.bound));
    var retired = Registration{ .retired = true };
    try std.testing.expect(!retired.finish(.bound));
    try std.testing.expect(!retired.finish(.failed));
}

test "callback frame keeps retired context alive after owner and subscriptions detach" {
    var refs = References{}; // owner
    refs.retain(); // async method completion
    refs.retain(); // signal subscription
    refs.retain(); // active callback frame
    var registration = Registration{};
    registration.retired = true; // handler deinitializes its own Hotkey
    try std.testing.expect(!refs.release()); // owner
    try std.testing.expect(!refs.release()); // subscription destroy notify
    try std.testing.expect(!refs.release()); // cancelled method completion
    try std.testing.expect(!registration.finish(.bound));
    try std.testing.expectEqual(@as(usize, 1), refs.count);
    try std.testing.expect(refs.release()); // only callback return can free
}

test "portal tokens differ for live attempts and request roles" {
    const a = std.testing.allocator;
    const first = try allocateAttempt();
    const second = try allocateAttempt();
    try std.testing.expect(second > first);
    var tokens: [6][:0]u8 = undefined;
    var used: usize = 0;
    defer for (tokens[0..used]) |token| a.free(token);
    for ([_]u64{ first, second }) |attempt| {
        for ([_]TokenKind{ .session, .create, .bind }) |kind| {
            const token = try makeToken(a, kind, 42, attempt);
            tokens[used] = token;
            for (tokens[0..used]) |previous| try std.testing.expect(!std.mem.eql(u8, previous, token));
            used += 1;
            for (token) |ch| try std.testing.expect(std.ascii.isAlphanumeric(ch) or ch == '_');
        }
    }
    const session = try computeObjectPath(a, "session", ":1.42", tokens[0]);
    defer a.free(session);
    try std.testing.expect(std.mem.startsWith(u8, session, "/org/freedesktop/portal/desktop/session/1_42/djinn_session_42_"));
}

test "Hotkey native API compiles without requesting a shortcut" {
    if (builtin.os.tag == .linux) std.testing.refAllDecls(Hotkey);
}

test "translateTrigger maps modifiers and lowercases key" {
    const a = std.testing.allocator;

    const t1 = try translateTrigger(a, "ctrl+shift+space");
    defer a.free(t1);
    try std.testing.expectEqualStrings("CTRL+SHIFT+space", t1);

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
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyToken, translateTrigger(a, "ctrl++space"));
    try std.testing.expectError(error.EmptyToken, translateTrigger(a, "+space"));
    try std.testing.expectError(error.EmptyToken, translateTrigger(a, ""));
}

test "computeRequestPath strips colon and rewrites dots" {
    const a = std.testing.allocator;
    const path = try computeRequestPath(a, ":1.234", "tok42");
    defer a.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_234/tok42",
        path,
    );
}

test "computeRequestPath tolerates a name without leading colon" {
    const a = std.testing.allocator;
    const path = try computeRequestPath(a, "org.example.Foo", "x");
    defer a.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/org_example_Foo/x",
        path,
    );
}
