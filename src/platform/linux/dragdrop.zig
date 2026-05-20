//! Drag-drop into the VTE terminal.
//!
//! Mirrors `src/terminal/view.zig`'s NSDraggingDestination wiring on
//! darwin: file paths get shell-quoted + space-separated and pasted
//! into the running shell so e.g. dragging `~/Downloads/spec.pdf`
//! over djinn produces `'~/Downloads/spec.pdf'` at the cursor, ready
//! for `cat`, `bat`, the `Read` MCP tool, etc.
//!
//! Implementation: attach a `GtkDropTarget` controller to the VTE
//! widget, accept `G_TYPE_STRING`. GTK 4 negotiates with the drag
//! source, picks the best matching MIME type from its offer set
//! (typically `text/uri-list` from file managers), and serializes
//! the value into a string — exactly the multi-line `file://` URI
//! list the spec calls for. We parse the lines, decode percent-
//! escapes, shell-quote what needs it, and feed via
//! `vte_terminal_paste_text` so the running TUI's bracketed-paste
//! mode (DEC 2004) wraps the input transparently when enabled.
//!
//! Image drops (screenshots, browser drags, Files preview thumbs)
//! land on a second `GtkDropTarget` registered for `GdkTexture`.
//! Both controllers are attached to the same widget; GTK iterates
//! them in attach order and picks the first whose accepted type the
//! drag offers. The string controller is added first so file-manager
//! drops (which offer both `text/uri-list` and a thumbnail bitmap)
//! resolve to paths rather than rasterized previews.
//!
//! For images we save the texture to `/tmp/djinn-drop-<128-bit hex>.png`
//! via `gdk_texture_save_to_png` and paste the path. Darwin's
//! `tryDropImage` in `terminal/view.zig` mirrors this. A random
//! suffix keeps a cooperating local process from pre-positioning a
//! symlink at the path between create and write. `main_linux.zig`
//! runs the reaper at startup AND on a 30-minute `g_timeout_add`
//! cadence so /tmp doesn't accumulate temps either across launches
//! (startup pass) or within a long-running session (periodic pass).

const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk.zig");

const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
const gpointer = gtk.gpointer;
const gboolean = gtk.gboolean;

// ─── GTK4 / Gdk extern types ─────────────────────────────────────────

const GtkDropTarget = opaque {};
const GtkEventController = opaque {};
const GValue = opaque {};
const GdkTexture = opaque {};
const GObject = opaque {};
const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

// ─── GTypes ──────────────────────────────────────────────────────────
//
// GLib fundamental type IDs are ABI-stable since GLib 1.0:
//   G_TYPE_FUNDAMENTAL_SHIFT = 2
//   G_TYPE_STRING = G_TYPE_MAKE_FUNDAMENTAL(16) = 16 << 2 = 64
// Hardcoded rather than fetched at runtime so we avoid an extra
// extern. If GLib ever renumbers (it won't — too much ABI breakage),
// the build will fail loudly at the gtk_drop_target_new call.

const G_TYPE_STRING: c_ulong = 16 << 2;

// GdkDragAction. Bitfield — COPY is the only one we accept.
const GdkDragAction = c_int;
const GDK_ACTION_COPY: GdkDragAction = 1;

// ─── GTK / Gdk extern surface ────────────────────────────────────────

extern "c" fn gtk_drop_target_new(type: c_ulong, actions: GdkDragAction) *GtkDropTarget;
const gtk_widget_add_controller = gtk.gtk_widget_add_controller;
extern "c" fn g_value_get_string(value: *const GValue) ?[*:0]const u8;
extern "c" fn g_value_get_object(value: *const GValue) ?*GObject;
/// GdkTexture isn't a fundamental GType (those are baked into GLib);
/// the runtime ID is assigned the first time the type is registered
/// with the type system, which has happened by the time gtk_init
/// returns. Call this to get the live ID and feed it to
/// gtk_drop_target_new.
extern "c" fn gdk_texture_get_type() c_ulong;
/// Synchronous PNG encode + write. Returns nonzero on success.
extern "c" fn gdk_texture_save_to_png(texture: *GdkTexture, filename: [*:0]const u8) c_int;

// Shared GLib signal connect lives in gtk.zig.
const g_signal_connect_data = gtk.g_signal_connect_data;

// GObject data-slot accessors. Used to mark "attach already ran on
// this widget" so a duplicate call (refactor accident) no-ops instead
// of silently stacking controllers. Cleared automatically when the
// widget is destroyed because GObject teardown wipes its data table.
extern "c" fn g_object_set_data(object: *GObject, key: [*:0]const u8, data: ?*anyopaque) void;
extern "c" fn g_object_get_data(object: *GObject, key: [*:0]const u8) ?*anyopaque;

const ATTACH_MARKER_KEY: [*:0]const u8 = "djinn-dragdrop-attached";

// ─── VTE paste ───────────────────────────────────────────────────────

/// VTE's clipboard-paste path: applies bracketed-paste (DEC 2004)
/// wrapping when the running TUI requested it, filters control
/// characters except newline/tab, and writes the result to the PTY.
/// `vte_terminal_feed_child` would bypass all of that; paste_text
/// matches what a user pressing Ctrl-Shift-V would invoke.
extern "c" fn vte_terminal_paste_text(terminal: *VteTerminal, text: [*:0]const u8) void;

// ─── Public surface ──────────────────────────────────────────────────

/// Install drop targets on `widget`. The widget retains the
/// controllers; no separate handle is returned because there's
/// nothing the caller would do with them beyond letting them live for
/// the widget's lifetime.
///
/// Order matters: the string target is attached first so a drag from
/// a file manager (which typically offers `text/uri-list` AND a
/// thumbnail `image/png`) resolves to the path rather than the
/// preview bitmap. The image target catches screenshots, browser
/// drags, and Photos-style sources where there's no path.
///
/// Idempotent: a second call on the same widget no-ops via a
/// GObject-data marker. `gtk_widget_add_controller` accepts duplicate
/// controllers silently, so without this guard a refactor that
/// double-routes through `Terminal.open` would stack four targets
/// (two string + two image) and double-fire on every drop. The
/// marker auto-clears when the widget is destroyed.
pub fn attach(widget: *GtkWidget) void {
    const obj: *GObject = @ptrCast(widget);
    if (g_object_get_data(obj, ATTACH_MARKER_KEY) != null) return;
    g_object_set_data(obj, ATTACH_MARKER_KEY, @ptrFromInt(1));
    attachString(widget);
    attachImage(widget);
}

fn attachString(widget: *GtkWidget) void {
    const target = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_COPY);
    _ = g_signal_connect_data(
        @ptrCast(target),
        "drop",
        @ptrCast(&onDrop),
        @ptrCast(widget),
        null,
        0,
    );
    gtk_widget_add_controller(widget, @ptrCast(target));
}

fn attachImage(widget: *GtkWidget) void {
    const target = gtk_drop_target_new(gdk_texture_get_type(), GDK_ACTION_COPY);
    _ = g_signal_connect_data(
        @ptrCast(target),
        "drop",
        @ptrCast(&onDropImage),
        @ptrCast(widget),
        null,
        0,
    );
    gtk_widget_add_controller(widget, @ptrCast(target));
}

// ─── Drop handler ────────────────────────────────────────────────────

fn onDrop(
    _: *GtkDropTarget,
    value: *const GValue,
    _: f64,
    _: f64,
    user_data: gpointer,
) callconv(.c) gboolean {
    const widget: *GtkWidget = @ptrCast(@alignCast(user_data orelse return 0));
    const terminal: *VteTerminal = @ptrCast(widget);

    const text_z = g_value_get_string(value) orelse return 0;
    const text = std.mem.span(text_z);
    if (text.len == 0) return 0;

    var buf: [4096]u8 = undefined;
    const formatted = formatPayload(&buf, text) catch return 0;
    if (formatted.len == 0) return 0;

    // formatted is buf[0..len] without a NUL — but our buffer has
    // space + we wrote up to formatted.len bytes. The caller's
    // formatPayload guarantees len < buf.len so we can append the NUL.
    buf[formatted.len] = 0;
    const paste_z: [*:0]const u8 = @ptrCast(buf[0..formatted.len :0].ptr);
    vte_terminal_paste_text(terminal, paste_z);
    return 1;
}

/// GdkTexture drop: save to /tmp as PNG, paste the path so the
/// running shell or agent can read it back. Mirrors darwin's
/// `tryDropImage` in `terminal/view.zig` — same naming scheme, same
/// reaper invariant (entries older than 1h cleaned up at startup).
fn onDropImage(
    _: *GtkDropTarget,
    value: *const GValue,
    _: f64,
    _: f64,
    user_data: gpointer,
) callconv(.c) gboolean {
    const widget: *GtkWidget = @ptrCast(@alignCast(user_data orelse return 0));
    const terminal: *VteTerminal = @ptrCast(widget);

    const obj = g_value_get_object(value) orelse return 0;
    const texture: *GdkTexture = @ptrCast(obj);

    // 128 bits of randomness → unpredictable filename. The /tmp file
    // can't pre-exist (collision space is 2^128) and a local attacker
    // can't pre-position a symlink at the path between when we choose
    // it and when gdk_texture_save_to_png opens it — same security
    // posture mkstemp(3) provides via a different mechanism. See
    // tryDropImage in terminal/view.zig:457 for the darwin sibling.
    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var hex_buf: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_buf, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/djinn-drop-{s}.png",
        .{hex_buf[0..]},
    ) catch return 0;

    if (gdk_texture_save_to_png(texture, path.ptr) == 0) {
        std.debug.print("dragdrop: gdk_texture_save_to_png failed for {s}\n", .{path});
        return 0;
    }

    // Paths under /tmp don't contain shell metacharacters (we choose
    // them ourselves), so no quoting needed. paste_text handles
    // bracketed-paste wrapping if the running TUI enabled it.
    vte_terminal_paste_text(terminal, path.ptr);
    return 1;
}

// ─── Payload formatting ──────────────────────────────────────────────

/// Build the text to paste into the terminal. Accepts either a
/// newline-separated URI list (`text/uri-list` representation —
/// `file:///path` per line) or a plain string (URL from browser,
/// snippet from a text editor). URIs get path-decoded and shell-
/// quoted; non-URI text passes through unchanged so dragging a URL
/// from Firefox lands as `https://...` at the cursor.
fn formatPayload(out: []u8, text: []const u8) ![]const u8 {
    // Quick test: if no line starts with "file:", treat the whole
    // payload as plain text. Saves the parse and lets URL drags
    // through unchanged.
    if (std.mem.indexOf(u8, text, "file:") == null) {
        const n = @min(out.len - 1, text.len);
        @memcpy(out[0..n], text[0..n]);
        return out[0..n];
    }

    var len: usize = 0;
    var emitted: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        // text/uri-list uses CRLF terminators per RFC 2483. We split
        // on '\n' and trim a trailing '\r' here so both LF and CRLF
        // sources work without a second tokenize pass.
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        // Skip comment lines per RFC 2483.
        if (line[0] == '#') continue;

        if (emitted > 0) {
            if (len >= out.len - 1) return out[0..len];
            out[len] = ' ';
            len += 1;
        }

        if (std.mem.startsWith(u8, line, "file://")) {
            const path_encoded = line[7..];
            // Some sources include a host between file:// and the
            // path, e.g. "file://localhost/tmp/foo". Strip the host
            // segment up to the next '/' so we get the bare path.
            const path_start = if (std.mem.indexOfScalar(u8, path_encoded, '/')) |i|
                if (path_encoded[0] == '/') 0 else i
            else
                0;
            const bare_path = path_encoded[path_start..];
            // A bare `file://` with no path (or `file://host` with no
            // trailing `/`) produces an empty path; emitting `''` to
            // the shell is worse than a no-op — it noises the prompt
            // with an empty positional arg. Skip the entry.
            if (bare_path.len == 0) continue;
            const written = writeShellQuoted(out[len..], bare_path, true) catch |err| {
                std.debug.print("dragdrop: payload truncated at {d} entries: {}\n", .{ emitted, err });
                return out[0..len];
            };
            len += written;
        } else {
            // Non-file URI on the same drop: paste as-is.
            const written = writeShellQuoted(out[len..], line, false) catch |err| {
                std.debug.print("dragdrop: payload truncated at {d} entries: {}\n", .{ emitted, err });
                return out[0..len];
            };
            len += written;
        }
        emitted += 1;
    }
    return out[0..len];
}

/// Write `value` into `dest`, optionally percent-decoding (for file
/// URIs) and shell-quoting when the result contains characters a
/// POSIX shell would interpret. Returns bytes written. Errors when
/// `dest` is too small to hold the formatted result.
fn writeShellQuoted(dest: []u8, value: []const u8, percent_decode: bool) !usize {
    var decoded_buf: [4096]u8 = undefined;
    const decoded = if (percent_decode)
        percentDecode(&decoded_buf, value)
    else
        value;

    const needs_quote = std.mem.indexOfAny(u8, decoded, " \t'\"\\$&|;()<>*?#`!\n") != null;
    if (!needs_quote) {
        if (decoded.len > dest.len) return error.NoSpace;
        @memcpy(dest[0..decoded.len], decoded);
        return decoded.len;
    }

    // Single-quote wrap with POSIX '\'' dance for embedded quotes.
    var n: usize = 0;
    if (n >= dest.len) return error.NoSpace;
    dest[n] = '\'';
    n += 1;
    for (decoded) |c| {
        if (c == '\'') {
            const seq = "'\\''";
            for (seq) |sc| {
                if (n >= dest.len) return error.NoSpace;
                dest[n] = sc;
                n += 1;
            }
        } else {
            if (n >= dest.len) return error.NoSpace;
            dest[n] = c;
            n += 1;
        }
    }
    if (n >= dest.len) return error.NoSpace;
    dest[n] = '\'';
    n += 1;
    return n;
}

/// Decode percent-encoded bytes (RFC 3986). Invalid escapes pass
/// through as the literal `%` plus following bytes, matching
/// browsers' "be liberal in what you accept" decode of malformed
/// URIs. Truncates at buffer end without error — caller's buffers
/// are sized generously.
fn percentDecode(dest: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (n >= dest.len) break;
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = hexDigit(src[i + 1]);
            const lo = hexDigit(src[i + 2]);
            if (hi != null and lo != null) {
                dest[n] = (hi.? << 4) | lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        dest[n] = src[i];
        n += 1;
        i += 1;
    }
    return dest[0..n];
}

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "formatPayload pastes plain text unchanged" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]u8 = undefined;
    const out = try formatPayload(&buf, "https://example.com/x");
    try std.testing.expectEqualStrings("https://example.com/x", out);
}

test "formatPayload decodes a single file URI" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]u8 = undefined;
    const out = try formatPayload(&buf, "file:///tmp/foo.txt\r\n");
    try std.testing.expectEqualStrings("/tmp/foo.txt", out);
}

test "formatPayload shell-quotes paths with spaces" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]u8 = undefined;
    const out = try formatPayload(&buf, "file:///home/me/My%20Docs/spec.pdf");
    try std.testing.expectEqualStrings("'/home/me/My Docs/spec.pdf'", out);
}

test "formatPayload joins multiple URIs with spaces" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]u8 = undefined;
    const out = try formatPayload(&buf, "file:///a\nfile:///b\n");
    try std.testing.expectEqualStrings("/a /b", out);
}

test "formatPayload escapes embedded single quotes" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]u8 = undefined;
    const out = try formatPayload(&buf, "file:///tmp/it%27s.txt");
    try std.testing.expectEqualStrings("'/tmp/it'\\''s.txt'", out);
}

test "formatPayload ignores comment lines and blanks" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]u8 = undefined;
    const out = try formatPayload(
        &buf,
        "# a comment\nfile:///x\n\nfile:///y\n",
    );
    try std.testing.expectEqualStrings("/x /y", out);
}

test "percentDecode passes malformed escapes through" {
    if (builtin.os.tag != .linux) return;
    var buf: [64]u8 = undefined;
    const out = percentDecode(&buf, "ab%ZZcd%2");
    try std.testing.expectEqualStrings("ab%ZZcd%2", out);
}
