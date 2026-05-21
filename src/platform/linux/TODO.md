# djinn — Linux port handoff

You're picking up an in-flight port of djinn (originally macOS-only) to
Linux/Wayland. The terminal works; the chrome is mostly there. This file
is your map. Each subsystem has its own `src/platform/linux/<name>.zig`
with the design rationale in the file-doc — TODO.md stays terse and
points you at the source.

## Priority order

The Linux port is consolidated as four commits on top of the
shared `main` baseline; the granular prototype history is parked
on the `archive/linux/pre-squash-after-prototype` branch (local
and on the personal upstream) for anyone who wants to read the
chain. The original Important / Minor code-review tiers landed
during the prototype phase; remaining work is opportunistic
darwin-parity ports and the deferred per-action user_data
refactor.

1. **Darwin-parity opportunistic ports for linux**: per-client
   header color, filter prefix syntax + level pills, and palette
   enrichment + duplicate-active row already shipped on darwin
   (see the consolidated multi-profile commit); each waits on a
   separate session to land its linux counterpart because the
   surrounding code is unfamiliar. Right-click "Copy entry",
   per-profile bell, per-profile window-size memory, and the
   tab-strip agent-state dot landed in the May 2026 polish wave.
   The Tier A block under `## Pick-up plan` has the per-feature
   shape for the remaining items.
2. **Per-action `*anyopaque` user_data for keymap actions** (deferred).
   Today every handler takes `*Context` and reaches for the slots it
   needs; the Popovers sub-struct cleaned up the late-stamped
   slots but kept the single-context shape. A genuine per-action
   user_data refactor would let each row carry its own dependency
   type, with comptime-generated wrappers casting back. Not
   justified at today's 32-row count: the cost of type-erasing
   every handler outweighs the structural-clarity win. Revisit
   if the action table doubles.

Commit conventions: conventional-commits subject (`fix(linux): …`,
`feat(...)`, `docs(...)`, `build: …`), `- ` bullet bodies wrapped
~80 chars, no `Co-Authored-By` trailer, no em dashes. Bodies are
declarative: they state what the code now does, not the discovery
path ("previously…", "without this would…"). `git log --oneline`
for the prevailing shape.

## Status snapshot

**Working** (see file + commit for the why):

- `panel.zig` — GTK4 borderless window + gtk4-layer-shell for
  Quake-drop on KDE / Hyprland / sway / wlroots; plain undecorated
  toplevel fallback on GNOME. `setHideOnBlur` connects (lazily, on
  first enable) to `notify::is-active` for Raycast/Spotlight-style
  auto-hide. `setTopmost` flips the layer between OVERLAY (above
  fullscreen) and TOP (above normal toplevels but below
  screen-lockers); no-op on non-layer-shell. `setSize` re-issues
  `gtk_window_set_default_size` for live resize. A `map` signal
  handler calls `gdk_surface_set_opaque_region(surface, NULL)` so
  the compositor blends transparency through — defensive supplement
  to the theme CSS for compositors that compute the region too
  aggressively. `focusChild` wraps `gtk_widget_grab_focus`; called
  from `main_linux.zig` after the GtkPaned wraps the VTE — without
  it the paned divider holds keyboard focus on startup and every
  key (including VTE's own copy/paste + our window-level shortcuts)
  goes nowhere. `setOnResize(ctx, cb)` registers a 500ms
  `g_timeout_add` that polls `gtk_widget_get_width/get_height` and
  fires the callback on changes (GTK4 has no public user-resize
  signal on GtkWindow; default-width/-height are app-set hints,
  GdkSurface.layout fires before allocation settles, polling
  sidesteps both). Source unregistered in `deinit`.
  `DJINN_NO_LAYER_SHELL=1` forces the plain-toplevel path on
  layer-shell-capable compositors (debugging utility).
  `flashBell()` drops `gtk_widget_set_opacity` to 0.4 for 80ms
  then restores via a one-shot `g_timeout_add` (tag stashed in
  `bell_restore_id`, cancelled in `deinit`). Re-entrant: a
  second flash mid-dim cancels the pending restore so each bell
  gets the full 80ms. Triggered by `Dispatch.onBell` when the
  firing profile (or global) has `bell-visual = true`.
  **Popover-grab counter**: `popover_grab_count: u32` tracks
  active `autohide=true` popovers owned by djinn (find overlay,
  palette). `pushPopoverGrab` / `popPopoverGrab` bump the counter
  on the popover's `show` / `closed` signals; `trackPopoverGrabs
  (popover)` wires both. `onActiveChanged` short-circuits while
  the counter is non-zero so the popover's input grab on KWin
  Wayland (which flips the parent's `is-active=false` even though
  focus is on a child popover) doesn't trigger hide-on-blur and
  yank djinn out from under Ctrl+Shift+{F,P}. `popPopoverGrab`
  re-checks `is-active` on counter→0 to handle the app-switch-
  with-popover-open case (the active-false event was suppressed
  while open and won't re-fire). Assumption: tracked popovers
  are init-once; revisit if any popover ever gets re-created.
- `terminal.zig` + `theme.zig` — VTE widget embedded as the panel's
  child, spawns the profile's resolved command (`script > command >
  provider > /bin/zsh`, same precedence as darwin) into the
  caller-supplied `cwd`, applies `config.terminal.*` +
  `config.theme.*` (font / fg / bg / cursor / padding /
  palette[0..15] / opacity) via VTE setters and a single
  module-level GtkCssProvider that gets reloaded in place on each
  apply (so live-reload doesn't stack providers). `Terminal.open`
  takes a `Spawn { command, cwd }` parameter — null falls back to
  `$SHELL` / `/bin/sh` (unused by SessionHost). `applyFont` runs a
  Pango font-family availability check before setting
  `vte_terminal_set_font` and logs a clear warning when the family
  isn't installed (avoids the "wide-cell" rendering bug from silent
  Pango substitution to non-monospace). `child-exited` flips the
  owning session's `exited` bit via the host dispatcher (chip
  dims + strikethrough, panel stays up); the user revives the
  slot with Ctrl+R (`restart_session`) or Ctrl+Shift+R
  (`shell_session`). Mirrors darwin's "Press any key to close"
  semantics. `bell` signal connects when `Handler.on_bell` is
  set; Audible bell is per-VTE via
  `vte_terminal_set_audible_bell` from `Spawn.audible_bell` so
  per-profile mute (`profile.<name>.bell-audible`) lands without
  the host needing the dispatch. `feedScreen(data)` paints
  directly into VTE's screen buffer (used to drop a "Process
  exited. Press Ctrl+R…" banner into the dying VTE so single-
  profile setups still get a visible cue). SIGTERM is routed
  onto the GLib main loop via `g_unix_signal_add` and quits the
  panel cleanly (needed by systemd user units). SIGINT already
  worked through GLib's default signal-fd watch.
- `session_host.zig` — multi-profile container. Owns a `GtkStack`
  of one VTE per profile, lazy-spawned on first `activate(idx)`;
  the active-at-startup session spawns eagerly so the first paint
  shows its shell. Reads `SessionManager` for the active index +
  per-profile spawn payload. `widget()` returns the stack (drop-in
  replacement for the single VTE at the GtkPaned start child slot).
  `currentTerminal()` / `currentVte()` getters let keymap handlers
  reach the visible session without tracking the active index
  themselves. `applyTheme(opts)` fans across every live VTE; lazy
  slots pick up the new theme on first activate via the cached
  `theme_opts`. Late-stamped `find_overlay` slot — `activate`
  retargets the search needle via `FindOverlay.setTarget` without
  reparenting the popover. `on_switch: ?OnSwitch` hook fires once
  per successful activate so the tab strip + palette can re-skin
  the active chip / line up on the visible profile without
  session_host importing either UI module (avoids the circular
  import a typed pointer would create). `restartActive
  (override_cmd)` replaces the active VTE widget in place:
  build a fresh `Terminal` first, `detachExitHandler` on the
  old so the imminent SIGHUP doesn't race into
  `markExited(idx, true)` ahead of the new spawn and flicker
  the chip + paint a stale banner the user never sees,
  `gtk_stack_remove` the old (closes the pty, child gets
  SIGHUP), then `gtk_stack_add_named` the new under the same
  stack name. Wired into Ctrl+R (keeps the profile command) /
  Ctrl+Shift+R (passes `/bin/zsh`) from the keymap. The simpler
  `vte_terminal_set_pty(t, NULL)` approach NULL-derefs at +0x18
  inside VTE 0.84's PTY dispose; see the matching "Decisions
  you should not undo" entry.
  **Per-session exit tracking**: `Entry.exited: bool` flips
  true on every child-exit (active or inactive; the panel
  never closes on shell exit). Mirrors darwin's
  `handleChildExited`. Per-VTE handler carries the session idx
  via `Terminal.Handler.extra` (stamped by `handlerFor(idx)`);
  Dispatch reads the idx and feeds a "Process exited. Press
  Ctrl+R…" banner into the firing VTE before marking the slot.
  `markExited (idx, value)` mutates the bit and fans
  `on_exit_changed` when the value flips; the caller (main_linux)
  wires the hook to `tab_strip.markExited(idx, value)` so the
  chip dims + gains a strikethrough on exit, drops the class on
  restart.
  **Per-spawn bell config**: SessionHost stamps
  `bell_audible_default` at init (from `cfg.bell.audible`) and
  resolves `profile.bell_audible orelse default` per spawn,
  passing the result through `Spawn.audible_bell` so each
  profile's VTE gets the right mute state. Hot-reload of
  `cfg.bell.audible` lands on next spawn; existing VTEs keep
  construction-time value.
  `restartActive` clears the bit on its success path so a
  user reviving an exited session via Ctrl+R re-skins the
  chip automatically. `isExited(idx)` peeks the bit without
  subscribing.
- `tab_strip.zig` — horizontal `GtkBox` of `GtkButton` chips, one
  per session. Active chip carries the `.djinn-tab-active` CSS
  class; inactive chips reserve a 2px transparent border-bottom so
  the active accent underline doesn't shift the row vertically on
  switch. Module-local `GtkCssProvider` reloaded in place on
  `applyTheme` (same pattern as `log_pane.zig`); CSS buffer now
  appends a trailing `\0` before `gtk_css_provider_load_from_string`
  (palette landing surfaced the latent missing-sentinel bug as
  Theme parser errors). Accent color picks `palette[4]` (blue ANSI
  slot) with `@accent_color` fallback. Hidden when
  `sm.count() < 2` so single-profile setups paint identically to
  pre-Phase-1. `pairWithChild(paned)` wraps `(strip, paned)` into
  a vertical GtkBox so main_linux stays free of GtkBox externs.
  Click handlers route through a caller-supplied `OnActivate`
  callback into `SessionHost.activate` — keeps the type
  dependency one-way. Label buffers are owned per-chip
  (sentinel-terminated) so a Config reload arena drop can't
  invalidate the C `gtk_button_new_with_label` pointer.
  **Exited-chip skin**: `markExited(idx, exited)` adds /
  removes the `.djinn-tab-exited` CSS class on the chip at
  `idx`. CSS dims color to 0.35 alpha, italicizes the label,
  and strikes through the label text via `> label` (GTK4
  GtkButton renders its label as a direct child label node,
  so the selector matches across themes). Fed by SessionHost's
  `on_exit_changed` hook so the chip stays in lockstep with
  `Entry.exited`.
  **Agent-state dot**: small CSS-painted circle at the trailing
  edge (`box.djinn-state-dot` with `hexpand + halign=END` so it
  gravitates right without disturbing chip layout). `markState`
  swaps a per-state class on the dot; `observeAgentState`
  starts a 250ms `g_timeout_add` mirroring the tray's poll
  cadence. Color per `Agent`: `palette[4]` (blue) for working,
  `palette[3]` (yellow) for attention, `palette[1]` (red) for
  error, transparent for idle and done. Two AgentState
  observers (tray + tab strip + log pane = three) is cheap;
  each module stays decoupled.
- `palette.zig` — `Ctrl+Shift+P` type-to-switch profile palette.
  `GtkPopover` anchored to `host.widget()` (the GtkStack) so it
  survives profile switches without reparenting. Vertical box
  child: `GtkSearchEntry` on top, `GtkScrolledWindow → GtkListBox`
  (min/max content height 120/360) underneath. One
  `GtkListBoxRow` per profile, label as the row child, model
  index == profile index (`gtk_list_box_row_get_index`).
  Filtering via `gtk_list_box_set_filter_func` reading a cached
  lowercased needle that gets rebuilt on each `search-changed`
  (GtkSearchEntry's built-in 150ms debounce). Each row carries
  pre-lowercased `label_lower + name_lower` slices into a single
  per-row buffer (one alloc per profile, ASCII case-fold) so the
  filter hot path is two `mem.indexOf` calls. Up/Down/Return/
  Escape intercepted by a CAPTURE-phase `GtkEventControllerKey`
  on the entry — selection moves through the visible filtered
  rows while the entry keeps focus, Enter activates, Esc closes;
  everything else falls through to the entry as normal text
  input. Selection mode BROWSE so one row is always selected
  (Enter always has a target). `OnActivate` callback into
  `host.activate(idx)` — reuses `main_linux.onTabActivate`, so
  palette-driven switches fan through the same `on_switch` hook
  the tab strip listens on. Module-local `GtkCssProvider`
  reload-in-place on `applyTheme`; selected-row background from
  `palette[4]` (blue ANSI slot) with `@accent_color` fallback.
  CSS-node gotcha: the listbox is targeted by `.djinn-palette-
  list` class, not the `listbox` selector, because GtkListBox's
  CSS node is `list` (already-burned in log_pane). CSS buffer
  appended with `\0` before `load_from_string` — same trap as
  tab_strip's. Pre-existing `keymap` action row count was 29;
  with `palette_open` the banner now reads `installed 30/30`.
- `ghostty_config.zig` — parses `~/.config/ghostty/config` directly
  (linux doesn't link libghostty). Strips matched `"…"` / `'…'`
  around values (ghostty's parser allows it; font-family with
  spaces is the common case). Resolves `theme = NAME` against
  `~/.config/ghostty/themes`, `/usr/share/ghostty/themes`,
  `/usr/local/share/ghostty/themes`; `loadThemeFile` runs
  `isSafeThemeName` first so values containing path separators,
  `..`, leading dots, or NUL bytes resolve to null instead of
  reading outside the themes/ tree. `tryLoadThemeAt` requires a
  regular file (post-open `stat`) so a symlink to `/dev/zero` or
  a device file resolves to null rather than blocking startup on
  a 1 MiB read. `parseInto` strips trailing `# comment` sections
  via `stripInlineComment` (preserves `#rrggbb` sigils by only
  treating `#` as a comment when not followed by a hex digit).
  `loadFromUserConfig` / `loadThemeFile` degrade to "skip
  inheritance" on `FileTooBig` instead of propagating the error
  and blocking the panel open. Light/dark variants picked from
  xdg-desktop-portal.Settings color-scheme (defaults to dark; KDE's
  portal double-wraps the value in a variant, the unwrap loop in
  `detectAppearance` handles both shapes). `main_linux.zig` merges
  the result into ThemeOptions: djinn config wins on each field,
  ghostty fills the gaps, palette is ghostty-only.
- `ipc.zig` — Unix-socket bridge at `$XDG_RUNTIME_DIR/djinn.sock`
  (fallback `/tmp/djinn-<uid>.sock` when the runtime dir is unset),
  accepts `toggle` / `show` / `hide` / `quit`. `Ipc.init` narrows the
  process umask to 0077 around `bind()` so the socket inode lands
  with mode 0600 atomically — same-machine users can't drive the
  verb stream regardless of which path is chosen. Stale-unlink
  errors (non-ENOENT) log a clear "bind may fail" pre-warning.
  `onListenReady` caps the per-dispatch accept loop at 32 iters
  so a same-UID client `connect()`-ing in a tight loop can't
  starve the GLib main thread; non-EINTR `read` errors log
  distinctly from benign restarts.
- `hotkey.zig` — `xdg-desktop-portal.GlobalShortcuts` over GDBus.
  Auto-registers from `config.hotkey.toggle`; first launch on KDE pops
  a confirmation dialog, subsequent launches are silent. The method
  reply's canonical `(o)` Request path is reconciled against the
  locally-predicted path in both the CreateSession and BindShortcuts
  callbacks via `reconcileRequestPath` — if the portal renames the
  request segment (KDE has done this), the Response subscription
  swaps onto the canonical path before the body executes. Each
  portal call uses `PORTAL_CALL_TIMEOUT_MS = 30s` so a stuck
  xdg-desktop-portal daemon can't peg the subscription until
  process exit. `reportSuccess` / `reportFailure` /
  `reportSyncFailure` emit one definitive
  `hotkey: portal active — trigger "<X>"` /
  `hotkey: portal unavailable — <reason>` line per init attempt;
  `ctx.outcome_reported` latches the first call so duplicate
  handler paths don't double-log. Falls through to the IPC bridge
  when no portal backend implements GlobalShortcuts.
- `log_pane.zig` + `log_pane_css.zig` + `log_model.zig` —
  right-hand column inside a horizontal `GtkPaned` next to the
  VTE. `log_pane.zig` owns the widget tree + signal wiring;
  `log_pane_css.zig` owns the themed CSS builder (extracted
  ~280 lines); `log_model.zig` owns the filter-needle +
  last-client-tracking pure-data model with its own unit tests
  (`matchesFilter`, `shouldEmitHeader`, `updateLastClient`,
  `setFilter`, `resetGrouping`, `hasActiveFilter`). LogPane
  holds a `model: LogModel = .{}`; the hot
  `appendRangeLocked` path delegates through it. Widget tree:
  outer vertical `GtkBox` → (attention `GtkButton`,
  `GtkScrolledWindow → GtkListBox`, `GtkSearchEntry`).
  CSS-node gotcha: GtkListBox's node is `list`, NOT
  `listbox` — easy to lose hours on. Per-level CSS classes
  (`.djinn-log-info` / `-warn` / `-err`) on a module-local
  reload-in-place provider. 250ms `g_timeout_add` poll same shape
  as tray's — diffs `(count, first_ts)` and either appends new
  rows or rebuilds when the ring evicts. `pollTick` and
  `rebuildAll` hold `state.mutex` across the snapshot AND the
  GTK row builds via `appendRangeLocked` so a concurrent
  `appendLog` eviction can't shift the `[from..from+count]`
  window onto different entries than the snapshot intended.
  Auto-scroll to newest via
  an idle callback (deferred so GTK's measured upper-bound
  reflects the freshly-appended row). `applyTheme(opts)` mirrors
  `Terminal.applyTheme`: resolved background + opacity paint at
  the `list` node (deepest in the tree, beats KDE theme's
  `viewport.view` paints without needing `!important`), info text
  uses resolved foreground, warn / err use `palette[3]` /
  `palette[1]` with `@warning_color` / `@error_color` as fallback.
  Called from startup AND `Dispatch.onConfigChanged` so theme
  stays in lockstep with VTE. `vexpand=1` on the listbox AND the
  scrolled window so the list fills the box's remainder after the
  chip + filter take their natural heights. `pairWithSibling
  (vte_widget, position)` builds the GtkPaned so main_linux.zig
  stays free of GtkPaned externs. Ctrl+/ toggle via
  `toggleVisible` (flips the outer container); watcher
  live-applies `log_pane.enabled` flips. Placeholder row is
  state-driven: `.no_activity` ("no agent activity yet") until
  first MCP traffic; swaps to `.no_matches` ("no matches for
  filter") when an active filter rejects every entry.
  `refreshPlaceholder` picks the right kind after every list
  mutation; `appendRange` lazy-clears so no-match ticks don't
  churn the placeholder.
  **Sticky-attention chip**: GtkButton above the scrolledwindow,
  hidden until `AgentState.pinnedAttention(dst)` returns Some.
  `refreshAttentionChip` runs every pollTick (independent of log
  appends — attention pins/unpins on its own schedule via the
  agent state machine), diffs against `attention_buf` to skip
  no-op relabels, and toggles visibility. Click signal →
  `ackAttention`; the next tick observes the cleared pin and
  hides the chip, keeping a single source of truth. Themed via
  `palette[3]` (yellow / warning slot) with `@warning_color` as
  GTK-named-color fallback.
  **Free-text filter**: GtkSearchEntry below the scrolledwindow,
  case-insensitive substring match against `entry.message` +
  `entry.client` (case-folded once into `filter_buf` so the
  per-entry path is one `mem.indexOf`). `search-changed` signal
  → full rebuild via `rebuildAll`; GtkSearchEntry's built-in
  150ms debounce keeps fast typing from triggering a rebuild on
  every keystroke. `appendRange` skips non-matching entries
  inline so new log activity under an active filter doesn't
  surface rows the user filtered out.
  **Client-grouped headers**: `shouldEmitHeader` emits a dim
  `{client} · HH:MM` row at group transitions (first non-null
  client OR client change); body rows drop the client prefix
  since the header carries it. Null-client (djinn-internal)
  entries break the group so the next non-null client gets a
  fresh header. Headers emit only directly before their
  matching body row — no orphan headers under a narrow filter.
  `formatHeaderTime` mirrors darwin's `formatEntryHeader` (UTC
  HH:MM) so the two surfaces read identically.
  **Right-click "Copy entry"**: each body label gets a
  GtkGestureClick (`button = GDK_BUTTON_SECONDARY`); the
  `pressed` handler reads the label's text via
  `gtk_label_get_text`, strips the leading `[LVL] ` prefix
  when present, and writes the message to the system
  clipboard via `gdk_display_get_clipboard`. No user_data
  needed; the handler reaches back through the gesture →
  widget chain. Left-click drag-selection still works because
  the gesture is scoped to the right button only.
- `tray.zig` — hand-rolled `org.kde.StatusNotifierItem` +
  `com.canonical.dbusmenu` over GDBus. State-driven themed icon
  (idle/working/attention/done/error), left-click toggles the panel,
  right-click pops a static Toggle / Quit menu. `observeAgentState`
  polls `AgentState` every 250ms on the GLib main thread and emits
  `NewIcon` / `NewTitle` / `NewStatus` when state or message changes.
  Consumed by KDE plasmashell, waybar, xfce4-panel, GNOME's
  AppIndicator extension. Silent when no SNI host runs. A
  `NameOwnerChanged` subscription on `org.kde.StatusNotifierWatcher`
  drives `sendRegisterRequest` whenever the well-known name flips to
  a new owner — plasmashell / waybar / xfce4-panel restarts mid-
  session auto-recover the tray without a djinn relaunch.
- `notifier.zig` — `org.freedesktop.Notifications.Notify` over GDBus.
  Same `Kind` / `send` / `sendKind` / `playSound` surface as
  `notify/darwin.zig`; maps Kind to urgency levels + freedesktop
  sound-name hints. Re-exported as `platform.Notifier`. `init(Options
  {enabled, rate_limit_ms})` + `deinit` are the construction
  contract; the session bus `*GDBusConnection` is cached on the
  struct (lazy-acquired on first `deliver` under `conn_mutex`,
  unref'd by `deinit`) so the hot path past first delivery is
  mutex-free. Failed acquire keeps `connection = null` so transient
  bus loss retries automatically on the next send. `ztrunc` snaps
  back to a UTF-8 code-point boundary before writing the NUL — the
  banner body field requires valid UTF-8 and a half-byte tail
  silently disappears on KDE/GNOME notification daemons.
- `gdbus.zig` — shared GDBus surface. Opaque types (`GDBusConnection`,
  `GVariant`, `GVariantBuilder`, `GVariantType`, `GCancellable`,
  `GAsyncResult`), `GError` layout, bus + call-flag constants, the
  `GAsyncReadyCallback` / `GDBusSignalCallback` typedefs, and ~25
  externs (`g_bus_get_sync`, `g_dbus_connection_call` / `_call_sync`
  / `_call_finish`, signal subscribe / unsubscribe, the
  `g_variant_new_*` family, builder ops, readers). Imported by
  `hotkey.zig`, `tray.zig`, `notifier.zig`, `ghostty_config.zig`
  through `const gdbus = @import("gdbus.zig");`. SNI server-side
  scaffolding (`g_dbus_node_info_*`, `g_dbus_method_invocation_*`,
  `register_object`, `emit_signal`, the vtable typedefs) stays local
  to `tray.zig` — single caller, no drift surface.
- `watcher.zig` — `GFileMonitor` parent-dir watch on
  `~/.config/djinn/config` and `~/.config/ghostty/config`. Events
  pass through a shared `CoalesceState` with a 100ms leading-edge
  `g_timeout_add` debounce so an editor's atomic-rename burst
  (5+ GFileMonitor events in ~10ms) collapses to a single
  `on_changed` call; saves across both files in the same window
  also coalesce. Handler in `main_linux.zig` re-loads djinn config
  (with 3× 20ms retry to ride out atomic-rename ENOENT — at most
  one retry path per save now thanks to coalescing), re-parses
  ghostty inheritance when on,
  re-applies theme via `Terminal.applyTheme` + `LogPane.applyTheme`
  (font / colors / palette / padding / opacity), re-issues
  `Panel.setSize` when window dims changed, re-toggles
  `Panel.setHideOnBlur` / `Panel.setTopmost`, rebinds the portal
  hotkey on `hotkey.toggle` change (init-new-then-deinit-old so a
  bad trigger keeps the working binding), starts / stops the MCP
  server on `mcp.enabled` flip, refreshes the autostart entry on
  `open_at_login` flip, and shows/hides the log pane on
  `log_pane.enabled` flip. `warnUnliveable` is the canonical list
  of fields still requiring a restart — currently empty; the helper
  stays as the home for the next cold-path field.
- `autostart.zig` — XDG `.desktop` entry at
  `$XDG_CONFIG_HOME/autostart/djinn.desktop`, gated on
  `config.system.open_at_login`. `Exec=` from `/proc/self/exe`
  with `stripDeletedAnnotation` to drop the kernel's ` (deleted)`
  suffix when the inode has been unlinked mid-session (routine on
  a pacman/apt upgrade). Stages content to `<path>.tmp` and
  atomic-renames over the final path so a mid-write crash can't
  leave a torn file. Replaces SMAppService.
- `keymap.zig` — `GtkShortcutController` on the panel window with
  `GTK_SHORTCUT_SCOPE_MANAGED` + PROPAGATION_CAPTURE so bindings
  beat VTE's internal shortcut set. 32 entries (`installed
  32/32` banner on startup):
  - `font_inc` / `font_inc_shift` / `font_dec` / `font_reset`
    (Ctrl+= / Ctrl+Shift+= / Ctrl+- / Ctrl+0)
  - `clear_scrollback` (Ctrl+Shift+K) — `vte_terminal_reset` then
    `\x0c` (Ctrl+L) via `feed_child` so readline redraws the
    prompt at the cleared top
  - `restart_session` (Ctrl+R) — `session_host.restartActive
    (null)` hangs up the active VTE's child and re-spawns the
    same profile command into the same widget
  - `shell_session` (Ctrl+Shift+R) — `restartActive("/bin/zsh")`
    drops to the shell fallback when the configured profile
    script is broken
  - `open_settings` (Ctrl+,) — `xdg-open` primary (desktop MIME
    handler, GUI editor on KDE/GNOME), `$EDITOR` fallback (TTY
    editors fail silently with `.Ignore` stdio)
  - `mcp_copy_endpoint` (Ctrl+Shift+M) — copies
    `~/.config/djinn/mcp.json` to GDK clipboard
  - `copy` / `paste` (Ctrl+Shift+C / Ctrl+Shift+V) — VTE 0.74+
    removed default keybindings, host app must wire these or
    there's no way to copy text out of the terminal.
    `VTE_FORMAT_TEXT = 1` (not 0 — enum starts at 1, passing 0
    trips `check_enum_value` assertion and silently no-ops)
  - `toggle_log_pane` (Ctrl+/) — flips `log_pane.toggleVisible()`
  - `scroll_page_up` / `scroll_page_down` (Shift+PgUp /
    Shift+PgDn) — drives VTE's GtkScrollable vadjustment by one
    page each; universal terminal-emulator scrollback gesture
  - `theme_toggle` (Ctrl+Shift+T) — cycles
    `ghostty_config.appearance_override` (null → light → dark),
    then invokes the `reapply_config` hook so the new
    `theme = light:X,dark:Y` variant gets baked in. Logs the new
    state to the agent log pane via `LogPane.appendInfo`
  - `find_open` / `find_next` / `find_prev` (Ctrl+Shift+F /
    Ctrl+G / Ctrl+Shift+G) — drive `find_overlay.zig`'s
    GtkPopover + VTE PCRE2 search
  - `cheatsheet_open` (Ctrl+?) — toggles `cheatsheet.zig`'s
    GtkPopover, rendered from `keymap.actionList()` as Pango
    markup
  - `hide_panel` (Escape) — gated by `predHideOnEscape`, only
    consumes the key when `window.hide_on_escape = true`;
    propagates to VTE otherwise so TUIs (vim, less, htop, fzf)
    keep working. Action table grew a per-row `predicate` field
    for this — handlers return 0 (not-handled) when the
    predicate rejects, letting GTK continue propagation.
  - `next_tab` / `prev_tab` (Ctrl+Tab / Ctrl+Shift+Tab) and
    `tab_1..tab_9` (Alt+1..Alt+9) — multi-profile switching.
    All gated by `predHasMultipleProfiles` so single-profile
    setups propagate the keys (Alt+N as readline repeat-count
    prefix keeps working). `tab_N` handlers are
    comptime-built via `makeTabHandler(n)`. `next_tab` /
    `prev_tab` reach `session_host.activateNext` /
    `activatePrev`; `tab_N` reaches `session_host.activate(n - 1)`
    which bounds-checks (no-op past `sm.count()`).
  - `palette_open` (Ctrl+Shift+P) — toggles `palette.zig`'s
    type-to-switch popover. Same `predHasMultipleProfiles` gate
    as the tab keys; single-profile setups propagate Ctrl+Shift+P
    unchanged.
  - `restart_session` / `shell_session` (Ctrl+R / Ctrl+Shift+R)
    — `session_host.restartActive(null)` keeps the profile
    command; `restartActive("/bin/zsh")` drops to the shell
    fallback. Strategy is widget-replacement: build a fresh
    Terminal, detach the old's child-exited handler,
    `gtk_stack_remove` the old, `gtk_stack_add_named` the new
    under the same name. Sidesteps VTE 0.84's set_pty(NULL)
    NULL-deref at +0x18 inside PTY dispose.
  Action table grew `display` + `description` fields so
  cheatsheet renders human-readable text without re-implementing
  GTK's accel→label transform. Context is a service registry
  carrying `session_host`, `allocator`, `log_pane`, `panel`,
  `config`, `reapply_config`, plus a `popovers: Popovers`
  sub-struct grouping the late-stamped optionals
  (`find_overlay`, `cheatsheet`, `palette`). Mirrors darwin's
  `terminal/view.zig::actions` — entries tied to features that
  don't exist on linux yet (IME) land as their backing features
  do.
- `find_overlay.zig` — `GtkPopover` anchored to the VTE widget
  with a `GtkSearchEntry` + Prev/Next icon buttons. Each entry-
  text change recompiles a PCRE2 regex
  (`vte_regex_new_for_search`, CASELESS + MULTILINE) and feeds
  it into `vte_terminal_search_set_regex`; an inline `find_next`
  fires on every recompile so the first match is visible without
  an extra Enter. `vte_terminal_search_set_wrap_around(true)` at
  init so searches loop past buffer edges. Ctrl+Shift+F /
  Ctrl+G / Ctrl+Shift+G binds in keymap.zig; Esc / autohide
  dismisses. Signal handler ids stashed on the struct so
  `deinit` disconnects before unparenting + regex unref.
- `cheatsheet.zig` — `GtkPopover` parented to the VTE widget
  containing a Pango-markup `GtkLabel`. Walks
  `keymap.actionList()` at startup, renders rows with non-empty
  `description` as a two-column "accel | description" block
  inside a `<tt>` span for monospace alignment. Toggled by Ctrl+?
  via `gtk_widget_get_visible`; autohide handles click-outside
  dismiss.
- `dragdrop.zig` — two `GtkDropTarget`s on the VTE widget. The
  string target accepts `G_TYPE_STRING` (GTK 4 auto-serializes
  `text/uri-list` from file managers), percent-decodes paths, shell-
  quotes them, and pastes via `vte_terminal_paste_text`. The image
  target accepts `GdkTexture` (screenshots / browser drags / Photos),
  serializes via `gdk_texture_save_to_png` to
  `/tmp/djinn-drop-<128-bit hex>.png`, and pastes the path. The
  string target is attached first so file-manager drags (which
  typically offer both URI list and thumbnail) resolve to paths
  rather than rasterized previews. `formatPayload` skips bare
  `file://` URIs (no path) so the shell doesn't get an empty `''`
  positional arg, and logs the truncation count when
  `writeShellQuoted` runs out of room mid-payload.
  `main_linux.zig::reapDragDropTemps` runs once at startup to
  clear entries older than 1h, continuing past per-entry
  `dir.iterate` errors so other users' /tmp files can't abandon
  the sweep.
- MCP HTTP server in `main_linux.zig` — same wiring shape as darwin's:
  `AgentState → Notifier → ToolTable → Dispatcher → McpServer` on a
  detached thread, gated on `mcp-enabled`. Endpoint info in
  `~/.config/djinn/mcp.json`. `handleConnection` returns `!void`
  and `run()` logs failed handler returns so transient I/O errors
  stay visible instead of silently disabling MCP requests for the
  server's lifetime. Body-read failures fall through to the
  existing 400 "incomplete body" response instead of bare TCP RST.

Tested on CachyOS + KDE Plasma Wayland 6.x.

**Not yet wired** — exists on darwin but no linux analogue:

- Hot-reload reconcile for multi-profile. Watcher's
  `onConfigChanged` already fires; the linux analogue of
  `src/session/live.zig` (add / remove / re-point sessions in
  place) hasn't landed. Tab strip + palette are built once at
  startup today — reconcile needs to also rebuild the chip row
  and the palette listbox when a profile is added / removed /
  renamed.

## Decisions you should not undo

- **VTE, not ghostty, on linux.** ghostty's embeddable surface C API
  is darwin/iOS only (no GTK variant in `src/apprt/embedded.zig`), and
  ghostty's GTK frontend is a full `GtkApplication`, not a library.
  macOS keeps using ghostty. djinn's value-add is the chrome, not the
  terminal engine.
- **Hide-on-blur must consult `Panel.popover_grab_count` before
  hiding.** GTK4's `autohide=true` popovers (find overlay, palette)
  grab keyboard input at popup. On KWin Wayland the grab makes the
  parent toplevel report `is-active=false` even though focus is on
  a popover child inside the same window. Without the guard,
  `setHideOnBlur` fires the instant any tracked popover pops up
  and yanks djinn out from under Ctrl+Shift+{F,P}. The counter is
  incremented via the popover's `show` signal and decremented via
  `closed`; `Panel.trackPopoverGrabs(popover)` wires both. A
  `gtk_window_get_focus`-based heuristic looks tempting (popovers
  parent into the window tree via `gtk_widget_set_parent`, so the
  popover's entry shows up as `get_focus()`) but GTK4 retains the
  focus child across legitimate app-switches, so it can't
  distinguish "popover grabbed focus inside me" from "user clicked
  another app and I still remember my last focus child." The
  cheatsheet doesn't need this guard because it uses `autohide=
  false` (its only child is a non-focusable GtkLabel; autohide
  would race the panel-active flip itself). Add new popovers to
  `trackPopoverGrabs` only when they use `autohide=true`.
- **`popPopoverGrab` re-checks `is-active` on counter→0.** When
  the user app-switches while a popover is open, the
  `is-active=false` event fires while the count is still >0 and
  gets suppressed. `notify::is-active` won't re-fire once the
  popover dismisses, so without the recheck the panel would stay
  visible after the user clearly switched away. Keep the recheck
  call in `popPopoverGrab` even though it duplicates a snippet of
  `onActiveChanged`.
- **Layer-shell linked statically, listed BEFORE gtk4 on the link
  line.** ld.so processes `DT_NEEDED` in declaration order, and
  gtk4-layer-shell works by interposing one libwayland-client symbol.
  Runtime `dlopen` is too late.
- **`VTE_SPAWN_NO_SYSTEMD_SCOPE` is mandatory.** Without it, VTE's
  nested `StartTransientUnit` call returns a malformed reply when
  djinn launches from another scope-creating terminal (Ghostty,
  gnome-terminal, konsole) and VTE's libfmt error reporter aborts on
  a null string.
- **argv lifetime in `vte_terminal_spawn_async`.** Genuinely async —
  pointers are stashed for a deferred fork-and-exec. Free the strings
  or array before the spawn lands and you get
  `g_utf8_make_valid: assertion 'str != NULL' failed`. `Terminal`
  owns argv until `deinit`.
- **Restart via widget replacement, NOT `vte_terminal_set_pty
  (t, NULL)`.** The natural-looking shape (hangup the child via
  set_pty(NULL), reset, then call spawn_async on the same widget)
  NULL-derefs at +0x18 inside VTE 0.84's PTY dispose chain. Stack
  was `Terminal.restart -> vte_terminal_set_pty -> inner helper ->
  unmapped fn at libvte+0x4a7b4`; address 0x18 is some priv-struct
  field accessed mid-dispose. Deferring the spawn via `g_idle_add`
  doesn't help — the crash is in the hangup path. `SessionHost.
  restartActive` instead builds a fresh `Terminal`, detaches the
  old's `child-exited` (so the imminent SIGHUP doesn't race into
  `markExited(idx, true)` ahead of the new spawn and paint a
  stale "Process exited" banner into a buffer about to be
  discarded), `gtk_stack_remove`s the old (which finalizes it,
  closes the pty, SIGHUPs the child), then `gtk_stack_add_named`s
  the new under the same stack name. Sidesteps the buggy codepath
  entirely; matches darwin's `restartSurfaceCallback` shape.
- **`SessionHost.Entry.name_z` must point into the STORED slot's
  `name` buffer, not into a stack-local.** The natural pattern
  (`var e: Entry = ...; e.name_z = written.ptr; entries.append
  AssumeCapacity(e)`) puts `name_z` aliased to the loop frame's
  `e.name`; after the `append` copies the value, the next
  iteration reuses the frame so every stored `name_z` resolves to
  the last iteration's name buffer. Looks fine on a 1-profile
  config (no second iteration), breaks loudly on 2+: GtkStack
  rejects every non-eager add with `duplicate child name`,
  `set_visible_child_name` always picks the same slot, switching
  is a visible no-op. Always `append` first then write through
  `&entries.items[i]`; `ensureTotalCapacity(n)` reserved up front
  guarantees no realloc-induced pointer drift.
- **Per-target root source file.** `build.zig` selects `src/main.zig`
  on darwin and `src/main_linux.zig` on linux. Two roots are simpler
  than gating each `@import("objc")` site.
- **Comptime platform switch.** `src/platform.zig` dispatches via
  `builtin.os.tag` to `platform/darwin.zig` or `platform/linux.zig`.
  Most darwin re-exports are stubs because `src/main.zig` still
  imports its darwin types directly; `Notifier` is the exception —
  a real re-export of `notify/darwin.zig.Notifier` so
  `mcp/tools.zig` can target a unified surface. New subsystems
  consumed by code that runs on both OSes should follow the Notifier
  pattern: real re-export on darwin, real impl on linux.
- **Font availability check before VTE setFont.** Pango substitutes
  missing families silently and the substitute often has glyph
  metrics that cause VTE to render each Latin char in a 2-cell
  width ("wide-cell" bug). `theme.zig::fontFamilyAvailable`
  enumerates `pango_font_map_list_families` and compares
  case-insensitively. The check looks ceremonial but the silent
  fallback was the first real bug a Linux user hit during the
  ghostty inheritance landing — keep it.
- **Single module-level CSS provider in `theme.zig`.** First apply
  creates + adds the provider; every subsequent apply reloads its
  content via `gtk_css_provider_load_from_string`. Stacking new
  providers on each reload would "almost work" (last-added wins on
  conflicting rules) but breaks the "user deleted the setting"
  case — an old `window { background-color: transparent; }` rule
  would linger forever. Reload-in-place avoids that and keeps the
  live-apply path side-effect-free.
- **Longhand `background-color` + `background-image: none` for the
  opacity rules.** GTK4's CSS parser rejects `!important` inside
  the `background` shorthand ("Theme parser error: Junk at end of
  value for background") and drops the whole rule on parse error
  — the panel stays opaque and the bug looks like a compositor
  issue. `background-image: none` is the belt: some user themes
  set a gradient image that the color alone wouldn't override.
- **`!important` is fragile on GTK 4.20+ — don't reach for it.**
  Despite older theme.zig comments suggesting `!important` works
  on longhand `background-color`, GTK 4.20.3 (current Nix dev
  shell) rejects it with "Junk at end of value for
  background-color" and drops the rule. Use higher-specificity
  selectors instead — `PRIORITY_APPLICATION` (600) already beats
  `PRIORITY_THEME` (200) on equal-specificity ties.
- **GtkListBox's CSS node is `list`, not `listbox`.** Easy hours-
  long bug: selectors like `listbox.djinn-log { background: … }`
  silently never match because the actual node name is `list`.
  Same trap for any GTK4 widget that took a short CSS name in the
  4.x naming pass. When a CSS rule "looks right but does nothing,"
  the FIRST thing to check is the node name with GtkInspector or
  the GTK source.
- **`gtk_css_provider_load_from_string` needs a NUL terminator.**
  The function takes `const char*` — passing
  `buf.items.ptr` from a `std.ArrayList(u8)` reads past
  `len` into uninitialized capacity / neighbouring allocations
  until it hits a `\0` somewhere downstream. Symptom is garbage
  `Theme parser error: <data>:N:M: Expected '{' after
  selectors` warnings that mention line numbers PAST the actual
  CSS content. log_pane appends `0` to the buffer for this
  reason; tab_strip + palette do the same. Latent for ages until
  the palette provider's allocation pattern shifted layout and
  surfaced it.
- **Initial focus grab on the VTE is mandatory.** Once the VTE
  lives inside a `GtkPaned` (for the log pane sibling), the paned's
  divider holds keyboard focus by default — arrow-key navigable.
  Every keypress goes to the paned's handlers, not the VTE. Result:
  no typing in the shell, no VTE copy/paste (Ctrl+Shift+C/V),
  and our `GtkShortcutController(MANAGED)` shortcuts don't dispatch
  because MANAGED resolves the controller chain off the focused
  widget. `panel.focusChild(term.widget)` after `attachChild` fixes
  it. If you ever change the widget tree, keep this call alive.
- **VTE 0.74+ removed default copy/paste keybindings.** Host apps
  must wire `vte_terminal_copy_clipboard_format` and
  `vte_terminal_paste_clipboard` themselves. `VTE_FORMAT_TEXT = 1`
  (not 0 — the enum starts at 1; passing 0 trips a
  `check_enum_value` assertion and silently no-ops the copy).
- **`clear_scrollback` must send Ctrl+L after the reset.**
  `vte_terminal_reset(0, 1)` drops scrollback and visible content
  but the shell process doesn't know — PS1 doesn't re-render and
  the user stares at an empty buffer. `vte_terminal_feed_child`
  with `\x0c` (Ctrl+L) triggers readline's `clear-screen` action,
  which redraws the prompt at the cleared top. Works in bash /
  zsh / fish and in TUIs that handle Ctrl+L as redraw (vim, less,
  htop).
- **`open_settings` uses `xdg-open` first, `$EDITOR` fallback.**
  Reversed order silently no-ops on every linux user who has
  `$EDITOR=vim`/`nvim`/`helix` — TTY editors spawned with
  `.Ignore` stdio exec successfully then immediately exit
  (no controlling terminal). `xdg-open` delegates to the desktop's
  text/plain handler (Kate on KDE, etc.), which is the right
  primary path for a GUI-context "open config file" action.
- **Grep `Gtk-WARNING` in stderr before suspecting the compositor.**
  Symptoms of dropped CSS look exactly like a wlr-layer-shell + KDE
  bug (transparency, padding, font sizing all "just don't work" but
  the call succeeds). One quick grep up front saves an afternoon of
  red herrings.

## Layout

```
src/
  main.zig                  # darwin entry (untouched)
  main_linux.zig            # linux entry — wires platform layer to the cold path
  platform.zig              # comptime selector
  platform/
    darwin.zig              # darwin re-exports (mostly stubs)
    linux.zig               # aggregator
    linux/
      gtk.zig               # shared GTK / GLib opaque types
      panel.zig             # GtkWindow + gtk4-layer-shell + show/hide/toggle
      terminal.zig          # VteTerminal + shell spawn
      theme.zig             # VTE font / colors / palette / padding / opacity
      find_overlay.zig      # GtkPopover + VTE PCRE2 search
      cheatsheet.zig        # GtkPopover keymap reference
      ipc.zig               # Unix-socket toggle bridge
      hotkey.zig            # xdg-desktop-portal.GlobalShortcuts client
      tray.zig              # StatusNotifierItem + dbusmenu
      notifier.zig          # org.freedesktop.Notifications client
      watcher.zig           # GFileMonitor parent-dir watch
      autostart.zig         # XDG .desktop autostart entry
      dragdrop.zig          # GtkDropTarget on the VTE widget
      keymap.zig            # GtkShortcutController actions table
      session_host.zig      # GtkStack of N VTEs (one per profile)
      tab_strip.zig         # GtkBox of GtkButton chips per profile
      palette.zig           # Ctrl+Shift+P type-to-switch popover
      log_pane.zig          # GtkPaned sibling: log entries widget
      log_pane_css.zig      # themed CSS builder for the log pane
      log_model.zig         # filter + header bookkeeping (LogModel)
      ghostty_config.zig    # ~/.config/ghostty/config + theme parser
      gdbus.zig             # shared GDBus / GVariant surface
      TODO.md               # this file
```

## Use today

```sh
nix develop                 # x86_64-linux dev shell with gtk4 + vte + glib + ...
zig build                   # debug, zig-out/bin/djinn
zig build test              # unit suite
./zig-out/bin/djinn         # opens the layer-shell panel + terminal
DJINN_NO_LAYER_SHELL=1 ./zig-out/bin/djinn   # force plain toplevel (debug)
```

The portal auto-registers `config.hotkey.toggle` (default
`ctrl+space`). First launch on KDE prompts for approval; accept it
once and the binding sticks. To trigger from a script — or as a
fallback when the portal isn't available — talk to the Unix socket:

```sh
printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock
```

You can also bind the socket to a compositor hotkey directly if you
prefer to manage shortcuts in your compositor config:

- **Hyprland** (`~/.config/hypr/hyprland.conf`):
  ```
  bind = ALT, space, exec, printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock
  ```
- **KDE Plasma**: System Settings → Shortcuts → Custom Shortcuts →
  Edit → New → Global Shortcut → Command/URL. Trigger ALT+Space,
  action `sh -c 'printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock'`.
- **sway** (`~/.config/sway/config`):
  ```
  bindsym Mod1+space exec printf toggle | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/djinn.sock
  ```

## Pick-up plan

### Foundations *(all landed)*

The original port's phased rollout (packaging, cold-path
live-apply, CLI overrides, keymap expansion, log pane MVP) all
shipped in the prototype phase; the four consolidated commits
on `main` are the entry points, and the granular landing chain
lives on `archive/linux/pre-squash-after-prototype`. Two
gotchas the next agent should not re-discover:

- **Toolchain pin: `zig0.15` from AUR**, not Arch's stock `zig`.
  Current Arch zig is 0.16 and ghostty's `requireZig` rejects
  it with a `@compileError`. Ghostty `main` still pins
  `minimum_zig_version = "0.15.2"` (revisit quarterly). On
  Nix the dev shell pins the right version; on Debian zig
  isn't in the archive so `rules` uses `$(ZIG)`.
- **Build via nix dev shell on current Arch.** Arch's gcc
  16.1.1 emits SFrame relocations
  (`R_X86_64_PC64` against `crt1.o:.sframe` and
  `libc_nonshared.a(pthread_atfork.oS/):.sframe`) that
  zig 0.15's lld can't handle — the final link step fails
  with `fatal linker error: unhandled relocation type
  R_X86_64_PC64`. The Zig compile + sema steps still pass
  (build summary will read "17/20 steps succeeded; 1
  failed"), so AST checking and codegen are unaffected.
  Workarounds: build inside `nix develop` (pins an older
  glibc/crt without SFrame), or skip the link by running
  `zig ast-check <file>` on touched files to confirm
  semantic correctness. Linker fix lands in zig 0.16+;
  reassess when the toolchain pin moves.
- **Keymap shortcut extension pattern.** A new shortcut is
  one row in `keymap.zig`'s `actions` array + a handler
  function. The `predicate` field gates whether the row
  consumes the key or propagates to VTE (`hide_panel` /
  `Escape` and the `tab_*` family are the precedents —
  predicate returns false → handler returns 0 → GTK continues
  propagation). `KeymapContext` is a service registry
  carrying `{session_host, allocator, log_pane, panel,
  config, reapply_config, popovers: {find_overlay,
  cheatsheet, palette}}` — popover slots clustered into a
  sub-struct because they share the late-stamped lifetime
  story.

### Multi-profile rollout

Decision: N VTE widgets in a `GtkStack`, one per profile, with
custom-themed `GtkBox` + `GtkButton` chips for the tab strip and a
`GtkPopover`-backed palette for type-to-switch. Phases 0 + 1 landed;
Phase 2 is the next focused session.

**Phase 0 — Foundation** *(landed)*

`SessionHost` + `SessionManager` + MCP `djinn_active_profile`,
`Terminal.Spawn`, find overlay `setTarget` for switch-time retarget.

**Phase 1 — Tab strip + keyboard switching** *(landed)*

`src/platform/linux/tab_strip.zig` (~430 LOC): horizontal `GtkBox`
of `GtkButton` chips, one per profile, with `.djinn-tab-active`
CSS class on the active row. CSS via reload-in-place provider.
Hidden when `sm.count() < 2`. `pairWithChild(paned)` wraps
`(strip, paned)` in a vertical `GtkBox`. Keymap rows landed:
`next_tab` (Ctrl+Tab), `prev_tab` (Ctrl+Shift+Tab), `tab_1..9`
(Alt+1..9), all gated by `predHasMultipleProfiles` so single-
profile setups propagate the keys. SessionHost gained an
`on_switch` hook that fires after every successful activate;
main_linux wires it onto `TabStrip.markActive` so keymap- and
click-driven switches share one chip-update path.

**Phase 2 — `Ctrl+Shift+P` palette switcher** *(landed)*

`src/platform/linux/palette.zig` (~520 LOC): `GtkPopover` anchored
to `host.widget()` (the GtkStack) so it survives profile switches.
Children: `GtkSearchEntry` (built-in 150ms debounce) plus a
`GtkScrolledWindow → GtkListBox` of profile rows. Filter via
`gtk_list_box_set_filter_func` reading a cached lowercased needle
(rebuilt on each `search-changed`); each row carries pre-
lowercased label + name slices in a per-row buffer so the hot
path is two `mem.indexOf` calls. CAPTURE-phase
`GtkEventControllerKey` on the entry intercepts Up/Down/Return/
Escape — keyboard moves selection while the entry keeps focus.
Activation routes through `host.activate(idx)` via the same
`OnActivate` callback shape `tab_strip.zig` uses; the
`SessionHost.on_switch` hook then fans the chip-row re-skin so
palette- and click-driven switches converge on one code path.
Keymap row `palette_open` is gated by `predHasMultipleProfiles`,
banner reads `installed 30/30`. Side-effect: tab_strip + palette
`gtk_css_provider_load_from_string` calls both append `\0` now
(palette landing surfaced tab_strip's pre-existing missing-
sentinel bug).

**Phase 3 — restart-session + per-profile window-size memory** *(landed)*

`SessionHost.restartActive(override_cmd)` replaces the active VTE
widget in place. First-cut shape was in-place re-spawn:
`vte_terminal_set_pty(t, NULL)` to hangup + deferred
`spawn_async`; that path NULL-derefs at +0x18 inside VTE 0.84's
PTY dispose (`set_pty -> inner helper -> libvte+0x4a7b4`) and
crashed every Ctrl+R. The deployed shape: build a fresh
`Terminal` first (so an OOM doesn't strand the slot empty),
`Terminal.detachExitHandler` on the old (so the imminent SIGHUP
doesn't race into `markExited` on the about-to-be-replaced
slot), `gtk_stack_remove` the old widget (closes the pty, child
gets SIGHUP), `deinit` the old's owned strings, then
`gtk_stack_add_named` the fresh
widget under the same stack name. Tab strip, log pane, window
position all preserved. Mirrors darwin's
`restartSurfaceCallback` (free old surface, bind a fresh one
to the same NSView). `null` keeps the profile command
(Ctrl+R), `"/bin/zsh"` drops to the shell fallback
(Ctrl+Shift+R). Keymap action table grew to 32 rows.

Tangent that surfaced during the restart bring-up:
`SessionHost.init` was writing each Entry's `name_z` as a
pointer to a stack-local's `name` buffer, then copying the
value into the ArrayList. Every stored `name_z` aliased the
last iteration's stack frame (resolved to `"session-N-1"`),
so `gtk_stack_add_named` collided on every non-eager spawn
and `set_visible_child_name` always selected the same slot —
profile switching was visually a no-op. Fix: append the entry
first, then `bufPrintZ` into the stored slot's `name` and
point `name_z` at it.

Per-profile window-size memory rides the `on_switch` hook: the
hook's ctx flipped from `&tab_strip` to `&g_dispatch` so the
callback can fan to both the chip refresh and a new
`Dispatch.applyProfileWindowSize` that reads `state.json` and
resizes the panel to the per-profile dims. Mirrors darwin's
`applyProfileWindowSize` in `src/ghostty/surface_lifecycle.zig`.
Config-pinned `window-width` / `window-height` short-circuit so
editing the file always wins over state.json.

**Follow-up multi-profile items**

- **Hot-reload reconcile.** Linux analogue of
  `src/session/live.zig`: add / remove / re-point sessions on
  watcher fire. The tab strip is built once at startup today —
  reconcile needs to also rebuild the chip row when a profile is
  added / removed / renamed.

### May 2026 polish wave *(landed)*

Five-commit follow-up cleared the child-exit hang report and four
adjacent linux-only gaps. Each landed as its own commit (`7215113`
→ `4ee75e7`) so reverts stay surgical; full diff statable via
`git log 73c6c09..4ee75e7`.

- **`fix(linux) 7215113`**: `Dispatch.onChildExited` stops
  calling `panel.quit()` and instead always feeds a dim
  "Process exited. Press Ctrl+R…" banner into the firing VTE
  via the new `Terminal.feedScreen`, then flips
  `entry.exited`. Matches darwin's `handleChildExited`; the
  underlying teardown hang on `g_main_loop_quit` no longer
  fires on the common close-the-shell path. New extern:
  `vte_terminal_feed`. New SessionHost getter: `terminalAt(idx)`.
- **`fix(linux) e37f6ba`**: startup applies the active-at-
  startup profile's persisted dims via
  `Dispatch.applyProfileWindowSize` right after SessionManager
  comes up. Closes the gap where the initial `panel.open`
  only knew the global state.json slot.
- **`feat(linux) 98ef114`**: per-profile bell. Audible side
  is per-VTE via `vte_terminal_set_audible_bell`
  (resolved from `profile.bell_audible orelse cfg.bell.audible`
  at spawn time, threaded through `Spawn.audible_bell`). Visual
  side is `Panel.flashBell` (composition opacity 0.4 → 80ms
  restore via `g_timeout_add`). Handler gains `on_bell` slot;
  `Dispatch.onBell` reads the firing profile's `bell_visual`
  at fire time so live config flips work on the visual path.
- **`feat(linux) f8247a4`**: right-click "Copy entry" on log
  rows. `GtkGestureClick` (button = `GDK_BUTTON_SECONDARY`) per
  body label; pressed handler reads `gtk_label_get_text`, strips
  the `[LVL] ` prefix, writes to `gdk_display_get_clipboard`.
  Left-click drag-select on the label still works because the
  gesture is scoped to right button only.
- **`feat(linux) 4ee75e7`**: tab-strip agent-state dot at
  trailing edge. Small CSS-painted circle (`box.djinn-state-dot`
  with `hexpand + halign=END`), color per `Agent` state from
  the palette[1/3/4] slots, transparent in idle and done.
  `observeAgentState` starts a 250ms GLib timer mirroring the
  tray's poll cadence.

### Darwin parity (May 2026 Tier A)

A pass on the darwin-side `TODO.md`'s Tier A landed five log-pane /
chrome features. Each translates to Linux but waits on platform
mappings since the underlying widget stack diverges (NSTextView ↔
GtkListBox, NSPanel chip ↔ GtkPopover etc.). Names below are the
darwin module / pull-request that landed each; grep there for the
shape before porting.

- **Right-click "Copy entry"** in the log pane.
  Darwin: subclassed NSTextView (`DjinnLogTextView` in
  `agent/log_view.zig`) with `menuForEvent:` override + per-entry
  character-range table.
  Linux equivalent: each `GtkListBoxRow` already has its own
  `GtkLabel`; bind a `GtkGestureClick` (right-button) on the row
  that writes `entry.message` to `GDK_SELECTION_CLIPBOARD` via
  `gdk_display_get_clipboard`. Probably one new helper in
  `log_pane.zig` + a small per-row signal hookup; no schema change
  needed (the message lives on `LogEntry.message`).
- **Per-client color in log header.**
  Darwin: `chrome.Style.client_palette[6]` (palette[9..15] minus
  bright_white) + a stable hash of the resolved client label picks
  the accent.
  Linux: extend `log_pane.zig`'s row builder to attach a Pango
  span with `<span color='#...'>` around the `{client}` portion of
  the header. Palette source: `theme.palette[9..15]`, same
  Wyhash-mod-6 mapping as darwin so the same client lands on the
  same color across the two platforms.
- **Filter prefix syntax** (`level:info,warn,err`, `client:<name>`)
  + **clickable level pills** `[i][w][e]`.
  Darwin: `FilterSpec` + `parseFilterSpec` in
  `agent/log_view.zig` (pure-zig, already unit-tested); pills are
  a `DjinnLevelPills` NSView in `session/log_filter.zig` with a
  `composeNeedle` rewriter that keeps pill state + chip text in
  sync via the needle string.
  Linux: `parseFilterSpec` is platform-agnostic — extract from
  `agent/log_view.zig` into a shared `agent/log_filter_spec.zig`
  and import on both sides. Pills are a three-`GtkToggleButton`
  row inside the existing `GtkSearchEntry` container (or
  immediately above it); the toggle's `notify::active` handler
  rewrites the entry text via `composeNeedle`. Cheatsheet update
  in `linux/cheatsheet.zig` mirrors darwin's footer block.
- **Profile palette enrichment + "+ duplicate active profile" row.**
  Darwin: `session/palette.zig` row renderer now emits
  `{label}  ·  {cwd or command}`; a synthetic row past the last
  real session triggers `profile_manager.duplicateActive` on
  Enter. Single-session setups can still open the palette to
  reach the duplicate affordance.
  Linux: each profile `GtkListBoxRow` in `linux/palette.zig` is
  already a label child — swap the child for a horizontal `GtkBox`
  carrying the label + a dim cwd/command label. Append a
  sentinel row with `+ duplicate active profile` text; route its
  `OnActivate` through a new `linux/profile_manager.zig` (mirror
  the darwin module's append-only writeback to
  `~/.config/djinn/config`). FSEvent watcher reload handles the
  reconcile on disk-write completion.

None of these are urgent; the structural refactors at the head of
the priority order rank above darwin parity. Porting is
opportunistic — pick one up when its surrounding code is already
open for another reason.

### Independent small bites *(any order)*

Don't depend on each other or on multi-profile. Sized so each
is one focused session.

- **Per-state djinn tray icon** (small).
  `tray.zig` currently uses generic freedesktop names
  (`utilities-terminal`, `dialog-warning`, …). Ship per-state
  SVGs into a hicolor theme path during packaging and swap
  `iconName` to `djinn-idle` / `djinn-working` / etc.
- **IME / preedit support** (`vte 0.74+ commit / preedit-changed`,
  ~2 days). Matters for CJK + dead-key keyboard layouts. Wire
  the signals into the input pipeline so composed text reaches
  the PTY as a single sequence instead of per-keystroke garbage.

## Known issues

- **Tray uses generic themed icons.** Each state maps to a
  freedesktop name (`utilities-terminal`, `dialog-warning`,
  `task-due`, `task-complete`, `dialog-error`). Swap for per-state
  djinn SVGs once a djinn icon ships into a hicolor theme path.
- **`main_linux.zig` allocator never `deinit`s for config strings.**
  Mirrors `main.zig`'s intentional leak — startup-only state lives
  until exit. The live-reload path adds a small bounded leak (old
  Config strings shed on each reload; ghostty colors do get
  `deinit`'d). Watch for this if you add leak-checking test
  scaffolding.
- **`GtkGizmo (slider) reported min width/height -2` warnings** at
  startup are benign GTK4 noise from GtkPaned's internal slider
  widget. Investigated: removing `set_shrink_*_child` calls
  (deprecated since GTK 4.10) and `set_size_request` on the log
  pane didn't suppress them. Likely a GTK4 + KDE-theme interaction
  in the slider's measure pass; reported upstream in multiple GTK
  apps with no functional impact. Don't chase unless it correlates
  with a real layout bug.
- **KDE custom-shortcut binding is a separate step from portal
  registration.** Portal accepts the binding (you'll see
  `hotkey: portal registration confirmed`), but KDE Plasma still
  requires the user to open System Settings → Shortcuts and bind
  a key to djinn's exposed action. Not a bug — KDE's portal
  presents the registration as "available", not "active".
  Documented in README's "Linux (Wayland) → First launch"; the
  troubleshooting list there points users at the right Settings
  panel.

## Code review backlog

Originally surfaced by a four-slice review of the prototype
branch (~10k LoC). Items are grouped by severity; within a
severity, related items are clustered so a fix session can sweep
one theme at a time. Each entry: `file:line` + 1-line
description. Landed entries get pruned in place; the original
chain lives on `archive/linux/pre-squash-after-prototype`. The
Critical-tier (debian source format, link order, ghostty
theme-name validation, PKGBUILD git-variant) and the bulk of
the Important + Minor tiers all landed during the prototype
phase.

### Important — real debt, will bite production

Lifetime hazards:

- **`main_linux.zig` CLI overrides** — `keybinding_override` /
  `provider_override` come from `ArgIterator`, which
  `defer args.deinit()` frees AFTER `defer config.deinit()` runs
  (defers fire in reverse registration order). The override
  survives the arena drop because the arena doesn't own it; the
  original parse-duped value it displaced gets freed by
  `Config.deinit`. Documented at the assignment site — any
  reordering of the defers inverts the safety story.

Build + packaging:

- **`debian/control` + `debian/rules:19-25`** — no
  `Build-Depends: zig (>= 0.15)` because zig isn't in the Debian
  archive; `dh_auto_configure` runs `zig build --fetch` which
  needs network. Unbuildable on fresh pbuilder chroot
  (architectural dead-end until zig is archived or vendored).
- **`djinn.service:11-12`** — `After=graphical-session.target` +
  `PartOf=graphical-session.target` is documented now (the
  `[Unit]` comment block names the Hyprland / bare-sway uwsm
  caveat) but no fallback `After=` line. If a user reports the
  unit sitting `inactive` after a Hyprland install, the
  next step is either a `default.target` fallback or a README
  pointer to `systemctl --user start graphical-session.target`.
- **`djinn.service:38-39`** — `WantedBy=graphical-session.target`
  with transient targets is fragile across compositor restarts:
  `PartOf=` stops djinn but `WantedBy=` of a transient target
  doesn't necessarily re-pull it. Test path: log out → log back
  in → verify djinn restarts. Consider `WantedBy=default.target`
  + `Requisite=graphical-session.target`.
- **`flake.nix:190-197`** — `__noChroot = true` on
  `packages.default` (not just `checks`) makes
  `nix build .#default` non-reproducible and non-substitutable.
  `nix profile install` re-downloads ghostty on every rebuild.
  The cleaner architectural fix is `zon2nix` vendoring so the
  package builds in the sandbox while `checks` retains
  `__noChroot`.

### Minor — track, not blocking

Code-shape:

- **`keymap.zig` per-action user_data** — current shape is a
  `Context` service registry with seven top-level fields plus a
  `Popovers` sub-struct (three optionals). 32-row action table.
  Per-action `*anyopaque` user_data (each row carries its own
  dependency type via a comptime-generated wrapper) is the next
  step if the table doubles or a new subsystem doesn't fit the
  registry shape. At today's count the registry is honest about
  the dependency graph and the type-erasure cost outweighs the
  structural-clarity win.
- **`main_linux.zig` Terminal bring-up** — `Terminal.open` takes
  the `on_child_exited` handler with `@ptrCast(&g_dispatch)` while
  `g_dispatch.terminal` is still `undefined` at that point. The
  handler doesn't read `terminal` today, but the fragility is
  load-bearing on knowing which fields each handler touches
  (subsumed by the priority-#3 Dispatch refactor).

Resilience:

- **`notifier.zig` bell-sound proper wiring** — `playSound` logs
  the gap on first call today, but the user's `bell-sound`
  override still falls through to the per-kind hint
  (`dialog-warning` etc.). Real fix is either (a) wire VTE's
  `bell` signal in `terminal.zig` and route into a sound-only
  delivery, or (b) call `ca_context_play_full` from libcanberra
  (adds a runtime dep). Track until the bell subsystem itself
  lands.

Packaging:

- **`flake.nix:220`** — `homepage` URL duplicated in `PKGBUILD:7`,
  `debian/control:13`, `debian/copyright:4`. Single source of truth
  (or a comptime cross-check) avoids drift.
- **`build.zig:43-54`** — `ghostty_dep` branch duplicates the
  dependency call to drop two darwin-only options. A future
  ghostty rev that renames a required option breaks only one
  branch. Guard with a `comptime` validation or share an options
  struct.
- **`build.zig:111-119`** — `test_mod` on linux drags GTK system
  libraries onto the test build path; `zig build test` on a linux
  host without GTK4 dev headers fails at link time. Skip system
  libs for tests or document.
- **`PKGBUILD` depends list** — `pango`, `cairo`, `harfbuzz`
  explicit but `gdk-pixbuf2` is transitive. Half-explicit /
  half-transitive; pick one.
- **`debian/rules:38-43`** — empty `override_dh_auto_test:`
  silently skips the step. Comment-only; an `autopkgtest` config
  would be the proper way to enforce skip.

### Cross-cutting themes (synthesis)

1. **GLib main-thread blocking.** Tray's `pollAgentTick` now has
   the lock-ordering invariant documented (file-doc + Context
   field comments). Watcher coalesces GFileMonitor bursts via a
   100ms debounce so the per-save cost is one reload (≤60ms
   typical) instead of 5+ × 60ms. Notifier is mutex-free past
   first delivery via cached connection. Log pane holds
   `state.mutex` across each pollTick now — bounded, but a new
   point that future GLib callback authors should be aware of.
   Audit any new GLib callback for blocking I/O or contended
   locks against the same rule.
2. **GTK extern surface — consolidated.** `gtk.zig` now hosts
   the GLib/GTK helpers used by 3+ modules. Per-feature externs
   (gtk_window_*, vte_terminal_*, gtk_paned_*, pango_*,
   gtk_layer_*) stay scoped to their consumer.
3. **Platform abstraction — reverted to minimal surface.**
   `platform.zig` re-exports only `Notifier` + `NotifyKind` (the
   cross-OS consumers). Linux + darwin entries use direct
   imports for everything else. `platform/darwin.zig` shrunk
   from 14 stubs to 2.
4. **Threading model.** `state.mutex` ↔ GLib main lock-ordering
   documented in tray.zig file-doc; persist worker lifetime
   pinned (single in-flight, joined on shutdown); MCP accept
   thread joined via `McpServer.thread` on linux. Remaining
   under-documented surface: agent state's per-method contract
   (which methods take the mutex, who can call them concurrently)
   — could land as a section in `agent/state.zig`'s file-doc.
5. **Packaging not yet upstream-ready.** Debian source format
   workable but `dh_auto_configure` runs `zig build --fetch`
   (needs network in pbuilder); flake.nix `nix build .#default`
   relies on `__noChroot = true` (non-reproducible, non-substitutable).
   `-Dsystem-install=true` now owns the .desktop / .service /
   LICENSE / README drops under share/, so the orphan-on-uninstall
   hole is closed and the rules / PKGBUILD / nix derivation all
   share the same install transaction. Two independent blockers
   left for true distro inclusion; the GH-release tarball + AUR
   `djinn-git` PKGBUILD are the two working install paths today.
6. **Untested high-risk paths.** CI now covers linux — Ubuntu 24.04
   runs `zig build test` + debug build + ReleaseSafe + `--version`
   smoke on every push (`.github/workflows/ci.yml::linux`).
   main_linux now has its own smoke suite for the pure-data merge
   plumbing (`Config` round-trip, `mergeColor`, `buildThemeOptions`);
   what stays untested by `zig build test` is anything that drives
   GTK on the main thread — the actual `onConfigChanged` apply
   sequence, MCP live-flip, watcher reload re-entry, persist
   worker join. Those need a Wayland session and are covered by
   manual smoke runs.
7. **Install/uninstall asymmetry + path conflicts.** Arch/Debian/Nix
   all invoke `zig build install --prefix …`; no `zig build
   uninstall` exists. The `.desktop` identity at
   `/usr/share/applications/djinn.desktop` is what
   xdg-desktop-portal's hotkey approval persists against — a
   user-local install (`~/.local/share/applications/…`) silently
   breaks hotkey persistence. Document or block.

The full chain of landed themes from the prototype phase lives
on the `archive/linux/pre-squash-after-prototype` branch (local
+ personal upstream). Browse with `git log --oneline
archive/linux/pre-squash-after-prototype` and pick a SHA when
"why did we do it that way?" needs the original landing context;
the recurring decisions are already captured under `## Decisions
you should not undo`.

## Don't touch

- The macOS path. `src/main.zig`, `src/window/`, `src/hotkey/darwin.zig`,
  `src/notify/`, `src/system/loginitem.zig`, `src/terminal/`, etc. The
  port intentionally keeps the darwin path byte-for-byte intact. The
  one exception is `mcp/tools.zig`, which had to lose its
  `notify/darwin.zig` + `app.zig` imports for cross-OS use; the
  refactor was behavior-preserving on darwin (verified by passing
  `&config` + `&session_manager` at the same ToolTable construction
  site).
- `patches/ghostty-001-darwin-install.patch` and
  `scripts/apply-ghostty-patch.sh`. Cross-platform-safe, idempotent.
- "Phase N" markers in new linux code. Comments describe what the
  code IS, not the porting journey that produced it. The
  `chore(linux): drop stale port-narrative comments` commit pattern
  is the precedent.
