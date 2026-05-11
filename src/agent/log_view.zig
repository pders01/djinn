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
    /// 1px-wide border view at x=0; tracks chip.border color across
    /// theme reloads via `applyStyle`.
    separator: objc.Object,
    /// Sticky-attention chip floating above the scroll view. Visible
    /// only when AgentState has a pinned attention message. Frame-to-
    /// zero for hide because layer-backed setHidden races with
    /// ghostty's CADisplayLink-driven repaints (see CLAUDE memory).
    attention_banner: objc.Object,
    attention_label: objc.Object,
    /// Tracks the currently-displayed banner text so syncFrom can
    /// skip the NSString rebuild when the pinned message hasn't
    /// changed. Cleared when the banner hides.
    attention_buf: [256]u8 = [_]u8{0} ** 256,
    attention_len: usize = 0,
    /// Banner reserves a chunk of textContainerInset.top when
    /// visible so log entries scroll into view beneath it instead of
    /// hiding behind the chip on first paint.
    attention_inset_top: f64 = 16,
    /// Free-text filter for log entries. When `filter_len > 0`,
    /// syncFrom skips entries whose message doesn't contain the
    /// needle (case-insensitive substring). Filter changes call
    /// `rebuild` which clears the text storage and re-streams the
    /// full ring filtered.
    filter_buf: [128]u8 = [_]u8{0} ** 128,
    filter_len: usize = 0,
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
    border: Rgb,
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

        // Pane background matches the terminal surface so the strip
        // + pane + terminal column read as one continuous panel. The
        // chrome cue is the 1px chip.border separator on the left
        // edge — visible boundary, no bg lift to break visual flow
        // against the tab strip above.
        const ns_bg = chrome.nsColorFromRgb(NSColor, style.bg);

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
        // Generous left + top, slightly larger right keeps long URLs
        // from wrapping mid-token at the trailing edge.
        tv.msgSend(void, "setTextContainerInset:", .{NSSize{ .width = 16, .height = 16 }});

        // System UI font (medium weight) keeps log entries on a
        // different typographic axis from the terminal monospace, so
        // the panel reads as chrome instead of as more terminal output.
        _ = NSString;
        const font = chrome.chromeFont(NSFont, style.font_family, style.font_size_sm);
        tv.msgSend(void, "setFont:", .{font});

        scroll.msgSend(void, "setDocumentView:", .{tv});

        // Hairline separator on the inner edge (x=0 in the wrapper's
        // local coords, which is the side that meets the terminal
        // surface). 1px wide, full height, dim chip border tone — gives
        // the log pane a visible boundary even under translucency.
        const sep_alloc = NSView.msgSend(objc.Object, "alloc", .{});
        const sep = sep_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 1, .height = height },
        }});
        sep.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
        const sep_layer = sep.msgSend(objc.Object, "layer", .{});
        if (sep_layer.value != null) {
            const sep_ns = chrome.nsColorFromRgb(NSColor, style.chip.border);
            sep_layer.msgSend(void, "setBackgroundColor:", .{sep_ns.msgSend(?*anyopaque, "CGColor", .{})});
        }
        // NSViewMaxXMargin (4) + NSViewHeightSizable (16) — pinned to
        // x=0, full height under resize.
        sep.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 4 | 16)});
        wrapper.msgSend(void, "addSubview:", .{sep});

        // Sticky attention banner. NSTextField wrapped in a chip-style
        // NSView (lifted chip.bg + 1px chip.border outline). Built
        // hidden (frame-to-zero); syncFrom sizes + shows it when an
        // attention is pinned.
        const NSTextField = objc.getClass("NSTextField") orelse return error.ClassNotFound;
        const banner_alloc = NSView.msgSend(objc.Object, "alloc", .{});
        const banner = banner_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 0, .height = 0 },
        }});
        banner.msgSend(void, "setWantsLayer:", .{@as(c_int, 1)});
        const banner_layer = banner.msgSend(objc.Object, "layer", .{});
        if (banner_layer.value != null) {
            const banner_bg = chrome.nsColorFromRgb(NSColor, style.chip.bg);
            banner_layer.msgSend(void, "setBackgroundColor:", .{banner_bg.msgSend(?*anyopaque, "CGColor", .{})});
            banner_layer.msgSend(void, "setCornerRadius:", .{@as(f64, 4)});
            banner_layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1)});
            const banner_border = chrome.nsColorFromRgb(NSColor, style.chip.border);
            banner_layer.msgSend(void, "setBorderColor:", .{banner_border.msgSend(?*anyopaque, "CGColor", .{})});
        }
        // NSViewMinYMargin (32) + NSViewWidthSizable (2) — pinned to
        // wrapper top, stretches horizontally on resize.
        banner.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 32 | 2)});

        const label_alloc = NSTextField.msgSend(objc.Object, "alloc", .{});
        const label = label_alloc.msgSend(objc.Object, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 8, .y = 4 },
            .size = .{ .width = 0, .height = 0 },
        }});
        label.msgSend(void, "setEditable:", .{@as(c_int, 0)});
        label.msgSend(void, "setSelectable:", .{@as(c_int, 0)});
        label.msgSend(void, "setBezeled:", .{@as(c_int, 0)});
        label.msgSend(void, "setBordered:", .{@as(c_int, 0)});
        label.msgSend(void, "setDrawsBackground:", .{@as(c_int, 0)});
        label.msgSend(void, "setFont:", .{font});
        const warn_ns = chrome.nsColorFromRgb(NSColor, style.warn);
        label.msgSend(void, "setTextColor:", .{warn_ns});
        // WidthSizable so the label tracks the banner width on resize.
        label.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 2)});
        banner.msgSend(void, "addSubview:", .{label});
        wrapper.msgSend(void, "addSubview:", .{banner});

        return .{
            .view = wrapper,
            .scroll = scroll,
            .text_view = tv,
            .separator = sep,
            .attention_banner = banner,
            .attention_label = label,
            .font = font,
            .bg = style.bg,
            .fg = style.fg,
            .dim = style.dim,
            .border = style.chip.border,
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
        self.bg = style.bg;
        self.fg = style.fg;
        self.dim = style.dim;
        self.border = style.chip.border;
        self.info_color = style.info;
        self.warn_color = style.warn;
        self.err_color = style.err;

        const NSColor = objc.getClass("NSColor") orelse return;
        const ns_bg = chrome.nsColorFromRgb(NSColor, style.bg);

        const wrapper_layer = self.view.msgSend(objc.Object, "layer", .{});
        if (wrapper_layer.value != null) {
            wrapper_layer.msgSend(void, "setBackgroundColor:", .{ns_bg.msgSend(?*anyopaque, "CGColor", .{})});
        }

        self.scroll.msgSend(void, "setBackgroundColor:", .{ns_bg});
        const clip = self.scroll.msgSend(objc.Object, "contentView", .{});
        if (clip.value != null) clip.msgSend(void, "setBackgroundColor:", .{ns_bg});
        self.text_view.msgSend(void, "setBackgroundColor:", .{ns_bg});

        const sep_layer = self.separator.msgSend(objc.Object, "layer", .{});
        if (sep_layer.value != null) {
            const sep_ns = chrome.nsColorFromRgb(NSColor, style.chip.border);
            sep_layer.msgSend(void, "setBackgroundColor:", .{sep_ns.msgSend(?*anyopaque, "CGColor", .{})});
        }

        // Re-skin the sticky attention banner so a theme flip while
        // an attention is pinned doesn't leave the chip on stale
        // palette tones.
        const banner_layer = self.attention_banner.msgSend(objc.Object, "layer", .{});
        if (banner_layer.value != null) {
            const banner_bg = chrome.nsColorFromRgb(NSColor, style.chip.bg);
            banner_layer.msgSend(void, "setBackgroundColor:", .{banner_bg.msgSend(?*anyopaque, "CGColor", .{})});
            const banner_border = chrome.nsColorFromRgb(NSColor, style.chip.border);
            banner_layer.msgSend(void, "setBorderColor:", .{banner_border.msgSend(?*anyopaque, "CGColor", .{})});
        }
        const warn_ns = chrome.nsColorFromRgb(NSColor, style.warn);
        self.attention_label.msgSend(void, "setTextColor:", .{warn_ns});

        self.view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        self.scroll.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
        self.text_view.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    }

    pub fn syncFrom(self: *LogView, agent_state: *AgentState) void {
        // Refresh the sticky attention banner first — it reads
        // pinned_attention under the same mutex appendEntry needs, so
        // doing it before the lock window avoids a second acquire on
        // the AgentState mutex.
        self.refreshAttentionBanner(agent_state);

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
            if (!self.entryMatchesFilter(entry)) continue;
            self.appendEntry(entry);
        }
        self.last_count = entries.len;

        self.text_view.msgSend(void, "scrollToEndOfDocument:", .{@as(?*anyopaque, null)});
    }

    /// Set the free-text filter needle. Subsequent `syncFrom` calls
    /// (and the immediate `rebuild` here) only render entries whose
    /// message contains `needle` (case-insensitive substring). Empty
    /// needle = no filter.
    pub fn setFilter(self: *LogView, needle: []const u8, agent_state: *AgentState) void {
        const trim_len = @min(needle.len, self.filter_buf.len);
        if (trim_len == self.filter_len and std.mem.eql(u8, needle[0..trim_len], self.filter_buf[0..self.filter_len])) return;

        @memcpy(self.filter_buf[0..trim_len], needle[0..trim_len]);
        self.filter_len = trim_len;
        self.rebuild(agent_state);
    }

    /// Clear the active filter. Equivalent to `setFilter("", state)`.
    pub fn clearFilter(self: *LogView, agent_state: *AgentState) void {
        self.setFilter("", agent_state);
    }

    fn entryMatchesFilter(self: *const LogView, entry: LogEntry) bool {
        if (self.filter_len == 0) return true;
        return indexOfIgnoreCase(entry.message, self.filter_buf[0..self.filter_len]) != null;
    }

    /// Clear the text view + re-stream the full agent_state.log
    /// through the filter. Called when `setFilter` changes the needle
    /// — the streaming-append model can't retroactively hide entries
    /// already rendered with the previous filter.
    fn rebuild(self: *LogView, agent_state: *AgentState) void {
        const NSString = objc.getClass("NSString") orelse return;
        const empty = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, "")});
        if (empty.value != null) {
            self.text_view.msgSend(void, "setString:", .{empty});
        }
        self.last_count = 0;
        self.last_client_known = false;

        agent_state.mutex.lock();
        defer agent_state.mutex.unlock();
        const entries = agent_state.log.items;
        for (entries) |entry| {
            if (!self.entryMatchesFilter(entry)) continue;
            self.appendEntry(entry);
        }
        self.last_count = entries.len;
        self.text_view.msgSend(void, "scrollToEndOfDocument:", .{@as(?*anyopaque, null)});
    }

    /// Update the sticky attention banner from `pinned_attention`.
    /// When pinned: chip floats at the top of the log pane with the
    /// latest attention message + raises the text view's top inset so
    /// log entries scroll into view below it. When unpinned: chip
    /// frame goes to zero and the inset drops back to its base value.
    fn refreshAttentionBanner(self: *LogView, agent_state: *AgentState) void {
        var local_buf: [256]u8 = undefined;
        const maybe_len = agent_state.pinnedAttention(&local_buf);

        if (maybe_len) |len| {
            const same = (len == self.attention_len) and
                std.mem.eql(u8, local_buf[0..len], self.attention_buf[0..self.attention_len]);
            if (same and self.attention_len > 0) return;

            @memcpy(self.attention_buf[0..len], local_buf[0..len]);
            self.attention_len = len;

            const NSString = objc.getClass("NSString") orelse return;
            var z: [257]u8 = undefined;
            @memcpy(z[0..len], local_buf[0..len]);
            z[len] = 0;
            // Prefix the message with ⚠ — same visual semantic as the
            // menubar attention SF Symbol, just inline in the chip so
            // the banner reads as "user-action required" without the
            // user needing to glance at the menubar.
            var with_prefix_buf: [288]u8 = undefined;
            const prefix = "⚠  ";
            @memcpy(with_prefix_buf[0..prefix.len], prefix);
            @memcpy(with_prefix_buf[prefix.len..][0..len], local_buf[0..len]);
            with_prefix_buf[prefix.len + len] = 0;

            const text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, @ptrCast(&with_prefix_buf))});
            if (text.value == null) return;
            self.attention_label.msgSend(void, "setStringValue:", .{text});

            // Size + show the banner. 28pt chip, 8px horizontal inset
            // inside the wrapper. Pin to the top of the wrapper —
            // banner.frame.y = wrapper.height - banner.height - 8.
            const wrap_bounds = self.view.msgSend(NSRect, "bounds", .{});
            const banner_h: f64 = 28;
            const banner_y = wrap_bounds.size.height - banner_h - 8;
            const banner_w = wrap_bounds.size.width - 8 - 16; // 8px left (after separator), 16px right
            self.attention_banner.msgSend(void, "setFrame:", .{NSRect{
                .origin = .{ .x = 8, .y = banner_y },
                .size = .{ .width = banner_w, .height = banner_h },
            }});
            self.attention_label.msgSend(void, "setFrame:", .{NSRect{
                .origin = .{ .x = 10, .y = 6 },
                .size = .{ .width = banner_w - 12, .height = banner_h - 8 },
            }});

            // Push the text view's top inset down so the first log
            // entry sits below the banner instead of being covered.
            self.text_view.msgSend(void, "setTextContainerInset:", .{NSSize{
                .width = 16,
                .height = self.attention_inset_top + banner_h + 8,
            }});
        } else {
            if (self.attention_len == 0) return;
            self.attention_len = 0;
            // Frame-to-zero hide (layer-backed setHidden races with
            // ghostty's CADisplayLink on this view's layout).
            self.attention_banner.msgSend(void, "setFrame:", .{NSRect{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = 0, .height = 0 },
            }});
            self.text_view.msgSend(void, "setTextContainerInset:", .{NSSize{
                .width = 16,
                .height = self.attention_inset_top,
            }});
        }
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
        //
        // Display nickname swap: when the user has set
        // `client.<hash>.name` in config, the friendly label replaces
        // the raw 6-hex id. Grouping key still uses the raw entry.client
        // so a rename mid-session doesn't accidentally split a group.
        const client_str: []const u8 = blk: {
            if (entry.client) |id| {
                if (@import("../app.zig").g.config) |cfg| {
                    if (cfg.findClient(id)) |e| {
                        if (e.name) |n| break :blk n;
                    }
                }
                break :blk id;
            }
            break :blk "djinn";
        };
        const same_client = self.last_client_known and
            std.mem.eql(u8, client_str, self.last_client_buf[0..self.last_client_len]);

        if (!same_client) {
            // Hairline divider above each new-client group, except the
            // very first one (no client previously known = no group to
            // separate from). Box-drawing `─` rendered at chip.border
            // tone gives a faint horizontal rule that scans as group
            // boundary without becoming visual noise.
            if (self.last_client_known) {
                self.appendStyled("──────────────\n", self.border, .divider);
            }

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

    const Kind = enum { header, body, spacer, divider };

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
        // alloc/init returns a +1 retain owned by us; the dict will
        // retain on insert. `release` after the dict construction
        // balances the +1 so para's lifetime tracks the dict's.
        const para = NSParagraphStyle.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        defer para.msgSend(void, "release", .{});
        switch (kind) {
            .header => {
                // 4pt gap below the `{client} · HH:MM` header so the
                // first body line breathes; without it the timestamp
                // collides with the message.
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 0)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 4)});
            },
            .body => {
                // Tight log-style rhythm — close to a real shell, just
                // enough leading + trailing gap to keep adjacent lines
                // distinct.
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 0)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 2)});
            },
            .spacer => {
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 0)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 0)});
            },
            .divider => {
                para.msgSend(void, "setLineSpacing:", .{@as(f64, 0)});
                para.msgSend(void, "setParagraphSpacing:", .{@as(f64, 4)});
                para.msgSend(void, "setParagraphSpacingBefore:", .{@as(f64, 4)});
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

        // alloc/init owned by us; textStorage retains on append. Our
        // release balances the +1 so attr's lifetime tracks textStorage.
        const attr = NSAttributedString.msgSend(objc.Object, "alloc", .{}).msgSend(
            objc.Object,
            "initWithString:attributes:",
            .{ ns_text, dict },
        );
        defer attr.msgSend(void, "release", .{});

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
/// Case-insensitive substring search used by `entryMatchesFilter`.
/// ASCII-only — log messages from agent tooling are practically all
/// ASCII, and a real Unicode-aware fold would drag in NSString just
/// for this hot path.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        var match = true;
        while (j < needle.len) : (j += 1) {
            const a = haystack[i + j];
            const b = needle[j];
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (al != bl) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

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

test "indexOfIgnoreCase: ascii folding" {
    try std.testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "hel"));
    try std.testing.expectEqual(@as(?usize, 6), indexOfIgnoreCase("hello World", "world"));
    try std.testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("foo", "bar"));
    // Empty needle matches at 0 (vacuous truth).
    try std.testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("anything", ""));
    // Needle longer than haystack.
    try std.testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("hi", "hello"));
}
