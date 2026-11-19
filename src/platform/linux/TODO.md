# Linux backend acceptance

## Contract

Preserve the existing GTK4/VTE backend as the Linux implementation of Djinn's
terminal-first contract. macOS embeds Ghostty; Linux does not emulate the
Ghostty surface API or require its renderer at runtime.

Keep native window/focus handling, portal/compositor shortcuts, ordinary shell
sessions, optional lazy profiles, find, clipboard/IME/drag-drop, themes,
terminal notifications, tray settings, appearance, config watching, and optional
autostart. No agent state, MCP/HTTP service, log pane, palette, cheatsheet, or
profile-editing/writeback UI. The local control socket only carries native
window/instance commands.

The reconciled source uses the shared Ghostty 1.4.0/Zig 0.17.1 baseline;
Ghostty remains macOS-only at runtime. Native linking/test execution and desktop
acceptance are separate gates. The compile-only and host-model records below
cannot establish a successful native Linux suite or desktop acceptance.

## Source-review implementation (native acceptance still open)

These fixes are implemented and centrally wired. Checked source/model items do
not establish native Linux linking, test execution, desktop acceptance, or release
approval. See the [root implementation record](../../../TODO.md#correctnessrelease-safety-implementation).

- [x] VTE applies `scrollback-size` as lines; null restores the captured native
      default, zero disables retained scrollback, positive sets a limit. All live
      terminals update on reload; lazy/restarted/recovery sessions retain policy.
      Ghostty uses its line cap too, but only new surfaces adopt reloaded caps.
- [x] Startup placement is applied before initial mapping. Reload reconciles nine
      named layer-shell anchors and zero margins. Absolute coordinates report
      unsupported with named fallback; plain-toplevel placement is explicitly
      compositor-controlled. Pure anchor/margin models pass.
- [x] Removed font/foreground/background/palette/cursor/padding/opacity settings
      restore intentional native defaults. Complete replacement reaches active,
      inactive and future sessions; no legacy opacity fallback remains. Font,
      color, CSS and session replacement models pass.
- [x] Absent login policy leaves OS registration alone; explicit true/false
      reconciles at startup/every accepted reload. CLI/tray reject conflicts
      without config writeback. Status parses disabled/malformed/conditional
      desktop entries conservatively rather than treating existence as enabled.
- [x] Desktop Exec has correct desktop-entry escaping for spaces, quotes,
      backslashes, percent, dollars and backticks. Launcher selection preserves
      public wrappers/symlinks, including relative invocation and PATH lookup;
      known Nix internal payloads prefer their adjacent wrapper. Selection is
      fixture-tested; actual packaged environment remains native acceptance.
- [x] Shared geometry owns exact long/Unicode profile names, coalesces per profile,
      preserves updates during flush, and drains accepted work on normal shutdown
      with one writer and atomic replacement. Real blocked-flush/temp fixtures pass.
- [x] Image writes use exact private 0700 directories/0600 files and clean failed
      pre-handoff operations only. Fixtures verify ownership/permissions/failure
      cleanup, unrelated-path preservation, and accepted-path retention.
- [ ] Accepted image reclamation remains unresolved: VTE's void paste API cannot
      acknowledge arbitrary consumer completion. Files intentionally survive quit
      and relaunch; no timer, wildcard scan, or shutdown reaper is safe without a
      consumer-release protocol. No shutdown-reaping hook is installed.
- [x] Geometry semantics are explicitly 300 ms **periodic coalescing**, not
      trailing-edge debounce or one-write-per-drag. Shutdown closes acceptance,
      drains after any current sleep, and imposes no further coalescing delay.
- [ ] Measure writes during a drag and idle wakeups/CPU before changing the
      inherited 500 ms geometry observer; no measured performance claim is made.

## Build and unit verification

- [ ] Native Linux `zig build test` with GTK4, VTE GTK4, gtk4-layer-shell,
      GLib/GIO, and pkg-config development dependencies.
- [ ] Native Linux debug and ReleaseSafe builds; relocated `--version` and
      `--help` without a display server or unintended startup side effects.
- [x] Current-source Linux x86_64 and aarch64 `check test-compile` pass from
      macOS without GTK/pkg-config linkage. Cross-checking does not establish
      successful native linking, Linux test execution, or runtime behavior.
- [x] Host `test-linux-models` executes pure autostart/launcher/status/escaping,
      appearance/scrollback/placement/session and image fixtures without GTK.
      Historical counts belong to the commit-specific root verification records;
      the earlier 34-test integration snapshot predates the entry-point theme
      tests added in `bf63346`. Do not treat it as a current suite count.
- [x] Reviewed and executed new host pure/model/filesystem tests with injected
      paths/temporary fixtures; no personal config, OS registration, display, or
      desktop portal access. Native API-body tests are compile-only on this host.
- [ ] Verify packaging/install paths and required library versions on the
      Ubuntu CI image and appropriate Arch/Nix environments.

## Sessions and input

- [ ] No-profile interactive default shell; PATH/environment, TERM, Unicode,
      manpages, curses applications, and ordinary agent CLIs.
- [ ] `script > command > default shell`; executable validation and literal
      quoting, including executable paths containing spaces/apostrophes.
- [ ] Explicit invalid/missing cwd fails visibly, including lazy starts and
      restarts after a directory disappears. No inherited-directory fallback.
- [ ] Profile reload updates labels and membership without replacing live VTE
      widgets. Removed running tabs disappear on exit; no config writeback.
- [ ] Stable callback source identity/generation across tab changes, child
      exits, failed async spawn, restart, and teardown; no callbacks into freed
      or moved handler contexts.
- [ ] Inactive child exit marks only its own session; exit output remains
      visible and explicit restart revives the intended session.
- [ ] Tab labels prefer explicit title, then terminal title, then profile name.
- [ ] Find target follows the active session; UTF-8/binary/control input and
      clipboard data never fall through from rejected find input to the shell.
- [ ] Keyboard/IME, selection, copy/paste, bracketed paste, scrollback, links,
      and drag/drop files/images with metacharacters and multiple paths.

## Desktop and lifecycle

- [ ] Wayland layer-shell positioning/focus/show-hide on supported compositors;
      unsupported environments report limitations rather than claim parity.
- [ ] Portal global-shortcut approval, activation, cancellation, and repeated
      startup/quit, including callbacks arriving during teardown.
- [ ] Compositor fallback using `djinn --toggle`/`--show`/`--hide`; local control
      socket ownership, stale-instance handling, and duplicate launch behavior.
- [ ] Default Ctrl+Shift+Space and explicit CLI/config overrides; failed live
      rebinding must not falsely report the replacement as active.
- [ ] Blur handling, display changes/scaling, repeated show/hide, and sleep/wake.
- [ ] Tray Show/Hide, Settings, Quit, and optional autostart; no agent status
      polls, MCP config actions, or profile mutation entries.
- [ ] Config/theme changes and portal appearance updates while visible/hidden;
      failed reload preserves valid existing state and sessions. Check clearing
      font/color/padding/opacity overrides as well as setting replacements;
      inherited early-return paths can retain previous native appearance.
- [ ] Ordinary audible/visual BEL, terminal notifications, per-source rate
      limits, desktop notification policy, and background/inactive sessions.
- [ ] Stop GLib signals, sources, and async callback producers before destroying
      their objects; drain accepted persistence work before process IO teardown.
- [ ] Settings creates only a missing file; reads/reloads never overwrite the
      user's config. Autostart changes only on explicit user actions/settings.

## Packaging and performance

- [ ] Native Linux CI jobs actually build/link/run tests and verify relocated
      CLI artifacts. Do not publish until both platform candidates validate;
      preserve the previous Linux prerelease download if either platform fails.
      Exact-tag resolution, candidate gates, architecture naming and serialized
      publishing are implemented and offline fixture-tested. Workflow execution
      remains open; rolling publication is manual-only. GitHub asset/tag mutation
      is not atomic and API errors can require operator recovery.
- [ ] Desktop identity and portal permissions remain stable across upgrades.
- [ ] Optional systemd user unit is not auto-enabled by developer builds.
- [ ] Exercise image-temp cleanup after implementation, including failed drops,
      repeated drops, normal quit, and a slow consumer. Failed drops now clean
      owned paths; accepted paths intentionally remain until a safe consumer
      lifetime policy/protocol is available.
- [x] Tooling review removes terminal-child execution restrictions from the
      optional user unit, includes staged notices in the Debian manifest, and
      corrects the Arch source URL/version parser. Offline fixtures exercise
      these contracts; real Debian/Arch/Nix packaging and service/PTY behavior
      remain unaccepted.
- [ ] Audit licenses for the actual linked libraries and distributed resources.
- [ ] Measure startup/show latency, idle CPU, memory, and repeated-session
      behavior with machine/compositor/build/workload recorded. No performance
      or native desktop acceptance is implied by compile-only checks.

Linux runtime validation must be performed outside pi or in CI when the local
sandbox does not permit the intended execution environment. Do not retry or
work around a sandbox denial through another VM/container route.
