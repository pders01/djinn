//! Native terminal services shared by cross-platform consumers. AppKit UI
//! and hotkey ownership remain in the established macOS entry point.
pub const Notifier = @import("../notify/darwin.zig").Notifier;
