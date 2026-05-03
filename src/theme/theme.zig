const std = @import("std");
const objc = @import("objc");
const ghostty_runtime = @import("../ghostty/runtime.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Appearance = enum { light, dark };

/// Accepts `#rrggbb`, `rrggbb`, optionally with `0x` prefix. Used by
/// main.zig to resolve djinn-config-level theme overrides (where the
/// user types a hex color string in the config file).
pub fn parseColor(s: []const u8) ?Rgb {
    var hex = s;
    if (std.mem.startsWith(u8, hex, "#")) hex = hex[1..];
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

/// Resolved visual theme for djinn — what the renderer actually uses.
/// All fields have defaults so callers don't carry optionals around.
pub const Theme = struct {
    font_family: []const u8 = "Menlo",
    /// Default 11pt — closer to ghostty's actual rendered cell size on
    /// macOS than 13pt. ghostty's "13pt" lands smaller than ours did
    /// because their font shaper accounts for leading differently;
    /// matching their visual rather than their config-stated value.
    font_size: f64 = 11,
    padding_x: f64 = 8,
    padding_y: f64 = 8,
    opacity: f64 = 0.97,
    blur_radius: f64 = 0,
    background: Rgb = .{ .r = 26, .g = 26, .b = 30 },
    foreground: Rgb = .{ .r = 204, .g = 204, .b = 204 },
    cursor_color: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    palette: [16]Rgb = default_palette,
    appearance: Appearance = .dark,

    /// Owned strings are freed here.
    owned_font_family: bool = false,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Theme) void {
        if (self.owned_font_family) {
            if (self.allocator) |a| a.free(self.font_family);
        }
    }
};

const default_palette = [16]Rgb{
    .{ .r = 0x1d, .g = 0x1f, .b = 0x21 }, .{ .r = 0xcc, .g = 0x66, .b = 0x66 },
    .{ .r = 0xb5, .g = 0xbd, .b = 0x68 }, .{ .r = 0xf0, .g = 0xc6, .b = 0x74 },
    .{ .r = 0x81, .g = 0xa2, .b = 0xbe }, .{ .r = 0xb2, .g = 0x94, .b = 0xbb },
    .{ .r = 0x8a, .g = 0xbe, .b = 0xb7 }, .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 },
    .{ .r = 0x66, .g = 0x66, .b = 0x66 }, .{ .r = 0xd5, .g = 0x4e, .b = 0x53 },
    .{ .r = 0xb9, .g = 0xca, .b = 0x4a }, .{ .r = 0xe7, .g = 0xc5, .b = 0x47 },
    .{ .r = 0x7a, .g = 0xa6, .b = 0xda }, .{ .r = 0xc3, .g = 0x97, .b = 0xd8 },
    .{ .r = 0x70, .g = 0xc0, .b = 0xb1 }, .{ .r = 0xea, .g = 0xea, .b = 0xea },
};

/// Detect macOS system appearance via NSAppearance. Defaults to .dark on
/// failure (most terminal users prefer dark).
pub fn detectSystemAppearance() Appearance {
    const NSApplication = objc.getClass("NSApplication") orelse return .dark;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    const appearance = app.msgSend(objc.Object, "effectiveAppearance", .{});
    if (appearance.value == null) return .dark;
    const name = appearance.msgSend(objc.Object, "name", .{});
    if (name.value == null) return .dark;
    const utf8 = name.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8 == null) return .dark;
    const str = std.mem.sliceTo(utf8, 0);
    if (std.mem.indexOf(u8, str, "Dark") != null) return .dark;
    return .light;
}

/// `theme = light:X,dark:Y` → return {X or Y} based on appearance.
/// Plain `theme = X` → return X regardless.
pub fn pickThemeName(spec: []const u8, appearance: Appearance) []const u8 {
    if (std.mem.indexOf(u8, spec, ",") == null and std.mem.indexOf(u8, spec, ":") == null) {
        return std.mem.trim(u8, spec, " \t");
    }
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const variant = std.mem.trim(u8, trimmed[0..colon], " \t");
        const name = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        const matches = switch (appearance) {
            .light => std.mem.eql(u8, variant, "light"),
            .dark => std.mem.eql(u8, variant, "dark"),
        };
        if (matches) return name;
    }
    return std.mem.trim(u8, spec, " \t");
}

/// Resolve a complete Theme by reading ghostty config + the named theme
/// file (if any) + applying djinn config overrides (caller passes those in
/// via the Overrides struct).
pub fn resolve(allocator: std.mem.Allocator, overrides: Overrides) !Theme {
    var t = Theme{ .allocator = allocator };
    t.appearance = detectSystemAppearance();

    // ghostty owns config resolution: it already merged the active
    // theme + finalized during App.init. We read the resolved Config
    // via ghostty_config_get so the surface and the log_pane /
    // menubar palettes can never diverge.
    if (overrides.inherit_ghostty_config) {
        if (overrides.ghostty_cfg) |cfg_opaque| {
            const cfg: ghostty_runtime.c.ghostty_config_t = @ptrCast(cfg_opaque);
            applyFromGhostty(&t, cfg, allocator);
        }
    }

    // Djinn-config overrides take precedence over ghostty.
    if (overrides.font_family) |s| {
        if (t.owned_font_family) allocator.free(t.font_family);
        t.font_family = try allocator.dupe(u8, s);
        t.owned_font_family = true;
    }
    if (overrides.font_size) |v| t.font_size = v;
    if (overrides.padding_x) |v| t.padding_x = v;
    if (overrides.padding_y) |v| t.padding_y = v;
    if (overrides.opacity) |v| t.opacity = v;
    if (overrides.background) |c| t.background = c;
    if (overrides.foreground) |c| t.foreground = c;
    if (overrides.cursor_color) |c| t.cursor_color = c;

    return t;
}

pub const Overrides = struct {
    inherit_ghostty_config: bool = true,
    /// When non-null + inherit_ghostty_config, theme.resolve queries
    /// ghostty's own Config via ghostty_config_get instead of
    /// re-parsing ~/.config/ghostty/config. Opaque to avoid pulling
    /// ghostty.h into this module — runtime.zig casts it back.
    ghostty_cfg: ?*anyopaque = null,
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,
    padding_x: ?f64 = null,
    padding_y: ?f64 = null,
    opacity: ?f64 = null,
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    cursor_color: ?Rgb = null,
};

/// Reads from a live ghostty_config_t
/// via ghostty_config_get. Replaces the file re-parse path when ghostty
/// backend is active. Bypasses the bundled-theme search dance entirely
/// because ghostty already merged the active theme file into its
/// resolved Config during finalize().
fn applyFromGhostty(t: *Theme, cfg: ghostty_runtime.c.ghostty_config_t, allocator: std.mem.Allocator) void {
    if (ghostty_runtime.configString(cfg, "font-family")) |s| {
        if (s.len > 0) {
            if (t.owned_font_family) allocator.free(t.font_family);
            t.font_family = allocator.dupe(u8, s) catch t.font_family;
            t.owned_font_family = true;
        }
    }
    // Type-strict reads: ghostty stores `font-size` as f32,
    // `background-opacity` as f64. `window-padding-x/y` are a
    // `WindowPadding` struct in ghostty (not a scalar) — the previous
    // configFloat read returned false silently, so padding overrides
    // never actually applied. Until we wire up the struct path, leave
    // the defaults from the djinn-config layer untouched.
    if (ghostty_runtime.configF32(cfg, "font-size")) |v| {
        if (v > 0) t.font_size = @floatCast(v);
    }
    if (ghostty_runtime.configF64(cfg, "background-opacity")) |v| t.opacity = v;
    if (ghostty_runtime.configColor(cfg, "background")) |c| {
        t.background = .{ .r = c.r, .g = c.g, .b = c.b };
    }
    if (ghostty_runtime.configColor(cfg, "foreground")) |c| {
        t.foreground = .{ .r = c.r, .g = c.g, .b = c.b };
    }
    if (ghostty_runtime.configColor(cfg, "cursor-color")) |c| {
        t.cursor_color = .{ .r = c.r, .g = c.g, .b = c.b };
    }
    if (ghostty_runtime.configPalette(cfg)) |pal| {
        for (0..16) |i| {
            const c = pal.colors[i];
            t.palette[i] = .{ .r = c.r, .g = c.g, .b = c.b };
        }
    }
}

test "pickThemeName: light/dark variants" {
    try std.testing.expectEqualStrings("Day", pickThemeName("light:Day,dark:Night", .light));
    try std.testing.expectEqualStrings("Night", pickThemeName("light:Day,dark:Night", .dark));
}

test "pickThemeName: plain name" {
    try std.testing.expectEqualStrings("Dracula", pickThemeName("Dracula", .light));
    try std.testing.expectEqualStrings("Dracula", pickThemeName("Dracula", .dark));
}

test "pickThemeName: spaces in name" {
    try std.testing.expectEqualStrings("TokyoNight Storm", pickThemeName("light:TokyoNight Day,dark:TokyoNight Storm", .dark));
}

test "parseColor: #rrggbb form" {
    const c = parseColor("#1a2b3c") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0x1a), c.r);
    try std.testing.expectEqual(@as(u8, 0x2b), c.g);
    try std.testing.expectEqual(@as(u8, 0x3c), c.b);
}

test "parseColor: plain rrggbb" {
    const c = parseColor("ffeedd") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0xff), c.r);
    try std.testing.expectEqual(@as(u8, 0xee), c.g);
    try std.testing.expectEqual(@as(u8, 0xdd), c.b);
}

test "parseColor: 0x prefix" {
    const c = parseColor("0x010203") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 1), c.r);
    try std.testing.expectEqual(@as(u8, 2), c.g);
    try std.testing.expectEqual(@as(u8, 3), c.b);
}

test "parseColor: 0X uppercase prefix" {
    try std.testing.expect(parseColor("0XABCDEF") != null);
}

test "parseColor: rejects wrong length" {
    try std.testing.expect(parseColor("#abc") == null);
    try std.testing.expect(parseColor("abcdefg") == null);
    try std.testing.expect(parseColor("") == null);
}

test "parseColor: rejects non-hex chars" {
    try std.testing.expect(parseColor("#zzggbb") == null);
    try std.testing.expect(parseColor("gghhii") == null);
}
