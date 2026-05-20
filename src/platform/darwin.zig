//! Darwin platform re-exports (cross-OS surface).
//!
//! Tiny by design — only the symbols `platform.zig` actually re-exports
//! land here. Today that's `Notifier`, which `mcp/tools.zig` reaches
//! through `platform.Notifier` so the linux MCP wiring can share a
//! ToolTable with the darwin path. The transitive `objc` import only
//! activates on darwin builds because `platform.zig` only switches to
//! this file when `builtin.os.tag == .macos`.
//!
//! Everything else the darwin entry (`src/main.zig`) needs comes from
//! direct imports (`hotkey/darwin.zig`, `notify/menubar.zig`,
//! `system/loginitem.zig`, …) — no abstraction layer in between. The
//! previous shape stubbed 12 unused symbols here so that
//! `platform.zig`'s comptime switch type-checked against the linux
//! surface; the stubs were never consumed and accumulated drift
//! against the real linux types (e.g. `ThemeOptions` `_hex` suffixes,
//! `KeymapContext` field-count mismatch). Reverted in favor of the
//! minimal surface that actually pays rent.

const notify_darwin = @import("../notify/darwin.zig");

pub const NotifyKind = notify_darwin.Kind;
pub const Notifier = notify_darwin.Notifier;
