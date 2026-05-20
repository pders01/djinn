//! Darwin platform re-exports.
//!
//! Mostly stubs that match the linux impl's contract so `platform.zig`'s
//! comptime switch type-checks. The darwin entry (`src/main.zig`) is
//! still wired against the historical direct imports
//! (`../hotkey/darwin.zig`, `../notify/menubar.zig`, …); migrating
//! those onto this re-export surface is a later, behavior-preserving
//! refactor.
//!
//! Exception: `Notifier` is a real re-export of `notify/darwin.zig`
//! rather than a stub. `mcp/tools.zig` reaches `platform.Notifier`
//! for its banner sender so the linux MCP wiring can share a tool
//! table with the darwin path; that means `platform.Notifier` on
//! darwin must be the actual AppKit-backed sender, not a no-op. The
//! transitive `objc` import only activates on darwin builds because
//! `platform.zig` only switches to this file when
//! `builtin.os.tag == .macos`.

const std = @import("std");
const notify_darwin = @import("../notify/darwin.zig");

pub const Panel = struct {
    pub const Capabilities = struct {
        gtk4: bool = false,
        layer_shell: bool = false,
        wayland: bool = false,
        desktop: []const u8 = "",
        pub fn quakeDropAvailable(_: Capabilities) bool {
            return false;
        }
    };

    pub fn detect(_: std.mem.Allocator) Capabilities {
        return .{};
    }
};

pub const ThemeOptions = struct {
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,
    background_hex: ?[]const u8 = null,
    foreground_hex: ?[]const u8 = null,
    cursor_hex: ?[]const u8 = null,
    padding_x: ?f64 = null,
    padding_y: ?f64 = null,
    inherit_ghostty: bool = false,
};
pub const Terminal = struct {
    pub fn open(_: std.mem.Allocator, _: ThemeOptions) !Terminal {
        return .{};
    }
    pub fn deinit(_: *Terminal) void {}
    pub fn applyTheme(_: *Terminal, _: ThemeOptions) void {}
};

pub const IpcCommand = enum { toggle, show, hide, quit };
pub const IpcHandler = struct {
    ctx: *anyopaque,
    on_command: *const fn (ctx: *anyopaque, command: IpcCommand) void,
};
pub const Ipc = struct {
    pub fn init(_: std.mem.Allocator, _: IpcHandler) !Ipc {
        return .{};
    }
    pub fn deinit(_: *Ipc) void {}
};

pub const HotkeyHandler = struct {
    ctx: *anyopaque,
    on_activated: *const fn (ctx: *anyopaque) void,
};
pub const Hotkey = struct {
    pub fn init(_: std.mem.Allocator, _: HotkeyHandler, _: []const u8) !Hotkey {
        return .{};
    }
    pub fn deinit(_: *Hotkey) void {}
};

pub const TrayHandler = struct {
    ctx: *anyopaque,
    on_activate: *const fn (ctx: *anyopaque) void,
    on_quit: *const fn (ctx: *anyopaque) void,
};
pub const Tray = struct {
    pub fn init(_: std.mem.Allocator, _: TrayHandler) !Tray {
        return .{};
    }
    pub fn deinit(_: *Tray) void {}
};

pub const NotifyKind = notify_darwin.Kind;
pub const Notifier = notify_darwin.Notifier;

/// Linux installs its panel-window action shortcuts via
/// `platform.keymap.install`. Darwin runs its own NSResponder-based
/// dispatcher in `src/terminal/view.zig` against the `actions` table
/// there, so this stub is intentionally a no-op — kept only so the
/// `platform.zig` comptime switch type-checks against the linux
/// surface.
pub const KeymapContext = struct {
    terminal: *Terminal,
    allocator: std.mem.Allocator,
    log_pane: *LogPane,
};
pub const keymap = struct {
    pub fn install(_: *Panel, _: *KeymapContext) void {}
};

/// Linux's log pane is a sibling GtkPaned column next to the VTE.
/// Darwin has its own `agent/log_view.zig` driven by NSResponder /
/// NSTextView, integrated into `terminal/view.zig`'s layout pass —
/// this stub exists only so the `platform.zig` comptime switch
/// type-checks against the linux surface. The darwin entry never
/// constructs `platform.LogPane`.
pub const LogPane = struct {
    pub fn init(_: std.mem.Allocator) !LogPane {
        return .{};
    }
    pub fn deinit(_: *LogPane) void {}
};

pub const WatcherHandler = struct {
    ctx: *anyopaque,
    on_changed: *const fn (ctx: *anyopaque) void,
};
pub const Watcher = struct {
    pub fn init(_: std.mem.Allocator, _: []const []const u8, _: WatcherHandler) !Watcher {
        return .{};
    }
    pub fn deinit(_: *Watcher) void {}
};

pub const AutoStartStatus = enum {
    not_registered,
    enabled,
    requires_approval,
    not_found,
    unknown,
    pub fn label(self: AutoStartStatus) []const u8 {
        return @tagName(self);
    }
};
pub const AutoStart = struct {
    pub fn register(_: std.mem.Allocator) !void {}
    pub fn unregister(_: std.mem.Allocator) !void {}
    pub fn status(_: std.mem.Allocator) !AutoStartStatus {
        return .not_registered;
    }
};

/// Linux's `ghostty_config` parses `~/.config/ghostty/config` directly
/// because the linux build doesn't link libghostty (VTE is the
/// terminal engine). Darwin gets the resolved config via
/// `ghostty_runtime.configString/configColor/...` against the running
/// libghostty surface, so this stub is unused. Kept here only so
/// `platform.zig`'s comptime switch type-checks.
pub const ghostty_config = struct {
    pub const Rgb = struct { r: u8, g: u8, b: u8 };
    pub const Appearance = enum { light, dark };
    pub const Colors = struct {
        background: ?Rgb = null,
        foreground: ?Rgb = null,
        cursor: ?Rgb = null,
        palette: [16]?Rgb = .{null} ** 16,
        font_family: ?[]const u8 = null,
        font_size: ?f64 = null,
        pub fn deinit(self: *Colors, _: std.mem.Allocator) void {
            self.* = .{};
        }
    };
    pub fn loadFromUserConfig(_: std.mem.Allocator) !?Colors {
        return null;
    }
    pub fn parseColor(_: []const u8) ?Rgb {
        return null;
    }
};
pub const GhosttyColors = ghostty_config.Colors;
