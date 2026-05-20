//! Linux platform aggregator.
//!
//! Re-exports the Linux subsystem modules under flat names so callers
//! in `main_linux.zig` reach them via `platform.zig` rather than
//! poking inside `src/platform/linux/*` directly.

pub const panel = @import("linux/panel.zig");
pub const Panel = panel.Panel;

pub const terminal = @import("linux/terminal.zig");
pub const Terminal = terminal.Terminal;
pub const TerminalHandler = terminal.Handler;
pub const TerminalSpawn = terminal.Spawn;
pub const ThemeOptions = terminal.ThemeOptions;

pub const session_host = @import("linux/session_host.zig");
pub const SessionHost = session_host.SessionHost;

pub const tab_strip = @import("linux/tab_strip.zig");
pub const TabStrip = tab_strip.TabStrip;
pub const TabStripOnActivate = tab_strip.OnActivate;

pub const palette = @import("linux/palette.zig");
pub const Palette = palette.Palette;
pub const PaletteOnActivate = palette.OnActivate;

pub const keymap = @import("linux/keymap.zig");
pub const KeymapContext = keymap.Context;

pub const log_pane = @import("linux/log_pane.zig");
pub const LogPane = log_pane.LogPane;

pub const find_overlay = @import("linux/find_overlay.zig");
pub const FindOverlay = find_overlay.FindOverlay;

pub const cheatsheet = @import("linux/cheatsheet.zig");
pub const Cheatsheet = cheatsheet.Cheatsheet;

pub const ghostty_config = @import("linux/ghostty_config.zig");
pub const GhosttyColors = ghostty_config.Colors;

pub const ipc = @import("linux/ipc.zig");
pub const Ipc = ipc.Ipc;
pub const IpcCommand = ipc.Command;
pub const IpcHandler = ipc.Handler;

pub const hotkey = @import("linux/hotkey.zig");
pub const Hotkey = hotkey.Hotkey;
pub const HotkeyHandler = hotkey.Handler;

pub const tray = @import("linux/tray.zig");
pub const Tray = tray.Tray;
pub const TrayHandler = tray.Handler;

pub const notifier = @import("linux/notifier.zig");
pub const Notifier = notifier.Notifier;
pub const NotifyKind = notifier.Kind;

pub const watcher = @import("linux/watcher.zig");
pub const Watcher = watcher.Watcher;
pub const WatcherHandler = watcher.Handler;

pub const autostart = @import("linux/autostart.zig");
pub const AutoStartStatus = autostart.Status;
pub const AutoStart = struct {
    pub const register = autostart.register;
    pub const unregister = autostart.unregister;
    pub const status = autostart.status;
};
