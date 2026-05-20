//! Cross-OS platform surface.
//!
//! Narrow on purpose — only types/functions that are *consumed*
//! cross-OS land here. Today that's `Notifier` (used by `mcp/tools.zig`
//! to surface attention banners on both darwin and linux). Everything
//! else (Panel, Terminal, Hotkey, Tray, Watcher, AutoStart, LogPane,
//! KeymapContext, ghostty_config) is consumed only by one entry point
//! and lives in `platform/<os>/` — the linux entry imports
//! `platform/linux.zig` directly, the darwin entry uses its
//! historical direct imports (`hotkey/darwin.zig`, `notify/menubar.zig`,
//! …). The previous shape re-exported 14 symbols here even though 12
//! of them were used by exactly one entry point — pure abstraction tax
//! with no consumer benefit.
//!
//! Compile-time gating: each branch only references its own subtree,
//! so the inactive branch's code isn't part of the build at all.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/darwin.zig"),
    .linux => @import("platform/linux.zig"),
    else => @compileError("djinn supports macOS and Linux; got " ++ @tagName(builtin.os.tag)),
};

pub const Notifier = impl.Notifier;
pub const NotifyKind = impl.NotifyKind;
