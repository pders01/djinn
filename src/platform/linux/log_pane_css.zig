//! Themed CSS builder for the linux log pane.
//!
//! Extracted from `log_pane.zig` to keep the widget-construction
//! module focused on widget lifecycle + signal handlers; the styling
//! surface had grown to ~280 lines covering nine related selectors
//! (scrolledwindow, viewport, listbox, rows, info / warn / err / empty
//! / header text, attention chip, filter entry, container box) and
//! shipping them in their own file makes the relationship between
//! `applyTheme` and the CSS easier to follow.
//!
//! Single public surface: `writeThemedCss(allocator, buf, opts)`.
//! Appends a complete CSS document onto `buf` ending in a `\0`
//! sentinel so the caller can hand `buf.items.ptr` straight to
//! `gtk_css_provider_load_from_string` (which is a C function that
//! reads until NUL). Same shape as `tab_strip.writeThemedCss`.
//!
//! CSS-node gotcha (worth re-reading every time): GtkListBox's CSS
//! node is `list`, NOT `listbox`. Selectors like `listbox.djinn-log`
//! silently never match. Same trap for every GTK4 widget that took a
//! short CSS name in the 4.x naming pass.
//!
//! Selector inventory (search by name when adjusting styles):
//!
//!   - `scrolledwindow.djinn-log-scroller`          — outer scroll wrapper
//!   - `scrolledwindow.djinn-log-scroller > viewport` — internal viewport
//!   - `list.djinn-log`                              — the listbox itself
//!   - `list.djinn-log > row`                        — every row
//!   - `list.djinn-log > row label`                  — row text
//!   - `.djinn-log-info` / `-warn` / `-err`          — per-level row text
//!   - `.djinn-log-empty`                            — placeholder rows
//!   - `.djinn-log-header`                           — client-group header rows
//!   - `button.djinn-log-attention` (+ `:hover`)     — sticky-attention chip
//!   - `box.djinn-log-container`                     — outer column
//!   - `entry.djinn-log-filter` (+ `> text`)         — filter input
//!
//! Why we paint at `list.djinn-log` instead of the scrolledwindow:
//! GTK4 widgets render children-over-parents, so painting on the
//! deepest visible node sidesteps the "intermediate node paints
//! opaque dark on top of our bg" trap that hits the scrolledwindow /
//! viewport pair. The KDE Plasma GTK theme has `viewport.view` and
//! `listbox > row.view` rules painting `@view_bg_color`; our
//! `list.djinn-log` (type+class, specificity 11) ties or beats them
//! at specificity, and our PRIORITY_APPLICATION (600) > theme's
//! PRIORITY_THEME (200) settles the rest. `!important` is fragile on
//! GTK 4.20.3+ (CSS parser rejects it on `background-color` with
//! "Junk at end of value" and drops the whole rule) — don't reach
//! for it.

const std = @import("std");
const ThemeOptions = @import("terminal.zig").ThemeOptions;

/// Build the log pane's themed CSS into `buf` and null-terminate.
/// Caller passes the buffer's `items.ptr` to
/// `gtk_css_provider_load_from_string`. Null theme fields fall back
/// to GTK named colors so a no-inheritance setup still reads
/// coherently.
pub fn writeThemedCss(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    opts: ThemeOptions,
) !void {
    const w = buf.writer(allocator);

    // Paint the background at the deepest node in the tree — the
    // listbox itself, not the scrolledwindow. See the file-doc for
    // the specificity / theme-priority reasoning; the short version
    // is "KDE Breeze paints `viewport.view` opaque, so target the
    // child node it doesn't override."
    try w.writeAll(
        \\scrolledwindow.djinn-log-scroller {
        \\  background-color: transparent;
        \\  background-image: none;
        \\}
        \\scrolledwindow.djinn-log-scroller > viewport {
        \\  background-color: transparent;
        \\  background-image: none;
        \\}
        \\
    );

    if (opts.background) |bg| {
        const alpha = opts.opacity orelse 1.0;
        try w.print(
            "list.djinn-log {{ background-color: rgba({d}, {d}, {d}, {d:.2}); background-image: none; }}\n",
            .{ bg.r, bg.g, bg.b, alpha },
        );
    } else {
        try w.writeAll(
            \\list.djinn-log {
            \\  background-color: transparent;
            \\  background-image: none;
            \\}
            \\
        );
    }

    // Rows themselves stay transparent so the listbox's themed
    // background bleeds through unmodified — no per-row paint that
    // would break visual continuity when scrolling.
    try w.writeAll(
        \\list.djinn-log > row {
        \\  background-color: transparent;
        \\  padding: 6px 10px;
        \\
    );

    // Row border + info text color track the resolved foreground
    // when available, GTK theme fg otherwise.
    if (opts.foreground) |fg| {
        try w.print(
            "  border-bottom: 1px solid rgba({d}, {d}, {d}, 0.10);\n}}\n",
            .{ fg.r, fg.g, fg.b },
        );
    } else {
        try w.writeAll("  border-bottom: 1px solid alpha(@view_fg_color, 0.06);\n}\n");
    }

    try w.writeAll(
        \\list.djinn-log > row label {
        \\  font-family: monospace;
        \\  font-size: 0.9em;
        \\}
        \\
    );

    if (opts.foreground) |fg| {
        try w.print(
            ".djinn-log-info {{ color: rgba({d}, {d}, {d}, 0.85); }}\n",
            .{ fg.r, fg.g, fg.b },
        );
        try w.print(
            ".djinn-log-empty {{ color: rgba({d}, {d}, {d}, 0.45); font-style: italic; }}\n",
            .{ fg.r, fg.g, fg.b },
        );
        // Header is dim + italic + slightly smaller, with a top
        // margin so each group breathes apart from the previous
        // one's body. Bottom margin is tight so the header sits
        // directly above its first body row.
        try w.print(
            ".djinn-log-header {{\n" ++
                "  color: rgba({d}, {d}, {d}, 0.55);\n" ++
                "  font-style: italic;\n" ++
                "  font-size: 0.8em;\n" ++
                "  margin-top: 6px;\n" ++
                "}}\n",
            .{ fg.r, fg.g, fg.b },
        );
    } else {
        try w.writeAll(
            \\.djinn-log-info {
            \\  color: alpha(@view_fg_color, 0.85);
            \\}
            \\.djinn-log-empty {
            \\  color: alpha(@view_fg_color, 0.45);
            \\  font-style: italic;
            \\}
            \\.djinn-log-header {
            \\  color: alpha(@view_fg_color, 0.55);
            \\  font-style: italic;
            \\  font-size: 0.8em;
            \\  margin-top: 6px;
            \\}
            \\
        );
    }

    // Level accent colors. Palette[3] is yellow, palette[1] is red
    // in the standard 16-color ANSI layout — same indices ghostty's
    // theme files use for the "warning" and "danger" semantics.
    if (opts.palette[3]) |warn| {
        try w.print(
            ".djinn-log-warn {{ color: rgb({d}, {d}, {d}); }}\n",
            .{ warn.r, warn.g, warn.b },
        );
    } else {
        try w.writeAll(".djinn-log-warn { color: @warning_color; }\n");
    }
    if (opts.palette[1]) |err_color| {
        try w.print(
            ".djinn-log-err {{ color: rgb({d}, {d}, {d}); }}\n",
            .{ err_color.r, err_color.g, err_color.b },
        );
    } else {
        try w.writeAll(".djinn-log-err { color: @error_color; }\n");
    }

    // Sticky-attention chip. Reuses palette[3] (the "warning" slot)
    // for both the text and a low-alpha background tint — same
    // semantic darwin uses for the menubar attention symbol and the
    // top-of-pane banner, so a user who's set both djinn surfaces
    // gets a coherent visual language across them. `box-shadow: none`
    // suppresses the default GtkButton drop-shadow some themes set
    // (looks out of place inside the pane's bounded column).
    //
    // GtkButton's CSS node IS `button` (unlike GtkListBox's `list`
    // gotcha), so the `button.djinn-log-attention` selector matches
    // directly. The inner label gets its color via inheritance from
    // the button rule — no separate `> label` selector needed.
    if (opts.palette[3]) |warn_rgb| {
        try w.print(
            "button.djinn-log-attention {{\n" ++
                "  background-color: rgba({d}, {d}, {d}, 0.18);\n" ++
                "  background-image: none;\n" ++
                "  color: rgb({d}, {d}, {d});\n" ++
                "  border: 1px solid rgba({d}, {d}, {d}, 0.45);\n" ++
                "  padding: 6px 10px;\n" ++
                "  margin: 6px 6px 0 6px;\n" ++
                "  border-radius: 4px;\n" ++
                "  box-shadow: none;\n" ++
                "  font-weight: bold;\n" ++
                "}}\n" ++
                "button.djinn-log-attention:hover {{\n" ++
                "  background-color: rgba({d}, {d}, {d}, 0.28);\n" ++
                "}}\n",
            .{
                warn_rgb.r, warn_rgb.g, warn_rgb.b,
                warn_rgb.r, warn_rgb.g, warn_rgb.b,
                warn_rgb.r, warn_rgb.g, warn_rgb.b,
                warn_rgb.r, warn_rgb.g, warn_rgb.b,
            },
        );
    } else {
        try w.writeAll(
            \\button.djinn-log-attention {
            \\  background-color: alpha(@warning_color, 0.18);
            \\  background-image: none;
            \\  color: @warning_color;
            \\  border: 1px solid alpha(@warning_color, 0.45);
            \\  padding: 6px 10px;
            \\  margin: 6px 6px 0 6px;
            \\  border-radius: 4px;
            \\  box-shadow: none;
            \\  font-weight: bold;
            \\}
            \\button.djinn-log-attention:hover {
            \\  background-color: alpha(@warning_color, 0.28);
            \\}
            \\
        );
    }

    // Outer container shares the list background so the chip's
    // margin shows the same bleed-through color as the list itself.
    // Without this rule, the box paints the GTK theme's window
    // background between the chip and the scrolledwindow.
    if (opts.background) |bg| {
        const alpha = opts.opacity orelse 1.0;
        try w.print(
            "box.djinn-log-container {{ background-color: rgba({d}, {d}, {d}, {d:.2}); background-image: none; }}\n",
            .{ bg.r, bg.g, bg.b, alpha },
        );
    } else {
        try w.writeAll(
            \\box.djinn-log-container {
            \\  background-color: transparent;
            \\  background-image: none;
            \\}
            \\
        );
    }

    // Filter entry. GtkSearchEntry's CSS node is `entry`; the
    // `.djinn-log-filter` class lands on the outer search-entry
    // widget, so we target `entry.djinn-log-filter`. The inner
    // GtkText (where the typed characters actually paint) inherits
    // color from the entry — explicit `> text` rule mirrors the
    // listbox row trick where the inner node ignores theme overrides
    // unless addressed directly.
    //
    // 6px horizontal/bottom margin matches the chip's left/right
    // inset so the two siblings visually align in the column. The
    // entry sits on top of the same translucent container bg so it
    // doesn't pop visually — explicit transparent + GTK-theme
    // border keeps the field's affordance visible without painting
    // an opaque box that would clash with the inherited terminal
    // background tint.
    if (opts.foreground) |fg| {
        try w.print(
            "entry.djinn-log-filter {{\n" ++
                "  background-color: rgba({d}, {d}, {d}, 0.06);\n" ++
                "  background-image: none;\n" ++
                "  color: rgba({d}, {d}, {d}, 0.90);\n" ++
                "  margin: 4px 6px 6px 6px;\n" ++
                "  padding: 2px 6px;\n" ++
                "  border-radius: 4px;\n" ++
                "  caret-color: rgba({d}, {d}, {d}, 0.90);\n" ++
                "}}\n" ++
                "entry.djinn-log-filter > text {{\n" ++
                "  color: rgba({d}, {d}, {d}, 0.90);\n" ++
                "}}\n",
            .{
                fg.r, fg.g, fg.b,
                fg.r, fg.g, fg.b,
                fg.r, fg.g, fg.b,
                fg.r, fg.g, fg.b,
            },
        );
    } else {
        try w.writeAll(
            \\entry.djinn-log-filter {
            \\  background-color: alpha(@view_fg_color, 0.06);
            \\  background-image: none;
            \\  margin: 4px 6px 6px 6px;
            \\  padding: 2px 6px;
            \\  border-radius: 4px;
            \\}
            \\
        );
    }

    // Null-terminate for the C `load_from_string` call.
    try buf.append(allocator, 0);
}

// ─── Tests ───────────────────────────────────────────────────────────

test "writeThemedCss: empty opts renders default palette" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    // Sanity-check that all the major selectors made it into the
    // output. A missed selector silently strips its visual; the
    // smoke check catches accidental deletions.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "list.djinn-log") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ".djinn-log-info") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ".djinn-log-warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ".djinn-log-err") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ".djinn-log-header") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "button.djinn-log-attention") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "entry.djinn-log-filter") != null);
    // Last byte is the NUL sentinel for gtk_css_provider_load_from_string.
    try std.testing.expectEqual(@as(u8, 0), buf.items[buf.items.len - 1]);
}

test "writeThemedCss: palette[1]/[3] override @warning_color and @error_color" {
    const a = std.testing.allocator;
    var opts = ThemeOptions{};
    opts.palette[1] = .{ .r = 200, .g = 30, .b = 40 };
    opts.palette[3] = .{ .r = 220, .g = 180, .b = 50 };
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, opts);
    // The palette-supplied rgb() values must appear AND the
    // named-color fallbacks must be absent — a stale @warning_color
    // would mean theme inheritance silently overrode the user's
    // explicit palette.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rgb(200, 30, 40)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rgb(220, 180, 50)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@warning_color") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@error_color") == null);
}

test "writeThemedCss: background drives list + container fill" {
    const a = std.testing.allocator;
    var opts = ThemeOptions{};
    opts.background = .{ .r = 20, .g = 22, .b = 28 };
    opts.opacity = 0.85;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, opts);
    // Both selectors must carry the resolved rgba — the listbox so
    // log rows have an opaque-enough backdrop, the container so the
    // chip + filter row don't show a GTK theme stripe in the gap.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rgba(20, 22, 28, 0.85)") != null);
}
