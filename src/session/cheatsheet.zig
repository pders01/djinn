//! Keyboard cheatsheet overlay — Cmd+? lists every host action +
//! its current binding. Reads `terminal/view.zig:actionList()` so
//! the rendered table reflects live `rebind` overrides (user
//! keymap entries from `~/.config/djinn/config` already mutated
//! the table at startup).
//!
//! Read-only modal: Esc / Cmd+? again dismisses. No filter input
//! — the binding count is small enough (~25 actions) that a
//! single column fits comfortably.
//!
//! Built on NSScrollView + NSTextView so we don't have to manage
//! per-row click handlers or custom drawRect. Pattern is closer to
//! the agent log pane than to the palette overlay.

const std = @import("std");
const objc = @import("objc");
const app = @import("../app.zig");
const chrome = @import("../chrome.zig");
const keymap = @import("../terminal/keymap.zig");
const view_mod = @import("../terminal/view.zig");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const sheet_w: f64 = 360;
const sheet_h: f64 = 360;

pub fn actionOpen() void {
    if (app.g.cheatsheet.mode) {
        close();
        return;
    }
    app.g.cheatsheet.mode = true;
    mountOverlay();
}

pub fn close() void {
    if (!app.g.cheatsheet.mode) return;
    app.g.cheatsheet.mode = false;
    if (app.g.cheatsheet.view_id) |vid| {
        objc.Object.fromId(vid).msgSend(void, "removeFromSuperview", .{});
        app.g.cheatsheet.view_id = null;
    }
    if (app.g.term.view_id) |tid| {
        const term = objc.Object.fromId(tid);
        const window = term.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            _ = window.msgSend(c_int, "makeFirstResponder:", .{term});
        }
    }
}

/// Caller (keyDownImpl) only invokes this when `cheatsheet.mode` is
/// true and no Cmd / Ctrl chord is held. Any key dismisses; the
/// overlay is read-only and there's nothing meaningful to type.
pub fn handleKey(_: objc.Object, _: u16) void {
    close();
}

fn mountOverlay() void {
    const container_id = app.g.layout.container_id orelse return;
    const container = objc.Object.fromId(container_id);
    const c_bounds = container.msgSend(NSRect, "bounds", .{});

    const NSView = objc.getClass("NSView") orelse return;
    const NSScrollView = objc.getClass("NSScrollView") orelse return;
    const NSTextView = objc.getClass("NSTextView") orelse return;
    const NSColor = objc.getClass("NSColor") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const style = app.g.theme.chrome_style orelse return;

    // Center the sheet in the container. Sized to fit ~15 rows
    // without scroll; longer action tables fall back to scrolling.
    const x = (c_bounds.size.width - sheet_w) / 2.0;
    const y = (c_bounds.size.height - sheet_h) / 2.0;

    const wrapper_alloc = NSView.msgSend(objc.Object, "alloc", .{});
    const wrapper = wrapper_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = sheet_w, .height = sheet_h },
    }});
    wrapper.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
    const ns_chip_bg = chrome.nsColorFromRgb(NSColor, style.chip.bg);
    const layer = wrapper.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        layer.msgSend(void, "setBackgroundColor:", .{ns_chip_bg.msgSend(?*anyopaque, "CGColor", .{})});
        layer.msgSend(void, "setCornerRadius:", .{@as(f64, 6)});
        layer.msgSend(void, "setMasksToBounds:", .{@as(c_int, 1)});
        layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1)});
        const border = chrome.nsColorFromRgb(NSColor, style.chip.border);
        layer.msgSend(void, "setBorderColor:", .{border.msgSend(?*anyopaque, "CGColor", .{})});
    }

    const scroll_alloc = NSScrollView.msgSend(objc.Object, "alloc", .{});
    const scroll = scroll_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = sheet_w, .height = sheet_h },
    }});
    scroll.msgSend(void, "setHasVerticalScroller:", .{@as(c_int, 1)});
    scroll.msgSend(void, "setHasHorizontalScroller:", .{@as(c_int, 0)});
    scroll.msgSend(void, "setBorderType:", .{@as(c_long, 0)});
    scroll.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
    scroll.msgSend(void, "setBackgroundColor:", .{ns_chip_bg});
    wrapper.msgSend(void, "addSubview:", .{scroll});

    const tv_alloc = NSTextView.msgSend(objc.Object, "alloc", .{});
    const tv = tv_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = sheet_w, .height = sheet_h },
    }});
    tv.msgSend(void, "setEditable:", .{@as(c_int, 0)});
    tv.msgSend(void, "setSelectable:", .{@as(c_int, 0)});
    tv.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
    tv.msgSend(void, "setBackgroundColor:", .{ns_chip_bg});
    tv.msgSend(void, "setTextContainerInset:", .{NSSize{ .width = 16, .height = 16 }});
    const font = chrome.chromeFont(NSFont, style.font_family, style.font_size_sm);
    tv.msgSend(void, "setFont:", .{font});
    scroll.msgSend(void, "setDocumentView:", .{tv});

    // Populate. One row per action: `<binding>  <name>`. Padding
    // computed from longest binding so the action names line up.
    populateTextView(tv, style);

    container.msgSend(void, "addSubview:", .{wrapper});
    app.g.cheatsheet.view_id = wrapper.value;
}

fn populateTextView(tv: objc.Object, style: chrome.Style) void {
    const NSString = objc.getClass("NSString") orelse return;
    const NSColor = objc.getClass("NSColor") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSDictionary = objc.getClass("NSDictionary") orelse return;
    const NSAttributedString = objc.getClass("NSMutableAttributedString") orelse return;

    const actions = view_mod.actionList();

    // First pass: compute max binding width for column alignment.
    var max_binding: usize = 0;
    var pad_buf: [64]u8 = undefined;
    for (actions) |a| {
        const formatted = formatBinding(a.mods, a.keycode, &pad_buf) catch continue;
        if (formatted.len > max_binding) max_binding = formatted.len;
    }

    const root_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const root = root_alloc.msgSend(objc.Object, "init", .{});
    defer root.msgSend(void, "release", .{});

    appendRun(root, NSString, NSColor, NSFont, NSDictionary, "Keyboard cheatsheet\n", style.fg, style, true);
    appendRun(root, NSString, NSColor, NSFont, NSDictionary, "Esc to dismiss\n\n", style.dim, style, false);

    var line_buf: [128]u8 = undefined;
    for (actions) |a| {
        var binding_buf: [64]u8 = undefined;
        const binding = formatBinding(a.mods, a.keycode, &binding_buf) catch continue;
        const line = std.fmt.bufPrint(&line_buf, "{s: <[width]}  {s}\n", .{
            binding,
            .{ .width = max_binding },
            a.name,
        }) catch continue;
        appendRun(root, NSString, NSColor, NSFont, NSDictionary, line, style.fg, style, false);
    }

    const ts = tv.msgSend(objc.Object, "textStorage", .{});
    if (ts.value != null) {
        ts.msgSend(void, "setAttributedString:", .{root});
    }
}

fn appendRun(
    root: objc.Object,
    NSString: objc.Class,
    NSColor: objc.Class,
    NSFont: objc.Class,
    NSDictionary: objc.Class,
    text: []const u8,
    color: chrome.Rgb,
    style: chrome.Style,
    bold: bool,
) void {
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return;
    var stack: [257]u8 = undefined;
    const take = @min(text.len, stack.len - 1);
    @memcpy(stack[0..take], text[0..take]);
    stack[take] = 0;
    const ns_text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, &stack)});

    const font = if (bold)
        chrome.chromeFont(NSFont, style.font_family, style.font_size_sm)
    else
        chrome.chromeFont(NSFont, style.font_family, style.font_size_sm);
    const ns_color = chrome.nsColorFromRgb(NSColor, color);

    const fg_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSColor")});
    const font_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "NSFont")});
    const objects = [_]objc.c.id{ ns_color.value, font.value };
    const keys = [_]objc.c.id{ fg_key.value, font_key.value };
    const dict = NSDictionary.msgSend(
        objc.Object,
        "dictionaryWithObjects:forKeys:count:",
        .{ &objects, &keys, @as(c_ulong, 2) },
    );

    const attr_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const attr = attr_alloc.msgSend(objc.Object, "initWithString:attributes:", .{ ns_text, dict });
    defer attr.msgSend(void, "release", .{});
    root.msgSend(void, "appendAttributedString:", .{attr});
}

/// Render a (mods, keycode) pair as a human-readable binding —
/// `Cmd+Shift+P`, `Cmd+/`, etc. Output written into `buf`; returns
/// the formatted slice (always a prefix of `buf`).
pub fn formatBinding(mods: u64, keycode: u16, buf: []u8) ![]const u8 {
    var w = std.io.fixedBufferStream(buf);
    const out = w.writer();
    var first = true;
    if (mods & keymap.mod_control != 0) {
        try out.writeAll("Ctrl");
        first = false;
    }
    if (mods & keymap.mod_alt != 0) {
        if (!first) try out.writeAll("+");
        try out.writeAll("Alt");
        first = false;
    }
    if (mods & keymap.mod_shift != 0) {
        if (!first) try out.writeAll("+");
        try out.writeAll("Shift");
        first = false;
    }
    if (mods & keymap.mod_cmd != 0) {
        if (!first) try out.writeAll("+");
        try out.writeAll("Cmd");
        first = false;
    }
    if (!first) try out.writeAll("+");
    try out.writeAll(keycodeName(keycode));
    return w.getWritten();
}

/// Reverse lookup for the small set of macOS virtual keycodes the
/// host action table uses. The hotkey grammar accepts named keys
/// (grave / space / escape / …); this maps the codes back to the
/// same names so the cheatsheet output round-trips with what the
/// user would type in config.
fn keycodeName(keycode: u16) []const u8 {
    return switch (keycode) {
        0 => "A",
        1 => "S",
        2 => "D",
        3 => "F",
        4 => "H",
        5 => "G",
        6 => "Z",
        7 => "X",
        8 => "C",
        9 => "V",
        11 => "B",
        12 => "Q",
        13 => "W",
        14 => "E",
        15 => "R",
        16 => "Y",
        17 => "T",
        18 => "1",
        19 => "2",
        20 => "3",
        21 => "4",
        22 => "6",
        23 => "5",
        24 => "=",
        25 => "9",
        26 => "7",
        27 => "-",
        28 => "8",
        29 => "0",
        30 => "]",
        31 => "O",
        32 => "U",
        33 => "[",
        34 => "I",
        35 => "P",
        37 => "L",
        38 => "J",
        39 => "'",
        40 => "K",
        41 => ";",
        42 => "\\",
        43 => ",",
        44 => "/",
        45 => "N",
        46 => "M",
        47 => ".",
        48 => "Tab",
        49 => "Space",
        50 => "`",
        51 => "Backspace",
        53 => "Esc",
        36 => "Return",
        76 => "Enter",
        123 => "Left",
        124 => "Right",
        125 => "Down",
        126 => "Up",
        else => "?",
    };
}

test "formatBinding: cmd+shift+P" {
    var buf: [64]u8 = undefined;
    const out = try formatBinding(keymap.mod_cmd | keymap.mod_shift, 35, &buf);
    try std.testing.expectEqualStrings("Shift+Cmd+P", out);
}

test "formatBinding: bare keycode" {
    var buf: [64]u8 = undefined;
    const out = try formatBinding(0, 53, &buf);
    try std.testing.expectEqualStrings("Esc", out);
}

test "formatBinding: all four mods" {
    var buf: [64]u8 = undefined;
    const out = try formatBinding(
        keymap.mod_cmd | keymap.mod_shift | keymap.mod_alt | keymap.mod_control,
        3,
        &buf,
    );
    try std.testing.expectEqualStrings("Ctrl+Alt+Shift+Cmd+F", out);
}

test "keycodeName: unknown codes fall back to ?" {
    try std.testing.expectEqualStrings("?", keycodeName(200));
}
