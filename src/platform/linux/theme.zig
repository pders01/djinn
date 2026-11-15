//! VTE theme translation.
//!
//! Maps djinn's ghostty-format config (terminal.font_*, theme.*) onto
//! VTE's GObject-property API. Current surface:
//!
//!   - terminal.font_family + terminal.font_size →
//!     vte_terminal_set_font(PangoFontDescription*)
//!   - theme.background + theme.foreground + palette[0..15] →
//!     vte_terminal_set_colors(fg, bg, palette, 16)
//!   - theme.cursor → vte_terminal_set_color_cursor(GdkRGBA*)
//!   - terminal.padding_x + terminal.padding_y → CSS attached to the
//!     default GdkDisplay so the `vte-terminal` widget type matches
//!     all djinn session terminals without needing a per-widget
//!     style-context dance (deprecated in GTK 4.10).
//!
//! `inherit_ghostty` is owned by `main_linux.zig` now — it loads
//! ghostty's config via `ghostty_config.zig` and merges the result
//! into Options before calling `apply`. This file stays a pure
//! Options → VTE translator with no I/O.
//!
//! Opacity: passed as the alpha channel of the background GdkRGBA.
//! VTE honors bg-alpha when the parent window's surface is RGBA-capable.
//! On Wayland every surface is RGBA, so the only extra ceremony is one
//! CSS rule that makes `window` itself transparent — otherwise GTK's
//! default theme paints an opaque background under VTE and the alpha
//! never reaches the compositor. The shared CSS provider is replaced on every
//! apply, including an empty stylesheet when padding/transparency are removed.
//! Every apply is a full reconciliation, never a patch to previous options.
//!
//! Out of scope:
//!
//!   - cursor-shape / cursor-blink. Not in config today.

const std = @import("std");
const gtk = @import("gtk.zig");
const ghostty_config = @import("ghostty_config.zig");

const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
pub const Rgb = ghostty_config.Rgb;

// ─── GdkRGBA + opaque types ──────────────────────────────────────────

/// GTK4's color struct. Layout-stable extern: four float channels in
/// [0, 1]. VTE accepts pointers to this, never returns one.
const GdkRGBA = extern struct {
    red: f32,
    green: f32,
    blue: f32,
    alpha: f32,
};

const PangoFontDescription = opaque {};
const GtkCssProvider = gtk.GtkCssProvider;
const GdkDisplay = gtk.GdkDisplay;

// ─── External surface ────────────────────────────────────────────────

// VTE setters. The widget retains references to font descriptions and
// copies the GdkRGBA values internally — caller frees / drops on
// return.
extern "c" fn vte_terminal_set_font(
    terminal: *VteTerminal,
    font_desc: ?*const PangoFontDescription,
) void;
extern "c" fn vte_terminal_set_colors(
    terminal: *VteTerminal,
    foreground: ?*const GdkRGBA,
    background: ?*const GdkRGBA,
    palette: ?[*]const GdkRGBA,
    palette_size: usize,
) void;
extern "c" fn vte_terminal_set_color_cursor(
    terminal: *VteTerminal,
    cursor_background: ?*const GdkRGBA,
) void;

// Start from VTE's current native default description after set_font(NULL),
// then override only the configured axes (no synthetic family/size default).
extern "c" fn vte_terminal_get_font(terminal: *VteTerminal) *const PangoFontDescription;
extern "c" fn pango_font_description_copy(desc: *const PangoFontDescription) *PangoFontDescription;
extern "c" fn pango_font_description_set_family(desc: *PangoFontDescription, family: [*:0]const u8) void;
extern "c" fn pango_font_description_set_size(desc: *PangoFontDescription, size: c_int) void;
extern "c" fn pango_font_description_free(desc: *PangoFontDescription) void;

// Font availability check. `pango_font_map_list_families` populates a
// caller-freed array of PangoFontFamily pointers; we compare their
// names against the requested family (case-insensitive) to decide
// whether Pango would substitute. Substitution from a Nerd Font →
// generic sans is the root cause of the "wide-cell" rendering we saw
// when inheriting an uninstalled ghostty font.
const PangoFontMap = opaque {};
const PangoFontFamily = opaque {};
extern "c" fn pango_cairo_font_map_get_default() *PangoFontMap;
extern "c" fn pango_font_map_list_families(
    font_map: *PangoFontMap,
    families: *[*]?*PangoFontFamily,
    n_families: *c_int,
) void;
extern "c" fn pango_font_family_get_name(family: *PangoFontFamily) [*:0]const u8;
const g_free = gtk.g_free;

// CSS provider — global so we don't need gtk_widget_get_style_context
// (deprecated in GTK 4.10). The `vte-terminal` selector matches by
// widget type name and applies the shared appearance to session terminals.
// Provider externs live in gtk.zig.
const gtk_css_provider_new = gtk.gtk_css_provider_new;
const gtk_css_provider_load_from_string = gtk.gtk_css_provider_load_from_string;
const gtk_style_context_add_provider_for_display = gtk.gtk_style_context_add_provider_for_display;
const gdk_display_get_default = gtk.gdk_display_get_default;

/// Mirrors `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION` from
/// `gtkstyleprovider.h`. Sits above theme defaults so our padding
/// wins over whatever the user's GTK theme says about VTE.
const STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;

// ─── Public surface ──────────────────────────────────────────────────

/// Caller-supplied subset of djinn config. Each field is optional so
/// `apply` restores native defaults for anything the user removed or
/// didn't set. Colors arrive as `Rgb` so the caller owns hex parsing
/// upstream (`ghostty_config.parseColor` is the canonical entry).
pub const Options = struct {
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    cursor: ?Rgb = null,
    padding_x: ?f64 = null,
    padding_y: ?f64 = null,
    /// Background alpha in [0, 1]. null leaves VTE on full opacity.
    /// Applied as the alpha channel of the background GdkRGBA we send
    /// to `vte_terminal_set_colors`; foreground and palette stay fully
    /// opaque. Values < 1 also flip on a global `window {
    /// background-color: transparent; }` CSS rule so GTK doesn't paint
    /// an opaque theme background underneath VTE.
    opacity: ?f64 = null,
    /// 16-color ANSI palette. Each slot is independently optional —
    /// when *any* slot is set, the full palette is sent to VTE, with
    /// missing slots filled from `default_palette` (matches darwin's
    /// `theme/theme.zig::default_palette` so cross-platform users see
    /// the same fallback). When all slots are null, VTE keeps its
    /// built-in palette, restoring it if a previous apply overrode it.
    palette: [16]?Rgb = @splat(null),
};

pub fn apply(widget: *GtkWidget, opts: Options) void {
    const terminal: *VteTerminal = @ptrCast(widget);
    applyFont(terminal, opts);
    applyColors(terminal, opts);
    applyCursorColor(terminal, opts);
    applyCss(opts);
}

/// Module-level CSS provider — single instance owned by the display
/// once installed, reloaded in place on every `apply` call so config
/// hot-reloads don't stack providers (each new provider would have
/// equal priority and the last one would win for conflicting rules,
/// but removing an opt-in like `opacity` would leave the old
/// transparency rule lingering). One provider + reload = correct
/// behavior on every code path, including "user deleted the setting".
var g_css_provider: ?*GtkCssProvider = null;

/// Fallback ANSI palette used to fill slots the caller didn't set
/// when the *rest* of the palette is set. Same values as darwin's
/// `theme/theme.zig::default_palette` (Tomorrow Night–ish, the djinn
/// baseline) so a user with a partial ghostty palette gets the same
/// missing-slot colors on both platforms.
const default_palette: [16]Rgb = .{
    .{ .r = 0x1d, .g = 0x1f, .b = 0x21 }, .{ .r = 0xcc, .g = 0x66, .b = 0x66 },
    .{ .r = 0xb5, .g = 0xbd, .b = 0x68 }, .{ .r = 0xf0, .g = 0xc6, .b = 0x74 },
    .{ .r = 0x81, .g = 0xa2, .b = 0xbe }, .{ .r = 0xb2, .g = 0x94, .b = 0xbb },
    .{ .r = 0x8a, .g = 0xbe, .b = 0xb7 }, .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 },
    .{ .r = 0x66, .g = 0x66, .b = 0x66 }, .{ .r = 0xd5, .g = 0x4e, .b = 0x53 },
    .{ .r = 0xb9, .g = 0xca, .b = 0x4a }, .{ .r = 0xe7, .g = 0xc5, .b = 0x47 },
    .{ .r = 0x7a, .g = 0xa6, .b = 0xda }, .{ .r = 0xc3, .g = 0x97, .b = 0xd8 },
    .{ .r = 0x70, .g = 0xc0, .b = 0xb1 }, .{ .r = 0xea, .g = 0xea, .b = 0xea },
};

// ─── Field appliers ──────────────────────────────────────────────────

const FontPlan = struct {
    family: ?[]const u8,
    size: ?c_int,
};

fn fontPlan(opts: Options, family_available: bool) FontPlan {
    return .{
        .family = if (family_available) opts.font_family else null,
        .size = if (opts.font_size) |size|
            if (std.math.isFinite(size) and size > 0)
                @intFromFloat(std.math.clamp(size * 1024.0, 1.0, @as(f64, @floatFromInt(std.math.maxInt(c_int)))))
            else
                null
        else
            null,
    };
}

fn applyFont(terminal: *VteTerminal, opts: Options) void {
    // NULL restores VTE's native default even when the old family disappeared,
    // inheritance was disabled, or a newly requested font is unavailable.
    vte_terminal_set_font(terminal, null);
    const available = if (opts.font_family) |family| fontFamilyAvailable(family) else false;
    const plan = fontPlan(opts, available);
    if (opts.font_family != null and !available)
        std.debug.print("theme: pango can't resolve font-family '{s}'; using VTE default family\n", .{opts.font_family.?});
    if (plan.family == null and plan.size == null) return;

    const desc = pango_font_description_copy(vte_terminal_get_font(terminal));
    defer pango_font_description_free(desc);
    if (plan.family) |family| {
        var buffer: [512]u8 = undefined;
        if (std.mem.printSentinel(&buffer, "{s}", .{family}, 0)) |name| {
            pango_font_description_set_family(desc, name.ptr);
        } else |_| {
            std.debug.print("theme: font-family too long; using VTE default family\n", .{});
        }
    }
    if (plan.size) |size| pango_font_description_set_size(desc, size);
    vte_terminal_set_font(terminal, desc);
}

/// Is `family` installed and known to Pango's default font map?
/// Comparison is ASCII case-insensitive; family names are
/// conventionally Title Case but config files sometimes lower-case
/// them. Returns false on map-empty edge cases (Pango not yet
/// initialized) — caller treats that as "skip the font override".
fn fontFamilyAvailable(family: []const u8) bool {
    // Pango's generic monospace alias need not appear in the installed list.
    if (std.ascii.eqlIgnoreCase(family, "monospace")) return true;
    var families: [*]?*PangoFontFamily = undefined;
    var n: c_int = 0;
    pango_font_map_list_families(pango_cairo_font_map_get_default(), &families, &n);
    defer g_free(@ptrCast(families));
    if (n <= 0) return false;

    var i: usize = 0;
    const total: usize = @intCast(n);
    while (i < total) : (i += 1) {
        const fam = families[i] orelse continue;
        const name_z = pango_font_family_get_name(fam);
        const name = std.mem.span(name_z);
        if (std.ascii.eqlIgnoreCase(name, family)) return true;
    }
    return false;
}

const ColorPlan = struct {
    foreground: ?GdkRGBA,
    background: ?GdkRGBA,
    palette: [16]GdkRGBA,
    has_palette: bool = false,
};

fn colorPlan(opts: Options) ColorPlan {
    const alpha: f32 = if (opts.opacity) |o| @floatCast(std.math.clamp(o, 0.0, 1.0)) else 1.0;
    var plan = ColorPlan{
        .foreground = if (opts.foreground) |c| rgbToGdkRgba(c, 1.0) else null,
        // Opacity alone intentionally uses the djinn dark baseline background.
        .background = if (opts.background != null or alpha < 1.0) rgbToGdkRgba(opts.background orelse default_palette[0], alpha) else null,
        .palette = undefined,
    };
    for (opts.palette, default_palette, 0..) |slot, fallback, i| {
        plan.has_palette = plan.has_palette or slot != null;
        plan.palette[i] = rgbToGdkRgba(slot orelse fallback, 1.0);
    }
    return plan;
}

fn applyColors(terminal: *VteTerminal, opts: Options) void {
    const plan = colorPlan(opts);
    // This is a reset API, not a patch: NULL fg/bg choose VTE's defaults,
    // NULL palette + size 0 restores the built-in palette. ALWAYS call it,
    // even when every override disappeared, to remove previous values/alpha.
    vte_terminal_set_colors(
        terminal,
        if (plan.foreground) |*c| c else null,
        if (plan.background) |*c| c else null,
        if (plan.has_palette) &plan.palette else null,
        if (plan.has_palette) 16 else 0,
    );
}

fn rgbToGdkRgba(c: Rgb, alpha: f32) GdkRGBA {
    return .{
        .red = @as(f32, @floatFromInt(c.r)) / 255.0,
        .green = @as(f32, @floatFromInt(c.g)) / 255.0,
        .blue = @as(f32, @floatFromInt(c.b)) / 255.0,
        .alpha = alpha,
    };
}

fn cursorColor(opts: Options) ?GdkRGBA {
    return if (opts.cursor) |c| rgbToGdkRgba(c, 1.0) else null;
}

fn applyCursorColor(terminal: *VteTerminal, opts: Options) void {
    const rgba = cursorColor(opts);
    // NULL returns to VTE's reverse-video cursor, including after reload.
    vte_terminal_set_color_cursor(terminal, if (rgba) |*c| c else null);
}

/// Build the combined theme CSS (padding + window transparency) and
/// install or reload the module-level provider on the default
/// display. First call creates + adds the provider; subsequent calls
/// reload its content in place. CSS shorthand puts vertical first,
/// horizontal second, matching GTK's box model.
/// Empty CSS is intentional: loading it removes old padding/transparency.
fn applyCss(opts: Options) void {
    var css_buf: [512]u8 = undefined;
    const css = buildCss(&css_buf, opts) catch |err| {
        std.debug.print("theme: CSS buffer overflow: {}\n", .{err});
        return;
    };
    if (css.len == 0 and g_css_provider == null) return;

    const display = gdk_display_get_default() orelse {
        std.debug.print("theme: gdk_display_get_default returned null; skipping CSS\n", .{});
        return;
    };

    if (g_css_provider == null) {
        const provider = gtk_css_provider_new();
        g_css_provider = provider;
        // add_provider_for_display retains its own ref on the provider;
        // we hold ours via g_css_provider so reload calls can find it
        // again. Both live for the process lifetime.
        gtk_style_context_add_provider_for_display(
            display,
            @ptrCast(provider),
            STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    gtk_css_provider_load_from_string(g_css_provider.?, css.ptr);
}

fn cssPixels(value: f64) u32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(value, 0.0, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
}

/// Pure stylesheet builder. Omitted axes have NO rule so GTK's native theme
/// supplies them; never fill a removed axis with an arbitrary 8px override.
fn buildCss(buffer: []u8, opts: Options) ![:0]const u8 {
    var n: usize = 0;
    if (opts.padding_x) |x| {
        const text = try std.fmt.bufPrint(buffer[n..], "vte-terminal {{ padding-left: {d}px; padding-right: {d}px; }}", .{ cssPixels(x), cssPixels(x) });
        n += text.len;
    }
    if (opts.padding_y) |y| {
        const text = try std.fmt.bufPrint(buffer[n..], "vte-terminal {{ padding-top: {d}px; padding-bottom: {d}px; }}", .{ cssPixels(y), cssPixels(y) });
        n += text.len;
    }
    if ((opts.opacity orelse 1.0) < 1.0) {
        const text = try std.fmt.bufPrint(buffer[n..], "window, window.background, window.csd {{ background-color: transparent; background-image: none; }} " ++
            "window > * {{ background-color: transparent; }} " ++
            "vte-terminal, vte-terminal.terminal {{ background-color: transparent; }}", .{});
        n += text.len;
    }
    if (n >= buffer.len) return error.NoSpaceLeft;
    buffer[n] = 0;
    return buffer[0..n :0];
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Theme native API compiles without opening a display" {
    std.testing.refAllDecls(@This());
}

test "font and cursor plans remove each override without inventing defaults" {
    var opts = Options{ .font_family = "Fixture Mono", .font_size = 13.5, .cursor = .{ .r = 1, .g = 2, .b = 3 } };
    var plan = fontPlan(opts, true);
    try std.testing.expectEqualStrings("Fixture Mono", plan.family.?);
    try std.testing.expectEqual(@as(?c_int, 13824), plan.size);
    try std.testing.expect(cursorColor(opts) != null);
    opts.font_family = null;
    plan = fontPlan(opts, false);
    try std.testing.expect(plan.family == null);
    try std.testing.expectEqual(@as(?c_int, 13824), plan.size);
    opts.font_family = "Fixture Mono";
    opts.font_size = null;
    plan = fontPlan(opts, true);
    try std.testing.expectEqualStrings("Fixture Mono", plan.family.?);
    try std.testing.expect(plan.size == null);
    // An unavailable inherited family falls back to the reset native font,
    // not whichever override had been installed on this terminal before.
    plan = fontPlan(opts, false);
    try std.testing.expect(plan.family == null and plan.size == null);
    plan = fontPlan(.{}, false);
    try std.testing.expect(plan.family == null and plan.size == null);
    try std.testing.expect(cursorColor(.{}) == null);
    try std.testing.expect(fontPlan(.{ .font_size = std.math.inf(f64) }, false).size == null);
}

test "removed colors palette and opacity resolve to native reset arguments" {
    var opts = Options{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .background = .{ .r = 4, .g = 5, .b = 6 },
        .cursor = .{ .r = 7, .g = 8, .b = 9 },
        .opacity = 0.4,
    };
    opts.palette[3] = .{ .r = 10, .g = 11, .b = 12 };
    var plan = colorPlan(opts);
    try std.testing.expect(plan.has_palette);
    try std.testing.expectEqual(@as(f32, 0.4), plan.background.?.alpha);
    // Clearing an individual field must not retain its previous native value.
    opts.foreground = null;
    opts.opacity = null;
    opts.palette[3] = null;
    plan = colorPlan(opts);
    try std.testing.expect(plan.foreground == null);
    try std.testing.expect(!plan.has_palette);
    try std.testing.expectEqual(@as(f32, 1.0), plan.background.?.alpha);
    // Missing inheritance / inherit=false / fresh standalone session all use
    // the identical complete reset plan, regardless of previous options.
    for (0..3) |_| {
        plan = colorPlan(.{});
        try std.testing.expect(plan.foreground == null and plan.background == null);
        try std.testing.expect(!plan.has_palette);
    }
    const alpha_only = colorPlan(.{ .opacity = 0.5 });
    try std.testing.expectEqual(rgbToGdkRgba(default_palette[0], 0.5), alpha_only.background.?);
}

test "CSS replacement clears removed axes and transparency including empty reset" {
    var buffer: [512]u8 = undefined;
    const full = try buildCss(&buffer, .{ .padding_x = 12, .padding_y = 9, .opacity = 0.5 });
    try std.testing.expect(std.mem.indexOf(u8, full, "padding-left: 12px") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "padding-top: 9px") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "transparent") != null);
    const x_only = try buildCss(&buffer, .{ .padding_x = 0, .opacity = 1.0 });
    try std.testing.expect(std.mem.indexOf(u8, x_only, "padding-left: 0px") != null);
    try std.testing.expect(std.mem.indexOf(u8, x_only, "padding-top") == null);
    try std.testing.expect(std.mem.indexOf(u8, x_only, "transparent") == null);
    const y_only = try buildCss(&buffer, .{ .padding_y = 3 });
    try std.testing.expect(std.mem.indexOf(u8, y_only, "padding-left") == null);
    try std.testing.expect(std.mem.indexOf(u8, y_only, "padding-top: 3px") != null);
    const empty = try buildCss(&buffer, .{});
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expectEqual(@as(u8, 0), empty.ptr[0]);
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, buildCss(&tiny, .{ .padding_x = 8 }));
}

test "rgbToGdkRgba: channel mapping" {
    const c = rgbToGdkRgba(.{ .r = 0x1a, .g = 0x2b, .b = 0x3c }, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0x1a) / 255.0, c.red, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0x2b) / 255.0, c.green, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0x3c) / 255.0, c.blue, 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), c.alpha);
}
