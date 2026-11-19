const std = @import("std");
const platform = @import("../io/platform.zig");
const objc = @import("objc");
const app = @import("../app.zig");
const ghostty_runtime = @import("../ghostty/runtime.zig");
const menubar_mod = @import("../notify/menubar.zig");
const tis = @import("tis.zig");
const chrome_mod = @import("../chrome.zig");
const keymap = @import("keymap.zig");
const find = @import("find.zig");
const font_mod = @import("font.zig");
const ime = @import("ime.zig");
const Ticket = @import("../ghostty/surface_lifecycle.zig").Ticket;
const Session = @import("../session/manager.zig").Session;

const cg = @import("darwin-c");

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

// Cross-callback state lives in app.g; class registration stays local.
var g_class_registered: bool = false;

/// Main-thread physical key ownership, separate from modifier flagsChanged
/// reporting. macOS virtual keycodes fit in one byte. Never retain a surface
/// pointer: a press belongs to one session incarnation until its release.
const ForwardedKeys = struct {
    sources: [256]?Ticket = @splat(null),

    fn begin(self: *ForwardedKeys, keycode: u16, repeat: bool) void {
        if (keycode < self.sources.len and !repeat) self.sources[keycode] = null;
    }

    fn forward(self: *ForwardedKeys, keycode: u16, repeat: bool, source: Ticket) bool {
        if (keycode >= self.sources.len) return false;
        if (repeat) {
            const original = self.sources[keycode] orelse return false;
            // A consumed initial press cannot become a terminal repeat,
            // and holding a key across a tab switch cannot transfer it.
            return original.session_id == source.session_id and original.generation == source.generation;
        }
        self.sources[keycode] = source;
        return true;
    }

    fn release(self: *ForwardedKeys, keycode: u16) ?Ticket {
        if (keycode >= self.sources.len) return null;
        const source = self.sources[keycode];
        self.sources[keycode] = null;
        return source;
    }
};

var g_forwarded_keys: ForwardedKeys = .{};

fn keySourceSurface(ticket: Ticket, sessions: []const *Session) ?*anyopaque {
    for (sessions) |session| {
        if (ticket.matches(session)) return session.surface;
    }
    return null;
}

fn activeKeySource(surface: *anyopaque) ?Ticket {
    const sm = app.g.session_manager orelse return null;
    const session = sm.active();
    if (session.surface != surface) return null;
    return .{ .session_id = session.id, .generation = session.surface_generation };
}

test "key releases require a forwarded physical press and preserve repeat ownership" {
    var keys: ForwardedKeys = .{};
    const source: Ticket = .{ .session_id = 1, .generation = 3 };
    const other: Ticket = .{ .session_id = 2, .generation = 1 };
    // Host/find/IME consumed the down: even a later repeat cannot acquire it.
    keys.begin(12, false);
    keys.begin(12, true);
    try std.testing.expect(!keys.forward(12, true, source));
    try std.testing.expectEqual(@as(?Ticket, null), keys.release(12));

    keys.begin(12, false);
    try std.testing.expect(keys.forward(12, false, source));
    keys.begin(12, true);
    try std.testing.expect(keys.forward(12, true, source));
    try std.testing.expect(!keys.forward(12, true, other));
    try std.testing.expectEqualDeep(source, keys.release(12).?);
    try std.testing.expectEqual(@as(?Ticket, null), keys.release(12));

    // A fresh, consumed down clears a stale press if AppKit lost its up.
    try std.testing.expect(keys.forward(12, false, source));
    keys.begin(12, false);
    try std.testing.expectEqual(@as(?Ticket, null), keys.release(12));
    // Independent held keys must not clear one another.
    try std.testing.expect(keys.forward(12, false, source));
    keys.begin(13, false);
    try std.testing.expect(keys.forward(13, false, other));
    try std.testing.expectEqualDeep(source, keys.release(12).?);
    try std.testing.expectEqualDeep(other, keys.release(13).?);
}

test "key release resolves the live source not the active or replacement surface" {
    const first: *anyopaque = @ptrFromInt(0x1000);
    const second: *anyopaque = @ptrFromInt(0x2000);
    var sessions = [_]Session{
        .{ .id = 1, .surface_generation = 3, .surface = first, .profile = .{ .name = "first" } },
        .{ .id = 2, .surface_generation = 1, .surface = second, .profile = .{ .name = "second" } },
    };
    const source: Ticket = .{ .session_id = 1, .generation = 3 };
    // Source need not be the selected session or the first array entry.
    const ordered = [_]*Session{ &sessions[1], &sessions[0] };
    try std.testing.expectEqual(first, keySourceSurface(source, &ordered).?);
    sessions[0].surface = null;
    try std.testing.expectEqual(@as(?*anyopaque, null), keySourceSurface(source, &ordered));
    sessions[0].surface = first; // allocator may reuse the same address
    sessions[0].surface_generation += 1;
    try std.testing.expectEqual(@as(?*anyopaque, null), keySourceSurface(source, &ordered));
    try std.testing.expectEqual(@as(?*anyopaque, null), keySourceSurface(source, ordered[0..1]));
}

/// Explicit paste/drop input uses Ghostty's protected paste API. IME commits
/// use ghostty_surface_text separately in ime.zig; they must not trigger paste
/// confirmation. Ghostty copies the sentinel-terminated payload before return.
fn forwardText(text: []const u8) bool {
    const surf_ptr = app.g.ghostty.surface orelse return false;
    const allocator = std.heap.page_allocator;
    const text_z = allocator.dupeSentinel(u8, text, 0) catch return false;
    defer allocator.free(text_z);
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_paste_text(surf, text_z.ptr, text_z.len);
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
        // the path for the running command to consume.
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
        ta.msgSend(void, "release", .{});

        // Find-overlay NSTextField — read-only display chip parented
        // to the terminal view. See `find.createOverlay` for the layer
        // setup and find-mode dataflow.
        try find.createOverlay(view, width, height, style);

        // Frame/bounds notifications fire for programmatic and hidden-view
        // changes as well as live resize. No host polling timer is needed.
        view.msgSend(void, "setPostsFrameChangedNotifications:", .{@as(c_int, 1)});
        view.msgSend(void, "setPostsBoundsChangedNotifications:", .{@as(c_int, 1)});
        if (objc.getClass("NSNotificationCenter")) |NotificationCenter| {
            const center = NotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
            for ([_][*:0]const u8{ "NSViewFrameDidChangeNotification", "NSViewBoundsDidChangeNotification" }) |name| {
                const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, name)});
                center.msgSend(void, "addObserver:selector:name:object:", .{
                    view, objc.sel("djinnViewGeometryDidChange:"), ns_name, view,
                });
            }
        }

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
        checkResize(self.view);
    }
};

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
    _ = cls.addMethod("djinnViewGeometryDidChange:", geometryDidChangeImpl);
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
    _ = cls.addMethod("doCommandBySelector:", imeCommandImpl);
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

fn geometryDidChangeImpl(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    checkResize(objc.Object.fromId(self_id));
}

fn viewDidChangeBackingPropertiesImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    syncLayerScale(view);
    checkResize(view);
}

fn viewDidMoveToWindowImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const view = objc.Object.fromId(self_id);
    syncLayerScale(view);
    checkResize(view);
}

/// AppKit calls this when system appearance flips (light ↔ dark) for
/// any view in the hierarchy. Re-resolve the theme through the same
/// pipeline main() uses on startup, then reapply colors to the
/// terminal and panel without rebuilding anything.
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
/// TUI requested DEC mode 2004 — the application treats the result as a
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
/// and paste the resulting path for the running command to consume.
/// Used when a drop carried image bytes but no NSURL — Photos, Cmd+
/// Shift+4 screenshots, browser drags, etc.
fn tryDropImage(pb: objc.Object) bool {
    const NSImage = objc.getClass("NSImage") orelse return false;
    const NSArray = objc.getClass("NSArray") orelse return false;
    const NSBitmapImageRep = objc.getClass("NSBitmapImageRep") orelse return false;
    const NSDictionary = objc.getClass("NSDictionary") orelse return false;

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

    // Random naming plus exclusive mode-0600 creation prevents following a
    // pre-positioned path and keeps clipboard image bytes private.
    var rand_buf: [16]u8 = undefined;
    platform.io().randomSecure(&rand_buf) catch return false;
    var hex_buf: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_buf, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    var path_buf: [128]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/tmp/djinn-drop-{s}.png", .{hex_buf[0..]}, 0) catch return false;
    const bytes = png.msgSend(?[*]const u8, "bytes", .{}) orelse return false;
    const length = png.msgSend(usize, "length", .{});
    const io = platform.io();
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return false;
    var handed_off = false;
    defer if (!handed_off) std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    {
        defer file.close(io);
        file.writeStreamingAll(io, bytes[0..length]) catch return false;
    }
    // A rejected paste has no consumer, so remove only this exact owned path.
    // An accepted shell path has no completion acknowledgement: retaining it
    // is safer than deleting it on a timer, shutdown, or a later app launch.
    handed_off = forwardText(path);
    return handed_off;
}

/// Final size synchronization after AppKit's live-resize cascade.
fn viewDidEndLiveResizeImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    checkResize(objc.Object.fromId(self_id));
}

/// Explicit recovery hook for panel show, window/screen notifications,
/// and callers that bind or activate a surface after layout has settled.
pub fn syncResize() void {
    const view_id = app.g.term.view_id orelse return;
    const view = objc.Object.fromId(view_id);
    syncLayerScale(view);
    checkResize(view);
}

/// Push point bounds and backing scale on geometry events, including
/// while hidden. All session hosts share the input overlay's frame, so
/// inactive surfaces stay sized too. Ghostty owns rendering and wakeups.
fn checkResize(view: objc.Object) void {
    const bounds = view.msgSend(NSRect, "bounds", .{});
    const window = view.msgSend(objc.Object, "window", .{});
    const backing_scale = if (window.value != null) window.msgSend(f64, "backingScaleFactor", .{}) else 1.0;
    const scale = if (backing_scale > 0) backing_scale else 1.0;
    const px_w: u32 = @intFromFloat(@max(1.0, bounds.size.width * scale));
    const px_h: u32 = @intFromFloat(@max(1.0, bounds.size.height * scale));
    if (app.g.session_manager) |sm| {
        for (sm.sessions.items) |sess| {
            if (sess.surface) |surface| {
                const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surface);
                ghostty_runtime.surfaceSetContentScale(surf, scale);
                ghostty_runtime.surfaceSetSize(surf, px_w, px_h);
            }
        }
    } else if (app.g.ghostty.surface) |surface| {
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surface);
        ghostty_runtime.surfaceSetContentScale(surf, scale);
        ghostty_runtime.surfaceSetSize(surf, px_w, px_h);
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
fn becomeFirstResponderImpl(self_id: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    const view = objc.Object.fromId(self_id);
    const window = view.msgSend(objc.Object, "window", .{});
    // A programmatic responder change (e.g. ending search before a
    // background session switch) must not refocus an inactive window.
    const focused = window.value != null and window.msgSend(bool, "isKeyWindow", .{});
    if (app.g.ghostty.surface) |surf_ptr| {
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        ghostty_runtime.surfaceSetFocus(surf, focused);
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
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    forwardMousePosTo(surf, objc.Object.fromId(self_id), objc.Object.fromId(event_id));
}

fn forwardMousePosTo(surf: ghostty_runtime.c.ghostty_surface_t, view: objc.Object, event: objc.Object) void {
    const ghostty_input = @import("../ghostty/input.zig");
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
fn forwardMouseButton(self_id: objc.c.id, event_id: objc.c.id, state: ghostty_runtime.c.ghostty_input_mouse_state_e) void {
    const surf_ptr = app.g.ghostty.surface orelse return;
    const ghostty_input = @import("../ghostty/input.zig");
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const event = objc.Object.fromId(event_id);
    // A click/release may arrive without any preceding move (including on
    // an inactive panel). Position and button must target the same surface.
    forwardMousePosTo(surf, objc.Object.fromId(self_id), event);
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

fn mouseDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(self_id, event_id, ghostty_runtime.c.GHOSTTY_MOUSE_PRESS);
}

fn mouseDraggedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMousePos(self_id, event_id);
}

fn rightMouseDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(self_id, event_id, ghostty_runtime.c.GHOSTTY_MOUSE_PRESS);
}

fn rightMouseUpImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(self_id, event_id, ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE);
}

fn rightMouseDraggedImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMousePos(self_id, event_id);
}

fn otherMouseDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(self_id, event_id, ghostty_runtime.c.GHOSTTY_MOUSE_PRESS);
}

fn otherMouseUpImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(self_id, event_id, ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE);
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
    area.msgSend(void, "release", .{});
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

fn mouseUpImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    forwardMouseButton(self_id, event_id, ghostty_runtime.c.GHOSTTY_MOUSE_RELEASE);
}

/// Paste actions (including rebound Cmd+V) belong to the query while find
/// is open. Otherwise the surface handles terminal bracketed-paste mode.
fn pasteFromClipboard() void {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    if (pb.value == null) return;

    const NSString = objc.getClass("NSString") orelse return;
    const type_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "public.utf8-plain-text")});
    if (type_name.value == null) return;
    const ns_str = pb.msgSend(objc.Object, "stringForType:", .{type_name});
    if (ns_str.value == null) return;

    const utf8_ptr = ns_str.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return;
    // Preserve the explicit byte length, including embedded NULs. Find
    // rejects binary input; Ghostty's clipboard API handles paste policy.
    const byte_len = ns_str.msgSend(c_ulong, "lengthOfBytesUsingEncoding:", .{@as(c_ulong, 4)});
    const text = utf8_ptr[0..@intCast(byte_len)];
    if (app.g.find.mode) {
        find.appendText(text);
        return; // Even rejected input must never fall through to the shell.
    }
    if (text.len == 0) return;

    _ = forwardText(text);
}

// NSEventModifierFlag bits (high bits of NSUInteger).
const mod_shift = keymap.mod_shift;
const mod_control = keymap.mod_control;
const mod_alt = keymap.mod_alt;
const mod_cmd = keymap.mod_cmd;

/// All physical key encoders, including AppKit's IME command fallback,
/// share source ownership. Text commits and preedit never acquire a key.
fn forwardOwnedKey(surface: *anyopaque, keycode: u16, repeat: bool, event: ghostty_runtime.c.ghostty_input_key_s) void {
    const source = activeKeySource(surface) orelse return;
    if (!g_forwarded_keys.forward(keycode, repeat, source)) return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surface);
    _ = ghostty_runtime.c.ghostty_surface_key(surf, event);
}

fn imeCommandImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.SEL) callconv(.c) void {
    ime.handled_during_interpret = true;
    const event_id = ime.current_keydown orelse return;
    const surf_ptr = app.g.ghostty.surface orelse return;
    const event = objc.Object.fromId(event_id);
    const ghostty_input = @import("../ghostty/input.zig");
    const keycode = event.msgSend(c_ushort, "keyCode", .{});
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const mods = ghostty_input.modsFromNS(flags);
    const repeat = event.msgSend(bool, "isARepeat", .{});
    forwardOwnedKey(surf_ptr, keycode, repeat, .{
        .action = if (repeat) ghostty_runtime.c.GHOSTTY_ACTION_REPEAT else ghostty_runtime.c.GHOSTTY_ACTION_PRESS,
        .mods = mods,
        .consumed_mods = mods,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    });
}

fn keyDownImpl(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const event = objc.Object.fromId(event_id);

    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});
    // Clear stale ownership before any host/find/IME early return. Repeats
    // retain the initial press, even when an individual repeat is consumed.
    g_forwarded_keys.begin(keycode, is_repeat);

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
        forwardOwnedKey(surf_ptr, keycode, is_repeat, key_event);
        return;
    }
}

/// Release only a press actually forwarded to this still-live source.
/// Selection changes, consumed downs, and destroyed/recreated surfaces must
/// never leak an orphan keyUp into the currently selected terminal.
fn keyUpImpl(_: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const event = objc.Object.fromId(event_id);
    const keycode: u16 = event.msgSend(c_ushort, "keyCode", .{});
    const source = g_forwarded_keys.release(keycode) orelse return;
    const sm = app.g.session_manager orelse return;
    const surf_ptr = keySourceSurface(source, sm.sessions.items) orelse return;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    const ghostty_input = @import("../ghostty/input.zig");
    const flags: u64 = @intCast(event.msgSend(c_ulong, "modifierFlags", .{}));
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

// Ghostty owns rendering. This transparent overlay handles native input,
// IME, and mouse events without a second terminal drawing pipeline.

// ─── Action table ────────────────────────────────────────────────────
//
// Single source of truth for app-level keyboard shortcuts. keyDownImpl
// asks dispatchAction first; matching entries fire and short-circuit
// the rest of the keyDown pipeline. Adding a new shortcut is one line
// here + a function — no more growing the if-chain in keyDownImpl.

/// Mutable so user keymap overrides can rebind individual entries at
/// startup without rebuilding the table. Length stays fixed; we only
/// swap mods/keycode, never add/remove handlers.
const default_actions = [_]keymap.Action{
    // Selection / clipboard
    .{ .name = "copy", .mods = mod_cmd, .keycode = 8, .handler = actionCopy }, // Cmd+C
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
    // Find overlay — Cmd+F opens the search field;
    // Cmd+G / Cmd+Shift+G cycle through matches.
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
    // Close the ordinary session without removing its configured profile.
    .{ .name = "close_session", .mods = mod_cmd | mod_shift, .keycode = 13, .handler = actionCloseSession },
    // Cycle theme override — Cmd+Shift+T (kVK_ANSI_T = 17).
    .{ .name = "theme_toggle", .mods = mod_cmd | mod_shift, .keycode = 17, .handler = actionThemeToggle },
    // Restart dead session — Cmd+R re-spawns with the same profile command.
    .{ .name = "restart_session", .mods = mod_cmd, .keycode = 15, .handler = actionRestartSession },
};
var actions = default_actions;

pub fn resetBindings() void {
    actions = default_actions;
}

fn actionCopy() void {
    forwardBindingAction("copy_to_clipboard");
}

/// Override an entry's binding by name. Called from main() during
/// startup for each user keymap entry. Unknown names log + are
/// ignored — a typo in config shouldn't crash djinn.
pub fn rebind(name: []const u8, mods: u64, keycode: u16) bool {
    return keymap.rebind(&actions, name, mods, keycode);
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

fn scrollByPage(direction: i32) void {
    forwardBindingAction(if (direction < 0) "scroll_page_up" else "scroll_page_down");
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

/// Reflow the terminal-first container and synchronize its surfaces.
pub fn relayout() void {
    @import("../window/layout.zig").relayout();
    syncResize();
}

fn actionClearScrollback() void {
    forwardBindingAction("clear_screen");
}

// Tab switching — thin wrappers around
// `ghostty.surface_lifecycle.activateSession(idx)`. Generated
// explicitly (no `comptime` lambda) so each handler has a distinct
// function pointer the action table can dispatch through.
fn activateSessionByIndex(idx: usize) void {
    _ = @import("../ghostty/surface_lifecycle.zig").activateSession(idx);
}
fn actionTab1() void {
    activateSessionByIndex(0);
}
fn actionTab2() void {
    activateSessionByIndex(1);
}
fn actionTab3() void {
    activateSessionByIndex(2);
}
fn actionTab4() void {
    activateSessionByIndex(3);
}
fn actionTab5() void {
    activateSessionByIndex(4);
}
fn actionTab6() void {
    activateSessionByIndex(5);
}
fn actionTab7() void {
    activateSessionByIndex(6);
}
fn actionTab8() void {
    activateSessionByIndex(7);
}
fn actionTab9() void {
    activateSessionByIndex(8);
}
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

fn actionCloseSession() void {
    @import("../ghostty/surface_lifecycle.zig").closeActiveSession();
}

fn actionThemeToggle() void {
    // Cycle null (system) → light → dark → null. reloadTheme forces
    // a full reapply on each step by clearing the last_appearance
    // cache; otherwise the chrome stays on the cached variant when
    // the override resolves to the same value as the previous one.
    // Unwrap the system-following state before cycling explicit variants.
    if (app.g.theme.override) |cur| {
        app.g.theme.override = switch (cur) {
            .light => @as(?theme_mod.Appearance, .dark),
            .dark => null,
        };
    } else {
        app.g.theme.override = .light;
    }
    reloadTheme();
}

fn actionRestartSession() void {
    @import("../ghostty/surface_lifecycle.zig").restartActiveSession(null);
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
// the new colors into the terminal and panel.

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
        .inherit_ghostty_config = true, // Runtime already chose inherited files or standalone defaults.
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
