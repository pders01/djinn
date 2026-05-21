//! Tiny helper for the alloc/release pairing on NSView subviews
//! djinn creates at runtime.
//!
//! Cocoa convention: `[NSView alloc].initWithFrame:` returns an object
//! with a +1 retain count owned by the caller. `addSubview:` retains
//! again, but `removeFromSuperview` drops only AppKit's retain — the
//! caller's +1 is still ours. Forgetting the release leaks the view
//! (and any subviews / CAMetalLayer / backing store hanging off it)
//! on every teardown.
//!
//! Long-lived subviews (panel content, log pane, terminal column) hit
//! this on program-exit only and the leak is bounded by ~1 alloc.
//! Subviews that come and go at runtime (tab strip on profile add /
//! remove, palette switcher on open / close, cheatsheet overlay,
//! per-session surface_host) leak per cycle and accumulate.
//!
//! Audited callers (2026-05-21):
//!   - `session/live.zig:removeSessionLive` — surface_host detach.
//!   - `session/live.zig:ensureTabStripVisible(false)` — strip detach.
//!   - `session/palette.zig:close` — palette overlay detach.
//!   - `session/cheatsheet.zig:close` — cheatsheet overlay detach.
//!
//! New runtime-allocated NSView subviews should route through
//! `detach` instead of calling `removeFromSuperview` directly so the
//! retain balance stays explicit at the call site.

const objc = @import("objc");

/// Remove `view_id` from its superview and release the +1 retain the
/// alloc/init pair owed us. Caller passes the raw NSView id (the
/// `?*anyopaque` slot we tend to stash on `Session.surface_host` /
/// `app.g.palette.view_id` / etc).
pub fn detach(view_id: objc.c.id) void {
    const view = objc.Object.fromId(view_id);
    view.msgSend(void, "removeFromSuperview", .{});
    view.msgSend(void, "release", .{});
}
