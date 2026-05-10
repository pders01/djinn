//! Container subview layout — terminal + divider + log + surface_host
//! + tab strip composed inside the panel's content view.
//!
//! NSSplitView's auto-layout glitches inside an NSVisualEffectView
//! during live resize (panes go blank); manual frames + autoresizing
//! flags are robust. So this module owns the explicit frame math +
//! autoresize-mask wiring instead of leaning on AppKit's split view.

const objc = @import("objc");
const app = @import("../app.zig");
const Config = @import("../config.zig").Config;
const view_mod = @import("../terminal/view.zig");
const tab_strip = @import("../session/tab_strip.zig");

const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

/// Compute the log pane width for a given panel width. Reads bounds
/// from the active Config so users can tune the fraction + min/max
/// without recompiling.
pub fn computeLogWidth(panel_w: f64, cfg: *const Config) f64 {
    const desired = panel_w * cfg.log_pane.width_fraction;
    return @min(cfg.log_pane.width_max, @max(cfg.log_pane.width_min, desired));
}

/// Plain NSView container with autoresizing-driven layout: terminal
/// flexes to fill, log keeps proportional width on the right edge.
pub fn buildContainer(
    width: f64,
    height: f64,
    cfg: *const Config,
    terminal: objc.Object,
    log: objc.Object,
    surface_host: objc.Object,
) objc.Object {
    const log_width: f64 = computeLogWidth(width, cfg);

    const NSView = objc.getClass("NSView") orelse unreachable;
    const c_alloc = NSView.msgSend(objc.Object, "alloc", .{});
    const container = c_alloc.msgSend(
        objc.Object,
        "initWithFrame:",
        .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } }},
    );
    container.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});

    const divider_w: f64 = view_mod.divider_width;
    const term_w = @max(1.0, width - log_width - divider_w);

    // Multi-profile tab strip: built when more than one profile is
    // declared. Eats `tab_strip.tab_h` off the top of the container;
    // every below-strip frame uses `term_h = height - tab_h`.
    var tab_h: f64 = 0;
    if (app.g.session_manager) |sm| {
        if (sm.sessions.items.len > 1) tab_h = tab_strip.tab_h;
    }
    const term_h = @max(1.0, height - tab_h);

    // Tier-5 surface host: sibling of `terminal` at the same frame.
    // Added FIRST (z-bottom) so TerminalView sits in front and
    // continues to capture key/mouse events even in surface mode.
    // TerminalView's drawRect early-returns when surface is bound so
    // its (transparent) NSView lets the surface_host CAMetalLayer
    // show through.
    surface_host.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = term_w, .height = term_h },
    }});
    surface_host.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    surface_host.msgSend(void, "setHidden:", .{@as(c_int, 1)});
    container.msgSend(void, "addSubview:", .{surface_host});

    terminal.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = term_w, .height = term_h },
    }});
    // WidthSizable | HeightSizable — terminal absorbs most of the extra space.
    terminal.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
    container.msgSend(void, "addSubview:", .{terminal});

    // Vertical divider between terminal + log. Subclassed as
    // `DjinnDivider` so it can host its own mouseDown/Dragged/Up
    // handlers (drag-to-resize) and a resize cursor rect. Width = 4px
    // is wide enough to grab reliably; the visible alpha is kept low
    // so the line still reads as a hairline.
    const divider = view_mod.createDivider(term_w, term_h);
    container.msgSend(void, "addSubview:", .{divider});
    app.g.layout.divider_view_id = divider.value;

    log.msgSend(void, "setFrame:", .{NSRect{
        .origin = .{ .x = term_w + divider_w, .y = 0 },
        .size = .{ .width = log_width, .height = term_h },
    }});
    // MinXMargin | HeightSizable — log stays anchored to the right
    // edge with fixed width. Width changes only via the toggle path.
    log.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 0) | (1 << 4))});
    container.msgSend(void, "addSubview:", .{log});

    if (tab_h > 0) {
        const strip = tab_strip.create(width, height);
        container.msgSend(void, "addSubview:", .{strip});
        app.g.layout.tab_strip_id = strip.value;
        if (app.g.theme.chrome_style) |s| tab_strip.applyStyle(s);
    }

    return container;
}
