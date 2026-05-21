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
/// alloc/init pair owed us. Parameter is `?*anyopaque` to accept both
/// the `Session.surface_host` slot (`*anyopaque`) and the `objc.c.id`
/// slots stashed on `app.g.{palette,cheatsheet,layout}.*_id` — `[*c]T`
/// coerces in via the C-pointer rules, but `*anyopaque` does not
/// coerce to `[*c]T`, so the wider type lives at the parameter
/// boundary and the `@ptrCast` to `objc.c.id` happens once here.
pub fn detach(view_id: ?*anyopaque) void {
    // `*anyopaque` nominally has alignment 1; `objc.c.id`
    // (`[*c]struct_objc_object`) wants pointer alignment. The
    // runtime alignment is fine — NSView pointers come from
    // `[NSView alloc]` which returns properly-aligned heap memory —
    // we just have to assert it past Zig's static check.
    const id: objc.c.id = @ptrCast(@alignCast(view_id));
    const view = objc.Object.fromId(id);
    view.msgSend(void, "removeFromSuperview", .{});
    view.msgSend(void, "release", .{});
}
