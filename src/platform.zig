//! Platform abstraction selector.
//!
//! Every host-side subsystem that has a per-OS implementation lives
//! under `src/platform/<os>/`. This file picks the right subtree at
//! comptime and re-exports it as a flat namespace so call sites read
//! `@import("../platform.zig").Panel` without caring whether the
//! darwin or linux module backs it.
//!
//! Why this exists:
//!   - The darwin path was the only path until 2026-05; every file
//!     historically imported `hotkey/darwin.zig`, `notify/darwin.zig`,
//!     `window/panel.zig` directly. That's fine while there's one
//!     target, but each new platform would multiply call-site edits.
//!   - The platform layer collects every "must differ per OS" surface
//!     in one place — Panel (window/Quake-drop), Hotkey (global
//!     binding), Menubar (tray icon), Notifier (system notifications),
//!     LoginItem (autostart), ConfigWatcher (FS notifications).
//!   - Pure-logic modules (config, theme, mcp, agent state, persist,
//!     session manager core) stay out of here — they have no platform
//!     dependency and never will.
//!
//! Compile-time gating: each branch only references its own subtree, so
//! the inactive branch's code isn't part of the build at all. The
//! darwin entry (`src/main.zig`) still imports `hotkey/darwin.zig` etc.
//! directly today; this file is initially consumed only by the linux
//! entry. Migrating darwin call sites onto `platform.zig` is a later,
//! mechanical refactor — we'll get there once the linux side is real.

const builtin = @import("builtin");

// Zig 0.15 removed `usingnamespace`. The replacement is explicit
// per-symbol re-export from the chosen impl. Keep the list short and
// only re-export what the rest of the codebase actually consumes —
// each addition is a deliberate widening of the platform contract.
const impl = switch (builtin.os.tag) {
    .macos => @import("platform/darwin.zig"),
    .linux => @import("platform/linux.zig"),
    else => @compileError("djinn supports macOS and Linux; got " ++ @tagName(builtin.os.tag)),
};

pub const Panel = impl.Panel;
pub const Terminal = impl.Terminal;
pub const ThemeOptions = impl.ThemeOptions;
pub const Ipc = impl.Ipc;
pub const IpcCommand = impl.IpcCommand;
pub const IpcHandler = impl.IpcHandler;
pub const Hotkey = impl.Hotkey;
pub const HotkeyHandler = impl.HotkeyHandler;
pub const Tray = impl.Tray;
pub const TrayHandler = impl.TrayHandler;
pub const Notifier = impl.Notifier;
pub const NotifyKind = impl.NotifyKind;
pub const Watcher = impl.Watcher;
pub const WatcherHandler = impl.WatcherHandler;
pub const AutoStart = impl.AutoStart;
pub const AutoStartStatus = impl.AutoStartStatus;
pub const ghostty_config = impl.ghostty_config;
pub const GhosttyColors = impl.GhosttyColors;
pub const keymap = impl.keymap;
pub const KeymapContext = impl.KeymapContext;
pub const LogPane = impl.LogPane;
