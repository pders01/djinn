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
};

fn mainService() !objc.Object {
    const cls = objc.getClass("SMAppService") orelse return Error.SmAppServiceUnavailable;
    const svc = cls.msgSend(objc.Object, "mainAppService", .{});
    if (svc.value == null) return Error.SmAppServiceUnavailable;
    return svc;
}

/// Register the running bundle for launch-at-login. Returns true if the
/// register call succeeded; user-approval state can still be required —
/// check via `status()` afterwards.
pub fn register() !void {
    const svc = try mainService();
    const ok: bool = svc.msgSend(bool, "registerAndReturnError:", .{@as(?*anyopaque, null)});
    if (!ok) return Error.OperationFailed;
}

pub fn unregister() !void {
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

/// Open System Settings → Login Items pane. Useful when the user
/// revokes consent and we want to point them back at the right place.
pub fn openSystemSettings() void {
    const cls = objc.getClass("SMAppService") orelse return;
    cls.msgSend(void, "openSystemSettingsLoginItems", .{});
}
