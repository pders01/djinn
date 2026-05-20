# djinn — Linux port handoff

You're picking up an in-flight port of djinn (originally macOS-only) to
Linux/Wayland. The terminal works; the chrome is mostly there. This file
is your map. Each subsystem has its own `src/platform/linux/<name>.zig`
with the design rationale in the file-doc — TODO.md stays terse and
points you at the source.

## Priority order

The original Important / Minor tiers have largely drained — see the
History block under `## Code review backlog` for the chain. What's
left is the Structural refactors batch:

1. **Structural refactors** — `log_pane.zig` extraction
   (1373 lines; pull `writeThemedCss` into `log_pane_css.zig`,
   move filter+header bookkeeping into a `LogModel`),
   `keymap.zig` `Context` god-object split before
   find_overlay / command_palette land.

Two batches landed since the last refresh:

- **Packaging cleanup** — `-Dsystem-install` gate in `build.zig`,
  PKGBUILD + `debian/rules` drop the manual LICENSE/README installs,
  `debian/djinn.install` declares the binary package's payload,
  flake.nix `nix run` exports LD_LIBRARY_PATH on linux + glib moves
  to buildInputs, `djinn.service` gains the conservative sandbox
  set + `StartLimitBurst`, `djinn.desktop` flips `StartupNotify=true`
  and documents the bare-Exec intent. Pbuilder debchroot + Nix
  `nix build` revalidation still wanted before declaring
  distro-ready.
- **Resilience polish** — `watcher.zig` survives
  destroy-and-recreate of the config dir via a 5s inode-health
  probe that rebuilds the GFileMonitor in place when the cached
  `st_ino` no longer matches; `dragdrop.zig` /tmp reaper now runs
  on a 30-minute `g_timeout_add` cadence in addition to the
  startup sweep, so long-running sessions don't accumulate temps;
  `notifier.zig::playSound` logs once per process when invoked so
  the `bell-sound` override gap is visible (the per-kind
  notification sound-name hint still plays — only the override is
  dropped today).

`mcp/tools.zig:43` `session_manager` type-purity audit and the
remaining Minor code-shape items (terminal.zig argv const, hotkey
errdefer gap, unique_name re-fetch, watcher partial-init cleanup,
ghostty_config detectAppearance GVariant ownership style) are
small one-line edits and a good warm-up before the structural
refactors above.

The "Cross-cutting themes" subsection at the end of the backlog
names patterns rather than files.

Commit conventions: conventional-commits subject (`fix(linux): …`,
`feat(...)`, `docs(...)`, `build: …`), `- ` bullet bodies wrapped
~80 chars, no `Co-Authored-By` trailer. Bodies are declarative —
they state what the code now does, not the discovery path
("previously…", "without this would…", "wrong twice over"). Bundled
changes split into separate commits. `git log --oneline` for the
prevailing shape.

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
- `terminal.zig` + `theme.zig` — VTE widget embedded as the panel's
  child, spawns `$SHELL` (fallback `/bin/sh`), applies
  `config.terminal.*` + `config.theme.*` (font / fg / bg / cursor /
  padding / palette[0..15] / opacity) via VTE setters and a single
  module-level GtkCssProvider that gets reloaded in place on each
  apply (so live-reload doesn't stack providers). `applyFont` runs a Pango font-family availability
  check before setting `vte_terminal_set_font` and logs a clear
  warning when the family isn't installed (avoids the "wide-cell"
  rendering bug from silent Pango substitution to non-monospace).
  `child-exited` is wired to `panel.quit` so typing `exit` closes
  the window. SIGTERM is routed onto the GLib main loop via
  `g_unix_signal_add` and quits the panel cleanly — needed by
  systemd user units. SIGINT already worked through GLib's default
  signal-fd watch.
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
- `log_pane.zig` — right-hand column inside a horizontal `GtkPaned`
  next to the VTE. Widget tree: outer vertical `GtkBox` →
  (attention `GtkButton`, `GtkScrolledWindow → GtkListBox`,
  `GtkSearchEntry`). CSS-node gotcha: GtkListBox's node is `list`,
  NOT `listbox` — easy to lose hours on. Per-level CSS classes
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
  beat VTE's internal shortcut set. Eleven entries (`installed 11/11`
  banner on startup):
  - `font_inc` / `font_inc_shift` / `font_dec` / `font_reset`
    (Ctrl+= / Ctrl+Shift+= / Ctrl+- / Ctrl+0)
  - `clear_scrollback` (Ctrl+Shift+K) — `vte_terminal_reset` then
    `\x0c` (Ctrl+L) via `feed_child` so readline redraws the
    prompt at the cleared top
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
  - `hide_panel` (Escape) — gated by `predHideOnEscape`, only
    consumes the key when `window.hide_on_escape = true`;
    propagates to VTE otherwise so TUIs (vim, less, htop, fzf)
    keep working. Action table grew a per-row `predicate` field
    for this — handlers return 0 (not-handled) when the
    predicate rejects, letting GTK continue propagation.
  Context carries `terminal`, `allocator`, `log_pane`, `panel`,
  `config`. Subset of darwin's `terminal/view.zig::actions` —
  entries tied to features that don't exist on linux yet (tabs,
  find, theme toggle, cheatsheet) land as their backing features
  do.
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

- SessionManager + multi-profile + tab strip + command palette
  + find overlay. SessionManager itself is platform-agnostic, but
  its surface_host wiring is darwin-only (each session binds to a
  ghostty surface). Linux would need one VTE per session with
  siblings hidden — a larger task, kept off this priority list
  until someone asks for it. Find overlay + command palette can
  land independently of multi-profile (see pick-up #7).

## Decisions you should not undo

- **VTE, not ghostty, on linux.** ghostty's embeddable surface C API
  is darwin/iOS only (no GTK variant in `src/apprt/embedded.zig`), and
  ghostty's GTK frontend is a full `GtkApplication`, not a library.
  macOS keeps using ghostty. djinn's value-add is the chrome, not the
  terminal engine.
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
      ipc.zig               # Unix-socket toggle bridge
      hotkey.zig            # xdg-desktop-portal.GlobalShortcuts client
      tray.zig              # StatusNotifierItem + dbusmenu
      notifier.zig          # org.freedesktop.Notifications client
      watcher.zig           # GFileMonitor parent-dir watch
      autostart.zig         # XDG .desktop autostart entry
      dragdrop.zig          # GtkDropTarget on the VTE widget
      keymap.zig            # GtkShortcutController actions table
      log_pane.zig          # GtkPaned sibling: log entries + theme
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

The original port's phased rollout — packaging, cold-path
live-apply, CLI overrides, keymap expansion, log pane MVP —
all shipped. `git log --grep=linux --oneline` carries the
chain. Two gotchas the next agent should not re-discover:

- **Toolchain pin: `zig0.15` from AUR**, not Arch's stock `zig`.
  Current Arch zig is 0.16 and ghostty's `requireZig` rejects
  it with a `@compileError`. Ghostty `main` still pins
  `minimum_zig_version = "0.15.2"` (revisit quarterly). On
  Nix the dev shell pins the right version; on Debian zig
  isn't in the archive so `rules` uses `$(ZIG)`.
- **Keymap shortcut extension pattern.** A new shortcut is
  one row in `keymap.zig`'s `actions` array + a handler
  function. The `predicate` field gates whether the row
  consumes the key or propagates to VTE (`hide_panel` /
  `Escape` is the precedent — predicate reads
  `ctx.config.window.hide_on_escape`, returns false → handler
  returns 0 → GTK continues propagation). `KeymapContext`
  carries `{terminal, allocator, log_pane, panel, config}` —
  trending toward god-object (see Minor backlog).

### Multi-profile *(deferred — needs design)*

Linux runs one VTE; darwin runs N ghostty surfaces with siblings
hidden + a tab strip + `Cmd+Shift+P` palette switcher.
SessionManager core is platform-agnostic but its surface_host
wiring is darwin-only. Off-list until someone asks; expect a
multi-week commitment + a design pass on whether linux uses
N VTE widgets or N-PTYs-into-one-VTE (the latter is closer to
ghostty's "tabs as logical sessions" but harder to surface in
GTK).

### Independent small bites *(any order)*

Don't depend on each other or on multi-profile. Sized so each
is one focused session.

- **Find overlay** (`<Control><Shift>f`, ~1 day).
  VTE has `vte_terminal_search_set_regex` +
  `vte_terminal_search_find_next` / `_find_previous`.
  Surface a `GtkPopover` anchored to the top of the panel with
  a `GtkEntry` + prev/next buttons. Darwin uses ghostty's
  built-in find via `forwardBindingAction("search:foo")`;
  linux is greenfield.
- **Command palette** (`<Control><Shift>p`, ~1 day).
  `GtkPopover` with `GtkEntry` fuzzy-filter + `GtkListView`
  of matching actions; invoke via the same handler chain
  keymap.zig uses. Caveat: with ~10 actions and no
  multi-profile, value-per-effort is low — palette earns its
  keep once multi-profile lands and profile-switching needs
  a search UI.
- **Per-state djinn tray icon** (small).
  `tray.zig` currently uses generic freedesktop names
  (`utilities-terminal`, `dialog-warning`, …). Ship per-state
  SVGs into a hicolor theme path during packaging and swap
  `iconName` to `djinn-idle` / `djinn-working` / etc.
- **Log pane divider persistence.** GtkPaned tracks position
  via user drag automatically; persist to `state.json`
  (`state/persist.zig` is wired on linux; add a divider-fraction
  field) and restore on next launch. Defer until multi-profile
  since per-profile widths are the natural unit.

## Known issues

- **No per-profile window size memory.** Top-level size persists
  via `persist.saveDebounced(allocator, w, h, null)` — SessionManager
  not wired yet, so the `null` profile name means every profile
  (when multi-profile lands) would clobber the same slot. Plumb
  the active profile name through `Dispatch.onPanelResize` once #6
  ships.
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

A four-slice review of `origin/main..HEAD` (2026-05-17, 48 commits,
~10k LoC) surfaced these. Items are grouped by severity; within a
severity, related items are clustered so a fix session can sweep
one theme at a time. Each entry: `file:line` + 1-line description.
Landed entries are pruned as work lands — `git log --grep=linux`
carries the history. The Critical-tier (debian source format, link
order, ghostty theme-name validation, PKGBUILD git-variant) all
landed in the original 2026-05-17 pass.

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

MCP cross-OS refactor:

- **`mcp/tools.zig:43`** — `session_manager: ?*SessionManager`
  imports `../session/manager.zig` from linux. Verify the type
  alone is platform-agnostic; if `session/manager.zig` transitively
  pulls darwin-specific code, linux build breaks.

### Minor — track, not blocking

Code-shape:

- **`terminal.zig:243`** — `argv[0..2]` magic number duplicated
  against the `alloc(?[*:0]u8, 2)` site. Field or const.
- **`keymap.zig` `Context`** — five fields (`terminal`, `allocator`,
  `log_pane`, `panel`, `config`) trending toward god-object as
  find_overlay + command_palette land. Consider per-action
  `*anyopaque` user_data or a `Services` registry.
- **`log_pane.zig` size** — 1373 lines, multiple concerns. Extract
  `writeThemedCss` (~280 lines) to `log_pane_css.zig`; pull
  filter+header bookkeeping into a `LogModel` struct.
- **`hotkey.zig` errdefer cleanup gap** on init failure between
  the last subscribe and the trailing alloc/dup steps. Latent
  today (no allocs after subscribes) but trap for the next edit.
- **`hotkey.zig:466, 553`** — `unique_name` re-fetched per call.
  Stash once in `Context`; the unique name is fixed for the
  connection's lifetime.
- **`watcher.zig:140-145`** — partial init failure cleanup
  increments `built` after a fallible alloc. Latent today;
  refactor-prone.
- **`ghostty_config.zig:340-376` `detectAppearance`** — builds
  `params` without explicit floating-ref handling, while
  `hotkey.zig` / `tray.zig` use builder-based construction. Mixed
  GVariant ownership styles make audits harder.
- **`dragdrop.zig:139`** — two `GtkDropTarget`s attached, neither
  detached. Widget lifetime cleans up via parent destroy, but a
  double `dragdrop.attach` (refactor mishap) silently stacks the
  controllers.
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
   `djinn-git` PKGBUILD are the two working install paths today
   (see History).
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

History (landed themes — kept for context, `git log --grep=linux`
has the chain):

- **Resilience polish pass** — `watcher.zig` now survives
  destroy-and-recreate of the config dir (`rm -rf ~/.config/djinn;
  mkdir ~/.config/djinn`, an editor that does the same, a config
  rotation script). A new 5-second GLib timeout walks every entry,
  compares each parent path's `st_ino` against the value cached at
  init / last rebuild, and on mismatch rebuilds the GFile +
  GFileMonitor + signal subscription in place — then schedules a
  coalesce fire so the caller's `on_changed` re-reads through the
  new inode. Same-FS `mv` round-trips were already safe (inotify
  watches by inode; rename preserves it). `EntryContext.parent_ino`
  caches the inode; 0 doubles as a "disable recheck" sentinel for
  entries whose init-time stat failed. `dragdrop.zig` /tmp reaper
  now fires on a 30-minute `g_timeout_add` cadence in addition to
  the startup sweep — a 9-hour workday with 100 image drops no
  longer accumulates temps until djinn restarts. `notifier.zig`'s
  `playSound` stub gained a one-shot stderr warning on first call
  so the `bell-sound` override gap is visible (`tools.zig` invokes
  it after every successful `sendKind`, once per 30s per (kind,
  client) bucket by rate-limit default); the per-kind notification
  sound-name hint set by `deliver` still plays through the
  notification daemon — only the user override falls through. New
  `readParentInode detects destroy-recreate inode swap` test
  exercises the kernel + std.fs.statFile path the recheck relies
  on: same-FS rename keeps the inode invariant, destroy-recreate
  rotates it, missing path returns the 0 sentinel.
- **Packaging cleanup pass** — `build.zig` grows a
  `-Dsystem-install` option; the linux install branch is gated so
  `zig build install` from a dev tree drops only `zig-out/bin/djinn`,
  while distro recipes (PKGBUILD, debian/rules, flake.nix) pass
  `-Dsystem-install=true` to also land .desktop + systemd user
  unit + LICENSE + README under `share/`. PKGBUILD + debian/rules
  drop their out-of-band `install -Dm644` calls, closing the
  orphan-on-uninstall gap. `debian/rules` stages into
  `debian/tmp/usr` and the new `debian/djinn.install` declares the
  binary package's payload — no more hardcoded `debian/djinn/usr`.
  `flake.nix nix run .#` on linux exports `LD_LIBRARY_PATH`
  against `linuxDeps` so a fresh `nix run` doesn't fail at first
  GTK dlopen on NixOS; `glib` moves from `nativeBuildInputs` into
  the shared `linuxDeps` (runtime library, not a build tool);
  `dontWrapGApps = false` line drops in favor of the
  wrapGAppsHook4 default with a corrected rationale comment.
  `djinn.service` gains the conservative sandbox set
  (`NoNewPrivileges`, `ProtectKernel{Tunables,Modules,Logs}`,
  `ProtectControlGroups`, `LockPersonality`, `RestrictSUIDSGID`,
  `RestrictRealtime`, `MemoryDenyWriteExecute`) plus
  `StartLimitBurst=5` / `StartLimitIntervalSec=30s` so a panic
  loop trips a transient failure state instead of flooding the
  journal indefinitely; the Hyprland / bare-sway `uwsm` caveat
  for `graphical-session.target` is documented in `[Unit]`.
  `djinn.desktop` flips `StartupNotify=true` (GTK4 emits the
  notification ID automatically at panel map; the prior `false`
  paired with `StartupWMClass=djinn` left KDE's launcher spinner
  ticking until protocol timeout), and the comments now explain
  why `Exec=djinn` stays bare (same .desktop ships from both
  `/usr` system installs and the nix derivation) and why
  `MimeType=` is deliberately omitted.
- **Minor-tier pass — robustness across the platform layer** —
  UTF-8 boundary truncation for notifier banners + log_pane
  attention chip (`utf8FloorBoundary` helper); error-visibility
  pass on `loadConfigWithRetry`, panel `detect` allocator,
  `ipc` unlink, `keymap` makePath, reapDragDropTemps iterate;
  defensive bounds in `theme::applyCss` (NoSpace bubble + empty
  CSS guard), `dragdrop::formatPayload` (bare-file:// skip,
  truncation log), `ghostty_config` (FileTooBig graceful, inline
  `# comment` strip that preserves hex sigils);
  long-running resilience via `PORTAL_CALL_TIMEOUT_MS=30s`,
  `autostart::register` atomic .tmp + rename,
  `autostart::resolveExePath` strips ` (deleted)`, `ipc` accept
  loop capped at 32 iters/dispatch with read-error logging,
  `keymap::trySpawnDetached` registers each child with
  `g_child_watch_add` for GLib-side reaping;
  `cli::consumeValue` rejects flag-like values for --hotkey /
  --provider; `mcp::handleConnection` returns 400 instead of
  RST on body-read failure.
- **log_pane appendRange lock window** — `appendRange` (now
  `appendRangeLocked`) requires the caller to hold `state.mutex`.
  `pollTick` and `rebuildAll` both acquire the lock once across
  snapshot + row builds instead of dropping it between phases.
  GTK calls happen under the lock, but the tick is bounded
  (every 250ms, typical 0-few rows) so MCP worker contention is
  negligible. The prior shape let a concurrent `appendLog`
  eviction shift the `[from..from+count]` window onto different
  entries than the snapshot intended — corrupt row text and
  dangling slice reads on the freed string.
- **tray.zig threading-model docs** — file-doc spells out the
  GLib main-thread invariant for `ctx.state`, `ctx.message_buf`,
  `ctx.message_len`, plus the lock-ordering rule w.r.t.
  `state.mutex` (GLib main may wait on it; mutex holders never
  wait on GLib). `pollAgentTick`'s brief lock acquisition is now
  documented as the established direction; future GLib callbacks
  that introduce blocking I/O or contended locks need an audit
  pass against this rule.
- **GTK extern consolidation** — `gtk.zig` now hosts the shared
  GLib/GTK surface: `g_signal_connect_data`,
  `g_signal_handler_disconnect`, `g_timeout_add`, `g_idle_add`,
  `g_source_remove`, `g_object_unref`, `g_free`,
  `gdk_display_get_default`, `gtk_widget_set/get_visible`,
  `gtk_widget_add_controller`, `gtk_css_provider_*`,
  `gtk_style_context_add_provider_for_display`. Reconciles
  `g_source_remove`'s previously-divergent `c_int` / `gboolean`
  return types onto the canonical `gboolean` spelling. Each
  consumer module aliases the shared declaration (`const
  g_signal_connect_data = gtk.g_signal_connect_data;`) instead
  of redeclaring its own extern. Same shape as the landed
  `gdbus.zig` extraction. Per-feature externs (gtk_window_new,
  vte_terminal_*, gtk_paned_*, pango_*, gtk_layer_*) stay
  scoped to their consumer.
- **platform.zig dead-stub revert** — abstraction surface shrunk
  from 14 re-exports to just `Notifier` + `NotifyKind` (the only
  cross-OS consumers — `mcp/tools.zig`). `main_linux.zig` now
  imports `platform/linux.zig` directly under the same `platform`
  alias; the linux call sites don't change. `platform/darwin.zig`
  drops 12 unused stubs that had been accumulating drift against
  the real linux types (ThemeOptions `_hex` suffixes,
  KeymapContext field-count mismatch). Net: ~170 lines removed,
  no behavior change on either OS.
- **MCP accept-thread error logging** — `handleConnection` now
  returns `!void`; `run()` logs the error before continuing so a
  recurring bug (parser regression, OOM, partial-read I/O) becomes
  visible instead of silently disabling every MCP request. The
  accept-fail backoff path also checks `stop_flag` before logging,
  so `deinit` no longer prints a spurious "accept failed" warning
  when it closes the listener.
- **Hotkey aggregate outcome reporter** — `hotkey.zig` emits one
  definitive log line per `init()` attempt: `"hotkey: portal
  active — trigger "<X>""` on success, `"hotkey: portal unavailable
  — <reason>"` on failure. The sync paths (session bus, unique
  name, trigger parse) and async terminal points (CreateSession
  reply / Response status, BindShortcuts reply / Response status)
  all flow through `reportSuccess` / `reportFailure` / `reportSync
  Failure`. `ctx.outcome_reported` latches the first reporter call
  so duplicate handlers don't double-log. `main_linux.zig` no
  longer prints its own "init failed" line on the cold path; the
  reload path replaces its "rebind failed: <err>" line with a
  concise "previous binding still active" since hotkey.zig now
  carries the failure detail.
- **main_linux smoke tests** — `Config.parse` + `deinit` round-
  trip (covers the live-reload arena drop), `mergeColor` priority
  (djinn hex wins, ghostty fallback, malformed-hex fall-through,
  null when both unset), `buildThemeOptions` merge order (djinn
  wins on every field, ghostty fills gaps including palette, no-
  inheritance path), `strOptEql` identity. The full GTK-bound
  `onConfigChanged` flow stays covered by manual smoke runs on a
  Wayland session — the testable building blocks are now wired so
  a regression in the merge rules surfaces under `zig build test`.
- **Signal-handler lifecycle** — panel/terminal/log_pane all stash
  handler ids and disconnect in `deinit` before any free that
  invalidates user_data. New GTK modules should follow this shape.
- **Live-reload Config string ownership** — internal
  `ArenaAllocator` per Config; deinit drops it as a single
  transaction; linux wires deinit on shutdown + live-reload.
  Darwin wires shutdown only — its `resolveEntry` would need to
  copy strings through `owned_strings` before live-reload deinit
  becomes safe (Sessions store raw arena pointers).
- **GDBus consolidation** — `platform/linux/gdbus.zig` holds the
  shared D-Bus surface; the four consumers route through it.
- **Notifier session bus connection caching** — cached on the
  Notifier struct under `conn_mutex`, lazy-acquired, unref'd by
  `deinit`. Three GDBus consumers each acquire-and-unref their
  own connection now (hotkey + tray + notifier); ghostty config
  acquires once at startup. A `gdbus.zig` singleton with borrow
  semantics could consolidate further, but defer until a new
  consumer needs it.
- **Persist worker thread lifetime** — `state/persist.zig` tracks
  the in-flight `std.Thread` handle in `g_thread`, loops a single
  worker through accumulated dirty values (debouncing at 300ms
  per write), and `main_linux.zig` defers `joinPendingSave`
  before `gpa.deinit` so a mid-sleep worker can't outlive the
  allocator. The detach-per-save shape it replaced let a worker
  dereference freed gpa state at shutdown.
- **Dispatch null-safety** — `main_linux.zig::Dispatch` declares
  its seven late-stamped fields as optional pointers defaulting
  to null instead of the prior `undefined` placeholders. The
  initial `g_dispatch = .{ … }` literal carries only the
  always-present fields (allocator / panel / config /
  ghostty_colors); each subsystem stamps its slot non-null right
  after construction. `onConfigChanged` opens with a readiness
  gate that unwraps every slot via `logDispatchUnready` —
  callbacks that fire before their dependencies are wired bail
  with a clear log instead of dereferencing undefined memory.
- **Watcher event coalescing** — `watcher.zig` allocates a single
  shared `CoalesceState` per `Watcher` that owns the user's
  Handler plus a `g_timeout_add` source id. Each entry's
  GFileMonitor signal handler schedules a 100ms leading-edge
  debounce via `coalesce.schedule`; subsequent events while the
  timer is pending no-op. Fires the user's `on_changed` exactly
  once per save (or per cross-file save in the same window).
  `deinit` removes a pending timer before freeing entries so the
  fire callback can't dispatch into half-freed state. The prior
  shape called the handler directly from every event — 5+ fires
  per atomic-rename save, multiplied by the 60ms retry budget
  in `onConfigChanged` for ~900ms of main-thread blocking on
  rapid `:w`.
- **SNI watcher recovery** — `tray.zig` subscribes to
  `org.freedesktop.DBus.NameOwnerChanged` filtered on
  `arg0=org.kde.StatusNotifierWatcher` before the initial
  `RegisterStatusNotifierItem` call. `onWatcherNameOwnerChanged`
  re-issues `sendRegisterRequest` whenever a new owner takes the
  well-known name — plasmashell / waybar / xfce4-panel restarts
  mid-session, GNOME AppIndicator extension reload, or the host
  coming up after djinn (user logs into Plasma post-launch). The
  exported `/StatusNotifierItem` + `/MenuBar` objects survive
  across watcher restarts because they live on the bus connection,
  so re-registering is the only step needed to restore visibility.
- **Hotkey canonical Request-path** — `hotkey.zig::reconcileRequestPath`
  parses the `(o)` Request path from CreateSession and
  BindShortcuts method replies and swaps the Response subscription
  onto the canonical path when it differs from the locally-
  predicted one. xdg-desktop-portal documents the request-path
  scheme but KDE has historically renamed segments; under the
  prior shape the Response signal could fire on a path we weren't
  subscribed to and the binding would silently fail. Prediction
  stays as the pre-subscribe path so the Response can't fire
  between method call and reply (the Request body runs after the
  reply, so the canonical re-subscribe is race-safe).
- **IPC socket mode** — `ipc.zig::Ipc.init` narrows the process
  umask to 0077 around `bind()` and restores it via defer; the
  socket inode is created with mode 0600 atomically. Race-free
  against any local user `nc -U`-ing the verb stream — covers the
  `/tmp/djinn-<uid>.sock` fallback path where the runtime dir
  isn't 0700-protected.
- **CI + release pipeline cover linux** —
  `.github/workflows/ci.yml::linux` runs on `ubuntu-24.04`,
  apt-installs `libgtk-4-dev` / `libgtk4-layer-shell-dev` /
  `libvte-2.91-gtk4-dev` / `libglib2.0-dev` / `pkg-config`, then
  exercises `zig build test` + debug build + ReleaseSafe + a
  `djinn --version` smoke. `release.yml::build-linux` and
  `pre-release.yml::build-linux` produce a
  `djinn-${tag}-x86_64-linux.tar.gz` containing the ReleaseSafe
  binary + `.desktop` + `.service` + LICENSE + NOTICES + README.
  pre-release linux is sequenced AFTER the darwin `publish` job so
  the delete-and-recreate of the rolling tag can't race the linux
  upload. aarch64-linux deferred.
- **README + just install-arch** — README intro names both macOS
  and Linux; the `## Linux (Wayland)` section covers prereqs per
  distro, four install paths (AUR PKGBUILD, `just install-arch`,
  manual zig build, pre-built tarball), the two-step KDE hotkey
  flow (portal registration + System Settings binding), IPC
  socket fallback for compositors without
  `xdg-desktop-portal.GlobalShortcuts`, systemd user unit opt-in,
  and a troubleshooting list. `justfile` gains `install-arch` /
  `uninstall-arch` for fast dev iteration outside pacman tracking;
  `arch_zig` probes for `/usr/bin/zig-0.15` (AUR) before falling
  back to the nix dev shell so the recipe doesn't accidentally
  pick Arch's stock 0.16 zig.

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
