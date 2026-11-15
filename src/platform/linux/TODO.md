# Linux backend acceptance

## Contract

Preserve the existing GTK4/VTE backend as the Linux implementation of Djinn's
terminal-first contract. macOS embeds Ghostty; Linux does not emulate the
Ghostty surface API or require its renderer at runtime.

Keep native window/focus handling, portal/compositor shortcuts, ordinary shell
sessions, optional fixed lazy profiles, find, clipboard/IME/drag-drop, themes,
terminal notifications, tray settings, appearance, config watching, and optional
autostart. No agent state, MCP/HTTP service, log pane, palette, cheatsheet, or
profile-editing/writeback UI. The local control socket only carries native
window/instance commands.

The reconciled source uses the shared Ghostty 1.4.0/Zig 0.17.1 baseline;
Ghostty remains macOS-only at runtime. The checklist below is outstanding work,
not a claim that a Linux binary or desktop session has been exercised. Existing
compile-only results predate the source-review fixes listed below.

## Source-review fixes before acceptance

These remain unimplemented. See the [root review backlog](../../../TODO.md#review-backlog-correctness-before-publication)
for release priorities, cross-platform policy, and disjoint worker ownership.

- [ ] Apply configured `scrollback-size` to VTE as lines. Cover no override,
      zero, positive limits, and new/lazy/restarted sessions. Align the contract
      with Ghostty's `scrollback-limit-lines`, not its old byte-limit alias;
      accurately report reload/new-session/restart behavior.
- [ ] Wire configured window positioning into panel creation and supported
      updates. The panel currently always anchors to the top; restart does not
      apply ignored coordinates. Test supported named anchors/margins and give
      explicit limitations for unsupported absolute placement/compositors.
- [ ] Reset removed font/color/palette/cursor/padding/opacity overrides instead
      of retaining previous native state through early returns. Cover clearing
      individual fields, disabling inheritance, missing inherited config, light/
      dark changes, inactive terminals, and sessions created after reload.
- [ ] Unify config/CLI/tray/OS autostart policy. Startup's default `false` must
      not silently undo a previous enable action. Agree on absent versus
      explicit config policy and expose conflicts truthfully, without config
      writeback. Test enable/disable/status across app restarts using fixtures.
- [ ] Encode autostart desktop-entry `Exec` paths with desktop-entry escaping,
      including spaces, quotes, backslashes, and `%`. Verify the chosen launcher
      works for wrapped Nix and distro installs; do not bypass required wrapper
      environment by blindly using the resolved internal executable.
- [ ] Preserve exact owned profile names in shared geometry persistence; no
      128-byte truncation, prefix collisions, split UTF-8, or invalid JSON.
      Queue updates per profile so switching profiles before a flush cannot
      discard another profile's size. Test updates during flush and shutdown
      using temporary fixtures; retain one writer and atomic replacement.
- [ ] Define and implement safe reaping for djinn-owned mode-0600 image-drop
      files. Keep them available until the target can consume them; clean only
      owned paths, including failure paths. Coordinate any entry-point shutdown
      hook with the owner of `src/main_linux.zig`.
- [ ] Test/document whether geometry persistence is trailing-edge debounce or
      periodic coalescing. Measure writes during a drag and preserve all pending
      profile updates on shutdown before changing the 500 ms geometry observer.

## Build and unit verification

- [ ] Native Linux `zig build test` with GTK4, VTE GTK4, gtk4-layer-shell,
      GLib/GIO, and pkg-config development dependencies.
- [ ] Native Linux debug and ReleaseSafe builds; relocated `--version` and
      `--help` without a display server or unintended startup side effects.
- [x] Linux x86_64 and aarch64 compile-only checks and full test-suite
      compilation from macOS. Cross-checking does not establish successful
      native library linking, Linux test execution, or runtime behavior.
- [ ] Audit tests for real HOME/config/autostart writes and GUI/portal access;
      persistence and filesystem tests must use temporary fixtures.
- [ ] Verify packaging/install paths and required library versions on the
      Ubuntu CI image and appropriate Arch/Nix environments.

## Sessions and input

- [ ] No-profile interactive default shell; PATH/environment, TERM, Unicode,
      manpages, curses applications, and ordinary agent CLIs.
- [ ] `script > command > default shell`; executable validation and literal
      quoting, including executable paths containing spaces/apostrophes.
- [ ] Explicit invalid/missing cwd fails visibly, including lazy starts and
      restarts after a directory disappears. No inherited-directory fallback.
- [ ] Static profile launch data remains valid after config replacement;
      membership edits require restart and never rewrite configuration.
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
      Manual tagged releases must build the requested tag's exact commit, not
      the workflow-dispatch branch tip. See root P1 release tasks.
- [ ] Desktop identity and portal permissions remain stable across upgrades.
- [ ] Optional systemd user unit is not auto-enabled by developer builds.
- [ ] Exercise image-temp cleanup after implementation, including failed drops,
      repeated drops, normal quit, and a slow consumer. Current Linux drops do
      not schedule reaping; source-review tasks above are not completed fixes.
- [ ] Audit licenses for the actual linked libraries and distributed resources.
- [ ] Measure startup/show latency, idle CPU, memory, and repeated-session
      behavior with machine/compositor/build/workload recorded. No performance
      or native desktop acceptance is implied by compile-only checks.

Linux runtime validation must be performed outside pi or in CI when the local
sandbox does not permit the intended execution environment. Do not retry or
work around a sandbox denial through another VM/container route.
