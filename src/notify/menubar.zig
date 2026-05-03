const std = @import("std");
const objc = @import("objc");
const app_state = @import("../app.zig");

pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSPoint = extern struct { x: f64, y: f64 };

pub const AgentState = enum {
    idle,
    working,
    attention,
    done,
    @"error",
};

/// Action handlers wired by main after the Panel is created. Cocoa method
/// callbacks can't capture Zig context; we route via globals.
var g_show_hide_handler: ?*const fn () void = null;

/// Idle-state brand mark: Arabic letters jīm + nūn (= "djinn"). CoreText
/// shapes the contextual joining via NSAttributedString → drawAtPoint, so
/// no HarfBuzz dependency required. setTemplate:1 makes AppKit re-tint to
/// the menubar foreground color (light/dark-mode aware).
const brand_text: [:0]const u8 = "جن";

/// Menu bar status item showing djinn agent state with a dropdown menu:
/// status line, show/hide, copy MCP config, quit.
pub const Menubar = struct {
    status_item: ?objc.Object = null,
    state_menu_item: ?objc.Object = null,
    enabled: bool = true,

    pub fn init() Menubar {
        registerControllerClass();

        const NSStatusBar = objc.getClass("NSStatusBar") orelse return .{};
        const status_bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});

        const status_item = status_bar.msgSend(
            objc.Object,
            "statusItemWithLength:",
            .{@as(f64, -1)},
        );

        // Idle = Arabic brand mark; non-idle states swap to SF Symbols for
        // status semantics (spinner, warning, check, X). Both render as
        // template images so menubar tinting Just Works.
        const button = status_item.msgSend(objc.Object, "button", .{});
        setBrandImage(button);

        const menu = buildMenu();
        const state_item = menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_long, 0)});

        status_item.msgSend(void, "setMenu:", .{menu});

        return .{ .status_item = status_item, .state_menu_item = state_item };
    }

    pub fn setShowHideHandler(self: *Menubar, handler: *const fn () void) void {
        _ = self;
        g_show_hide_handler = handler;
    }

    pub fn updateState(self: *Menubar, state: AgentState, message: []const u8) void {
        if (!self.enabled) return;
        const item = self.status_item orelse return;
        const button = item.msgSend(objc.Object, "button", .{});
        if (state == .idle) {
            setBrandImage(button);
        } else {
            setSymbolImage(button, stateSymbol(state));
        }

        if (self.state_menu_item) |mi| {
            const NSString = objc.getClass("NSString") orelse return;
            // Suffix the active profile label only when more than one
            // profile is configured — the indicator is the only
            // visual feedback for which session is up front, so it
            // matters under multi-profile and is noise otherwise.
            var profile_label: []const u8 = "";
            if (app_state.g.session_manager) |sm| {
                if (sm.sessions.len > 1) profile_label = sm.active().profile.label();
            }
            var buf: [256]u8 = undefined;
            const txt = std.fmt.bufPrintZ(&buf, "{s}{s}{s}{s}{s}", .{
                stateLabel(state),
                if (message.len > 0) " — " else "",
                message,
                if (profile_label.len > 0) " · " else "",
                profile_label,
            }) catch return;
            const title = NSString.msgSend(
                objc.Object,
                "stringWithUTF8String:",
                .{@as([*c]const u8, txt.ptr)},
            );
            mi.msgSend(void, "setTitle:", .{title});
        }
    }

    fn stateSymbol(state: AgentState) [:0]const u8 {
        return switch (state) {
            .idle => "terminal",
            .working => "arrow.triangle.2.circlepath",
            .attention => "exclamationmark.triangle.fill",
            .done => "checkmark.circle.fill",
            .@"error" => "xmark.octagon.fill",
        };
    }

    fn stateLabel(state: AgentState) [:0]const u8 {
        return switch (state) {
            .idle => "Idle",
            .working => "Working",
            .attention => "Needs attention",
            .done => "Done",
            .@"error" => "Error",
        };
    }

    pub fn deinit(self: *Menubar) void {
        if (self.status_item) |item| {
            const NSStatusBar = objc.getClass("NSStatusBar") orelse return;
            const status_bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
            status_bar.msgSend(void, "removeStatusItem:", .{item});
        }
    }
};

/// Render brand_text as a template NSImage using NSAttributedString. Uses
/// the system font at the menubar's icon point size so the glyphs match
/// height with sibling SF Symbols when a state flip swaps the image.
fn setBrandImage(button: objc.Object) void {
    const NSString = objc.getClass("NSString") orelse return;
    const NSImage = objc.getClass("NSImage") orelse return;
    const NSFont = objc.getClass("NSFont") orelse return;
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return;
    const NSDictionary = objc.getClass("NSDictionary") orelse return;

    const text = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, brand_text.ptr)},
    );

    // 15pt semibold matches the visual weight of an SF Symbol at default
    // menubar size. NSFontWeightSemibold = 0.3.
    const font = NSFont.msgSend(
        objc.Object,
        "systemFontOfSize:weight:",
        .{ @as(f64, 15), @as(f64, 0.3) },
    );

    const font_attr = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, "NSFont")},
    );
    const attrs = NSDictionary.msgSend(
        objc.Object,
        "dictionaryWithObject:forKey:",
        .{ font, font_attr },
    );

    const attr_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const attr = attr_alloc.msgSend(
        objc.Object,
        "initWithString:attributes:",
        .{ text, attrs },
    );

    var size = attr.msgSend(NSSize, "size", .{});
    size.width = @ceil(size.width);
    size.height = @ceil(size.height);

    const img_alloc = NSImage.msgSend(objc.Object, "alloc", .{});
    const img = img_alloc.msgSend(objc.Object, "initWithSize:", .{size});

    img.msgSend(void, "lockFocus", .{});
    attr.msgSend(void, "drawAtPoint:", .{NSPoint{ .x = 0, .y = 0 }});
    img.msgSend(void, "unlockFocus", .{});

    img.msgSend(void, "setTemplate:", .{@as(c_int, 1)});
    button.msgSend(void, "setImage:", .{img});
}

fn setSymbolImage(button: objc.Object, symbol: [:0]const u8) void {
    const NSString = objc.getClass("NSString") orelse return;
    const NSImage = objc.getClass("NSImage") orelse return;
    const name = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, symbol.ptr)},
    );
    const img = NSImage.msgSend(
        objc.Object,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ name, @as(?*anyopaque, null) },
    );
    if (img.value == null) {
        // SF Symbols missing on older macOS: fall back to a literal title.
        button.msgSend(void, "setTitle:", .{name});
        return;
    }
    img.msgSend(void, "setTemplate:", .{@as(c_int, 1)});
    button.msgSend(void, "setImage:", .{img});
}

/// Build the dropdown NSMenu. Items in order:
///   0. Status line (disabled, updated by updateState)
///   1. Separator
///   2. Show / Hide djinn  (Cmd-toggle hint shown via key equivalent)
///   3. Copy MCP config
///   4. Separator
///   5. Quit
fn buildMenu() objc.Object {
    const NSMenu = objc.getClass("NSMenu") orelse unreachable;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse unreachable;
    const NSString = objc.getClass("NSString") orelse unreachable;
    const Controller = objc.getClass("DjinnMenuController") orelse unreachable;

    const menu_alloc = NSMenu.msgSend(objc.Object, "alloc", .{});
    const menu = menu_alloc.msgSend(objc.Object, "initWithTitle:", .{ns(NSString, "djinn")});
    menu.msgSend(void, "setAutoenablesItems:", .{@as(c_int, 0)});

    const ctrl = Controller.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    // 0. Status line (disabled)
    const status = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Idle"), @as(?*anyopaque, null), ns(NSString, "") },
    );
    status.msgSend(void, "setEnabled:", .{@as(c_int, 0)});
    menu.msgSend(void, "addItem:", .{status});

    menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{})});

    // 2. Show / Hide
    const showhide = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Show / Hide djinn"), objc.sel("showHide:"), ns(NSString, "") },
    );
    showhide.msgSend(void, "setTarget:", .{ctrl});
    menu.msgSend(void, "addItem:", .{showhide});

    // 3. Copy MCP config
    const copy = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Copy MCP config to clipboard"), objc.sel("copyMcpConfig:"), ns(NSString, "") },
    );
    copy.msgSend(void, "setTarget:", .{ctrl});
    menu.msgSend(void, "addItem:", .{copy});

    // 4. Settings… (Cmd+,) — keyEquivalent string + default modifier mask
    // (Cmd) means the menu shows the standard shortcut hint and AppKit
    // routes the key combo to the action when the menu is in the
    // responder chain.
    const settings = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Settings…"), objc.sel("openSettings:"), ns(NSString, ",") },
    );
    settings.msgSend(void, "setTarget:", .{ctrl});
    menu.msgSend(void, "addItem:", .{settings});

    menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{})});

    // 5. Quit
    const quit = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Quit djinn"), objc.sel("quit:"), ns(NSString, "q") },
    );
    quit.msgSend(void, "setTarget:", .{ctrl});
    menu.msgSend(void, "addItem:", .{quit});

    return menu;
}

fn ns(NSString: objc.Class, str: [:0]const u8) objc.Object {
    return NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, str.ptr)},
    );
}

var g_controller_registered: bool = false;

fn registerControllerClass() void {
    if (g_controller_registered) return;
    g_controller_registered = true;
    const superclass = objc.getClass("NSObject") orelse return;
    const cls = objc.allocateClassPair(superclass, "DjinnMenuController") orelse return;
    _ = cls.addMethod("showHide:", showHideImpl);
    _ = cls.addMethod("copyMcpConfig:", copyMcpConfigImpl);
    _ = cls.addMethod("openSettings:", openSettingsImpl);
    _ = cls.addMethod("quit:", quitImpl);
    objc.registerClassPair(cls);
}

fn showHideImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    if (g_show_hide_handler) |h| h();
}

fn copyMcpConfigImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const home = std.posix.getenv("HOME") orelse return;
    const allocator = std.heap.page_allocator;
    const path = std.mem.concat(allocator, u8, &.{ home, "/.config/djinn/mcp.json" }) catch return;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();
    const contents = file.readToEndAllocOptions(allocator, 64 * 1024, null, .of(u8), 0) catch return;
    defer allocator.free(contents);

    const NSPasteboard = objc.getClass("NSPasteboard") orelse return;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    _ = pb.msgSend(c_long, "clearContents", .{});

    const NSString = objc.getClass("NSString") orelse return;
    const ns_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, contents.ptr)},
    );
    const type_name = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*c]const u8, "public.utf8-plain-text")},
    );
    _ = pb.msgSend(c_int, "setString:forType:", .{ ns_str, type_name });
}

fn openSettingsImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    openSettings();
}

/// Open `~/.config/djinn/config` in the user's text editor. Creates the
/// file + parent dir with a defaults skeleton if missing.
///
/// Uses `/usr/bin/open -t` (open as text) — same approach ghostty takes.
/// Plain `[NSWorkspace openURL:]` defers to LaunchServices' default for
/// the file's UTI; the `-t` flag forces the system default text editor.
pub fn openSettings() void {
    const home = std.posix.getenv("HOME") orelse return;
    const allocator = std.heap.page_allocator;
    const dir = std.mem.concat(allocator, u8, &.{ home, "/.config/djinn" }) catch return;
    defer allocator.free(dir);
    const path = std.mem.concat(allocator, u8, &.{ dir, "/config" }) catch return;
    defer allocator.free(path);

    std.fs.makeDirAbsolute(dir) catch {};
    if (std.fs.accessAbsolute(path, .{})) {} else |_| {
        if (std.fs.createFileAbsolute(path, .{})) |f| {
            defer f.close();
            f.writeAll(default_config_skeleton) catch {};
        } else |_| {}
    }

    var child = std.process.Child.init(
        &.{ "/usr/bin/open", "-t", path },
        allocator,
    );
    child.spawn() catch return;
    _ = child.wait() catch {};
}

/// ghostty-style key=value config. Comments start with `#` at column 0
/// (inline `#` reserved for hex). Unknown keys log a warning.
const default_config_skeleton =
    \\# djinn config
    \\#
    \\# Format mirrors ghostty's: `key = value` per line, `#` line comments.
    \\# Settings menu (Cmd+,) reopens this file.
    \\
    \\# ─── Window ──────────────────────────────────────────────────
    \\window-width = 800
    \\window-height = 400
    \\window-position = top-center
    \\hide-on-blur = false
    \\
    \\# ─── Toggle hotkey ───────────────────────────────────────────
    \\hotkey = ctrl+space
    \\
    \\# ─── Provider (claude / codex / aider / gemini / generic) ───
    \\provider = generic
    \\# provider-command = /usr/local/bin/claude
    \\
    \\# ─── Renderer ────────────────────────────────────────────────
    \\# coregraphics — drawRect + CTFontDrawGlyphs (default)
    \\# metal       — djinn's CAMetalLayer + glyph atlas
    \\# ghostty     — Tier-5: libghostty surface owns the layer (native font + AA)
    \\render-backend = coregraphics
    \\
    \\# ─── Terminal ────────────────────────────────────────────────
    \\# font-family = IosevkaTerm Nerd Font Mono
    \\# font-size = 13
    \\# padding-x = 8
    \\# padding-y = 8
    \\# cursor-style = block         # block / bar / underline
    \\
    \\# ─── Theme ───────────────────────────────────────────────────
    \\inherit-ghostty = true
    \\# opacity = 0.95
    \\# background = #1e1e2e
    \\# foreground = #cdd6f4
    \\# cursor-color = #f5e0dc
    \\
    \\# ─── Cursor + scrollback ────────────────────────────────────
    \\cursor-blink = true
    \\scrollback-size = 10000
    \\
    \\# ─── Log pane (toggle: Cmd+/) ───────────────────────────────
    \\log-pane-enabled = false
    \\log-pane-width-fraction = 0.28
    \\log-pane-width-min = 220
    \\log-pane-width-max = 360
    \\
    \\# ─── System ──────────────────────────────────────────────────
    \\open-at-login = false
    \\
    \\# ─── Bell ────────────────────────────────────────────────────
    \\bell-audible = true
    \\bell-visual = false
    \\bell-sound = Tink
    \\
    \\# ─── MCP server ──────────────────────────────────────────────
    \\mcp-enabled = true
    \\
    \\# ─── Notifications ──────────────────────────────────────────
    \\system-notifications = true
    \\menubar-icon = true
    \\attention-sound = Glass
    \\
    \\# ─── Keybinds ────────────────────────────────────────────────
    \\# Format: keybind = action=trigger
    \\# Actions: copy, paste, scroll_page_up, scroll_page_down,
    \\#          font_inc, font_dec, font_reset, clear_scrollback,
    \\#          open_settings, toggle_log_pane, palette_open,
    \\#          tab_1..tab_9, next_tab, prev_tab
    \\# Example: keybind = clear_scrollback=cmd+l
    \\
;

fn quitImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
}

test "stateSymbol: all states map" {
    const states = [_]AgentState{ .idle, .working, .attention, .done, .@"error" };
    for (states) |s| {
        const sym = Menubar.stateSymbol(s);
        try std.testing.expect(sym.len > 0);
    }
}
