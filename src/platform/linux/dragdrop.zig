//! GTK drop controllers, scoped to their VTE widget. Text is validated and
//! shell-quoted before VTE's bracketed-paste-aware API; never synthesize keys.
const std = @import("std");
const gtk = @import("gtk.zig");
const GtkWidget = gtk.GtkWidget;
const VteTerminal = gtk.VteTerminal;
const GtkDropTarget = opaque {};
const GValue = opaque {};
const GdkTexture = opaque {};
const GBytes = opaque {};
const GObject = opaque {};
const GdkFileList = opaque {};
const GFile = opaque {};
const GSList = extern struct { data: ?*anyopaque, next: ?*GSList };
extern "c" fn gdk_file_list_get_type() c_ulong;
extern "c" fn gdk_file_list_get_files(*GdkFileList) ?*GSList;
extern "c" fn g_value_get_boxed(*const GValue) ?*anyopaque;
extern "c" fn g_file_is_native(*GFile) gtk.gboolean;
extern "c" fn g_file_get_path(*GFile) ?[*:0]u8;
extern "c" fn g_file_get_uri(*GFile) ?[*:0]u8;
extern "c" fn g_free(?*anyopaque) void;
extern "c" fn gtk_drop_target_new(c_ulong, c_int) *GtkDropTarget;
extern "c" fn g_value_get_string(*const GValue) ?[*:0]const u8;
extern "c" fn g_value_get_object(*const GValue) ?*GObject;
extern "c" fn gdk_texture_get_type() c_ulong;
extern "c" fn gdk_texture_save_to_png_bytes(*GdkTexture) *GBytes;
extern "c" fn g_bytes_get_data(*GBytes, *usize) ?[*]const u8;
extern "c" fn g_bytes_unref(*GBytes) void;
extern "c" fn g_object_set_data(*GObject, [*:0]const u8, ?*anyopaque) void;
extern "c" fn g_object_get_data(*GObject, [*:0]const u8) ?*anyopaque;
extern "c" fn vte_terminal_paste_text(*VteTerminal, [*:0]const u8) void;
extern "c" fn mkstemps([*:0]u8, c_int) c_int;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn close(c_int) c_int;
extern "c" fn unlink([*:0]const u8) c_int;

const marker = "djinn-dragdrop-attached";
pub fn attach(widget: *GtkWidget) void {
    const obj: *GObject = @ptrCast(widget);
    if (g_object_get_data(obj, marker) != null) return;
    g_object_set_data(obj, marker, @ptrFromInt(1));
    const text = gtk_drop_target_new(16 << 2, 1);
    _ = gtk.g_signal_connect_data(@ptrCast(text), "drop", @ptrCast(&onDrop), widget, null, 0);
    gtk.gtk_widget_add_controller(widget, @ptrCast(text));
    // File managers advertise text/uri-list, converted by GDK to this boxed
    // list rather than G_TYPE_STRING. Keep files, plain text and images apart.
    const files = gtk_drop_target_new(gdk_file_list_get_type(), 1);
    _ = gtk.g_signal_connect_data(@ptrCast(files), "drop", @ptrCast(&onDropFiles), widget, null, 0);
    gtk.gtk_widget_add_controller(widget, @ptrCast(files));
    const image = gtk_drop_target_new(gdk_texture_get_type(), 1);
    _ = gtk.g_signal_connect_data(@ptrCast(image), "drop", @ptrCast(&onDropImage), widget, null, 0);
    gtk.gtk_widget_add_controller(widget, @ptrCast(image));
}

fn onDrop(_: *GtkDropTarget, value: *const GValue, _: f64, _: f64, data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const widget: *GtkWidget = @ptrCast(@alignCast(data orelse return 0));
    const z = g_value_get_string(value) orelse return 0;
    const text = std.mem.span(z);
    if (text.len == 0) return 0;
    var buf: [4096]u8 = undefined;
    const formatted = formatPayload(&buf, text) catch return 0;
    if (formatted.len == 0) return 0;
    buf[formatted.len] = 0;
    vte_terminal_paste_text(@ptrCast(widget), buf[0..formatted.len :0].ptr);
    return 1;
}

fn onDropFiles(_: *GtkDropTarget, value: *const GValue, _: f64, _: f64, data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const widget: *GtkWidget = @ptrCast(@alignCast(data orelse return 0));
    const files: *GdkFileList = @ptrCast(@alignCast(g_value_get_boxed(value) orelse return 0));
    var node = gdk_file_list_get_files(files);
    var buf: [4096]u8 = undefined;
    var payload = FilePayload{ .out = &buf };
    while (node) |item| : (node = item.next) {
        const file: *GFile = @ptrCast(@alignCast(item.data orelse return 0));
        if (g_file_is_native(file) == 0) return 0;
        const path = g_file_get_path(file) orelse return 0;
        defer g_free(@ptrCast(path));
        const uri = g_file_get_uri(file) orelse return 0;
        defer g_free(@ptrCast(uri));
        // Both strings are GIO-owned allocations. The URI check rejects remote
        // authorities too; quote the decoded local path exactly once.
        payload.append(std.mem.span(path), std.mem.span(uri)) catch return 0;
    }
    const formatted = payload.finish() catch return 0;
    vte_terminal_paste_text(@ptrCast(widget), formatted.ptr);
    return 1;
}

fn onDropImage(_: *GtkDropTarget, value: *const GValue, _: f64, _: f64, data: gtk.gpointer) callconv(.c) gtk.gboolean {
    const widget: *GtkWidget = @ptrCast(@alignCast(data orelse return 0));
    const obj = g_value_get_object(value) orelse return 0;
    const bytes = gdk_texture_save_to_png_bytes(@ptrCast(obj));
    defer g_bytes_unref(bytes);
    var len: usize = 0;
    const png = g_bytes_get_data(bytes, &len) orelse return 0;
    if (len == 0 or len > 64 * 1024 * 1024) return 0;
    // Atomically create a mode-0600 file. Encode to bytes and write through
    // that SAME descriptor; never re-open a guessed /tmp pathname for writing.
    const path = "/tmp/djinn-drop-XXXXXX.png".*;
    var path_z: [path.len:0]u8 = undefined;
    @memcpy(&path_z, &path);
    path_z[path.len] = 0;
    const fd = mkstemps(&path_z, 4);
    if (fd < 0) return 0;
    var complete = false;
    defer if (!complete) {
        _ = unlink(&path_z);
    };
    var n: usize = 0;
    while (n < len) {
        const result = write(fd, png + n, len - n);
        if (result <= 0) {
            if (result < 0 and std.c.errno(result) == .INTR) continue;
            _ = close(fd);
            return 0;
        }
        n += @intCast(result);
    }
    if (close(fd) != 0) return 0;
    complete = true;
    vte_terminal_paste_text(@ptrCast(widget), &path_z);
    return 1;
}

fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var it = (std.unicode.Utf8View.initUnchecked(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    }
    return true;
}

fn localUriPath(uri: []const u8) ![]const u8 {
    if (!validText(uri) or !std.mem.startsWith(u8, uri, "file://")) return error.InvalidUri;
    var encoded = uri[7..];
    if (std.mem.startsWith(u8, encoded, "localhost/")) encoded = encoded[9..];
    if (encoded.len == 0 or encoded[0] != '/') return error.InvalidUri;
    return encoded;
}

/// Only finish exposes a pasteable payload. Any invalid/oversized member
/// poisons the entire list, even when earlier paths were already formatted.
const FilePayload = struct {
    out: []u8,
    len: usize = 0,
    input_bytes: usize = 0,
    count: usize = 0,
    rejected: bool = false,

    fn append(self: *FilePayload, path: []const u8, uri: []const u8) !void {
        errdefer self.rejected = true;
        if (self.rejected) return error.Rejected;
        if (uri.len > 4096 or path.len > 4096 - self.input_bytes) return error.TooLarge;
        _ = try localUriPath(uri);
        if (path.len == 0 or path[0] != '/' or !validText(path)) return error.InvalidText;
        if (self.out.len == 0) return error.NoSpace;
        const dest = self.out[0 .. self.out.len - 1];
        if (self.count != 0) {
            if (self.len == dest.len) return error.NoSpace;
            dest[self.len] = ' ';
            self.len += 1;
        }
        self.len += try writeShellQuoted(dest[self.len..], path, false);
        self.input_bytes += path.len;
        self.count += 1;
    }

    fn finish(self: *FilePayload) ![:0]const u8 {
        if (self.rejected or self.count == 0) return error.Rejected;
        self.out[self.len] = 0;
        return self.out[0..self.len :0];
    }
};

/// All-or-nothing: reserve the sentinel and never paste a truncated quote,
/// incomplete UTF-8 sequence, decoded control byte, or mixed remote URI list.
fn formatPayload(out: []u8, text: []const u8) ![]const u8 {
    if (out.len == 0) return error.NoSpace;
    const dest = out[0 .. out.len - 1];
    if (text.len > 4096 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    if (std.mem.indexOf(u8, text, "file:") == null) {
        const n = try writeShellQuoted(dest, text, false);
        return out[0..n];
    }
    var len: usize = 0;
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Only local absolute paths, not file://remote/share or file:relative.
        const encoded = try localUriPath(line);
        if (emitted != 0) {
            if (len == dest.len) return error.NoSpace;
            dest[len] = ' ';
            len += 1;
        }
        len += try writeShellQuoted(dest[len..], encoded, true);
        emitted += 1;
    }
    return out[0..len];
}

fn writeShellQuoted(dest: []u8, value: []const u8, decode: bool) !usize {
    var decoded_buf: [4096]u8 = undefined;
    const decoded = if (decode) try percentDecode(&decoded_buf, value) else value;
    if (!validText(decoded)) return error.InvalidText;
    var quote = decoded.len == 0;
    for (decoded) |c| {
        // A whitelist also catches shell expansions missed by metacharacter
        // lists, e.g. '~', '{...}', and unicode bytes (quoted conservatively).
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_/@%+=:.,-", c) == null) quote = true;
    }
    if (!quote) {
        if (decoded.len > dest.len) return error.NoSpace;
        @memcpy(dest[0..decoded.len], decoded);
        return decoded.len;
    }
    var n: usize = 1;
    if (dest.len < 2) return error.NoSpace;
    dest[0] = '\'';
    for (decoded) |c| {
        const seq: []const u8 = if (c == '\'') "'\\''" else &.{c};
        if (seq.len > dest.len - n) return error.NoSpace;
        @memcpy(dest[n..][0..seq.len], seq);
        n += seq.len;
    }
    if (n == dest.len) return error.NoSpace;
    dest[n] = '\'';
    return n + 1;
}
fn percentDecode(dest: []u8, src: []const u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (n == dest.len) return error.NoSpace;
        if (src[i] == '%' and i + 2 < src.len) {
            if (hexDigit(src[i + 1])) |hi| {
                if (hexDigit(src[i + 2])) |lo| {
                    dest[n] = hi << 4 | lo;
                    n += 1;
                    i += 3;
                    continue;
                }
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

test "file list formats multiple decoded local paths without double decoding" {
    var buf: [256]u8 = undefined;
    var payload = FilePayload{ .out = &buf };
    try payload.append("/tmp/My Docs/it's.txt", "file:///tmp/My%20Docs/it%27s.txt");
    try payload.append("/tmp/%20literal", "file://localhost/tmp/%2520literal");
    try std.testing.expectEqualStrings("'/tmp/My Docs/it'\\''s.txt' /tmp/%20literal", try payload.finish());
}

test "file list rejects entire mixed remote invalid or oversized payload" {
    const invalid = [_]struct { path: []const u8, uri: []const u8 }{
        .{ .path = "/remote", .uri = "file://remote/remote" },
        .{ .path = "/remote", .uri = "sftp://host/remote" },
        .{ .path = "relative", .uri = "file:///relative" },
        .{ .path = "/bad\x00path", .uri = "file:///bad%00path" },
        .{ .path = "/bad\npath", .uri = "file:///bad%0Apath" },
        .{ .path = "/bad\xff", .uri = "file:///bad%FF" },
        .{ .path = "/bad\xc2\x85", .uri = "file:///bad%C2%85" },
    };
    for (invalid) |item| {
        var buf: [256]u8 = undefined;
        var payload = FilePayload{ .out = &buf };
        try payload.append("/safe", "file:///safe");
        if (payload.append(item.path, item.uri)) |_| return error.ExpectedRejection else |_| {}
        try std.testing.expectError(error.Rejected, payload.finish());
    }
    var tiny: [10]u8 = undefined;
    var payload = FilePayload{ .out = &tiny };
    try payload.append("/safe", "file:///safe");
    try std.testing.expectError(error.NoSpace, payload.append("/has spaces", "file:///has%20spaces"));
    try std.testing.expectError(error.Rejected, payload.finish());
    const huge: [4097]u8 = @splat('a');
    var large: [8192]u8 = undefined;
    var oversized = FilePayload{ .out = &large };
    try std.testing.expectError(error.TooLarge, oversized.append(&huge, "file:///huge"));
    try std.testing.expectError(error.Rejected, oversized.finish());
    var empty = FilePayload{ .out = &tiny };
    try std.testing.expectError(error.Rejected, empty.finish());
}

test "formatPayload pastes plain text unchanged" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/x", try formatPayload(&buf, "https://example.com/x"));
}
test "formatPayload decodes a single file URI" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/foo.txt", try formatPayload(&buf, "file:///tmp/foo.txt\r\n"));
}
test "formatPayload shell-quotes paths with spaces" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("'/home/me/My Docs/spec.pdf'", try formatPayload(&buf, "file:///home/me/My%20Docs/spec.pdf"));
}
test "formatPayload joins multiple URIs with spaces" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/a /b", try formatPayload(&buf, "file:///a\nfile:///b\n"));
}
test "formatPayload escapes embedded single quotes" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("'/tmp/it'\\''s.txt'", try formatPayload(&buf, "file:///tmp/it%27s.txt"));
}
test "formatPayload ignores comment lines and blanks" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/x /y", try formatPayload(&buf, "# a comment\nfile:///x\n\nfile:///y\n"));
}
test "percentDecode passes malformed escapes through" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ab%ZZcd%2", try percentDecode(&buf, "ab%ZZcd%2"));
}
test "drops reject binary controls remote URI and truncation without paste" {
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "file:///tmp/a%00b", "file:///tmp/a%0Ab", "file:///tmp/a%1Bb", "file:///tmp/a%FF", "echo hi\nexit", "\xc2\x85", "\xff" }) |input| {
        try std.testing.expectError(error.InvalidText, formatPayload(&buf, input));
    }
    try std.testing.expectError(error.InvalidUri, formatPayload(&buf, "file://remote/a"));
    try std.testing.expectError(error.InvalidUri, formatPayload(&buf, "file:///a\nhttps://example.com"));
    var tiny: [5]u8 = undefined;
    try std.testing.expectError(error.NoSpace, formatPayload(&tiny, "file:///a%20b"));
    try std.testing.expectEqualStrings("/tmp/x", try formatPayload(&buf, "file://localhost/tmp/x"));
    try std.testing.expectEqualStrings("'~/{a,b}'", try formatPayload(&buf, "~/{a,b}"));
    try std.testing.expectEqualStrings("'é'", try formatPayload(&buf, "é"));
}
