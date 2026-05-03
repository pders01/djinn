const std = @import("std");

pub const Config = struct {
    window: WindowConfig = .{},
    terminal: TerminalConfig = .{},
    theme: ThemeConfig = .{},
    hotkey: HotkeyConfig = .{},
    provider: ProviderConfig = .{},
    mcp: McpConfig = .{},
    notifications: NotifyConfig = .{},
    scrollback: ScrollbackConfig = .{},
    log_pane: LogPaneConfig = .{},
    system: SystemConfig = .{},
    bell: BellConfig = .{},
    keymap: KeymapConfig = .{},
    profiles: ProfilesConfig = .{},

    pub const WindowConfig = struct {
        /// Optional so the runtime can tell "user set this explicitly"
        /// from "fall through to state.json or default". Set in
        /// applyKey when the user writes `window-width = N`. When null,
        /// `restoreWindowSize` uses state.json (if present) else the
        /// hardcoded default.
        width: ?u32 = null,
        height: ?u32 = null,
        position: Position = .top_center,
        // Legacy: kept for backward compat. Prefer `theme.opacity`.
        opacity: f64 = 0.95,
        // Legacy: kept for backward compat. Prefer `terminal.font_size`.
        font_size: f64 = 14.0,
        toggle_style: ToggleStyle = .instant,
        topmost: bool = true,
        /// When true, the panel auto-hides as soon as it loses key status —
        /// e.g. user invokes Raycast/Spotlight. Off by default because users
        /// who toggle frequently typically want the popup to stay put.
        hide_on_blur: bool = false,

        pub const Position = enum { top_center, top_left, top_right, center };
        pub const ToggleStyle = enum { instant, minimize };
    };

    pub const TerminalConfig = struct {
        font_family: ?[]const u8 = null,
        font_size: ?f64 = null,
        padding_x: ?f64 = null,
        padding_y: ?f64 = null,
    };

    pub const ThemeConfig = struct {
        /// Read `~/.config/ghostty/config` and resolve the named theme file
        /// from standard ghostty theme search paths. djinn-config fields
        /// below override ghostty values.
        inherit_ghostty: bool = true,
        opacity: ?f64 = null,
        background: ?[]const u8 = null,
        foreground: ?[]const u8 = null,
        cursor: ?[]const u8 = null,
    };

    pub const HotkeyConfig = struct {
        toggle: []const u8 = "ctrl+space",
    };

    pub const ProviderConfig = struct {
        name: []const u8 = "generic",
        command: ?[]const u8 = null,
        args: []const []const u8 = &.{},
    };

    /// One named profile = one provider instance. The session layer
    /// (`src/session/manager.zig`) consumes these and binds each to a
    /// ghostty surface; UI layers (keybind switcher today, tab strip
    /// or palette later) sit above the session manager and don't see
    /// this struct directly.
    pub const ProfileEntry = struct {
        name: []const u8,
        provider: ?[]const u8 = null,
        command: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        title: ?[]const u8 = null,
    };

    pub const ProfilesConfig = struct {
        /// Name of the profile that's active at startup. Falls back to
        /// the first parsed profile if unset; falls back to a synthesized
        /// "default" profile (built from flat `provider` / `provider-
        /// command`) if no profile lines were configured.
        default: ?[]const u8 = null,
        entries: []const ProfileEntry = &.{},
    };

    pub const McpConfig = struct {
        enabled: bool = true,
        socket_path: ?[]const u8 = null,
    };

    pub const ScrollbackConfig = struct {
        /// Rows of scrollback retained beyond the visible grid. Matches
        /// ghostty's default. Bumping helps when CC streams thousands of
        /// log lines; cost is roughly `size * cols * sizeof(cell)` of
        /// resident memory in the ghostty page list.
        size: u32 = 10000,
    };

    pub const LogPaneConfig = struct {
        /// Hidden by default — most users only want the log surface
        /// on demand (debugging an MCP client, watching agent state).
        /// Toggle via Cmd+/ (`toggle_log_pane` action). When false at
        /// startup, the log view is still built so toggling is just a
        /// frame change; MCP `djinn_log` calls always update state.
        enabled: bool = false,
        /// Fraction of total panel width allocated to the log column.
        /// Clamped against `width_min` and `width_max` so tiny + huge
        /// panels still get a legible / non-crowding pane.
        width_fraction: f64 = 0.28,
        width_min: f64 = 220,
        width_max: f64 = 360,
    };

    pub const SystemConfig = struct {
        /// When true, djinn ensures launch-at-login is registered on
        /// every startup (idempotent — SMAppService.register is safe
        /// to call repeatedly). When false, it unregisters if currently
        /// enabled. Reading the same value back out is what `--login
        /// -item-status` already does. No-op if the binary isn't
        /// running from a signed `.app` bundle.
        open_at_login: bool = false,
    };

    pub const BellConfig = struct {
        /// Play a sound on BEL (0x07). Same playback path as
        /// notifications.attention_sound — afplay subprocess against a
        /// /System/Library/Sounds/<name>.aiff or absolute path.
        audible: bool = true,
        /// Flash the terminal background briefly on BEL — like ghostty's
        /// "audible-bell off" + "visual-bell on" behavior. Useful when
        /// audible is off (headphones unplugged, focus mode) but still
        /// want a visual cue.
        visual: bool = false,
        /// Sound to play for audible bell. Defaults to "Tink" — short,
        /// non-intrusive system sound. Set to null/"" to silence even
        /// when audible = true (effectively the same as audible = false).
        sound: ?[]const u8 = "Tink",
    };

    pub const KeymapEntry = struct {
        name: []const u8,
        binding: []const u8,
    };

    pub const KeymapConfig = struct {
        /// Action-name → binding pairs from user config. Each entry
        /// overrides the default binding for that action at startup.
        /// Action names match Action.name in view.zig (copy, paste,
        /// scroll_page_up, scroll_page_down, font_inc, font_dec,
        /// font_reset, clear_scrollback, open_settings,
        /// toggle_log_pane, palette_open, tab_1..tab_9, next_tab,
        /// prev_tab, etc.).
        /// Bindings parse via hotkey.parseKeybinding ("cmd+k", etc.).
        entries: []const KeymapEntry = &.{},
    };

    pub const NotifyConfig = struct {
        system_notifications: bool = true,
        menubar_icon: bool = true,
        /// Sound played when djinn_attention fires. null/"" = silent.
        /// "default" = Funk (system default). Absolute path = play that
        /// file via afplay. Anything else = /System/Library/Sounds/<n>.aiff.
        /// Defaults to "Glass" so the surface ships audibly out of the box;
        /// users can opt out by setting null.
        attention_sound: ?[]const u8 = "Glass",
    };

    /// Load config from ~/.config/djinn/config (ghostty key=value format),
    /// falling back to defaults.
    /// Read + parse the config file. Errors propagate so callers can
    /// distinguish "no config, use defaults" from "transient read
    /// failure, keep the previous config." Atomic-write editors (vim,
    /// VS Code, Helix) save by renaming a tmp file over the target;
    /// FSEvents fires during the gap and an open here hits ENOENT.
    /// Swallowing that as a default `Config{}` (the previous behavior)
    /// silently clobbered every user setting on every save.
    pub fn load(allocator: std.mem.Allocator) !Config {
        const path = try defaultConfigPath(allocator);
        defer allocator.free(path);

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(contents);

        return parse(allocator, contents);
    }

    /// First-launch convenience: load the config or fall back to
    /// hardcoded defaults when the file is missing entirely. Anything
    /// other than `FileNotFound` propagates so startup fails loud
    /// instead of running with mystery defaults.
    pub fn loadOrDefault(allocator: std.mem.Allocator) !Config {
        return load(allocator) catch |err| switch (err) {
            error.FileNotFound => Config{},
            else => err,
        };
    }

    /// Parse config in ghostty's `key = value` format. Comments start with
    /// `#` at column 0 (inline `#` is reserved for hex colors). Unknown
    /// keys log a warning and continue. String values are duped with the
    /// allocator; lifetime is the parsed Config's lifetime.
    pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Config {
        var config = Config{};
        var keymap_list = std.ArrayList(KeymapEntry){};
        defer keymap_list.deinit(allocator);
        var profile_list = std.ArrayList(ProfileEntry){};
        defer profile_list.deinit(allocator);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: u32 = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
            if (line.len == 0) continue;

            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse {
                std.debug.print("warning: config:{d}: missing '=' in '{s}'\n", .{ line_no, line });
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const val = unquote(std.mem.trim(u8, line[eq_idx + 1 ..], " \t"));

            applyKey(&config, &keymap_list, &profile_list, allocator, key, val) catch |err| {
                std.debug.print("warning: config:{d}: '{s}' = '{s}' ({})\n", .{ line_no, key, val, err });
            };
        }

        // toOwnedSlice can OOM. On failure, free the per-item duped
        // strings so we don't leak them when we drop to an empty slice.
        // The list itself is `defer .deinit`'d; this loop just covers
        // the strings each entry holds.
        config.keymap.entries = keymap_list.toOwnedSlice(allocator) catch blk: {
            for (keymap_list.items) |e| {
                allocator.free(e.name);
                allocator.free(e.binding);
            }
            break :blk &.{};
        };
        config.profiles.entries = profile_list.toOwnedSlice(allocator) catch blk: {
            for (profile_list.items) |e| {
                allocator.free(e.name);
                if (e.provider) |s| allocator.free(s);
                if (e.command) |s| allocator.free(s);
                if (e.cwd) |s| allocator.free(s);
                if (e.title) |s| allocator.free(s);
            }
            break :blk &.{};
        };
        return config;
    }

    fn applyKey(
        config: *Config,
        keymap_list: *std.ArrayList(KeymapEntry),
        profile_list: *std.ArrayList(ProfileEntry),
        allocator: std.mem.Allocator,
        key: []const u8,
        val: []const u8,
    ) !void {
        // Profiles --------------------------------------------------------
        // `default-profile = name` selects which profile is active at
        // startup. `profile.<name>.<field> = value` defines per-profile
        // overrides. Both come BEFORE the flat-key fallthrough so the
        // dotted path wins over any later collision.
        if (eq(key, "default-profile")) {
            config.profiles.default = try allocator.dupe(u8, val);
            return;
        }
        if (std.mem.startsWith(u8, key, "profile.")) {
            try applyProfileKey(profile_list, allocator, key["profile.".len..], val);
            return;
        }

        // Window ----------------------------------------------------------
        if (eq(key, "window-width")) {
            config.window.width = try std.fmt.parseInt(u32, val, 10);
        } else if (eq(key, "window-height")) {
            config.window.height = try std.fmt.parseInt(u32, val, 10);
        } else if (eq(key, "window-position")) {
            config.window.position = std.meta.stringToEnum(WindowConfig.Position, dashToUnder(val)) orelse return error.UnknownEnum;
        } else if (eq(key, "window-toggle-style")) {
            config.window.toggle_style = std.meta.stringToEnum(WindowConfig.ToggleStyle, dashToUnder(val)) orelse return error.UnknownEnum;
        } else if (eq(key, "window-topmost")) {
            config.window.topmost = try parseBool(val);
        } else if (eq(key, "hide-on-blur")) {
            config.window.hide_on_blur = try parseBool(val);
        } else if (eq(key, "window-opacity")) {
            // Legacy. Prefer `opacity` (theme-level). Kept for back-compat.
            config.window.opacity = try std.fmt.parseFloat(f64, val);
        } else if (eq(key, "window-font-size")) {
            // Legacy. Prefer `font-size`.
            config.window.font_size = try std.fmt.parseFloat(f64, val);
        }
        // Hotkey ----------------------------------------------------------
        else if (eq(key, "hotkey")) {
            config.hotkey.toggle = try allocator.dupe(u8, val);
        }
        // Provider --------------------------------------------------------
        else if (eq(key, "provider")) {
            config.provider.name = try allocator.dupe(u8, val);
        } else if (eq(key, "provider-command")) {
            config.provider.command = try allocator.dupe(u8, val);
        }
        // MCP -------------------------------------------------------------
        else if (eq(key, "mcp-enabled")) {
            config.mcp.enabled = try parseBool(val);
        } else if (eq(key, "mcp-socket-path")) {
            config.mcp.socket_path = try allocator.dupe(u8, val);
        }
        // Notifications ---------------------------------------------------
        else if (eq(key, "system-notifications")) {
            config.notifications.system_notifications = try parseBool(val);
        } else if (eq(key, "menubar-icon")) {
            config.notifications.menubar_icon = try parseBool(val);
        } else if (eq(key, "attention-sound")) {
            config.notifications.attention_sound = try allocator.dupe(u8, val);
        }
        // Terminal --------------------------------------------------------
        else if (eq(key, "font-family")) {
            config.terminal.font_family = try allocator.dupe(u8, val);
        } else if (eq(key, "font-size")) {
            config.terminal.font_size = try std.fmt.parseFloat(f64, val);
        } else if (eq(key, "padding-x")) {
            config.terminal.padding_x = try std.fmt.parseFloat(f64, val);
        } else if (eq(key, "padding-y")) {
            config.terminal.padding_y = try std.fmt.parseFloat(f64, val);
        }
        // Scrollback ------------------------------------------------------
        else if (eq(key, "scrollback-size")) {
            config.scrollback.size = try std.fmt.parseInt(u32, val, 10);
        }
        // Log pane --------------------------------------------------------
        else if (eq(key, "log-pane-enabled")) {
            config.log_pane.enabled = try parseBool(val);
        } else if (eq(key, "log-pane-width-fraction")) {
            config.log_pane.width_fraction = try std.fmt.parseFloat(f64, val);
        } else if (eq(key, "log-pane-width-min")) {
            config.log_pane.width_min = try std.fmt.parseFloat(f64, val);
        } else if (eq(key, "log-pane-width-max")) {
            config.log_pane.width_max = try std.fmt.parseFloat(f64, val);
        }
        // System ----------------------------------------------------------
        else if (eq(key, "open-at-login")) {
            config.system.open_at_login = try parseBool(val);
        }
        // Bell ------------------------------------------------------------
        else if (eq(key, "bell-audible")) {
            config.bell.audible = try parseBool(val);
        } else if (eq(key, "bell-visual")) {
            config.bell.visual = try parseBool(val);
        } else if (eq(key, "bell-sound")) {
            config.bell.sound = try allocator.dupe(u8, val);
        }
        // Theme -----------------------------------------------------------
        else if (eq(key, "inherit-ghostty")) {
            config.theme.inherit_ghostty = try parseBool(val);
        } else if (eq(key, "opacity")) {
            config.theme.opacity = try std.fmt.parseFloat(f64, val);
        } else if (eq(key, "background")) {
            config.theme.background = try allocator.dupe(u8, val);
        } else if (eq(key, "foreground")) {
            config.theme.foreground = try allocator.dupe(u8, val);
        } else if (eq(key, "cursor-color")) {
            config.theme.cursor = try allocator.dupe(u8, val);
        }
        // Keybinds — `keybind = action=trigger` (ghostty syntax) ---------
        else if (eq(key, "keybind")) {
            const sub_eq = std.mem.indexOfScalar(u8, val, '=') orelse return error.MalformedKeybind;
            const action = std.mem.trim(u8, val[0..sub_eq], " \t");
            const trigger = std.mem.trim(u8, val[sub_eq + 1 ..], " \t");
            try keymap_list.append(allocator, .{
                .name = try allocator.dupe(u8, action),
                .binding = try allocator.dupe(u8, trigger),
            });
        } else {
            std.debug.print("warning: config: unknown key '{s}'\n", .{key});
        }
    }

    /// Parse a `profile.<name>.<field>` line. The leading `profile.` has
    /// already been stripped; `tail` is `<name>.<field>`. Mutates the
    /// profile list in place — appends a new entry the first time we see
    /// a name, then writes the field on subsequent lines for that name.
    fn applyProfileKey(
        profile_list: *std.ArrayList(ProfileEntry),
        allocator: std.mem.Allocator,
        tail: []const u8,
        val: []const u8,
    ) !void {
        const dot = std.mem.indexOfScalar(u8, tail, '.') orelse return error.MalformedProfileKey;
        const name = tail[0..dot];
        const field = tail[dot + 1 ..];
        if (name.len == 0 or field.len == 0) return error.MalformedProfileKey;

        // Find or insert the named entry.
        var idx: ?usize = null;
        for (profile_list.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) {
                idx = i;
                break;
            }
        }
        if (idx == null) {
            try profile_list.append(allocator, .{ .name = try allocator.dupe(u8, name) });
            idx = profile_list.items.len - 1;
        }

        const entry = &profile_list.items[idx.?];
        const dup = try allocator.dupe(u8, val);
        if (eq(field, "provider")) {
            entry.provider = dup;
        } else if (eq(field, "command")) {
            entry.command = dup;
        } else if (eq(field, "cwd")) {
            entry.cwd = dup;
        } else if (eq(field, "title")) {
            entry.title = dup;
        } else {
            allocator.free(dup);
            return error.UnknownProfileField;
        }
    }

    /// Get the effective command to spawn for the configured provider.
    pub fn getProviderCommand(self: *const Config) []const u8 {
        if (self.provider.command) |cmd| return cmd;

        // Default commands per provider name. Each shortcut maps to the
        // exact CLI binary name shipped by that project; anything else
        // falls through to /bin/zsh. Match is case-insensitive so
        // `provider = Claude` resolves to `claude`, matching user
        // intuition (config keys themselves are lowercase + hyphenated
        // but provider VALUES are user-typed names).
        const map = .{
            .{ "claude", "claude" },
            .{ "codex", "codex" },
            .{ "aider", "aider" },
            .{ "gemini", "gemini" },
            .{ "opencode", "opencode" },
            .{ "crush", "crush" }, // charmbracelet/crush
            .{ "pi", "pi" }, // Pi AI CLI
        };
        inline for (map) |entry| {
            if (eqIgnoreCase(self.provider.name, entry[0])) return entry[1];
        }

        // Generic: prefer macOS system zsh over $SHELL.
        // $SHELL inherited from `nix develop` (or other dev shells) often
        // points at /nix/store/.../bash with broken terminfo lookup, which
        // breaks readline arrow keys / Ctrl-bindings in the spawned PTY.
        // /bin/zsh has been macOS's default since 10.15 and ships with
        // working ncurses — use it unconditionally.
        return "/bin/zsh";
    }

    pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/.config/djinn/config", .{home});
    }
};

// Parse helpers ---------------------------------------------------------

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn parseBool(val: []const u8) !bool {
    if (eq(val, "true") or eq(val, "yes") or eq(val, "on") or eq(val, "1")) return true;
    if (eq(val, "false") or eq(val, "no") or eq(val, "off") or eq(val, "0")) return false;
    return error.NotABool;
}

/// Strip line comments. `#` at column 0 (after whitespace trim) is a
/// comment. Inline `#` is reserved for hex colors. Matches ghostty's
/// own config grammar — see memory note `djinn_ghostty_config_parsing.md`.
fn stripComment(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '#') return "";
    return s;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// Convert dashed value to underscored so std.meta.stringToEnum hits.
/// Operates on a small static buffer; OK because enum names are short.
fn dashToUnder(s: []const u8) []const u8 {
    const Buf = struct {
        var b: [64]u8 = undefined;
    };
    if (s.len > Buf.b.len) return s;
    for (s, 0..) |c, i| Buf.b[i] = if (c == '-') '_' else c;
    return Buf.b[0..s.len];
}

// Tests
test "Config: parse defaults from empty input" {
    const config = try Config.parse(std.testing.allocator, "");
    try std.testing.expect(config.window.width == null);
    try std.testing.expect(config.window.height == null);
    try std.testing.expectEqualStrings("ctrl+space", config.hotkey.toggle);
    try std.testing.expectEqualStrings("generic", config.provider.name);
}

test "Config: parse window settings" {
    const src =
        \\window-width = 1024
        \\window-height = 600
        \\window-opacity = 0.9
        \\window-font-size = 16
    ;
    const config = try Config.parse(std.testing.allocator, src);
    try std.testing.expectEqual(@as(u32, 1024), config.window.width.?);
    try std.testing.expectEqual(@as(u32, 600), config.window.height.?);
    try std.testing.expect(config.window.opacity < 0.91 and config.window.opacity > 0.89);
}

test "Config: parse provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\provider = claude
        \\provider-command = /usr/local/bin/claude
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("claude", config.provider.name);
    try std.testing.expectEqualStrings("/usr/local/bin/claude", config.provider.command.?);
}

test "Config: parse hotkey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try Config.parse(arena.allocator(), "hotkey = cmd+grave\n");
    try std.testing.expectEqualStrings("cmd+grave", config.hotkey.toggle);
}

test "Config: comments + blank lines + unknown keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# comment
        \\
        \\hotkey = ctrl+space
        \\unknown-key = whatever
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("ctrl+space", config.hotkey.toggle);
}

test "Config: keybind syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\keybind = clear_scrollback=cmd+l
        \\keybind = copy=cmd+c
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), config.keymap.entries.len);
    try std.testing.expectEqualStrings("clear_scrollback", config.keymap.entries[0].name);
    try std.testing.expectEqualStrings("cmd+l", config.keymap.entries[0].binding);
}

test "Config: getProviderCommand default mapping" {
    var config = Config{};
    config.provider.name = "claude";
    try std.testing.expectEqualStrings("claude", config.getProviderCommand());
}

test "Config: getProviderCommand case-insensitive" {
    var c = Config{};
    c.provider.name = "Claude";
    try std.testing.expectEqualStrings("claude", c.getProviderCommand());
    c.provider.name = "CRUSH";
    try std.testing.expectEqualStrings("crush", c.getProviderCommand());
    c.provider.name = "Pi";
    try std.testing.expectEqualStrings("pi", c.getProviderCommand());
}

test "Config: getProviderCommand explicit override" {
    var config = Config{};
    config.provider.command = "/opt/bin/my-claude";
    try std.testing.expectEqualStrings("/opt/bin/my-claude", config.getProviderCommand());
}

test "Config: parse bell settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\bell-audible = false
        \\bell-visual = on
        \\bell-sound = Glass
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expect(!config.bell.audible);
    try std.testing.expect(config.bell.visual);
    try std.testing.expectEqualStrings("Glass", config.bell.sound.?);
}

test "Config: parse scrollback + system" {
    const src =
        \\scrollback-size = 50000
        \\open-at-login = yes
    ;
    const config = try Config.parse(std.testing.allocator, src);
    try std.testing.expectEqual(@as(u32, 50000), config.scrollback.size);
    try std.testing.expect(config.system.open_at_login);
}

test "Config: parse log pane" {
    const src =
        \\log-pane-enabled = true
        \\log-pane-width-fraction = 0.4
        \\log-pane-width-min = 180
        \\log-pane-width-max = 420
    ;
    const config = try Config.parse(std.testing.allocator, src);
    try std.testing.expect(config.log_pane.enabled);
    try std.testing.expect(config.log_pane.width_fraction > 0.39 and config.log_pane.width_fraction < 0.41);
    try std.testing.expectEqual(@as(f64, 180), config.log_pane.width_min);
    try std.testing.expectEqual(@as(f64, 420), config.log_pane.width_max);
}

test "Config: window-position dash → enum" {
    const config = try Config.parse(std.testing.allocator, "window-position = top-left\n");
    try std.testing.expectEqual(Config.WindowConfig.Position.top_left, config.window.position);
}

test "Config: window-toggle-style enum" {
    const config = try Config.parse(std.testing.allocator, "window-toggle-style = minimize\n");
    try std.testing.expectEqual(Config.WindowConfig.ToggleStyle.minimize, config.window.toggle_style);
}

test "Config: quoted string value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try Config.parse(arena.allocator(), "font-family = \"JetBrains Mono\"\n");
    try std.testing.expectEqualStrings("JetBrains Mono", config.terminal.font_family.?);
}

test "Config: theme hex value preserved (inline # not a comment)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\background = #112233
        \\foreground = #aabbcc
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("#112233", config.theme.background.?);
    try std.testing.expectEqualStrings("#aabbcc", config.theme.foreground.?);
}

test "Config: malformed keybind warns but parse succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\keybind = no_equals_here
        \\hotkey = ctrl+space
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 0), config.keymap.entries.len);
    try std.testing.expectEqualStrings("ctrl+space", config.hotkey.toggle);
}

test "Config: parse profile entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\default-profile = main
        \\profile.main.provider = claude
        \\profile.main.cwd = ~/projects/main
        \\profile.main.title = main repo
        \\profile.codex.provider = codex
        \\profile.codex.command = /opt/bin/codex
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("main", config.profiles.default.?);
    try std.testing.expectEqual(@as(usize, 2), config.profiles.entries.len);
    try std.testing.expectEqualStrings("main", config.profiles.entries[0].name);
    try std.testing.expectEqualStrings("claude", config.profiles.entries[0].provider.?);
    try std.testing.expectEqualStrings("~/projects/main", config.profiles.entries[0].cwd.?);
    try std.testing.expectEqualStrings("main repo", config.profiles.entries[0].title.?);
    try std.testing.expectEqualStrings("codex", config.profiles.entries[1].name);
    try std.testing.expectEqualStrings("/opt/bin/codex", config.profiles.entries[1].command.?);
}

test "Config: malformed profile key warns + skips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\profile.no_field = whatever
        \\profile..provider = bogus
        \\profile.good.provider = claude
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), config.profiles.entries.len);
    try std.testing.expectEqualStrings("good", config.profiles.entries[0].name);
}

test "Config: unknown profile field warns + skips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\profile.main.provider = claude
        \\profile.main.bogus_field = nope
    ;
    const config = try Config.parse(arena.allocator(), src);
    // The "bogus_field" warning fires but the provider field stuck.
    try std.testing.expectEqual(@as(usize, 1), config.profiles.entries.len);
    try std.testing.expectEqualStrings("claude", config.profiles.entries[0].provider.?);
}

test "Config: parseBool variants" {
    try std.testing.expectEqual(true, try parseBool("true"));
    try std.testing.expectEqual(true, try parseBool("yes"));
    try std.testing.expectEqual(true, try parseBool("on"));
    try std.testing.expectEqual(true, try parseBool("1"));
    try std.testing.expectEqual(false, try parseBool("false"));
    try std.testing.expectEqual(false, try parseBool("no"));
    try std.testing.expectEqual(false, try parseBool("off"));
    try std.testing.expectEqual(false, try parseBool("0"));
    try std.testing.expectError(error.NotABool, parseBool("maybe"));
}
