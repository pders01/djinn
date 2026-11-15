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
//!     djinn's single VTE instance without needing a per-widget
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
//! never reaches the compositor. We register that rule unconditionally
//! when opacity < 1.0; at exactly 1.0 (or null) the bg is rendered
//! solid and the CSS would be a no-op anyway.
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

// Pango font descriptions. `from_string` parses a "Family Size" form
// (e.g. "IosevkaTerm 13"). We build that string from the config so we
// don't have to set size via a separate setter call.
extern "c" fn pango_font_description_from_string(
    str: [*:0]const u8,
) *PangoFontDescription;
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
/// `apply` can leave VTE's defaults in place for anything the user
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
    /// built-in palette.
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

fn applyFont(terminal: *VteTerminal, opts: Options) void {
    // Both unset → leave VTE's default in place. We don't synthesize a
    // family name to attach a size to; that would silently override
    // whatever the user's GTK theme picked.
    if (opts.font_family == null and opts.font_size == null) return;

    // Pango substitutes silently when the requested family is missing.
    // Some substitutions (a Nerd Font name → a generic sans, glyph
    // table padded out with CJK ranges) produce the "wide-cell"
    // rendering bug. Check availability up front so a missing font
    // inherited from ghostty doesn't trash legibility.
    var effective_family: ?[]const u8 = opts.font_family;
    if (opts.font_family) |fam| {
        if (!fontFamilyAvailable(fam)) {
            std.debug.print(
                "theme: pango can't resolve font-family '{s}' — falling back to monospace default. Install the font or set terminal.font_family in djinn config.\n",
                .{fam},
            );
            effective_family = null;
        }
    }

    // If we dropped the family but have no size override either,
    // there's nothing meaningful to set — leave VTE's default whole.
    if (effective_family == null and opts.font_size == null) return;

    var buf: [256]u8 = undefined;
    const family = effective_family orelse "monospace";
    const size = opts.font_size orelse 11;
    const spec = std.mem.printSentinel(&buf, "{s} {d:.1}", .{ family, size }, 0) catch return;

    const desc = pango_font_description_from_string(spec.ptr);
    defer pango_font_description_free(desc);
    vte_terminal_set_font(terminal, desc);
}

/// Is `family` installed and known to Pango's default font map?
/// Comparison is ASCII case-insensitive; family names are
/// conventionally Title Case but config files sometimes lower-case
/// them. Returns false on map-empty edge cases (Pango not yet
/// initialized) — caller treats that as "skip the font override".
fn fontFamilyAvailable(family: []const u8) bool {
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

fn applyColors(terminal: *VteTerminal, opts: Options) void {
    const bg_alpha: f32 = if (opts.opacity) |o|
        @floatCast(std.math.clamp(o, 0.0, 1.0))
    else
        1.0;

    var fg_rgba: GdkRGBA = undefined;
    var bg_rgba: GdkRGBA = undefined;
    const fg_ptr: ?*const GdkRGBA = if (opts.foreground) |c| blk: {
        fg_rgba = rgbToGdkRgba(c, 1.0);
        break :blk &fg_rgba;
    } else null;
    // When opacity < 1 but no explicit background was supplied, fall
    // back to a black bg so VTE has something to apply alpha against.
    // The dark fallback matches default_palette[0] (Tomorrow Night–ish
    // background) so users who only set opacity don't see a stark
    // black flash through the transparency.
    const need_bg = opts.background != null or bg_alpha < 1.0;
    const bg_ptr: ?*const GdkRGBA = if (need_bg) blk: {
        const c = opts.background orelse default_palette[0];
        bg_rgba = rgbToGdkRgba(c, bg_alpha);
        break :blk &bg_rgba;
    } else null;

    // Build the palette only if the caller set at least one slot. VTE
    // accepts palette_size = 0 to mean "keep defaults", and we want
    // that path when no palette overrides exist at all — otherwise
    // we'd needlessly stomp VTE's built-in ANSI table with our
    // fallback every launch.
    var has_palette = false;
    for (opts.palette) |slot| {
        if (slot != null) {
            has_palette = true;
            break;
        }
    }

    if (fg_ptr == null and bg_ptr == null and !has_palette) return;

    if (has_palette) {
        var palette: [16]GdkRGBA = undefined;
        for (opts.palette, default_palette, 0..) |slot, fallback, i| {
            const c = slot orelse fallback;
            palette[i] = rgbToGdkRgba(c, 1.0);
        }
        vte_terminal_set_colors(terminal, fg_ptr, bg_ptr, &palette, 16);
        return;
    }

    // No palette override → null + size 0 keeps VTE's built-in ANSI.
    vte_terminal_set_colors(terminal, fg_ptr, bg_ptr, null, 0);
}

fn rgbToGdkRgba(c: Rgb, alpha: f32) GdkRGBA {
    return .{
        .red = @as(f32, @floatFromInt(c.r)) / 255.0,
        .green = @as(f32, @floatFromInt(c.g)) / 255.0,
        .blue = @as(f32, @floatFromInt(c.b)) / 255.0,
        .alpha = alpha,
    };
}

fn applyCursorColor(terminal: *VteTerminal, opts: Options) void {
    const c = opts.cursor orelse return;
    var rgba = rgbToGdkRgba(c, 1.0);
    vte_terminal_set_color_cursor(terminal, &rgba);
}

/// Build the combined theme CSS (padding + window transparency) and
/// install or reload the module-level provider on the default
/// display. First call creates + adds the provider; subsequent calls
/// reload its content in place. CSS shorthand puts vertical first,
/// horizontal second, matching GTK's box model.
///
/// Both buf-print failures and an empty-CSS reload now log + return
/// without touching the provider. The prior shape silently dropped
/// half-written CSS strings on `bufPrint` `NoSpace` and loaded an
/// empty string (no rules) when neither padding nor opacity was
/// set, which silently disabled any previously-applied padding /
/// transparency without the user knowing why.
fn applyCss(opts: Options) void {
    var css_buf: [512]u8 = undefined;
    var css_len: usize = 0;

    if (opts.padding_x != null or opts.padding_y != null) {
        const px: u32 = if (opts.padding_x) |v| @intFromFloat(@max(0.0, v)) else 8;
        const py: u32 = if (opts.padding_y) |v| @intFromFloat(@max(0.0, v)) else 8;
        const w = std.fmt.bufPrint(
            css_buf[css_len..],
            "vte-terminal {{ padding: {d}px {d}px; }}",
            .{ py, px },
        ) catch |err| {
            std.debug.print("theme: padding CSS overflowed buf: {}\n", .{err});
            return;
        };
        css_len += w.len;
    }

    // Transparent window only when opacity actually requests it.
    // GdkRGBA bg-alpha won't reach the compositor without these rules;
    // GTK4 themes paint an opaque background on `window.background`
    // (the default class on every GtkWindow), and the VTE widget node
    // also inherits one. Use longhand `background-color` — GTK4's CSS
    // parser rejects `!important` inside the `background` shorthand
    // ("Junk at end of value") and drops the whole rule on parse
    // error. `background-color` accepts it cleanly. PRIORITY_APPLICATION
    // already beats the default theme; !important only matters against
    // a user-installed gtk.css at PRIORITY_USER (rare).
    if (opts.opacity) |o| {
        if (o < 1.0) {
            const w = std.fmt.bufPrint(
                css_buf[css_len..],
                "window, window.background, window.csd {{ background-color: transparent; background-image: none; }} " ++
                    "window > * {{ background-color: transparent; }} " ++
                    "vte-terminal, vte-terminal.terminal {{ background-color: transparent; }}",
                .{},
            ) catch |err| {
                std.debug.print("theme: opacity CSS overflowed buf: {}\n", .{err});
                return;
            };
            css_len += w.len;
        }
    }

    // Empty buffer = neither padding nor opacity is set. Loading
    // the empty sentinel string into the provider would clear any
    // prior rules — fine if that's what the caller wants, but it's
    // distinct from "first apply with no theme overrides", which
    // should leave the GTK theme defaults alone. Skip the load so
    // we don't perturb the display.
    if (css_len == 0) return;
    if (css_len >= css_buf.len) return;
    css_buf[css_len] = 0;
    const css: [*:0]const u8 = @ptrCast(css_buf[0..css_len :0].ptr);

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

    gtk_css_provider_load_from_string(g_css_provider.?, css);
}

// ─── Tests ───────────────────────────────────────────────────────────

test "Theme native API compiles without opening a display" {
    std.testing.refAllDecls(@This());
}

test "rgbToGdkRgba: channel mapping" {
    const c = rgbToGdkRgba(.{ .r = 0x1a, .g = 0x2b, .b = 0x3c }, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0x1a) / 255.0, c.red, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0x2b) / 255.0, c.green, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0x3c) / 255.0, c.blue, 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), c.alpha);
}
