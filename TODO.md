# djinn TODO

State as of May 3, 2026. Tier-5 surface migration is **complete**:
djinn is a libghostty-surface host. All host-side rendering, scrollback,
selection, hyperlink hover, cursor logic, and vt parsing retired —
the surface owns the visible terminal area end-to-end. djinn keeps
panel chrome, MCP server, agent state surface, hotkey, menubar,
log pane, drag-drop, find-overlay UI, and an action keymap.

## Open work — pick from here

### Per-call log expansion *(deferred — needs MCP schema work)*

Concept: tool calls collapse to a one-line summary, click expands to
show args + result. Today's `djinn_log` only carries `message` +
`level`, so there's nothing structured to expand. Real path forward:

1. Add an MCP tool surface for tool-call telemetry (`djinn_tool_call`
   with `tool_name` / `args` / `result` fields, or extend
   `djinn_log` with optional structured payload).
2. Extend `LogEntry` (state.zig) with `kind: enum { simple,
   tool_call }` + optional payload fields.
3. log_view: per-entry NSView (instead of one shared NSTextStorage)
   so each row can carry its own click handler + collapse state.

The view-tree refactor in step 3 is the expensive part. Worth it
only if the MCP side actually grows tool-call telemetry — speculative
right now.

### Animated log row insertion *(deferred — bad cost/value)*

CALayer fade-in on new rows. Conflicts with the current scroll-to-end
behavior (animation + autoscroll fight) and would need the per-row
NSView refactor (above) before it's feasible. Not worth it on its
own; revisit if the per-call expansion lands.

### Sleep / wake verification *(manual)*

Surface child behavior post-system-sleep is untested. Should be
ghostty's problem (we don't own the PTY or render pump), but worth
opening the panel after a sleep cycle to confirm the surface recovers
cleanly. No automation path — just smoke-test occasionally.

### Log pane formatting tests *(shipped)*

`formatEntryHeader(buf, client, timestamp_ms)` extracted as a pure
helper from `appendEntry`. 8 unit tests cover: epoch zero, client
name passthrough, noon, minute zero-pad, 23:59 boundary, past-
midnight wraparound, buffer-too-small null, empty client. Suite
total now 77.

### Pure-nix package build *(blocked on Metal Toolchain access)*

`packages.default` was attempted but the nix builder can't reach
the Metal Toolchain — Apple ships it through cryptexd at
`/var/run/com.apple.security.cryptexd/...`, mounted dynamically and
invisible to the build sandbox even with `__noChroot = true`.
ghostty's renderer compiles `.metal` shaders during link, so the
full djinn binary can't be produced inside `/nix/store`.

Current strategy: `scripts/build.sh` is the primary path. nix is a
toolchain layer (provides zig 0.15.2 when the host doesn't have a
compatible version). justfile probes the host zig at parse time and
either runs build.sh directly or wraps with `nix develop --command`.
Flake also exposes `apps.{default,bundle,install,test}` runners for
nix-only users — they delegate to the host-side `zig build` chain
the same way.

Real fix would mean either (a) ghostty shipping pre-built `.metallib`
files, or (b) nixpkgs adopting the Metal Toolchain as a fetched
dep.

### TCC churn *(blocked on release pipeline)*

Every `install-app` rebuild burns Accessibility + PostEvent grants
because the cdhash changes. Workaround:
`tccutil reset All com.pders01.djinn` + first-press re-grant. Use
`just tcc-reset`. Real fix: stable signing identity (Developer ID
or self-signed cert with consistent CN). Out of scope until we have
a release pipeline.

### Dispatch table coverage *(decision logged)*

Step 8 wired ~10 ghostty action handlers. The remaining ~50 stubs
are mostly window-manager actions (new_window, new_tab,
toggle_fullscreen, …) that don't apply to a Quake-drop panel.
**Skip** — they stay as `stub("…")` returning false.

## Recently shipped — this session

### Design language unification

- `src/chrome.zig` (new): `Style.fromTheme(theme)` hub. One source
  of truth for chrome colors (bg, fg, dim, info/warn/err) +
  `Chip` sub-style (bg, fg, dim) + `mix` / `nsColorFromRgb` /
  `chromeFont` helpers. Old `lift` field dropped — `chip.bg`
  (`mix(theme.bg, theme.fg, 0.12)`) is the single elevation token,
  shared by log pane + find chip.
- Find chip rebuilt: outlined-pill → 4px-rounded chip on `chip.bg`,
  no border, ghostty font at `font_size_sm`, `find · {needle} ·
  {n/m}` middle-dot format mirroring log entry headers. Auto-sizes
  width to content + 24px padding, anchored top-right.
- `DjinnChipCell : NSTextFieldCell` (view.zig): overrides
  `drawInteriorWithFrame:inView:` to vertically + horizontally
  center the attributed string. Fixes NSTextFieldCell's
  baselined-at-top default.
- Log pane: ACTIVITY header strip dropped (each entry already
  leads with dim `{client} · {time}` — separate section title was
  redundant signage). Reclaimed ~32px vertical. Wrapper + scroll +
  text view all use `chip.bg`, same as find chip.
- Group consecutive log entries by client: `last_client_buf` +
  `last_client_known` on LogView. Same client → skip header.
  Switching clients → new header. Ring truncation resets group.

### Drag-to-resize log column

- `DjinnDivider : NSView` (view.zig): mouseDown/Dragged/Up handlers
  + `resetCursorRects` (resizeLeftRightCursor) +
  `acceptsFirstMouse:` YES. Drag adjusts split, clamped to
  `cfg.log_pane.width_min/max`. mouseUp persists the new ratio to
  `cfg.log_pane.width_fraction` (in-memory).
- Divider width bumped 1px → 4px (grab area), alpha 0.05 keeps the
  visible band reading as a hairline.
- `applyLogLayout(container, term_w, log_w, height)`: shared layout
  primitive used by drag handler AND `setLogPaneHidden`. Single
  source of truth for the term/log/divider/surface_host split.

### Test suite expanded 35 → 67

- `theme.parseColor`: `#`/`0x`/plain forms, invalid length, invalid
  hex (6 tests).
- `Config.parse`: bell, scrollback, log_pane fields, system, window
  position enum, quoted values, malformed keybind, parseBool
  variants, inline-`#` hex preserved (9 tests).
- `mcp/tools.zig`: all 5 tools (attention/done/error/log info/warn/
  err level mapping), missing-message error, client label flow (6
  tests).
- `mcp/dispatch.zig` (new test block): initialize, notifications/
  initialized, tools/list, tools/call missing/non-object/
  missing-name params, tools/call dispatch, unknown method (8 tests).
- `chrome.zig`: `Style.fromTheme` derivation, font_size_sm floor,
  mix endpoints (4 tests).

### main.zig refactor

main() reduced 365 → 286 LOC. Helpers extracted with their own
docstrings: `restoreWindowSize`, `resolveTheme`,
`applyKeymapOverrides`, `bindGhosttySurface`. Defers + storage stay
in main() so lifetimes are clear.

### justfile + README rewrite

- `justfile` (new): 12 recipes (build/test/run/release/bundle/sign/
  install-app/patch/clean/profile/tcc-reset/check). Each build
  recipe wraps `nix develop --command bash -c ...` so it works from
  any shell, idempotent inside the dev shell.
- README "Picking a hotkey that won't fight macOS" section: lists
  conflict-free defaults (alt+space, ctrl+grave, ctrl+\\) +
  conflict-prone combos to avoid. Config block rewritten to ghostty
  `key=value` format (was stale JSON).

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
Same Config the surface uses, so log_pane / menubar / surface
palettes can no longer diverge. Killed the bundled-theme search.

### Step 10 — retire CG/Metal renderer + vt parser (-4344 LOC)
- `5589246` Stage A: render/atlas|metal|scene.zig deleted (~1500
  LOC), render-backend config key + RenderConfig dropped, debug
  flags removed.
- `b858130` Stage B: drawRectImpl + drawPreedit + glyph caches +
  prewarm + flushGlyphRun + buildAsciiGlyphCache deleted.
- `e8889ab`: ptyReadHandler + watchPtyRead retired (FSEventStream
  wrapper survives for live config reload).
- `8bfa311`: pty.zig deleted; drag-drop / paste / unmapped-key
  fallback writes funnel through `forwardText` →
  `ghostty_surface_text`.
- `b5d7fac`: theme/ghostty_config.zig re-parser deleted; theme.zig
  shrinks 222 → 165 LOC.
- `74bf0dc`: terminal.zig deleted (vt-static wrapper, scrollback,
  selection, encodeMacKey, encodePaste). view.zig: 2879 → 1578.

### Bundle / config / UX
- `f6a8420` config: JSON → ghostty `key=value` format.
- `140ca59` build.zig: bundle libghostty.dylib into `.app`,
  install_name_tool rewrites rpath to `@loader_path`.
- `acd7280` **THE big find**: `wakeup_cb` wires to `ghostty_app_tick`
  on main queue. Without this, ghostty's IO mailbox events stalled
  (child_exited, OSC actions, render hints never fired).
- `a713e1d` `closeSurfaceStub` → `panel.hide` via main-queue dispatch.
- `ef0c3fb` `surface_config.wait_after_command = false` so shell
  exit closes immediately.
- `da420bf` `setLogPaneHidden` reflows `surface_host` alongside
  TerminalView.

## Ghostty dependency boundary

djinn links the **full libghostty** (surface API). vt-static is
gone. `patches/ghostty-001-darwin-install.patch` +
`scripts/apply-ghostty-patch.sh` make `dep.artifact("ghostty")`
resolve on macOS; `scripts/build.sh` applies the patch and unsets
the nix-imposed Apple SDK env vars.

## Style / code-health (kept current)

- Zig 0.15 quirks: `memory/djinn_zig_015_pitfalls.md`.
- `{d:0>2}` formatter prepends `+` for non-negative signed ints —
  cast to unsigned first.
- Single `@cImport` per C header — Zig duplicates opaque types
  across modules. AppState uses `?*anyopaque` slots for
  `ghostty_surface` + `ghostty_config` to keep ghostty.h's cImport
  out of app.zig + theme.zig.
- `dispatch_object_t` is a transparent union — declare via
  `?*anyopaque` extern.
- NSSound is main-thread-only — afplay subprocess for non-main
  callers.
- `ghostty_config_get` second arg is `?*anyopaque`; `&out` for
  pointer-typed `out` (e.g. `*[*:0]const u8`) needs `@ptrCast`,
  not implicit coercion.
- zig_objc.msgSend selector arg wants `[:0]const u8` (sentinel
  slice with length), not `[*:0]const u8` (pointer).
- **Action callbacks fire synchronously inside
  `performBindingAction`.** Handlers must not re-emit the binding
  they're handling — split UI sync from binding emit, or recurse
  to stack overflow.
- **Borderless NSPanel + NSTextField + ghostty surface** doesn't
  compose into a working field editor. `makeFirstResponder` reports
  success, key events vanish. Use host-owned input via keyDownImpl
  + a host buffer instead.
- **CALayer-backed views with custom layouts** don't reliably honor
  `setHidden` for visibility toggling when ghostty's CAMetalLayer
  drives its own CADisplayLink. Use frame-to-zero instead — visually
  authoritative AND tree-stable (responder chain untouched, unlike
  removeFromSuperview).
- **Stash key NSView pointers on AppState** instead of indexing
  `container.subviews[idx]`. Index-based lookup silently breaks
  whenever a sibling gets added at index 0. Slots:
  `surface_host_id`, `divider_view_id`, `search_field_id`.
- **NSTextFieldCell does not vertically center.** `setUsesSingleLineMode`
  changes layout mode, not vertical alignment. Subclass the cell
  + override `drawInteriorWithFrame:inView:` to measure the
  attributed string + offset the rect (see `DjinnChipCell` in
  view.zig).
- **`acceptsFirstMouse:` YES on borderless-panel drag controls.**
  Without it, the first click goes to window-activation hit-test
  and the drag never starts (`DjinnDivider`).

## Memory bank

- `djinn_direction.md` — product thesis
- `djinn_v0_problems.md` — what we ripped out and why
- `djinn_rewrite_plan.md` — phase-by-phase plan
- `djinn_dev_shell.md` — flake quirks
- `djinn_zig_015_pitfalls.md` — fcntl, posix.O packed struct
- `djinn_shell_default.md` — never trust $SHELL from a dev shell
- `djinn_nsview_layer_backing.md` — drawRect must always paint full
  area on modern macOS (note: drawRect retired in step 10; kept
  for historical context)
- `djinn_theme_autoswitch.md` — needs `theme = light:X,dark:Y` form
- `djinn_cold_start.md` — cold-start performance map
- `djinn_ghostty_full_lib_patch.md` — patch + script
