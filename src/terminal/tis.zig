const std = @import("std");

// Text Input Source (TIS) — HIToolbox / Carbon. Used to discover the
// current keyboard input source so keyDownImpl can short-circuit
// NSTextInputContext.handleEvent: when the user is typing on a plain
// Latin layout with no IME composition active. Skipping AppKit's IME
// pipeline removes ~per-keypress Cocoa dispatch overhead on the hot
// path; CJK / dead-key composition stays correct because we only
// fast-path when both:
//
//   - input source ID starts with `com.apple.keylayout.` (excludes
//     `com.apple.inputmethod.*` for Korean / Japanese / Chinese), AND
//   - no marked text is active (caller-side check via g_preedit_len)
//
// Known limitation: Latin layouts that drive dead-key composition
// through AppKit (German, French, Spanish defaults) will lose dead
// keys under the fast-path. Refining the deny-list is a follow-up;
// US / ABC / Dvorak / Colemak — the common case — work as-is.

const cf = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

extern "c" fn TISCopyCurrentKeyboardInputSource() ?*anyopaque;
extern "c" fn TISGetInputSourceProperty(src: ?*anyopaque, key: ?*anyopaque) ?*anyopaque;
extern const kTISPropertyInputSourceID: ?*anyopaque;

extern "c" fn CFNotificationCenterGetDistributedCenter() ?*anyopaque;
extern "c" fn CFNotificationCenterAddObserver(
    center: ?*anyopaque,
    observer: ?*const anyopaque,
    callback: ?*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) void,
    name: ?*anyopaque,
    object: ?*const anyopaque,
    suspensionBehavior: c_int,
) void;

const cf_notification_suspension_deliver_immediately: c_int = 4;

/// Cached. `false` is the safe default — caller takes the slow path
/// (full NSTextInputContext.handleEvent: round-trip) until refresh()
/// confirms a Latin layout. install() runs refresh() once at startup.
var g_is_latin: bool = false;

pub fn isLatin() bool {
    return g_is_latin;
}

const latin_prefix = "com.apple.keylayout.";

fn refresh() void {
    const src = TISCopyCurrentKeyboardInputSource() orelse {
        g_is_latin = false;
        return;
    };
    defer cf.CFRelease(@ptrCast(src));

    const id_obj = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) orelse {
        g_is_latin = false;
        return;
    };
    // TIS returns a CFStringRef; `Get` semantics — do not release.
    const id_cf: cf.CFStringRef = @ptrCast(id_obj);

    var buf: [128]u8 = undefined;
    const ok = cf.CFStringGetCString(id_cf, &buf, buf.len, cf.kCFStringEncodingUTF8);
    if (ok == 0) {
        g_is_latin = false;
        return;
    }
    const id_str = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf)), 0);
    g_is_latin = std.mem.startsWith(u8, id_str, latin_prefix);
}

fn onInputSourceChanged(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: ?*const anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    refresh();
}

/// Read current source + register distributed-notification observer.
/// Idempotent — safe to call once at startup.
pub fn install() void {
    refresh();

    const center = CFNotificationCenterGetDistributedCenter() orelse return;
    // Notification posted by HIToolbox when the selected keyboard
    // input source changes (kTISNotifySelectedKeyboardInputSourceChanged).
    // Use the literal name string to avoid pulling the Carbon umbrella
    // header just for one constant pointer.
    const name = cf.CFStringCreateWithCString(
        null,
        "AppleSelectedInputSourcesChangedNotification",
        cf.kCFStringEncodingUTF8,
    ) orelse return;
    defer cf.CFRelease(@ptrCast(name));

    CFNotificationCenterAddObserver(
        center,
        null,
        onInputSourceChanged,
        @ptrCast(@constCast(name)),
        null,
        cf_notification_suspension_deliver_immediately,
    );
}
