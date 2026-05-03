//! Argv parser for djinn.
//!
//! Flag table — adding a flag is one entry. Replaces a 70-line if/else
//! chain in main(). `--help` is auto-rendered from the table so help
//! text never drifts from actual flag handling.

const std = @import("std");
const loginitem = @import("system/loginitem.zig");

pub const Args = struct {
    keybinding_override: ?[]const u8 = null,
    provider_override: ?[]const u8 = null,
};

pub const ParseResult = enum { run, exit_ok, exit_err };

const Ctx = struct {
    args: *std.process.ArgIterator,
    parsed: *Args,
};

const Handler = *const fn (ctx: *Ctx) ParseResult;

const Flag = struct {
    name: []const u8,
    /// Right-hand portion of the help line, after the flag name. Empty
    /// for boolean / action flags. e.g. "<binding>" for --hotkey.
    arg_label: []const u8 = "",
    help: []const u8,
    handler: Handler,
};

const flags = [_]Flag{
    .{
        .name = "--hotkey",
        .arg_label = "<binding>",
        .help = "Toggle keybinding (default: ctrl+space)",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                ctx.parsed.keybinding_override = ctx.args.next();
                return .run;
            }
        }.h,
    },
    .{
        .name = "--provider",
        .arg_label = "<name>",
        .help = "Provider: claude/codex/aider/gemini/generic",
        .handler = struct {
            fn h(ctx: *Ctx) ParseResult {
                ctx.parsed.provider_override = ctx.args.next();
                return .run;
            }
        }.h,
    },
    .{
        .name = "--login-item-enable",
        .help = "Register Djinn.app to launch at login",
        .handler = struct {
            fn h(_: *Ctx) ParseResult {
                loginitem.register() catch |err| {
                    std.debug.print("error: register failed ({}). Bundle must be code-signed; run from Djinn.app.\n", .{err});
                    return .exit_err;
                };
                const s = loginitem.status() catch loginitem.Status.unknown;
                std.debug.print("login item: {s}\n", .{s.label()});
                return .exit_ok;
            }
        }.h,
    },
    .{
        .name = "--login-item-disable",
        .help = "Unregister from launch-at-login",
        .handler = struct {
            fn h(_: *Ctx) ParseResult {
                loginitem.unregister() catch |err| {
                    std.debug.print("error: unregister failed ({})\n", .{err});
                    return .exit_err;
                };
                std.debug.print("login item: not registered\n", .{});
                return .exit_ok;
            }
        }.h,
    },
    .{
        .name = "--login-item-status",
        .help = "Print current login-item status",
        .handler = struct {
            fn h(_: *Ctx) ParseResult {
                const s = loginitem.status() catch |err| {
                    std.debug.print("error: status query failed ({})\n", .{err});
                    return .exit_err;
                };
                std.debug.print("login item: {s}\n", .{s.label()});
                return .exit_ok;
            }
        }.h,
    },
    .{
        .name = "--version",
        .help = "Print version and exit",
        .handler = struct {
            fn h(_: *Ctx) ParseResult {
                // Mirrors Info.plist CFBundleShortVersionString. Bumped manually
                // on release; CI is not yet driving it.
                std.debug.print("djinn 0.1.0\n", .{});
                return .exit_ok;
            }
        }.h,
    },
    .{
        .name = "--help",
        .help = "Show this help",
        .handler = struct {
            fn h(_: *Ctx) ParseResult {
                printHelp();
                return .exit_ok;
            }
        }.h,
    },
};

pub fn parse(args_iter: *std.process.ArgIterator, parsed: *Args) ParseResult {
    var ctx = Ctx{ .args = args_iter, .parsed = parsed };
    while (args_iter.next()) |arg| {
        const flag = findFlag(arg) orelse continue;
        const r = flag.handler(&ctx);
        if (r != .run) return r;
    }
    return .run;
}

fn findFlag(name: []const u8) ?*const Flag {
    inline for (&flags) |*f| {
        if (std.mem.eql(u8, name, f.name)) return f;
    }
    return null;
}

fn printHelp() void {
    std.debug.print(
        \\djinn -- Quake-drop terminal + AI agent status surface
        \\
        \\Usage: djinn [options]
        \\
    , .{});
    const col = comptime helpCol();
    inline for (flags) |f| {
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
        const len = f.name.len + (if (f.arg_label.len > 0) f.arg_label.len + 1 else 0);
        if (len > max) max = len;
    }
    return max + 2;
}
