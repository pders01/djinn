//! NSEvent → ghostty input translation.
//!
//! Tier-5 surface mode forwards key + mouse events to libghostty via
//! `ghostty_surface_key` / `ghostty_surface_mouse_*`. Those APIs take
//! ghostty's own enums (`ghostty_input_mods_e`, `ghostty_input_mouse_button_e`)
//! built from raw Mac keycodes / NSEvent modifier flags.
//!
//! `ghostty_input_key_s.keycode` is the raw platform keycode — on macOS
//! that's `NSEvent.keyCode`. ghostty maps it to its W3C-style key enum
//! internally; we don't need a translation table on our side.

const c = @import("runtime.zig").c;

// NSEventModifierFlag bits (matching view.zig::mod_*).
const ns_caps_lock: u64 = 1 << 16;
const ns_shift: u64 = 1 << 17;
const ns_control: u64 = 1 << 18;
const ns_alt: u64 = 1 << 19;
const ns_cmd: u64 = 1 << 20;

pub fn modsFromNS(flags: u64) c.ghostty_input_mods_e {
    var m: c.ghostty_input_mods_e = c.GHOSTTY_MODS_NONE;
    if (flags & ns_shift != 0) m |= c.GHOSTTY_MODS_SHIFT;
    if (flags & ns_control != 0) m |= c.GHOSTTY_MODS_CTRL;
    if (flags & ns_alt != 0) m |= c.GHOSTTY_MODS_ALT;
    if (flags & ns_cmd != 0) m |= c.GHOSTTY_MODS_SUPER;
    if (flags & ns_caps_lock != 0) m |= c.GHOSTTY_MODS_CAPS;
    return m;
}

pub fn mouseButtonFromNS(button_number: c_long) c.ghostty_input_mouse_button_e {
    return switch (button_number) {
        0 => c.GHOSTTY_MOUSE_LEFT,
        1 => c.GHOSTTY_MOUSE_RIGHT,
        2 => c.GHOSTTY_MOUSE_MIDDLE,
        3 => c.GHOSTTY_MOUSE_FOUR,
        4 => c.GHOSTTY_MOUSE_FIVE,
        5 => c.GHOSTTY_MOUSE_SIX,
        6 => c.GHOSTTY_MOUSE_SEVEN,
        7 => c.GHOSTTY_MOUSE_EIGHT,
        8 => c.GHOSTTY_MOUSE_NINE,
        9 => c.GHOSTTY_MOUSE_TEN,
        10 => c.GHOSTTY_MOUSE_ELEVEN,
        else => c.GHOSTTY_MOUSE_UNKNOWN,
    };
}

/// Read the first Unicode scalar from a UTF-8 string. Used for the
/// `unshifted_codepoint` field — ghostty wants the raw codepoint of
/// `[event charactersIgnoringModifiers]` so it can identify the key
/// independent of layout shifts.
pub fn firstCodepoint(utf8: []const u8) u32 {
    if (utf8.len == 0) return 0;
    const b0 = utf8[0];
    if (b0 < 0x80) return b0;
    if (utf8.len < 2) return 0;
    if (b0 < 0xc0) return 0;
    if (b0 < 0xe0) return (@as(u32, b0 & 0x1f) << 6) | (utf8[1] & 0x3f);
    if (utf8.len < 3) return 0;
    if (b0 < 0xf0) return (@as(u32, b0 & 0x0f) << 12) | (@as(u32, utf8[1] & 0x3f) << 6) | (utf8[2] & 0x3f);
    if (utf8.len < 4) return 0;
    return (@as(u32, b0 & 0x07) << 18) | (@as(u32, utf8[1] & 0x3f) << 12) | (@as(u32, utf8[2] & 0x3f) << 6) | (utf8[3] & 0x3f);
}
