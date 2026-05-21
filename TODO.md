# djinn TODO

State as of May 21, 2026. **0.1.0-alpha.1 cut**: signed `.app` bundle,
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

### Roadmap from UX review (2026-05-11)

Full review in conversation; consolidated tier list below. Friction
themes — most cleared during the mid-May feature pass, see the
"Recently shipped" log for the commit map:

- No first-run flow; user reads 200-line README before hotkey works.
- MCP endpoint rotates per launch → re-paste into every project.
- `djinn_attention` is one-way; user must context-switch to terminal.
- ~~Log pane is fire-and-forget~~ ✅ filter chip, copy entry, level
  pills, per-client color, sticky attentions.
- ~~Multi-client confusion~~ ✅ nicknames + mute + color-coded
  client name in header.
- ~~Notification spam from `djinn_progress`~~ ✅ rate-limit per
  (client, kind) + per-state gates suppress chatter by default.
- ~~No keyboard discovery (`Cmd+?` cheatsheet absent)~~ ✅
  `session/cheatsheet.zig` overlay (Cmd+Shift+. after rebind).
- ~~Window size memory is global, not per-profile~~ ✅
  `state.profiles[<name>].{w,h}`.
- Profile creation is config-file-only (Cmd+Shift+N now duplicates
  the active profile, but a true "+ new profile from scratch"
  overlay still requires config writeback).
- ~~Drag-drop image temp files in `/tmp/djinn-drop-*` never reaped~~
  ✅ stale `djinn-drop-*` reaped on launch.

**Deferred Tier S items** (recorded for later):

- **S1 — inline reply to `djinn_attention`**: agent calls
  `djinn_ask(message, expects, choices?)`, mini-panel drops with
  prompt, reply routes back through tool response or
  `surface_input_text`. Defer — long-poll semantics on the MCP side
  + reply panel + agent-side schema all need design first.
- **S2 — first-run setup wizard**: drop-down with hotkey picker
  (conflict check), provider/profile picker, MCP snippet copy
  button. Defer — needs UX mock + decision on whether to write
  config from UI vs. open editor.
- **S3 — stable MCP endpoint (opt-in)**: `mcp.stable_port` +
  `mcp.stable_token_path`. **Security concern** — a long-lived
  bearer token in a flat file is a credentials-on-disk surface; a
  malicious local process can read it and impersonate any agent.
  Defer until we can pair with a keychain-backed token store +
  `chmod 600` enforcement.

**Tier S4 — Cmd+? cheatsheet overlay** ✅ — shipped as
`session/cheatsheet.zig` (commits `f2db861` + `6e3e9ff` + `1a2deef`).
Reuses the `session/palette.zig` overlay pattern; renders `actions[]`
grouped by category, reflects user keymap overrides, reskins with the
chrome `Style`. Final binding is **Cmd+Shift+.** — the original Cmd+?
mapping conflicted with macOS shortcut help on US layouts.

**Tier A — high value, medium cost (target this pass):**

1. **Log pane v2** — sticky attentions ✅, free-text filter chip ✅,
   per-client color in header ✅, right-click "Copy entry" ✅,
   prefix-syntax filter (`level:warn,err`, `client:<name>`) ✅,
   clickable level pills (`[i][w][e]` next to the chip) ✅. Pills
   rewrite the chip needle on click so the prefix-syntax and visual
   state share one source of truth. Per-client pill UI deferred
   (would need dynamic palette as clients appear — not blocking;
   `client:` prefix covers the keyboard path). Remaining:
   `djinn_log` schema `kind`/`file`/`line`/`tag` extension +
   per-row NSView refactor — still gated by per-call expansion.
2. **Per-client identity surface** — nickname ✅, mute toggle ✅,
   color-coded client name in log header ✅, tab strip status dot
   (global agent state, not per-client) ✅. The dot lives at the
   trailing edge of the tab strip, mirrors the menubar SF Symbol
   coloring (working / attention / error), and gives the user a
   near-eye-line state cue while focused on the panel. Per-client
   per-tab variant still deferred — needs per-profile MCP client
   routing first.
3. **Notification policy** ✅ — `Notifier.sendKind` rate-limits per
   (client, kind) tuple via `notifications.rate_limit_ms`; per-
   state gates (`notifications.notify_on_{attention,error,done,
   progress}`) suppress chatter classes by default.
4. **Profile manager overlay** ✅ — folded into the Cmd+Shift+P
   palette (same surface, no new module). Rows now render
   `{label}  ·  {cwd or command}` and a synthetic "+ duplicate
   active profile" row sits at the bottom, auto-selected when the
   filter excludes every real session. Cmd+Shift+N still maps to
   the direct `profile_duplicate` action for muscle-memory users.
5. **Session resume** *(deferred — ghostty API gap)*. ghostty
   exposes `ghostty_surface_read_text` (selection-based) but no
   `inject_text` / `write_to_scrollback`. We can dump scrollback
   to disk on hide for audit-style replay but cannot restore it
   into a fresh surface on the next show — the PTY child writes
   into a clean buffer. Either:
   - Wait for upstream ghostty to expose a scrollback-inject API,
     then restore the captured text into the new surface.
   - Ship a "previous session log" disk artifact instead and surface
     its path in the agent log on next show (degraded UX —
     scrollback lives outside the live terminal).
   Revisit when upstream lands the inject path.
6. **Window-per-profile size memory** ✅ — shipped in `f92a241`.
   `state.json` now carries `profiles[<name>].{w,h}`; active-profile
   switch via tab strip / palette / Cmd+number restores the cached
   dimensions. Config-pinned `window-width` / `window-height` still
   win — explicit user override beats implicit-from-drag memory.

**Tier B — quality-of-life:**

7. Paste history palette (Cmd+Shift+V) backed by host-side ring.
8. Quick-send palette (Cmd+K when not at prompt) — type command,
   Enter → inject into active surface.
9. Selection → MCP push (Cmd+Shift+L) — selection becomes
   `djinn_log(info, <text>)` so the agent can introspect what the
   user pinned. Pairs with MCP read tools below.
10. **MCP read tools** ✅ — `djinn_recent_logs`,
    `djinn_recent_attentions`, `djinn_active_profile` (`fc4f3fd`).
    Pairs with the still-open #9 (selection → MCP push) so agents
    can both read and write user-visible state.
11. **Theme toggle hotkey** ✅ — `Cmd+Shift+T` cycles
    null (system) → light → dark → null (`e5508d7`). Override
    survives ghostty config reloads (`98c4afb` fixes the regression
    where reloadConfigFromDisk wiped the override).
12. **Drag-drop image temp cleanup** ✅ — `f09ad8e` reaps
    `/tmp/djinn-drop-*` on launch. Panel-hide reap was deemed
    unnecessary since launch reap caps growth across sessions.
13. Find chip toggles *(deferred — ghostty API gap)*. The
    `ghostty_action_start_search_s` struct in ghostty.h carries
    only `const char* needle`; case / regex / word flags aren't
    exposed in the C API and the `search:<needle>` binding
    action grammar takes a plain needle. Without upstream
    additions, UI toggles wouldn't change search behaviour. Wait
    for upstream to surface the flags or wire host-side regex on
    top of `ghostty_surface_read_text` snapshots (expensive on
    large scrollbacks).
14. Mouse-less terminal nav — `Cmd+J` jump-to-prompt (regex per
    profile). Skips most scrollback dragging.
15. **Per-profile bell config** ✅ — `profile.<name>.bell-audible /
    bell-visual / bell-sound` (`110e082`). `handleRingBell` consults
    profile overrides before falling back to the global `bell.*`
    keys.

**Tier C — speculative / lower payoff:**

16. Pinned attentions (survive panel hide until manually cleared).
17. Activity heatmap sparkline in tab strip (log-rate per profile,
    last 5 min).
18. Spotlight-style action palette (restart session, clear
    scrollback, switch theme, open settings, copy MCP config).
19. WebUI mirror (`:port+1`) for second-monitor read-only log
    dashboard; reuses MCP server thread.

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

### Dynamic profile creation *(partly addressed — duplicate-active shipped)*

`Cmd+Shift+N` now duplicates the active profile in place (`ac67e3c`),
and `Cmd+Shift+W` closes the active profile (`c4979ff` +
`ca44c09` for the atomic-write rollback on remove). Both write back
to `~/.config/djinn/config` by appending to the bottom of the file —
preserves comments above, doesn't try to round-trip the existing
layout.

What's still missing is a true **"+ new profile from scratch"**
affordance: today every duplicated profile inherits the active
profile's command / cwd / bell config, so first-time users
without an existing profile have nothing to fork. Options when
this comes up:

1. Add a "+ blank profile" row to the palette switcher alongside
   the existing "+ duplicate active profile" row. Writes a minimal
   `profile.<name>.command = /bin/zsh` stanza.
2. Build a structure-preserving editor — read line-by-line, find
   the profile section, insert in place — only worth doing once
   we have more than 1-2 writeback paths.

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

### Post-refactor leftovers — all landed 2026-05-21

Six-commit wave (`9b900b7` → `15bf4d4`) cleared the ranked list from
the prior session. Net: `view.zig` 1458 → 1166 LOC (−20%), three new
modules (`terminal/dragdrop.zig`, `terminal/theme_apply.zig`,
`retained_view.zig`), per-session arena bounds the spawn-arg leak,
eight new unit tests cover the find + palette state machines, and
three latent NSView leaks (tab-strip teardown, palette close,
cheatsheet close) found during the retained-view audit are fixed.
See "Recently shipped — current session" below for the commit map.

## Recently shipped — current session

### Post-refactor leftovers cleared (2026-05-21)
*(commits `9b900b7` → `15bf4d4`, 6 commits — each one `zig
ast-check`-clean, build verification deferred to CI)*

Walked the entire post-refactor punch list from the prior session.
Each item became its own commit so reverts stay surgical.

**Module moves (3 commits):**
- **`refactor(layout)` `9b900b7`** — `applyLogLayout` moved out of
  `terminal/view.zig` into `window/layout.zig` (home of
  `buildContainer` + `computeLogWidth`). `terminal/divider.zig` no
  longer back-imports `view.zig` for the drag-resize reflow; it
  reaches `window/layout.applyLogLayout` directly. `checkResize`
  bumped to `pub` so the new home can call back into the surface-
  size push. view.zig: 1458 → 1400 LOC.
- **`refactor(terminal)` `6928510`** — Drag-drop callbacks
  (`draggingEnteredImpl`, `performDragOperationImpl`,
  `tryDropImage`) extracted to `terminal/dragdrop.zig` (~150 LOC).
  Self-contained `NSDraggingDestination` surface, no responder-chain
  coupling. Mirrors the same `forwardText` local-duplicate idiom as
  `ime.zig` and `find.zig` so imports stay flat. view.zig: 1400 →
  1249 LOC.
- **`refactor(theme)` `287147a`** — `reapplyTheme` +
  `reapplyThemeIfChanged` + `reloadTheme` centralized in
  `terminal/theme_apply.zig`. Fan-out (chrome, log_view, find
  overlay, tab strip, panel) now has a single registration point
  for the next chrome surface that reskins on appearance flip.
  Internal callers (`viewDidChangeEffectiveAppearance`,
  `actionThemeToggle`) plus external callers in `main.zig`
  (hot-config reload) and `window/panel.zig` (panel show recovery)
  all route through the new module. view.zig: 1249 → 1166 LOC.

**Bounded allocation + leak fixes (2 commits):**
- **`refactor(session)` `1947242`** — per-session
  `std.heap.ArenaAllocator` on `Session.spawn_arena` owns the
  cmd + cwd `dupeZ` buffers ghostty needs as `[*:0]`. Lazily
  created on first `bindGhosttySurface`, reset on every re-bind
  so restart traffic doesn't accumulate. `removeSessionLive`
  destroys it; `SessionManager.deinit` walks the list for the
  program-exit path. Caps the prior process-lifetime dupe leak
  at "active sessions × current spawn args" — bounded, explicit.
- **`fix(session)` `15bf4d4`** — `src/retained_view.zig:detach`
  pairs `removeFromSuperview` with the manual `release` Cocoa
  requires for the +1 retain `[NSView alloc]` returns. Plugged
  three latent leaks the audit surfaced beyond the previously-
  fixed `removeSessionLive` case: `ensureTabStripVisible(false)`
  leaked the strip on every 2↔1 profile crossing;
  `palette.close` leaked the overlay (and rendered rows) on
  every open/close; `cheatsheet.close` leaked the wrapper + its
  NSTextView subtree on every Cmd+? toggle.

**Tests (1 commit):**
- **`test(terminal)` `34040a1`** — pulled `appendChars` +
  `backspaceNeedle` out of `find.handleKey` so the needle buffer
  state machine is exercised without spinning Cocoa. Four find
  tests (grow, control-byte rejection, capacity saturation,
  backspace-at-empty) + four palette tests (`matches`,
  `firstMatch`, `moveSelection` cycle through synthetic duplicate
  row, filter respecting cycle). Palette tests install a temporary
  SessionManager fixture and swap `app.g.palette` /
  `app.g.session_manager` so tests don't leak state.

**Net impact:**
- view.zig: 1458 → 1166 LOC (−292, −20%)
- New modules: `terminal/dragdrop.zig` (178), `terminal/theme_apply.zig`
  (104), `retained_view.zig` (37)
- 8 unit tests added (was: 7 keymap tests; now 7 + 4 find + 4 palette)
- Per-session arena bounds the cmd/cwd leak
- Four NSView leaks fixed (per-cycle, not per-program)

### Mid-May feature pass (2026-05-07 → 2026-05-20)

Three-week feature wave between the architecture refactor and the
post-refactor cleanup, clearing most of the UX-review friction
themes recorded above.

**Tier S4 — keyboard discovery:**
- **`feat(cheatsheet) f2db861`** — Cmd+? keymap overlay
  (`session/cheatsheet.zig`). `actions[]` grouped by category,
  reflects keymap overrides.
- **`fix(cheatsheet) 6e3e9ff`** — replace `{s: <[width]}` runtime
  formatter (Zig 0.15 doesn't accept the bracketed-width form) with
  a manual space-pad loop.
- **`fix(cheatsheet) 1a2deef`** — rebind Cmd+? → Cmd+Shift+. + use
  monospaced row font so the column alignment lands on any layout.

**Tier A — per-profile chrome:**
- **`feat(window) f92a241`** — per-profile window size memory in
  `state.profiles[<name>]`. Tab switch / palette / Cmd+number
  restores cached dimensions; config-pinned `window-{width,height}`
  still wins.
- **`feat(notify) 6f7630c`** — per-state notification gates
  (`notify_on_{attention,error,done,progress}`) + rate-limit per
  (client, kind) tuple.
- **`feat(client) 89cf528`** — per-client identity surface:
  nicknames + mute toggle + color-coded client name in log header.
- **`feat(log) 834fbc8`** — sticky attention banner.
- **`feat(log) 95e4f97`** — free-text filter chip with prefix
  syntax (`level:warn,err`, `client:<name>`) + clickable `[i][w][e]`
  level pills that rewrite the chip needle on click.

**Tier B — MCP + theme + drops:**
- **`feat(mcp) fc4f3fd`** — read tools: `djinn_recent_logs`,
  `djinn_recent_attentions`, `djinn_active_profile`. Mirrors the
  write surface; agents can introspect user-visible state.
- **`feat(theme) e5508d7`** — Cmd+Shift+T cycles
  null (system) → light → dark → null. `actionThemeToggle` logs
  the new state to the agent log so the action stays observable
  even when the user's ghostty theme isn't dual-variant.
- **`fix(theme) 98c4afb`** — runtime override survives
  `reloadConfigFromDisk` (previously the override was wiped on
  every config reload).
- **`chore(tmp) f09ad8e`** — reap stale `/tmp/djinn-drop-*` on
  launch so the directory doesn't grow forever.
- **`feat(profile) 110e082`** — per-profile bell overrides
  (`bell-audible / bell-visual / bell-sound`); falls back to global
  `bell.*` when unset.

**Profile lifecycle:**
- **`feat(profile) ac67e3c`** — Cmd+Shift+N duplicates the active
  profile in place. Appends `profile.<copy>.*` to the config bottom
  so comments are preserved.
- **`feat(profile) c4979ff`** — Cmd+Shift+W closes the active
  profile + writes back to config.
- **`fix(profile) ca44c09`** — atomic write for profile removal so
  a crash mid-rewrite doesn't strand the user with a partial
  config.

**Log filter chip polish (3 commits):**
- **`fix(log-filter) e2504bc`** — chip is always visible when a
  filter is active; auto-opens the log pane when a needle has
  results.
- **`fix(log-filter) 6c28de8`** — mount chip on the log-pane
  wrapper instead of the container so it tracks pane visibility.
- **`fix(log-filter) 89350de`** — clear filter state on pane hide
  so the next show starts clean.

**Linux port (separate thread, archived):**
- **`feat(linux) c874296`** — initial GTK4 / Wayland port.
- **`build(linux) 31592a7`** — packaging + CI + resilience polish.
- **`feat(linux) cc89bb0`** — multi-profile sessions + darwin-
  parity Tier A. Linux now has the same tab-strip / palette /
  per-profile-size UX as darwin.
- **`refactor(linux) 27236ab`** — log_pane split + code-shape
  pass.
- **`ci(linux) 28e4027`** — build gtk4-layer-shell from source on
  ubuntu-24.04 (noble's universe doesn't ship the package).
- **`test(linux) d39cd0c`** — relax watcher inode-recreate
  assertion to accommodate Azure CI tmpfs inode reuse.
- **`docs(linux) 02b7e03`** — collapse TODO chain narrative; full
  history on `archive/linux/pre-squash-after-prototype`.

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
