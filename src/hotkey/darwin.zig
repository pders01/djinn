const std = @import("std");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("Carbon/Carbon.h");
});

pub const Hotkey = struct {
    tap: cg.CFMachPortRef,
    source: cg.CFRunLoopSourceRef,

    // Stored globally so the C callback can access it
    var global_callback: ?*const fn () void = null;
    var target_keycode: u16 = 0;
    var target_modifiers: u32 = 0;
    /// Stored so kCGEventTapDisabledByTimeout can re-enable the tap.
    /// macOS disables event taps when a callback exceeds its time
    /// budget (or when the system is under load); without re-enable,
    /// the hotkey silently stops working until the next process
    /// restart. The pointer is set in init and read by eventTapCallback.
    var global_tap: cg.CFMachPortRef = null;

    pub fn init(keycode: u16, modifiers: u32, callback: *const fn () void) !Hotkey {
        global_callback = callback;
        target_keycode = keycode;
        target_modifiers = modifiers;

        const event_mask: u64 = (1 << cg.kCGEventKeyDown);

        const tap = cg.CGEventTapCreate(
            cg.kCGSessionEventTap,
            cg.kCGHeadInsertEventTap,
            cg.kCGEventTapOptionDefault,
            event_mask,
            &eventTapCallback,
            null,
        ) orelse return error.EventTapFailed;

        const source = cg.CFMachPortCreateRunLoopSource(
            cg.kCFAllocatorDefault,
            tap,
            0,
        ) orelse return error.RunLoopSourceFailed;

        cg.CFRunLoopAddSource(
            cg.CFRunLoopGetCurrent(),
            source,
            cg.kCFRunLoopCommonModes,
        );
        cg.CGEventTapEnable(tap, true);
        global_tap = tap;

        return .{
            .tap = tap,
            .source = source,
        };
    }

    fn eventTapCallback(
        _: cg.CGEventTapProxy,
        event_type: cg.CGEventType,
        event: cg.CGEventRef,
        _: ?*anyopaque,
    ) callconv(.c) cg.CGEventRef {
        // Re-enable tap if it was disabled by timeout. macOS does NOT
        // auto-re-enable; without this call the hotkey silently stops
        // working until the process restarts. The disable-by-user
        // type is also forwarded here when a tool toggles the tap
        // explicitly — same fix.
        if (event_type == cg.kCGEventTapDisabledByTimeout or
            event_type == cg.kCGEventTapDisabledByUserInput)
        {
            if (global_tap != null) cg.CGEventTapEnable(global_tap, true);
            return event;
        }

        if (event_type != cg.kCGEventKeyDown) return event;

        const keycode: u16 = @intCast(cg.CGEventGetIntegerValueField(event, cg.kCGKeyboardEventKeycode));
        const flags: u64 = @intCast(cg.CGEventGetFlags(event));

        // Mask to only modifier bits we care about (cmd, ctrl, alt, shift)
        const modifier_mask: u64 = cg.kCGEventFlagMaskCommand |
            cg.kCGEventFlagMaskControl |
            cg.kCGEventFlagMaskAlternate |
            cg.kCGEventFlagMaskShift;
        const active_modifiers: u32 = @intCast(flags & modifier_mask);

        if (keycode == target_keycode and active_modifiers == target_modifiers) {
            if (global_callback) |cb| cb();
            return null; // consume the event
        }

        return event;
    }

    /// Swap the active binding without tearing down the event tap.
    /// Used by the live-config reload path so users can re-bind the
    /// global toggle without restarting djinn.
    pub fn setBinding(_: *Hotkey, keycode: u16, modifiers: u32) void {
        target_keycode = keycode;
        target_modifiers = modifiers;
    }

    pub fn deinit(self: *Hotkey) void {
        cg.CGEventTapEnable(self.tap, false);
        cg.CFRunLoopRemoveSource(
            cg.CFRunLoopGetCurrent(),
            self.source,
            cg.kCFRunLoopCommonModes,
        );
        cg.CFRelease(self.source);
        cg.CFRelease(self.tap);
        global_callback = null;
    }
};

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
    var seen = [_]bool{false} ** 128;
    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (letters) |ch| {
        const code = keycodeFromName(&.{ch}) orelse unreachable;
        try std.testing.expect(!seen[code]);
        seen[code] = true;
    }
}
