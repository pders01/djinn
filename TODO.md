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

### Post-refactor leftovers *(low priority — view.zig is no longer a god-module)*

Module split + AppState grouping wave landed (commits `1c62051`
through `d49ba5a`). Below is what remains, ranked by ROI.

1. **`view.applyLogLayout` + `checkResize` → `window/layout.zig`**
   `divider.zig` currently back-imports `view.applyLogLayout` for the
   drag-resize reflow. Moving `applyLogLayout` (+ its `checkResize`
   helper) into `window/layout.zig` — already home to `buildContainer`
   + `computeLogWidth` — drops the cyclic edge. Make `checkResize`
   pub on view.zig, layout calls it back. ~120 LOC moved.

2. **`bindGhosttySurface` per-session arena**
   Today every `restartActiveSession` dupeZ-leaks cmd + cwd. Per-session
   `std.heap.ArenaAllocator` freed in `removeSessionLive` would cap the
   leak at "active sessions × current spawn args". Cheap; well-bounded
   to `ghostty/surface_lifecycle.zig`.

3. **Tests for find / palette key handlers**
   `terminal/find.zig` `handleKey` and `session/palette.zig` filter
   logic are pure state machines on `app.g.find.*` / `app.g.palette.*`.
   Same testing ROI as the keymap unit tests — exercise needle
   manipulation, prefix-match scoring, selection-cycling without
   spinning Cocoa.

4. **Drag-drop callbacks → `terminal/dragdrop.zig`** *(~150 LOC)*
   `draggingEnteredImpl` + `performDragOperationImpl` + `tryDropImage`
   form a self-contained NSDraggingDestination surface inside view.zig.
   No responder-chain coupling. Extractable when next change touches
   drag handling.

5. **Theme reapply → `terminal/theme_apply.zig`** *(~150 LOC)*
   `reapplyTheme` + `reapplyThemeIfChanged` + `reloadTheme` cross
   chrome + log_view + tab_strip + find overlay; centralizing the
   "reskin everything" path makes the fan-out explicit. Worth doing
   when adding any new chrome surface that reskins on appearance flip.

6. **`RetainedView` ownership helper** *(NSObject manual ref-count)*
   `removeSessionLive` calls `release` to balance the +1 from
   `[NSView alloc]`. Open question: which other paths take alloc'd
   views to a place where `removeFromSuperview` doesn't drop the last
   retain? A small `RetainedView` wrapper struct that pairs alloc +
   manual release would catch new occurrences at the type level.

None are urgent. Each addresses real friction; the codebase no longer
has a god-module at the center, so prioritize features over more
extraction.

## Recently shipped — current session

### Architecture wave: god-module split + AppState grouping + low-hanging fixes
*(commits `1c62051` → `d49ba5a`, 18 commits, build + tests green throughout)*

Driven by the architectural assessment in the same session. Each
commit independently revertible; per-step build + test green.

**Security / robustness (3 commits):**
- **MCP token compare constant-time** (`src/mcp/server.zig`).
  `std.mem.eql` short-circuits and leaks position to a local timing
  observer; replaced with byte-folding `constantTimeEql`. Loopback-
  only, but the right correctness baseline.
- **MCP accept-loop backoff 1ms→200ms** with reset on success.
  Persistent `accept()` failure (fd exhaustion, kernel hiccup)
  previously busy-looped at ~100% CPU.
- **Reconcile remove buffer heap-sized** to current session count.
  Stack `[32]usize` cap silently truncated diffs at 32 entries.
- **`hostWarn` fans config-reload warnings to the agent log pane**
  in addition to stderr. `.app` users (no Console.app open) now see
  restart-required + reconcile-failure messages on screen.

**view.zig god-module split (5 modules, 1057 LOC pulled out):**
- `terminal/keymap.zig` (154 LOC) — `Action` struct, mod constants,
  `dispatch`, `matchIndex`, `rebind`. **+7 unit tests** for mask
  logic, mods disambiguation on shared keycodes, ignored non-target
  modifier bits, rebind-by-name. First tests for the user input
  layer.
- `terminal/find.zig` (398 LOC) — find overlay UI, NSTextField
  setup, `DjinnChipCell` class, `handleKey` / `actionOpen/Next/Prev`.
  Plus the `forwardBindingAction` helper duplicated locally to
  avoid back-importing view.zig.
- `terminal/font.zig` (190 LOC) — CoreText resolution + cell
  metrics. Owns its own `cg` cImport scope.
- `terminal/divider.zig` (106 LOC) — `DjinnDivider` class +
  drag-resize handlers + `width` constant.
- `terminal/ime.zig` (209 LOC) — 11 NSTextInputClient impls +
  preedit buffer + composition state. `view.keyDownImpl` /
  `flagsChangedImpl` now gate on `ime.preedit_len` /
  `ime.current_keydown` / `ime.handled_during_interpret`.

**main.zig over-bridging split (3 modules, 496 LOC pulled out):**
- `session/live.zig` (249 LOC) — `reconcileProfiles`,
  `addSessionLive`, `removeSessionLive`, `ensureTabStripVisible`.
  Hot-config-reload glue; `main.hostWarn` made pub so `live.zig` +
  future modules can fan warnings to the log pane.
- `window/layout.zig` (109 LOC) — `buildContainer` +
  `computeLogWidth`. NSSplitView's auto-layout glitches inside
  NSVisualEffectView during live resize, so the explicit-frame
  layout math lives here.
- `ghostty/surface_lifecycle.zig` (241 LOC) — `activateSession`,
  `restartActiveSession`, `restartSurfaceCallback`,
  `bindGhosttySurface`, `RestartCtx`, `isShell`. view.zig +
  tab_strip.zig + palette.zig + live.zig now reach the lifecycle
  module directly instead of round-tripping through main.zig.

**AppState field-sprawl regrouping (7 commits, 8 substructs):**
50+ flat fields collapsed into named substructs. Each field group
has obvious shared concern + lifetime. Top-level pointers
(`allocator`, `config`, `notifier`, `hotkey`, `tool_table`,
`session_manager`) stayed flat — single pointer with no peer state.
- `app.g.find.*` — find_mode, query_buf/len, total, selected, field_id
- `app.g.palette.*` — same pattern for the Cmd+Shift+P switcher
- `app.g.ghostty.*` — app, surface, config (the opaque-handle trio)
- `app.g.layout.*` — container_id, surface_host_id, divider_view_id,
  tab_strip_id, tab_strip_separator_id (the container subview tree)
- `app.g.term.*` — view_id, font, cell_w/h, baseline, padding_x/y,
  bg_alpha (the terminal view's glyph-metric state)
- `app.g.agent.*` — state, menubar, log_view, last_state, tick_count
- `app.g.theme.*` — chrome_style, last_appearance
- `app.g.window.*` — panel, hide_on_blur, resize_handler

**Net impact:**
- view.zig: 2202 → 1360 LOC (−38%)
- main.zig: 1262 → 766 LOC (−39%)
- app.zig: 180 flat fields → 219 LOC of grouped substructs
- 8 new modules under terminal/, session/, window/, ghostty/
- 7 keymap unit tests added (was: 0 for input layer)
- module-to-module direct imports replace main.zig back-import hub

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
