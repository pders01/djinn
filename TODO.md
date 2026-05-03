# djinn TODO

State as of May 4, 2026. **0.1.0-alpha.1 cut**: signed `.app` bundle,
GitHub Actions CI + release workflow, branded `.icns`, MIT LICENSE +
NOTICES, multi-profile sessions, theme inheritance for `light:X,dark:Y`
specs, dim-priority semantics for `state.json` vs config.

Tier-5 surface migration is **complete**: djinn is a libghostty-surface
host. ghostty owns the visible terminal area end-to-end (PTY, render,
scrollback, selection, hyperlink hover, search, IME). djinn keeps panel
chrome, MCP server, agent state surface, hotkey, menubar, log pane,
drag-drop, find-overlay UI, an action keymap, and now a SessionManager
on top.

## Open work — pick from here

### Visible profile UI *(natural follow-up)*

`SessionManager` is generic; today's UI is keybind-only (`Cmd+1..9`,
`Cmd+Shift+]/[`). Two surfaces would slot in over the same data:

- **Tab strip** — thin top-of-panel row of profile names (chip.bg,
  active in fg, inactive in dim). Click to switch. Reads
  `sm.sessions` for names, `sm.active_idx` for highlight, calls
  `activateSession(idx)` on click.
- **Palette switcher** — `Cmd+Shift+P` overlay listing profile
  names, type-to-filter, Enter to switch. Same data, modal UI.

Active-profile indicator on the menubar dropdown subtitle is the
cheapest start (one new line in the dropdown title format) — adds
visual feedback without new chrome.

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

### Dynamic profile creation *(deferred — needs config writeback)*

Currently profiles are file-defined. A `Cmd+Shift+N → New profile`
overlay would let users add a profile at runtime, but persisting it
requires writing back to `~/.config/djinn/config` without clobbering
comments / formatting. Either:

1. Append `profile.<name>.*` lines to the bottom of the file (simplest,
   preserves comments above).
2. Build a structure-preserving editor — read line-by-line, find the
   profile section, insert in place.

Pick (1) for v1 if this lands.

### Runtime appearance change *(today only at startup)*

`writeAppearanceThemeOverride` runs once in `App.init`. If the user
flips light/dark mode while djinn is running, ghostty's conditional
state isn't updated. Fix:

1. Listen for
   `NSDistributedNotificationCenter` `AppleInterfaceThemeChangedNotification`.
2. On fire: regenerate the override file, call
   `ghostty_app_set_color_scheme(app, .dark|.light)`, then
   `reloadConfigFromDisk` (which re-applies the override).

`view.zig::reapplyTheme` already partially handles this for chrome
colors — wire the ghostty side alongside.

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

### Alpha release prep
- `0.1.0-alpha.1` version stamp via `src/version.zig` (single source;
  cli, MCP `initialize` response, Info.plist all derive).
- `.github/workflows/ci.yml` — push + PR. Cached `~/.cache/zig`,
  `./scripts/build.sh test` + bare exe + `--version` smoke.
- `.github/workflows/release.yml` — fires on `v*` tags. Downloads
  Metal Toolchain, builds + signs Djinn.app, zips with sha256,
  publishes via `softprops/action-gh-release@v2` (prerelease=true
  when tag contains `-`).
- `assets/Djinn.icns` from `scripts/generate-icon.{swift,sh}` —
  Arabic brand glyph "جن" on Big Sur+ rounded-square gradient.
  Bundled via `CFBundleIconFile`.
- `LICENSE` (MIT, plain copyright), `NOTICES.md` (third-party survey
  for ghostty + transitive deps + zig-objc + Apple SF Symbols + MCP
  spec). README "Acknowledgements" + "License" sections at the end.

### Multi-profile sessions
- `default-profile = name` + repeating `profile.<name>.<field>` keys
  (`provider`, `command`, `cwd`, `title`).
- `Cmd+1..9` jump by index, `Cmd+Shift+]/[` cycle. 11 new actions
  rebindable via `keybind = action=trigger`.
- `src/session/manager.zig` — pure SessionManager. `peekNext` /
  `peekPrev` non-mutating helpers so view-layer math doesn't
  duplicate the wrap arithmetic.
- One surface_host NSView per session, all siblings, all hidden
  except active. Lazy spawn — only the active-at-startup session
  binds a surface during boot; secondaries spawn on first activate.
- `ghostty_runtime.App.newSurface` gains a `working_directory` arg
  so `profile.<name>.cwd` flows through `surface_config_s` instead
  of a process-wide chdir.
- `applyLogLayout` reflows every session's surface_host on resize +
  drag + log-pane toggle.
- Backwards compat: configs without `profile.*` keys synthesize a
  single "default" session from flat `provider` / `provider-command`
  — existing setups run unchanged.

### Bug fixes (post-alpha install regressions)
- `ghostty_config_get` slot-size match: split `configFloat` into
  `configF32` + `configF64`. ghostty `@alignCast`s the caller's
  pointer to the source field's type, so passing `f64*` for an
  `f32 font_size` left the upper half zero — values landed near 0.0,
  cell metrics collapsed to 1×1, mouse-click row/col went off by
  ~1000×.
- Theme inheritance for `light:X,dark:Y` specs: ghostty's `loadTheme`
  picks LIGHT as the default conditional state at finalize and
  there's no public C API to set it pre-finalize. Workaround: peek
  `~/.config/ghostty/config` for the `theme = ...` line, pick the
  variant matching `NSAppearance`, write `theme = <picked>` to a tmp
  file loaded via `ghostty_config_load_file` BEFORE finalize.
- `std.os.linux.getpid` is the linux-namespace syscall; on darwin it
  returns junk. ReleaseFast inlined the bogus value differently than
  Debug, so the override filename string the writer built diverged
  from the path `ghostty_config_load_file` later read from. Dropped
  the pid suffix; fixed filename, truncate-write per launch.
- Config window dims now optional (`?u32`). Priority: explicit config
  → state.json → hardcoded default. Editing `window-width = 2000`
  beats a state.json with a stale older size.
- Provider shortcut lookup case-insensitive in both
  `Config.getProviderCommand` and `SessionManager.providerCommand`.
  `provider = Claude` resolves to `claude` (was falling through to
  `/bin/zsh`).
- `Config.load` no longer swallows open / read errors as a default
  `Config{}`. Atomic-write editors (vim, VS Code, Helix) rename a
  tmp file over the target on save; FSEvents fires in the gap, open
  hits ENOENT. The default-on-error behavior was clobbering every
  user setting on every save. Errors propagate now;
  `loadOrDefault` for the startup path; `onConfigChanged` retries 3×
  with 20ms sleep before giving up + keeping previous config.
- `crush` (charmbracelet/crush) + `pi` (Pi AI) added to the provider
  shortcut table.

### Dev tooling
- `just deploy` chains `tcc-reset` + `install-app` + `open` for the
  full post-rebuild ritual.
- `just which-toolchain` reports active build wrapper (host `bash -c`
  vs `nix develop --command`).
- `justfile` `nix` variable now probes host zig at parse time via
  `printf '0.15.2\n%s\n' $(zig version) | sort -V -C`.
- README "Picking a hotkey that won't fight macOS" section, config
  block rewritten to ghostty `key=value`, "Install via Nix flake"
  section.
- `scripts/build.sh` + `scripts/install-app.sh` + `scripts/profile.sh`
  + `scripts/apply-ghostty-patch.sh` + `scripts/generate-icon.{sh,swift}`.
- `flake.nix` exposes `apps.{default,bundle,install,test}` +
  `checks.tests` + `devShells.default`. Tests build hermetically in
  the sandbox (no Metal); apps delegate to host build.

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
  keyDownImpl + a host buffer instead.
- **CALayer-backed views with custom layouts** don't reliably honor
  `setHidden` for visibility toggling when ghostty's CAMetalLayer
  drives its own CADisplayLink. Use frame-to-zero for full hide;
  setHidden works for the surface_host swap (no layout recompute).
- **Stash key NSView pointers on AppState** instead of indexing
  `container.subviews[idx]`. Slots: `surface_host_id`,
  `divider_view_id`, `search_field_id`. Per-session surface_host
  pointers live on `Session.surface_host` (`?*anyopaque`).
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
- **ghostty's `theme = light:X,dark:Y` resolution** uses `_conditional_state`
  inside ghostty. No public C API to set it pre-finalize, so djinn
  peeks the user's ghostty config + writes a tmp `theme = <variant>`
  loaded before finalize to override.
- **Provider shortcut match is case-insensitive.** Config values are
  user-typed (`provider = Claude` works); config KEYS are still
  strict-lowercase.

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
