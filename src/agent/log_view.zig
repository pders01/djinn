const std = @import("std");
const objc = @import("objc");
const chrome = @import("../chrome.zig");
const AgentState = @import("state.zig").AgentState;
const LogEntry = @import("state.zig").LogEntry;

pub const Rgb = chrome.Rgb;

/// Side activity panel. Outer NSView (`view`) hosts an NSScrollView
/// wrapping a read-only NSTextView. Streams `djinn_log` events so the
/// user sees a chronology of agent activity. No section header — each
/// log entry leads with its own dim `{client} · {time}` line.
///
/// Colors come from the resolved theme's palette so the panel inherits
/// the user's ghostty theme contrast (palette[8] = bright-black for
/// dim text, [9..14] = bright ANSI colors for level dots, foreground
/// for body text).
pub const LogView = struct {
    view: objc.Object,
    scroll: objc.Object,
    text_view: objc.Object,
    font: objc.Object,
    last_count: usize = 0,
    /// Tracks the client label of the previous entry so consecutive
    /// entries from the same agent skip the redundant `{client} ·
    /// {time}` header line. Cleared when `last_count` resets (log ring
    /// truncated) so the next entry always starts a fresh group.
    last_client_buf: [64]u8 = [_]u8{0} ** 64,
    last_client_len: usize = 0,
    last_client_known: bool = false,
    bg: Rgb,
    fg: Rgb,
    dim: Rgb,
    info_color: Rgb,
    warn_color: Rgb,
    err_color: Rgb,

    pub fn init(
        width: f64,
        height: f64,
        style: chrome.Style,
    ) !LogView {
        const NSView = objc.getClass("NSView") orelse return error.ClassNotFound;
        const NSScrollView = objc.getClass("NSScrollView") orelse return error.ClassNotFound;
        const NSTextView = objc.getClass("NSTextView") orelse return error.ClassNotFound;
        const NSColor = objc.getClass("NSColor") orelse return error.ClassNotFound;
        const NSFont = objc.getClass("NSFont") orelse return error.ClassNotFound;
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;

        // Single elevated bg shared with the find chip. The log pane
        // and the chip read as one chrome family — same fill, same
        // typography. Shape (split column vs. floating pill) does the
        // work of distinguishing roles.
        const ns_bg = chrome.nsColorFromRgb(NSColor, style.chip.bg);

        const wrapper_alloc = NSView.msgSend(objc.Object, "alloc", .{});
        const wrapper = wrapper_alloc.msgSend(
            objc.Object,
            "initWithFrame:",
            .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } }},
        );
        wrapper.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
        const wrapper_layer = wrapper.msgSend(objc.Object, "layer", .{});
        if (wrapper_layer.value != null) {
            wrapper_layer.msgSend(void, "setBackgroundColor:", .{ns_bg.msgSend(?*anyopaque, "CGColor", .{})});
        }
        wrapper.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});

        // Scroll fills the wrapper. The "ACTIVITY" header strip used to
        // sit above this — dropped: the log entries already lead with
        // a dim "{client} · {time}" header per row, so a separate
        // section title was redundant. Reclaiming that space puts more
        // log entries on screen.
        const scroll_alloc = NSScrollView.msgSend(objc.Object, "alloc", .{});
        const scroll = scroll_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        }});
        scroll.msgSend(void, "setHasVerticalScroller:", .{@as(c_int, 1)});
        scroll.msgSend(void, "setHasHorizontalScroller:", .{@as(c_int, 0)});
        scroll.msgSend(void, "setBorderType:", .{@as(c_long, 0)});
        scroll.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
        scroll.msgSend(void, "setBackgroundColor:", .{ns_bg});
        // WidthSizable | HeightSizable.
        scroll.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
        wrapper.msgSend(void, "addSubview:", .{scroll});

        const clip = scroll.msgSend(objc.Object, "contentView", .{});
        if (clip.value != null) {
            clip.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
            clip.msgSend(void, "setBackgroundColor:", .{ns_bg});
        }

        const tv_alloc = NSTextView.msgSend(objc.Object, "alloc", .{});
        const tv = tv_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        }});
        tv.msgSend(void, "setEditable:", .{@as(c_int, 0)});
        tv.msgSend(void, "setSelectable:", .{@as(c_int, 1)});
        tv.msgSend(void, "setRichText:", .{@as(c_int, 1)});
        tv.msgSend(void, "setDrawsBackground:", .{@as(c_int, 1)});
        tv.msgSend(void, "setBackgroundColor:", .{ns_bg});
        tv.msgSend(void, "setTextContainerInset:", .{NSSize{ .width = 14, .height = 14 }});

        const z_name = std.heap.page_allocator.allocSentinel(u8, style.font_family.len, 0) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(z_name);
        @memcpy(z_name[0..style.font_family.len], style.font_family);
        const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, z_name.ptr)});
        const font = blk: {
            const f = NSFont.msgSend(objc.Object, "fontWithName:size:", .{ ns_name, style.font_size_sm });
            if (f.value != null) break :blk f;
            break :blk NSFont.msgSend(objc.Object, "userFixedPitchFontOfSize:", .{style.font_size_sm});
        };
        tv.msgSend(void, "setFont:", .{font});

        scroll.msgSend(void, "setDocumentView:", .{tv});

        return .{
            .view = wrapper,
            .scroll = scroll,
            .text_view = tv,
            .font = font,
            .bg = style.chip.bg,
            .fg = style.fg,
            .dim = style.dim,
            .info_color = style.info,
            .warn_color = style.warn,
            .err_color = style.err,
        };
    }

    /// Re-skin the panel after a system appearance change without
    /// rebuilding the view hierarchy. Reapplies bg color to scroll +
    /// clip + text view; updates accent colors used for new entries
    /// going forward (existing entries keep their old NSAttributedString
    /// colors — repainting them all would mean re-streaming the ring,
    /// which costs more than the visual mismatch is worth).
    pub fn applyStyle(self: *LogView, style: chrome.Style) void {
        self.bg = style.chip.bg;
        self.fg = style.fg;
        self.dim = style.dim;
        self.info_color = style.info;
        self.warn_color = style.warn;
        self.err_color = style.err;

        const NSColor = objc.getClass("NSColor") orelse return;
        const ns_bg = chrome.nsColorFromRgb(NSColor, style.chip.bg);

        const wrapper_layer = self.view.msgSend(objc.Object, "layer", .{});
        if (wrapper_layer.value != null) {
            wrapper_layer.msgSend(void, "setBackgroundColor:", .{ns_bg.msgSend(?*anyopaque, "CGColor", .{})});
        }

        self.scroll.msgSend(void, "setBackgroundColor:", .{ns_bg});
        const clip = self.scroll.msgSend(objc.Object, "contentView", .{});
        if (clip.value != null) clip.msgSend(void, "setBackgroundColor:", .{ns_bg});
        self.text_view.msgSend(void, "setBackgroundColor:", .{ns_bg});
        self.view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        self.scroll.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        self.text_view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    }

    pub fn syncFrom(self: *LogView, agent_state: *AgentState) void {
        agent_state.mutex.lock();
        defer agent_state.mutex.unlock();

        const entries = agent_state.log.items;
        if (entries.len <= self.last_count) {
            if (entries.len < self.last_count) {
                // Log ring truncated upstream — drop our cached client
                // group so the next entry starts a fresh header.
                self.last_count = 0;
                self.last_client_known = false;
            } else return;
        }

        for (entries[self.last_count..]) |entry| {
            self.appendEntry(entry);
        }
        self.last_count = entries.len;

        self.text_view.msgSend(void, "scrollToEndOfDocument:", .{@as(?*anyopaque, null)});
    }

    fn appendEntry(self: *LogView, entry: LogEntry) void {
        const allocator = std.heap.page_allocator;
        const msg_z = allocator.allocSentinel(u8, entry.message.len, 0) catch return;
        defer allocator.free(msg_z);
        @memcpy(msg_z[0..entry.message.len], entry.message);

        // Group consecutive entries by client. First entry from a new
        // client gets a full `{client} · {hh:mm}` header; follow-ups
        // from the same client skip the header so the eye reads the
        // group as one conversation. When two agents interleave, each
        // switch reintroduces the header so the source stays clear.
        const client_str = entry.client orelse "djinn";
        const same_client = self.last_client_known and
            std.mem.eql(u8, client_str, self.last_client_buf[0..self.last_client_len]);

        if (!same_client) {
            var hdr_buf: [80]u8 = undefined;
            if (formatEntryHeader(&hdr_buf, client_str, entry.timestamp_ms)) |hdr| {
                self.appendStyled(hdr, self.dim, .header);
            }

            const n = @min(client_str.len, self.last_client_buf.len);
            @memcpy(self.last_client_buf[0..n], client_str[0..n]);
            self.last_client_len = n;
            self.last_client_known = true;
        }

        const body_color = switch (entry.level) {
            .info => self.fg,
            .warn => self.warn_color,
            .err => self.err_color,
        };
        self.appendStyled(msg_z, body_color, .body);
        self.appendStyled("\n", body_color, .spacer);
    }

    const Kind = enum { header, body, spacer };

    fn appendStyled(self: *LogView, text: [:0]const u8, color: Rgb, kind: Kind) void {
        const NSString = objc.getClass("NSString") orelse return;
        const NSColor = objc.getClass("NSColor") orelse return;
        const NSDictionary = objc.getClass("NSDictionary") orelse return;
        const NSAttributedString = objc.getClass("NSAttributedString") orelse return;
        const NSParagraphStyle = objc.getClass("NSMutableParagraphStyle") orelse return;

        const ns_text = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*c]const u8, text.ptr)},
        );
        const ns_color = chrome.nsColorFromRgb(NSColor, color);

        const font = self.font;

        // header rows pack tight against their body; body adds breathing
        // room before the next entry. spacer is just the trailing \n.
        const para = NSParagraphStyle.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        switch (kind) {
            .header => {
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 1)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 0)});
            },
            .body => {
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 2)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 12)});
            },
            .spacer => {
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 0)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 0)});
            },
        }

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

        const attr = NSAttributedString.msgSend(objc.Object, "alloc", .{}).msgSend(
            objc.Object,
            "initWithString:attributes:",
            .{ ns_text, dict },
        );

        const storage = self.text_view.msgSend(objc.Object, "textStorage", .{});
        storage.msgSend(void, "appendAttributedString:", .{attr});
    }
};

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// Build the dim per-entry header line `{client} · {hh:mm}\n`.
/// Caller provides the buffer; returns a sentinel-terminated slice on
/// success or null when the buffer can't hold the formatted output.
/// Hour/minute are UTC (seconds since epoch math) — matches the source
/// timestamps from `std.time.milliTimestamp` and stays stable across
/// timezone changes / DST transitions on the host.
pub fn formatEntryHeader(buf: []u8, client: []const u8, timestamp_ms: i64) ?[:0]const u8 {
    const seconds: i64 = @divFloor(timestamp_ms, 1000);
    const hr: u32 = @intCast(@mod(@divFloor(seconds, 3600), 24));
    const min: u32 = @intCast(@mod(@divFloor(seconds, 60), 60));
    return std.fmt.bufPrintZ(buf, "{s} · {d:0>2}:{d:0>2}\n", .{ client, hr, min }) catch null;
}

test "formatEntryHeader: epoch zero -> 00:00 UTC" {
    var buf: [80]u8 = undefined;
    const hdr = formatEntryHeader(&buf, "djinn", 0) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("djinn · 00:00\n", hdr);
}

test "formatEntryHeader: client name passes through" {
    var buf: [80]u8 = undefined;
    const hdr = formatEntryHeader(&buf, "agent_42", 0) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("agent_42 · 00:00\n", hdr);
}

test "formatEntryHeader: noon" {
    var buf: [80]u8 = undefined;
    // 12:00 UTC = 12 * 3600 seconds = 43200 sec = 43_200_000 ms.
    const hdr = formatEntryHeader(&buf, "djinn", 43_200_000) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("djinn · 12:00\n", hdr);
}

test "formatEntryHeader: minute pad" {
    var buf: [80]u8 = undefined;
    // 09:07 UTC = (9 * 3600 + 7 * 60) * 1000.
    const hdr = formatEntryHeader(&buf, "djinn", (9 * 3600 + 7 * 60) * 1000) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("djinn · 09:07\n", hdr);
}

test "formatEntryHeader: 23:59 boundary" {
    var buf: [80]u8 = undefined;
    const hdr = formatEntryHeader(&buf, "djinn", (23 * 3600 + 59 * 60) * 1000) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("djinn · 23:59\n", hdr);
}

test "formatEntryHeader: rolls past midnight" {
    var buf: [80]u8 = undefined;
    // 25:30 wall clock = 1:30 next day; @mod 24 keeps the display at 01:30.
    const hdr = formatEntryHeader(&buf, "djinn", (25 * 3600 + 30 * 60) * 1000) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("djinn · 01:30\n", hdr);
}

test "formatEntryHeader: buffer too small returns null" {
    var buf: [4]u8 = undefined;
    try std.testing.expect(formatEntryHeader(&buf, "djinn", 0) == null);
}

test "formatEntryHeader: empty client" {
    var buf: [80]u8 = undefined;
    const hdr = formatEntryHeader(&buf, "", 0) orelse return error.TestFailed;
    try std.testing.expectEqualStrings(" · 00:00\n", hdr);
}
