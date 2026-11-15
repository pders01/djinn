//! Compile-time native terminal services. OS-specific UI entry points import
//! their own aggregators; inactive platform code is never analyzed.
const builtin = @import("builtin");
pub const native = switch (builtin.os.tag) {
    .macos => @import("platform/darwin.zig"),
    .linux => @import("platform/linux.zig"),
    else => @compileError("djinn supports macOS and Linux; got " ++ @tagName(builtin.os.tag)),
};
pub const Notifier = native.Notifier;
