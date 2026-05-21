//! NSDraggingDestination protocol handlers for the terminal view.
//! Two impl callbacks (`draggingEnteredImpl`, `performDragOperationImpl`)
//! registered on the `DjinnTerminalView` class in view.zig, plus the
//! image-fallback path (`tryDropImage`) that turns raw pasteboard
//! bitmaps into a `/tmp/djinn-drop-*.png` path the agent's read tool
//! can pick up.
//!
//! No coupling to the responder chain — these handlers reach for the
//! pasteboard and forward UTF-8 to the ghostty surface. `forwardText`
//! is duplicated locally for the same reason it lives separately in
//! `ime.zig` and `find.zig`: keeps cross-module imports flat.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const ghostty_runtime = @import("../ghostty/runtime.zig");

/// Forward a UTF-8 blob to the ghostty surface. Returns false when the
/// surface isn't bound yet — drag-drop treats that as a hard failure
/// (the drop is dropped on the floor).
fn forwardText(text: []const u8) bool {
    const surf_ptr = app.g.ghostty.surface orelse return false;
    const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
    ghostty_runtime.c.ghostty_surface_text(surf, text.ptr, text.len);
    return true;
}

/// NSDraggingDestination: tell AppKit we accept the drag. Returns
/// `NSDragOperationCopy` so the cursor shows the "+" badge.
pub fn draggingEnteredImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) c_ulong {
    return 1; // NSDragOperationCopy
}

/// Pull file URLs off the dragging pasteboard, format paths into a
/// shell-safe space-separated string, and paste them into the PTY.
/// Wraps in single quotes when paths contain whitespace or shell
/// metacharacters; otherwise writes the raw path so completion + tab
/// expansion still chain cleanly. Uses bracketed paste when the
/// running TUI requested DEC mode 2004 — CC's REPL treats the result
/// as a pasted block instead of typed input.
pub fn performDragOperationImpl(_: objc.c.id, _: objc.c.SEL, sender_id: objc.c.id) callconv(.c) bool {
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
/// and paste the resulting path so the agent's read tool can pick it
/// up. Used when a drop carried image bytes but no NSURL — Photos,
/// Cmd+Shift+4 screenshots, browser drags, etc.
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
