# djinn — Linux port handoff

You're picking up an in-flight port of djinn (originally macOS-only) to
Linux/Wayland. The terminal works; the chrome is mostly there. This file
is your map. Each subsystem has its own `src/platform/linux/<name>.zig`
with the design rationale in the file-doc — TODO.md stays terse and
points you at the source.

## Priority order

Top three from the `## Code review backlog` section, ranked by
production risk. Prior top-three (Config live-reload arena,
signal-handler lifecycle sweep, GDBus extraction, persist worker
thread lifetime, Dispatch undefined-then-stamped, watcher event
coalescing, SNI watcher recovery, hotkey Request-path desync, IPC
`/tmp` socket permissions) all landed — `git log --grep=linux`
carries the trail.

1. **`mcp/server.zig` accept-thread panic recovery.** `run()`
   returns void; a panic in `handleConnection` kills the accept
   thread with no log signal. On linux's live-apply path the server
   may run for hours; a single hot bug silently disables MCP until
   the next config reload re-spawns it. Wrap each connection in a
   panic recovery + log.
2. **`main_linux.zig` has no unit tests of its own.** The
   `test {}` block re-exports submodules; the watcher reload,
   Dispatch stamping, persist worker lifetime, and MCP start/stop
   on live-flip — the highest-risk surfaces in the branch — are
   unverified by `zig build test`. Now that CI covers linux,
   regressions on these paths land green. Add at least a smoke
   test for `onConfigChanged` + Config round-trip.
3. **`hotkey.zig` silent fall-through hierarchy.** When portal
   init fails (invalid trigger, CreateSession error, status != 0,
   no portal backend), each failure mode logs to stderr but there
   is no positive log signal beyond `portal registration confirmed`.
   The README points users at `Gtk-WARNING` grep for CSS issues
   but the hotkey path has no equivalent diagnostic. Aggregate the
   failure paths into a single logged outcome ("portal hotkey
   active" / "portal hotkey unavailable: <reason>").

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
  a 1 MiB read. Light/dark variants picked from
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
  verb stream regardless of which path is chosen.
- `hotkey.zig` — `xdg-desktop-portal.GlobalShortcuts` over GDBus.
  Auto-registers from `config.hotkey.toggle`; first launch on KDE pops
  a confirmation dialog, subsequent launches are silent. The method
  reply's canonical `(o)` Request path is reconciled against the
  locally-predicted path in both the CreateSession and BindShortcuts
  callbacks via `reconcileRequestPath` — if the portal renames the
  request segment (KDE has done this), the Response subscription
  swaps onto the canonical path before the body executes. Falls
  through to the IPC bridge when no portal backend implements
  GlobalShortcuts.
- `log_pane.zig` — right-hand column inside a horizontal `GtkPaned`
  next to the VTE. Widget tree: outer vertical `GtkBox` →
  (attention `GtkButton`, `GtkScrolledWindow → GtkListBox`,
  `GtkSearchEntry`). CSS-node gotcha: GtkListBox's node is `list`,
  NOT `listbox` — easy to lose hours on. Per-level CSS classes
  (`.djinn-log-info` / `-warn` / `-err`) on a module-local
  reload-in-place provider. 250ms `g_timeout_add` poll same shape
  as tray's — diffs `(count, first_ts)` and either appends new
  rows or rebuilds when the ring evicts. Auto-scroll to newest via
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
  bus loss retries automatically on the next send.
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
  `config.system.open_at_login`. `Exec=` from `/proc/self/exe`.
  Replaces SMAppService.
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
  rather than rasterized previews. `main_linux.zig::reapDragDropTemps`
  runs once at startup to clear entries older than 1h.
- MCP HTTP server in `main_linux.zig` — same wiring shape as darwin's:
  `AgentState → Notifier → ToolTable → Dispatcher → McpServer` on a
  detached thread, gated on `mcp-enabled`. Endpoint info in
  `~/.config/djinn/mcp.json`.

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

GLib main-thread blocking surfaces (each independently fixable; the
pattern is the issue):

- **`tray.zig::pollAgentTick`** — grabs `state.mutex` from a GLib
  callback. No documented lock-ordering invariant against other
  threads that may hold it while calling GLib. Document the
  invariant or move to try-lock.
- **`main_linux.zig::onConfigChanged` reload on main thread** —
  with watcher debouncing landed, the per-save cost is now
  `Config.load` + ghostty parse + theme apply on the GLib main
  thread (≤60ms typical, 3× 20ms only on the atomic-rename ENOENT
  retry path). No longer a real blocker — track here in case the
  config parse grows. Off-thread reload would need `g_idle_add`
  marshalling because the apply path (panel.setSize, applyTheme,
  setVisible) is GTK-bound.

Concurrency + threading correctness:

- **`log_pane.zig appendRange`** — releases `state.mutex` between
  pollTick's snapshot and appendRange's re-lock. Concurrent
  `appendLogFrom` eviction in that window mis-indexes rows.
  Recovers on next tick's `.rebuild` (since `first_ts` differs) but
  produces one tick of wrong display. Hold the lock across the whole
  tick or copy entry bytes inside the snapshot lock.

System integration recovery + auth:

- **`hotkey.zig:202-223`** — silent fall-through hierarchy. The
  TODO claim "fall through to IPC bridge" isn't an active fallback;
  the IPC bridge is always running and `init` just logs each
  failure mode to stderr (invalid trigger, CreateSession error,
  status != 0, no portal). No positive log signal for "hotkey is
  working" beyond `portal registration confirmed`; if that signal
  is missed for any reason, the user gets neither error nor
  confirmation. Aggregate the failure paths into a single logged
  outcome. This is **priority #3**.
- **`tray.zig:516-532, 757, 785`** — `message_buf` is mutated in
  `pollAgentTick` (GLib main thread) and read from property-getter
  paths (`sniGetProperty` / `buildToolTip`) without explicit
  synchronization. Safe today because GDBus dispatches on the
  default main context, but the invariant is unstated. Assert
  main-thread ownership (`g_main_context_is_owner`) or move under
  a mutex.

Code-shape duplication ripe for extraction:

- **GTK externs × 4+ files** — `g_signal_connect_data`,
  `g_timeout_add`, `g_source_remove`, `g_object_unref`,
  `gdk_display_get_default`, `gtk_widget_set/get_visible`,
  `gtk_widget_add_controller`, `gtk_css_provider_*`,
  `gtk_style_context_add_provider_for_display` duplicated across
  panel/terminal/log_pane/tray/watcher. `g_source_remove` already
  has divergent return types (`c_int` in ipc/tray, `gboolean` in
  panel/log_pane). Same shape of consolidation as the landed
  `gdbus.zig` — carry the surface in `gtk.zig` (which is types-only
  today) or a sibling `glib.zig` if the GTK/GLib split matters.

Cross-OS abstraction:

- **`platform.zig:41-61` + `platform/darwin.zig`** — abstraction is
  ornamental for darwin. `main.zig` still imports `hotkey/darwin.zig`,
  `notify/menubar.zig`, `system/loginitem.zig` directly. 12 of 14
  darwin re-exports are dead stubs (only `Notifier` flows through).
  `ThemeOptions` fields diverge (linux has `background`/`foreground`/
  `cursor`/`opacity`/`palette`; darwin stub has `_hex`-suffixed
  triplet, no opacity, no palette). Either commit to the migration
  or revert the dead surface.

Build + packaging:

- **`flake.nix nix run .#`** — no LD_LIBRARY_PATH wrapper for
  linux. Dev shell exports it; the runner does not. NixOS users
  link fine then fail at first GTK dlopen. Wrap the runner with
  `makeWrapper` or document.
- **`flake.nix:182`** — `glib` in `nativeBuildInputs` but it's a
  runtime library. Move to `buildInputs`.
- **`debian/control` + `debian/rules:19-25`** — no
  `Build-Depends: zig (>= 0.15)` because zig isn't in the Debian
  archive; `dh_auto_configure` runs `zig build --fetch` which
  needs network. Unbuildable on fresh pbuilder chroot
  (architectural dead-end until zig is archived or vendored).
- **`debian/rules:35-36`** — `--prefix debian/djinn/usr` hardcodes
  the binary package name. Breaks if a second binary package
  appears (`djinn-doc`, `djinn-dbgsym`). Use `debian/tmp/usr` +
  `dh_install` reading `debian/djinn.install`, or
  `debian/$(DEB_SOURCE)/usr`.
- **`djinn.service`** — no sandboxing directives
  (`NoNewPrivileges=`, `ProtectSystem=`, `LockPersonality=` cost
  nothing). No `StartLimitBurst=` — tight panic loop respawns every
  2s indefinitely.
- **`djinn.service:11-12`** — `After=graphical-session.target` +
  `PartOf=graphical-session.target` is correct on KDE/GNOME but
  the user must explicitly `systemctl --user start
  graphical-session.target` on Hyprland/sway unless they use a
  session manager (`uwsm`, `niri-session`). Without it the unit
  sits `inactive` forever. Add fallback `After=` or document the
  prereq via `Documentation=`.
- **`djinn.service:38-39`** — `WantedBy=graphical-session.target`
  with transient targets is fragile across compositor restarts:
  `PartOf=` stops djinn but `WantedBy=` of a transient target
  doesn't necessarily re-pull it. Test path: log out → log back
  in → verify djinn restarts. Consider `WantedBy=default.target`
  + `Requisite=graphical-session.target`.
- **`djinn.desktop:8`** — `Categories=Utility;TerminalEmulator;`
  + `Terminal=false` + no `MimeType=` line means djinn won't
  appear as an "Open in Terminal" handler for file managers. If
  that's deliberate, document. Otherwise add appropriate MIME
  handlers.
- **`flake.nix:190-197`** — `__noChroot = true` on
  `packages.default` (not just `checks`) makes
  `nix build .#default` non-reproducible and non-substitutable.
  `nix profile install` re-downloads ghostty on every rebuild.
  The cleaner architectural fix is `zon2nix` vendoring so the
  package builds in the sandbox while `checks` retains
  `__noChroot`.
- **`build.zig:80-97`** — `.desktop` + `.service` installed even on
  `zig build run` from a dev tree. Gate on a `system-install` build
  option.
- **`PKGBUILD` `package()` lines 90-91** — `install -Dm644 LICENSE
  ...` and `README.md` placed manually after `zig build install`.
  Files aren't registered with zig's install step, so a future
  `zig build uninstall` would orphan them. Either move into
  `b.installFile` paths or document the gap.

MCP cross-OS refactor:

- **`mcp/tools.zig:43`** — `session_manager: ?*SessionManager`
  imports `../session/manager.zig` from linux. Verify the type
  alone is platform-agnostic; if `session/manager.zig` transitively
  pulls darwin-specific code, linux build breaks.
- **`mcp/server.zig:81-95`** — `run()` returns void; panic in
  `handleConnection` kills the accept thread with no log signal.
  On linux's live-apply path the server may run for hours; a single
  hot bug silently disables MCP. Wrap each connection in a panic
  recovery + log. This is **priority #1**.

Untested critical paths:

- **`main_linux.zig` has no unit tests of its own.** The test {}
  block re-exports submodules; the Dispatch stamping order,
  `onConfigChanged` lifecycle, MCP start/stop on live-flip,
  watcher reload, persist worker thread lifetime — the highest-
  risk surfaces in the branch — are unverified by `zig build test`.
  Add at least a smoke test that exercises the watcher's reload
  branch + a Config-with-deinit round-trip. This is **priority #2**.

### Minor — track, not blocking

- **`cli.zig:48`** — `djinn --hotkey` with no following arg silently
  consumes the next flag (`--provider claude` becomes the hotkey
  value).
- **`mcp/server.zig:130-152`** — content-length body read silently
  RSTs the client on partial read. Match the `n == 0` path's
  "incomplete body" 400 response.
- **`theme.zig:362`** — sentinel cast on potentially-empty buffer:
  empty CSS string loads on a reload where neither padding nor
  opacity is set. Guard `css_len > 0`.
- **`terminal.zig:243`** — `argv[0..2]` magic number duplicated
  against the `alloc(?[*:0]u8, 2)` site. Field or const.
- **`keymap.zig` `Context`** — five fields (`terminal`, `allocator`,
  `log_pane`, `panel`, `config`) trending toward god-object as
  find_overlay + command_palette land. Consider per-action
  `*anyopaque` user_data or a `Services` registry.
- **`keymap.zig:312`** — `std.fs.cwd().makePath(dir)` swallowed;
  ENOSPC / EACCES hidden, subsequent createFile reports confusing error.
- **`keymap.zig trySpawnDetached`** — doesn't reap the spawned
  child. One zombie per invocation until djinn exits. Documented on
  `onOpenSettings` only; future callers will hit it without warning.
- **`dragdrop.zig` /tmp cleanup** — `reapDragDropTemps` runs at
  startup only. Crash mid-session persists temps until next
  successful launch. Track per-session paths + unlink on `deinit`,
  or run the reaper periodically.
- **`dragdrop.zig:166`** — `formatPayload` returns partial write on
  `error.NoSpace`; user dragging 50 long paths gets silent truncation.
- **`dragdrop.zig` URI parsing** — `file://` (just scheme, no path)
  produces empty shell-quoted paste `''`. Defensive ignore would be
  cleaner.
- **`notifier.zig:267-273`** — `ztrunc` slices on byte boundary; can
  split UTF-8 mid-codepoint. Truncate on code-point boundary.
- **`log_pane.zig:1212`** — same UTF-8 boundary issue in
  `refreshAttentionChip` 252-byte clip.
- **`log_pane.zig:1184` `formatHeaderTime`** — `catch unreachable`
  on `bufPrint`. Safe today; replace with `catch return ""`.
- **`log_pane.zig` size** — 1373 lines, multiple concerns. Extract
  `writeThemedCss` (~280 lines) to `log_pane_css.zig`; pull
  filter+header bookkeeping into a `LogModel` struct.
- **`autostart.zig:65-99`** — non-atomic write
  (`createFile(.truncate=true)` + `writeAll`). Mid-write crash
  leaves truncated file. Write to `.tmp` + rename.
- **`autostart.zig:151-156`** — `/proc/self/exe` can include
  ` (deleted)` annotation after package update mid-session.
- **`reapDragDropTemps`** — `dir.iterate()` errors return from the
  function, abandoning the rest. Continue instead.
- **`hotkey.zig:417`** — errdefer cleanup gap on init failure.
  Latent today (no allocs after subscribes) but trap for the next
  edit.
- **`hotkey.zig:316`** — `timeout_msec=-1` lets stuck portal peg the
  subscription until process exit. 10-30s cap with logged timeout.
- **`ipc.zig:158-183`** — unbounded inner accept loop; same-UID
  client `connect()`-ing in a tight loop starves GLib main loop.
  Cap iterations per dispatch.
- **`ipc.zig:91-94`** — `unlink` swallows EACCES / EISDIR; `bind`
  then fails with less-informative error.
- **`watcher.zig:255-283`** — no recovery if config dir itself
  disappears (`mv ~/.config/djinn ~/.config/djinn.bak`).
  `MOVED_OUT`/`UNMOUNTED` should re-establish the monitor.
- **`ghostty_config.zig:81-82,225`** — `readToEndAlloc(1<<20)` is
  hard-fatal on >1 MiB config; should degrade to "skip, use
  defaults".
- **`ghostty_config.zig:113-153`** — inline `# comment` on a value
  line is not stripped, silently rejects the entry.
- **`notifier.zig`** — `playSound` is a no-op stub. If any
  cross-platform caller exercises `bell-sound`, linux users get
  silent failure. Log on first call or wire VTE's `bell` signal.
- **`djinn.desktop:5`** — `Exec=djinn` (bare) vs systemd unit's
  absolute `/usr/bin/djinn`. Inconsistent; .desktop should be
  absolute per freedesktop recommendation.
- **`djinn.desktop:9`** — `StartupNotify=false` + `StartupWMClass=djinn`
  inconsistent (WMClass only useful when StartupNotify=true).
- **`flake.nix:196`** — `dontWrapGApps = false;` is the default; the
  comment claims it disables wrapping (it doesn't). Delete or fix.
- **`flake.nix:220`** — `homepage` URL duplicated in `PKGBUILD:7`,
  `debian/control:13`, `debian/copyright:4`. Single source of truth
  (or a comptime cross-check) avoids drift.
- **`platform/darwin.zig:100-120`** — `KeymapContext` declares
  three fields; linux's `keymap.zig:97-101` has five. Stub doesn't
  enforce shape parity with the real surface. Either `@compileError
  ("not implemented on darwin")` or sync the field list.
- **`main_linux.zig::loadConfigWithRetry`** swallows every error
  from `Config.load` (`else |_| {}`). EACCES, malformed UTF-8,
  parse error all look the same as transient ENOENT and burn
  three retry attempts. Log the first error before retrying.
- **`main_linux.zig` Terminal bring-up** — `Terminal.open` takes
  the `on_child_exited` handler with `@ptrCast(&g_dispatch)` while
  `g_dispatch.terminal` is still `undefined` at that point. The
  handler doesn't read `terminal` today, but the fragility is
  load-bearing on knowing which fields each handler touches
  (subsumed by the priority-#3 Dispatch refactor).
- **`mcp/server.zig:83-95`** — only `error.SocketNotListening` is
  treated as "shutting down"; other listener errors during
  `deinit` (`ConnectionAborted`, `WouldBlock` if the listener went
  non-blocking) log a spurious "mcp accept failed" before the next
  loop iteration notices the stop flag. Check `stop_flag` BEFORE
  logging the error.
- **`panel.zig:218` `detect`** — `allocator.dupe` failure returns
  `""` for the desktop name. Masks an OOM as "unknown desktop"
  downstream. Return the error.
- **`theme.zig:319` `applyCss`** — 512-byte stack buffer; if the
  padding rule succeeds but the opacity rule overflows the
  remaining bytes, `bufPrint`'s `NoSpace` is caught and the partial
  write loads — silent partial styling. Bubble the NoSpace.
- **`log_pane.zig:393`** — `showPlaceholder` `unreachable` on
  `.none`. Brittle as the state grows; return early instead.
- **`log_pane.zig:373` `applyTheme`** — CSS-build errors swallowed
  via a debug-print + `return`. Previous provider stays active by
  accident; at minimum increment a counter callers can observe.
- **`dragdrop.zig:139`** — two `GtkDropTarget`s attached, neither
  detached. Widget lifetime cleans up via parent destroy, but a
  double `dragdrop.attach` (refactor mishap) silently stacks the
  controllers.
- **`hotkey.zig:466, 553`** — `unique_name` re-fetched per call.
  Stash once in `Context`; the unique name is fixed for the
  connection's lifetime.
- **`ipc.zig:177`** — `read` errors swallowed via `catch continue`.
  EINTR vs real I/O error are indistinguishable in logs.
- **`watcher.zig:140-145`** — partial init failure cleanup
  increments `built` after a fallible alloc. Latent today;
  refactor-prone.
- **`ghostty_config.zig:340-376` `detectAppearance`** — builds
  `params` without explicit floating-ref handling, while
  `hotkey.zig` / `tray.zig` use builder-based construction. Mixed
  GVariant ownership styles make audits harder.
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
- **`debian/changelog`** — timestamp `Sat, 16 May 2026 20:30:00`
  is future-dated relative to clock-conservative builders;
  `lintian` flags it. Use `date -R` at commit time.

### Cross-cutting themes (synthesis)

1. **GLib main-thread blocking.** Tray's `pollAgentTick` still
   grabs `state.mutex` from a GLib callback without a documented
   lock-ordering invariant. The watcher path now coalesces
   GFileMonitor bursts via a 100ms debounce so the per-save cost
   is one reload (≤60ms typical) instead of 5+ × 60ms. The
   notifier path is mutex-free past first delivery thanks to the
   cached connection landing. Audit any new GLib callback for
   blocking I/O or contended locks.
2. **GTK extern duplication.** Same shape as the landed
   `gdbus.zig` extraction. `g_signal_connect_data`, `g_timeout_add`,
   `g_source_remove`, `g_object_unref`, GTK CSS / widget helpers
   are duplicated across 4+ modules with at least one divergent
   signature (`g_source_remove` returns `c_int` in ipc/tray,
   `gboolean` in panel/log_pane). Consolidate in `gtk.zig` (or a
   sibling `glib.zig` if the split is worth it).
3. **Platform abstraction half-built.** Either commit darwin to
   `platform.zig` (mechanical) or shrink the surface to what's
   actually used cross-OS (just `Notifier` today).
4. **Threading model under-documented.** Mutex ordering between
   `state.mutex` and GLib main, MCP server thread join semantics —
   need explicit invariants. The persist worker's lifetime is now
   pinned (single in-flight, joined on shutdown via
   `joinPendingSave`); other subsystems still under-document their
   shared-state contract.
5. **Packaging not yet upstream-ready.** Debian source format
   workable but `dh_auto_configure` runs `zig build --fetch`
   (needs network in pbuilder); flake.nix `nix build .#default`
   relies on `__noChroot = true` (non-reproducible, non-substitutable);
   `zig build install` orphans manually-placed LICENSE/README on
   uninstall. Three independent blockers for true distro inclusion;
   the GH-release tarball + AUR `djinn-git` PKGBUILD are the two
   working install paths today (see History).
6. **Untested high-risk paths.** CI now covers linux — Ubuntu 24.04
   runs `zig build test` + debug build + ReleaseSafe + `--version`
   smoke on every push (`.github/workflows/ci.yml::linux`). What's
   still untested by `zig build test`: the bring-up sequence in
   `main_linux.zig` (Dispatch stamping order, `onConfigChanged`
   lifecycle, MCP live-flip, watcher reload, persist worker
   lifetime). Submodule unit tests stayed unchanged across the
   alpha; the main bring-up's regression surface needs its own
   smoke tests. This is **priority #2** in the live backlog.
7. **Install/uninstall asymmetry + path conflicts.** Arch/Debian/Nix
   all invoke `zig build install --prefix …`; no `zig build
   uninstall` exists. The `.desktop` identity at
   `/usr/share/applications/djinn.desktop` is what
   xdg-desktop-portal's hotkey approval persists against — a
   user-local install (`~/.local/share/applications/…`) silently
   breaks hotkey persistence. Document or block.

History (landed themes — kept for context, `git log --grep=linux`
has the chain):

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
