const std = @import("std");
const objc = @import("objc");
const platform = @import("../io/platform.zig");
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSPoint = extern struct { x: f64, y: f64 };

/// Action handlers wired by main after the Panel is created. Cocoa method
/// callbacks can't capture Zig context; we route via globals.
var g_show_hide_handler: ?*const fn () void = null;

/// Brand mark: Arabic letters jīm + nūn (= "djinn"). CoreText
/// shapes the contextual joining via NSAttributedString → drawAtPoint, so
/// no HarfBuzz dependency required. setTemplate:1 makes AppKit re-tint to
/// the menubar foreground color (light/dark-mode aware).
const brand_text: [:0]const u8 = "جن";

/// Main-thread-only status item: brand, active session, show/hide,
/// settings, and quit. No process- or application-specific status policy.
pub const Menubar = struct {
    /// Explicit +1 reference, independent of NSStatusBar/autorelease lifetime.
    status_item: ?objc.Object = null,
    /// Borrowed from the menu retained by status_item.
    session_menu_item: ?objc.Object = null,
    /// Owned +1: NSMenuItem targets are not retained by AppKit.
    controller: ?objc.Object = null,

    pub fn init() Menubar {
        registerControllerClass();

        const NSStatusBar = objc.getClass("NSStatusBar") orelse return .{};
        const status_bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});

        const status_item = status_bar.msgSend(
            objc.Object,
            "statusItemWithLength:",
            .{@as(f64, -1)},
        );

        if (status_item.value == null) return .{};
        _ = status_item.msgSend(objc.Object, "retain", .{});

        // A static template image lets AppKit handle light/dark tinting.
        const button = status_item.msgSend(objc.Object, "button", .{});
        setBrandImage(button);

        const built = buildMenu();
        // setMenu: retains the menu; transfer the controller's +1 to Menubar.
        defer built.menu.msgSend(void, "release", .{});
        const session_item = built.menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_long, 0)});

        status_item.msgSend(void, "setMenu:", .{built.menu});

        var result = Menubar{ .status_item = status_item, .session_menu_item = session_item, .controller = built.controller };
        result.refresh();
        return result;
    }

    pub fn setShowHideHandler(self: *Menubar, handler: *const fn () void) void {
        _ = self;
        g_show_hide_handler = handler;
    }

    /// Refresh after session activation/removal and after publishing the
    /// session manager at startup. Keep the app import inside the method:
    /// AppState stores a Menubar pointer, so type layout must not need app.g.
    pub fn refresh(self: *Menubar) void {
        const mi = self.session_menu_item orelse return;
        const app = @import("../app.zig");
        var label: []const u8 = "No active session";
        if (app.g.session_manager) |sm| {
            if (sm.sessions.items.len > 0) label = sm.active().label();
        }
        const NSString = objc.getClass("NSString") orelse return;
        // Length-aware conversion copies the label without a temporary
        // sentinel buffer or splitting a UTF-8 codepoint at a byte cap.
        const title = NSString.msgSend(objc.Object, "alloc", .{}).msgSend(
            objc.Object,
            "initWithBytes:length:encoding:",
            .{ label.ptr, @as(c_ulong, @intCast(label.len)), @as(c_ulong, 4) }, // NSUTF8StringEncoding
        );
        if (title.value == null) return;
        defer title.msgSend(void, "release", .{});
        mi.msgSend(void, "setTitle:", .{title});
    }

    pub fn deinit(self: *Menubar) void {
        self.session_menu_item = null;
        if (self.status_item) |item| {
            const menu = item.msgSend(objc.Object, "menu", .{});
            if (menu.value != null) {
                // Clear non-retained targets before releasing the controller,
                // even if AppKit temporarily keeps the menu/items alive.
                const count = menu.msgSend(c_long, "numberOfItems", .{});
                var i: c_long = 0;
                while (i < count) : (i += 1) {
                    const mi = menu.msgSend(objc.Object, "itemAtIndex:", .{i});
                    mi.msgSend(void, "setTarget:", .{@as(?*anyopaque, null)});
                }
            }
            item.msgSend(void, "setMenu:", .{@as(?*anyopaque, null)});
            if (objc.getClass("NSStatusBar")) |NSStatusBar| {
                const status_bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
                status_bar.msgSend(void, "removeStatusItem:", .{item});
            }
            item.msgSend(void, "release", .{});
        }
        if (self.controller) |ctrl| ctrl.msgSend(void, "release", .{});
        self.* = .{};
    }

    /// Toggle status-item presence at runtime. Used by config-reload
    /// when `notifications.menubar-icon` flips. No-op when the
    /// requested state already matches the current item presence.
    /// Re-enable rebuilds the item via `init` — `g_show_hide_handler`
    /// is global so the new menu inherits the existing handler.
    pub fn setEnabled(self: *Menubar, on: bool) void {
        if (on == (self.status_item != null)) return;
        if (on) {
            self.* = Menubar.init();
        } else {
            self.deinit();
        }
    }
};

/// Render brand_text as a template NSImage using NSAttributedString. Uses
/// the system font at the menubar's icon point size.
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

    defer attr.msgSend(void, "release", .{});

    var size = attr.msgSend(NSSize, "size", .{});
    size.width = @ceil(size.width);
    size.height = @ceil(size.height);

    const img_alloc = NSImage.msgSend(objc.Object, "alloc", .{});
    const img = img_alloc.msgSend(objc.Object, "initWithSize:", .{size});
    // The button retains its image; release our alloc/init reference.
    defer img.msgSend(void, "release", .{});

    img.msgSend(void, "lockFocus", .{});
    attr.msgSend(void, "drawAtPoint:", .{NSPoint{ .x = 0, .y = 0 }});
    img.msgSend(void, "unlockFocus", .{});

    img.msgSend(void, "setTemplate:", .{@as(c_int, 1)});
    button.msgSend(void, "setImage:", .{img});
}

/// Both fields carry +1 references; the caller transfers controller to
/// Menubar and releases menu after the status item retains it.
const BuiltMenu = struct { menu: objc.Object, controller: objc.Object };

/// Build the dropdown: active session, show/hide, settings, and quit.
fn buildMenu() BuiltMenu {
    const NSMenu = objc.getClass("NSMenu") orelse unreachable;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse unreachable;
    const NSString = objc.getClass("NSString") orelse unreachable;
    const Controller = objc.getClass("DjinnMenuController") orelse unreachable;

    const menu_alloc = NSMenu.msgSend(objc.Object, "alloc", .{});
    const menu = menu_alloc.msgSend(objc.Object, "initWithTitle:", .{ns(NSString, "djinn")});
    menu.msgSend(void, "setAutoenablesItems:", .{@as(c_int, 0)});

    const ctrl = Controller.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    // Active session label (informational).
    const status = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "No active session"), @as(?*anyopaque, null), ns(NSString, "") },
    );
    status.msgSend(void, "setEnabled:", .{@as(c_int, 0)});
    menu.msgSend(void, "addItem:", .{status});
    status.msgSend(void, "release", .{}); // NSMenu retains its items.

    menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{})});

    // 2. Show / Hide
    const showhide = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Show / Hide djinn"), objc.sel("showHide:"), ns(NSString, "") },
    );
    showhide.msgSend(void, "setTarget:", .{ctrl});
    menu.msgSend(void, "addItem:", .{showhide});
    showhide.msgSend(void, "release", .{});

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
    settings.msgSend(void, "release", .{});

    menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{})});

    // 5. Quit
    const quit = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ ns(NSString, "Quit djinn"), objc.sel("quit:"), ns(NSString, "q") },
    );
    quit.msgSend(void, "setTarget:", .{ctrl});
    menu.msgSend(void, "addItem:", .{quit});
    quit.msgSend(void, "release", .{});

    return .{ .menu = menu, .controller = ctrl };
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
    _ = cls.addMethod("openSettings:", openSettingsImpl);
    _ = cls.addMethod("quit:", quitImpl);
    objc.registerClassPair(cls);
}

fn showHideImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    if (g_show_hide_handler) |h| h();
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
    const home = platform.getenv("HOME") orelse return;
    const io = platform.io();
    const allocator = std.heap.page_allocator;
    const dir = std.mem.concat(allocator, u8, &.{ home, "/.config/djinn" }) catch return;
    defer allocator.free(dir);
    const path = std.mem.concat(allocator, u8, &.{ dir, "/config" }) catch return;
    defer allocator.free(path);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.debug.print("warning: cannot create settings directory: {}\n", .{err});
        return;
    };
    if (std.Io.Dir.accessAbsolute(io, path, .{})) {} else |err| {
        if (err != error.FileNotFound) {
            std.debug.print("warning: cannot access settings: {}\n", .{err});
            return;
        }
        const f = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |create_err| {
            std.debug.print("warning: cannot create settings: {}\n", .{create_err});
            return;
        };
        defer f.close(io);
        f.writeStreamingAll(io, default_config_skeleton) catch |write_err| {
            std.debug.print("warning: cannot write settings: {}\n", .{write_err});
            return;
        };
    }

    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", "-t", path },
    }) catch return;
    _ = child.wait(io) catch {};
}

/// Mirrored in config/default.conf. The module root is src/, so embedding
/// ../../config/default.conf would escape the Zig package. Keep this small.
const default_config_skeleton =
    \\# djinn: key = value; Settings (Cmd+,) opens this file.
    \\# No profiles required: start an ordinary default shell.
    \\# Avoid macOS shortcut conflicts; change this if needed.
    \\hotkey = ctrl+shift+space
    \\window-width = 800
    \\window-height = 400
    \\window-position = top_center
    \\inherit-ghostty = true
    \\system-notifications = true
    \\notify-rate-limit-ms = 30000
    \\menubar-icon = true
    \\bell-audible = true
    \\bell-visual = false
    \\bell-sound = Tink
    \\open-at-login = false
    \\
    \\# Optional static profiles; changes require an app restart.
    \\# Launch precedence: script > command > default shell.
    \\# Explicit invalid launch settings are errors, not shell fallbacks.
    \\# default-profile = work
    \\# profile.work.script = ~/.config/djinn/profiles/work.sh
    \\# profile.work.cwd = ~/projects/work
    \\# profile.work.title = Work
    \\
;

fn quitImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
}
