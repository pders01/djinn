const std = @import("std");
const objc = @import("objc");

/// Wraps SMAppService.mainAppService — registers the running bundle as
/// a Login Item so macOS launches djinn at login. Requires djinn to be
/// running from a signed `.app` bundle (ad-hoc sign is enough); the
/// SMAppService API rejects bare-binary callers with kSMErrorInvalidSignature.
///
/// Surfaced via the CLI:
///   djinn --login-item-enable   register
///   djinn --login-item-disable  unregister
///   djinn --login-item-status   print status
pub const Status = enum {
    not_registered,
    enabled,
    requires_approval,
    not_found,
    unknown,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .not_registered => "not registered",
            .enabled => "enabled (will launch at login)",
            .requires_approval => "registered, awaiting user approval in System Settings",
            .not_found => "not found",
            .unknown => "unknown",
        };
    }
};

pub const Error = error{
    SmAppServiceUnavailable,
    NotABundle,
    OperationFailed,
    PolicyConflict,
};

// Central startup/reload code publishes the accepted config before syncing.
// Absent policy leaves OS registration alone; actions never write config.
var configured_policy: ?bool = null;

pub fn setPolicy(value: ?bool) void {
    configured_policy = value;
}

pub fn policy() ?bool {
    return configured_policy;
}

pub fn checkRequest(enabled: bool) Error!void {
    if (configured_policy) |required| {
        if (enabled != required) return Error.PolicyConflict;
    }
}

pub fn policyConflict(actual: Status) bool {
    const required = configured_policy orelse return false;
    return if (required) actual != .enabled else (actual != .not_registered and actual != .not_found);
}

/// Startup/reload reconciliation only. Never changes OS state when absent.
/// Pending approval is not retried: it requires the user's System Settings action.
pub fn syncPolicy() !void {
    const required = configured_policy orelse return;
    const actual = try status();
    if (required) {
        if (actual != .enabled and actual != .requires_approval) try register();
    } else if (actual != .not_registered and actual != .not_found) {
        try unregister();
    }
}

fn mainService() !objc.Object {
    const cls = objc.getClass("SMAppService") orelse return Error.SmAppServiceUnavailable;
    const svc = cls.msgSend(objc.Object, "mainAppService", .{});
    if (svc.value == null) return Error.SmAppServiceUnavailable;
    return svc;
}

/// Register the running bundle for launch-at-login. User approval can
/// still be required even if the call succeeds —
/// check via `status()` afterwards.
pub fn register() !void {
    try checkRequest(true);
    const svc = try mainService();
    const ok: bool = svc.msgSend(bool, "registerAndReturnError:", .{@as(?*anyopaque, null)});
    if (!ok) return Error.OperationFailed;
}

pub fn unregister() !void {
    try checkRequest(false);
    const svc = try mainService();
    const ok: bool = svc.msgSend(bool, "unregisterAndReturnError:", .{@as(?*anyopaque, null)});
    if (!ok) return Error.OperationFailed;
}

pub fn status() !Status {
    const svc = try mainService();
    // SMAppServiceStatus is NSInteger (= isize on 64-bit darwin).
    const raw: isize = svc.msgSend(isize, "status", .{});
    return switch (raw) {
        0 => .not_registered,
        1 => .enabled,
        2 => .requires_approval,
        3 => .not_found,
        else => .unknown,
    };
}

test "login policy checks never invoke SMAppService" {
    defer setPolicy(null);
    setPolicy(null);
    try checkRequest(true);
    try checkRequest(false);
    try std.testing.expect(!policyConflict(.unknown));
    setPolicy(true);
    try checkRequest(true);
    try std.testing.expectError(Error.PolicyConflict, checkRequest(false));
    try std.testing.expect(!policyConflict(.enabled));
    try std.testing.expect(policyConflict(.requires_approval));
    try std.testing.expect(policyConflict(.unknown));
    setPolicy(false);
    try checkRequest(false);
    try std.testing.expectError(Error.PolicyConflict, checkRequest(true));
    try std.testing.expect(!policyConflict(.not_registered));
    try std.testing.expect(policyConflict(.enabled));
}

/// Open System Settings → Login Items pane when approval is required.
pub fn openSystemSettings() void {
    const cls = objc.getClass("SMAppService") orelse return;
    cls.msgSend(void, "openSystemSettingsLoginItems", .{});
}
