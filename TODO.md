# djinn TODO

State as of May 6, 2026. **0.1.0-alpha.1 cut**: signed `.app` bundle,
GitHub Actions CI + release workflow, branded `.icns`, MIT LICENSE +
NOTICES, multi-profile sessions, theme inheritance for `light:X,dark:Y`
specs, dim-priority semantics for `state.json` vs config.

djinn is a libghostty-surface host. ghostty owns the visible
terminal area end-to-end (PTY, render, scrollback, selection,
hyperlink hover, search, IME). djinn keeps panel chrome, MCP server,
agent state surface, hotkey, menubar, log pane, drag-drop,
find-overlay UI, an action keymap, a SessionManager, and a
multi-profile tab strip + Cmd+Shift+P palette switcher on top.

NSResponder coverage is complete (right / middle / hover / focus /
modifier-only / Y-flip / scroll precision / keyUp / pressureChange).
Clipboard write/read flows through ghostty's callbacks; system
appearance flips push to ghostty + reload its config from disk.
Cmd+Tab focus restoration on macOS 14+ is fixed via
`setHidesOnDeactivate:` + dropping `setFloatingPanel:1`.

Profile scripts (`profile.<name>.script = path`) let users construct
the agentic shell with arbitrary bash; the script `exec`s the agent
at the end, and djinn validates existence + execute-bit at startup.

`just dev-cert` installs a stable self-signed codesign identity in
the user's login keychain so every `install-app` keeps TCC grants
across rebuilds. Local iteration no longer needs `tccutil reset`.

## Open work — pick from here

### Per-profile env vars *(low priority — script subsumes)*

`profile.<name>.script` already lets users export env vars before
`exec`'ing the agent, so this is no longer blocking. Still nice to
have for declarative configs that don't want a shell layer:

```
profile.main.env.OPENAI_API_KEY = sk-...
```

Parse via `applyProfileKey` — when `field` starts with `env.`, append
to a `[]const struct { k: []const u8, v: []const u8 }` on the entry.
Spawn path: pass through to ghostty via `surface_config_s.env_*`
(`_count` + `_pairs` pattern in ghostty.h).

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

- `magnify:` — pinch-to-zoom font size. ghostty.app itself doesn't
  override this; would need a host-side accumulator over
  `event.magnification` deltas. Skip until users ask.
- `quickLook:` — three-finger-tap dictionary lookup over the
  selection. Needs CTFont attribute dict + NSAttributedString
  presentation. Mirror ghostty.app's `quickLook(with:)`
  (SurfaceView_AppKit.swift:1438) if this lands.

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

### TCC for distribution *(blocked on Developer ID signing)*

Local iteration is fixed via `just dev-cert`. For *redistribution*
(handing the bundle to another user), they'd hit the same cdhash
churn on each new release: TCC matches on certificate leaf hash, not
on the act of signing. Real fix for shipping: Developer ID
certificate + notarytool flow in `release.yml`. Needs paid Apple
Developer account ($99/yr) — out of scope for the alpha.

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

## Recently shipped — current session

### Theme reapply on panel show

- **AppKit suppresses `viewDidChangeEffectiveAppearance` for offscreen
  windows.** Light↔dark flip while the Quake panel is hidden left
  djinn chrome (tab strip, log pane, find chip, panel bg) stuck on
  the stale palette while ghostty's surface flipped on its own
  pipeline — visible mismatch on next show.
- **`Panel.show` now calls `reapplyThemeIfChanged`** before the
  redraw recursion. The existing `last_appearance == current_tag`
  guard inside `reapplyTheme` makes it a cheap no-op when nothing
  changed; only does work when system actually flipped since last
  reapply.

### Config-wiring sweep follow-ups

- **`wakeupStub` host_inited guard** — every other `host_storage`
  accessor checked `host_inited` first; the wakeup path didn't.
  A future caller skipping `setHost` in the startup path would
  dereference uninitialized memory on the first ghostty IO wakeup.
  Added the guard so the stub no-ops cleanly until `setHost`
  runs.
- **`dashToUnder` caller-supplied buffer** — replaced the
  module-level `static var buf[N]` workaround with a caller-passed
  buffer. The static-var idiom is Zig's way around no
  function-static locals, but slice escape across calls = clobber
  if any caller stores the result. No observable bug today (all
  call sites were synchronous), but the lifetime trap is now
  explicit at the type level.

### Restart current session / drop to shell

- **`restart_session` action** (Cmd+R) frees the active session's
  ghostty surface and re-binds a fresh one against the same
  `Session.surface_host` NSView. Survives "Process exited. Press
  any key to close." after a script-spawned child exits.
- **`shell_session` action** (Cmd+Shift+R) same path but overrides
  the command to `/bin/zsh` — escape hatch when the configured
  profile script is broken.
- **Dispatch on next main-queue turn after `surface_free`** —
  ghostty's IO mailbox needs a runloop cycle to unwind before the
  same NSView can host a new surface; doing it synchronously
  hangs the renderer.

### Config wiring + dead-code sweep

- **Wired six previously-dead settings**: `window-toggle-style`,
  `window-position`, `window-topmost`, `scrollback-size`,
  `bell-visual`, `mcp-enabled`. Each had been parsed but never
  consumed since the keys landed.
- **Window position is now a 9-grid** anchor
  (`{top,center,bottom}_{left,center,right}`) with optional per-axis
  manual override (`window-position-x` / `-y`) or an `X,Y` shorthand
  on `window-position`. NSScreen-native coords (origin bottom-left of
  the active screen, +Y up). The enum form clears any earlier manual
  coords, so the named anchor wins regardless of parse order.
- **`scrollback-size` is now `?u32`** — null = inherit ghostty's 10M
  default instead of clobbering it with djinn's historical 10K. The
  override flows through a tmp ghostty config file loaded after
  `~/.config/ghostty/config`.
- **`bell-visual` is a brief alpha dim** (→0.4 for 80ms) on RING_BELL.
  Restoration target is `expected_alpha`, tracked alongside
  `setBackgroundColor` so theme flips keep it accurate.
- **`mcp-enabled = false`** skips `McpServer.init`, the accept thread,
  and `~/.config/djinn/mcp.json` writeback — no stale endpoint
  pointing at a closed port after toggling off.
- **Removed truly-dead lines** from the default config template:
  `cursor-blink`, `cursor-style`, `render-backend`. None had parsers;
  all emitted "unknown key" warnings on startup.
- **Dropped unused fields**: `provider.args` (declared, never parsed,
  never read), `app.g.font_family` / `font_size` (written by
  `TerminalView.init`, never read; chrome reads `theme.font_*`
  directly via `Style.fromTheme`).
- **README config block** now lists option enums and value types
  inline; `.gitignore` covers `.direnv` + `zig-pkg`.

### Cmd+Tab focus restoration
- **`setHidesOnDeactivate:` for blur-hide** — replaces the
  cross-app-activate dance that fought macOS 14+'s throttle. djinn
  deactivates as a *consequence* of the user's target activating, so
  no cascade fires.
- **Drop `setFloatingPanel:1`** — floating panels keep app key state
  across cross-window focus shifts (tool-palette idiom), which
  prevented `windowDidResignKey` from firing on Cmd+Tab.
- **`Panel.hide` skips prev-app restore when user navigated away** —
  guard via `NSApp.isActive` (not `NSWorkspace.frontmostApplication`,
  which never reports an Accessory app as frontmost).

### Profile scripts
- **`profile.<name>.script`** points at an executable shell script;
  djinn passes the path to ghostty as the PTY command. Script must
  `exec` the agent at the end.
- Spawn precedence: `script > command > provider shortcut > /bin/zsh`.
- `SessionManager.resolveScript` expands `~/`, validates existence +
  execute bit; on failure logs a warning and falls through to the
  next layer.

### Chrome polish
- **Single border tone**: `chip.border = mix(bg, black, 0.2)`.
  Tracks ghostty's split-divider tone (sampled #151824 against
  #1a1b26 bg). All four host surfaces (find chip, log pane, tab
  strip, palette) use this token.
- **Chrome typography**: `chrome.chromeFont` returns the system UI
  font (San Francisco, medium weight). Caps at 13pt for log entries,
  12pt for chips so chrome stays subordinate to terminal output
  regardless of theme font size.
- **Layout chrome = surface bg, overlay chrome = chip bg**: tab strip
  + log pane fill `style.bg` (no seam against terminal column);
  find chip + palette switcher fill `chip.bg` (lifted, with 1px
  chip.border outline).
- **Per-group hairline divider in the log pane** (`─` × N) above
  each new-client header. Single-client streams stay clean.
- **Tab labels left-aligned** with 12pt inset — stable horizontal
  position across active/inactive font swaps.
- **Divider between terminal + log pane is now a transparent
  hit-target** — the prior white@5% fill produced a dark fringe
  next to the log pane's chip.border separator on translucent
  panels.

### Stable codesign identity
- **`scripts/dev-cert-create.sh`** generates a self-signed cert in
  login.keychain. OpenSSL `-legacy -macalg SHA1` PKCS12 (modern
  AES-256/SHA-256 fails macOS's `security import`).
- **`scripts/codesign-bundle.sh`** probes via `find-certificate`
  (`find-identity -v` filters self-signed even though codesign
  accepts them); falls back to ad-hoc on failure.
- `just dev-cert` recipe + README "Stable signing identity" section.
- TCC grants now persist across rebuilds — designated requirement
  stays constant (`identifier "..." and certificate leaf = H"..."`).

### CI fixes
- **`mlugg/setup-zig` v1 → v2** — v1 line ended at 1.2.2 and didn't
  recognise the newer Zig mirror tarball naming, breaking installs
  with cascading 503/404s.
- **Pin newest Xcode + probe `xcrun --find metal`** — runner's default
  `xcode-select` may point at an Xcode <15.3 that rejects
  `-downloadComponent`. Switch to `/Applications/Xcode_*.app | sort
  -V | tail -1` first, then probe; fallback to `-downloadComponent`
  works against the newer Xcode if the toolchain is genuinely
  missing.
- **`bundle` job** added to ci.yml — full distributable path
  (Metal compile, install_name_tool rpath, ad-hoc codesign,
  `--version` smoke) runs on every push, not just on tags.

### Bug fixes from review
- **`Panel.hide` Accessory-app guard** — see above.
- **NSObject leaks in chrome paint loops** — `appendStyled` (log
  pane) + `appendFindRun` / `updateSearchCountLabel` (find chip)
  allocated `NSMutableParagraphStyle` and `NSAttributedString`
  without `release`. Hot-path leak under streaming logs / find
  typing. Paired `defer release` after consumer takes its retain.
- **`resolveScript` double-free** — function-scope `errdefer
  allocator.free(expanded)` fired on later error AFTER `owned`
  already retained the pointer; outer init errdefer drained `owned`
  → double-free. Replaced with explicit `catch |e| { free; return
  e; }` at ownership-transfer point.
- **`codesign-bundle.sh` swallowed errors** — stderr was redirected
  to `/dev/null`, so failed signed-path runs silently fell to ad-hoc
  with no diagnostic. TCC stability goal silently unmet. Stderr now
  surfaces.

## Ghostty dependency boundary

djinn links the **full libghostty** (surface API).
`patches/ghostty-001-darwin-install.patch` +
`scripts/apply-ghostty-patch.sh` make `dep.artifact("ghostty")`
resolve on macOS; `scripts/build.sh` applies the patch and unsets
nix's Apple SDK env vars.

The `wakeup_cb` (`acd7280`) wires `ghostty_app_tick` on the main
queue — without it ghostty's IO mailbox events stall (child_exited,
OSC actions, render hints never fire).

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
  `tab_strip_separator_id`, `palette_view_id`. Per-session
  surface_host pointers live on `Session.surface_host`
  (`?*anyopaque`).
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
  more than once.
- **Accessory app + `NSWorkspace.frontmostApplication`** never
  reports djinn itself as frontmost — workspace tracks regular
  apps only. Use `NSApp.isActive` for "is djinn the active app"
  questions; use `NSWorkspace.frontmostApplication` only for
  "which OTHER app owns the menu bar".
- **`setFloatingPanel:1`** keeps the app's key window across
  cross-window focus shifts (tool-palette idiom). Fatal for
  Quake-drop UX: `windowDidResignKey` never fires on Cmd+Tab,
  so blur-driven hide never engages. Use `setLevel:` +
  collection behavior alone for visual on-top.
- **`setHidesOnDeactivate:`** is the right blur-hide knob on
  Accessory apps. It sidesteps the macOS 14+ cross-app activation
  throttle entirely — the user's target activates, djinn
  deactivates as a consequence, panel auto-hides. No cascade.
- **alloc/init from Zig is +1 retained**, period. There's no ARC
  bridging; every `alloc/init` needs a `release`. `defer
  obj.msgSend(void, "release", .{})` after the consumer takes
  its +1 retain is the idiomatic balance. Class factory methods
  (`stringWith…:`, `dictionaryWith…:`) return autoreleased
  objects and don't need an explicit release.
- **errdefer at function scope keeps firing for the whole
  function body.** Once ownership transfers (e.g. to an
  ArrayList), the errdefer becomes harmful — a later error in
  the same function fires the errdefer AND the caller's drain
  of the list → double-free. Use explicit `catch |e| { free;
  return e; }` at the ownership-transfer site instead of relying
  on errdefer past it.
- **Chrome design vocabulary**: layout chrome (tab strip, log
  pane, terminal column) shares `style.bg` — single continuous
  surface, only chrome cue is a 1px chip.border at the seam.
  Overlay chrome (find chip, palette switcher) uses
  `style.chip.bg` (lifted) + 1px chip.border outline + 4px
  corner radius — floats above the surface deliberately.
- **Border tone is theme-derived, not hardcoded**:
  `chip.border = mix(bg, black, 0.2)`. Tracks ghostty's
  split-divider hairline tone across all themes; pure-black mix
  is the only theme-invariant way to "go darker than bg by N%".
