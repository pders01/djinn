const std = @import("std");

/// NSEvent modifier flag bits as the keymap dispatcher sees them.
/// Match AppKit's `NSEventModifierFlag*` raw values so callers can
/// pass `event.modifierFlags` straight in. The 32-bit bits used by
/// `parseKeybinding` (in `hotkey/darwin.zig`) match these positions —
/// the bit layout is shared across NSEvent / Carbon / CGEvent.
pub const mod_shift: u64 = 1 << 17;
pub const mod_control: u64 = 1 << 18;
pub const mod_alt: u64 = 1 << 19;
pub const mod_cmd: u64 = 1 << 20;
pub const mod_mask: u64 = mod_shift | mod_control | mod_alt | mod_cmd;

pub const Handler = *const fn () void;

/// One row of the host action table. Stable `name` doubles as the
/// config key for `keymap.<name> = <binding>` overrides; `mods` +
/// `keycode` are matched exactly against masked-off NSEvent flags +
/// the macOS hardware keycode (kVK_*).
pub const Action = struct {
    name: []const u8,
    mods: u64,
    keycode: u16,
    handler: Handler,
};

/// Linear lookup over `actions`: returns the first row whose
/// (mods, keycode) matches `flags & mod_mask` exactly. Returns null
/// when nothing matches. Pulled out of `dispatch` so tests can verify
/// the mask + match semantics without invoking the side-effecting
/// handlers.
pub fn matchIndex(actions: []const Action, flags: u64, keycode: u16) ?usize {
    const masked = flags & mod_mask;
    for (actions, 0..) |a, i| {
        if (a.keycode == keycode and a.mods == masked) return i;
    }
    return null;
}

/// Run the first matching action's handler. Returns true when a row
/// fired, false when no row matched. Equivalent to:
/// `if (matchIndex(...)) |i| { actions[i].handler(); return true; }`
pub fn dispatch(actions: []const Action, flags: u64, keycode: u16) bool {
    const i = matchIndex(actions, flags, keycode) orelse return false;
    actions[i].handler();
    return true;
}

/// Override `actions[i].mods` + `actions[i].keycode` for the first
/// row whose name matches. Returns true on hit, false when the name
/// is unknown — caller logs + skips so a typo in user config doesn't
/// crash the host.
pub fn rebind(actions: []Action, name: []const u8, mods: u64, keycode: u16) bool {
    for (actions) |*a| {
        if (std.mem.eql(u8, a.name, name)) {
            a.mods = mods;
            a.keycode = keycode;
            return true;
        }
    }
    return false;
}

// ─── Tests ──────────────────────────────────────────────────────────

const TestCounter = struct {
    var hits: [4]u32 = [_]u32{0} ** 4;

    fn reset() void {
        hits = [_]u32{0} ** 4;
    }

    fn h0() void {
        hits[0] += 1;
    }
    fn h1() void {
        hits[1] += 1;
    }
    fn h2() void {
        hits[2] += 1;
    }
    fn h3() void {
        hits[3] += 1;
    }
};

fn testActions() [4]Action {
    return [_]Action{
        .{ .name = "paste", .mods = mod_cmd, .keycode = 9, .handler = TestCounter.h0 },
        .{ .name = "find_open", .mods = mod_cmd, .keycode = 3, .handler = TestCounter.h1 },
        .{ .name = "find_prev", .mods = mod_cmd | mod_shift, .keycode = 5, .handler = TestCounter.h2 },
        .{ .name = "find_next", .mods = mod_cmd, .keycode = 5, .handler = TestCounter.h3 },
    };
}

test "keymap: dispatch fires matching handler" {
    TestCounter.reset();
    const actions = testActions();
    try std.testing.expect(dispatch(&actions, mod_cmd, 9));
    try std.testing.expectEqual(@as(u32, 1), TestCounter.hits[0]);
    for (TestCounter.hits[1..]) |h| try std.testing.expectEqual(@as(u32, 0), h);
}

test "keymap: dispatch returns false on miss" {
    TestCounter.reset();
    const actions = testActions();
    // Cmd+Shift+V — no entry binds this.
    try std.testing.expect(!dispatch(&actions, mod_cmd | mod_shift, 9));
    for (TestCounter.hits) |h| try std.testing.expectEqual(@as(u32, 0), h);
}

test "keymap: dispatch ignores non-target modifier bits" {
    // Caps Lock (1<<16), function-key flag (1<<23), and other AppKit
    // bits sit outside `mod_mask` and must not break the match.
    TestCounter.reset();
    const actions = testActions();
    const noisy_flags = mod_cmd | (1 << 16) | (1 << 23);
    try std.testing.expect(dispatch(&actions, noisy_flags, 9));
    try std.testing.expectEqual(@as(u32, 1), TestCounter.hits[0]);
}

test "keymap: overlapping keycodes pick the right mods" {
    // find_prev (Cmd+Shift+G) and find_next (Cmd+G) share keycode 5;
    // the mods column has to disambiguate.
    TestCounter.reset();
    const actions = testActions();
    try std.testing.expect(dispatch(&actions, mod_cmd, 5));
    try std.testing.expect(dispatch(&actions, mod_cmd | mod_shift, 5));
    try std.testing.expectEqual(@as(u32, 1), TestCounter.hits[3]); // find_next
    try std.testing.expectEqual(@as(u32, 1), TestCounter.hits[2]); // find_prev
}

test "keymap: matchIndex returns first match" {
    const actions = testActions();
    try std.testing.expectEqual(@as(?usize, 0), matchIndex(&actions, mod_cmd, 9));
    try std.testing.expectEqual(@as(?usize, 1), matchIndex(&actions, mod_cmd, 3));
    try std.testing.expectEqual(@as(?usize, null), matchIndex(&actions, mod_alt, 9));
}

test "keymap: rebind by name updates table in place" {
    var actions = testActions();
    try std.testing.expect(rebind(&actions, "paste", mod_cmd | mod_shift, 9));
    try std.testing.expectEqual(mod_cmd | mod_shift, actions[0].mods);
    // Old binding (Cmd+V) no longer matches; new one does.
    TestCounter.reset();
    try std.testing.expect(!dispatch(&actions, mod_cmd, 9));
    try std.testing.expect(dispatch(&actions, mod_cmd | mod_shift, 9));
    try std.testing.expectEqual(@as(u32, 1), TestCounter.hits[0]);
}

test "keymap: rebind unknown name returns false" {
    var actions = testActions();
    try std.testing.expect(!rebind(&actions, "nonexistent", mod_cmd, 0));
}
