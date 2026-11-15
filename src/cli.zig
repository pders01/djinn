//! Argv parser for djinn.
//!
//! Flag table — adding a flag is one entry. Replaces a 70-line if/else
//! chain in main(). `--help` is auto-rendered from the table so help
//! text never drifts from actual flag handling.

const std = @import("std");
const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;
const loginitem = if (is_linux) @import("platform/linux/autostart.zig") else @import("system/loginitem.zig");
const Config = @import("config.zig").Config;
pub const WindowAction = enum { toggle, show, hide, quit };

const LoginAction = enum { enable, disable, status };

pub const Args = struct {
    keybinding_override: ?[]const u8 = null,
    diagnose_hotkey: bool = false,
    login_action: ?LoginAction = null,
    /// Linux's local terminal-window IPC; never an agent protocol.
    window_action: ?WindowAction = null,
};

pub const ParseResult = enum { run, exit_ok, exit_err };

const Ctx = struct {
    args: *std.process.Args.Iterator,
    parsed: *Args,
    info_action: ?enum { help, version } = null,
};

const Handler = *const fn (ctx: *Ctx) ParseResult;

const Flag = struct {
    name: []const u8,
    /// Right-hand portion of the help line, after the flag name. Empty
    /// for boolean / action flags. e.g. "<binding>" for --hotkey.
    arg_label: []const u8 = "",
    help: []const u8,
    handler: Handler,
    linux_only: bool = false,
    darwin_only: bool = false,
};

const flags = [_]Flag{
    .{
        .name = "--hotkey",
        .arg_label = "<binding>",
        .help = "Toggle keybinding (default: ctrl+shift+space)",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                const binding = ctx.args.next() orelse {
                    std.debug.print("error: --hotkey requires a binding, for example --hotkey ctrl+shift+space\n", .{});
                    return .exit_err;
                };
                if (std.mem.startsWith(u8, binding, "--")) {
                    std.debug.print("error: --hotkey requires a binding, not '{s}'\n", .{binding});
                    return .exit_err;
                }
                ctx.parsed.keybinding_override = binding;
                return .run;
            }
        }.h,
    },
    .{
        .name = "--diagnose-hotkey",
        .darwin_only = true,
        .help = "Probe native registration (--hotkey or built-in default), then exit",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                ctx.parsed.diagnose_hotkey = true;
                return .run;
            }
        }.h,
    },
    .{
        .name = "--login-item-enable",
        .help = if (is_linux) "Enable XDG launch-at-login" else "Register Djinn.app to launch at login",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                return setLoginAction(ctx, .enable);
            }
        }.h,
    },
    .{
        .name = "--login-item-disable",
        .help = "Unregister from launch-at-login",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                return setLoginAction(ctx, .disable);
            }
        }.h,
    },
    .{
        .name = "--login-item-status",
        .help = "Print current login-item status",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                return setLoginAction(ctx, .status);
            }
        }.h,
    },
    .{ .name = "--toggle", .linux_only = true, .help = "Toggle the running terminal", .handler = windowHandler(.toggle) },
    .{ .name = "--show", .linux_only = true, .help = "Show the running terminal", .handler = windowHandler(.show) },
    .{ .name = "--hide", .linux_only = true, .help = "Hide the running terminal", .handler = windowHandler(.hide) },
    .{ .name = "--quit", .linux_only = true, .help = "Quit the running terminal", .handler = windowHandler(.quit) },
    .{
        .name = "--version",
        .help = "Print version and exit",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                ctx.info_action = .version;
                return .run;
            }
        }.h,
    },
    .{
        .name = "--help",
        .help = "Show this help",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                ctx.info_action = .help;
                return .run;
            }
        }.h,
    },
};

fn setLoginAction(ctx: *Ctx, action: LoginAction) ParseResult {
    if (ctx.parsed.login_action != null) {
        std.debug.print("error: choose only one login-item action\n", .{});
        return .exit_err;
    }
    ctx.parsed.login_action = action;
    return .run;
}

fn windowHandler(comptime action: WindowAction) Handler {
    return struct {
        fn h(ctx: *Ctx) ParseResult {
            if (ctx.parsed.window_action != null) {
                std.debug.print("error: choose only one window action\n", .{});
                return .exit_err;
            }
            ctx.parsed.window_action = action;
            return .run;
        }
    }.h;
}

fn available(flag: Flag) bool {
    return (!flag.linux_only or is_linux) and (!flag.darwin_only or builtin.os.tag == .macos);
}

fn validateActions(parsed: Args) !void {
    if (parsed.diagnose_hotkey and parsed.login_action != null)
        return error.IncompatibleActions;
    if (parsed.window_action != null and (parsed.login_action != null or parsed.diagnose_hotkey or parsed.keybinding_override != null))
        return error.IncompatibleActions;
}

fn runLoginAction(action: LoginAction) ParseResult {
    const allocator = std.heap.page_allocator;
    // This executes before normal app initialization. Never use a permissive
    // parse or swallow read failures: an unread policy must not authorize OS
    // changes. Only a genuinely missing file selects the absent default.
    var config = Config.loadOrDefault(allocator) catch |err| {
        std.debug.print("error: cannot read launch-at-login config policy ({}); no OS changes made\n", .{err});
        if (action == .status) {
            const actual = queryLoginStatus(allocator) catch loginitem.Status.unknown;
            std.debug.print("login item OS state: {s}\nconfig policy: unknown (config could not be loaded)\n", .{actual.label()});
        }
        return .exit_err;
    };
    defer config.deinit();
    loginitem.setPolicy(config.system.open_at_login);
    if (actionRequest(action)) |requested| {
        loginitem.checkRequest(requested) catch {
            std.debug.print("error: launch-at-login policy conflict: open-at-login = {s}; no OS/config changes made\n", .{if (loginitem.policy().?) "true" else "false"});
            _ = printLoginStatus(allocator);
            return .exit_err;
        };
        if (comptime is_linux) {
            if (requested) loginitem.register(allocator) catch |err| {
                std.debug.print("error: autostart register failed ({})\n", .{err});
                return .exit_err;
            } else loginitem.unregister(allocator) catch |err| {
                std.debug.print("error: autostart unregister failed ({})\n", .{err});
                return .exit_err;
            };
        } else {
            if (requested) loginitem.register() catch |err| {
                std.debug.print("error: register failed ({}). Run from a signed Djinn.app bundle.\n", .{err});
                return .exit_err;
            } else loginitem.unregister() catch |err| {
                std.debug.print("error: unregister failed ({})\n", .{err});
                return .exit_err;
            };
        }
    }
    return printLoginStatus(allocator);
}

fn actionRequest(action: LoginAction) ?bool {
    return switch (action) {
        .enable => true,
        .disable => false,
        .status => null,
    };
}

fn queryLoginStatus(allocator: std.mem.Allocator) !loginitem.Status {
    return if (comptime is_linux) loginitem.status(allocator) else loginitem.status();
}

fn printLoginStatus(allocator: std.mem.Allocator) ParseResult {
    const actual = queryLoginStatus(allocator) catch |err| {
        std.debug.print("login item OS state: unknown (query failed: {})\n", .{err});
        printLoginPolicy(.unknown);
        return .exit_err;
    };
    std.debug.print("login item OS state: {s}\n", .{actual.label()});
    printLoginPolicy(actual);
    return if (actual == .unknown) .exit_err else .exit_ok;
}

fn printLoginPolicy(actual: loginitem.Status) void {
    if (loginitem.policy()) |required| {
        std.debug.print("config policy: open-at-login = {s}{s}\n", .{
            if (required) "true" else "false",
            if (loginitem.policyConflict(actual)) " (OS state does not satisfy policy; approval may be required or state unknown)" else " (matches OS state)",
        });
    } else {
        std.debug.print("config policy: absent (OS state is user-controlled)\n", .{});
    }
}

pub fn parse(args_iter: *std.process.Args.Iterator, parsed: *Args) ParseResult {
    const result = parseFlags(args_iter, parsed);
    if (result != .run) return result;
    if (parsed.login_action) |action| return runLoginAction(action);
    return .run;
}

/// Pure argument validation: login registration is deliberately outside this
/// function so tests and all error/help paths cannot change system state.
fn parseFlags(args_iter: *std.process.Args.Iterator, parsed: *Args) ParseResult {
    var ctx = Ctx{ .args = args_iter, .parsed = parsed };
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--provider") or std.mem.startsWith(u8, arg, "--provider=")) {
            std.debug.print("error: --provider was removed; set profile.<name>.command in ~/.config/djinn/config, or omit it for your default shell\n", .{});
            return .exit_err;
        }
        const flag = findFlag(arg) orelse {
            std.debug.print("error: unknown argument '{s}'; use --help for supported options\n", .{arg});
            return .exit_err;
        };
        const r = flag.handler(&ctx);
        if (r != .run) return r;
    }
    // Defer side effects until every argument has been validated.
    validateActions(parsed.*) catch {
        std.debug.print("error: incompatible diagnostic, login-item or window actions\n", .{});
        return .exit_err;
    };
    if (ctx.info_action) |action| {
        switch (action) {
            .help => printHelp(),
            .version => std.debug.print("djinn {s}\n", .{@import("version.zig").string}),
        }
        return .exit_ok;
    }
    return .run;
}

fn findFlag(name: []const u8) ?*const Flag {
    inline for (&flags) |*f| {
        if (available(f.*) and std.mem.eql(u8, name, f.name)) return f;
    }
    return null;
}

fn printHelp() void {
    std.debug.print(
        \\djinn -- Quake-drop terminal
        \\
        \\Usage: djinn [options]
        \\
    , .{});
    const col = comptime helpCol();
    inline for (flags) |f| {
        if (comptime !available(f)) continue;
        const lhs_len = f.name.len + (if (f.arg_label.len > 0) f.arg_label.len + 1 else 0);
        if (f.arg_label.len > 0) {
            std.debug.print("  {s} {s}", .{ f.name, f.arg_label });
        } else {
            std.debug.print("  {s}", .{f.name});
        }
        const pad = if (lhs_len < col) col - lhs_len else 1;
        for (0..pad) |_| std.debug.print(" ", .{});
        std.debug.print("{s}\n", .{f.help});
    }
    std.debug.print(
        \\
        \\Config: ~/.config/djinn/config (ghostty key=value format)
        \\
    , .{});
}

fn helpCol() usize {
    var max: usize = 0;
    for (flags) |f| {
        if (!available(f)) continue;
        const len = f.name.len + (if (f.arg_label.len > 0) f.arg_label.len + 1 else 0);
        if (len > max) max = len;
    }
    return max + 2;
}

test "CLI: login API compiles without running loader or OS actions" {
    std.testing.refAllDecls(@This());
}

test "CLI: strict in-memory config distinguishes absent and explicit login policy" {
    for ([_]struct { text: []const u8, expected: ?bool }{
        .{ .text = "", .expected = null },
        .{ .text = "open-at-login = true\n", .expected = true },
        .{ .text = "open-at-login = false\n", .expected = false },
    }) |fixture| {
        var config = try Config.parseStrict(std.testing.allocator, fixture.text);
        defer config.deinit();
        try std.testing.expectEqual(fixture.expected, config.system.open_at_login);
    }
    try std.testing.expectError(error.NotABool, Config.parseStrict(std.testing.allocator, "open-at-login = invalid\n"));
}

test "CLI: login actions honor injected policy without config IO or OS calls" {
    defer loginitem.setPolicy(null);
    try std.testing.expectEqual(@as(?bool, null), actionRequest(.status));
    for ([_]?bool{ null, true, false }) |policy| {
        loginitem.setPolicy(policy);
        inline for (.{ LoginAction.enable, LoginAction.disable }) |action| {
            const requested = actionRequest(action).?;
            if (policy != null and policy.? != requested) {
                try std.testing.expectError(error.PolicyConflict, loginitem.checkRequest(requested));
            } else try loginitem.checkRequest(requested);
        }
    }
}

test "CLI: useful flags remain, provider flag is removed" {
    try std.testing.expect(findFlag("--provider") == null);
    const retained = [_][]const u8{
        "--hotkey",             "--help",              "--version", "--login-item-enable",
        "--login-item-disable", "--login-item-status",
    };
    for (retained) |name| try std.testing.expect(findFlag(name) != null);
    try std.testing.expectEqual(builtin.os.tag == .macos, findFlag("--diagnose-hotkey") != null);
    inline for (.{ "--toggle", "--show", "--hide", "--quit" }) |name|
        try std.testing.expectEqual(is_linux, findFlag(name) != null);
}

test "CLI: window actions cannot cause login side effects or launch with hotkey overrides" {
    try validateActions(.{ .window_action = .toggle });
    try std.testing.expectError(error.IncompatibleActions, validateActions(.{ .window_action = .show, .login_action = .enable }));
    try std.testing.expectError(error.IncompatibleActions, validateActions(.{ .window_action = .quit, .keybinding_override = "ctrl+x" }));
}

test "CLI: full argv is validated before login actions or informational exit" {
    const cases = [_][]const [*:0]const u8{
        &.{ "--login-item-enable", "--unknown" },
        &.{ "--login-item-disable", "--hotkey" },
        &.{ "--login-item-status", "--login-item-enable" },
        &.{ "--help", "--unknown" },
        &.{ "--version", "--provider=removed" },
        &.{ "--hotkey", "--help" },
    };
    for (cases) |argv| {
        var iter = std.process.Args.Iterator.init(.{ .vector = argv });
        var parsed = Args{};
        try std.testing.expectEqual(ParseResult.exit_err, parseFlags(&iter, &parsed));
    }
}

test "CLI: Linux window actions validate the whole argv without side effects" {
    if (!is_linux) return;
    const cases = [_][]const [*:0]const u8{
        &.{ "--show", "--hide" },
        &.{ "--show", "--login-item-enable" },
        &.{ "--quit", "--unknown" },
        &.{ "--toggle", "--hotkey", "ctrl+x" },
    };
    for (cases) |argv| {
        var iter = std.process.Args.Iterator.init(.{ .vector = argv });
        var parsed = Args{};
        try std.testing.expectEqual(ParseResult.exit_err, parseFlags(&iter, &parsed));
    }
    var iter = std.process.Args.Iterator.init(.{ .vector = &.{"--toggle"} });
    var parsed = Args{};
    try std.testing.expectEqual(ParseResult.run, parseFlags(&iter, &parsed));
    try std.testing.expectEqual(@as(?WindowAction, .toggle), parsed.window_action);
}

test "CLI: diagnostics reject all login actions before side effects" {
    try validateActions(.{ .diagnose_hotkey = true });
    try validateActions(.{ .login_action = .status });
    inline for (.{ LoginAction.enable, LoginAction.disable, LoginAction.status }) |action| {
        try std.testing.expectError(error.IncompatibleActions, validateActions(.{ .diagnose_hotkey = true, .login_action = action }));
    }
}
