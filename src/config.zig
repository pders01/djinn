const std = @import("std");
const platform = @import("io/platform.zig");

pub const Config = struct {
    window: WindowConfig = .{},
    terminal: TerminalConfig = .{},
    theme: ThemeConfig = .{},
    hotkey: HotkeyConfig = .{},
    notifications: NotifyConfig = .{},
    scrollback: ScrollbackConfig = .{},
    system: SystemConfig = .{},
    bell: BellConfig = .{},
    keymap: KeymapConfig = .{},
    profiles: ProfilesConfig = .{},
    /// Parsed configs own their strings and entry slices in this arena.
    /// Defaults and manually constructed configs borrow their values. Do not
    /// deinit multiple copies of a parsed Config.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub const WindowConfig = struct {
        /// Optional so the runtime can tell "user set this explicitly"
        /// from "fall through to state.json or default". Set in
        /// applyKey when the user writes `window-width = N`. When null,
        /// `restoreWindowSize` uses state.json (if present) else the
        /// hardcoded default.
        width: ?u32 = null,
        height: ?u32 = null,
        position: Position = .top_center,
        /// Manual override in NSScreen coords (origin bottom-left of the
        /// active screen, +Y up). null = use `position`'s enum-derived
        /// value for that axis. Set via `window-position-x` /
        /// `window-position-y`, or via the `X,Y` form of `window-position`.
        position_x: ?f64 = null,
        position_y: ?f64 = null,
        // Parse-only compatibility fields; neither terminal backend consumes
        // them. Legacy keys warn with their modern replacements, without
        // restoring old opacity/font fallbacks or changing explicit overrides.
        opacity: f64 = 0.95,
        font_size: f64 = 14.0,
        toggle_style: ToggleStyle = .instant,
        topmost: bool = true,
        /// When true, the panel auto-hides as soon as it loses key status —
        /// e.g. user invokes Raycast/Spotlight. Off by default because users
        /// who toggle frequently typically want the popup to stay put.
        hide_on_blur: bool = false,

        pub const Position = enum {
            top_left,
            top_center,
            top_right,
            center_left,
            center,
            center_right,
            bottom_left,
            bottom_center,
            bottom_right,
        };
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
        toggle: []const u8 = "ctrl+shift+space",
    };

    /// One static configured terminal profile. The session manager copies
    /// these strings so a config reload cannot invalidate launch state.
    pub const ProfileEntry = struct {
        name: []const u8,
        /// Shell expression: preserve executable/argument quotes verbatim.
        command: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        title: ?[]const u8 = null,
        /// Executable script; takes precedence over command. Invalid scripts
        /// fail session initialization instead of silently spawning a shell.
        /// Leading `~/` is expanded by SessionManager.
        script: ?[]const u8 = null,
        /// Per-profile bell overrides. null = inherit the global
        /// `bell.*` config.
        bell_audible: ?bool = null,
        bell_visual: ?bool = null,
        bell_sound: ?[]const u8 = null,
    };

    pub const ProfilesConfig = struct {
        /// Name of the profile that's active at startup. Falls back to
        /// the first parsed profile if unset; falls back to a synthesized
        /// "default" ordinary-shell profile if none were configured.
        default: ?[]const u8 = null,
        entries: []const ProfileEntry = &.{},
    };

    pub const ScrollbackConfig = struct {
        /// Lines retained beyond the visible grid. null leaves the backend
        /// default/inherited limit; zero disables retained scrollback.
        /// Ghostty's independent byte cap can retain fewer than this limit.
        size: ?u32 = null,
    };

    pub const SystemConfig = struct {
        /// Absent: leave OS registration alone, including explicit CLI/menu
        /// actions. Explicit true/false is policy reconciled at startup/reload;
        /// conflicting actions are rejected, never written back to config.
        open_at_login: ?bool = null,
    };

    pub const BellConfig = struct {
        /// Play a sound on BEL (0x07) via afplay using a system sound
        /// name or an absolute path.
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
        /// tab_1..tab_9, next_tab, prev_tab, etc.).
        /// Bindings parse via hotkey.parseKeybinding ("cmd+k", etc.).
        entries: []const KeymapEntry = &.{},
    };

    pub const NotifyConfig = struct {
        system_notifications: bool = true,
        menubar_icon: bool = true,
        /// Minimum interval between terminal notifications.
        rate_limit_ms: u64 = 30_000,
    };

    /// Strictly load ~/.config/djinn/config (ghostty key=value format).
    /// Read, syntax and known-setting errors propagate so callers can
    /// distinguish "no config, use defaults" from "transient read
    /// failure, keep the previous config." Atomic-write editors (vim,
    /// VS Code, Helix) save by renaming a tmp file over the target;
    /// FSEvents fires during the gap and an open here hits ENOENT.
    /// Swallowing that as a default `Config{}` (the previous behavior)
    /// silently clobbered every user setting on every save.
    pub fn load(allocator: std.mem.Allocator) !Config {
        const path = try defaultConfigPath(allocator);
        defer allocator.free(path);

        const contents = try std.Io.Dir.cwd().readFileAlloc(platform.io(), path, allocator, .limited(64 * 1024));
        defer allocator.free(contents);

        return parseStrict(allocator, contents);
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
    /// allocator; release them with Config.deinit, including on reload.
    pub fn parse(backing_allocator: std.mem.Allocator, contents: []const u8) !Config {
        return parseWithMode(backing_allocator, contents, false);
    }

    /// Reject malformed syntax and known settings atomically. Unknown and
    /// removed keys still warn for migration compatibility. Hotkey/binding
    /// grammar is checked by the runtime before it installs this candidate.
    pub fn parseStrict(backing_allocator: std.mem.Allocator, contents: []const u8) !Config {
        return parseWithMode(backing_allocator, contents, true);
    }

    fn parseWithMode(backing_allocator: std.mem.Allocator, contents: []const u8, strict: bool) !Config {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var config = Config{};
        var keymap_list: std.ArrayList(KeymapEntry) = .empty;
        defer keymap_list.deinit(allocator);
        var profile_list: std.ArrayList(ProfileEntry) = .empty;
        defer profile_list.deinit(allocator);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: u32 = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
            if (line.len == 0) continue;

            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse {
                std.debug.print("warning: config:{d}: missing '=' in '{s}'\n", .{ line_no, line });
                if (strict) return error.MalformedSetting;
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const raw_val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
            if (strict and (key.len == 0 or std.mem.indexOfScalar(u8, line, 0) != null or
                !validQuotedValue(key, raw_val)))
            {
                std.debug.print("warning: config:{d}: malformed key/value syntax\n", .{line_no});
                return error.MalformedSetting;
            }
            // Commands are shell expressions, not quoted scalar strings: even
            // an executable-only quoted path needs its quotes at launch.
            const val = if (isProfileCommand(key)) raw_val else unquote(raw_val);

            if (removedKeyHelp(key)) |help| {
                std.debug.print("warning: config:{d}: removed key '{s}'; {s}\n", .{ line_no, key, help });
                continue;
            }
            if (legacyKeyReplacement(key)) |replacement|
                std.debug.print("warning: config:{d}: legacy key '{s}' has no terminal effect; use '{s}' instead\n", .{ line_no, key, replacement });
            applyKey(&config, &keymap_list, &profile_list, allocator, key, val) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                std.debug.print("warning: config:{d}: '{s}' = '{s}' ({}); check this setting in ~/.config/djinn/config\n", .{ line_no, key, val, err });
                if (strict and err != error.UnknownProfileField) return err;
            };
        }

        config.keymap.entries = try keymap_list.toOwnedSlice(allocator);
        config.profiles.entries = try profile_list.toOwnedSlice(allocator);
        config.arena = arena;
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
            try requireNonempty(val);
            config.profiles.default = try allocator.dupe(u8, val);
            return;
        }
        if (std.mem.startsWith(u8, key, "profile.")) {
            try applyProfileKey(profile_list, allocator, key["profile.".len..], val);
            return;
        }

        // Window ----------------------------------------------------------
        if (eq(key, "window-width")) {
            config.window.width = try parseDimension(val);
        } else if (eq(key, "window-height")) {
            config.window.height = try parseDimension(val);
        } else if (eq(key, "window-position")) {
            // Two accepted forms: a named enum (e.g. `top_center`) or an
            // `X,Y` coord pair in NSScreen units. The pair form sets
            // position_x/y; the enum form clears them so the named anchor
            // takes full effect even when `-x` / `-y` lines appeared
            // earlier in the file (precedence by setting, not parse order).
            var pos_buf: [64]u8 = undefined;
            if (std.meta.stringToEnum(WindowConfig.Position, dashToUnder(val, &pos_buf))) |p| {
                config.window.position = p;
                config.window.position_x = null;
                config.window.position_y = null;
            } else if (std.mem.indexOfScalar(u8, val, ',')) |idx| {
                const xs = std.mem.trim(u8, val[0..idx], " \t");
                const ys = std.mem.trim(u8, val[idx + 1 ..], " \t");
                const x = try parseFloatRange(xs, -max_position, max_position);
                const y = try parseFloatRange(ys, -max_position, max_position);
                config.window.position_x = x;
                config.window.position_y = y;
            } else return error.UnknownEnum;
        } else if (eq(key, "window-position-x")) {
            config.window.position_x = try parseFloatRange(val, -max_position, max_position);
        } else if (eq(key, "window-position-y")) {
            config.window.position_y = try parseFloatRange(val, -max_position, max_position);
        } else if (eq(key, "window-toggle-style")) {
            var ts_buf: [64]u8 = undefined;
            config.window.toggle_style = std.meta.stringToEnum(WindowConfig.ToggleStyle, dashToUnder(val, &ts_buf)) orelse return error.UnknownEnum;
        } else if (eq(key, "window-topmost")) {
            config.window.topmost = try parseBool(val);
        } else if (eq(key, "hide-on-blur")) {
            config.window.hide_on_blur = try parseBool(val);
        } else if (eq(key, "window-opacity")) {
            // Parse and validate only; parseWithMode emits migration advice.
            config.window.opacity = try parseFloatRange(val, 0, 1);
        } else if (eq(key, "window-font-size")) {
            // Parse and validate only; use terminal.font_size at runtime.
            config.window.font_size = try parseFloatRange(val, 1, max_dimension);
        }
        // Hotkey ----------------------------------------------------------
        else if (eq(key, "hotkey")) {
            try requireNonempty(val);
            config.hotkey.toggle = try allocator.dupe(u8, val);
        }
        // Notifications ---------------------------------------------------
        else if (eq(key, "system-notifications")) {
            config.notifications.system_notifications = try parseBool(val);
        } else if (eq(key, "menubar-icon")) {
            config.notifications.menubar_icon = try parseBool(val);
        } else if (eq(key, "notify-rate-limit-ms")) {
            config.notifications.rate_limit_ms = try std.fmt.parseInt(u64, val, 10);
        }
        // Terminal --------------------------------------------------------
        else if (eq(key, "font-family")) {
            try requireNonempty(val);
            config.terminal.font_family = try allocator.dupe(u8, val);
        } else if (eq(key, "font-size")) {
            config.terminal.font_size = try parseFloatRange(val, 1, max_dimension);
        } else if (eq(key, "padding-x")) {
            config.terminal.padding_x = try parseFloatRange(val, 0, max_dimension);
        } else if (eq(key, "padding-y")) {
            config.terminal.padding_y = try parseFloatRange(val, 0, max_dimension);
        }
        // Scrollback ------------------------------------------------------
        else if (eq(key, "scrollback-size")) {
            config.scrollback.size = try std.fmt.parseInt(u32, val, 10);
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
            config.theme.opacity = try parseFloatRange(val, 0, 1);
        } else if (eq(key, "background")) {
            try validateColor(val);
            config.theme.background = try allocator.dupe(u8, val);
        } else if (eq(key, "foreground")) {
            try validateColor(val);
            config.theme.foreground = try allocator.dupe(u8, val);
        } else if (eq(key, "cursor-color")) {
            try validateColor(val);
            config.theme.cursor = try allocator.dupe(u8, val);
        }
        // Keybinds — `keybind = action=trigger` (ghostty syntax) ---------
        else if (eq(key, "keybind")) {
            const sub_eq = std.mem.indexOfScalar(u8, val, '=') orelse return error.MalformedKeybind;
            const action = std.mem.trim(u8, val[0..sub_eq], " \t");
            const trigger = std.mem.trim(u8, val[sub_eq + 1 ..], " \t");
            if (action.len == 0 or trigger.len == 0) return error.MalformedKeybind;
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

        // Validate first: unsupported fields must not create shell profiles.
        const supported = [_][]const u8{ "command", "cwd", "title", "script", "bell-audible", "bell-visual", "bell-sound" };
        var known = false;
        for (supported) |candidate| {
            if (eq(field, candidate)) known = true;
        }
        if (!known) return error.UnknownProfileField;
        if (eq(field, "command") or eq(field, "script") or eq(field, "cwd")) {
            const empty = if (eq(field, "command")) emptyCommand(val) else std.mem.trim(u8, val, " \t\r\n").len == 0;
            if (empty) return error.EmptyLaunchValue;
            if (std.mem.indexOfScalar(u8, val, 0) != null) return error.InvalidLaunchValue;
        }

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

        // Bell overrides take a bool or a sound name. Parse those
        // before the generic dup path so we don't allocate then free.
        if (eq(field, "bell-audible")) {
            entry.bell_audible = try parseBool(val);
            return;
        } else if (eq(field, "bell-visual")) {
            entry.bell_visual = try parseBool(val);
            return;
        }

        const dup = try allocator.dupe(u8, val);
        if (eq(field, "command")) {
            entry.command = dup;
        } else if (eq(field, "cwd")) {
            entry.cwd = dup;
        } else if (eq(field, "title")) {
            entry.title = dup;
        } else if (eq(field, "script")) {
            entry.script = dup;
        } else if (eq(field, "bell-sound")) {
            entry.bell_sound = dup;
        } else {
            allocator.free(dup);
            return error.UnknownProfileField;
        }
    }

    pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const home = platform.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/.config/djinn/config", .{home});
    }
};

// Parse helpers ---------------------------------------------------------

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Accepted legacy scalars are validated but do not drive either backend.
fn legacyKeyReplacement(key: []const u8) ?[]const u8 {
    if (eq(key, "window-opacity")) return "opacity";
    if (eq(key, "window-font-size")) return "font-size";
    return null;
}

/// Migration diagnostics for removed infrastructure.
fn removedKeyHelp(key: []const u8) ?[]const u8 {
    if (eq(key, "provider") or eq(key, "provider-command") or
        (std.mem.startsWith(u8, key, "profile.") and std.mem.endsWith(u8, key, ".provider")))
        return "use profile.<name>.command = <executable> (or .script); omit both for your default shell";
    if (std.mem.startsWith(u8, key, "mcp-") or std.mem.startsWith(u8, key, "client.") or
        std.mem.startsWith(u8, key, "log-pane-"))
        return "remove this setting; MCP, client identities and the log pane are no longer supported";
    if (eq(key, "attention-sound") or eq(key, "notify-attention") or eq(key, "notify-error") or
        eq(key, "notify-done") or eq(key, "notify-progress"))
        return "remove this agent notification setting; terminal bells use bell-audible, bell-visual and bell-sound";
    return null;
}

// Bound sizes before they reach native geometry, font, and integer casts.
// Zero padding/opacity is useful; fonts and window dimensions must be positive.
const max_dimension = std.math.maxInt(u16);
const max_position = std.math.maxInt(i32);

fn parseDimension(val: []const u8) !u32 {
    const value = try std.fmt.parseInt(u32, val, 10);
    if (value == 0 or value > max_dimension) return error.OutOfRange;
    return value;
}

fn parseFiniteFloat(val: []const u8) !f64 {
    const value = try std.fmt.parseFloat(f64, val);
    if (!std.math.isFinite(value)) return error.OutOfRange;
    return value;
}

fn parseFloatRange(val: []const u8, min: f64, max: f64) !f64 {
    const value = try parseFiniteFloat(val);
    if (value < min or value > max) return error.OutOfRange;
    return value;
}

fn requireNonempty(val: []const u8) !void {
    if (std.mem.trim(u8, val, " \t\r\n").len == 0) return error.EmptyValue;
}

// Match the theme parser's supported #rrggbb, 0xrrggbb, and rrggbb forms.
fn validateColor(val: []const u8) !void {
    const digits = if (std.mem.startsWith(u8, val, "#")) val[1..] else if (std.mem.startsWith(u8, val, "0x") or std.mem.startsWith(u8, val, "0X")) val[2..] else val;
    if (digits.len != 6) return error.InvalidColor;
    _ = std.fmt.parseInt(u24, digits, 16) catch return error.InvalidColor;
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

/// Find the closing quote paired with an opening double quote, not a later
/// shell argument's quote. Leave escaping intact, as in permissive parsing.
fn closingQuote(s: []const u8) ?usize {
    if (s.len == 0 or s[0] != '"') return null;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == '"') return i;
    }
    return null;
}

fn isProfileCommand(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "profile.") and std.mem.endsWith(u8, key, ".command");
}

/// Validate without removing shell quoting from the stored expression.
fn emptyCommand(value: []const u8) bool {
    const s = std.mem.trim(u8, value, " \t\r\n");
    if (s.len == 0) return true;
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
        return std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n").len == 0;
    }
    return false;
}

fn validQuotedValue(key: []const u8, s: []const u8) bool {
    if (s.len == 0 or s[0] != '"') return true;
    const end = closingQuote(s) orelse return false;
    // A quoted executable followed by shell arguments is a command, not a
    // malformed quoted config string. Shell grammar belongs to the shell.
    return end == s.len - 1 or isProfileCommand(key);
}

fn unquote(s: []const u8) []const u8 {
    if (closingQuote(s)) |end| {
        if (end == s.len - 1) return s[1..end];
    }
    return s;
}

/// Convert dashed value to underscored so std.meta.stringToEnum hits.
/// Caller-supplied buffer keeps the result safe to nest; if the input
/// is longer than the buffer the original slice is returned unchanged
/// (the enum lookup will then miss, which is the right outcome).
fn dashToUnder(s: []const u8, buf: []u8) []const u8 {
    if (s.len > buf.len) return s;
    for (s, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return buf[0..s.len];
}

// Tests
test "Config: parse defaults from empty input" {
    var config = try Config.parse(std.testing.allocator, "");
    defer config.deinit();
    try std.testing.expect(config.window.width == null);
    try std.testing.expect(config.window.height == null);
    try std.testing.expectEqualStrings("ctrl+shift+space", config.hotkey.toggle);
}

test "Config: parse window settings" {
    const src =
        \\window-width = 1024
        \\window-height = 600
        \\window-opacity = 0.9
        \\window-font-size = 16
    ;
    var config = try Config.parse(std.testing.allocator, src);
    defer config.deinit();
    try std.testing.expectEqual(@as(u32, 1024), config.window.width.?);
    try std.testing.expectEqual(@as(u32, 600), config.window.height.?);
    try std.testing.expect(config.window.opacity < 0.91 and config.window.opacity > 0.89);
}

test "Config: legacy window settings have migration advice and no terminal fallback" {
    try std.testing.expectEqualStrings("opacity", legacyKeyReplacement("window-opacity").?);
    try std.testing.expectEqualStrings("font-size", legacyKeyReplacement("window-font-size").?);
    try std.testing.expect(legacyKeyReplacement("opacity") == null);
    try std.testing.expect(legacyKeyReplacement("font-size") == null);
    var config = try Config.parseStrict(std.testing.allocator, "window-opacity = 0.4\nwindow-font-size = 16\n");
    defer config.deinit();
    try std.testing.expectEqual(@as(f64, 0.4), config.window.opacity);
    try std.testing.expectEqual(@as(f64, 16), config.window.font_size);
    try std.testing.expect(config.theme.opacity == null);
    try std.testing.expect(config.terminal.font_size == null);
}

test "Config: legacy window keys never override modern settings in either order" {
    for ([_][]const u8{
        "window-opacity = 0.4\nopacity = 0.8\nwindow-font-size = 16\nfont-size = 18\n",
        "opacity = 0.8\nwindow-opacity = 0.4\nfont-size = 18\nwindow-font-size = 16\n",
    }) |settings| {
        var config = try Config.parseStrict(std.testing.allocator, settings);
        defer config.deinit();
        try std.testing.expectEqual(@as(?f64, 0.8), config.theme.opacity);
        try std.testing.expectEqual(@as(?f64, 18), config.terminal.font_size);
    }
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

test "Config: absent login policy leaves OS state alone; explicit false is distinct" {
    var absent = try Config.parse(std.testing.allocator, "");
    defer absent.deinit();
    var disabled = try Config.parse(std.testing.allocator, "open-at-login = false\n");
    defer disabled.deinit();
    try std.testing.expectEqual(@as(?bool, null), absent.system.open_at_login);
    try std.testing.expectEqual(@as(?bool, false), disabled.system.open_at_login);
}

test "Config: scrollback unset zero and positive are distinct line limits" {
    const cases = [_]struct { text: []const u8, lines: ?u32 }{
        .{ .text = "", .lines = null },
        .{ .text = "scrollback-size = 0", .lines = 0 },
        .{ .text = "scrollback-size = 12345", .lines = 12345 },
    };
    for (cases) |case| {
        var cfg = try Config.parse(std.testing.allocator, case.text);
        defer cfg.deinit();
        try std.testing.expectEqual(case.lines, cfg.scrollback.size);
    }
}

test "Config: parse scrollback + system" {
    const src =
        \\scrollback-size = 50000
        \\open-at-login = yes
    ;
    var config = try Config.parse(std.testing.allocator, src);
    defer config.deinit();
    try std.testing.expectEqual(@as(?u32, 50000), config.scrollback.size);
    try std.testing.expectEqual(@as(?bool, true), config.system.open_at_login);
}

test "Config: window-position dash → enum" {
    var config = try Config.parse(std.testing.allocator, "window-position = top-left\n");
    defer config.deinit();
    try std.testing.expectEqual(Config.WindowConfig.Position.top_left, config.window.position);
    try std.testing.expectEqual(@as(?f64, null), config.window.position_x);
    try std.testing.expectEqual(@as(?f64, null), config.window.position_y);
}

test "Config: window-position 9-grid arms" {
    inline for ([_][]const u8{ "bottom_right", "center_left", "center", "bottom-center" }) |name| {
        const src = "window-position = " ++ name ++ "\n";
        var config = try Config.parse(std.testing.allocator, src);
        defer config.deinit();
    }
}

test "Config: window-position X,Y coord pair" {
    var config = try Config.parse(std.testing.allocator, "window-position = 100,250\n");
    defer config.deinit();
    try std.testing.expectEqual(@as(?f64, 100), config.window.position_x);
    try std.testing.expectEqual(@as(?f64, 250), config.window.position_y);
}

test "Config: window-position-x / -y override" {
    var config = try Config.parse(std.testing.allocator, "window-position-x = 50\nwindow-position-y = 75\n");
    defer config.deinit();
    try std.testing.expectEqual(@as(?f64, 50), config.window.position_x);
    try std.testing.expectEqual(@as(?f64, 75), config.window.position_y);
}

test "Config: window-position enum clears earlier manual coords" {
    const src =
        \\window-position-x = 100
        \\window-position-y = 200
        \\window-position = top_left
    ;
    var config = try Config.parse(std.testing.allocator, src);
    defer config.deinit();
    try std.testing.expectEqual(Config.WindowConfig.Position.top_left, config.window.position);
    try std.testing.expectEqual(@as(?f64, null), config.window.position_x);
    try std.testing.expectEqual(@as(?f64, null), config.window.position_y);
}

test "Config: window-toggle-style enum" {
    var config = try Config.parse(std.testing.allocator, "window-toggle-style = minimize\n");
    defer config.deinit();
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
        \\profile.main.command = /bin/sh
        \\profile.main.cwd = ~/projects/main
        \\profile.main.title = main repo
        \\profile.codex.command = /opt/bin/codex
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("main", config.profiles.default.?);
    try std.testing.expectEqual(@as(usize, 2), config.profiles.entries.len);
    try std.testing.expectEqualStrings("main", config.profiles.entries[0].name);
    try std.testing.expectEqualStrings("/bin/sh", config.profiles.entries[0].command.?);
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
        \\profile..command = bogus
        \\profile.good.command = /bin/sh
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), config.profiles.entries.len);
    try std.testing.expectEqualStrings("good", config.profiles.entries[0].name);
}

test "Config: profile.script parses + survives roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\profile.main.script = ~/.config/djinn/profiles/main.sh
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), config.profiles.entries.len);
    try std.testing.expectEqualStrings(
        "~/.config/djinn/profiles/main.sh",
        config.profiles.entries[0].script.?,
    );
}

test "Config: unknown profile field warns + skips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\profile.main.bogus_field = nope
        \\profile.main.title = Shell
    ;
    const config = try Config.parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), config.profiles.entries.len);
    try std.testing.expectEqualStrings("Shell", config.profiles.entries[0].title.?);
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

test "Config: removed keys have migration diagnostics and do not create profiles" {
    const removed = [_][]const u8{
        "provider",           "provider-command", "profile.old.provider", "mcp-enabled",      "mcp-socket-path",
        "client.abc123.name", "log-pane-enabled", "attention-sound",      "notify-attention", "notify-error",
        "notify-done",        "notify-progress",
    };
    for (removed) |key| try std.testing.expect(removedKeyHelp(key) != null);
    try std.testing.expect(removedKeyHelp("notify-rate-limit-ms") == null);
    var config = try Config.parse(std.testing.allocator,
        \\profile.old.provider = old-agent
        \\mcp-enabled = true
        \\log-pane-enabled = true
        \\system-notifications = false
        \\menubar-icon = false
        \\notify-rate-limit-ms = 123
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 0), config.profiles.entries.len);
    try std.testing.expect(!config.notifications.system_notifications);
    try std.testing.expect(!config.notifications.menubar_icon);
    try std.testing.expectEqual(@as(u64, 123), config.notifications.rate_limit_ms);
}

test "Config: parsed strings and repeated keys are owned until deinit" {
    var config = try Config.parse(std.testing.allocator,
        \\hotkey = cmd+k
        \\hotkey = ctrl+space
        \\font-family = Mono
        \\background = #123456
        \\foreground = #abcdef
        \\cursor-color = #aaaaaa
        \\default-profile = main
        \\profile.main.command = old
        \\profile.main.command = /bin/sh
        \\profile.main.cwd = /tmp
        \\profile.main.title = Shell
        \\profile.main.script = /tmp/shell.sh
        \\profile.main.bell-sound = Glass
        \\profile.main.bell-audible = false
        \\profile.main.bell-visual = true
        \\bell-sound = Tink
        \\keybind = copy=cmd+c
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("/bin/sh", config.profiles.entries[0].command.?);
    try std.testing.expectEqualStrings("Glass", config.profiles.entries[0].bell_sound.?);
    try std.testing.expectEqual(@as(?bool, false), config.profiles.entries[0].bell_audible);
    try std.testing.expectEqual(@as(?bool, true), config.profiles.entries[0].bell_visual);
}

test "Config: strict parser rejects malformed syntax and known settings" {
    const cases = [_]struct { text: []const u8, err: anyerror }{
        .{ .text = "window-width 800", .err = error.MalformedSetting },
        .{ .text = "= value", .err = error.MalformedSetting },
        .{ .text = "font-family = \"unterminated", .err = error.MalformedSetting },
        .{ .text = "font-family = \"Mono\" trailing", .err = error.MalformedSetting },
        .{ .text = "hotkey = \x00bad", .err = error.MalformedSetting },
        .{ .text = "window-width = wide", .err = error.InvalidCharacter },
        .{ .text = "notify-rate-limit-ms = fast", .err = error.InvalidCharacter },
        .{ .text = "opacity = opaque", .err = error.InvalidCharacter },
        .{ .text = "bell-audible = maybe", .err = error.NotABool },
        .{ .text = "profile.main.bell-visual = maybe", .err = error.NotABool },
        .{ .text = "window-position = diagonal", .err = error.UnknownEnum },
        .{ .text = "window-toggle-style = fade", .err = error.UnknownEnum },
        .{ .text = "keybind = no_equals", .err = error.MalformedKeybind },
        .{ .text = "keybind = =cmd+c", .err = error.MalformedKeybind },
        .{ .text = "keybind = copy=", .err = error.MalformedKeybind },
        .{ .text = "profile..title = main", .err = error.MalformedProfileKey },
        .{ .text = "profile.main = main", .err = error.MalformedProfileKey },
        .{ .text = "font-family = \"\"", .err = error.EmptyValue },
        .{ .text = "default-profile =", .err = error.EmptyValue },
        .{ .text = "hotkey =", .err = error.EmptyValue },
        .{ .text = "background = not-a-color", .err = error.InvalidColor },
        .{ .text = "profile.main.command =", .err = error.EmptyLaunchValue },
        .{ .text = "profile.main.script = \" \"", .err = error.EmptyLaunchValue },
        .{ .text = "profile.main.cwd = \"\"", .err = error.EmptyLaunchValue },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, Config.parseStrict(std.testing.allocator, case.text));
    }
}

test "Config: strict numeric ranges reject nonfinite and unsafe geometry" {
    const invalid = [_][]const u8{
        "window-width = 0",          "window-height = 65536",
        "font-size = 0",             "font-size = 0.000001",
        "font-size = 65536",         "window-font-size = -1",
        "font-size = nan",           "font-size = inf",
        "font-size = 1e999",         "padding-x = -1",
        "padding-y = nan",           "padding-x = 1e100",
        "window-position-x = nan",   "window-position-y = inf",
        "window-position = 100,nan", "window-position-x = 1e100",
        "opacity = 1.1",             "opacity = -0.1",
        "window-opacity = inf",      "window-opacity = nan",
    };
    for (invalid) |src| {
        try std.testing.expectError(error.OutOfRange, Config.parseStrict(std.testing.allocator, src));
    }
    var config = try Config.parseStrict(std.testing.allocator,
        \\window-width = 1
        \\window-height = 65535
        \\font-size = 1
        \\padding-x = 0
        \\padding-y = 65535
        \\opacity = 0
        \\window-opacity = 1
        \\window-position = -100,200
        \\scrollback-size = 0
        \\notify-rate-limit-ms = 0
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(?f64, 0), config.terminal.padding_x);
    try std.testing.expectEqual(@as(?f64, 0), config.theme.opacity);
}

test "Config: strict mode accepts unknown and removed keys without creating profiles" {
    var config = try Config.parseStrict(std.testing.allocator,
        \\unknown-key = future-setting
        \\provider = removed
        \\profile.old.provider = removed
        \\profile.unknown.future-field = value
        \\mcp-enabled = true
        \\profile.main.title = Shell
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 1), config.profiles.entries.len);
    try std.testing.expectEqualStrings("main", config.profiles.entries[0].name);
}

test "Config: strict candidate failure leaves previous valid config untouched" {
    var current = try Config.parseStrict(std.testing.allocator, "font-size = 18\nhotkey = cmd+k\n");
    defer current.deinit();
    try std.testing.expectError(error.NotABool, Config.parseStrict(std.testing.allocator, "font-size = 24\nwindow-topmost = maybe\n"));
    try std.testing.expectEqual(@as(?f64, 18), current.terminal.font_size);
    try std.testing.expectEqualStrings("cmd+k", current.hotkey.toggle);
}

test "Config: strict parsing preserves shell syntax within explicit commands" {
    var config = try Config.parseStrict(std.testing.allocator,
        \\profile.main.command = "/some path/tool" --arg='literal $HOME'
        \\profile.quoted.command = "/some path/tool" --arg="literal $HOME"
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("\"/some path/tool\" --arg='literal $HOME'", config.profiles.entries[0].command.?);
    try std.testing.expectEqualStrings("\"/some path/tool\" --arg=\"literal $HOME\"", config.profiles.entries[1].command.?);
}

test "Config: command expressions keep quotes while profile scalars unquote" {
    const source =
        \\profile.only.command = "/tmp/my tool"
        \\profile.args.command = "/tmp/my tool" --arg="value"
        \\profile.normal.command = /bin/tool --flag
        \\profile.single.command = '/tmp/my tool'
        \\profile.only.script = "/tmp/my script"
        \\profile.only.cwd = "/tmp/my directory"
        \\profile.only.title = "My title"
        \\font-family = "My font"
    ;
    // Both parsing modes must agree; only scalar values lose their quotes.
    for ([_]bool{ false, true }) |strict| {
        var config = try Config.parseWithMode(std.testing.allocator, source, strict);
        defer config.deinit();
        try std.testing.expectEqualStrings("\"/tmp/my tool\"", config.profiles.entries[0].command.?);
        try std.testing.expectEqualStrings("\"/tmp/my tool\" --arg=\"value\"", config.profiles.entries[1].command.?);
        try std.testing.expectEqualStrings("/bin/tool --flag", config.profiles.entries[2].command.?);
        try std.testing.expectEqualStrings("'/tmp/my tool'", config.profiles.entries[3].command.?);
        try std.testing.expectEqualStrings("/tmp/my script", config.profiles.entries[0].script.?);
        try std.testing.expectEqualStrings("/tmp/my directory", config.profiles.entries[0].cwd.?);
        try std.testing.expectEqualStrings("My title", config.profiles.entries[0].title.?);
        try std.testing.expectEqualStrings("My font", config.terminal.font_family.?);
    }
}

test "Config: empty and whitespace command expressions remain invalid" {
    const sources = [_][]const u8{
        "profile.work.command =",
        "profile.work.command = \t ",
        "profile.work.command = \"\"",
        "profile.work.command = \" \t \"",
        "profile.work.command = ''",
        "profile.work.command = ' \t '",
    };
    for (sources) |source| {
        try std.testing.expectError(error.EmptyLaunchValue, Config.parseStrict(std.testing.allocator, source));
        var permissive = try Config.parse(std.testing.allocator, source);
        defer permissive.deinit();
        try std.testing.expectEqual(@as(usize, 0), permissive.profiles.entries.len);
    }
}

test "Config: strict allocation failures clean up successful and rejected candidates" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            var config = try Config.parseStrict(allocator, "profile.main.command = /bin/sh\nkeybind = copy=cmd+c\n");
            defer config.deinit();
            if (Config.parseStrict(allocator, "profile.main.command = /bin/sh\nbell-audible = invalid\n")) |candidate| {
                var unexpected = candidate;
                unexpected.deinit();
                return error.ExpectedInvalidConfig;
            } else |err| switch (err) {
                error.NotABool => {},
                else => return err,
            }
        }
    }.check, .{});
}

test "Config: allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            var config = try Config.parse(allocator, "profile.main.command = /bin/sh\nkeybind = copy=cmd+c\n");
            defer config.deinit();
        }
    }.check, .{});
}
