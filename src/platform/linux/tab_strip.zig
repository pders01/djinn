//! Optional fixed-profile tabs. No session creation, mutation or agent state.
const std = @import("std");
const gtk = @import("gtk.zig");
const SessionManager = @import("../../session/manager.zig").SessionManager;
const ThemeOptions = @import("terminal.zig").ThemeOptions;
const GtkWidget = gtk.GtkWidget;
const GtkBox = opaque {};
const GtkButton = opaque {};
extern "c" fn gtk_box_new(c_int, c_int) *GtkWidget;
extern "c" fn gtk_box_append(*GtkBox, *GtkWidget) void;
extern "c" fn gtk_button_new_with_label([*:0]const u8) *GtkWidget;
extern "c" fn gtk_button_set_label(*GtkButton, [*:0]const u8) void;
extern "c" fn gtk_widget_add_css_class(*GtkWidget, [*:0]const u8) void;
extern "c" fn gtk_widget_remove_css_class(*GtkWidget, [*:0]const u8) void;
extern "c" fn gtk_widget_set_vexpand(*GtkWidget, gtk.gboolean) void;
extern "c" fn g_object_ref_sink(*anyopaque) *anyopaque;
extern "c" fn gtk_style_context_remove_provider_for_display(*gtk.GdkDisplay, *anyopaque) void;

pub const OnActivate = struct { ctx: *anyopaque, on_invoke: *const fn (*anyopaque, usize) bool };
/// Copy the dispatch value, never a pointer to the init-local TabStrip.
const Slot = struct { activate: OnActivate, idx: usize };

pub const TabStrip = struct {
    allocator: std.mem.Allocator,
    sm: *SessionManager,
    on_activate: OnActivate,
    container: *GtkWidget,
    provider: *gtk.GtkCssProvider,
    buttons: std.ArrayList(*GtkWidget) = .empty,
    clicked_ids: std.ArrayList(c_ulong) = .empty,
    slots: std.ArrayList(*Slot) = .empty,
    label_bufs: std.ArrayList([:0]u8) = .empty,
    theme_opts: ThemeOptions,

    pub fn init(a: std.mem.Allocator, sm: *SessionManager, activate: OnActivate, opts: ThemeOptions) !TabStrip {
        const container = gtk_box_new(0, 0);
        _ = g_object_ref_sink(@ptrCast(container));
        gtk_widget_add_css_class(container, "djinn-tab-strip");
        const provider = gtk.gtk_css_provider_new();
        if (gtk.gdk_display_get_default()) |d| gtk.gtk_style_context_add_provider_for_display(d, @ptrCast(provider), 600);
        var self = TabStrip{ .allocator = a, .sm = sm, .on_activate = activate, .container = container, .provider = provider, .theme_opts = opts };
        errdefer self.deinit();
        try self.buildButtons();
        self.applyTheme(opts);
        gtk.gtk_widget_set_visible(container, @intFromBool(sm.count() > 1));
        return self;
    }
    pub fn deinit(self: *TabStrip) void {
        for (self.buttons.items, self.clicked_ids.items) |button, id| {
            if (id != 0) gtk.g_signal_handler_disconnect(@ptrCast(button), id);
        }
        for (self.slots.items) |slot| self.allocator.destroy(slot);
        for (self.label_bufs.items) |buf| self.allocator.free(buf);
        self.buttons.deinit(self.allocator);
        self.clicked_ids.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.label_bufs.deinit(self.allocator);
        if (gtk.gdk_display_get_default()) |d| gtk_style_context_remove_provider_for_display(d, @ptrCast(self.provider));
        gtk.g_object_unref(@ptrCast(self.provider));
        gtk.g_object_unref(@ptrCast(self.container));
    }
    pub fn widget(self: *TabStrip) *GtkWidget {
        return self.container;
    }
    pub fn pairWithChild(self: *TabStrip, bottom: *GtkWidget) *GtkWidget {
        const box = gtk_box_new(1, 0);
        gtk_box_append(@ptrCast(box), self.container);
        gtk_box_append(@ptrCast(box), bottom);
        gtk_widget_set_vexpand(bottom, 1);
        return box;
    }
    pub fn markActive(self: *TabStrip, idx: usize) void {
        for (self.buttons.items, 0..) |button, i| {
            if (i == idx) gtk_widget_add_css_class(button, "djinn-tab-active") else gtk_widget_remove_css_class(button, "djinn-tab-active");
        }
    }
    pub fn markExited(self: *TabStrip, idx: usize, exited: bool) void {
        if (idx >= self.buttons.items.len) return;
        const b = self.buttons.items[idx];
        if (exited) gtk_widget_add_css_class(b, "djinn-tab-exited") else gtk_widget_remove_css_class(b, "djinn-tab-exited");
    }
    /// Session.label: explicit profile title > VTE title > profile name.
    /// Wire SessionHost.setTitleChangedHandler to this after init.
    pub fn refreshLabel(self: *TabStrip, idx: usize) void {
        if (idx >= self.buttons.items.len) return;
        const z = self.allocator.dupeSentinel(u8, self.sm.sessions.items[idx].label(), 0) catch return;
        gtk_button_set_label(@ptrCast(self.buttons.items[idx]), z.ptr);
        self.allocator.free(self.label_bufs.items[idx]);
        self.label_bufs.items[idx] = z;
    }
    pub fn applyTheme(self: *TabStrip, opts: ThemeOptions) void {
        self.theme_opts = opts;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        writeThemedCss(self.allocator, &buf, opts) catch return;
        buf.append(self.allocator, 0) catch return;
        gtk.gtk_css_provider_load_from_string(self.provider, @ptrCast(buf.items.ptr));
    }
    fn buildButtons(self: *TabStrip) !void {
        const n = self.sm.count();
        try self.buttons.ensureTotalCapacity(self.allocator, n);
        try self.clicked_ids.ensureTotalCapacity(self.allocator, n);
        try self.slots.ensureTotalCapacity(self.allocator, n);
        try self.label_bufs.ensureTotalCapacity(self.allocator, n);
        // Box callbacks separately: even moving/reallocating the lists does
        // not change any GTK user_data address.
        for (self.sm.sessions.items, 0..) |*session, i| {
            const label = try self.allocator.dupeSentinel(u8, session.label(), 0);
            self.label_bufs.appendAssumeCapacity(label);
            const slot = try self.allocator.create(Slot);
            slot.* = .{ .activate = self.on_activate, .idx = i };
            self.slots.appendAssumeCapacity(slot);
            const button = gtk_button_new_with_label(label.ptr);
            self.buttons.appendAssumeCapacity(button);
            gtk_box_append(@ptrCast(self.container), button);
            gtk_widget_add_css_class(button, "djinn-tab");
            if (i == self.sm.active_idx) gtk_widget_add_css_class(button, "djinn-tab-active");
            if (session.exited) gtk_widget_add_css_class(button, "djinn-tab-exited");
            const id = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onClicked), slot, null, 0);
            self.clicked_ids.appendAssumeCapacity(id);
        }
    }
};
fn onClicked(_: *gtk.GObject, data: gtk.gpointer) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    _ = slot.activate.on_invoke(slot.activate.ctx, slot.idx);
}

fn appendPrint(a: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var scratch: [2048]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&scratch, fmt, args));
}
fn writeThemedCss(a: std.mem.Allocator, buf: *std.ArrayList(u8), opts: ThemeOptions) !void {
    try buf.appendSlice(a, "box.djinn-tab-strip { background-image: none; padding: 4px 6px 0 6px; }\n" ++
        "button.djinn-tab { background-color: transparent; background-image: none; border: none; border-bottom: 2px solid transparent; padding: 4px 12px; margin: 0 2px; border-radius: 0; box-shadow: none; font-weight: normal; color: alpha(@theme_fg_color, 0.55); }\n" ++
        "button.djinn-tab:hover { background-color: alpha(@theme_fg_color, 0.08); color: alpha(@theme_fg_color, 0.85); }\n" ++
        "button.djinn-tab.djinn-tab-active { color: @theme_fg_color; font-weight: bold; }\n" ++
        "button.djinn-tab.djinn-tab-exited { color: alpha(@theme_fg_color, 0.35); font-style: italic; }\n" ++
        "button.djinn-tab.djinn-tab-exited > label { text-decoration: line-through; }\n" ++
        "button.djinn-tab.djinn-tab-exited:hover { color: alpha(@theme_fg_color, 0.6); }\n");
    if (opts.background) |bg| {
        try appendPrint(a, buf, "box.djinn-tab-strip {{ background-color: rgba({d}, {d}, {d}, {d:.2}); }}\n", .{ bg.r, bg.g, bg.b, opts.opacity orelse 1.0 });
    } else try buf.appendSlice(a, "box.djinn-tab-strip { background-color: transparent; }\n");
    if (opts.palette[4]) |c| {
        try appendPrint(a, buf, "button.djinn-tab.djinn-tab-active {{ border-bottom: 2px solid rgb({d}, {d}, {d}); }}\n", .{ c.r, c.g, c.b });
    } else try buf.appendSlice(a, "button.djinn-tab.djinn-tab-active { border-bottom: 2px solid @accent_color; }\n");
    if (opts.foreground) |c| {
        try appendPrint(a, buf, "button.djinn-tab {{ color: rgba({d}, {d}, {d}, 0.55); }}\n" ++
            "button.djinn-tab:hover {{ background-color: rgba({d}, {d}, {d}, 0.08); color: rgba({d}, {d}, {d}, 0.85); }}\n" ++
            "button.djinn-tab.djinn-tab-active {{ color: rgb({d}, {d}, {d}); }}\n" ++
            "button.djinn-tab.djinn-tab-exited {{ color: rgba({d}, {d}, {d}, 0.35); }}\n" ++
            "button.djinn-tab.djinn-tab-exited:hover {{ color: rgba({d}, {d}, {d}, 0.6); }}\n", .{ c.r, c.g, c.b, c.r, c.g, c.b, c.r, c.g, c.b, c.r, c.g, c.b, c.r, c.g, c.b, c.r, c.g, c.b });
    }
}

test "TabStrip CSS includes active selector" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "djinn-tab-active") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "border-bottom") != null);
}
test "TabStrip CSS uses palette[4] for accent when available" {
    const a = std.testing.allocator;
    var opts = ThemeOptions{};
    opts.palette[4] = .{ .r = 100, .g = 149, .b = 237 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, opts);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rgb(100, 149, 237)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@accent_color") == null);
}
test "TabStrip CSS falls back to @accent_color when palette[4] is null" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@accent_color") != null);
}
test "TabStrip CSS includes exited-chip rules" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeThemedCss(a, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "djinn-tab-exited") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "line-through") != null);
}
test "TabStrip type compiles" {
    _ = TabStrip;
    _ = Slot;
    _ = OnActivate;
}
test "tab CSS contains no activity indicator" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeThemedCss(std.testing.allocator, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "state-dot") == null);
}
