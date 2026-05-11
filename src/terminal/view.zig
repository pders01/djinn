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
const keymap = @import("keymap.zig");
const find = @import("find.zig");
const font_mod = @import("font.zig");
const divider_mod = @import("divider.zig");
const ime = @import("ime.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
});

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

// Module-private state lives here; everything cross-callback flows through
// `app.g`. `g_class_registered` and the PTY read buffer stay local because
// they're implementation details of view-class registration / drain — no
// other module reads them.
var g_class_registered: bool = false;

pub const divider_width = divider_mod.width;

/// Forward a UTF-8 text blob to the ghostty surface (paste / drop /
/// IME commit / unmapped-key fallback path). Returns false when the
/// surface isn't bound yet — caller decides whether that's a hard
/// failure (drag-drop) or silent (key fallback).
fn forwardText(text: []const u8) bool {
    const surf_ptr = app.g.ghostty.surface orelse return false;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_text(surf, text.ptr, text.len);
    return true;
}

/// Trigger a ghostty binding action by its parsed string form
/// (e.g. "search:foo", "navigate_search:next", "end_search").
fn forwardBindingAction(action_str: []const u8) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    _ = ghostty_runtime.c.ghostty_surface_binding_action(surf, action_str.ptr, action_str.len);
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

        const metrics = try font_mod.buildFont(font_name, font_size);

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

        app.g.term.font = @ptrCast(metrics.font);
        app.g.term.view_id = view.value;
        app.g.term.cell_w = metrics.cell_w;
        app.g.term.cell_h = metrics.cell_h;
        app.g.term.baseline = metrics.baseline;
        app.g.term.padding_x = padding_x;
        app.g.term.padding_y = padding_y;
        app.g.term.bg_alpha = bg_alpha;

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

        // Find-overlay NSTextField — read-only display chip parented
        // to the terminal view. See `find.createOverlay` for the layer
        // setup and find-mode dataflow.
        try find.createOverlay(view, width, height, style);

        return .{ .view = view, .cell_w = metrics.cell_w, .cell_h = metrics.cell_h };
    }

    pub fn gridSize(self: TerminalView, width: f64, height: f64) struct { cols: u16, rows: u16 } {
        const usable_w = @max(1.0, width - 2 * app.g.term.padding_x);
        const usable_h = @max(1.0, height - 2 * app.g.term.padding_y);
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
        app.g.agent.state = state;
        app.g.agent.menubar = menubar;
    }

    pub fn observeLog(self: *TerminalView, log_view: *LogView) void {
        _ = self;
        app.g.agent.log_view = log_view;
    }
};

pub const createDivider = divider_mod.create;

/// Reflow terminal + divider + log + surface_host frames to a new
/// split. Shared between drag-to-resize + log-pane toggle so the
/// layout invariants live in one place. Reserves `tab_strip.tab_h`
/// at the top when the multi-profile tab strip is present.
pub fn applyLogLayout(container: objc.Object, term_w: f64, log_w: f64, height: f64) void {
    const tab_strip = @import("../session/tab_strip.zig");
    const tab_h: f64 = if (app.g.layout.tab_strip_id != null) tab_strip.tab_h else 0;
    const term_h = @max(1.0, height - tab_h);
    const view_id = app.g.term.view_id orelse return;
    const term_view = objc.Object.fromId(view_id);
    term_view.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = term_w, .height = term_h },
    }});
    if (app.g.layout.divider_view_id) |did| {
        objc.Object.fromId(did).msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = term_w, .y = 0 },
            .size = .{ .width = if (log_w > 0) divider_width else 0, .height = term_h },
        }});
    }
    if (app.g.agent.log_view) |lv| {
        const div_w: f64 = if (log_w > 0) divider_width else 0;
        lv.view.msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = term_w + div_w, .y = 0 },
            .size = .{ .width = log_w, .height = term_h },
        }});
    }
    if (app.g.layout.tab_strip_id) |tid| {
        objc.Object.fromId(tid).msgSend(void, "setFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = term_h },
            .size = .{ .width = container.msgSend(NSRect, "bounds", .{}).size.width, .height = tab_h },
        }});
    }
    // Reflow every session's surface_host so inactive sessions stay
    // sized identically to the active one (autoresizingMask covers
    // window resize; this covers term/log split changes from
    // setLogPaneHidden + drag-to-resize). main() guarantees the
    // session_manager pointer is set before any caller of
    // applyLogLayout fires; no fallback path needed.
    if (app.g.session_manager) |sm| {
        for (sm.sessions.items) |sess| {
            if (sess.surface_host) |sid| {
                objc.Object.fromId(sid).msgSend(void, "setFrame:", .{NSRect{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{ .width = term_w, .height = term_h },
                }});
            }
        }
    }
    checkResize(term_view);
    container.msgSend(void, "setNeedsLayout:", .{@as(c_int, 1)});
    container.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
}

fn registerClass() void {
    if (g_class_registered) return;
    g_class_registered = true;

    const superclass = objc.getClass("NSView") orelse return;
    const cls = objc.allocateClassPair(superclass, "DjinnTerminalView") orelse return;
    _ = cls.addMethod("acceptsFirstResponder", acceptsFirstResponderImpl);
    _ = cls.addMethod("becomeFirstResponder", becomeFirstResponderImpl);
    _ = cls.addMethod("resignFirstResponder", resignFirstResponderImpl);
    _ = cls.addMethod("flagsChanged:", flagsChangedImpl);
    _ = cls.addMethod("keyDown:", keyDownImpl);
    _ = cls.addMethod("tick:", tickImpl);
    _ = cls.addMethod("mouseDown:", mouseDownImpl);
    _ = cls.addMethod("mouseDragged:", mouseDraggedImpl);
    _ = cls.addMethod("mouseUp:", mouseUpImpl);
    _ = cls.addMethod("mouseMoved:", mouseMovedImpl);
    _ = cls.addMethod("rightMouseDown:", rightMouseDownImpl);
    _ = cls.addMethod("rightMouseDragged:", rightMouseDraggedImpl);
    _ = cls.addMethod("rightMouseUp:", rightMouseUpImpl);
    _ = cls.addMethod("otherMouseDown:", otherMouseDownImpl);
    _ = cls.addMethod("otherMouseDragged:", otherMouseDraggedImpl);
    _ = cls.addMethod("otherMouseUp:", otherMouseUpImpl);
    _ = cls.addMethod("mouseEntered:", mouseEnteredImpl);
    _ = cls.addMethod("mouseExited:", mouseExitedImpl);
    _ = cls.addMethod("updateTrackingAreas", updateTrackingAreasImpl);
    _ = cls.addMethod("scrollWheel:", scrollWheelImpl);
    _ = cls.addMethod("keyUp:", keyUpImpl);
    _ = cls.addMethod("pressureChange:", pressureChangeImpl);
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
    _ = cls.addMethod("insertText:replacementRange:", ime.insertTextImpl);
    _ = cls.addMethod("doCommandBySelector:", ime.doCommandBySelectorImpl);
    _ = cls.addMethod("setMarkedText:selectedRange:replacementRange:", ime.setMarkedTextImpl);
    _ = cls.addMethod("unmarkText", ime.unmarkTextImpl);
    _ = cls.addMethod("selectedRange", ime.selectedRangeImpl);
    _ = cls.addMethod("markedRange", ime.markedRangeImpl);
    _ = cls.addMethod("hasMarkedText", ime.hasMarkedTextImpl);
    _ = cls.addMethod("attributedSubstringForProposedRange:actualRange:", ime.attributedSubstringForProposedRangeImpl);
    _ = cls.addMethod("validAttributesForMarkedText", ime.validAttributesForMarkedTextImpl);
    _ = cls.addMethod("firstRectForCharacterRange:actualRange:", ime.firstRectForCharacterRangeImpl);
    _ = cls.addMethod("characterIndexForPoint:", ime.characterIndexForPointImpl);
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

    // Filename is randomised so a co-operating local process can't
    // pre-position a symlink at the path and trick the writeToFile
    // call into following it elsewhere. With a 128-bit suffix the
    // path is unpredictable within the sub-millisecond create→write
    // window — same protection mkstemp(3) provides via a different
    // mechanism.
    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var hex_buf: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_buf, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/djinn-drop-{s}.png", .{hex_buf[0..]}) catch return false;
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
    if (app.g.agent.log_view) |lv| {
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
    if (app.g.ghostty.surface) |surf_ptr| {
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
    if (app.g.agent.log_view) |lv| {
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
    const view_id = app.g.term.view_id orelse return;
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
    app.g.agent.tick_count +%= 1;

    const view = objc.Object.fromId(self_id);
    checkResize(view);

    // PTY drain moved to a kqueue-backed dispatch_source_t (see
    // ptyReadHandler). Tick now only covers what's still polled:
    // window resize, agent-state sync, and the cursor-blink cadence.

    // (cursor blink + visual bell flash retired in step 10 — surface
    // owns both.)

    // Poll agent state every 15 ticks (~250ms at 60Hz).
    if (app.g.agent.tick_count % 15 == 0) {
        if (app.g.agent.state) |state| {
            if (app.g.agent.log_view) |lv| lv.syncFrom(state);

            if (app.g.agent.menubar) |menubar| {
                const snap = state.snapshot();
                if (snap.state != app.g.agent.last_state or app.g.agent.tick_count == 15) {
                    const mb_state: MenubarAgentState = switch (snap.state) {
                        .idle => .idle,
                        .working => .working,
                        .attention => .attention,
                        .done => .done,
                        .@"error" => .@"error",
                    };
                    menubar.updateState(mb_state, snap.message);
                    app.g.agent.last_state = snap.state;
                }
            }
        }
    }
}

fn acceptsFirstResponderImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

/// AppKit fires `flagsChanged:` when a modifier key is pressed or
/// released without an accompanying character key — bare Cmd hold,
/// Shift release, etc. ghostty needs these to drive Cmd-hover link
/// detection and any binding triggered by a modifier-only chord.
///
/// Logic mirrors ghostty.app's `flagsChanged` (SurfaceView_AppKit.swift):
/// look up which modifier the keycode owns, check if that modifier is
/// currently held in `modifierFlags`, then send PRESS or RELEASE.
/// Side-specific keycodes (right-shift etc.) further check the
/// device-specific bit so left + right shift don't masquerade as the
/// same key.
fn flagsChangedImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const event = objc.Object.fromId(event_id);
    const ghostty_input = @import("../ghostty/input.zig");

    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const C = ghostty_runtime.c;

    // kVK_* modifier keycodes → ghostty modifier bit.
    const mod_bit: c_uint = switch (keycode) {
        0x39 => @intCast(C.GHOSTTY_MODS_CAPS),
        0x38, 0x3C => @intCast(C.GHOSTTY_MODS_SHIFT),
        0x3B, 0x3E => @intCast(C.GHOSTTY_MODS_CTRL),
        0x3A, 0x3D => @intCast(C.GHOSTTY_MODS_ALT),
        0x37, 0x36 => @intCast(C.GHOSTTY_MODS_SUPER),
        else => return,
    };

    if (ime.preedit_len > 0) return; // mid-IME composition; modifier flicks aren't ours

    const mods_g = ghostty_input.modsFromNS(flags);

    // Right-side variant keycodes also need the device-specific bit
    // set in the raw flags, otherwise releasing right-shift while
    // left-shift is held would still register as a press.
    // NX_DEVICER*KEYMASK bits (from IOKit hidsystem/ev_keymap.h):
    const NX_DEVICERSHIFT: u64 = 0x0004;
    const NX_DEVICERCTL: u64 = 0x2000;
    const NX_DEVICERALT: u64 = 0x0040;
    const NX_DEVICERCMD: u64 = 0x0010;

    var action: c_uint = @intCast(C.GHOSTTY_ACTION_RELEASE);
    if ((@as(c_uint, @intCast(mods_g)) & mod_bit) != 0) {
        const side_held = switch (keycode) {
            0x3C => (flags & NX_DEVICERSHIFT) != 0,
            0x3E => (flags & NX_DEVICERCTL) != 0,
            0x3D => (flags & NX_DEVICERALT) != 0,
            0x36 => (flags & NX_DEVICERCMD) != 0,
            else => true,
        };
        if (side_held) action = @intCast(C.GHOSTTY_ACTION_PRESS);
    }

    const key_event = C.ghostty_input_key_s{
        .action = action,
        .mods = mods_g,
        .consumed_mods = 0,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    };
    _ = C.ghostty_surface_key(surf, key_event);
}

/// Push focus state into the ghostty surface. Without this, ghostty
/// thinks the surface is in its boot focus state forever — cursor
/// blink stays in one mode (steady block when "focused", hollow when
/// "unfocused"), and apps that subscribe to focus reports
/// (`\e[I`/`\e[O`, mode 1004) never see anything.
fn becomeFirstResponderImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    if (app.g.ghostty.surface) |surf_ptr| {
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        ghostty_runtime.surfaceSetFocus(surf, true);
    }
    return true;
}

fn resignFirstResponderImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    if (app.g.ghostty.surface) |surf_ptr| {
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        ghostty_runtime.surfaceSetFocus(surf, false);
    }
    return true;
}

/// Convert an NSEvent location (window coords) to a cell column/row.
/// cell_w/cell_h come from our font system + survive surface mode for
/// host-level cell math (find overlay anchoring + future selection).
fn eventToCell(view: objc.Object, event: objc.Object) struct { col: i32, row: i32 } {
    const win_pt = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_pt = view.msgSend(NSPoint, "convertPoint:fromView:", .{ win_pt, @as(?*anyopaque, null) });
    const bounds = view.msgSend(NSRect, "bounds", .{});

    const x = view_pt.x - app.g.term.padding_x;
    const y_top = (bounds.size.height - app.g.term.padding_y) - view_pt.y;
    const col = @as(i32, @intFromFloat(@floor(x / app.g.term.cell_w)));
    const row = @as(i32, @intFromFloat(@floor(y_top / app.g.term.cell_h)));
    return .{ .col = col, .row = row };
}

/// Shared body for mouseMoved/mouseDragged + rightMouseDragged +
/// otherMouseDragged. Position events all funnel through one
/// `ghostty_surface_mouse_pos` call — ghostty tracks button state
/// independently, so the same body handles every drag variant.
fn forwardMousePos(self_id: objc.c.id, event_id: objc.c.id) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
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

/// Shared body for mouseDown/Up + rightMouse* + otherMouse* handlers.
/// AppKit splits button events across three method families (left,
/// right, "other" = middle/4/5+); ghostty's `mouse_button` API takes
/// a single button enum, so the handlers all funnel through here.
fn forwardMouseButton(event: objc.Object, state: ghostty_runtime.c.ghostty_input_mouse_state_e) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const button_num: c_long = event.msgSend(c_long, "buttonNumber", .{});
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    _ = ghostty_runtime.c.ghostty_surface_mouse_button(
        surf,
        state,
        ghostty_input.mouseButtonFromNS(button_num),
        ghostty_input.modsFromNS(flags),
    );
}

fn mouseMovedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMousePos(self_id, event_id);
}

fn mouseDownImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(objc.Object.fromId(event_id), ghostty_runtime.c.GHOSTTY_MOUSE_PRESS);
}

fn mouseDraggedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMousePos(self_id, event_id);
}

fn rightMouseDownImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(objc.Object.fromId(event_id), ghostty_runtime.c.GHOSTTY_MOUSE_PRESS);
}

fn rightMouseUpImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(objc.Object.fromId(event_id), ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE);
}

fn rightMouseDraggedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMousePos(self_id, event_id);
}

fn otherMouseDownImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(objc.Object.fromId(event_id), ghostty_runtime.c.GHOSTTY_MOUSE_PRESS);
}

fn otherMouseUpImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(objc.Object.fromId(event_id), ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE);
}

fn otherMouseDraggedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMousePos(self_id, event_id);
}

fn mouseEnteredImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    // On enter, push the actual cursor position so ghostty's hover/link
    // state recovers from the (-1, -1) we sent on exit.
    forwardMousePos(self_id, event_id);
}

fn mouseExitedImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const event = objc.Object.fromId(event_id);

    // Mid-drag: dragging out of bounds still emits drag events with
    // real coords; don't blank the cursor on exit or hover state thrashes.
    const NSEvent = objc.getClass("NSEvent") orelse return;
    const pressed: c_ulong = NSEvent.msgSend(c_ulong, "pressedMouseButtons", .{});
    if (pressed != 0) return;

    const ghostty_input = @import("../ghostty/input.zig");
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    // Negative coords are ghostty's "cursor left viewport" sentinel.
    ghostty_runtime.c.ghostty_surface_mouse_pos(surf, -1, -1, ghostty_input.modsFromNS(flags));
}

/// Rebuild the tracking area on every layout change. NSTrackingArea
/// with `.inVisibleRect` makes its frame track the view automatically;
/// `.activeAlways` keeps mouse events flowing even when the panel
/// isn't key (we still want hover state). `.mouseMoved` is what makes
/// `mouseMoved:` actually fire — without a tracking area, AppKit only
/// sends mouse moves while a button is held.
fn updateTrackingAreasImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const view = objc.Object.fromId(self_id);

    // Drop existing areas before adding the new one.
    const areas = view.msgSend(objc.Object, "trackingAreas", .{});
    if (areas.value != null) {
        const count: c_ulong = areas.msgSend(c_ulong, "count", .{});
        var i: c_ulong = 0;
        while (i < count) : (i += 1) {
            const area = areas.msgSend(objc.Object, "objectAtIndex:", .{i});
            view.msgSend(void, "removeTrackingArea:", .{area});
        }
    }

    const NSTrackingArea = objc.getClass("NSTrackingArea") orelse return;
    const area_alloc = NSTrackingArea.msgSend(objc.Object, "alloc", .{});
    const frame = view.msgSend(NSRect, "frame", .{});
    // Options: NSTrackingMouseEnteredAndExited(0x01) | NSTrackingMouseMoved(0x02)
    //        | NSTrackingActiveAlways(0x80) | NSTrackingInVisibleRect(0x200).
    const opts: c_ulong = 0x01 | 0x02 | 0x80 | 0x200;
    const area = area_alloc.msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
        frame,
        opts,
        view.value,
        @as(?*anyopaque, null),
    });
    if (area.value == null) return;
    view.msgSend(void, "addTrackingArea:", .{area});
}

// Trackpad scroll deltas arrive as fine-grained pixels. ghostty owns
// the f64 → row accumulator + scrollback bounds; we just forward —
// but the scroll_mods byte (precision bit + momentum phase) must be
// set or ghostty treats every pixel of delta as a whole line tick.
fn scrollWheelImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const event = objc.Object.fromId(event_id);

    const surf_ptr = app.g.ghostty.surface orelse return;
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

fn mouseUpImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(objc.Object.fromId(event_id), ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE);
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
const mod_shift = keymap.mod_shift;
const mod_control = keymap.mod_control;
const mod_alt = keymap.mod_alt;
const mod_cmd = keymap.mod_cmd;

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
    if (app.g.find.mode and (flags & (mod_cmd | mod_control)) == 0) {
        find.handleKey(event, keycode);
        return;
    }

    // Palette mode is modal too — same Cmd/Ctrl fall-through as
    // find_mode so Cmd+Shift+P toggling stays reachable.
    if (app.g.palette.mode and (flags & (mod_cmd | mod_control)) == 0) {
        @import("../session/palette.zig").handleKey(event, keycode);
        return;
    }

    // Log filter chip — same modal idiom as find / palette. Cmd-held
    // chords fall through so the toggle (Cmd+Shift+L) stays reachable.
    if (app.g.log_filter.mode and (flags & (mod_cmd | mod_control)) == 0) {
        @import("../session/log_filter.zig").handleKey(event, keycode);
        return;
    }

    // Cheatsheet overlay — any non-modifier key dismisses (the
    // overlay is read-only; there's nothing meaningful to type
    // into it).
    if (app.g.cheatsheet.mode and (flags & (mod_cmd | mod_control)) == 0) {
        @import("../session/cheatsheet.zig").handleKey(event, keycode);
        return;
    }

    // IME slow path. When the input source is non-Latin (Kotoeri,
    // Pinyin, Hangul …) or we're already mid-composition, route the
    // event through AppKit's text input pipeline so insertText /
    // setMarkedText / doCommandBySelector get a chance to run. Skip
    // when Cmd / Ctrl is held — those are bindings, not text input.
    const has_command_mods = (flags & (mod_cmd | mod_control)) != 0;
    const want_ime_route = !has_command_mods and (!tis.isLatin() or ime.preedit_len > 0);
    if (want_ime_route) {
        const view = objc.Object.fromId(self_id);
        const NSArray = objc.getClass("NSArray") orelse return;
        const arr = NSArray.msgSend(objc.Object, "arrayWithObject:", .{event_id});
        ime.current_keydown = event_id;
        ime.handled_during_interpret = false;
        view.msgSend(void, "interpretKeyEvents:", .{arr.value});
        ime.current_keydown = null;
        if (ime.handled_during_interpret) return;
        // No IME callback fired (e.g. dead-key partial state) — fall
        // through to surface_key so the keypress isn't swallowed.
    }

    // Step 6b: route input to the ghostty surface via the full key
    // event API. ghostty maps the raw Mac keycode internally + uses
    // the text/codepoint fields for character semantics. Special keys
    // (arrows, enter, function keys, Ctrl-combos) all reach ghostty
    // through this single path.
    if (app.g.ghostty.surface) |surf_ptr| {
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

/// keyUp companion to keyDownImpl. Only meaningful for terminals
/// running the Kitty Keyboard Protocol in full mode (CSI u with key
/// release reporting); regular VT terminals don't observe key
/// releases. Cheap to forward unconditionally — ghostty's key encoder
/// drops the event when the surface isn't in keyboard-protocol mode.
fn keyUpImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const event = objc.Object.fromId(event_id);
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const ghostty_input = @import("../ghostty/input.zig");
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});
    const key_event = ghostty_runtime.c.ghostty_input_key_s{
        .action = ghostty_runtime.c.GHOSTTY_ACTION_RELEASE,
        .mods = ghostty_input.modsFromNS(flags),
        .consumed_mods = 0,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    };
    _ = ghostty_runtime.c.ghostty_surface_key(surf, key_event);
}

/// Force-touch pressure events. ghostty uses these for stage detection
/// (force-click → quicklook trigger) + apps that want raw pressure
/// data. We forward the raw values; quicklook itself is unimplemented
/// host-side, so stage-2 force clicks are no-ops for now.
fn pressureChangeImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const event = objc.Object.fromId(event_id);
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const stage: c_long = event.msgSend(c_long, "stage", .{});
    const pressure: f64 = event.msgSend(f64, "pressure", .{});
    ghostty_runtime.c.ghostty_surface_mouse_pressure(surf, @intCast(stage), pressure);
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

/// Mutable so user keymap overrides can rebind individual entries at
/// startup without rebuilding the table. Length stays fixed; we only
/// swap mods/keycode, never add/remove handlers.
var actions = [_]keymap.Action{
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
    .{ .name = "find_open", .mods = mod_cmd, .keycode = 3, .handler = find.actionOpen }, // Cmd+F
    .{ .name = "find_next", .mods = mod_cmd, .keycode = 5, .handler = find.actionNext }, // Cmd+G
    .{ .name = "find_prev", .mods = mod_cmd | mod_shift, .keycode = 5, .handler = find.actionPrev }, // Cmd+Shift+G
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
    // Palette switcher — Cmd+Shift+P (kVK_ANSI_P = 35).
    .{ .name = "palette_open", .mods = mod_cmd | mod_shift, .keycode = 35, .handler = actionPaletteOpen },
    // Log filter chip — Cmd+Shift+L (kVK_ANSI_L = 37).
    .{ .name = "log_filter_open", .mods = mod_cmd | mod_shift, .keycode = 37, .handler = actionLogFilterOpen },
    // Cheatsheet — Cmd+Shift+. (kVK_ANSI_Period = 47). Cmd+? would
    // be the conventional binding but macOS's system-wide "Show
    // Help Menu" shortcut consumes Cmd+Shift+/ before the event
    // reaches our keyDown handler, even in Accessory apps with no
    // Help menu set. Period is unclaimed and stable across layouts.
    .{ .name = "cheatsheet_open", .mods = mod_cmd | mod_shift, .keycode = 47, .handler = actionCheatsheetOpen },
    // Duplicate active profile — Cmd+Shift+N (kVK_ANSI_N = 45).
    .{ .name = "profile_duplicate", .mods = mod_cmd | mod_shift, .keycode = 45, .handler = actionProfileDuplicate },
    // Close active profile — Cmd+Shift+W (kVK_ANSI_W = 13). Tab-close
    // convention; refuses to remove the last profile.
    .{ .name = "profile_close", .mods = mod_cmd | mod_shift, .keycode = 13, .handler = actionProfileClose },
    // Cycle theme override — Cmd+Shift+T (kVK_ANSI_T = 17).
    .{ .name = "theme_toggle", .mods = mod_cmd | mod_shift, .keycode = 17, .handler = actionThemeToggle },
    // Restart dead session — Cmd+R re-spawns with the same profile command.
    .{ .name = "restart_session", .mods = mod_cmd, .keycode = 15, .handler = actionRestartSession },
    // Drop to a plain shell — Cmd+Shift+R forces /bin/zsh for the session.
    .{ .name = "shell_session", .mods = mod_cmd | mod_shift, .keycode = 15, .handler = actionShellSession },
};

/// Override an entry's binding by name. Called from main() during
/// startup for each user keymap entry. Unknown names log + are
/// ignored — a typo in config shouldn't crash djinn.
pub fn rebind(name: []const u8, mods: u64, keycode: u16) bool {
    return keymap.rebind(&actions, name, mods, keycode);
}

/// Read-only access to the host action table. The cheatsheet
/// overlay (`session/cheatsheet.zig`) iterates this to render the
/// live keymap (reflects user `rebind` overrides).
pub fn actionList() []const keymap.Action {
    return &actions;
}

fn dispatchAction(flags: u64, keycode: u16) bool {
    return keymap.dispatch(&actions, flags, keycode);
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
    const lv = app.g.agent.log_view orelse return;
    const log_frame = lv.view.msgSend(NSRect, "frame", .{});
    setLogPaneHidden(log_frame.size.width > 0);
}

/// Re-run the container's tab-aware reflow against the live log
/// width, without changing log visibility. Used by hot-config-reload's
/// session add/remove path: after building or removing the tab
/// strip we need every child (terminal, log, divider, surface_hosts)
/// to absorb / release `tab_strip.tab_h` of vertical space, and
/// `applyLogLayout` is the canonical place where that math lives.
/// Reads the current log width off the live frame so a user's
/// drag-resize or Cmd+/ toggle isn't reset.
pub fn relayout() void {
    const container_id = app.g.layout.container_id orelse return;
    const container = objc.Object.fromId(container_id);
    const c_bounds = container.msgSend(NSRect, "bounds", .{});

    var log_w: f64 = 0;
    if (app.g.agent.log_view) |lv| {
        log_w = lv.view.msgSend(NSRect, "frame", .{}).size.width;
    }
    const eff_div_w: f64 = if (log_w > 0) divider_width else 0;
    const term_w = @max(1.0, c_bounds.size.width - log_w - eff_div_w);
    applyLogLayout(container, term_w, log_w, c_bounds.size.height);
}

/// Show or hide the log pane at runtime. Hidden state collapses log +
/// divider frames to width 0 (Metal-layer compositor honors zero-pixel
/// frames, unlike setHidden which left translucent leaks). Stays in
/// the view tree to keep responder-chain + key-window state intact on
/// borderless NSPanels.
pub fn setLogPaneHidden(hide: bool) void {
    const view_id = app.g.term.view_id orelse return;
    const term_view = objc.Object.fromId(view_id);
    const container = term_view.msgSend(objc.Object, "superview", .{});
    if (container.value == null) return;

    const c_bounds = container.msgSend(NSRect, "bounds", .{});
    const cfg = app.g.config orelse return;
    const layout = @import("../window/layout.zig");
    const log_baseline_w: f64 = layout.computeLogWidth(c_bounds.size.width, cfg);
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

// Tab switching — thin wrappers around
// `ghostty.surface_lifecycle.activateSession(idx)`. Generated
// explicitly (no `comptime` lambda) so each handler has a distinct
// function pointer the action table can dispatch through.
fn activateSessionByIndex(idx: usize) void {
    _ = @import("../ghostty/surface_lifecycle.zig").activateSession(idx);
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

fn actionLogFilterOpen() void {
    @import("../session/log_filter.zig").actionOpen();
}

fn actionCheatsheetOpen() void {
    @import("../session/cheatsheet.zig").actionOpen();
}

fn actionProfileDuplicate() void {
    @import("../session/profile_manager.zig").duplicateActive();
}

fn actionProfileClose() void {
    @import("../session/profile_manager.zig").closeActive();
}

fn actionThemeToggle() void {
    // Cycle null (system) → light → dark → null. reloadTheme forces
    // a full reapply on each step by clearing the last_appearance
    // cache; otherwise the chrome stays on the cached variant when
    // the override resolves to the same value as the previous one.
    // Zig 0.15 doesn't switch directly on `?Enum`, so unwrap first.
    if (app.g.theme.override) |cur| {
        app.g.theme.override = switch (cur) {
            .light => @as(?theme_mod.Appearance, .dark),
            .dark => null,
        };
    } else {
        app.g.theme.override = .light;
    }
    reloadTheme();

    // Log the new state to the agent log pane. The visible chrome
    // flip only happens when the user's ghostty config has a
    // `theme = light:X,dark:Y` split — without it the override is
    // applied internally but the static theme palette doesn't
    // change, leaving the action looking like a no-op. Surfacing
    // the override in the log makes the action observable.
    if (app.g.agent.state) |st| {
        const label: []const u8 = if (app.g.theme.override) |cur| switch (cur) {
            .light => "theme override → light",
            .dark => "theme override → dark",
        } else "theme override cleared (follow system)";
        st.appendLog(.info, label) catch {};
    }
}

fn actionPaletteOpen() void {
    @import("../session/palette.zig").open();
}

fn actionRestartSession() void {
    @import("../ghostty/surface_lifecycle.zig").restartActiveSession(null);
}

fn actionShellSession() void {
    @import("../ghostty/surface_lifecycle.zig").restartActiveSession("/bin/zsh");
}

// IME (NSTextInputClient) bindings live in `terminal/ime.zig`. The
// Cocoa view class registration above wires `ime.*Impl` into AppKit;
// keyDownImpl + flagsChangedImpl read `ime.preedit_len` /
// `ime.current_keydown` / `ime.handled_during_interpret` to gate the
// fall-through to ghostty_surface_key.

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
    app.g.theme.last_appearance = 0;
    reapplyTheme();
}

/// Re-resolve theme only if system appearance has actually changed.
/// Cheap no-op when stable — used by panel show path to recover from
/// system flips that happened while the panel was offscreen and
/// AppKit suppressed viewDidChangeEffectiveAppearance.
pub fn reapplyThemeIfChanged() void {
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
    // Runtime override (Cmd+Shift+T) wins over system appearance.
    // When null, fall back to NSAppearance probe.
    const current_appearance = app.g.theme.override orelse theme_mod.detectSystemAppearance();
    const current_tag: u8 = switch (current_appearance) {
        .light => 1,
        .dark => 2,
    };
    if (app.g.theme.last_appearance == current_tag) return;

    // Push the new appearance to ghostty + reload its Config BEFORE
    // theme.resolve runs. theme.resolve reads `app.g.ghostty.config`
    // via applyFromGhostty, so the chrome palette is sourced from
    // whichever variant ghostty currently has resolved for `theme =
    // light:X,dark:Y`. If we resolve first, chrome locks onto the
    // pre-flip variant while the surface (which ghostty repaints on
    // its own pipeline) flips correctly — produces the visible
    // tab-strip / panel-bg mismatch reported on light↔dark flips.
    ghostty_runtime.appSetColorScheme(current_appearance == .dark);
    ghostty_runtime.reloadConfigFromDisk();

    var new_theme = theme_mod.resolve(allocator, .{
        .inherit_ghostty_config = config.theme.inherit_ghostty,
        .ghostty_cfg = app.g.ghostty.config,
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

    const new_style = chrome_mod.Style.fromTheme(new_theme);
    app.g.theme.chrome_style = new_style;
    if (app.g.agent.log_view) |lv| lv.applyStyle(new_style);
    find.applyOverlayStyle(new_style);
    @import("../session/tab_strip.zig").applyStyle(new_style);

    if (app.g.window.panel) |p| {
        const bg_r = @as(f64, @floatFromInt(new_theme.background.r)) / 255.0;
        const bg_g = @as(f64, @floatFromInt(new_theme.background.g)) / 255.0;
        const bg_b = @as(f64, @floatFromInt(new_theme.background.b)) / 255.0;
        p.setBackgroundColor(bg_r, bg_g, bg_b, new_theme.opacity);
    }

    // Stamp last_appearance only after a successful apply. Pre-stamping
    // and bailing on theme.resolve failure would poison the guard —
    // every subsequent call would short-circuit until the system
    // flipped a second time.
    app.g.theme.last_appearance = current_tag;
}
