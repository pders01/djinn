const std = @import("std");
const objc = @import("objc");
const app_state = @import("../app.zig");

// Class registration is a one-shot flag with no cross-callback reach,
// so it stays module-private. Resize wiring goes through app.g.
var g_class_registered: bool = false;
var g_key_observers_registered: bool = false;

/// Subclass NSPanel so we can override `canBecomeKeyWindow:` — borderless
/// panels return NO by default, which prevents the contentView from ever
/// receiving keyDown events.
fn registerPanelClass() void {
    if (g_class_registered) return;
    g_class_registered = true;
    const superclass = objc.getClass("NSPanel") orelse return;
    const cls = objc.allocateClassPair(superclass, "DjinnPanel") orelse return;
    _ = cls.addMethod("canBecomeKeyWindow", canBecomeKeyImpl);
    _ = cls.addMethod("canBecomeMainWindow", canBecomeKeyImpl);
    _ = cls.addMethod("djinnPanelDidResignKey:", didResignKeyImpl);
    _ = cls.addMethod("djinnPanelDidBecomeKey:", didBecomeKeyImpl);
    _ = cls.addMethod("djinnApplicationDidDeactivate:", didDeactivateImpl);
    _ = cls.addMethod("djinnPanelDidEndLiveResize:", didEndLiveResizeImpl);
    _ = cls.addMethod("djinnPanelGeometryDidChange:", geometryDidChangeImpl);
    _ = cls.addMethod("djinnPanelRestoreBellAlpha:", restoreBellAlphaImpl);
    objc.registerClassPair(cls);
}

/// Reset alpha after a visual-bell flash. Scheduled via
/// performSelector:withObject:afterDelay: from `Panel.flashBell`.
fn restoreBellAlphaImpl(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const p = app_state.g.window.panel orelse return;
    const panel_obj = objc.Object.fromId(self_id);
    panel_obj.msgSend(void, "setAlphaValue:", .{p.expected_alpha});
}

fn canBecomeKeyImpl(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

/// Key-window focus is independent of visibility and hide-on-blur policy.
/// A sibling window taking key also unfocuses the terminal, but does not
/// dismiss the panel while our application remains active.
fn didResignKeyImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const p = app_state.g.window.panel orelse return;
    if (app_state.g.ghostty.surface) |surf_ptr| {
        const ghostty_runtime = @import("../ghostty/runtime.zig");
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        ghostty_runtime.surfaceSetFocus(surf, false);
    }
    p.dismissForBlur(.key_resigned);
}

/// Deactivation can follow a prior key resignation (e.g. to a sibling
/// window), so it needs its own observer rather than relying on key loss.
fn didDeactivateImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const p = app_state.g.window.panel orelse return;
    if (app_state.g.ghostty.surface) |surf_ptr| {
        const ghostty_runtime = @import("../ghostty/runtime.zig");
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        ghostty_runtime.surfaceSetFocus(surf, false);
    }
    p.dismissForBlur(.app_deactivated);
}

const BlurEvent = enum { key_resigned, app_deactivated };

fn shouldDismissOnBlur(visible: bool, enabled: bool, event: BlurEvent, app_active: bool) bool {
    return visible and enabled and (event == .app_deactivated or !app_active);
}

test "blur dismissal follows deactivation even after key resignation" {
    try std.testing.expect(!shouldDismissOnBlur(true, true, .key_resigned, true));
    // No second key resignation is needed; the deactivation notification
    // is authoritative even if isActive has not caught up yet.
    try std.testing.expect(shouldDismissOnBlur(true, true, .app_deactivated, true));
    try std.testing.expect(shouldDismissOnBlur(true, true, .key_resigned, false));
    for ([_]BlurEvent{ .key_resigned, .app_deactivated }) |event| {
        try std.testing.expect(!shouldDismissOnBlur(true, false, event, false));
        try std.testing.expect(!shouldDismissOnBlur(false, true, event, false));
    }
}

/// Clicking a still-visible, unfocused panel may not change its first
/// responder, so becomeFirstResponder alone cannot restore surface focus.
fn didBecomeKeyImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const p = app_state.g.window.panel orelse return;
    if (!p.visible) return;
    if (app_state.g.ghostty.surface) |surf_ptr| {
        const ghostty_runtime = @import("../ghostty/runtime.zig");
        const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
        ghostty_runtime.surfaceSetFocus(surf, true);
    }
}

/// Window notifications cover backing/screen changes and resizing even
/// while ordered out. Do not gate geometry synchronization on visibility.
fn geometryDidChangeImpl(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    @import("../terminal/view.zig").relayout();
}

fn didEndLiveResizeImpl(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    @import("../terminal/view.zig").relayout();
    const handler = app_state.g.window.resize_handler orelse return;
    const panel_obj = objc.Object.fromId(self_id);
    const frame = panel_obj.msgSend(NSRect, "frame", .{});
    const w: u32 = @intFromFloat(@max(1.0, frame.size.width));
    const h: u32 = @intFromFloat(@max(1.0, frame.size.height));
    handler(w, h);
}

/// Quake-drop NSPanel: floats above other windows, joins all spaces, slides
/// down from above the screen on show, slides up on hide.
pub const Panel = struct {
    /// 9-grid anchor on the active screen. Resolved at show-time against
    /// the screen the cursor lives on (multi-monitor friendly). Manual
    /// coords (`position_x` / `position_y`) override the corresponding
    /// axis when non-null.
    pub const Position = enum {
        top_left,
        top_center,
        top_right,
        center_left,
        center,
        center_right,
        bottom_left,
        bottom_center,
        bottom_right,
    };

    ns_app: objc.Object,
    ns_panel: objc.Object,
    blur_view: ?objc.Object = null,
    visible: bool = false,
    hidden_y: f64 = 0,
    visible_y: f64 = 0,
    width: f64 = 800,
    height: f64 = 400,
    blur: bool = false,
    /// When true, show/hide skip the slide animation and the panel pops in
    /// place. Wired from `window-toggle-style = instant`.
    instant_toggle: bool = false,
    /// Anchor on the active screen. Wired from `window-position`.
    position: Position = .top_center,
    /// Manual override in NSScreen coords (origin bottom-left of the
    /// active screen, +Y up). When non-null, replaces the enum-derived
    /// value for that axis.
    position_x: ?f64 = null,
    position_y: ?f64 = null,
    /// Steady-state alpha — what `flashBell` restores to after the
    /// visual-bell dim. Tracked here because theme reloads (light/dark
    /// flip) update it via `setBackgroundColor`. Blur-on panels stay at
    /// 1.0 (the visual-effect view does the painting); blur-off panels
    /// follow `theme.opacity`.
    expected_alpha: f64 = 1.0,
    /// PID of the application that was frontmost when the panel was last
    /// shown. Used to restore focus on hide so a Quake-style toggle behaves
    /// like Spotlight: pop in over your work, then disappear without leaving
    /// djinn frontmost. 0 = nothing to restore.
    prev_app_pid: i32 = 0,

    pub fn init(width: f64, height: f64, opacity: f64, bg_r: f64, bg_g: f64, bg_b: f64, blur: bool) !Panel {
        registerPanelClass();

        const NSApplication = objc.getClass("NSApplication") orelse return error.ClassNotFound;
        const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
        // NSApplicationActivationPolicyAccessory = 1: no dock icon, can become frontmost,
        // can host menubar items (status item).
        _ = app.msgSend(c_long, "setActivationPolicy:", .{@as(c_long, 1)});

        const NSScreen = objc.getClass("NSScreen") orelse return error.ClassNotFound;
        const main_screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});
        const screen_frame = main_screen.msgSend(NSRect, "frame", .{});

        const x = (screen_frame.size.width - width) / 2.0;
        const visible_y = screen_frame.size.height - height;
        const hidden_y = screen_frame.size.height;

        const visible_frame = NSRect{
            .origin = .{ .x = x, .y = visible_y },
            .size = .{ .width = width, .height = height },
        };

        // NSWindowStyleMaskBorderless (0) | NSWindowStyleMaskResizable (1 << 3).
        // Resizable bit alone keeps the panel chrome-free but allows live resize
        // via invisible edge/corner hit areas.
        const style_mask: c_ulong = 1 << 3;
        // NSBackingStoreBuffered = 2
        const backing: c_ulong = 2;

        const DjinnPanel = objc.getClass("DjinnPanel") orelse return error.ClassNotFound;
        const alloc = DjinnPanel.msgSend(objc.Object, "alloc", .{});
        const panel = alloc.msgSend(
            objc.Object,
            "initWithContentRect:styleMask:backing:defer:",
            .{ visible_frame, style_mask, backing, @as(c_int, 0) },
        );

        // setFloatingPanel:1 makes the panel "stay key when other windows
        // lose focus" — desirable for tool palettes, fatal for Quake-drop.
        // It prevents Cmd+Tab from deactivating djinn, so windowDidResignKey
        // never fires + the panel never hides. setLevel + collection
        // behavior below give us the visual on-top property without the
        // focus-stickiness.
        panel.msgSend(void, "setFloatingPanel:", .{@as(c_int, 0)});
        // Always hide explicitly. AppKit's automatic hiding restores the
        // panel on reactivation behind our visible/focus/occlusion state.
        panel.msgSend(void, "setHidesOnDeactivate:", .{@as(c_int, 0)});
        panel.msgSend(void, "setReleasedWhenClosed:", .{@as(c_int, 0)});
        panel.msgSend(void, "setOpaque:", .{@as(c_int, 0)});
        // NSFloatingWindowLevel = 3 — above normal windows but below
        // system UI (IME candidate windows, context menus, popups,
        // tooltips). setFloatingPanel:1 + FullScreenAuxiliary
        // collection behavior already keep the panel on top of regular
        // app windows + over fullscreen apps; we used to sit at
        // NSStatusWindowLevel (25) which covered IME candidates.
        panel.msgSend(void, "setLevel:", .{@as(c_long, 3)});

        // Collection behavior:
        //   NSWindowCollectionBehaviorCanJoinAllSpaces  = 1 << 0
        //   NSWindowCollectionBehaviorFullScreenAuxiliary = 1 << 8 (=256)
        // Together: panel appears on every space and overlays fullscreen apps.
        const cb: c_ulong = (1 << 0) | (1 << 8);
        panel.msgSend(void, "setCollectionBehavior:", .{cb});

        const NSColor = objc.getClass("NSColor") orelse return error.ClassNotFound;

        var blur_view: ?objc.Object = null;
        if (blur) {
            // Blur: panel transparent. Use a plain NSView as the contentView
            // and stack two siblings inside: NSVisualEffectView (background
            // blur layer, sized to fill) and a placeholder for the content
            // container (added later via setContentView). Sibling layout
            // avoids the case where NSVisualEffectView, when used directly
            // as contentView, suppresses autoresize propagation to its
            // subviews after a window resize cycle.
            panel.msgSend(void, "setAlphaValue:", .{@as(f64, 1.0)});
            const clear = NSColor.msgSend(objc.Object, "clearColor", .{});
            panel.msgSend(void, "setBackgroundColor:", .{clear});

            const NSView = objc.getClass("NSView") orelse return error.ClassNotFound;
            const wrapper_alloc = NSView.msgSend(objc.Object, "alloc", .{});
            const content_frame = NSRect{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = width, .height = height },
            };
            const wrapper = wrapper_alloc.msgSend(objc.Object, "initWithFrame:", .{content_frame});

            const NSVisualEffectView = objc.getClass("NSVisualEffectView") orelse return error.ClassNotFound;
            const ve_alloc = NSVisualEffectView.msgSend(objc.Object, "alloc", .{});
            const ve = ve_alloc.msgSend(objc.Object, "initWithFrame:", .{content_frame});
            ve.msgSend(void, "setMaterial:", .{@as(c_long, 13)}); // hudWindow
            ve.msgSend(void, "setBlendingMode:", .{@as(c_long, 0)}); // behindWindow
            ve.msgSend(void, "setState:", .{@as(c_long, 1)}); // active
            ve.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))});
            wrapper.msgSend(void, "addSubview:", .{ve});

            panel.msgSend(void, "setContentView:", .{wrapper});
            blur_view = wrapper; // setContentView will add the content as a sibling of `ve`
        } else {
            // No blur: opacity applied at the window level, bg is solid theme color.
            panel.msgSend(void, "setAlphaValue:", .{opacity});
            const bg = NSColor.msgSend(
                objc.Object,
                "colorWithSRGBRed:green:blue:alpha:",
                .{ bg_r, bg_g, bg_b, @as(f64, 1.0) },
            );
            panel.msgSend(void, "setBackgroundColor:", .{bg});
        }

        // AppKit emits these for programmatic/hidden resizes too. View
        // frame notifications handle intermediate live-resize geometry;
        // window notifications also catch scale-only display transitions.
        if (objc.getClass("NSNotificationCenter")) |NotificationCenter| {
            const center = NotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
            const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
            for ([_][*:0]const u8{
                "NSWindowDidResizeNotification",
                "NSWindowDidChangeBackingPropertiesNotification",
                "NSWindowDidChangeScreenNotification",
            }) |name| {
                const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*c]const u8, name)});
                center.msgSend(void, "addObserver:selector:name:object:", .{
                    panel, objc.sel("djinnPanelGeometryDidChange:"), ns_name, panel,
                });
            }
        }

        return .{
            .ns_app = app,
            .ns_panel = panel,
            .blur_view = blur_view,
            .hidden_y = hidden_y,
            .visible_y = visible_y,
            .width = width,
            .height = height,
            .blur = blur,
            .expected_alpha = if (blur) 1.0 else opacity,
        };
    }

    pub fn show(self: *Panel) void {
        if (!@import("../ghostty/surface_lifecycle.zig").ensureActiveSession()) return;
        // Capture the app that's currently frontmost so hide() can hand
        // focus back. NSWorkspace.frontmostApplication returns the app with
        // the menu bar — the app the user was using before they hit our
        // hotkey.
        self.prev_app_pid = currentFrontmostPid();

        const frame = self.ns_panel.msgSend(NSRect, "frame", .{});
        // Anchor the visible-state Y to the *current* (possibly resized) panel
        // height on the screen the cursor lives on. Using NSScreen.mainScreen
        // here would lock the popup to the keyboard-focused display even when
        // the user has dragged their mouse to a second monitor expecting it
        // to land there. Origin x re-centers on the cursor screen too —
        // multi-monitor frames have non-zero origin.x in the global coord space.
        var target_x = frame.origin.x;
        var target_y = self.hidden_y;
        var visible_y = self.visible_y;
        if (currentScreen()) |screen| {
            const sframe = screen.msgSend(NSRect, "frame", .{});
            target_x = if (self.position_x) |px|
                sframe.origin.x + px
            else switch (self.position) {
                .top_left, .center_left, .bottom_left => sframe.origin.x,
                .top_center, .center, .bottom_center => sframe.origin.x + (sframe.size.width - frame.size.width) / 2.0,
                .top_right, .center_right, .bottom_right => sframe.origin.x + sframe.size.width - frame.size.width,
            };
            visible_y = if (self.position_y) |py|
                sframe.origin.y + py
            else switch (self.position) {
                .top_left, .top_center, .top_right => sframe.origin.y + sframe.size.height - frame.size.height,
                .center_left, .center, .center_right => sframe.origin.y + (sframe.size.height - frame.size.height) / 2.0,
                .bottom_left, .bottom_center, .bottom_right => sframe.origin.y,
            };
            // Slide-from anchor stays above the screen so the animation
            // direction is consistent regardless of `position`.
            target_y = sframe.origin.y + sframe.size.height;
            self.hidden_y = target_y;
            self.visible_y = visible_y;
        }

        const target = NSRect{
            .origin = .{ .x = target_x, .y = visible_y },
            .size = frame.size,
        };

        if (self.instant_toggle) {
            self.ns_panel.msgSend(void, "setFrame:display:", .{ target, @as(c_int, 0) });
        } else {
            const start = NSRect{
                .origin = .{ .x = target_x, .y = target_y },
                .size = frame.size,
            };
            self.ns_panel.msgSend(void, "setFrame:display:", .{ start, @as(c_int, 0) });
        }
        // Key/activation notifications and the animation can reenter us.
        // Let blur dismissal see this show, and never overwrite its state
        // if the user switches apps before the animation has completed.
        self.visible = true;
        self.ns_panel.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        if (!self.visible) return;
        self.ns_app.msgSend(void, "activateIgnoringOtherApps:", .{@as(c_int, 1)});
        if (!self.visible) return;

        // makeKeyAndOrderFront resets firstResponder to the window's
        // initialFirstResponder (defaults to contentView, which is the
        // blur NSVisualEffectView — has no keyDown). Push it back to
        // the TerminalView so keystrokes reach our forwarding path.
        if (app_state.g.term.view_id) |vid| {
            _ = self.ns_panel.msgSend(c_int, "makeFirstResponder:", .{objc.Object.fromId(vid)});
        }
        if (!self.instant_toggle) {
            self.ns_panel.msgSend(void, "setFrame:display:animate:", .{ target, @as(c_int, 1), @as(c_int, 1) });
        }

        // Re-resolve theme on show. AppKit suppresses
        // viewDidChangeEffectiveAppearance for offscreen windows, so a
        // system light↔dark flip while the panel is hidden leaves djinn
        // chrome (tab strip, find bar, panel bg) stuck on the
        // stale palette. Ghostty's surface has its own appearance
        // pipeline and flips independently — that's why the terminal
        // pane updates but the chrome around it lags. The internal
        // `last_appearance == current_tag` guard makes this a no-op
        // when nothing actually changed.
        if (!self.visible) return;
        @import("../terminal/view.zig").reapplyThemeIfChanged();
        @import("../terminal/view.zig").relayout();

        // Force a fresh redraw of the entire view hierarchy. orderOut may
        // discard the backing store; without an explicit invalidation, AppKit
        // can re-display stale or empty pixels after orderFront.
        const cv = self.ns_panel.msgSend(objc.Object, "contentView", .{});
        if (cv.value != null) {
            cv.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
            recursiveSetNeedsDisplay(cv);
        }
        if (!self.visible) return;

        // Visibility wakes rendering; focus follows the actual key window.
        // Key notifications keep focus current even when hide-on-blur is off.
        if (app_state.g.ghostty.surface) |surf_ptr| {
            const ghostty_runtime = @import("../ghostty/runtime.zig");
            const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
            ghostty_runtime.surfaceSetOcclusion(surf, true);
            ghostty_runtime.surfaceSetFocus(surf, self.ns_panel.msgSend(bool, "isKeyWindow", .{}));
        }
    }

    /// Explicit hide (hotkey toggle). Slides offscreen, orderOut, then
    /// conditionally restores the previously-frontmost regular app.
    ///
    /// The restore fires only when djinn was the active app at hide
    /// time. Counter-example: user shows djinn over A, Cmd+Tabs to B,
    /// then hits hotkey to dismiss the still-visible panel. djinn is
    /// not active (B is) — restoring `prev_app_pid=A` would yank
    /// the user back to A, undoing their Cmd+Tab. So we leave
    /// frontmost alone in that case and just hide the chrome.
    ///
    /// `NSApp.isActive` is the correct probe here, not
    /// `NSWorkspace.frontmostApplication`. djinn is an Accessory app
    /// — the workspace's frontmost-application machinery never
    /// reports an Accessory as frontmost, even when its panel owns
    /// key. `isActive` reflects the AppKit-level "is this process
    /// driving the menu bar / receiving key events" view, which is
    /// exactly the user-intent question we want to answer.
    pub fn hide(self: *Panel) void {
        const djinn_was_active = self.ns_app.msgSend(bool, "isActive", .{});

        const frame = self.ns_panel.msgSend(NSRect, "frame", .{});

        var target_x = frame.origin.x;
        var visible_y = self.visible_y;
        var hidden_y = self.hidden_y;
        if (currentScreen()) |screen| {
            const win_screen = self.ns_panel.msgSend(objc.Object, "screen", .{});
            const used = if (win_screen.value != null) win_screen else screen;
            const fr = used.msgSend(NSRect, "frame", .{});
            visible_y = fr.origin.y + fr.size.height - frame.size.height;
            hidden_y = fr.origin.y + fr.size.height;
            target_x = frame.origin.x;
            self.visible_y = visible_y;
            self.hidden_y = hidden_y;
        }

        if (self.instant_toggle) {
            self.ns_panel.msgSend(void, "orderOut:", .{@as(?*anyopaque, null)});
        } else {
            const offscreen = NSRect{
                .origin = .{ .x = target_x, .y = hidden_y },
                .size = frame.size,
            };
            self.ns_panel.msgSend(void, "setFrame:display:animate:", .{ offscreen, @as(c_int, 1), @as(c_int, 1) });

            self.ns_panel.msgSend(void, "orderOut:", .{@as(?*anyopaque, null)});
            const restore = NSRect{
                .origin = .{ .x = target_x, .y = visible_y },
                .size = frame.size,
            };
            self.ns_panel.msgSend(void, "setFrame:display:", .{ restore, @as(c_int, 0) });
        }

        if (djinn_was_active and self.prev_app_pid != 0) {
            activateAppByPid(self.prev_app_pid);
        }

        self.syncHiddenState();
    }

    /// Dismiss without animation or focus restoration: another app already
    /// owns activation. Clear state before orderOut's reentrant key callback.
    fn dismissForBlur(self: *Panel, event: BlurEvent) void {
        if (!shouldDismissOnBlur(self.visible, app_state.g.window.hide_on_blur, event, self.ns_app.msgSend(bool, "isActive", .{}))) return;
        self.syncHiddenState();
        self.ns_panel.msgSend(void, "orderOut:", .{@as(?*anyopaque, null)});
    }

    /// Reconcile explicit toggle/blur dismissal with surface bookkeeping.
    pub fn syncHiddenState(self: *Panel) void {
        self.prev_app_pid = 0;
        self.visible = false;

        if (app_state.g.ghostty.surface) |surf_ptr| {
            const ghostty_runtime = @import("../ghostty/runtime.zig");
            const surf: ghostty_runtime.c.ghostty_surface_t = @ptrCast(surf_ptr);
            ghostty_runtime.surfaceSetFocus(surf, false);
            ghostty_runtime.surfaceSetOcclusion(surf, false);
        }
    }

    pub fn toggle(self: *Panel) void {
        if (self.visible) self.hide() else self.show();
    }

    pub fn setInstantToggle(self: *Panel, instant: bool) void {
        self.instant_toggle = instant;
    }

    pub fn setPosition(self: *Panel, position: Position, position_x: ?f64, position_y: ?f64) void {
        self.position = position;
        self.position_x = position_x;
        self.position_y = position_y;
    }

    /// Toggle NSFloatingWindowLevel (3, "always on top") vs NSNormalWindowLevel
    /// (0, regular stacking). Off lets djinn coexist with normal app focus
    /// order — the panel stops floating over other windows but still joins
    /// all spaces and overlays fullscreen apps via collection behavior.
    pub fn setTopmost(self: *Panel, topmost: bool) void {
        const level: c_long = if (topmost) 3 else 0;
        self.ns_panel.msgSend(void, "setLevel:", .{level});
    }

    pub fn setContentView(self: *Panel, view: objc.Object) void {
        if (self.blur_view) |ve| {
            // Add the terminal view as a subview of the visual effect view so
            // the blur shows through. The terminal view is responsible for
            // drawing a translucent bg over the blur layer.
            view.msgSend(void, "setFrame:", .{NSRect{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = self.width, .height = self.height },
            }});
            view.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, (1 << 1) | (1 << 4))}); // width + height sizable
            ve.msgSend(void, "addSubview:", .{view});
        } else {
            self.ns_panel.msgSend(void, "setContentView:", .{view});
        }
        _ = self.ns_panel.msgSend(c_int, "makeFirstResponder:", .{view});
    }

    /// Resize the panel to `width`×`height`, re-anchored to its current
    /// position grid (top_left → origin stays at the top-left of the
    /// active screen; top_center → re-centers). Called when switching
    /// to a profile that has a persisted per-profile size in
    /// state.json. Each profile gets its own frame back. No-op when dims
    /// match current frame to avoid a redundant repaint.
    pub fn setSize(self: *Panel, width: f64, height: f64) void {
        const cur = self.ns_panel.msgSend(NSRect, "frame", .{});
        if (cur.size.width == width and cur.size.height == height) return;

        self.width = width;
        self.height = height;

        // Re-resolve origin against the screen the panel is on so
        // top_center / center / bottom_center stay anchored after the
        // size change. Mirrors the `show()` placement math.
        const win_screen = self.ns_panel.msgSend(objc.Object, "screen", .{});
        const screen = if (win_screen.value != null) win_screen else (currentScreen() orelse return);
        const sframe = screen.msgSend(NSRect, "frame", .{});

        const new_x = if (self.position_x) |px|
            sframe.origin.x + px
        else switch (self.position) {
            .top_left, .center_left, .bottom_left => sframe.origin.x,
            .top_center, .center, .bottom_center => sframe.origin.x + (sframe.size.width - width) / 2.0,
            .top_right, .center_right, .bottom_right => sframe.origin.x + sframe.size.width - width,
        };
        const new_y = if (self.position_y) |py|
            sframe.origin.y + py
        else switch (self.position) {
            .top_left, .top_center, .top_right => sframe.origin.y + sframe.size.height - height,
            .center_left, .center, .center_right => sframe.origin.y + (sframe.size.height - height) / 2.0,
            .bottom_left, .bottom_center, .bottom_right => sframe.origin.y,
        };

        self.visible_y = new_y;
        self.hidden_y = sframe.origin.y + sframe.size.height;

        const target = NSRect{
            .origin = .{ .x = new_x, .y = new_y },
            .size = .{ .width = width, .height = height },
        };
        // Animate when visible — the size pop is jarring without it.
        // Skip animation when hidden — no point spending frames on a
        // window the user can't see.
        const animate: c_int = if (self.visible) 1 else 0;
        self.ns_panel.msgSend(void, "setFrame:display:animate:", .{ target, @as(c_int, 1), animate });
        @import("../terminal/view.zig").relayout();
    }

    /// Register a resize-end handler. AppKit emits NSWindowDidEndLiveResize
    /// once the user releases a window-edge drag; we forward the new frame
    /// size to the supplied callback (typically the persistence hook).
    pub fn setResizeEndHandler(self: *Panel, handler: *const fn (u32, u32) void) void {
        app_state.g.window.resize_handler = handler;

        const NSNotificationCenter = objc.getClass("NSNotificationCenter") orelse return;
        const center = NSNotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
        const NSString = objc.getClass("NSString") orelse return;
        const name = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*c]const u8, "NSWindowDidEndLiveResizeNotification")},
        );
        center.msgSend(void, "addObserver:selector:name:object:", .{
            self.ns_panel,
            objc.sel("djinnPanelDidEndLiveResize:"),
            name,
            self.ns_panel,
        });
    }

    /// Observe focus independently of the policy. Blur dismissal uses
    /// orderOut, never AppKit auto-hide/restore, and also observes app
    /// deactivation when the panel has already stopped being key.
    pub fn setHideOnBlur(self: *Panel, enabled: bool) void {
        app_state.g.window.hide_on_blur = enabled;
        app_state.g.window.panel = self;

        self.ns_panel.msgSend(void, "setHidesOnDeactivate:", .{@as(c_int, 0)});

        if (g_key_observers_registered) return;

        const NSNotificationCenter = objc.getClass("NSNotificationCenter") orelse return;
        const center = NSNotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
        const NSString = objc.getClass("NSString") orelse return;
        const name = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*c]const u8, "NSWindowDidResignKeyNotification")},
        );
        if (name.value == null) return;
        const become_name = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*c]const u8, "NSWindowDidBecomeKeyNotification")},
        );
        if (become_name.value == null) return;
        const deactivate_name = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*c]const u8, "NSApplicationDidResignActiveNotification")},
        );
        if (deactivate_name.value == null) return;
        center.msgSend(void, "addObserver:selector:name:object:", .{
            self.ns_panel,
            objc.sel("djinnPanelDidResignKey:"),
            name,
            self.ns_panel,
        });
        center.msgSend(void, "addObserver:selector:name:object:", .{
            self.ns_panel,
            objc.sel("djinnPanelDidBecomeKey:"),
            become_name,
            self.ns_panel,
        });
        center.msgSend(void, "addObserver:selector:name:object:", .{
            self.ns_panel,
            objc.sel("djinnApplicationDidDeactivate:"),
            deactivate_name,
            self.ns_app,
        });
        g_key_observers_registered = true;
    }

    /// Update the panel's background color. No-op when blur is on
    /// (the visual effect view does the painting; panel itself stays
    /// transparent). Used by the theme auto-switch path.
    pub fn setBackgroundColor(self: *Panel, r: f64, g: f64, b: f64, opacity: f64) void {
        if (self.blur) return;
        const NSColor = objc.getClass("NSColor") orelse return;
        const bg = NSColor.msgSend(
            objc.Object,
            "colorWithSRGBRed:green:blue:alpha:",
            .{ r, g, b, @as(f64, 1.0) },
        );
        self.ns_panel.msgSend(void, "setBackgroundColor:", .{bg});
        self.ns_panel.msgSend(void, "setAlphaValue:", .{opacity});
        self.expected_alpha = opacity;
    }

    /// Brief alpha dim as a visual bell. Triggered by ghostty's
    /// RING_BELL action when `bell.visual = true`. Hardcoded duration
    /// (0.08s) and dim factor (alpha → 0.4) keep the flash short
    /// enough to feel like an event rather than a state change.
    pub fn flashBell(self: *Panel) void {
        self.ns_panel.msgSend(void, "setAlphaValue:", .{@as(f64, 0.4)});
        const sel = objc.sel("djinnPanelRestoreBellAlpha:");
        self.ns_panel.msgSend(void, "performSelector:withObject:afterDelay:", .{
            sel,
            @as(?*anyopaque, null),
            @as(f64, 0.08),
        });
    }

    pub fn deinit(self: *Panel) void {
        if (objc.getClass("NSNotificationCenter")) |NotificationCenter| {
            const center = NotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
            center.msgSend(void, "removeObserver:", .{self.ns_panel});
        }
        g_key_observers_registered = false;
        self.ns_panel.msgSend(void, "close", .{});
    }
};

/// Pick the NSScreen the user is currently looking at — defined as the
/// screen containing the mouse cursor. NSScreen.mainScreen tracks the
/// keyboard-focused screen, which on multi-monitor setups can lag behind
/// the user's intent (e.g. they moved the mouse to a second display
/// expecting Quake-drop to land there). Falls back to mainScreen when
/// the cursor sits outside every screen rect (rare; sleep/wake transition).
pub fn currentScreen() ?objc.Object {
    const NSEvent = objc.getClass("NSEvent");
    const NSScreen = objc.getClass("NSScreen") orelse return null;

    if (NSEvent) |ne| {
        const mouse: NSPoint = ne.msgSend(NSPoint, "mouseLocation", .{});
        const screens = NSScreen.msgSend(objc.Object, "screens", .{});
        if (screens.value != null) {
            const count: c_ulong = screens.msgSend(c_ulong, "count", .{});
            var i: c_ulong = 0;
            while (i < count) : (i += 1) {
                const s = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
                if (s.value == null) continue;
                const fr = s.msgSend(NSRect, "frame", .{});
                if (mouse.x >= fr.origin.x and mouse.x < fr.origin.x + fr.size.width and
                    mouse.y >= fr.origin.y and mouse.y < fr.origin.y + fr.size.height)
                {
                    return s;
                }
            }
        }
    }

    const main = NSScreen.msgSend(objc.Object, "mainScreen", .{});
    if (main.value == null) return null;
    return main;
}

/// Look up the PID of the app that currently owns the menu bar. Returns 0
/// when NSWorkspace returns no frontmost app or when the app is djinn
/// itself (we don't want to "restore" focus to ourselves).
fn currentFrontmostPid() i32 {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return 0;
    const ws = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const app = ws.msgSend(objc.Object, "frontmostApplication", .{});
    if (app.value == null) return 0;

    const pid: c_int = app.msgSend(c_int, "processIdentifier", .{});
    const me = std.c.getpid();
    if (pid == me) return 0;
    return @intCast(pid);
}

/// Activate the app with the given PID. Falls through silently if the app
/// has since exited.
fn activateAppByPid(pid: i32) void {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return;
    const app = NSRunningApplication.msgSend(
        objc.Object,
        "runningApplicationWithProcessIdentifier:",
        .{@as(c_int, @intCast(pid))},
    );
    if (app.value == null) return;
    // NSApplicationActivationOptions = 0 (default — no extra options).
    _ = app.msgSend(c_int, "activateWithOptions:", .{@as(c_ulong, 0)});
}

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// Walk a view's subview tree and mark every node as needing display.
fn recursiveSetNeedsDisplay(v: objc.Object) void {
    v.msgSend(void, "setNeedsDisplay:", .{@as(c_int, 1)});
    const subs = v.msgSend(objc.Object, "subviews", .{});
    if (subs.value == null) return;
    const count: c_ulong = subs.msgSend(c_ulong, "count", .{});
    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const child = subs.msgSend(objc.Object, "objectAtIndex:", .{i});
        if (child.value != null) recursiveSetNeedsDisplay(child);
    }
}
