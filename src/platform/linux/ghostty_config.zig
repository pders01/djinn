//! Ghostty config inheritance for the linux path.
//!
//! Darwin gets ghostty's resolved Config via `ghostty_config_get`
//! against the running libghostty surface; linux doesn't link
//! libghostty (the terminal engine is VTE), so we parse
//! `~/.config/ghostty/config` directly. Same format ghostty's own
//! parser documents: `key = value` per line, `#` line-level comments
//! (column-0 only — `#` inside hex values like `#1a1b1c` is content),
//! no `[section]` headers, repeated keys for `palette = N=#rrggbb`.
//!
//! Surface area is intentionally narrow: colors + font, the keys VTE
//! can actually consume. Window / scrollback / kitty-protocol keys
//! belong to ghostty's renderer and have no analogue here.
//!
//! Theme resolution. When the main config sets `theme = NAME`, we
//! parse the referenced theme file *first* (so its colors form the
//! base) and then re-apply the main config (its keys override the
//! theme). Search order matches what ghostty itself does:
//!
//!   1. `~/.config/ghostty/themes/<name>`
//!   2. `/usr/share/ghostty/themes/<name>`
//!   3. `/usr/local/share/ghostty/themes/<name>`     (Homebrew/Linux)
//!
//! `theme = light:Day,dark:Night` resolves via xdg-desktop-portal's
//! `org.freedesktop.appearance.color-scheme` setting. Defaults to
//! dark when the portal is unreachable or the value is 0 (no
//! preference) — most terminal users prefer dark, and matching the
//! macOS default (`detectSystemAppearance` in `theme/theme.zig`)
//! keeps cross-platform users from getting a surprise on first run.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../../io/platform.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Appearance = enum { light, dark };

/// Resolved subset of a ghostty config — every field is optional so
/// `loadFromUserConfig`'s caller can tell the difference between
/// "user set this" and "use VTE default". Owned strings are tagged
/// in the field docs; `deinit` frees them.
pub const Colors = struct {
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    cursor: ?Rgb = null,
    /// 16-color ANSI palette. Each slot is independently optional —
    /// a theme that sets only the bright variants leaves slots 0–7
    /// null and the caller fills with VTE defaults.
    palette: [16]?Rgb = @splat(null),
    /// Owned slice. Freed in deinit. Caller can dupe to extend
    /// lifetime past `Colors.deinit`.
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,

    pub fn deinit(self: *Colors, allocator: std.mem.Allocator) void {
        if (self.font_family) |s| allocator.free(s);
        self.* = .{};
    }
};

// ─── Top-level load ──────────────────────────────────────────────────

/// Read the user's ghostty config and merge any referenced theme file.
/// Returns null when `~/.config/ghostty/config` is absent — the
/// caller decides whether that's an error. On success the caller owns
/// the returned Colors and must call `Colors.deinit(allocator)`.
pub fn loadFromUserConfig(allocator: std.mem.Allocator) !?Colors {
    const root = try configRoot(allocator) orelse return null;
    defer allocator.free(root);
    const cfg_path = try std.fs.path.join(allocator, &.{ root, "ghostty/config" });
    defer allocator.free(cfg_path);
    const user_themes = try std.fs.path.join(allocator, &.{ root, "ghostty/themes" });
    defer allocator.free(user_themes);
    return loadFromPath(allocator, cfg_path, detectAppearance(), &.{
        user_themes,
        "/usr/share/ghostty/themes",
        "/usr/local/share/ghostty/themes",
    });
}

fn configRoot(allocator: std.mem.Allocator) !?[]u8 {
    if (platform.getenv("XDG_CONFIG_HOME")) |xdg| {
        if (std.fs.path.isAbsolute(xdg)) return try allocator.dupe(u8, xdg);
    }
    const home = platform.getenv("HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".config" });
}

/// Explicit paths and appearance keep fixtures independent of the user's
/// configuration and the settings portal. Theme directories are searched
/// in the supplied order; no implicit personal/system reads occur here.
pub fn loadFromPath(
    allocator: std.mem.Allocator,
    cfg_path: []const u8,
    appearance: Appearance,
    theme_dirs: []const []const u8,
) !?Colors {

    // 1 MiB cap. Real-world ghostty configs sit under 10 KB; the
    // ceiling is just to keep a runaway file from OOMing startup.
    // Hard-fatal `readToEndAlloc` made a too-big config block the
    // whole inheritance path with no recovery — degrade to "use VTE
    // defaults" instead so the panel still opens.
    const text = std.Io.Dir.cwd().readFileAlloc(platform.io(), cfg_path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return null,
        error.StreamTooLong => {
            std.debug.print("ghostty config: {s} exceeds 1 MiB cap; skipping inheritance\n", .{cfg_path});
            return null;
        },
        else => return err,
    };
    defer allocator.free(text);

    var colors = Colors{};
    errdefer colors.deinit(allocator);

    // Theme file forms the base layer. We parse it first, then the
    // main config so its keys win on conflict. `findThemeName`
    // returns a slice borrowing from `text`; we dupe it because the
    // theme-file load allocates and we don't want to entangle its
    // lifetime with the source buffer.
    if (findThemeName(text, appearance)) |name_borrow| {
        const name = try allocator.dupe(u8, name_borrow);
        defer allocator.free(name);
        if (try loadThemeFile(allocator, name, theme_dirs)) |theme_colors|
            colors = theme_colors;
    }

    // Main config overrides whatever the theme set.
    try parseInto(text, &colors, allocator);

    return colors;
}

// ─── Parser ──────────────────────────────────────────────────────────

/// Parse ghostty config text, overlaying onto `colors`. Existing
/// fields are overwritten only when a matching key is present in
/// `text`. Unknown keys are silently ignored — ghostty has hundreds
/// of keys we don't model, and warning on each would drown out the
/// useful diagnostics.
/// Trim an inline `# comment` tail off a config line. `#` is also a
/// hex-color sigil (`background = #1a1a1a`), so we only strip when
/// the `#` is followed by something that isn't a hex digit — i.e.
/// the `#` opens a comment rather than a color value. Matches
/// ghostty's own parser behavior. Returns the line without the
/// comment + any trailing whitespace.
fn stripInlineComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '#') continue;
        if (i + 1 < line.len) {
            const next = line[i + 1];
            const is_hex = (next >= '0' and next <= '9') or
                (next >= 'a' and next <= 'f') or
                (next >= 'A' and next <= 'F');
            if (is_hex) continue;
        }
        if (i == 0) return line[0..0];
        return std.mem.trimEnd(u8, line[0..i], " \t");
    }
    return line;
}

test "stripInlineComment: trailing comment removed" {
    try std.testing.expectEqualStrings("foo = bar", stripInlineComment("foo = bar # ignore me"));
}

test "stripInlineComment: hex color preserved" {
    try std.testing.expectEqualStrings("background = #1a2b3c", stripInlineComment("background = #1a2b3c"));
}

test "stripInlineComment: hex color + trailing comment" {
    try std.testing.expectEqualStrings(
        "background = #1a2b3c",
        stripInlineComment("background = #1a2b3c # warm tone"),
    );
}

test "stripInlineComment: no comment passes through" {
    try std.testing.expectEqualStrings("foo = bar", stripInlineComment("foo = bar"));
}

test "stripInlineComment: leading # stays leading" {
    // Leading # is a comment line (caller handles separately); we
    // return an empty slice so the trim-then-empty-check at the
    // caller skips the row.
    try std.testing.expectEqualStrings("", stripInlineComment("# whole line is a comment"));
}

pub fn parseInto(text: []const u8, colors: *Colors, allocator: std.mem.Allocator) !void {
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw| {
        const stripped = stripInlineComment(std.mem.trim(u8, raw, " \t\r"));
        const trimmed = std.mem.trim(u8, stripped, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const val = unquote(std.mem.trim(u8, trimmed[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "background")) {
            if (parseColor(val)) |c| colors.background = c;
        } else if (std.mem.eql(u8, key, "foreground")) {
            if (parseColor(val)) |c| colors.foreground = c;
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            if (parseColor(val)) |c| colors.cursor = c;
        } else if (std.mem.eql(u8, key, "palette")) {
            // Inner form: `N=#rrggbb`. N is 0..255 in ghostty; we only
            // model 0..15 (the ANSI primary palette). Higher indices
            // skipped silently.
            const inner_eq = std.mem.indexOfScalar(u8, val, '=') orelse continue;
            const idx_str = std.mem.trim(u8, val[0..inner_eq], " \t");
            const color_str = std.mem.trim(u8, val[inner_eq + 1 ..], " \t");
            const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue;
            if (idx >= 16) continue;
            if (parseColor(color_str)) |c| colors.palette[idx] = c;
        } else if (std.mem.eql(u8, key, "font-family")) {
            const family = try allocator.dupe(u8, val);
            if (colors.font_family) |s| allocator.free(s);
            colors.font_family = family;
        } else if (std.mem.eql(u8, key, "font-size")) {
            if (std.fmt.parseFloat(f64, val)) |v| {
                if (v > 0) colors.font_size = v;
            } else |_| {}
        }
        // `theme = ...` is handled by findThemeName up front; ignore
        // it on the data-pass so theme files referencing other themes
        // can't loop. (Theme files don't actually set theme = in the
        // wild, but explicit is better than implicit.)
    }
}

// ─── Theme resolution ────────────────────────────────────────────────

/// Walk `text` for `theme = X` and pick a variant by `appearance`.
/// Returns null when no `theme =` line exists. The slice borrows from
/// `text` — caller must `dupe` to extend lifetime.
fn findThemeName(text: []const u8, appearance: Appearance) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (!std.mem.eql(u8, key, "theme")) continue;
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        return pickThemeVariant(val, appearance);
    }
    return null;
}

/// `theme = X` → X. `theme = light:Day,dark:Night` → the matching
/// variant. Falls back to the raw spec on no match (so a misspelled
/// variant still resolves to *something* rather than null'ing the
/// theme entirely). Mirrors darwin's `theme/theme.zig::pickThemeName`.
pub fn pickThemeVariant(spec: []const u8, appearance: Appearance) []const u8 {
    if (std.mem.indexOfScalar(u8, spec, ',') == null and
        std.mem.indexOfScalar(u8, spec, ':') == null)
        return spec;

    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const variant = std.mem.trim(u8, t[0..colon], " \t");
        const name = std.mem.trim(u8, t[colon + 1 ..], " \t");
        const matches = switch (appearance) {
            .light => std.mem.eql(u8, variant, "light"),
            .dark => std.mem.eql(u8, variant, "dark"),
        };
        if (matches) return name;
    }
    return spec;
}

fn loadThemeFile(allocator: std.mem.Allocator, name: []const u8, theme_dirs: []const []const u8) !?Colors {
    // Reject names that could escape the themes/ directories. A
    // malicious ghostty config (shared dotfiles repo, copy-pasted from
    // a forum) with `theme = ../../../etc/passwd` would otherwise
    // cause djinn to open that file. Data doesn't leak (the file is
    // parsed as ghostty config and discarded), but it's a confused-
    // deputy pattern and triggers audit-loggable reads. Validation
    // covers the user-dir and system-dir branches uniformly so a
    // future fourth search path can't forget the check.
    if (!isSafeThemeName(name)) return null;

    for (theme_dirs) |dir| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        defer allocator.free(p);
        if (try tryLoadThemeAt(allocator, p)) |c| return c;
    }
    return null;
}

/// True when `name` is a plain ghostty theme name suitable for direct
/// concatenation under `themes/`. Rejects path separators (`/` and
/// `\`), parent-dir refs (`..` as a whole component), absolute paths
/// (leading `/`), names embedding NUL, leading dots (`.config` etc.
/// aren't themes), and the empty string. Ghostty's own theme names
/// in the wild are plain ASCII like `Dracula` / `gruvbox-dark`, so
/// the allowlist is narrow on purpose.
fn isSafeThemeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '.' or name[0] == '/') return false;
    if (std.mem.eql(u8, name, "..")) return false;
    for (name) |c| switch (c) {
        '/', '\\', 0 => return false,
        else => {},
    };
    return true;
}

fn tryLoadThemeAt(allocator: std.mem.Allocator, path: []const u8) !?Colors {
    const io = platform.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.IsDir => return null,
        else => return err,
    };
    defer file.close(io);

    // Refuse anything that isn't a regular file. A theme file
    // symlinked at `/dev/zero` would otherwise block startup on a
    // 1 MiB read; a fifo replacement between path resolution and
    // open would otherwise hang.
    const stat = file.stat(io) catch return null;
    if (stat.kind != .file) return null;

    // Same 1 MiB cap as the user config; degrade to "skip this
    // theme" instead of aborting startup when a runaway theme file
    // hits the ceiling.
    var reader = file.reader(io, &.{});
    const text = reader.interface.allocRemaining(allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.StreamTooLong => return null,
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    defer allocator.free(text);

    var colors = Colors{};
    errdefer colors.deinit(allocator);
    try parseInto(text, &colors, allocator);
    return colors;
}

/// Strip a matched leading/trailing `"…"` or `'…'` pair. Ghostty's
/// own parser allows quoting values whose contents contain commas or
/// shell-active characters (paths, multi-word font families). Without
/// stripping here, Pango ends up looking for a font family literally
/// named `"IosevkaTerm Nerd Font Mono"` (with the quote chars) and
/// substitutes silently.
fn unquote(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const first = s[0];
    const last = s[s.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\''))
        return s[1 .. s.len - 1];
    return s;
}

// ─── Color parsing ───────────────────────────────────────────────────

/// Accept the three forms ghostty's parser and djinn's own
/// `theme/theme.zig::parseColor` accept: `#rrggbb`, `rrggbb`,
/// `0xrrggbb`. Returns null on malformed input; ghostty also
/// supports `rgb:rr/gg/bb` and CSS color names but no theme file in
/// the wild uses them.
///
/// Public so `main_linux.zig` can re-use it for the djinn-config
/// `theme.background/foreground/cursor` hex fields — keeps the linux
/// path on one parser.
pub fn parseColor(s: []const u8) ?Rgb {
    var hex = s;
    if (std.mem.startsWith(u8, hex, "#")) hex = hex[1..];
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

// ─── Appearance detection (xdg-desktop-portal) ──────────────────────
//
// `org.freedesktop.portal.Settings.Read("org.freedesktop.appearance",
// "color-scheme")` returns a variant containing a u32:
//   0 = no preference  →  default dark
//   1 = prefer dark
//   2 = prefer light
//
// Sync DBus call — appearance is one-shot at startup, and the portal
// responds in microseconds when present. The TIMEOUT cap keeps a
// dead portal from blocking djinn launch; default-on-fail is `dark`.

const gdbus = @import("gdbus.zig");
const GVariantType = gdbus.GVariantType;
const GError = gdbus.GError;
const G_BUS_TYPE_SESSION = gdbus.G_BUS_TYPE_SESSION;
const G_DBUS_CALL_FLAGS_NONE = gdbus.G_DBUS_CALL_FLAGS_NONE;

/// GVariantType is internally just a nul-terminated DBus signature
/// string. Casting a static `[:0]const u8` to `*const GVariantType`
/// avoids the `g_variant_type_new` / `_free` allocator dance for the
/// fixed type checks we do here.
inline fn vt(comptime spec: [:0]const u8) *const GVariantType {
    return @ptrCast(spec.ptr);
}

const PORTAL_TIMEOUT_MS: c_int = 500;

/// Runtime appearance override set by `cycleAppearanceOverride`
/// (typically bound to Ctrl+Shift+T). `null` means "follow the
/// xdg-desktop-portal color-scheme setting" — the default. Not
/// persisted: a restart returns to system-follow, matching darwin's
/// `app.g.theme.override`. Module scope rather than per-Config
/// because the override is a runtime/session state, not a saved
/// preference.
var appearance_override: ?Appearance = null;

/// Cycle the appearance override and return the new state. Matches
/// darwin's `actionThemeToggle` shape: null → light → dark → null.
/// Callers re-invoke the theme apply chain after this so the new
/// variant of `theme = light:X,dark:Y` gets picked up — see
/// `keymap.zig::onThemeToggle` and main_linux's reapply hook.
pub fn cycleAppearanceOverride() ?Appearance {
    appearance_override = if (appearance_override) |cur| switch (cur) {
        .light => @as(?Appearance, .dark),
        .dark => null,
    } else .light;
    return appearance_override;
}

/// Read the current override without changing it. Useful for log
/// messages that want to surface "theme override → light/dark/
/// cleared" alongside the cycle action.
pub fn getAppearanceOverride() ?Appearance {
    return appearance_override;
}

pub fn detectAppearance() Appearance {
    if (builtin.os.tag != .linux) return .dark;

    // Override takes precedence over the portal probe so `Ctrl+Shift+T`
    // (theme_toggle) flips the variant deterministically regardless
    // of whether the user's desktop has portal-Settings or what its
    // color-scheme says.
    if (appearance_override) |o| return o;

    var err: ?*GError = null;
    const conn = gdbus.g_bus_get_sync(G_BUS_TYPE_SESSION, null, &err) orelse {
        if (err) |e| gdbus.g_error_free(e);
        return .dark;
    };
    defer gdbus.g_object_unref(conn);

    // Build `("org.freedesktop.appearance", "color-scheme")` tuple.
    // Builder-based construction matches `hotkey.zig` /
    // `tray.zig`'s style — `g_variant_builder_add_value` sinks each
    // floating child, `g_variant_builder_end` returns the (still
    // floating) tuple, and `g_dbus_connection_call_sync` consumes
    // that float when we hand it over. No `@constCast` over a stack
    // array of pointers needed.
    const tuple = gdbus.g_variant_builder_new(vt("(ss)"));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string("org.freedesktop.appearance"));
    gdbus.g_variant_builder_add_value(tuple, gdbus.g_variant_new_string("color-scheme"));
    const params = gdbus.g_variant_builder_end(tuple);
    gdbus.g_variant_builder_unref(tuple);

    err = null;
    const reply = gdbus.g_dbus_connection_call_sync(
        conn,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings",
        "Read",
        params,
        null, // reply_type: let GDBus infer
        G_DBUS_CALL_FLAGS_NONE,
        PORTAL_TIMEOUT_MS,
        null,
        &err,
    ) orelse {
        // Portal absent (bare wlroots / older systems) or method
        // missing; default-dark is a reasonable fallback.
        if (err) |e| gdbus.g_error_free(e);
        return .dark;
    };
    defer gdbus.g_variant_unref(reply);

    // Reply shape per spec: `(v<u>)` — tuple → variant → uint32.
    // KDE Plasma's portal (Frameworks ≤6.x) double-wraps to
    // `(v<v<u>>)` — Reads on most other namespaces are single-wrapped,
    // but `color-scheme` historically isn't. Loop through `v` layers
    // until we hit a non-variant type, then read it as uint32.
    var current = gdbus.g_variant_get_child_value(reply, 0);
    while (gdbus.g_variant_is_of_type(current, vt("v")) != 0) {
        const inner = gdbus.g_variant_get_variant(current);
        gdbus.g_variant_unref(current);
        current = inner;
    }
    defer gdbus.g_variant_unref(current);

    if (gdbus.g_variant_is_of_type(current, vt("u")) == 0) {
        // Portal returned something that isn't a uint32 after fully
        // unwrapping — unexpected, but fall back rather than abort.
        return .dark;
    }
    const value = gdbus.g_variant_get_uint32(current);
    return switch (value) {
        1 => .dark,
        2 => .light,
        else => .dark, // 0 = no preference; honor the terminal-default.
    };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "cycleAppearanceOverride: null → light → dark → null" {
    // The override is a module-level static; reset to null at the top
    // and bottom so other tests in the suite see the documented
    // default ("follow portal").
    appearance_override = null;
    defer appearance_override = null;

    try std.testing.expectEqual(@as(?Appearance, null), getAppearanceOverride());
    try std.testing.expectEqual(@as(?Appearance, .light), cycleAppearanceOverride());
    try std.testing.expectEqual(@as(?Appearance, .light), getAppearanceOverride());
    try std.testing.expectEqual(@as(?Appearance, .dark), cycleAppearanceOverride());
    try std.testing.expectEqual(@as(?Appearance, null), cycleAppearanceOverride());
}

test "parseColor: #rrggbb form" {
    const c = parseColor("#1a2b3c") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0x1a), c.r);
    try std.testing.expectEqual(@as(u8, 0x2b), c.g);
    try std.testing.expectEqual(@as(u8, 0x3c), c.b);
}

test "parseColor: rejects malformed" {
    try std.testing.expectEqual(@as(?Rgb, null), parseColor("#abc"));
    try std.testing.expectEqual(@as(?Rgb, null), parseColor("nothex!"));
    try std.testing.expectEqual(@as(?Rgb, null), parseColor(""));
}

test "pickThemeVariant: plain name" {
    try std.testing.expectEqualStrings("Dracula", pickThemeVariant("Dracula", .dark));
    try std.testing.expectEqualStrings("Dracula", pickThemeVariant("Dracula", .light));
}

test "pickThemeVariant: light/dark split" {
    try std.testing.expectEqualStrings("Day", pickThemeVariant("light:Day,dark:Night", .light));
    try std.testing.expectEqualStrings("Night", pickThemeVariant("light:Day,dark:Night", .dark));
}

test "pickThemeVariant: variants with spaces" {
    try std.testing.expectEqualStrings(
        "TokyoNight Storm",
        pickThemeVariant("light:TokyoNight Day,dark:TokyoNight Storm", .dark),
    );
}

test "parseInto: scalar colors" {
    var c = Colors{};
    defer c.deinit(std.testing.allocator);
    const text =
        \\# comment
        \\background = #1e1e2e
        \\foreground = #cdd6f4
        \\cursor-color = #f5e0dc
    ;
    try parseInto(text, &c, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0x1e), c.background.?.r);
    try std.testing.expectEqual(@as(u8, 0xcd), c.foreground.?.r);
    try std.testing.expectEqual(@as(u8, 0xf5), c.cursor.?.r);
}

test "parseInto: palette entries" {
    var c = Colors{};
    defer c.deinit(std.testing.allocator);
    const text =
        \\palette = 0=#000000
        \\palette = 1=#ff0000
        \\palette = 15=#ffffff
        \\palette = 200=#deadbe   # out of range — skipped
    ;
    try parseInto(text, &c, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0x00), c.palette[0].?.r);
    try std.testing.expectEqual(@as(u8, 0xff), c.palette[1].?.r);
    try std.testing.expectEqual(@as(u8, 0xff), c.palette[15].?.r);
    try std.testing.expect(c.palette[2] == null);
}

test "parseInto: font keys" {
    var c = Colors{};
    defer c.deinit(std.testing.allocator);
    const text =
        \\font-family = IosevkaTerm Nerd Font Mono
        \\font-size = 13
    ;
    try parseInto(text, &c, std.testing.allocator);
    try std.testing.expectEqualStrings("IosevkaTerm Nerd Font Mono", c.font_family.?);
    try std.testing.expectEqual(@as(f64, 13), c.font_size.?);
}

test "parseInto: unknown keys ignored, malformed lines skipped" {
    var c = Colors{};
    defer c.deinit(std.testing.allocator);
    const text =
        \\renderer = something
        \\not_a_kv_line
        \\background = bogus
        \\foreground = #aabbcc
    ;
    try parseInto(text, &c, std.testing.allocator);
    try std.testing.expect(c.background == null);
    try std.testing.expectEqual(@as(u8, 0xaa), c.foreground.?.r);
}

test "parseInto: quoted values are unwrapped" {
    var c = Colors{};
    defer c.deinit(std.testing.allocator);
    const text =
        \\font-family = "IosevkaTerm Nerd Font Mono"
        \\background = '#1e1e2e'
    ;
    try parseInto(text, &c, std.testing.allocator);
    try std.testing.expectEqualStrings("IosevkaTerm Nerd Font Mono", c.font_family.?);
    try std.testing.expectEqual(@as(u8, 0x1e), c.background.?.r);
}

test "parseInto: later font-family frees earlier" {
    var c = Colors{};
    defer c.deinit(std.testing.allocator);
    try parseInto("font-family = First", &c, std.testing.allocator);
    try parseInto("font-family = Second", &c, std.testing.allocator);
    try std.testing.expectEqualStrings("Second", c.font_family.?);
}

test "findThemeName: pure name" {
    try std.testing.expectEqualStrings(
        "Dracula",
        findThemeName("theme = Dracula\n", .dark) orelse return error.TestFailed,
    );
}

test "findThemeName: variant split picks active" {
    try std.testing.expectEqualStrings(
        "Day",
        findThemeName("theme = light:Day,dark:Night\n", .light) orelse return error.TestFailed,
    );
}

test "findThemeName: missing key returns null" {
    try std.testing.expectEqual(@as(?[]const u8, null), findThemeName("background = #fff\n", .dark));
}

test "Ghostty config native API compiles without reading personal files" {
    std.testing.refAllDecls(@This());
}

test "loadFromPath merges only injected temporary config and themes" {
    const a = std.testing.allocator;
    const io = platform.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "themes", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "config",
        .data = "theme = light:Day,dark:Night\nforeground = #ffffff\nfont-size = 15\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "themes/Night",
        .data = "background = #112233\nforeground = #000000\nfont-family = fixture-font\n",
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "config" });
    defer a.free(path);
    const themes = try std.fs.path.join(a, &.{ root, "themes" });
    defer a.free(themes);
    var colors = (try loadFromPath(a, path, .dark, &.{themes})).?;
    defer colors.deinit(a);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, colors.background.?);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, colors.foreground.?);
    try std.testing.expectEqualStrings("fixture-font", colors.font_family.?);
    try std.testing.expectEqual(@as(f64, 15), colors.font_size.?);
    try tmp.dir.deleteFile(io, "config");
    try std.testing.expectEqual(@as(?Colors, null), try loadFromPath(a, path, .light, &.{}));
}

test "isSafeThemeName: plain names accepted" {
    try std.testing.expect(isSafeThemeName("Dracula"));
    try std.testing.expect(isSafeThemeName("gruvbox-dark"));
    try std.testing.expect(isSafeThemeName("solarized_light"));
    try std.testing.expect(isSafeThemeName("Tokyo Night"));
}

test "isSafeThemeName: path traversal rejected" {
    try std.testing.expect(!isSafeThemeName(".."));
    try std.testing.expect(!isSafeThemeName("../etc/passwd"));
    try std.testing.expect(!isSafeThemeName("a/b"));
    try std.testing.expect(!isSafeThemeName("a\\b"));
    try std.testing.expect(!isSafeThemeName("/etc/passwd"));
}

test "isSafeThemeName: hidden + empty + null-byte rejected" {
    try std.testing.expect(!isSafeThemeName(""));
    try std.testing.expect(!isSafeThemeName(".hidden"));
    try std.testing.expect(!isSafeThemeName("name\x00rest"));
}
