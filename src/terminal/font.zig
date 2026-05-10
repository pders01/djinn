//! CoreText font resolution + cell-metric derivation.
//!
//! `buildFont` resolves a family name + point size to a CTFontRef and
//! returns the cell metrics djinn paints with. The resolution path is
//! defensive: CTFontCreateWithFontDescriptor will substitute the
//! system UI face when the family doesn't match anything installed,
//! and the substitute can ship with very different metrics. So we
//! validate the resolved family name against the request and warn on
//! every mismatch — silent fallback is the failure mode we want
//! visible.

const std = @import("std");

pub const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
});

/// Successful-resolution log fires once per process. buildFont gets
/// called from TerminalView.init + Cmd+/- font zoom + theme reload —
/// repeat lines just clutter logs once we've confirmed the family
/// resolves.
var g_font_resolved_logged: bool = false;

/// Resolved font + cell metrics. Returned by buildFont so the same
/// logic drives both first-time init and Cmd+/- runtime resize.
pub const Metrics = struct {
    font: cg.CTFontRef,
    cell_w: f64,
    cell_h: f64,
    baseline: f64,
};

/// Build a CTFont from a family name + point size, then derive the cell
/// metrics djinn uses (advance for 'M' is the cell width; ascent +
/// descent + leading rounded up is the cell height; descent doubles as
/// the baseline offset since CG y grows up).
///
/// Resolution strategy — `CTFontCreateWithFontDescriptor` happily
/// returns a substitute font (often the system UI face) when the
/// descriptor doesn't match anything installed, so a `null` check
/// alone misses silent fallbacks. We instead:
///   1. Build a family-name descriptor + Regular style attribute so
///      ambiguous installs (e.g. Iosevka + Iosevka Bold both present)
///      pick the upright face deterministically.
///   2. Run it through `CTFontDescriptorCreateMatchingFontDescriptor`,
///      which returns null when nothing real matches — that's our cue
///      to try the PostScript-name fallback.
///   3. After font creation, copy the resolved face's family name and
///      compare to the request. A mismatch logs a visible warning so
///      the user notices a wrong font instead of staring at a clashing
///      render and assuming djinn just looks different from ghostty.
pub fn buildFont(name: []const u8, size: f64) !Metrics {
    const cf_name = cg.CFStringCreateWithBytes(
        null,
        @ptrCast(name.ptr),
        @intCast(name.len),
        cg.kCFStringEncodingUTF8,
        0,
    ) orelse return error.FontNameFailed;
    defer cg.CFRelease(cf_name);

    const cf_regular = cg.CFStringCreateWithBytes(
        null,
        @ptrCast("Regular".ptr),
        7,
        cg.kCFStringEncodingUTF8,
        0,
    ) orelse return error.FontNameFailed;
    defer cg.CFRelease(cf_regular);

    const font = resolveFont(cf_name, cf_regular, size) orelse return error.FontCreate;

    var fam_buf: [128]u8 = undefined;
    var ps_buf: [128]u8 = undefined;
    var style_buf: [64]u8 = undefined;
    const fam_len = copyCtFontFamilyName(font, &fam_buf);
    const ps_len = copyCtFontName(font, cg.kCTFontPostScriptNameKey, &ps_buf);
    const style_len = copyCtFontName(font, cg.kCTFontStyleNameKey, &style_buf);
    const actual_family = fam_buf[0..fam_len];
    const actual_ps = ps_buf[0..ps_len];
    const actual_style = style_buf[0..style_len];
    if (!asciiEqIgnoreCaseTrim(actual_family, name)) {
        // Substitution always logs — silent fallback is the bug we're
        // detecting, so the user has to see it every time.
        std.debug.print(
            "warning: font \"{s}\" not installed; rendering with substitute \"{s}\" ({s}, {s}). Check ~/.config/djinn/config or ~/.config/ghostty/config.\n",
            .{ name, actual_family, actual_ps, actual_style },
        );
    } else if (!g_font_resolved_logged) {
        g_font_resolved_logged = true;
        std.debug.print("font: {s} ({s}, {s})\n", .{ actual_family, actual_ps, actual_style });
    }

    const ascent = cg.CTFontGetAscent(font);
    const descent = cg.CTFontGetDescent(font);
    const leading = cg.CTFontGetLeading(font);
    const cell_h = @ceil(ascent + descent + leading);

    var ch_m: cg.UniChar = 'M';
    var glyph: cg.CGGlyph = 0;
    _ = cg.CTFontGetGlyphsForCharacters(font, &ch_m, &glyph, 1);
    var advance: cg.CGSize = .{ .width = 0, .height = 0 };
    _ = cg.CTFontGetAdvancesForGlyphs(font, cg.kCTFontOrientationDefault, &glyph, &advance, 1);
    const cell_w = @ceil(advance.width);

    return .{
        .font = font,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .baseline = descent,
    };
}

fn resolveFont(cf_name: cg.CFStringRef, cf_regular: cg.CFStringRef, size: f64) ?cg.CTFontRef {
    // Family + Regular-style descriptor. Style attr tie-breaks on
    // multi-face installs so we don't accidentally pick Bold or Italic.
    const keys: [2]?*const anyopaque = .{
        @ptrCast(cg.kCTFontFamilyNameAttribute),
        @ptrCast(cg.kCTFontStyleNameAttribute),
    };
    const values: [2]?*const anyopaque = .{ @ptrCast(cf_name), @ptrCast(cf_regular) };
    const attrs = cg.CFDictionaryCreate(
        null,
        @ptrCast(@constCast(&keys)),
        @ptrCast(@constCast(&values)),
        2,
        &cg.kCFTypeDictionaryKeyCallBacks,
        &cg.kCFTypeDictionaryValueCallBacks,
    );

    if (attrs != null) {
        defer cg.CFRelease(attrs);
        if (cg.CTFontDescriptorCreateWithAttributes(attrs)) |desc| {
            defer cg.CFRelease(desc);
            // CreateMatchingFontDescriptor returns null when no installed
            // face matches the family. That's the substitution signal we
            // need — CTFontCreateWithFontDescriptor would fall back to the
            // system face silently.
            if (cg.CTFontDescriptorCreateMatchingFontDescriptor(desc, null)) |matched| {
                defer cg.CFRelease(matched);
                if (cg.CTFontCreateWithFontDescriptor(matched, size, null)) |f| return f;
            }
        }
    }

    // PostScript-name fallback. CTFontCreateWithName ignores spaces
    // gracefully on some macOS versions and returns null when the name
    // doesn't resolve at all, so we surface that as our error.
    return cg.CTFontCreateWithName(cf_name, size, null);
}

fn copyCtFontFamilyName(font: cg.CTFontRef, out: []u8) usize {
    const cf = cg.CTFontCopyFamilyName(font);
    if (cf == null) return 0;
    defer cg.CFRelease(cf);
    return cfStringToUtf8(cf, out);
}

fn copyCtFontName(font: cg.CTFontRef, key: cg.CFStringRef, out: []u8) usize {
    const cf = cg.CTFontCopyName(font, key);
    if (cf == null) return 0;
    defer cg.CFRelease(cf);
    return cfStringToUtf8(cf, out);
}

fn cfStringToUtf8(cf: cg.CFStringRef, out: []u8) usize {
    const length = cg.CFStringGetLength(cf);
    const range = cg.CFRange{ .location = 0, .length = length };
    var converted: cg.CFIndex = 0;
    _ = cg.CFStringGetBytes(
        cf,
        range,
        cg.kCFStringEncodingUTF8,
        0,
        0,
        out.ptr,
        @intCast(out.len),
        &converted,
    );
    return @intCast(converted);
}

fn asciiEqIgnoreCaseTrim(a: []const u8, b: []const u8) bool {
    const trim = std.mem.trim;
    const ws = " \t\r\n";
    const ta = trim(u8, a, ws);
    const tb = trim(u8, b, ws);
    return std.ascii.eqlIgnoreCase(ta, tb);
}
