const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const ghostty_runtime = @import("../ghostty/runtime.zig");
const AgentState = @import("../agent/state.zig").AgentState;
const Agent = @import("../agent/state.zig").Agent;
const LogView = @import("../agent/log_view.zig").LogView;
const Menubar = @import("../notify/menubar.zig").Menubar;
const MenubarAgentState = @import("../notify/menubar.zig").AgentState;
const menubar_mod = @import("../notify/menubar.zig");
const tis = @import("tis.zig");
const chrome_mod = @import("../chrome.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
});

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

/// Sentinel returned by NSTextInputClient methods when there's no value
/// (e.g. markedRange when nothing's composing). `kCFNotFound`/`NSNotFound`
/// = NSIntegerMax = (1 << 63) - 1 on 64-bit darwin.
const ns_not_found: c_ulong = (@as(c_ulong, 1) << 63) - 1;

// Module-private state lives here; everything cross-callback flows through
// `app.g`. `g_class_registered` and the PTY read buffer stay local because
// they're implementation details of view-class registration / drain — no
// other module reads them.
var g_class_registered: bool = false;
var g_chip_cell_class_registered: bool = false;
var g_divider_class_registered: bool = false;

/// Visible + grabbable width of the log/terminal divider. Wide enough
/// for a reliable mouse hit (1px is too narrow on dense displays);
/// alpha keeps the visible band reading as a hairline.
pub const divider_width: f64 = 4.0;

var g_font_resolved_logged: bool = false;

/// Forward a UTF-8 text blob to the ghostty surface (paste / drop /
/// IME commit / unmapped-key fallback path). Returns false when the
/// surface isn't bound yet — caller decides whether that's a hard
/// failure (drag-drop) or silent (key fallback).
fn forwardText(text: []const u8) bool {
    const surf_ptr = app.g.ghostty_surface orelse return false;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_text(surf, text.ptr, text.len);
    return true;
}

/// Forward IME preedit (in-progress composition) to the ghostty
/// surface so it paints the underline overlay at the cursor cell.
/// Empty slice clears the composition.
fn forwardPreedit(text: []const u8) void {
    const surf_ptr = app.g.ghostty_surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_preedit(surf, text.ptr, text.len);
}

/// Trigger a ghostty binding action by its parsed string form
/// (e.g. "search:foo", "navigate_search:next", "end_search").
fn forwardBindingAction(action_str: []const u8) void {
    const surf_ptr = app.g.ghostty_surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    _ = ghostty_runtime.c.ghostty_surface_binding_action(surf, action_str.ptr, action_str.len);
}

/// Re-render the find-overlay display field from current state.
/// Three styled runs: dim "find " label, fg needle, dim count. Layout
/// echoes the log-pane "ACTIVITY" header idiom so the find overlay
/// reads as the same chrome family rather than a stray native field.
pub fn updateSearchCountLabel() void {
    const fid = app.g.search_field_id orelse return;
    const tf = objc.Object.fromId(fid);
    if (!app.g.find_mode) {
        tf.msgSend(void, "setHidden:", .{@as(c_int, 1)});
        return;
    }
    const style = app.g.chrome_style orelse return;

    const needle = app.g.search_query_buf[0..app.g.search_query_len];
    var count_buf: [32]u8 = undefined;
    const count_str: []const u8 = blk: {
        if (app.g.search_total) |total| {
            const sel_disp: u32 = if (app.g.search_selected) |s| s + 1 else 0;
            break :blk std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ sel_disp, total }) catch "";
        }
        break :blk "";
    };

    const NSAttributedString = objc.getClass("NSMutableAttributedString") orelse return;
    const root_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const root = root_alloc.msgSend(objc.Object, "init", .{});

    // Format mirrors log-entry headers (`{client} · {hh:mm}`) — middle
    // dot separators, dim accent text, fg body. Same idiom, different
    // chrome surface.
    appendFindRun(root, "find", style.chip.dim, style);
    if (needle.len > 0) {
        appendFindRun(root, " · ", style.chip.dim, style);
        appendFindRun(root, needle, style.chip.fg, style);
    }
    if (count_str.len > 0) {
        appendFindRun(root, " · ", style.chip.dim, style);
        appendFindRun(root, count_str, style.chip.dim, style);
    }

    tf.msgSend(void, "setAttributedStringValue:", .{root});

    // Auto-size width to content + horizontal padding. Re-anchor at
    // top-right of parent so the chip grows leftward, not rightward
    // off-screen. h is fixed; only width tracks content.
    const text_size = root.msgSend(NSSize, "size", .{});
    const pad_x: f64 = 24; // 12px each side — breathing room for the dim runs
    const tf_h: f64 = 22;
    const margin: f64 = 14;
    const new_w = @ceil(text_size.width) + pad_x;
    const parent = tf.msgSend(objc.Object, "superview", .{});
    if (parent.value != null) {
        const parent_frame = parent.msgSend(NSRect, "frame", .{});
        const new_frame = NSRect{
            .origin = .{
                .x = parent_frame.size.width - new_w - margin,
                .y = parent_frame.size.height - tf_h - margin,
            },
            .size = .{ .width = new_w, .height = tf_h },
        };
        tf.msgSend(void, "setFrame:", .{new_frame});
    }

    tf.msgSend(void, "setHidden:", .{@as(c_int, 0)});
}

/// Append one styled run to the find-overlay's attributed string.
/// Center-aligned, system UI font at semibold weight — chip typography
/// sits on a different axis from the terminal so the overlay doesn't
/// blend into the surface text behind it.
fn appendFindRun(root: objc.Object, text: []const u8, color: chrome_mod.Rgb, style: chrome_mod.Style) void {
    const NSString = objc.getClass("NSString") orelse return;
    const NSColor = objc.getClass("NSColor") orelse return;
    const NSDictionary = objc.getClass("NSDictionary") orelse return;
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSParagraphStyle = objc.getClass("NSMutableParagraphStyle") orelse return;

    var stack: [257]u8 = undefined;
    const take = @min(text.len, stack.len - 1);
    @memcpy(stack[0..take], text[0..take]);
    stack[take] = 0;
    const ns_text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, &stack)});

    const font = chrome_mod.chromeFont(NSFont, style.font_family, style.font_size_chip);
    const ns_color = chrome_mod.nsColorFromRgb(NSColor, color);

    // NSCenterTextAlignment = 2. NSTextField paints the cell vertically
    // centered already; horizontal center keeps the chip balanced even
    // when needle length changes (no jitter).
    const para = NSParagraphStyle.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    para.msgSend(void, "setAlignment:", .{@as(c_long, 2)});

    const fg_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSColor")});
    const font_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSFont")});
    const para_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSParagraphStyle")});
    const objects = [_]objc.c.id{ ns_color.value, font.value, para.value };
    const keys = [_]objc.c.id{ fg_key.value, font_key.value, para_key.value };
    const dict = NSDictionary.msgSend(
        objc.Object,
        "dictionaryWithObjects:forKeys:count:",
        .{ &objects, &keys, @as(c_ulong, 3) },
    );

    const attr_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const attr = attr_alloc.msgSend(objc.Object, "initWithString:attributes:", .{ ns_text, dict });
    root.msgSend(void, "appendAttributedString:", .{attr});
}

/// Set the NSFont on the find-overlay textfield. Bare-string fallback
/// before updateSearchCountLabel pushes the styled attributed value.
fn applyFindOverlayFont(tf: objc.Object, style: chrome_mod.Style) void {
    const NSFont = objc.getClass("NSFont") orelse return;
    tf.msgSend(void, "setFont:", .{chrome_mod.chromeFont(NSFont, style.font_family, style.font_size_chip)});
}

/// Reskin the find-overlay chip after a theme reload. Layer bg + font
/// flip immediately; the per-run colors of the next setAttributedStringValue
/// pick up `style.chip.*` automatically since updateSearchCountLabel
/// reads `app.g.chrome_style` on every call.
pub fn applyFindOverlayStyle(style: chrome_mod.Style) void {
    const fid = app.g.search_field_id orelse return;
    const tf = objc.Object.fromId(fid);
    const NSColor = objc.getClass("NSColor") orelse return;
    tf.msgSend(void, "setBackgroundColor:", .{chrome_mod.nsColorFromRgb(NSColor, style.chip.bg)});
    tf.msgSend(void, "setTextColor:", .{chrome_mod.nsColorFromRgb(NSColor, style.chip.fg)});
    applyFindOverlayFont(tf, style);
    if (app.g.find_mode) updateSearchCountLabel();
}

pub const TerminalView = struct {
    view: objc.Object,
    cell_w: f64,
    cell_h: f64,

    pub fn init(
        width: f64,
        height: f64,
        font_name: []const u8,
        font_size: f64,
        padding_x: f64,
        padding_y: f64,
        bg_alpha: f64,
        style: chrome_mod.Style,
    ) !TerminalView {
        registerClass();

        const metrics = try buildFont(font_name, font_size);

        const TerminalViewClass = objc.getClass("DjinnTerminalView") orelse return error.ClassNotFound;
        const alloc = TerminalViewClass.msgSend(objc.Object, "alloc", .{});
        const frame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        };
        const view = alloc.msgSend(objc.Object, "initWithFrame:", .{frame});

        // Force a layer-backed view with explicit contents scale tracking.
        // On Retina, an implicitly-backed NSView captures drawRect at 1x
        // and AppKit upscales, which is what produced the "lowered
        // resolution" look. setWantsLayer:YES + a viewDidChangeBackingProperties
        // hook keeps layer.contentsScale matched to the window's
        // backingScaleFactor so glyph runs hit native pixels.
        view.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});

        app.g.font = @ptrCast(metrics.font);
        app.g.view_id = view.value;
        app.g.font_family = font_name;
        app.g.font_size = font_size;
        app.g.cell_w = metrics.cell_w;
        app.g.cell_h = metrics.cell_h;
        app.g.baseline = metrics.baseline;
        app.g.padding_x = padding_x;
        app.g.padding_y = padding_y;
        app.g.bg_alpha = bg_alpha;

        // Drag-drop types: file URLs (Finder), and raw image data (PNG/
        // TIFF) so screenshots / Photos / browser image drags also reach
        // performDragOperation. We save image bytes to /tmp and paste
        // the path so CC's Read tool can pick the file up.
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        const NSArray = objc.getClass("NSArray") orelse return error.ClassNotFound;
        const file_url_type = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.file-url")});
        const png_type = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.png")});
        const tiff_type = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.tiff")});
        const type_array: [3]objc.c.id = .{ file_url_type.value.?, png_type.value.?, tiff_type.value.? };
        const types = NSArray.msgSend(objc.Object, "arrayWithObjects:count:", .{
            @as([*c]const objc.c.id, &type_array),
            @as(c_ulong, 3),
        });
        view.msgSend(void, "registerForDraggedTypes:", .{types});

        // NSTrackingArea — without this, mouseMoved: only fires while the
        // window has acceptsMouseMovedEvents:YES set. The InVisibleRect
        // option means AppKit auto-resizes the area when the view's
        // bounds change, so we never have to update it on resize.
        // Flags:
        //   NSTrackingMouseMoved        = 0x002
        //   NSTrackingActiveAlways      = 0x080
        //   NSTrackingInVisibleRect     = 0x200
        const NSTrackingArea = objc.getClass("NSTrackingArea") orelse return error.ClassNotFound;
        const ta_alloc = NSTrackingArea.msgSend(objc.Object, "alloc", .{});
        const ta_opts: c_ulong = 0x002 | 0x080 | 0x200;
        const ta_rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        const ta = ta_alloc.msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
            ta_rect,
            ta_opts,
            view.value,
            @as(?*anyopaque, null),
        });
        view.msgSend(void, "addTrackingArea:", .{ta});

        // Find-overlay NSTextField — read-only display. Find mode
        // routes keys via our keyDownImpl, not via field editor; this
        // field only shows the needle + match count. Hidden until
        // Cmd+F. NSViewMinXMargin (1) + NSViewMinYMargin (32) pins
        // top-right on resize. Colors come from `chrome.Style` so the
        // overlay tracks the same palette as the log pane and reskins
        // alongside it on appearance flips.
        // Find chip: lifted bg, no border, full-pill cornerRadius.
        // Width auto-sizes to content in updateSearchCountLabel — the
        // initial frame here just reserves a slot in the responder
        // chain and an initial position.
        registerChipCellClass();
        const NSTextField = objc.getClass("NSTextField") orelse return error.ClassNotFound;
        const NSColor_tf = objc.getClass("NSColor") orelse return error.ClassNotFound;
        const tf_alloc = NSTextField.msgSend(objc.Object, "alloc", .{});
        const tf_h: f64 = 22;
        const tf_margin: f64 = 14;
        const tf_init_w: f64 = 80;
        const tf_frame = NSRect{
            .origin = .{ .x = width - tf_init_w - tf_margin, .y = height - tf_h - tf_margin },
            .size = .{ .width = tf_init_w, .height = tf_h },
        };
        const tf = tf_alloc.msgSend(objc.Object, "initWithFrame:", .{tf_frame});
        // DjinnChipCell vertically centers the attributed text — stock
        // NSTextFieldCell baselines at top.
        const ChipCellClass = objc.getClass("DjinnChipCell") orelse return error.ClassNotFound;
        const cell_alloc = ChipCellClass.msgSend(objc.Object, "alloc", .{});
        const cell = cell_alloc.msgSend(objc.Object, "init", .{});
        tf.msgSend(void, "setCell:", .{cell});
        tf.msgSend(void, "setBezeled:", .{@as(c_int, 0)});
        tf.msgSend(void, "setEditable:", .{@as(c_int, 0)});
        tf.msgSend(void, "setSelectable:", .{@as(c_int, 0)});
        tf.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
        tf.msgSend(void, "setHidden:", .{@as(c_int, 1)});
        // NSViewMinXMargin (1) + NSViewMinYMargin (32) — pinned
        // top-right under live resize. Width is dynamic so the
        // autoresize mask doesn't need to track height/width.
        tf.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 | 32)});
        const tf_cell = tf.msgSend(objc.Object, "cell", .{});
        if (tf_cell.value != null) {
            tf_cell.msgSend(void, "setUsesSingleLineMode:", .{@as(c_int, 1)});
            // NSLineBreakByClipping = 4. Stops the cell from shrinking
            // text to fit when the needle gets long.
            tf_cell.msgSend(void, "setLineBreakMode:", .{@as(c_long, 4)});
        }
        tf.msgSend(void, "setBackgroundColor:", .{chrome_mod.nsColorFromRgb(NSColor_tf, style.chip.bg)});
        tf.msgSend(void, "setTextColor:", .{chrome_mod.nsColorFromRgb(NSColor_tf, style.chip.fg)});
        // Full pill: cornerRadius = h/2. masksToBounds clips the bg
        // fill to the rounded shape regardless of NSCell drawing.
        tf.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
        const tf_layer = tf.msgSend(objc.Object, "layer", .{});
        if (tf_layer.value != null) {
            // 4px round, not a full pill. Matches the log pane's flat
            // chrome — chip and log read as the same surface family,
            // not a pill floating over a slab.
            tf_layer.msgSend(void, "setCornerRadius:", .{@as(f64, 4)});
            tf_layer.msgSend(void, "setMasksToBounds:", .{@as(c_int, 1)});
        }
        view.msgSend(void, "addSubview:", .{tf});
        app.g.search_field_id = tf.value;
        applyFindOverlayFont(tf, style);

        return .{ .view = view, .cell_w = metrics.cell_w, .cell_h = metrics.cell_h };
    }

    pub fn gridSize(self: TerminalView, width: f64, height: f64) struct { cols: u16, rows: u16 } {
        const usable_w = @max(1.0, width - 2 * app.g.padding_x);
        const usable_h = @max(1.0, height - 2 * app.g.padding_y);
        const cols: u16 = @max(1, @as(u16, @intFromFloat(@floor(usable_w / self.cell_w))));
        const rows: u16 = @max(1, @as(u16, @intFromFloat(@floor(usable_h / self.cell_h))));
        return .{ .cols = cols, .rows = rows };
    }

    pub fn attach(self: *TerminalView) void {
        _ = self;
        startTickTimer();
    }

    pub fn observeAgent(self: *TerminalView, state: *AgentState, menubar: *Menubar) void {
        _ = self;
        app.g.agent_state = state;
        app.g.menubar = menubar;
    }

    pub fn observeLog(self: *TerminalView, log_view: *LogView) void {
        _ = self;
        app.g.log_view = log_view;
    }
};

/// Resolved font + cell metrics. Returned by buildFont so the same logic
/// drives both first-time init and Cmd+/- runtime resize.
const FontMetrics = struct {
    font: cg.CTFontRef,
    cell_w: f64,
    cell_h: f64,
    baseline: f64,
};

/// Build a CTFont from a family name + point size, then derive the cell
/// metrics djinn uses (advance for 'M' is the cell width; ascent + descent
/// + leading rounded up is the cell height; descent doubles as the
/// baseline offset since CG y grows up).
///
/// Resolution strategy — `CTFontCreateWithFontDescriptor` happily returns
/// a substitute font (often the system UI face) when the descriptor
/// doesn't match anything installed, so a `null` check alone misses
/// silent fallbacks. We instead:
///   1. Build a family-name descriptor + Regular style attribute so
///      ambiguous installs (e.g. Iosevka + Iosevka Bold both present) pick
///      the upright face deterministically.
///   2. Run it through `CTFontDescriptorCreateMatchingFontDescriptor`,
///      which returns null when nothing real matches — that's our cue
///      to try the PostScript-name fallback.
///   3. After font creation, copy the resolved face's family name and
///      compare to the request. A mismatch logs a visible warning so
///      the user notices a wrong font instead of staring at a clashing
///      render and assuming djinn just looks different from ghostty.
fn buildFont(name: []const u8, size: f64) !FontMetrics {
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
    if (!ascii_eq_ignore_case_trim(actual_family, name)) {
        // Substitution always logs — silent fallback is the bug we're
        // detecting, so the user has to see it every time.
        std.debug.print(
            "warning: font \"{s}\" not installed; rendering with substitute \"{s}\" ({s}, {s}). Check ~/.config/djinn/config or ~/.config/ghostty/config.\n",
            .{ name, actual_family, actual_ps, actual_style },
        );
    } else if (!g_font_resolved_logged) {
        // Successful resolution prints once per process. buildFont gets
        // called from TerminalView.init + LogView.init (not yet) +
        // Cmd+/- font zoom + theme reload — repeat lines just clutter
        // logs once we've confirmed the family resolves.
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

fn ascii_eq_ignore_case_trim(a: []const u8, b: []const u8) bool {
    const trim = std.mem.trim;
    const ws = " \t\r\n";
    const ta = trim(u8, a, ws);
    const tb = trim(u8, b, ws);
    return std.ascii.eqlIgnoreCase(ta, tb);
}

/// Build the resizable divider NSView between terminal + log pane.
/// Subclasses NSView as `DjinnDivider` to host mouseDown/Dragged/Up
/// + resetCursorRects so the user can drag-to-resize the log column.
pub fn createDivider(term_w: f64, height: f64) objc.Object {
    registerDividerClass();
    const cls = objc.getClass("DjinnDivider") orelse unreachable;
    const alloc = cls.msgSend(objc.Object, "alloc", .{});
    const div = alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = term_w, .y = 0 },
        .size = .{ .width = divider_width, .height = height },
    }});
    div.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    const NSColor = objc.getClass("NSColor") orelse return div;
    const div_color = NSColor.msgSend(objc.Object, "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, 1.0), @as(f64, 1.0), @as(f64, 1.0), @as(f64, 0.05),
    });
    const layer = div.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        layer.msgSend(void, "setBackgroundColor:", .{div_color.msgSend(?*anyopaque, "CGColor", .{})});
    }
    // MinXMargin | HeightSizable — divider tracks its x relative to the
    // right edge as the panel resizes.
    div.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 0) | (1 << 4))});
    return div;
}

fn registerDividerClass() void {
    if (g_divider_class_registered) return;
    g_divider_class_registered = true;
    const NSView = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(NSView, "DjinnDivider") orelse return;
    _ = cls.addMethod("mouseDown:", dividerMouseDownImpl);
    _ = cls.addMethod("mouseDragged:", dividerMouseDraggedImpl);
    _ = cls.addMethod("mouseUp:", dividerMouseUpImpl);
    _ = cls.addMethod("resetCursorRects", dividerResetCursorRectsImpl);
    _ = cls.addMethod("acceptsFirstMouse:", dividerAcceptsFirstMouseImpl);
    objc.registerClassPair(cls);
}

fn dividerAcceptsFirstMouseImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) c_int {
    // Return YES so the first click on a non-key window starts the drag
    // immediately, instead of being consumed by the window-activation
    // hit-test. Borderless NSPanel can lose key state on focus shifts.
    return 1;
}

fn dividerMouseDownImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // No-op — `mouseDragged:` does the actual layout work each tick.
    // Implementing the selector at all is what tells AppKit we want
    // mouse events; without it the divider is transparent to clicks.
}

fn dividerMouseUpImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // Persist the new fraction so subsequent toggles + resizes use it.
    const cfg = app.g.config orelse return;
    const lv = app.g.log_view orelse return;
    const log_frame = lv.view.msgSend(NSRect, "frame", .{});
    const container = lv.view.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;
    const c_bounds = container.msgSend(NSRect, "bounds", .{});
    if (c_bounds.size.width <= 0) return;
    cfg.log_pane.width_fraction = log_frame.size.width / c_bounds.size.width;
}

fn dividerMouseDraggedImpl(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const div = objc.Object.fromId(self);
    const container = div.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;
    const ev = objc.Object.fromId(event);
    const win_loc = ev.msgSend(NSPoint, "locationInWindow", .{});
    const cont_loc = container.msgSend(NSPoint, "convertPoint:fromView:", .{ win_loc, @as(?*anyopaque, null) });

    const c_bounds = container.msgSend(NSRect, "bounds", .{});
    const cfg = app.g.config orelse return;

    // Cursor x in container coords = the new term_w boundary. Log
    // takes whatever is right of that (minus the divider band).
    var new_log_w = c_bounds.size.width - cont_loc.x - divider_width;
    new_log_w = @max(cfg.log_pane.width_min, @min(cfg.log_pane.width_max, new_log_w));
    const new_term_w = @max(1.0, c_bounds.size.width - new_log_w - divider_width);
    applyLogLayout(container, new_term_w, new_log_w, c_bounds.size.height);
}

fn dividerResetCursorRectsImpl(self: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const div = objc.Object.fromId(self);
    const NSCursor = objc.getClass("NSCursor") orelse return;
    const cursor = NSCursor.msgSend(objc.Object, "resizeLeftRightCursor", .{});
    const bounds = div.msgSend(NSRect, "bounds", .{});
    div.msgSend(void, "addCursorRect:cursor:", .{ bounds, cursor });
}

/// Reflow terminal + divider + log + surface_host frames to a new
/// split. Shared between drag-to-resize + log-pane toggle so the
/// layout invariants live in one place.
fn applyLogLayout(container: objc.Object, term_w: f64, log_w: f64, height: f64) void {
    const view_id = app.g.view_id orelse return;
    const term_view = objc.Object.fromId(view_id);
    term_view.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = term_w, .height = height },
    }});
    if (app.g.divider_view_id) |did| {
        objc.Object.fromId(did).msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = term_w, .y = 0 },
            .size = .{ .width = if (log_w > 0) divider_width else 0, .height = height },
        }});
    }
    if (app.g.log_view) |lv| {
        const div_w: f64 = if (log_w > 0) divider_width else 0;
        lv.view.msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = term_w + div_w, .y = 0 },
            .size = .{ .width = log_w, .height = height },
        }});
    }
    // Reflow every session's surface_host so inactive sessions stay
    // sized identically to the active one (autoresizingMask covers
    // window resize; this covers term/log split changes from
    // setLogPaneHidden + drag-to-resize). main() guarantees the
    // session_manager pointer is set before any caller of
    // applyLogLayout fires; no fallback path needed.
    if (app.g.session_manager) |sm| {
        for (sm.sessions) |sess| {
            if (sess.surface_host) |sid| {
                objc.Object.fromId(sid).msgSend(void, "setFrame:", .{NSRect{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{ .width = term_w, .height = height },
                }});
            }
        }
    }
    checkResize(term_view);
    container.msgSend(void, "setNeedsLayout:", .{@as(c_int, 1)});
    container.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
}

/// Register `DjinnChipCell : NSTextFieldCell` once. The override
/// vertically centers attributed text within the cell rect — stock
/// NSTextFieldCell baselines at the top regardless of
/// `usesSingleLineMode`, which leaves chip text floating above center.
fn registerChipCellClass() void {
    if (g_chip_cell_class_registered) return;
    g_chip_cell_class_registered = true;

    const superclass = objc.getClass("NSTextFieldCell") orelse return;
    const cls = objc.allocateClassPair(superclass, "DjinnChipCell") orelse return;
    _ = cls.addMethod("drawInteriorWithFrame:inView:", drawChipInteriorImpl);
    objc.registerClassPair(cls);
}

fn drawChipInteriorImpl(
    self: objc.c.id,
    _: objc.c.SEL,
    frame: NSRect,
    control_view: objc.c.id,
) callconv(.c) void {
    _ = control_view;
    const cell = objc.Object.fromId(self);
    const attr = cell.msgSend(objc.Object, "attributedStringValue", .{});
    if (attr.value == null) return;
    const text_size = attr.msgSend(NSSize, "size", .{});

    // Center on both axes. Frame is sized to text + horizontal padding
    // by updateSearchCountLabel, so horizontal centering yields equal
    // padding on each side regardless of needle length.
    var rect = frame;
    if (text_size.height < frame.size.height) {
        rect.origin.y = frame.origin.y + (frame.size.height - text_size.height) / 2.0;
        rect.size.height = text_size.height;
    }
    if (text_size.width < frame.size.width) {
        rect.origin.x = frame.origin.x + (frame.size.width - text_size.width) / 2.0;
        rect.size.width = text_size.width;
    }
    attr.msgSend(void, "drawInRect:", .{rect});
}

fn registerClass() void {
    if (g_class_registered) return;
    g_class_registered = true;

    const superclass = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(superclass, "DjinnTerminalView") orelse return;
    _ = cls.addMethod("acceptsFirstResponder", acceptsFirstResponderImpl);
    _ = cls.addMethod("keyDown:", keyDownImpl);
    _ = cls.addMethod("tick:", tickImpl);
    _ = cls.addMethod("mouseDown:", mouseDownImpl);
    _ = cls.addMethod("mouseDragged:", mouseDraggedImpl);
    _ = cls.addMethod("mouseUp:", mouseUpImpl);
    _ = cls.addMethod("mouseMoved:", mouseMovedImpl);
    _ = cls.addMethod("scrollWheel:", scrollWheelImpl);
    _ = cls.addMethod("viewDidEndLiveResize", viewDidEndLiveResizeImpl);
    _ = cls.addMethod("viewDidChangeBackingProperties", viewDidChangeBackingPropertiesImpl);
    _ = cls.addMethod("viewDidMoveToWindow", viewDidMoveToWindowImpl);
    _ = cls.addMethod("viewDidChangeEffectiveAppearance", viewDidChangeEffectiveAppearanceImpl);
    _ = cls.addMethod("resetCursorRects", resetCursorRectsImpl);
    // Drag-drop: NSDraggingDestination protocol — file URLs paste as text.
    _ = cls.addMethod("draggingEntered:", draggingEnteredImpl);
    _ = cls.addMethod("performDragOperation:", performDragOperationImpl);
    // NSTextInputClient — wires IME for non-Latin input. AppKit calls
    // back into these in response to inputContext.handleEvent: from
    // keyDownImpl. Without these the view is invisible to input
    // sources (Korean/Japanese/Chinese), pinyin candidates, dead keys.
    _ = cls.addMethod("insertText:replacementRange:", insertTextImpl);
    _ = cls.addMethod("doCommandBySelector:", doCommandBySelectorImpl);
    _ = cls.addMethod("setMarkedText:selectedRange:replacementRange:", setMarkedTextImpl);
    _ = cls.addMethod("unmarkText", unmarkTextImpl);
    _ = cls.addMethod("selectedRange", selectedRangeImpl);
    _ = cls.addMethod("markedRange", markedRangeImpl);
    _ = cls.addMethod("hasMarkedText", hasMarkedTextImpl);
    _ = cls.addMethod("attributedSubstringForProposedRange:actualRange:", attributedSubstringForProposedRangeImpl);
    _ = cls.addMethod("validAttributesForMarkedText", validAttributesForMarkedTextImpl);
    _ = cls.addMethod("firstRectForCharacterRange:actualRange:", firstRectForCharacterRangeImpl);
    _ = cls.addMethod("characterIndexForPoint:", characterIndexForPointImpl);
    // NSControl text-field delegate methods for the find-overlay
    // NSTextField. controlTextDidChange:: live-updates matches; the
    // command-by-selector hook swallows Esc / Return so we hide the
    // overlay instead of beeping.
    // Declare protocol conformance so NSView returns a non-nil
    // -inputContext (interpretKeyEvents: requires an input client).
    // Without this, AppKit treats the view as a plain NSResponder and
    // `interpretKeyEvents:` no-ops + emits the "no input system" beep
    // on every keystroke.
    if (objc.getProtocol("NSTextInputClient")) |proto| {
        _ = objc.c.class_addProtocol(cls.value, proto.value);
    }
    objc.registerClassPair(cls);
}

/// Sync the backing layer's contentsScale to the screen the window now lives
/// on. AppKit fires viewDidChangeBackingProperties on screen change and on
/// initial window attach. Without this, a Retina (2x) display shows our
/// drawRect output at 1x scaled up — "blurry / low res" terminal text.
fn syncLayerScale(view: objc.Object) void {
    const window = view.msgSend(objc.Object, "window", .{});
    if (window.value == null) return;
    const scale: f64 = window.msgSend(f64, "backingScaleFactor", .{});
    if (scale <= 0) return;
    const layer = view.msgSend(objc.Object, "layer", .{});
    if (layer.value == null) return;
    layer.msgSend(void, "setContentsScale:", .{scale});
}

fn viewDidChangeBackingPropertiesImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    syncLayerScale(objc.Object.fromId(self_id));
}

fn viewDidMoveToWindowImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    syncLayerScale(objc.Object.fromId(self_id));
}

/// AppKit calls this when system appearance flips (light ↔ dark) for
/// any view in the hierarchy. Re-resolve the theme through the same
/// pipeline main() uses on startup, then reapply colors to the
/// terminal, log pane, and panel without rebuilding anything.
fn viewDidChangeEffectiveAppearanceImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    reapplyTheme();
}

/// AppKit calls resetCursorRects whenever it needs to rebuild cursor
/// regions for a view (window activation, layout change). Register the
/// I-beam over the entire view so the cursor matches a normal terminal.
fn resetCursorRectsImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    const NSCursor = objc.getClass("NSCursor") orelse return;
    const ibeam = NSCursor.msgSend(objc.Object, "IBeamCursor", .{});
    if (ibeam.value == null) return;
    const bounds = view.msgSend(NSRect, "bounds", .{});
    view.msgSend(void, "addCursorRect:cursor:", .{ bounds, ibeam });
}

/// NSDraggingDestination protocol: tell AppKit we accept the drag.
/// Returns NSDragOperationCopy so the cursor shows the "+" badge.
fn draggingEnteredImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) c_ulong {
    return 1; // NSDragOperationCopy
}

/// Pull file URLs off the dragging pasteboard, format paths into a
/// shell-safe space-separated string, and paste them into the PTY.
/// Wraps in single quotes when paths contain whitespace or shell
/// metacharacters; otherwise writes the raw path so completion + tab
/// expansion still chain cleanly. Uses bracketed paste when the running
/// TUI requested DEC mode 2004 — CC's REPL treats the result as a
/// pasted block instead of typed input.
fn performDragOperationImpl(_: objc.c.id, _: objc.c.SEL, sender_id: objc.c.id) callconv(.c) bool {
    const sender = objc.Object.fromId(sender_id);
    const pb = sender.msgSend(objc.Object, "draggingPasteboard", .{});
    if (pb.value == null) return false;

    const NSArray = objc.getClass("NSArray") orelse return false;
    const NSURL = objc.getClass("NSURL") orelse return false;
    const classes = NSArray.msgSend(objc.Object, "arrayWithObject:", .{NSURL});
    const items = pb.msgSend(objc.Object, "readObjectsForClasses:options:", .{ classes, @as(?*anyopaque, null) });
    const count: c_ulong = if (items.value != null) items.msgSend(c_ulong, "count", .{}) else 0;

    if (count == 0) {
        // No file URLs → try raw image data (screenshots, Photos drags,
        // browser image drags). Save bytes to /tmp and paste the path.
        return tryDropImage(pb);
    }

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const url = items.msgSend(objc.Object, "objectAtIndex:", .{i});
        if (url.value == null) continue;
        const path_str = url.msgSend(objc.Object, "path", .{});
        if (path_str.value == null) continue;
        const utf8_ptr = path_str.msgSend([*c]const u8, "UTF8String", .{});
        if (utf8_ptr == null) continue;
        const path = std.mem.sliceTo(utf8_ptr, 0);
        if (path.len == 0) continue;

        if (i > 0) {
            if (len < buf.len) {
                buf[len] = ' ';
                len += 1;
            }
        }
        const needs_quote = std.mem.indexOfAny(u8, path, " \t'\"\\$&|;()<>*?#`!") != null;
        if (needs_quote) {
            // Single-quote wrap; embedded single quotes via '\'' POSIX dance.
            if (len < buf.len) {
                buf[len] = '\'';
                len += 1;
            }
            for (path) |c| {
                if (c == '\'') {
                    const seq = "'\\''";
                    for (seq) |sc| {
                        if (len >= buf.len) break;
                        buf[len] = sc;
                        len += 1;
                    }
                } else {
                    if (len >= buf.len) break;
                    buf[len] = c;
                    len += 1;
                }
            }
            if (len < buf.len) {
                buf[len] = '\'';
                len += 1;
            }
        } else {
            const remaining = buf.len - len;
            const take = @min(remaining, path.len);
            @memcpy(buf[len .. len + take], path[0..take]);
            len += take;
        }
    }
    if (len == 0) return false;
    const text = buf[0..len];
    _ = forwardText(text);
    return true;
}

/// Pull an NSImage off the pasteboard, encode as PNG, write to /tmp,
/// and paste the resulting path so CC's Read tool can pick it up.
/// Used when a drop carried image bytes but no NSURL — Photos, Cmd+
/// Shift+4 screenshots, browser drags, etc.
fn tryDropImage(pb: objc.Object) bool {
    const NSImage = objc.getClass("NSImage") orelse return false;
    const NSArray = objc.getClass("NSArray") orelse return false;
    const NSBitmapImageRep = objc.getClass("NSBitmapImageRep") orelse return false;
    const NSDictionary = objc.getClass("NSDictionary") orelse return false;
    const NSString = objc.getClass("NSString") orelse return false;

    const img_classes = NSArray.msgSend(objc.Object, "arrayWithObject:", .{NSImage});
    const images = pb.msgSend(objc.Object, "readObjectsForClasses:options:", .{ img_classes, @as(?*anyopaque, null) });
    if (images.value == null) return false;
    const img_count: c_ulong = images.msgSend(c_ulong, "count", .{});
    if (img_count == 0) return false;

    const img = images.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, 0)});
    if (img.value == null) return false;

    // NSImage → TIFF data → NSBitmapImageRep → PNG. The TIFF detour is
    // the canonical AppKit path; NSImage holds vector reps when the
    // source is PDF/SVG, so we can't go straight to PNG without first
    // rasterizing via TIFFRepresentation.
    const tiff = img.msgSend(objc.Object, "TIFFRepresentation", .{});
    if (tiff.value == null) return false;
    const rep = NSBitmapImageRep.msgSend(objc.Object, "imageRepWithData:", .{tiff});
    if (rep.value == null) return false;

    const empty_dict = NSDictionary.msgSend(objc.Object, "dictionary", .{});
    // NSBitmapImageFileType: PNG = 4 (NSBitmapImageRepFileTypePNG).
    const png = rep.msgSend(objc.Object, "representationUsingType:properties:", .{
        @as(c_ulong, 4),
        empty_dict,
    });
    if (png.value == null) return false;

    var path_buf: [128]u8 = undefined;
    const ms = std.time.milliTimestamp();
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/djinn-drop-{d}.png", .{ms}) catch return false;
    const ns_path = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, path.ptr)});
    if (ns_path.value == null) return false;
    const wrote: bool = png.msgSend(bool, "writeToFile:atomically:", .{ ns_path, @as(c_int, 1) });
    if (!wrote) return false;

    // Paths under /tmp don't contain shell metacharacters; quoting
    // unnecessary. Surface handles bracketed-paste internally based
    // on the active mode.
    _ = forwardText(path);
    return true;
}

/// Final fixup after the user releases a window resize drag. AppKit may
/// suppress redraws during live resize for performance; once the drag ends
/// we force a fresh render-state snapshot + setNeedsDisplay on every surface
/// so neither pane ends up blank.
fn viewDidEndLiveResizeImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    checkResize(view);
    if (app.g.log_view) |lv| {
        lv.view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        lv.scroll.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        lv.text_view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    }
}

/// Push current view bounds + backing scale into the ghostty surface
/// every tick. Cheap — surfaceSetSize / surfaceSetContentScale dedupe
/// internally. Also pokes the log pane to repaint, since its layout
/// can lag behind a window-resize cascade.
fn checkResize(view: objc.Object) void {
    const bounds = view.msgSend(NSRect, "bounds", .{});

    // Push size + scale to the ghostty surface. The
    // surface_host's bounds tracks `view`'s frame (sibling, same
    // autoresize mask), so we use this view's bounds + window scale.
    // ghostty's CADisplayLink handles the actual refresh tick.
    if (app.g.ghostty_surface) |surf_ptr| {
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        const window = view.msgSend(objc.Object, "window", .{});
        const scale: f64 = if (window.value != null) window.msgSend(f64, "backingScaleFactor", .{}) else 1.0;
        const px_w: u32 = @intFromFloat(@max(1.0, bounds.size.width) * scale);
        const px_h: u32 = @intFromFloat(@max(1.0, bounds.size.height) * scale);
        ghostty_runtime.surfaceSetContentScale(surf, scale);
        ghostty_runtime.surfaceSetSize(surf, px_w, px_h);
    }

    // Split-view layout pass during a window resize doesn't reliably
    // propagate setNeedsDisplay down to the log pane's clip view +
    // text view; force them explicitly so the panel doesn't end up
    // with empty rectangles after the user lets go.
    if (app.g.log_view) |lv| {
        lv.view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        lv.scroll.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        lv.text_view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        const clip = lv.scroll.msgSend(objc.Object, "contentView", .{});
        if (clip.value != null) clip.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    }
}

/// Schedule a 60Hz timer that drains the PTY and redraws. Runs on main thread.
/// Registered in `NSRunLoopCommonModes` so it keeps firing during window drags
/// (event-tracking mode) — without that, the tick freezes during a resize and
/// the panel ends up blank afterward, because the post-resize PTY redraw from
/// the shell never gets drained.
fn startTickTimer() void {
    const view_id = app.g.view_id orelse return;
    const NSTimer = objc.getClass("NSTimer") orelse return;
    const NSRunLoop = objc.getClass("NSRunLoop") orelse return;
    const NSString = objc.getClass("NSString") orelse return;

    const timer = NSTimer.msgSend(
        objc.Object,
        "timerWithTimeInterval:target:selector:userInfo:repeats:",
        .{
            @as(f64, 1.0 / 60.0),
            objc.Object.fromId(view_id),
            objc.sel("tick:"),
            @as(?*anyopaque, null),
            @as(c_int, 1),
        },
    );
    const main_loop = NSRunLoop.msgSend(objc.Object, "mainRunLoop", .{});
    const common_modes = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, "kCFRunLoopCommonModes")},
    );
    main_loop.msgSend(void, "addTimer:forMode:", .{ timer, common_modes });
}

fn tickImpl(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    app.g.tick_count +%= 1;

    const view = objc.Object.fromId(self_id);
    checkResize(view);

    // PTY drain moved to a kqueue-backed dispatch_source_t (see
    // ptyReadHandler). Tick now only covers what's still polled:
    // window resize, agent-state sync, and the cursor-blink cadence.

    // (cursor blink + visual bell flash retired in step 10 — surface
    // owns both.)

    // Poll agent state every 15 ticks (~250ms at 60Hz).
    if (app.g.tick_count % 15 == 0) {
        if (app.g.agent_state) |state| {
            if (app.g.log_view) |lv| lv.syncFrom(state);

            if (app.g.menubar) |menubar| {
                const snap = state.snapshot();
                if (snap.state != app.g.last_state or app.g.tick_count == 15) {
                    const mb_state: MenubarAgentState = switch (snap.state) {
                        .idle => .idle,
                        .working => .working,
                        .attention => .attention,
                        .done => .done,
                        .@"error" => .@"error",
                    };
                    menubar.updateState(mb_state, snap.message);
                    app.g.last_state = snap.state;
                }
            }
        }
    }
}

fn acceptsFirstResponderImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

/// Convert an NSEvent location (window coords) to a cell column/row.
/// cell_w/cell_h come from our font system + survive surface mode for
/// host-level cell math (find overlay anchoring + future selection).
fn eventToCell(view: objc.Object, event: objc.Object) struct { col: i32, row: i32 } {
    const win_pt = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_pt = view.msgSend(NSPoint, "convertPoint:fromView:", .{ win_pt, @as(?*anyopaque, null) });
    const bounds = view.msgSend(NSRect, "bounds", .{});

    const x = view_pt.x - app.g.padding_x;
    const y_top = (bounds.size.height - app.g.padding_y) - view_pt.y;
    const col = @as(i32, @intFromFloat(@floor(x / app.g.cell_w)));
    const row = @as(i32, @intFromFloat(@floor(y_top / app.g.cell_h)));
    return .{ .col = col, .row = row };
}

fn mouseMovedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty_surface orelse return;
    const view = objc.Object.fromId(self_id);
    const event = objc.Object.fromId(event_id);
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const loc = event.msgSend(NSPoint, "locationInWindow", .{});
    const local = view.msgSend(NSPoint, "convertPoint:fromView:", .{ loc, @as(?*anyopaque, null) });
    const frame = view.msgSend(NSRect, "frame", .{});
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    // ghostty wants top-down Y; NSView origin is bottom-left.
    ghostty_runtime.c.ghostty_surface_mouse_pos(surf, local.x, frame.size.height - local.y, ghostty_input.modsFromNS(flags));
}


fn mouseDownImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty_surface orelse return;
    const event = objc.Object.fromId(event_id);
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const button_num: c_long = event.msgSend(c_long, "buttonNumber", .{});
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    _ = ghostty_runtime.c.ghostty_surface_mouse_button(
        surf,
        ghostty_runtime.c.GHOSTTY_MOUSE_PRESS,
        ghostty_input.mouseButtonFromNS(button_num),
        ghostty_input.modsFromNS(flags),
    );
}

fn mouseDraggedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty_surface orelse return;
    const view = objc.Object.fromId(self_id);
    const event = objc.Object.fromId(event_id);
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const loc = event.msgSend(NSPoint, "locationInWindow", .{});
    const local = view.msgSend(NSPoint, "convertPoint:fromView:", .{ loc, @as(?*anyopaque, null) });
    const frame = view.msgSend(NSRect, "frame", .{});
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    ghostty_runtime.c.ghostty_surface_mouse_pos(surf, local.x, frame.size.height - local.y, ghostty_input.modsFromNS(flags));
}

// Trackpad scroll deltas arrive as fine-grained pixels. ghostty owns
// the f64 → row accumulator + scrollback bounds; we just forward —
// but the scroll_mods byte (precision bit + momentum phase) must be
// set or ghostty treats every pixel of delta as a whole line tick.
fn scrollWheelImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const event = objc.Object.fromId(event_id);

    const surf_ptr = app.g.ghostty_surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    var dx: f64 = event.msgSend(f64, "scrollingDeltaX", .{});
    var dy: f64 = event.msgSend(f64, "scrollingDeltaY", .{});
    const has_precise: bool = event.msgSend(bool, "hasPreciseScrollingDeltas", .{});
    const phase: c_ulong = event.msgSend(c_ulong, "momentumPhase", .{});
    if (has_precise) {
        // Match ghostty.app's 2x feel multiplier on precision deltas.
        dx *= 2;
        dy *= 2;
    }
    if (dx == 0 and dy == 0 and phase == 0) return;
    ghostty_runtime.c.ghostty_surface_mouse_scroll(surf, dx, dy, scrollMods(has_precise, phase));
    _ = self_id;
}

/// Encode NSEvent precision flag + momentum phase into ghostty's
/// `ghostty_input_scroll_mods_t` packed byte: bit 0 = precision,
/// bits 1-3 = momentum enum (none/began/stationary/changed/ended/
/// cancelled/may_begin). NSEventPhase is a bit mask; ghostty uses a
/// sequential enum, so map bit positions individually.
fn scrollMods(precision: bool, phase: c_ulong) c_int {
    var v: c_int = 0;
    if (precision) v |= 0b0000_0001;
    const momentum: c_int = switch (phase) {
        0x01 => 1, // began
        0x02 => 2, // stationary
        0x04 => 3, // changed
        0x08 => 4, // ended
        0x10 => 5, // cancelled
        0x20 => 6, // may_begin
        else => 0, // none
    };
    v |= momentum << 1;
    return v;
}

fn mouseUpImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const event = objc.Object.fromId(event_id);

    if (app.g.ghostty_surface) |surf_ptr| {
        const ghostty_input = @import("../ghostty/input.zig");
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        const button_num: c_long = event.msgSend(c_long, "buttonNumber", .{});
        const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
        _ = ghostty_runtime.c.ghostty_surface_mouse_button(
            surf,
            ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE,
            ghostty_input.mouseButtonFromNS(button_num),
            ghostty_input.modsFromNS(flags),
        );
        return;
    }

    _ = self_id;
}

/// Cmd+V: read pasteboard string + forward raw to ghostty surface.
/// Surface handles bracketed-paste wrapping internally based on the
/// terminal's mode 2004 state, so no host-side encode dance needed.
fn pasteFromClipboard() void {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});

    const NSString = objc.getClass("NSString") orelse return;
    const type_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.utf8-plain-text")});
    const ns_str = pb.msgSend(objc.Object, "stringForType:", .{type_name});
    if (ns_str.value == null) return;

    const utf8_ptr = ns_str.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return;
    const text = std.mem.sliceTo(utf8_ptr, 0);
    if (text.len == 0) return;

    _ = forwardText(text);
}

// NSEventModifierFlag bits (high bits of NSUInteger).
const mod_shift: u64 = 1 << 17;
const mod_control: u64 = 1 << 18;
const mod_alt: u64 = 1 << 19;
const mod_cmd: u64 = 1 << 20;

fn keyDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const event = objc.Object.fromId(event_id);

    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});

    // App-level shortcuts go through the action table; on a hit we return
    // and never reach the encoder. Host shortcuts always win — Cmd+/-,
    // Cmd+F, Cmd+, etc. don't get swallowed by surface keybindings.
    if (dispatchAction(flags, keycode)) return;

    // Find mode owns the keyboard: route into the needle buffer
    // instead of the surface. Cmd / Ctrl chords still fall through
    // (so Cmd+G can navigate without entering "G" into the needle).
    if (app.g.find_mode and (flags & (mod_cmd | mod_control)) == 0) {
        handleFindKey(event, keycode);
        return;
    }

    // IME slow path. When the input source is non-Latin (Kotoeri,
    // Pinyin, Hangul …) or we're already mid-composition, route the
    // event through AppKit's text input pipeline so insertText /
    // setMarkedText / doCommandBySelector get a chance to run. Skip
    // when Cmd / Ctrl is held — those are bindings, not text input.
    const has_command_mods = (flags & (mod_cmd | mod_control)) != 0;
    const want_ime_route = !has_command_mods and (!tis.isLatin() or g_preedit_len > 0);
    if (want_ime_route) {
        const view = objc.Object.fromId(self_id);
        const NSArray = objc.getClass("NSArray") orelse return;
        const arr = NSArray.msgSend(objc.Object, "arrayWithObject:", .{event_id});
        g_current_keydown = event_id;
        g_handled_during_interpret = false;
        view.msgSend(void, "interpretKeyEvents:", .{arr.value});
        g_current_keydown = null;
        if (g_handled_during_interpret) return;
        // No IME callback fired (e.g. dead-key partial state) — fall
        // through to surface_key so the keypress isn't swallowed.
    }

    // Step 6b: route input to the ghostty surface via the full key
    // event API. ghostty maps the raw Mac keycode internally + uses
    // the text/codepoint fields for character semantics. Special keys
    // (arrows, enter, function keys, Ctrl-combos) all reach ghostty
    // through this single path.
    if (app.g.ghostty_surface) |surf_ptr| {
        const ghostty_input = @import("../ghostty/input.zig");
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);

        // Text field: ghostty's KeyEncoder expects the *unmapped* character
        // for control inputs (so it can apply the Ctrl→C0 mapping itself).
        // - Single control char (< 0x20): re-resolve characters with the
        //   control flag stripped. Ctrl+C: characters="\x03" → "c".
        //   Otherwise ghostty double-encodes.
        // - macOS PUA range (U+F700..F8FF): function keys. Don't pass as
        //   text; ghostty derives them from keycode + mods alone.
        // - Otherwise: NSEvent.characters as-is (Shift+A → "A", Alt+→ raw).
        const chars_obj = event.msgSend(objc.Object, "characters", .{});
        const chars_ptr_raw = chars_obj.msgSend([*c]const u8, "UTF8String", .{});
        var text_ptr: [*c]const u8 = null;
        if (chars_ptr_raw != null) {
            const slice = std.mem.sliceTo(chars_ptr_raw, 0);
            const is_pua = slice.len == 3 and slice[0] == 0xef and slice[1] >= 0x9c and slice[1] <= 0xa3;
            if (slice.len == 1 and slice[0] < 0x20) {
                const without_ctrl: c_ulong = @intCast(flags & ~mod_control);
                const re_obj = event.msgSend(objc.Object, "charactersByApplyingModifiers:", .{without_ctrl});
                if (re_obj.value != null) {
                    text_ptr = re_obj.msgSend([*c]const u8, "UTF8String", .{});
                }
            } else if (!is_pua and slice.len > 0) {
                text_ptr = chars_ptr_raw;
            }
        }

        // unshifted_codepoint: characters with no modifiers applied. Used
        // by ghostty's keymap to identify the physical key independent of
        // Shift/Alt/Caps. Skip charactersIgnoringModifiers — its behavior
        // changes under Ctrl in a way that breaks codepoint identity.
        var unshifted_cp: u32 = 0;
        const unshifted_obj = event.msgSend(objc.Object, "charactersByApplyingModifiers:", .{@as(c_ulong, 0)});
        if (unshifted_obj.value != null) {
            const u_ptr = unshifted_obj.msgSend([*c]const u8, "UTF8String", .{});
            if (u_ptr != null) {
                unshifted_cp = ghostty_input.firstCodepoint(std.mem.sliceTo(u_ptr, 0));
            }
        }

        const is_repeat: bool = event.msgSend(bool, "isARepeat", .{});
        const mods_g = ghostty_input.modsFromNS(flags);
        // consumed_mods: mods that contributed to text translation. Per
        // upstream's heuristic, control + command never contribute (they
        // map to terminal sequences); shift/alt/caps do.
        const ctrl_super_mask: c_uint = @as(c_uint, @intCast(ghostty_runtime.c.GHOSTTY_MODS_CTRL)) |
            @as(c_uint, @intCast(ghostty_runtime.c.GHOSTTY_MODS_SUPER));
        const consumed_g: c_uint = @as(c_uint, @intCast(mods_g)) & ~ctrl_super_mask;

        const key_event = ghostty_runtime.c.ghostty_input_key_s{
            .action = if (is_repeat) ghostty_runtime.c.GHOSTTY_ACTION_REPEAT else ghostty_runtime.c.GHOSTTY_ACTION_PRESS,
            .mods = mods_g,
            .consumed_mods = consumed_g,
            .keycode = keycode,
            .text = text_ptr,
            .unshifted_codepoint = unshifted_cp,
            .composing = false,
        };
        _ = ghostty_runtime.c.ghostty_surface_key(surf, key_event);
        return;
    }
}

// (Glyph caches + drawRectImpl + drawPreedit were retired in step 10
// stage B — ghostty surface owns rendering. TerminalView is now a
// transparent input-overlay; AppKit only calls input/IME/mouse
// methods on it, never drawRect:.)


// ─── Action table ────────────────────────────────────────────────────
//
// Single source of truth for app-level keyboard shortcuts. keyDownImpl
// asks dispatchAction first; matching entries fire and short-circuit
// the rest of the keyDown pipeline. Adding a new shortcut is one line
// here + a function — no more growing the if-chain in keyDownImpl.

const Action = struct {
    /// Stable name for config-driven keymap overrides. Must match the
    /// `keymap` object key in user config; see `pub fn rebind` below.
    name: []const u8,
    /// Required modifier set (exact match against mods masked out of flags).
    mods: u64,
    /// macOS hardware keycode (kVK_*).
    keycode: u16,
    handler: *const fn () void,
};

/// Mutable so user keymap overrides can rebind individual entries at
/// startup without rebuilding the table. Length stays fixed; we only
/// swap mods/keycode, never add/remove handlers.
var actions = [_]Action{
    // Selection / clipboard
    .{ .name = "paste", .mods = mod_cmd, .keycode = 9, .handler = pasteFromClipboard }, // Cmd+V
    // Scrollback
    .{ .name = "scroll_page_up", .mods = mod_cmd, .keycode = 126, .handler = actionScrollPageUp }, // Cmd+↑
    .{ .name = "scroll_page_down", .mods = mod_cmd, .keycode = 125, .handler = actionScrollPageDown }, // Cmd+↓
    // Font zoom — Cmd+= and Cmd+Shift+= both zoom in (macOS convention since
    // unshifted '=' and shifted '+' live on the same key).
    .{ .name = "font_inc", .mods = mod_cmd, .keycode = 24, .handler = actionFontInc }, // Cmd+=
    .{ .name = "font_inc_shift", .mods = mod_cmd | mod_shift, .keycode = 24, .handler = actionFontInc }, // Cmd++
    .{ .name = "font_dec", .mods = mod_cmd, .keycode = 27, .handler = actionFontDec }, // Cmd+-
    .{ .name = "font_reset", .mods = mod_cmd, .keycode = 29, .handler = actionFontReset }, // Cmd+0
    // Clear scrollback + visible screen — same as iTerm/ghostty Cmd+K.
    .{ .name = "clear_scrollback", .mods = mod_cmd, .keycode = 40, .handler = actionClearScrollback }, // Cmd+K
    // Settings — Cmd+, opens ~/.config/djinn/config in default editor.
    .{ .name = "open_settings", .mods = mod_cmd, .keycode = 43, .handler = actionOpenSettings }, // Cmd+,
    // Toggle log pane visibility on demand. Cmd+/ chosen for parity
    // with iTerm-style "show debug pane" muscle memory; rebindable.
    .{ .name = "toggle_log_pane", .mods = mod_cmd, .keycode = 44, .handler = actionToggleLogPane }, // Cmd+/
    // Find on page — Cmd+F prompts for a query (NSAlert + text
    // field). Cmd+G / Cmd+Shift+G cycle through matches.
    .{ .name = "find_open", .mods = mod_cmd, .keycode = 3, .handler = actionFindOpen }, // Cmd+F
    .{ .name = "find_next", .mods = mod_cmd, .keycode = 5, .handler = actionFindNext }, // Cmd+G
    .{ .name = "find_prev", .mods = mod_cmd | mod_shift, .keycode = 5, .handler = actionFindPrev }, // Cmd+Shift+G
    // Tab switching across profile sessions. Cmd+1..9 jump by index;
    // Cmd+Shift+]/[ cycle. No-ops when the index is out of range or
    // only a single profile is configured, so binding all 9 keys
    // eagerly is safe.
    .{ .name = "tab_1", .mods = mod_cmd, .keycode = 18, .handler = actionTab1 },
    .{ .name = "tab_2", .mods = mod_cmd, .keycode = 19, .handler = actionTab2 },
    .{ .name = "tab_3", .mods = mod_cmd, .keycode = 20, .handler = actionTab3 },
    .{ .name = "tab_4", .mods = mod_cmd, .keycode = 21, .handler = actionTab4 },
    .{ .name = "tab_5", .mods = mod_cmd, .keycode = 23, .handler = actionTab5 },
    .{ .name = "tab_6", .mods = mod_cmd, .keycode = 22, .handler = actionTab6 },
    .{ .name = "tab_7", .mods = mod_cmd, .keycode = 26, .handler = actionTab7 },
    .{ .name = "tab_8", .mods = mod_cmd, .keycode = 28, .handler = actionTab8 },
    .{ .name = "tab_9", .mods = mod_cmd, .keycode = 25, .handler = actionTab9 },
    .{ .name = "next_tab", .mods = mod_cmd | mod_shift, .keycode = 30, .handler = actionNextTab },
    .{ .name = "prev_tab", .mods = mod_cmd | mod_shift, .keycode = 33, .handler = actionPrevTab },
};

/// Override an entry's binding by name. Called from main() during
/// startup for each user keymap entry. Unknown names log + are
/// ignored — a typo in config shouldn't crash djinn.
pub fn rebind(name: []const u8, mods: u64, keycode: u16) bool {
    for (&actions) |*a| {
        if (std.mem.eql(u8, a.name, name)) {
            a.mods = mods;
            a.keycode = keycode;
            return true;
        }
    }
    return false;
}

fn dispatchAction(flags: u64, keycode: u16) bool {
    const mod_mask = mod_shift | mod_control | mod_alt | mod_cmd;
    const masked = flags & mod_mask;
    inline for (actions) |a| {
        if (a.keycode == keycode and a.mods == masked) {
            a.handler();
            return true;
        }
    }
    return false;
}

fn actionScrollPageUp() void {
    scrollByPage(-1);
}

fn actionScrollPageDown() void {
    scrollByPage(1);
}

/// Page scroll forwards as PgUp/PgDn keypress to the surface — surface
/// owns scrollback view + pin semantics. Sequence is `ESC [ 5 ~` /
/// `ESC [ 6 ~` per VT100, both honored by ghostty's parser.
fn scrollByPage(direction: i32) void {
    const seq: []const u8 = if (direction < 0) "\x1b[5~" else "\x1b[6~";
    _ = forwardText(seq);
}

fn actionFontInc() void {
    forwardBindingAction("increase_font_size:1");
}

fn actionFontDec() void {
    forwardBindingAction("decrease_font_size:1");
}

fn actionFontReset() void {
    forwardBindingAction("reset_font_size");
}

fn actionOpenSettings() void {
    menubar_mod.openSettings();
}

fn actionToggleLogPane() void {
    const lv = app.g.log_view orelse return;
    const log_frame = lv.view.msgSend(NSRect, "frame", .{});
    setLogPaneHidden(log_frame.size.width > 0);
}

/// Show or hide the log pane at runtime. Hidden state collapses log +
/// divider frames to width 0 (Metal-layer compositor honors zero-pixel
/// frames, unlike setHidden which left translucent leaks). Stays in
/// the view tree to keep responder-chain + key-window state intact on
/// borderless NSPanels.
pub fn setLogPaneHidden(hide: bool) void {
    const view_id = app.g.view_id orelse return;
    const term_view = objc.Object.fromId(view_id);
    const container = term_view.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;

    const c_bounds = container.msgSend(NSRect, "bounds", .{});
    const cfg = app.g.config orelse return;
    const main_mod = @import("../main.zig");
    const log_baseline_w: f64 = main_mod.computeLogWidth(c_bounds.size.width, cfg);
    const log_w: f64 = if (hide) 0 else log_baseline_w;
    const eff_div_w: f64 = if (hide) 0 else divider_width;
    const term_w: f64 = @max(1.0, c_bounds.size.width - log_w - eff_div_w);

    applyLogLayout(container, term_w, log_w, c_bounds.size.height);
}

fn actionClearScrollback() void {
    // CSI H + CSI 2 J + CSI 3 J: cursor home + erase visible + erase
    // scrollback (xterm extension; ghostty's parser honors it). Forward
    // to the surface — it parses through its own VT path which both
    // clears its own scrollback + paints the cleared frame.
    _ = forwardText("\x1b[H\x1b[2J\x1b[3J");
}

// ─── Find on page ────────────────────────────────────────────────────
//
// Cmd+F enters find mode. While find_mode is true, keyDownImpl routes
// printable keys into the needle buffer instead of the ghostty surface
// and pushes "search:<needle>" via the binding-action API; backspace
// shrinks the needle; Esc exits + clears; Return commits + exits but
// keeps matches highlighted (Cmd+G cycles after). Cmd+F again toggles
// off. The display NSTextField is read-only — borderless NSPanel +
// NSTextField + ghostty surface don't compose into a working field
// editor, so we own input + just paint the result into the field.

fn pushSearchNeedle() void {
    var buf: [160]u8 = undefined;
    const prefix = "search:";
    @memcpy(buf[0..prefix.len], prefix);
    const n = app.g.search_query_len;
    @memcpy(buf[prefix.len .. prefix.len + n], app.g.search_query_buf[0..n]);
    forwardBindingAction(buf[0 .. prefix.len + n]);
    app.g.search_total = null;
    app.g.search_selected = null;
    updateSearchCountLabel();
}

fn enterFindMode() void {
    if (app.g.find_mode) return;
    app.g.find_mode = true;
    app.g.search_query_len = 0;
    app.g.search_total = null;
    app.g.search_selected = null;
    updateSearchCountLabel();
    forwardBindingAction("start_search");
}

fn exitFindMode(end_search: bool) void {
    if (!app.g.find_mode) return;
    app.g.find_mode = false;
    app.g.search_query_len = 0;
    app.g.search_total = null;
    app.g.search_selected = null;
    updateSearchCountLabel();
    if (end_search) {
        // end_search calls Search.deinit which joins the search thread.
        // The thread's defer-block fires `.quit` via the event callback,
        // which surface routes through its mailbox to clear renderer
        // highlights. So this single call covers both teardown + clear.
        forwardBindingAction("end_search");
    }
    // Re-anchor first responder on the terminal view. The end_search
    // path blocks main on Search.deinit's thread.join; AppKit can
    // shuffle event/responder state during that pause and stop
    // delivering keyDown back to us. Force the responder back.
    if (app.g.view_id) |vid| {
        const view = objc.Object.fromId(vid);
        const window = view.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{view});
        }
    }
}

/// Public UI-sync entry point for ghostty's end_search action.
/// Hides UI without re-emitting the binding (would recurse).
pub fn closeOverlayUiOnly() void {
    if (!app.g.find_mode) return;
    app.g.find_mode = false;
    app.g.search_query_len = 0;
    app.g.search_total = null;
    app.g.search_selected = null;
    updateSearchCountLabel();
}

/// Public UI-sync entry point for ghostty's start_search action.
pub fn openOverlayUiOnly() void {
    if (app.g.find_mode) return;
    app.g.find_mode = true;
    app.g.search_query_len = 0;
    updateSearchCountLabel();
}

fn actionFindOpen() void {
    if (app.g.find_mode) {
        exitFindMode(true);
        return;
    }
    enterFindMode();
}

/// Handle a keystroke while find_mode is active. Returns when the
/// event was consumed by find mode and must NOT continue down the
/// surface_key path.
fn handleFindKey(event: objc.Object, keycode: u16) void {
    // Esc / Return — exit, clear highlights.
    if (keycode == 53 or keycode == 36 or keycode == 76) {
        exitFindMode(true);
        return;
    }
    // Backspace — shrink needle. Re-pushes (empty needle stops search
    // per ghostty semantics, but UI stays in find mode).
    if (keycode == 51) {
        if (app.g.search_query_len > 0) {
            app.g.search_query_len -= 1;
            pushSearchNeedle();
        }
        return;
    }
    // Append printable text from event.characters.
    const chars_obj = event.msgSend(objc.Object, "characters", .{});
    if (chars_obj.value == null) return;
    const chars_ptr = chars_obj.msgSend([*c]const u8, "UTF8String", .{});
    if (chars_ptr == null) return;
    const s = std.mem.sliceTo(chars_ptr, 0);
    if (s.len == 0) return;
    // Skip control chars (< 0x20) — covers Tab, Ctrl combos that AppKit
    // delivers via characters even when not intended as text.
    if (s.len == 1 and s[0] < 0x20) return;
    const room = app.g.search_query_buf.len - app.g.search_query_len;
    const take = @min(s.len, room);
    @memcpy(app.g.search_query_buf[app.g.search_query_len .. app.g.search_query_len + take], s[0..take]);
    app.g.search_query_len += take;
    pushSearchNeedle();
}

fn actionFindNext() void {
    forwardBindingAction("navigate_search:next");
}

fn actionFindPrev() void {
    forwardBindingAction("navigate_search:previous");
}

// Tab switching — thin wrappers around `main.activateSession(idx)`.
// Generated explicitly (no `comptime` lambda) so each handler has a
// distinct function pointer the action table can dispatch through.
fn activateSessionByIndex(idx: usize) void {
    _ = @import("../main.zig").activateSession(idx);
}
fn actionTab1() void { activateSessionByIndex(0); }
fn actionTab2() void { activateSessionByIndex(1); }
fn actionTab3() void { activateSessionByIndex(2); }
fn actionTab4() void { activateSessionByIndex(3); }
fn actionTab5() void { activateSessionByIndex(4); }
fn actionTab6() void { activateSessionByIndex(5); }
fn actionTab7() void { activateSessionByIndex(6); }
fn actionTab8() void { activateSessionByIndex(7); }
fn actionTab9() void { activateSessionByIndex(8); }
fn actionNextTab() void {
    const sm = app.g.session_manager orelse return;
    const idx = sm.peekNext() orelse return;
    activateSessionByIndex(idx);
}
fn actionPrevTab() void {
    const sm = app.g.session_manager orelse return;
    const idx = sm.peekPrev() orelse return;
    activateSessionByIndex(idx);
}

// ─── NSTextInputClient (IME) ────────────────────────────────────────
//
// We forward keyDown to NSTextInputContext.handleEvent: when no Cmd /
// Ctrl / Alt is held. AppKit then dispatches back into these methods:
//
//   insertText            → final committed text (typed ASCII or IME
//                            commit) — write to PTY
//   doCommandBySelector   → AppKit translated the key to an NSResponder
//                            selector (insertNewline:, moveLeft:, etc.).
//                            Re-encode via stashed event through the
//                            ghostty key encoder.
//   setMarkedText         → composition in progress (preedit). Push
//                            to ghostty_surface_preedit so the surface
//                            paints the underline overlay at the cursor.
//   unmarkText            → composition committed or canceled; clear
//                            surface preedit.
//
// The remaining read-side methods exist to satisfy the protocol; we
// don't keep a buffer of past output so most return empty / NotFound.
// `g_preedit_len` is retained as the protocol-side query state
// (markedRange / hasMarkedText) and as the tis fast-path gate; the
// buffer storage no longer drives any paint — the surface owns that.

const preedit_buf_size: usize = 256;
var g_preedit_buf: [preedit_buf_size]u8 = undefined;
var g_preedit_len: usize = 0;

/// Stashed by keyDownImpl while interpretKeyEvents: runs so
/// doCommandBySelector can recover the original NSEvent and re-encode
/// it via the ghostty key encoder. Reset to null when interpretKeyEvents
/// returns.
var g_current_keydown: ?objc.c.id = null;

/// Set by insertTextImpl / setMarkedTextImpl / doCommandBySelectorImpl
/// when called inside interpretKeyEvents:. Lets keyDownImpl skip its
/// fall-through `ghostty_surface_key` call so AppKit-handled events
/// don't get encoded twice.
var g_handled_during_interpret: bool = false;

fn insertTextImpl(self_id: objc.c.id, _: objc.c.SEL, str_id: objc.c.id, _: NSRange) callconv(.c) void {
    g_handled_during_interpret = true;
    g_preedit_len = 0;
    forwardPreedit(&[_]u8{});

    // `string` is NSString or NSAttributedString. Both respond to
    // -UTF8String, but NSAttributedString returns the attributed
    // representation; pull plain via -string when present.
    var s = objc.Object.fromId(str_id);
    if (s.value == null) return;
    if (s.msgSend(bool, "respondsToSelector:", .{objc.sel("string")})) {
        s = s.msgSend(objc.Object, "string", .{});
        if (s.value == null) return;
    }
    const utf8_ptr = s.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return;
    const text = std.mem.sliceTo(utf8_ptr, 0);
    if (text.len > 0) {
        _ = forwardText(text);
    }
    _ = self_id;
}

fn doCommandBySelectorImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.SEL) callconv(.c) void {
    // AppKit recognized the key as a command (arrows, Tab, Enter, Esc,
    // Backspace, …). Re-issue the original NSEvent through ghostty's
    // surface_key path so the wire format matches a non-IME keypress.
    g_handled_during_interpret = true;
    const event_id = g_current_keydown orelse return;
    const surf_ptr = app.g.ghostty_surface orelse return;
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const event = objc.Object.fromId(event_id);
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});

    const mods_g = ghostty_input.modsFromNS(flags);
    const key_event = ghostty_runtime.c.ghostty_input_key_s{
        .action = ghostty_runtime.c.GHOSTTY_ACTION_PRESS,
        .mods = mods_g,
        .consumed_mods = mods_g,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    };
    _ = ghostty_runtime.c.ghostty_surface_key(surf, key_event);
}

fn setMarkedTextImpl(_: objc.c.id, _: objc.c.SEL, str_id: objc.c.id, _: NSRange, _: NSRange) callconv(.c) void {
    g_handled_during_interpret = true;
    var s = objc.Object.fromId(str_id);
    if (s.value == null) {
        g_preedit_len = 0;
    } else {
        if (s.msgSend(bool, "respondsToSelector:", .{objc.sel("string")})) {
            s = s.msgSend(objc.Object, "string", .{});
        }
        if (s.value == null) {
            g_preedit_len = 0;
        } else {
            const utf8_ptr = s.msgSend([*c]const u8, "UTF8String", .{});
            if (utf8_ptr == null) {
                g_preedit_len = 0;
            } else {
                const text = std.mem.sliceTo(utf8_ptr, 0);
                const take = @min(text.len, preedit_buf_size);
                @memcpy(g_preedit_buf[0..take], text[0..take]);
                g_preedit_len = take;
            }
        }
    }
    forwardPreedit(g_preedit_buf[0..g_preedit_len]);
}

fn unmarkTextImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    g_preedit_len = 0;
    forwardPreedit(&[_]u8{});
}

fn selectedRangeImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    // Terminal has no "document" with a stable range — report zero.
    return .{ .location = 0, .length = 0 };
}

fn markedRangeImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    if (g_preedit_len == 0) return .{ .location = ns_not_found, .length = 0 };
    return .{ .location = 0, .length = @intCast(g_preedit_len) };
}

fn hasMarkedTextImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return g_preedit_len > 0;
}

fn attributedSubstringForProposedRangeImpl(_: objc.c.id, _: objc.c.SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.c.id {
    return null;
}

fn validAttributesForMarkedTextImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    const NSArray = objc.getClass("NSArray") orelse return null;
    const arr = NSArray.msgSend(objc.Object, "array", .{});
    return arr.value;
}

fn firstRectForCharacterRangeImpl(self_id: objc.c.id, _: objc.c.SEL, _: NSRange, _: ?*NSRange) callconv(.c) NSRect {
    // IME UI (candidate window etc.) anchors to this rect. Query
    // ghostty for the cursor position via ghostty_surface_ime_point;
    // returned coords are view-local pixels with top-left origin, so
    // we flip y to NSView's bottom-left convention before converting
    // to window → screen coords.
    const empty = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const view = objc.Object.fromId(self_id);
    const surf_ptr = app.g.ghostty_surface orelse return empty;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);

    var x: f64 = 0;
    var y: f64 = 0;
    var width: f64 = app.g.cell_w;
    var height: f64 = app.g.cell_h;
    ghostty_runtime.c.ghostty_surface_ime_point(surf, &x, &y, &width, &height);

    const frame = view.msgSend(NSRect, "frame", .{});
    const view_rect = NSRect{
        .origin = .{ .x = x, .y = frame.size.height - y },
        .size = .{ .width = width, .height = @max(height, app.g.cell_h) },
    };
    const win_rect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(?*anyopaque, null) });
    const window = view.msgSend(objc.Object, "window", .{});
    if (window.value == null) return empty;
    return window.msgSend(NSRect, "convertRectToScreen:", .{win_rect});
}

fn characterIndexForPointImpl(_: objc.c.id, _: objc.c.SEL, _: NSPoint) callconv(.c) c_ulong {
    return ns_not_found;
}

// ─── Theme reload ────────────────────────────────────────────────────
//
// Triggered by viewDidChangeEffectiveAppearance: when macOS toggles
// light ↔ dark (or the user runs `defaults write -g AppleInterfaceStyle`).
// Goes through the same theme.resolve pipeline as startup, then pushes
// the new colors into the terminal, log pane, and panel.

const theme_mod = @import("../theme/theme.zig");

/// Force a theme re-resolve regardless of the cached appearance tag.
/// Called by the live-config reload path after the user edits theme
/// fields; we can't rely on the appearance comparison since the
/// appearance hasn't changed — only the config has.
pub fn reloadTheme() void {
    app.g.last_appearance = 0;
    reapplyTheme();
}

fn reapplyTheme() void {
    const allocator = app.g.allocator orelse return;
    const config = app.g.config orelse return;

    // Skip when system appearance hasn't actually changed since the
    // last reload. AppKit fires viewDidChangeEffectiveAppearance for
    // many state transitions besides light/dark flips — first
    // window-attach, panel show, layout passes — and re-running
    // theme.resolve (file IO + parse) on every show is the source of
    // the perceived show-time lag.
    const current_appearance = theme_mod.detectSystemAppearance();
    const current_tag: u8 = switch (current_appearance) {
        .light => 1,
        .dark => 2,
    };
    if (app.g.last_appearance == current_tag) return;
    app.g.last_appearance = current_tag;

    var new_theme = theme_mod.resolve(allocator, .{
        .inherit_ghostty_config = config.theme.inherit_ghostty,
        .ghostty_cfg = app.g.ghostty_config,
        .font_family = config.terminal.font_family,
        .font_size = config.terminal.font_size,
        .padding_x = config.terminal.padding_x,
        .padding_y = config.terminal.padding_y,
        .opacity = config.theme.opacity,
        .background = if (config.theme.background) |s| theme_mod.parseColor(s) else null,
        .foreground = if (config.theme.foreground) |s| theme_mod.parseColor(s) else null,
        .cursor_color = if (config.theme.cursor) |s| theme_mod.parseColor(s) else null,
    }) catch return;
    defer new_theme.deinit();

    // Surface owns its own palette via its resolved Config; theme.resolve
    // already pulled the latest values when run. Push log_pane + menubar
    // colors so the host UI matches.

    const new_style = chrome_mod.Style.fromTheme(new_theme);
    app.g.chrome_style = new_style;
    if (app.g.log_view) |lv| lv.applyStyle(new_style);
    applyFindOverlayStyle(new_style);

    if (app.g.panel) |p| {
        const bg_r = @as(f64, @floatFromInt(new_theme.background.r)) / 255.0;
        const bg_g = @as(f64, @floatFromInt(new_theme.background.g)) / 255.0;
        const bg_b = @as(f64, @floatFromInt(new_theme.background.b)) / 255.0;
        p.setBackgroundColor(bg_r, bg_g, bg_b, new_theme.opacity);
    }
}
