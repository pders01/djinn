const std = @import("std");

const cg = @import("darwin-c");
const platform = @import("../io/platform.zig");

// Parser/local keymap masks stay in CG/NSEvent form. Only the global
// registration boundary translates them to Carbon's different bit layout.
fn carbonModifiers(modifiers: u32) !u32 {
    const supported: u32 = cg.kCGEventFlagMaskControl | cg.kCGEventFlagMaskCommand |
        cg.kCGEventFlagMaskAlternate | cg.kCGEventFlagMaskShift;
    if ((modifiers & ~supported) != 0) return error.UnsupportedModifierBits;
    var result: u32 = 0;
    const pairs = .{
        .{ cg.kCGEventFlagMaskControl, cg.controlKey },
        .{ cg.kCGEventFlagMaskCommand, cg.cmdKey },
        .{ cg.kCGEventFlagMaskAlternate, cg.optionKey },
        .{ cg.kCGEventFlagMaskShift, cg.shiftKey },
    };
    inline for (pairs) |pair| {
        if ((modifiers & @as(u32, @intCast(pair[0]))) != 0)
            result |= @as(u32, @intCast(pair[1]));
    }
    return result;
}

const signature: u32 = 0x446a696e; // 'Djin'
var next_registration_id: u32 = 1;

fn takeRegistrationID(counter: *u32) !u32 {
    if (counter.* == 0) return error.RegistrationIDExhausted;
    const id = counter.*;
    counter.* +%= 1; // Never recycle identities for potentially queued events.
    return id;
}

// The handler's userdata must survive moving the returned Hotkey value.
const Context = struct {
    callback: *const fn () void,
    id: u32,
};

fn dispatch(context: *Context, event_class: u32, event_kind: u32, id: cg.EventHotKeyID) cg.OSStatus {
    if (event_class != cg.kEventClassKeyboard or event_kind != cg.kEventHotKeyPressed or
        id.signature != signature or context.id == 0 or id.id != context.id)
        return cg.eventNotHandledErr;
    context.callback();
    return cg.noErr;
}

fn eventHandler(_: cg.EventHandlerCallRef, event: cg.EventRef, userdata: ?*anyopaque) callconv(.c) cg.OSStatus {
    const context: *Context = @ptrCast(@alignCast(userdata orelse return cg.eventNotHandledErr));
    if (event == null) return cg.eventNotHandledErr;
    var id: cg.EventHotKeyID = undefined;
    const status = cg.GetEventParameter(
        event,
        cg.kEventParamDirectObject,
        cg.typeEventHotKeyID,
        null,
        @sizeOf(cg.EventHotKeyID),
        null,
        &id,
    );
    if (status != cg.noErr) return status;
    return dispatch(context, cg.GetEventClass(event), cg.GetEventKind(event), id);
}

const Native = struct {
    fn install(context: *Context, out: *cg.EventHandlerRef) cg.OSStatus {
        const spec = cg.EventTypeSpec{
            .eventClass = cg.kEventClassKeyboard,
            .eventKind = cg.kEventHotKeyPressed,
        };
        // The dispatcher target also works when AppKit, rather than
        // RunApplicationEventLoop, drives event delivery.
        return cg.InstallEventHandler(cg.GetEventDispatcherTarget(), &eventHandler, 1, &spec, context, out);
    }

    fn register(keycode: u16, modifiers: u32, id: u32, out: *cg.EventHotKeyRef) cg.OSStatus {
        return cg.RegisterEventHotKey(
            keycode,
            modifiers,
            .{ .signature = signature, .id = id },
            cg.GetEventDispatcherTarget(),
            cg.kEventHotKeyExclusive,
            out,
        );
    }

    fn unregister(ref: cg.EventHotKeyRef) cg.OSStatus {
        return cg.UnregisterEventHotKey(ref);
    }

    fn remove(handler: cg.EventHandlerRef) cg.OSStatus {
        return cg.RemoveEventHandler(handler);
    }
};

fn registrationError(status: cg.OSStatus) error{ HotkeyConflict, InvalidHotkey, RegistrationFailed } {
    return switch (status) {
        cg.eventHotKeyExistsErr => error.HotkeyConflict,
        cg.eventHotKeyInvalidErr, cg.paramErr => error.InvalidHotkey,
        else => error.RegistrationFailed,
    };
}

fn registerBinding(comptime Backend: type, keycode: u16, modifiers: u32, id: u32) !cg.EventHotKeyRef {
    var ref: cg.EventHotKeyRef = null;
    const status = Backend.register(keycode, modifiers, id, &ref);
    if (status != cg.noErr) {
        std.debug.print("hotkey: RegisterEventHotKey failed (OSStatus={d}, keycode={d}, carbon-modifiers=0x{x})\n", .{ status, keycode, modifiers });
        return registrationError(status);
    }
    return ref orelse error.RegistrationFailed;
}

pub const Hotkey = HotkeyType(Native);

// Compile-time backend substitution is only a unit-test seam; production
// always calls Carbon directly. No event tap, timer, or keyboard monitor.
fn HotkeyType(comptime Backend: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        context: *Context,
        handler: cg.EventHandlerRef,
        ref: cg.EventHotKeyRef,
        pending_cleanup: cg.EventHotKeyRef = null,
        keycode: u16,
        modifiers: u32,

        /// All registration, callbacks, and teardown occur on the main thread.
        pub fn init(allocator: std.mem.Allocator, keycode: u16, modifiers: u32, callback: *const fn () void) !Self {
            const carbon_modifiers = try carbonModifiers(modifiers);
            const context = try allocator.create(Context);
            var destroy_context_on_error = true;
            errdefer if (destroy_context_on_error) allocator.destroy(context);
            context.* = .{ .callback = callback, .id = try takeRegistrationID(&next_registration_id) };

            var handler: cg.EventHandlerRef = null;
            const status = Backend.install(context, &handler);
            if (status != cg.noErr or handler == null) {
                std.debug.print("hotkey: InstallEventHandler failed (OSStatus={d})\n", .{status});
                return error.HandlerInstallFailed;
            }
            errdefer {
                context.id = 0;
                const cleanup_status = Backend.remove(handler);
                if (cleanup_status != cg.noErr) {
                    // A native handler may still retain this pointer. Disable
                    // dispatch and retain the context rather than free it.
                    destroy_context_on_error = false;
                    std.debug.print("hotkey: handler rollback failed (OSStatus={d})\n", .{cleanup_status});
                }
            }
            const ref = try registerBinding(Backend, keycode, carbon_modifiers, context.id);
            return .{
                .allocator = allocator,
                .context = context,
                .handler = handler,
                .ref = ref,
                .keycode = keycode,
                .modifiers = modifiers,
            };
        }

        /// Keep the working shortcut if replacement registration fails.
        /// Old queued hotkey events cannot toggle the newly bound shortcut.
        pub fn setBinding(self: *Self, keycode: u16, modifiers: u32) !void {
            // Retain and retry any registration whose rollback failed, rather
            // than orphan an exclusive shortcut until process exit.
            if (self.pending_cleanup) |pending| {
                const cleanup_status = Backend.unregister(pending);
                if (cleanup_status != cg.noErr) {
                    std.debug.print("hotkey: pending replacement cleanup failed (OSStatus={d})\n", .{cleanup_status});
                    return error.CleanupPending;
                }
                self.pending_cleanup = null;
            }
            if (self.keycode == keycode and self.modifiers == modifiers) return;
            const carbon_modifiers = try carbonModifiers(modifiers);
            const id = try takeRegistrationID(&next_registration_id);
            const replacement = try registerBinding(Backend, keycode, carbon_modifiers, id);
            errdefer {
                const rollback = Backend.unregister(replacement);
                if (rollback != cg.noErr) {
                    self.pending_cleanup = replacement;
                    std.debug.print("hotkey: replacement rollback failed (OSStatus={d}); retained for cleanup\n", .{rollback});
                }
            }
            const status = Backend.unregister(self.ref);
            if (status != cg.noErr) {
                std.debug.print("hotkey: UnregisterEventHotKey failed (OSStatus={d}); keeping previous binding\n", .{status});
                return error.UnregisterFailed;
            }
            self.ref = replacement;
            self.keycode = keycode;
            self.modifiers = modifiers;
            self.context.id = id;
        }

        pub fn deinit(self: *Self) void {
            self.context.id = 0;
            if (self.pending_cleanup) |pending| {
                const cleanup_status = Backend.unregister(pending);
                if (cleanup_status != cg.noErr)
                    std.debug.print("hotkey: pending replacement cleanup failed during teardown (OSStatus={d})\n", .{cleanup_status});
            }
            const unregister_status = Backend.unregister(self.ref);
            if (unregister_status != cg.noErr)
                std.debug.print("hotkey: UnregisterEventHotKey failed during teardown (OSStatus={d})\n", .{unregister_status});
            const status = Backend.remove(self.handler);
            if (status == cg.noErr) {
                self.allocator.destroy(self.context);
            } else {
                // Don't free userdata still referenced by a native handler.
                std.debug.print("hotkey: RemoveEventHandler failed (OSStatus={d})\n", .{status});
            }
            self.* = undefined;
        }
    };
}

fn reportIdentity() void {
    var executable_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable = platform.executablePath(&executable_buf) catch "<unavailable>";
    std.debug.print("hotkey diagnostic: executable={s}\n", .{executable});
    if (cg.CFBundleGetMainBundle()) |bundle| {
        if (cg.CFBundleGetIdentifier(bundle)) |identifier| {
            var buffer: [256]u8 = undefined;
            if (cg.CFStringGetCString(identifier, &buffer, buffer.len, cg.kCFStringEncodingUTF8) != 0)
                std.debug.print("hotkey diagnostic: bundle-id={s}\n", .{std.mem.sliceTo(&buffer, 0)});
        }
    }
    std.debug.print("hotkey diagnostic: backend=RegisterEventHotKey secure-input={}\n", .{cg.IsSecureEventInputEnabled() != 0});
}

/// Register and immediately release the requested shortcut. No config,
// shell, login-item sync, permission request, or event loop is involved.
pub fn diagnose(allocator: std.mem.Allocator, keycode: u16, modifiers: u32) bool {
    reportIdentity();
    std.debug.print("hotkey diagnostic: keycode={d} cg-modifiers=0x{x} exclusive=true\n", .{ keycode, modifiers });
    var hotkey = Hotkey.init(allocator, keycode, modifiers, &diagnosticCallback) catch |err| {
        std.debug.print("hotkey diagnostic: native-registration=failed ({})\n", .{err});
        return false;
    };
    defer hotkey.deinit();
    std.debug.print("hotkey diagnostic: native-registration=registered (OSStatus=0)\n", .{});
    return true;
}

fn diagnosticCallback() void {}

/// Parse a keybinding string like "ctrl+space" into keycode + modifier mask.
pub fn parseKeybinding(binding: []const u8) !struct { keycode: u16, modifiers: u32 } {
    var modifiers: u32 = 0;
    var remaining = binding;

    while (std.mem.indexOf(u8, remaining, "+")) |plus_idx| {
        const part = remaining[0..plus_idx];
        if (std.mem.eql(u8, part, "ctrl")) {
            modifiers |= @intCast(cg.kCGEventFlagMaskControl);
        } else if (std.mem.eql(u8, part, "cmd") or std.mem.eql(u8, part, "super")) {
            modifiers |= @intCast(cg.kCGEventFlagMaskCommand);
        } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "opt")) {
            modifiers |= @intCast(cg.kCGEventFlagMaskAlternate);
        } else if (std.mem.eql(u8, part, "shift")) {
            modifiers |= @intCast(cg.kCGEventFlagMaskShift);
        } else {
            return error.UnknownModifier;
        }
        remaining = remaining[plus_idx + 1 ..];
    }

    // remaining is the key name
    const keycode = keycodeFromName(remaining) orelse return error.UnknownKey;
    return .{ .keycode = keycode, .modifiers = modifiers };
}

fn keycodeFromName(name: []const u8) ?u16 {
    // macOS virtual keycodes
    const map = .{
        .{ "space", 49 },
        .{ "return", 36 },
        .{ "tab", 48 },
        .{ "escape", 53 },
        .{ "grave", 50 }, // backtick/tilde key
        .{ "`", 50 },
        .{ "a", 0 },
        .{ "b", 11 },
        .{ "c", 8 },
        .{ "d", 2 },
        .{ "e", 14 },
        .{ "f", 3 },
        .{ "g", 5 },
        .{ "h", 4 },
        .{ "i", 34 },
        .{ "j", 38 },
        .{ "k", 40 },
        .{ "l", 37 },
        .{ "m", 46 },
        .{ "n", 45 },
        .{ "o", 31 },
        .{ "p", 35 },
        .{ "q", 12 },
        .{ "r", 15 },
        .{ "s", 1 },
        .{ "t", 17 },
        .{ "u", 32 },
        .{ "v", 9 },
        .{ "w", 13 },
        .{ "x", 7 },
        .{ "y", 16 },
        .{ "z", 6 },
        .{ "1", 18 },
        .{ "2", 19 },
        .{ "3", 20 },
        .{ "4", 21 },
        .{ "5", 23 },
        .{ "6", 22 },
        .{ "7", 26 },
        .{ "8", 28 },
        .{ "9", 25 },
        .{ "0", 29 },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// Tests for keybinding parsing (hot path — user config drives this)
test "parseKeybinding: ctrl+space" {
    const result = try parseKeybinding("ctrl+space");
    try std.testing.expectEqual(@as(u16, 49), result.keycode);
    try std.testing.expect(result.modifiers != 0); // ctrl flag set
}

test "parseKeybinding: ctrl+shift+space default" {
    const result = try parseKeybinding("ctrl+shift+space");
    try std.testing.expectEqual(@as(u16, 49), result.keycode);
    const expected: u32 = @intCast(cg.kCGEventFlagMaskControl | cg.kCGEventFlagMaskShift);
    try std.testing.expectEqual(expected, result.modifiers);
    try std.testing.expectEqual(@as(u32, cg.controlKey | cg.shiftKey), try carbonModifiers(result.modifiers));
}

test "parseKeybinding: ctrl+shift+s" {
    const result = try parseKeybinding("ctrl+shift+s");
    try std.testing.expectEqual(@as(u16, 1), result.keycode);
    const expected: u32 = @intCast(cg.kCGEventFlagMaskControl | cg.kCGEventFlagMaskShift);
    try std.testing.expectEqual(expected, result.modifiers);
}

test "parseKeybinding: cmd+shift+grave" {
    const result = try parseKeybinding("cmd+shift+grave");
    try std.testing.expectEqual(@as(u16, 50), result.keycode);
    // both cmd and shift flags should be set
    const cmd_flag: u32 = @intCast(cg.kCGEventFlagMaskCommand);
    const shift_flag: u32 = @intCast(cg.kCGEventFlagMaskShift);
    try std.testing.expect(result.modifiers & cmd_flag != 0);
    try std.testing.expect(result.modifiers & shift_flag != 0);
}

test "parseKeybinding: single key no modifier" {
    const result = try parseKeybinding("space");
    try std.testing.expectEqual(@as(u16, 49), result.keycode);
    try std.testing.expectEqual(@as(u32, 0), result.modifiers);
}

test "parseKeybinding: alt aliases" {
    const r1 = try parseKeybinding("alt+a");
    const r2 = try parseKeybinding("opt+a");
    try std.testing.expectEqual(r1.modifiers, r2.modifiers);
    try std.testing.expectEqual(r1.keycode, r2.keycode);
}

test "parseKeybinding: unknown key errors" {
    try std.testing.expectError(error.UnknownKey, parseKeybinding("ctrl+banana"));
}

test "parseKeybinding: unknown modifier errors" {
    try std.testing.expectError(error.UnknownModifier, parseKeybinding("hyper+space"));
}

test "keycodeFromName: all letters map to unique codes" {
    var seen: [128]bool = @splat(false);
    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (letters) |ch| {
        const code = keycodeFromName(&.{ch}) orelse unreachable;
        try std.testing.expect(!seen[code]);
        seen[code] = true;
    }
}

const FakeNative = struct {
    var install_status: cg.OSStatus = 0;
    var register_status: cg.OSStatus = 0;
    var remove_status: cg.OSStatus = 0;
    var last_context: ?*Context = null;
    var fail_unregister_ref: cg.EventHotKeyRef = null;
    var fail_unregister_ref2: cg.EventHotKeyRef = null;
    var install_calls: usize = 0;
    var register_calls: usize = 0;
    var remove_calls: usize = 0;
    var unregistered: [8]cg.EventHotKeyRef = undefined;
    var unregister_calls: usize = 0;
    var last_modifiers: u32 = 0;

    fn reset() void {
        install_status = 0;
        register_status = 0;
        remove_status = 0;
        last_context = null;
        fail_unregister_ref = null;
        fail_unregister_ref2 = null;
        install_calls = 0;
        register_calls = 0;
        remove_calls = 0;
        unregister_calls = 0;
        last_modifiers = 0;
    }

    fn install(context: *Context, out: *cg.EventHandlerRef) cg.OSStatus {
        install_calls += 1;
        if (install_status == 0) {
            out.* = @ptrFromInt(0x80);
            last_context = context;
        }
        return install_status;
    }

    fn register(_: u16, modifiers: u32, _: u32, out: *cg.EventHotKeyRef) cg.OSStatus {
        register_calls += 1;
        last_modifiers = modifiers;
        if (register_status == 0) out.* = @ptrFromInt(0x100 + register_calls * 16);
        return register_status;
    }

    fn unregister(ref: cg.EventHotKeyRef) cg.OSStatus {
        unregistered[unregister_calls] = ref;
        unregister_calls += 1;
        return if (ref == fail_unregister_ref or ref == fail_unregister_ref2) cg.paramErr else cg.noErr;
    }

    fn remove(_: cg.EventHandlerRef) cg.OSStatus {
        remove_calls += 1;
        if (remove_status == cg.noErr) last_context = null;
        return remove_status;
    }
};

const FakeHotkey = HotkeyType(FakeNative);

test "native hotkey: CG modifier masks convert only at registration boundary" {
    try std.testing.expectEqual(@as(u32, 0), try carbonModifiers(0));
    try std.testing.expectEqual(@as(u32, cg.controlKey), try carbonModifiers(cg.kCGEventFlagMaskControl));
    try std.testing.expectEqual(@as(u32, cg.cmdKey), try carbonModifiers(cg.kCGEventFlagMaskCommand));
    try std.testing.expectEqual(@as(u32, cg.optionKey), try carbonModifiers(cg.kCGEventFlagMaskAlternate));
    try std.testing.expectEqual(@as(u32, cg.shiftKey), try carbonModifiers(cg.kCGEventFlagMaskShift));
    const binding = try parseKeybinding("ctrl+shift+s");
    try std.testing.expectEqual(@as(u32, cg.controlKey | cg.shiftKey), try carbonModifiers(binding.modifiers));
    try std.testing.expectError(error.UnsupportedModifierBits, carbonModifiers(cg.kCGEventFlagMaskAlphaShift));
}

test "native hotkey: OSStatus maps conflicts and invalid bindings distinctly" {
    try std.testing.expectEqual(error.HotkeyConflict, registrationError(cg.eventHotKeyExistsErr));
    try std.testing.expectEqual(error.InvalidHotkey, registrationError(cg.eventHotKeyInvalidErr));
    try std.testing.expectEqual(error.InvalidHotkey, registrationError(cg.paramErr));
    try std.testing.expectEqual(error.RegistrationFailed, registrationError(-1));
}

test "native hotkey: failed allocation never installs a native handler" {
    FakeNative.reset();
    try std.testing.expectError(error.OutOfMemory, FakeHotkey.init(std.testing.failing_allocator, 1, 0, &diagnosticCallback));
    try std.testing.expectEqual(@as(usize, 0), FakeNative.install_calls);
}

test "native hotkey: failed handler installation frees context without registration" {
    FakeNative.reset();
    FakeNative.install_status = cg.paramErr;
    try std.testing.expectError(error.HandlerInstallFailed, FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback));
    try std.testing.expectEqual(@as(usize, 0), FakeNative.register_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeNative.remove_calls);
}

test "native hotkey: failed registration removes handler and frees context" {
    FakeNative.reset();
    FakeNative.register_status = cg.eventHotKeyExistsErr;
    try std.testing.expectError(error.HotkeyConflict, FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback));
    try std.testing.expectEqual(@as(usize, 1), FakeNative.remove_calls);
}

test "native hotkey: failed handler rollback retains disabled userdata instead of dangling pointer" {
    FakeNative.reset();
    FakeNative.register_status = cg.eventHotKeyExistsErr;
    FakeNative.remove_status = cg.paramErr;
    try std.testing.expectError(error.HotkeyConflict, FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback));
    const retained = FakeNative.last_context.?;
    defer std.testing.allocator.destroy(retained); // Simulate eventual native handler disposal.
    try std.testing.expectEqual(@as(u32, 0), retained.id);
    FakeNative.last_context = null;
}

test "native hotkey: unchanged binding does not reregister" {
    FakeNative.reset();
    var hotkey = try FakeHotkey.init(std.testing.allocator, 1, cg.kCGEventFlagMaskControl, &diagnosticCallback);
    defer hotkey.deinit();
    const id = hotkey.context.id;
    try hotkey.setBinding(1, cg.kCGEventFlagMaskControl);
    try std.testing.expectEqual(@as(usize, 1), FakeNative.register_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeNative.unregister_calls);
    try std.testing.expectEqual(id, hotkey.context.id);
    try std.testing.expectEqual(@as(u32, cg.controlKey), FakeNative.last_modifiers);
}

test "native hotkey: successful rebind replaces reference and event identity" {
    FakeNative.reset();
    var hotkey = try FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback);
    defer hotkey.deinit();
    const old_ref = hotkey.ref;
    const old_id = hotkey.context.id;
    try hotkey.setBinding(49, cg.kCGEventFlagMaskControl | cg.kCGEventFlagMaskShift);
    try std.testing.expect(hotkey.ref != old_ref);
    try std.testing.expect(hotkey.context.id != old_id);
    try std.testing.expectEqual(@as(u16, 49), hotkey.keycode);
    try std.testing.expectEqual(old_ref, FakeNative.unregistered[0]);
    try std.testing.expectEqual(@as(u32, cg.controlKey | cg.shiftKey), FakeNative.last_modifiers);
}

test "native hotkey: conflicting replacement preserves working binding" {
    FakeNative.reset();
    var hotkey = try FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback);
    defer hotkey.deinit();
    const old_ref = hotkey.ref;
    const old_id = hotkey.context.id;
    FakeNative.register_status = cg.eventHotKeyExistsErr;
    try std.testing.expectError(error.HotkeyConflict, hotkey.setBinding(49, cg.kCGEventFlagMaskControl));
    try std.testing.expectEqual(old_ref, hotkey.ref);
    try std.testing.expectEqual(old_id, hotkey.context.id);
    try std.testing.expectEqual(@as(u16, 1), hotkey.keycode);
    try std.testing.expectEqual(@as(usize, 0), FakeNative.unregister_calls);
}

test "native hotkey: failed old-key removal rolls back replacement" {
    FakeNative.reset();
    var hotkey = try FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback);
    defer hotkey.deinit();
    const old_ref = hotkey.ref;
    const old_id = hotkey.context.id;
    FakeNative.fail_unregister_ref = old_ref;
    try std.testing.expectError(error.UnregisterFailed, hotkey.setBinding(49, cg.kCGEventFlagMaskControl));
    try std.testing.expectEqual(old_ref, hotkey.ref);
    try std.testing.expectEqual(old_id, hotkey.context.id);
    try std.testing.expectEqual(@as(usize, 2), FakeNative.unregister_calls);
    try std.testing.expect(FakeNative.unregistered[1] != old_ref);
    FakeNative.fail_unregister_ref = null;
}

test "native hotkey: failed rollback retains ownership and retries cleanup before another rebind" {
    FakeNative.reset();
    var hotkey = try FakeHotkey.init(std.testing.allocator, 1, 0, &diagnosticCallback);
    defer hotkey.deinit();
    const old_ref = hotkey.ref;
    const old_id = hotkey.context.id;
    FakeNative.fail_unregister_ref = old_ref;
    FakeNative.fail_unregister_ref2 = @ptrFromInt(0x120); // Second registration.
    try std.testing.expectError(error.UnregisterFailed, hotkey.setBinding(49, cg.kCGEventFlagMaskControl));
    try std.testing.expectEqual(FakeNative.fail_unregister_ref2, hotkey.pending_cleanup);
    try std.testing.expectEqual(old_id, hotkey.context.id);
    try std.testing.expectError(error.CleanupPending, hotkey.setBinding(49, cg.kCGEventFlagMaskControl));
    try std.testing.expectEqual(@as(usize, 2), FakeNative.register_calls);
    FakeNative.fail_unregister_ref = null;
    FakeNative.fail_unregister_ref2 = null;
    try hotkey.setBinding(49, cg.kCGEventFlagMaskControl);
    try std.testing.expect(hotkey.pending_cleanup == null);
    try std.testing.expect(hotkey.ref != old_ref);
    try std.testing.expect(hotkey.context.id != old_id);
}

test "native hotkey: only matching pressed events dispatch and stale identities are ignored" {
    const Counter = struct {
        var count: usize = 0;
        fn invoke() void {
            count += 1;
        }
    };
    Counter.count = 0;
    var context = Context{ .callback = &Counter.invoke, .id = 42 };
    const valid = cg.EventHotKeyID{ .signature = signature, .id = 42 };
    try std.testing.expectEqual(cg.eventNotHandledErr, dispatch(&context, 0, cg.kEventHotKeyPressed, valid));
    try std.testing.expectEqual(cg.eventNotHandledErr, dispatch(&context, cg.kEventClassKeyboard, cg.kEventHotKeyReleased, valid));
    try std.testing.expectEqual(cg.eventNotHandledErr, dispatch(&context, cg.kEventClassKeyboard, cg.kEventHotKeyPressed, .{ .signature = 0, .id = 42 }));
    try std.testing.expectEqual(cg.eventNotHandledErr, dispatch(&context, cg.kEventClassKeyboard, cg.kEventHotKeyPressed, .{ .signature = signature, .id = 41 }));
    try std.testing.expectEqual(@as(usize, 0), Counter.count);
    try std.testing.expectEqual(cg.noErr, dispatch(&context, cg.kEventClassKeyboard, cg.kEventHotKeyPressed, valid));
    try std.testing.expectEqual(@as(usize, 1), Counter.count);
    context.id = 0;
    try std.testing.expectEqual(cg.eventNotHandledErr, dispatch(&context, cg.kEventClassKeyboard, cg.kEventHotKeyPressed, valid));
}

test "native hotkey: registration identity exhaustion never reuses an old id" {
    var counter: u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(std.math.maxInt(u32), try takeRegistrationID(&counter));
    try std.testing.expectError(error.RegistrationIDExhausted, takeRegistrationID(&counter));
}
