//! Platform-independent terminal configuration, launch, and persistence tests.
//! No AppKit, GTK, VTE, desktop portal, or installed user configuration needed.
test {
    _ = @import("config.zig");
    _ = @import("session/manager.zig");
    _ = @import("state/persist.zig");
    _ = @import("io/platform.zig");
    // Backend policy/model fixtures have their own filtered host suite:
    // test-linux-models excludes API-body checks that require native linkage.
}
