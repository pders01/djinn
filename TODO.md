# djinn TODO

State as of May 4, 2026. **0.1.0-alpha.1 cut**: signed `.app` bundle,
GitHub Actions CI + release workflow, branded `.icns`, MIT LICENSE +
NOTICES, multi-profile sessions, theme inheritance for `light:X,dark:Y`
specs, dim-priority semantics for `state.json` vs config.

Tier-5 surface migration is **complete**: djinn is a libghostty-surface
host. ghostty owns the visible terminal area end-to-end (PTY, render,
scrollback, selection, hyperlink hover, search, IME). djinn keeps panel
chrome, MCP server, agent state surface, hotkey, menubar, log pane,
drag-drop, find-overlay UI, an action keymap, a SessionManager, and a
multi-profile tab strip + Cmd+Shift+P palette switcher on top.

The post-alpha **input bridge audit** is also done: every NSResponder
method djinn needs is now overridden + forwarded to ghostty (right /
middle / hover / focus / modifier-only / Y-flip / scroll precision /
keyUp / pressureChange). Clipboard write/read wired through ghostty's
callbacks (`df6923f`); system appearance flips push through to
ghostty (`96f2197`). Remaining audit residue is `magnify:` and
`quickLook:` — neither user-blocking.

One **known regression** carries over: Cmd+Tab away from djinn lands
on the wrong app (the pre-djinn frontmost, not the user's pick). Four
attempts at fixing it landed this session and none worked; suspected
cause is the macOS 14+ `activateWithOptions:` throttle. See "Cmd+Tab
focus restoration" under Open work for the chronology.

## Open work — pick from here

### Per-profile env vars *(deferred from v1 spec)*

Config grammar already accepts `profile.<name>.<field>` with fields
{provider, command, cwd, title}. Add an env namespace:

```
profile.main.env.OPENAI_API_KEY = sk-...
profile.main.env.ANTHROPIC_API_KEY = sk-...
```

Parse via `applyProfileKey` — when `field` starts with `env.`, append
to a `[]const struct { k: []const u8, v: []const u8 }` on the entry.
Spawn path: pass through to ghostty via `surface_config_s.env_*`
(check ghostty.h for the exact slot — there's a `_count` + `_pairs`
pattern for repeating fields).

### Cmd+Tab focus restoration *(unresolved — macOS 14+ activation throttle)*

Goal: when user Cmd+Tabs away from djinn (with `hide_on_blur`
enabled), djinn slides offscreen and the user lands on the app
they picked, not on whatever was frontmost before djinn appeared.

Currently broken on macOS 14+ (verified on 26.x). Suspected root
cause: `NSRunningApplication.activateWithOptions:` is throttled
to user-gesture only, so any `activateAppByPid` call we make is
silently dropped. macOS's own deactivation cascade (Accessory app
loses last visible window → falls back to "previous regular app")
runs uncontested and picks the pre-djinn frontmost.

What we tried this session (commits `c51587b 139b2ee bc5e129 0106a9f`):

1. Skip `activateAppByPid(prev_app_pid)` on the blur path —
   no help; cascade still picks prev app.
2. Defer `hideForBlur` via `dispatch_async_f` so it runs after
   Cmd+Tab resolves — no help.
3. Capture `currentFrontmostPid` *after* Cmd+Tab resolves +
   re-activate it explicitly — no help (activate throttled).
4. Skip `orderOut:` on the blur path; just slide offscreen and
   leave the panel in the window list to suppress the
   deactivation cascade — still doesn't restore right app per
   user testing.

Where to look next:

- `NSWorkspace.openApplicationAtURL:configuration:completionHandler:`
  with `activates: true` may bypass the throttle since it's a
  workspace-level call, not per-app.
- `[NSApp hide:nil]` (NSApplication-level hide) might let macOS
  pick a sensible "next" without the cascade rule kicking in;
  worth comparing the macOS-native cmd+H behavior.
- Check whether `frontmostApplication` is even reading the right
  value mid-Cmd+Tab. If it's stale / lagged, our re-activate
  target is wrong upstream of the throttle.
- See ghostty.app's `Ghostty.QuickTerminalController` for how
  upstream handles this — they hide the quick terminal on blur
  and the right app stays focused, so there's a working pattern
  in the same OS family to mine.

`hide_on_blur` users currently get the wrong app on Cmd+Tab. The
explicit-toggle path (Cmd+\ twice, or hotkey toggle) still works
correctly — it uses `prev_app_pid` capture + `orderOut`.

### Dynamic profile creation *(deferred — needs config writeback)*

Currently profiles are file-defined. A `Cmd+Shift+N → New profile`
overlay would let users add a profile at runtime, but persisting it
requires writing back to `~/.config/djinn/config` without clobbering
comments / formatting. Either:

1. Append `profile.<name>.*` lines to the bottom of the file (simplest,
   preserves comments above).
2. Build a structure-preserving editor — read line-by-line, find the
   profile section, insert in place.

Pick (1) for v1 if this lands. The palette-switcher UX from `ab9b18e`
is the natural place to surface a "+ New profile…" affordance.

### Lower-priority NSResponder gaps *(audit residue)*

Surfaced by the post-alpha input bridge audit; `keyUp:` +
`pressureChange:` shipped in `078aa9c`. Remaining:

- `magnify:` — pinch-to-zoom font size. ghostty.app itself
  doesn't override this on macOS; would have to invent the host
  side (accumulator over `event.magnification` deltas, threshold
  before firing `increase_font_size:1` / `decrease_font_size:1`).
  Skip until users ask.
- `quickLook:` — three-finger-tap dictionary lookup over the
  selection. Needs CTFont attribute dict + NSAttributedString
  presentation chain; ghostty exposes
  `ghostty_surface_quicklook_word` + `ghostty_surface_quicklook_font`
  but the macOS-side popover assembly is non-trivial. Mirror
  ghostty.app's `quickLook(with:)` (SurfaceView_AppKit.swift:1438)
  if this lands.

### Per-call log expansion *(deferred — speculative)*

Tool calls collapse to a one-line summary, click expands to args +
result. Today's `djinn_log` carries only `message` + `level`; nothing
structured to expand. Path:

1. New MCP tool (`djinn_tool_call` with `tool_name` / `args` / `result`)
   or extend `djinn_log` with optional structured payload.
2. Extend `LogEntry` (`state.zig`) with `kind: enum { simple,
   tool_call }`.
3. log_view: per-entry NSView (instead of one shared NSTextStorage)
   so each row carries its own click handler + collapse state.

Step 3 is expensive. Worth it only if MCP side actually grows
tool-call telemetry.

### Animated log row insertion *(deferred — bad cost/value)*

CALayer fade-in on new rows. Conflicts with scroll-to-end (animation
+ autoscroll fight) and depends on the per-row NSView refactor
above. Revisit only if per-call expansion lands.

### Sleep / wake verification *(manual)*

Surface child behavior post-system-sleep is untested. Should be
ghostty's problem (we don't own the PTY or render pump), but worth
opening the panel after a sleep cycle. No automation path.

### TCC churn *(blocked on Developer ID signing)*

Every `install-app` rebuild burns Accessibility + PostEvent grants
because the cdhash changes. Workaround: `just tcc-reset` (or `just
deploy` which chains it). Real fix: Developer ID certificate +
notarytool flow in `release.yml`. Needs paid Apple Developer account
($99/yr) — out of scope for the alpha.

### Pure-nix package build *(blocked on Metal Toolchain access)*

`packages.default` attempted but the nix builder can't reach the
Metal Toolchain (Apple ships it through cryptexd at
`/var/run/com.apple.security.cryptexd/...`, invisible to the build
sandbox even with `__noChroot = true`). Workaround: `apps.*` runners
delegate to host-side `zig build`. Real fix: ghostty ships pre-built
`.metallib` OR nixpkgs adopts the Metal Toolchain as a fetched dep.

### Dispatch table coverage *(decision logged)*

~50 ghostty action handlers stubbed (`stub("…")` returning false).
Mostly window-manager actions (new_window, new_tab, toggle_fullscreen)
that don't apply to a Quake-drop panel. **Skip** — listed so nobody
re-litigates.

## Recently shipped — this session

### Visible profile UI
- **Tab strip** (`9752269`) — DjinnTabStrip subclass paints one chip
  per profile inline, no per-tab NSView; click maps x → idx →
  `activateSession(idx)`. Auto-hides for single-profile setups.
- **Palette switcher** (`ab9b18e`) — Cmd+Shift+P modal overlay,
  type-to-filter, Up/Down to move, Return to switch, Esc to dismiss.
  Owns input via `app.g.palette_mode` (same idiom as `find_mode`).
- **Active-profile indicator** (`94bdc63`) — dropdown subtitle
  appends " · {profile.label}" when more than one profile exists;
  refreshes on every `activateSession`.

### Input bridge — Tier-5 audit fixes
- **Font zoom** (`ed8ae89`) — Cmd++ / Cmd+- / Cmd+0 forward to
  ghostty as `increase_font_size:1` etc.; previously mutated only
  host-side `app.g.font_size` so the surface kept boot size.
- **Mouse Y-flip + scroll mods** (`d6adf03`) — `mouse_pos` now
  sends `frame.height - local.y` (ghostty wants top-down);
  `scroll_mods` byte encodes precision + momentum so trackpad
  pixel deltas don't get treated as line counts.
- **Right + middle mouse** (`bee065b`) — register `rightMouse*`
  + `otherMouse*`, factor through `forwardMouseButton` /
  `forwardMousePos` helpers. Mouse-tracking apps (tmux, vim, htop)
  see secondary buttons.
- **Focus state** (`6a474f5`) — override `becomeFirstResponder` /
  `resignFirstResponder` to call `surfaceSetFocus`. Affects cursor
  blink + focus-event reports (`\e[I` / `\e[O`).
- **flagsChanged** (`1c660d9`) — modifier-only press/release
  forwarded via `ghostty_surface_key`; required for Cmd-hover
  hyperlink detection. Mirrors ghostty.app's side-specific
  NX_DEVICER*KEYMASK logic.
- **Hover** (`0e93bf2`) — NSTrackingArea registered with
  `.mouseEnteredAndExited | .mouseMoved | .inVisibleRect |
  .activeAlways`. `mouseEntered` re-pushes pos; `mouseExited`
  sends (-1, -1) only when no button is held.
- **Occlusion** (`1f26a27`) — Panel.show/hide call
  `surfaceSetOcclusion(true/false)` so the surface throttles
  CADisplayLink while the panel is offscreen.

### Panel UX fixes
- **Blur-hide split + deferred hide** (`c51587b 139b2ee bc5e129
  0106a9f`) — chain of attempts at the Cmd+Tab focus-restoration
  bug. All four landed but the bug is still unresolved on macOS
  14+; see "Cmd+Tab focus restoration" under Open work for the
  full chronology and what to try next.
- **NSNotificationCenter observer guarded** (`ff92da9`) — comment
  claimed setHideOnBlur was idempotent but every config reload
  re-added the observer. Add `g_blur_observer_registered` flag.
- **Theme override survives reload** (`58dfa95`) — `App.init`
  layered `writeAppearanceThemeOverride` before finalize but
  `reloadConfigFromDisk` skipped it; dual-theme users reverted to
  LIGHT on every config save. Mirror init's path.

### Theme + clipboard
- **System appearance pushed to ghostty** (`96f2197`) — closes
  the runtime appearance change loop. `viewDidChangeEffectiveAppearance`
  → `reapplyTheme` now also calls `appSetColorScheme` +
  `reloadConfigFromDisk`, so dual-theme palettes flip with the
  system instead of staying frozen at boot.
- **Cmd+C / OSC 52 clipboard wired** (`df6923f`) —
  `writeClipboardStub` was a no-op so ghostty's `copy_to_clipboard`
  action discarded the bytes; Cmd+C from djinn looked broken. Push
  the `text/plain` content array to NSPasteboard via
  `setString:forType:`. Read side wired symmetrically for OSC 52.

### Input bridge — extra coverage
- **keyUp + pressureChange** (`078aa9c`) — Kitty Keyboard Protocol
  full-mode key releases + force-touch pressure both reach the
  surface now. `magnify:` + `quickLook:` deferred (see Open work).

## Tier-5 ship notes (kept for context)

The migration commits + the gnarly bits worth remembering:

### Step 7 — PTY ownership (`797cad9`)
`surface_config.command` owns the child. Pty.spawn gated on backend,
then dropped entirely in step 10. Provider override (`claude`,
`codex`, …) flows in as a NUL-terminated argv[0] heap-duped to C.

### Step 8 — host action handlers (`81972ff`)
8 ghostty action callbacks gain real host work: desktop_notification
→ Notifier, mouse_shape → NSCursor, mouse_visibility → NSCursor
hide/unhide, mouse_over_link → pointing hand, secure_input →
EnableSecureEventInput, set_title / set_tab_title → logged, pwd
→ logged.

### Step 9 — config bridging (`6931e15`)
`theme.resolve` queries the live `ghostty_config_t` via
`ghostty_config_get` instead of re-parsing `~/.config/ghostty/config`.
Same Config the surface uses.

### Step 10 — retire CG/Metal renderer + vt parser (-4344 LOC)
Stage A: `render/atlas|metal|scene.zig` deleted (~1500 LOC).
Stage B: `drawRectImpl` + glyph caches + prewarm + flushGlyphRun
deleted. `pty.zig` + `terminal.zig` (vt-static wrapper) deleted.
view.zig: 2879 → 1578.

### Critical fix — `wakeup_cb` (`acd7280`)
Wires `ghostty_app_tick` on the main queue. Without it ghostty's IO
mailbox events stall (child_exited, OSC actions, render hints never
fire).

## Ghostty dependency boundary

djinn links the **full libghostty** (surface API). vt-static is gone.
`patches/ghostty-001-darwin-install.patch` +
`scripts/apply-ghostty-patch.sh` make `dep.artifact("ghostty")`
resolve on macOS; `scripts/build.sh` applies the patch and unsets
nix's Apple SDK env vars.

## Style / code-health (kept current)

- Zig 0.15 quirks: `memory/djinn_zig_015_pitfalls.md`.
- Single `@cImport` per C header — Zig duplicates opaque types
  across modules. AppState uses `?*anyopaque` slots for
  `ghostty_surface` + `ghostty_config` to keep ghostty.h's cImport
  out of `app.zig` + `theme.zig`.
- `dispatch_object_t` is a transparent union — declare via
  `?*anyopaque` extern.
- NSSound is main-thread-only — afplay subprocess for non-main
  callers.
- `ghostty_config_get` `@alignCast`s caller's pointer to the source
  field's type. Passing the wrong-size slot writes only the lower
  bytes (f64 for f32 → upper half zero) OR panics on alignment
  (f32 for f64). **Use `configF32` for f32 fields, `configF64` for
  f64; `configColor` / `configPalette` for structs.**
- **Action callbacks fire synchronously inside
  `performBindingAction`.** Handlers must not re-emit the binding
  they're handling — recurse to stack overflow.
- **Borderless NSPanel + NSTextField + ghostty surface** doesn't
  compose into a working field editor. Use host-owned input via
  keyDownImpl + a host buffer instead. Find overlay + palette
  switcher both use this idiom.
- **CALayer-backed views with custom layouts** don't reliably honor
  `setHidden` for visibility toggling when ghostty's CAMetalLayer
  drives its own CADisplayLink. Use frame-to-zero for full hide;
  setHidden works for the surface_host swap (no layout recompute).
- **Stash key NSView pointers on AppState** instead of indexing
  `container.subviews[idx]`. Slots: `surface_host_id`,
  `divider_view_id`, `search_field_id`, `tab_strip_id`,
  `palette_view_id`. Per-session surface_host pointers live on
  `Session.surface_host` (`?*anyopaque`).
- **NSTextFieldCell does not vertically center.** Subclass + override
  `drawInteriorWithFrame:inView:` (see `DjinnChipCell` in view.zig).
- **`acceptsFirstMouse:` YES on borderless-panel drag controls.**
  Without it the first click goes to window-activation hit-test and
  the drag never starts (`DjinnDivider`).
- **`std.os.linux.*` is wrong on darwin.** Compiles but returns
  junk for syscall wrappers. Use `std.posix` or `std.c`.
- **`Config.load` propagates errors.** Don't swallow open / read
  failures as a default `Config{}` — atomic-write rename gaps blip
  the file briefly, and the silent-default substitution clobbers
  every running setting.
- **State.json complements config dims**, doesn't override. Optional
  fields on `WindowConfig` track "user pinned this explicitly" vs
  "fall through to state.json or default."
- **ghostty's `theme = light:X,dark:Y` resolution** uses
  `_conditional_state` inside ghostty. No public C API to set it
  pre-finalize, so djinn peeks the user's ghostty config + writes
  a tmp `theme = <variant>` loaded before finalize to override.
  **Both `App.init` and `reloadConfigFromDisk` apply this** —
  diverging breaks dual-theme users on every config save.
- **Provider shortcut match is case-insensitive.** Config values are
  user-typed (`provider = Claude` works); config KEYS are still
  strict-lowercase.
- **NSResponder method coverage matters.** Each missing override on
  TerminalView = one silently-dropped terminal feature (right-click
  in tmux, Cmd-hover hyperlinks, focus reports, etc.). Audit
  against ghostty.app's `SurfaceView_AppKit.swift` when adding new
  input paths.
- **Mouse Y is bottom-up in NSView, top-down in ghostty.** Convert
  at the boundary via `frame.size.height - local.y`. Same fix
  pattern as `firstRectForCharacterRange:`.
- **`ghostty_input_scroll_mods_t` is a packed byte.** ghostty.h
  calls it `int` because C can't express the layout; bit 0 =
  precision, bits 1-3 = momentum enum. Passing 0 means "non-precise
  scroll, no momentum" → trackpad pixel deltas treated as line
  counts.
- **Idempotency comments are review fuel.** When a comment promises
  "registers on first call only" but the code unconditionally
  registers, the bug stays latent until something triggers the path
  more than once. Look for the second trigger (FSEvent reload here)
  to estimate severity.

## Memory bank

- `djinn_direction.md` — product thesis
- `djinn_v0_problems.md` — what we ripped out and why
- `djinn_rewrite_plan.md` — phase-by-phase plan
- `djinn_dev_shell.md` — flake quirks
- `djinn_zig_015_pitfalls.md` — fcntl, posix.O packed struct
- `djinn_shell_default.md` — never trust $SHELL from a dev shell
- `djinn_nsview_layer_backing.md` — drawRect must always paint full
  area on modern macOS (note: drawRect retired in step 10; kept for
  historical context)
- `djinn_theme_autoswitch.md` — needs `theme = light:X,dark:Y` form
- `djinn_cold_start.md` — cold-start performance map
- `djinn_ghostty_full_lib_patch.md` — patch + script
