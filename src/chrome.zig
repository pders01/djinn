const std = @import("std");
const objc = @import("objc");
const theme_mod = @import("theme/theme.zig");

/// Single source of truth for chrome (host UI surfaces — log pane, find
/// overlay, future settings/palette). Derives colors + typography from
/// the resolved Theme so every surface feels like one app, not three.
///
/// Anything that paints chrome should consume a `Style` and use the
/// helpers in this module instead of hardcoding colors. The terminal
/// surface itself is not chrome — ghostty owns its own render.
pub const Rgb = theme_mod.Rgb;

pub const Style = struct {
    bg: Rgb,
    fg: Rgb,
    /// palette[8] — bright black. Section headers, timestamps, inline
    /// labels; anywhere subdued text reads better than full fg.
    dim: Rgb,
    /// palette[12] / [11] / [9] — ANSI bright blue / yellow / red. Used
    /// by the log pane for level dots; available for any chrome that
    /// needs to signal info / warn / error consistently.
    info: Rgb,
    warn: Rgb,
    err: Rgb,
    /// Inverted high-contrast chip for floating UI affordances (find
    /// overlay, future toasts). Reads as a distinct surface, not as
    /// blended chrome — that's the design call: chips DECLARE
    /// themselves; header strips RECEDE.
    chip: Chip,
    /// Inherited from the resolved Theme — matches the terminal font so
    /// chrome text + terminal text don't fight for attention.
    font_family: []const u8,
    /// Smaller secondary size for chrome (log entries, log header).
    /// `max(11, theme.font_size - 2)` — readable but visually subordinate
    /// to terminal output.
    font_size_sm: f64,
    /// Chip text size — same as `font_size_sm` so chip labels and log
    /// entries read at the same visual weight. Different chrome roles
    /// (floating control vs. side panel) but one typographic axis.
    font_size_chip: f64,

    pub fn fromTheme(t: theme_mod.Theme) Style {
        return .{
            .bg = t.background,
            .fg = t.foreground,
            .dim = t.palette[8],
            .info = t.palette[12],
            .warn = t.palette[11],
            .err = t.palette[9],
            .chip = blk: {
                // 12% lift toward fg — strong enough to read against
                // terminal bg without inversion. Same fill drives the
                // log pane, so chrome surfaces share one color.
                const chip_bg = mix(t.background, t.foreground, 0.12);
                break :blk .{
                    .bg = chip_bg,
                    .fg = t.foreground,
                    // Mid-blend between chip bg and fg — guaranteed
                    // legible mid-tone regardless of theme polarity.
                    // palette[8] would clash on bright themes; this
                    // composes correctly against the lifted bg.
                    .dim = mix(chip_bg, t.foreground, 0.45),
                };
            },
            .font_family = t.font_family,
            .font_size_sm = @max(11, t.font_size - 2),
            .font_size_chip = @max(11, t.font_size - 2),
        };
    }
};

pub const Chip = struct {
    bg: Rgb,
    fg: Rgb,
    dim: Rgb,
};

/// Linear blend of two colors. `t=0` → a, `t=1` → b. Component-wise
/// interpolation in sRGB space; close enough for the small alpha values
/// chrome uses (4% lift, no perceptual nonlinearity worth correcting).
pub fn mix(a: Rgb, b: Rgb, t: f64) Rgb {
    const ar: f64 = @floatFromInt(a.r);
    const ag: f64 = @floatFromInt(a.g);
    const ab: f64 = @floatFromInt(a.b);
    const br: f64 = @floatFromInt(b.r);
    const bg: f64 = @floatFromInt(b.g);
    const bb: f64 = @floatFromInt(b.b);
    return .{
        .r = @intFromFloat(ar + (br - ar) * t),
        .g = @intFromFloat(ag + (bg - ag) * t),
        .b = @intFromFloat(ab + (bb - ab) * t),
    };
}

/// Convert an Rgb to an NSColor in sRGB space at full alpha. Caller
/// passes the NSColor class so this module doesn't have to repeat the
/// `objc.getClass` lookup at every call site.
pub fn nsColorFromRgb(NSColor: objc.Class, c: Rgb) objc.Object {
    return NSColor.msgSend(
        objc.Object,
        "colorWithSRGBRed:green:blue:alpha:",
        .{
            @as(f64, @floatFromInt(c.r)) / 255.0,
            @as(f64, @floatFromInt(c.g)) / 255.0,
            @as(f64, @floatFromInt(c.b)) / 255.0,
            @as(f64, 1.0),
        },
    );
}

/// Resolve the chrome font (ghostty family at the small chrome size).
/// Used by every host chrome surface — log entries, find chip, future
/// status text — so they sit on the same typographic axis. Falls back
/// to the system fixed-pitch font if the family doesn't resolve.
pub fn chromeFont(NSFont: objc.Class, family: []const u8, size: f64) objc.Object {
    const NSString = objc.getClass("NSString") orelse return NSFont.msgSend(objc.Object, "userFixedPitchFontOfSize:", .{size});
    const z = std.heap.page_allocator.allocSentinel(u8, family.len, 0) catch return NSFont.msgSend(objc.Object, "userFixedPitchFontOfSize:", .{size});
    defer std.heap.page_allocator.free(z);
    @memcpy(z[0..family.len], family);
    const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, z.ptr)});
    const f = NSFont.msgSend(objc.Object, "fontWithName:size:", .{ ns_name, size });
    if (f.value != null) return f;
    return NSFont.msgSend(objc.Object, "userFixedPitchFontOfSize:", .{size});
}

/// Same as `nsColorFromRgb` but with caller-provided alpha. Useful for
/// any chrome that wants a partially translucent fill (e.g. shadow
/// scrim, modal backdrop).
pub fn nsColorFromRgba(NSColor: objc.Class, c: Rgb, alpha: f64) objc.Object {
    return NSColor.msgSend(
        objc.Object,
        "colorWithSRGBRed:green:blue:alpha:",
        .{
            @as(f64, @floatFromInt(c.r)) / 255.0,
            @as(f64, @floatFromInt(c.g)) / 255.0,
            @as(f64, @floatFromInt(c.b)) / 255.0,
            alpha,
        },
    );
}

test "Style.fromTheme: dims + accents from palette" {
    const t = theme_mod.Theme{};
    const s = Style.fromTheme(t);
    try std.testing.expectEqual(t.palette[8], s.dim);
    try std.testing.expectEqual(t.palette[12], s.info);
    try std.testing.expectEqual(t.palette[11], s.warn);
    try std.testing.expectEqual(t.palette[9], s.err);
}

test "Style.fromTheme: chip bg lifted in-palette" {
    const t = theme_mod.Theme{};
    const s = Style.fromTheme(t);
    try std.testing.expect(s.chip.bg.r > t.background.r or s.chip.bg.g > t.background.g or s.chip.bg.b > t.background.b);
    try std.testing.expectEqual(t.foreground, s.chip.fg);
}

test "Style.font_size_sm: floor at 11" {
    const t = theme_mod.Theme{ .font_size = 9 };
    const s = Style.fromTheme(t);
    try std.testing.expectEqual(@as(f64, 11), s.font_size_sm);
}

test "Style.font_size_sm: tracks larger sizes minus 2" {
    const t = theme_mod.Theme{ .font_size = 14 };
    const s = Style.fromTheme(t);
    try std.testing.expectEqual(@as(f64, 12), s.font_size_sm);
}

test "mix: endpoints + midpoint" {
    const a = Rgb{ .r = 0, .g = 0, .b = 0 };
    const b = Rgb{ .r = 100, .g = 200, .b = 250 };
    try std.testing.expectEqual(a, mix(a, b, 0));
    try std.testing.expectEqual(b, mix(a, b, 1));
    const mid = mix(a, b, 0.5);
    try std.testing.expectEqual(@as(u8, 50), mid.r);
    try std.testing.expectEqual(@as(u8, 100), mid.g);
    try std.testing.expectEqual(@as(u8, 125), mid.b);
}
