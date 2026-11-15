//! Platform-independent terminal configuration, launch, and persistence tests.
//! No AppKit, GTK, VTE, desktop portal, or installed user configuration needed.
test {
    _ = @import("config.zig");
    _ = @import("session/manager.zig");
    _ = @import("state/persist.zig");
    _ = @import("io/platform.zig");
}
