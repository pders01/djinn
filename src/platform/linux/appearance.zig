//! Color-scheme listener (xdg-desktop-portal Settings).
//!
//! Subscribes to `org.freedesktop.portal.Settings.SettingChanged` so a
//! system-wide light/dark flip propagates without the user re-saving
//! their config or pressing Ctrl+Shift+T. Mirrors darwin's
//! `viewDidChangeEffectiveAppearance` → `theme_apply.reapply()` chain:
//! the portal is the analogue of NSAppearance.
//!
//! `ghostty_config.detectAppearance` already handles the variant
//! unwrap dance (KDE Plasma double-wraps `v<v<u>>`, others single-wrap
//! `v<u>`), so the listener doesn't decode the new value itself — it
//! only confirms that `key == "color-scheme"` and fans the change out
//! to the caller's handler, which re-runs the standard reload path.
//! The arg0 filter on `g_dbus_connection_signal_subscribe` is set to
//! the appearance namespace; the bus broker drops every other
//! namespace's SettingChanged before it reaches us.
//!
//! Lifetime: one GDBusConnection + one subscription id, both held for
//! djinn's lifetime. `deinit` unsubscribes before unreffing the
//! connection so a queued event can't dispatch into a half-freed
//! context (same ordering as `hotkey.zig` / `tray.zig`).
//!
//! Failure mode: `g_bus_get_sync` failing (no session bus — unusual
//! outside test rigs) returns an error. Caller logs and proceeds
//! without auto-switching; Ctrl+Shift+T + config saves remain
//! functional. Subscription itself is fire-and-forget — it returns 0
//! only if the connection is already closed, which the get_sync above
//! would have caught.

const std = @import("std");
const builtin = @import("builtin");
const gdbus = @import("gdbus.zig");

const GDBusConnection = gdbus.GDBusConnection;
const GVariant = gdbus.GVariant;
const GVariantType = gdbus.GVariantType;
const GError = gdbus.GError;
const gpointer = gdbus.gpointer;
const G_BUS_TYPE_SESSION = gdbus.G_BUS_TYPE_SESSION;
const G_DBUS_SIGNAL_FLAGS_NONE = gdbus.G_DBUS_SIGNAL_FLAGS_NONE;

/// GVariantType is internally a nul-terminated DBus signature string;
/// casting a static `[:0]const u8` avoids the `g_variant_type_new` /
/// `_free` dance for the one type check we do here. Mirrors the
/// `vt` helper in `ghostty_config.zig`.
inline fn vt(comptime spec: [:0]const u8) *const GVariantType {
    return @ptrCast(spec.ptr);
}

pub const Handler = struct {
    ctx: *anyopaque,
    /// Fires on the GLib main thread whenever the portal emits a
    /// `SettingChanged` for `org.freedesktop.appearance` / `color-scheme`.
    /// The new value is NOT passed in — callers should re-run
    /// `ghostty_config.detectAppearance()` to read the fresh value
    /// (it does the variant-unwrap and KDE-double-wrap dance for us).
    on_changed: *const fn (ctx: *anyopaque) void,
};

const Context = struct {
    connection: *GDBusConnection,
    subscription_id: c_uint,
    handler: Handler,
    allocator: std.mem.Allocator,
};

pub const Listener = struct {
    ctx: *Context,

    pub fn init(allocator: std.mem.Allocator, handler: Handler) !Listener {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        var err: ?*GError = null;
        const connection = gdbus.g_bus_get_sync(G_BUS_TYPE_SESSION, null, &err) orelse {
            if (err) |e| {
                const msg = if (e.message) |m| std.mem.span(m) else "(no message)";
                std.debug.print(
                    "appearance: session bus unavailable: {s} — auto theme switching disabled\n",
                    .{msg},
                );
                gdbus.g_error_free(e);
            }
            return error.SessionBusUnavailable;
        };
        errdefer gdbus.g_object_unref(connection);

        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .connection = connection,
            .subscription_id = 0,
            .handler = handler,
            .allocator = allocator,
        };

        // arg0 filter: the broker drops every SettingChanged whose
        // first string arg isn't the appearance namespace, so the
        // callback only sees signals we care about. Other namespaces
        // (org.gnome.desktop.interface, accent-color additions, …)
        // never wake us up.
        ctx.subscription_id = gdbus.g_dbus_connection_signal_subscribe(
            connection,
            "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.Settings",
            "SettingChanged",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.appearance",
            G_DBUS_SIGNAL_FLAGS_NONE,
            &onSettingChanged,
            @ptrCast(ctx),
            null,
        );
        if (ctx.subscription_id == 0) {
            std.debug.print(
                "appearance: signal_subscribe returned 0 — auto theme switching disabled\n",
                .{},
            );
            return error.SubscribeFailed;
        }

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Listener) void {
        const ctx = self.ctx;
        // Unsubscribe before unreffing the connection so a queued
        // event can't dispatch into a half-freed context. GLib
        // serializes signal dispatches on the main thread, so once
        // unsubscribe returns the callback can't fire again.
        if (ctx.subscription_id != 0)
            gdbus.g_dbus_connection_signal_unsubscribe(ctx.connection, ctx.subscription_id);
        gdbus.g_object_unref(ctx.connection);
        ctx.allocator.destroy(ctx);
    }
};

/// Spec: `SettingChanged(s namespace, s key, v value)`. The arg0
/// filter on subscribe already restricted us to the appearance
/// namespace, so the only remaining check is the `key` arg — the
/// portal may grow new keys under this namespace (accent-color
/// landed in 2024) and we only want color-scheme changes to retrigger
/// the theme reload.
fn onSettingChanged(
    _: *GDBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    parameters: *GVariant,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data));

    // Defensive: the signal is documented as `(ssv)` but a malformed
    // emitter could send the wrong shape. Bail rather than crash —
    // the user can still flip themes via Ctrl+Shift+T or a config
    // save. Once the tuple type matches, the second child is
    // guaranteed to be a string and the indexed access is safe.
    if (gdbus.g_variant_is_of_type(parameters, vt("(ssv)")) == 0) return;

    const key_variant = gdbus.g_variant_get_child_value(parameters, 1);
    defer gdbus.g_variant_unref(key_variant);

    const key_z = gdbus.g_variant_get_string(key_variant, null);
    const key = std.mem.span(key_z);
    if (!std.mem.eql(u8, key, "color-scheme")) return;

    ctx.handler.on_changed(ctx.handler.ctx);
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Appearance native API compiles without contacting the portal" {
    std.testing.refAllDecls(Listener);
}

test "Handler is callable with a stable ctx pointer" {
    // Smoke-only: the GDBus connection path needs a session bus and
    // belongs in integration testing, not the unit suite. This test
    // checks the Handler shape compiles + can be invoked through a
    // type-erased pointer — the same shape the portal callback uses.
    const S = struct {
        var fired: usize = 0;
        fn cb(_: *anyopaque) void {
            fired += 1;
        }
    };
    S.fired = 0;
    var sentinel: u8 = 0;
    const handler = Handler{ .ctx = @ptrCast(&sentinel), .on_changed = S.cb };
    handler.on_changed(handler.ctx);
    try std.testing.expectEqual(@as(usize, 1), S.fired);
}
