//! Host-executed Linux policy/model/fixture tests. Build filters deliberately
//! exclude native API-body checks; test-compile checks those without linking.
//! Never opens a display, reads personal configuration, or registers autostart.
test {
    _ = @import("platform/linux/autostart.zig");
    _ = @import("platform/linux/dragdrop.zig");
    _ = @import("platform/linux/theme.zig");
    _ = @import("platform/linux/panel.zig");
    _ = @import("platform/linux/terminal.zig");
    _ = @import("platform/linux/session_host.zig");
    _ = @import("platform/linux/tray.zig");
}
