# djinn TODO

## Contract

Terminal-first native drop-down terminal for macOS and Linux: Ghostty/AppKit
on macOS, GTK4/VTE with Wayland layer-shell on Linux. Retain native
hotkey/focus/window handling, find, clipboard/drag-drop, IME, themes,
static session tabs, terminal notifications, settings, and platform packaging.
No profiles are required: an ordinary default shell is the baseline.

No MCP/HTTP service, adapters, plugin service, agent state/client policy,
log UI, command palette, cheatsheet, or profile writeback. These are removed
scope, not deferred features. Optional static profiles and executable user
scripts use `script > command > default shell`. Explicit invalid launch
settings are errors. Membership changes require an app restart; session
restart/close never writes configuration.

See [README.md](README.md) for configuration, migration, and signing.
Old user endpoint/token files are left untouched; cleanup is manual.

## Review backlog: correctness before publication

These are source-review findings, not implemented fixes or newly executed
acceptance tests. Do not infer whether a gap was inherited or introduced without
checking its history. Keep the terminal-first contract and native backend split;
none of this work restores removed product scope.

### P1: release safety

- [ ] Normalize macOS release architecture names across CI, both release
      workflows, and `scripts/install-from-release.sh`. GitHub `runner.arch`
      uses `ARM64`/`X64`; the installer uses `uname -m` (`arm64`/`x86_64`).
      Test that generated asset names match installer lookup for both supported
      architectures; do not change cache keys merely to fix asset names.
- [ ] Resolve the requested release tag before checkout on manual dispatch.
      Both platform jobs must build its exact commit, not the dispatch branch
      tip. Verify that selecting an older tag from `main` cannot publish a
      main-tip binary under that tag. Reject invalid or missing tags safely.
- [ ] Build, test, and verify both platform artifacts before one prerelease
      publishing job replaces the rolling release. Linux currently starts
      after macOS publication/deletion of the previous release; a failed Linux
      build can remove the previous working Linux download. Preserve existing
      downloads if either platform fails and serialize competing publishers.
- [ ] Decide explicitly whether to gate/disable or accept automatic prerelease
      publication on `main` before pushing. Updating these TODOs does not
      authorize a push, workflow run, release, installation, or app launch.

### P2: terminal/configuration correctness

- [ ] Define `scrollback-size` consistently as lines: use Ghostty 1.4's
      `scrollback-limit-lines` and VTE's scrollback-lines API. The old Ghostty
      `scrollback-limit` alias means bytes; Linux currently ignores the value.
      Explain Ghostty's independent byte cap, update stale default/unit docs,
      and test unset/zero/positive values plus new/lazy/restarted sessions.
      State accurately whether changes require new sessions or app restart.
- [ ] Apply supported Linux window anchors/margins at startup and reload, or
      explicitly report restart-only behavior. Position/coordinates currently
      never reach the panel, which always anchors to the top; restart does not
      fix this. Report unsupported coordinate placement on constrained
      Wayland/plain-toplevel backends instead of promising macOS parity.
- [ ] Reset removed Linux appearance overrides to intentional native defaults.
      Reconcile font, foreground/background/palette/cursor, padding, and opacity
      when overrides or inheritance disappear; early returns currently leave
      old state installed. Cover active, inactive, and newly created sessions.
- [ ] Choose one coherent launch-at-login authority across configuration,
      CLI, menubar/tray, and OS registration. Startup's default `false` can undo
      an earlier enable action on both platforms. Consider absent config as
      leave-OS-state-alone; explicit policy conflicts need truthful UI/status.
      Do not solve this by rewriting existing config or profiles.
- [ ] Preserve exact profile identities in saved geometry. `PendingSave`
      truncates names to 128 bytes, allowing collisions and split UTF-8/invalid
      JSON. Keep owned names valid across config replacement and teardown;
      fixture tests must round-trip long names and multibyte boundary cases.
- [ ] Coalesce pending geometry per profile, not only in one global slot.
      Queueing B before A flushes must not discard A's geometry. Retain the
      single writer, atomic replacement, shutdown gate, and accepted-work drain;
      test rapid profile changes and updates arriving during a flush.

### Reliability and performance follow-ups

- [ ] Stage and validate installer downloads before replacing the installed
      app: checksum, expected bundle/layout/architecture, plist, and signature.
      Keep a same-filesystem backup/rollback path; bad archives or extraction
      failure must preserve the working app. Clean every temporary artifact.
      Do not auto-quit existing sessions or silently strip quarantine; document
      ad-hoc/Gatekeeper limits and remove obsolete Accessibility-permission
      advice. The installer remains macOS-only unless deliberately extended.
- [ ] Escape Linux autostart desktop-entry `Exec` paths using desktop-entry
      rules, not shell quoting. Cover spaces, quotes, backslashes, and `%`;
      verify packaged/wrapped launchers retain their required environment.
- [ ] Define safe cleanup for djinn-owned image-drop temporary files on both
      platforms. Do not reap files before consumers can read them or delete
      unrelated matching paths. Keep Linux files mode 0600.
- [ ] Decide whether resize persistence should be true trailing-edge debounce
      or periodic coalescing. The current worker flushes during continuous
      updates; do not claim one write per drag without a test. Ensure pending
      profiles still flush on normal shutdown.
- [ ] Measure the inherited Linux 500 ms geometry observer before replacing
      it. Record idle wakeups/CPU and drag write frequency; do not substitute a
      faster poll or resurrect the removed macOS host polling loop.

### Parallel implementation handoff

The previous session hit pi's 32-job limit before any fix agents started.
Use a fresh session for four workers with disjoint file ownership:

1. **Release/installer:** `.github/workflows/{ci,pre-release,release}.yml`
   and `scripts/install-from-release.sh`; artifact naming, exact-tag builds,
   publish-after-validation, and staged installation/rollback.
2. **Terminal settings/appearance:** `src/ghostty/runtime.zig` and Linux
   `terminal.zig`, `session_host.zig`, `panel.zig`, `theme.zig`; implement backend
   options/reset behavior and report required entry-point wiring.
3. **Autostart:** `src/system/loginitem.zig`, `src/cli.zig`,
   `src/notify/menubar.zig`, Linux `autostart.zig` and `tray.zig`; agree on policy
   with the coordinator first, then fix actions/status and desktop `Exec`.
4. **Persistence/image cleanup:** `src/state/persist.zig` and Linux
   `dragdrop.zig`; exact profile identity, per-profile pending updates, owned
   image lifecycle, and fixture tests. Report any shutdown hooks still needed.

The coordinator owns `src/config.zig`, `src/main.zig`, `src/main_linux.zig`,
shared/root test registration, and documentation. Agree on option/API contracts
before workers edit; integrate startup/reload/shutdown wiring centrally. Any
additional file ownership must be reassigned explicitly, never edited by two
workers. Preserve source identity/generation checks and async teardown leases.

Validate local formatting, pure/model/fixture tests, shell/workflow syntax, both
Linux architecture checks/test compilation, and the macOS bundle verifier as
permitted. Execute native Linux linking/tests and desktop acceptance in CI or
manually outside pi; cross-compilation is not runtime acceptance. Git
preparation/promotion was sandbox-denied and remains manual outside pi: do not
inspect, retry, diagnose, or work around that denied operation. Likewise, do not
retry the denied Docker validation through another container/VM route. All new
sandbox denials are final. Do not access personal config, credentials/keychain,
install/launch the app, force-quit sessions, or publish as part of these fixes.
Leave the pre-existing untracked `REDUCTION_PLAN.md` untouched.

## Recorded automated verification

The reconciled candidate uses **Ghostty 1.4.0**, its matching zig-objc revision,
Nix Zig **0.17.1**, and SDK **26.5** from the locked nixpkgs input. The results
below predate the review backlog above; they do not verify those pending fixes
or establish the current commit/push/promotion state. Snapshot promotion was
provided as a manual operation; its completion has not been confirmed here.
The last known installed app remains the earlier baseline, not this candidate.
Recorded build host: arm64, macOS 27.2.1, Xcode 27.0 (27A266a), system Metal.

```sh
nix develop --command ./scripts/build.sh bundle check test resources test-shared --summary all
codesign --force --sign - zig-out/Djinn.app/Contents/MacOS/libghostty.dylib
codesign --force --sign - zig-out/Djinn.app
./scripts/verify-bundle.sh
```

- [x] **139/139 build steps succeeded.** The macOS suite passes **135/135**;
      the standalone shared suite passes **61/61** (overlapping shared coverage).
      Coverage includes
      strict config and allocation failures, launch-string ownership,
      disappearing cwd, source/generation routing, initial surface state,
      input-state reconciliation, physical-key ownership, search payloads,
      UTF-8 editing, notification throttling, and native hotkey rollback.
      Coverage also includes platform IO, worker completion/cancellation,
      canceled-child ownership, and length-delimited clipboard payloads/MIME
      selection.
- [x] Compile-only `check` analyzes the native host without linking Ghostty
      or invoking Metal. Native hotkey unit tests use a mocked backend;
      neither check proves keyboard delivery or GUI behavior.
- [x] ReleaseFast `zig-out/Djinn.app` includes its own Ghostty dylib,
      compiled terminfo, shell integration, and pinned themes.
- [x] Executable and dylib target macOS **13.0** with baseline CPU features.
      The executable has only `@loader_path` as its rpath; Ghostty has none.
      Other dylib dependencies are system libraries/frameworks.
- [x] Ad-hoc signatures pass `codesign --verify --deep --strict`. The bundle
      verifier checks deployment floors, linkage, resources, and relocated
      `--version`/`--help` in a clean environment and unrelated directory.
      Dyld tracing confirms the relocated copy loads its own Ghostty.
- [x] Development and bundled terminfo validate with `infocmp`; Info.plist
      validates with `plutil`. Zig formatting, shell syntax, workflow YAML
      syntax, and `git diff --check` pass.
- [x] CI and release workflows execute the Metal compiler probe and the
      reusable bundle verifier. The GitHub-hosted workflows themselves
      have not been run as part of this local verification.

### Cross-platform reconciliation

- [x] Linux x86_64 and aarch64 compile-only `check` and full test-suite
      compilation pass on macOS without GTK/pkg-config linkage, Ghostty
      instantiation, or Apple frameworks. Linux tests were not executed.
- [x] `test-shared` passes **61/61** config/session/persistence/IO tests without
      linking AppKit or GTK. This includes fixture-only persistence writes,
      serialized pending saves, atomic replacement, and saved-size validation.
- [x] Linux terminal-first source retains VTE/native window controls and
      removes agent/log/palette/cheatsheet/profile-mutation code. The local
      Unix socket is limited to same-UID window/instance commands.
- [x] Source review fixes preserve acknowledged portal bindings/config across
      async replacement, use unique attempts and callback leases, and defer
      hotkey/VTE completion drains until every native producer has detached.
      Clipboard capture respects find/editable focus; file-list drops validate
      the whole payload; recovery shells execute directly. Close-request
      destruction remains owner-controlled. These are static/model checks,
      not native desktop acceptance.
- [ ] Native Linux link/build/tests and distro packaging. Compile-only checks
      and host pure tests are not evidence of a linked Linux executable.
- [ ] Linux compositor/portal, VTE input/lifecycle, tray, notification, and
      appearance acceptance; see [Linux checklist](src/platform/linux/TODO.md).
- [ ] Execute restored Linux CI/release jobs. Local container validation was
      sandbox-blocked; do not probe, retry, or use an alternative VM route.
- [ ] Measure Linux idle behavior, including the inherited 500ms allocated-size
      observer. The macOS event-driven geometry work does not establish Linux
      idle/performance equivalence.

### Dependency-refresh corrections (macOS)

- [x] Full rendering API remains selected explicitly; Ghostty's new VT-only
      default is not a replacement for Djinn's embedded renderer.
- [x] Native headers use a shared translated C module; host filesystem,
      subprocess, argument, environment, clock, and mutex APIs use Zig 0.17.
- [x] Clipboard callbacks preserve explicit byte lengths. Confirmation-required
      requests are explicitly denied; primary/selection do not alias the
      standard pasteboard. Explicit paste/drop uses Ghostty's protected paste
      API while IME commits remain separate raw text input.
- [x] Auxiliary sound/resize tasks use owned IO groups instead of detached
      threads. Shutdown cancels/reaps sounds and drains persistence after
      native producers stop, before the process IO backend is destroyed.
      A Zig 0.17.1 POSIX canceled-wait workaround retains only the still-owned
      child ID for cleanup; completed/error waits never restore stale IDs.
- [x] Saved-state round-trip testing uses a temporary file and real assertions.
      The old test could overwrite personal saved window geometry; no test
      should write the real HOME state path.

### Retained reduction corrections

- [x] Secure Input, cursor visibility, cursor shape, and link-hover requests
      belong to their source session. Only the active visible/focused source
      affects host state; teardown balances host-owned references.
- [x] Every new surface explicitly starts unfocused/occluded before applying
      actual panel state. Creation-time titles use validated construction
      userdata rather than guessing the active session.
- [x] Lazy launch/restart revalidates cwd and reports failure instead of
      allowing Ghostty's inherited-directory fallback. Explicit commands
      retain the pinned API's wait/press-any-key-to-close output policy.
- [x] Search-selection payloads are copied synchronously, including into an
      already-open find overlay. Queries remain bounded, valid UTF-8.
- [x] Physical releases only reach a live source that received their press;
      host/find/IME-consumed input cannot leak orphan releases into a tab.
      Mouse buttons synchronize position before forwarding the button.
- [x] Blur dismissal explicitly orders the panel out instead of relying on
      AppKit automatic hide/restore. Focus reporting remains independent
      of hide-on-blur, including application deactivation after key loss.
- [x] Tracking areas and rebuilt menubar objects balance creator ownership;
      font allocation failure cannot turn a borrowed default into owned data.
- [x] Executable-only quoted commands preserve their shell expression.
      Convenience recipes consistently use the pinned Nix environment.
- [x] Queued wakeups resolve the live app on main, rather than capturing a
      handle that may outlive teardown. Global owner pointers are cleared
      before their managers/native owners are destroyed.

## macOS native hotkey and reported smoke tests

Exclusive Carbon `RegisterEventHotKey` replaces keyboard event interception.
No Accessibility/Input Monitoring grants, event tap, or privacy reset is
required. Stable signing remains a packaging concern, not a hotkey remedy.

- [x] Default/starter/help use **Ctrl+Shift+Space**. Existing config and CLI
      overrides remain authoritative; personal configuration is not rewritten.
- [x] Replacement registers before removing the old shortcut. Failure keeps
      the working binding/settings; failed rollback remains owned for cleanup.
      Config reload can recover failed startup registration, and startup
      failure keeps the menubar reachable even if configured off.
- [x] Diagnostics probe the explicit/built-in binding and immediately release
      it, before config, shell, runtime, or login-item initialization. Native
      `OSStatus`/`HotkeyConflict` reporting distinguishes ownership conflicts.
- [x] User reported working TERM (`xterm-ghostty`), 256 colors, Unicode,
      manpages, menubar toggling, and keyboard-driven show/hide after the
      native registration change. These reports predate the dependency refresh
      and final review fixes; they do not establish candidate GUI acceptance.
- [ ] Confirm the default, review fixes, and refreshed dependencies in the bundle.
      Quit other instances before testing exclusive registration:
      `./zig-out/Djinn.app/Contents/MacOS/djinn --hotkey ctrl+shift+space`.

The recorded verification did not install or launch the candidate, rewrite
personal configuration, or use credentials/keychain-backed signing. The
pre-existing untracked `REDUCTION_PLAN.md` remains untouched.

## macOS manual acceptance checklist

All unchecked items remain unverified. Unit tests and relocated CLI checks
are not installed-app or native-interaction acceptance.

### Packaging and registration

- [ ] With permission, install the signed bundle and launch outside the
      checkout/Nix shell with Ghostty.app absent. Check shell/resources.
- [ ] Native shortcut delivery without Accessibility/Input Monitoring grants;
      menubar show/hide/settings/quit and exclusive conflict reporting.
- [ ] Successful/failed live rebind, startup-registration recovery, and CLI
      override precedence during reload. Ordinary per-app shortcut conflicts
      require separate testing; registration cannot discover them.
- [ ] Diagnostic probe releases registration and starts no shell/login sync.
- [ ] Login-item enable/status/disable from the installed signed bundle.
- [ ] Settings creates only a missing file, opens existing settings unchanged,
      and reports inaccessible files. Migration starts no service and leaves
      old endpoint/token files untouched.
- [ ] Run on actual macOS 13; the declared deployment floor is not proof of
      runtime compatibility. Verify x86_64 packaging on an appropriate runner.

### Input, focus, and screens

- [ ] IME preedit/candidate position/commit/cancel, composed text, modifier
      changes, and normal terminal shortcuts with multiple input sources.
- [ ] Kitty keyboard release reporting with find, host shortcuts, IME, held
      keys, tab switches, and destruction/restart of the source session.
- [ ] Cmd+Tab and explicit blur dismissal on/off, sibling-window key loss,
      repeated show/hide, Spaces/fullscreen apps, and focus restoration.
- [ ] Resize/reposition across displays/scales; disconnect/reconnect displays
      while visible and hidden; sleep/wake with retained sessions.
- [ ] Clipboard, selection, drag/drop files/images, hyperlinks, scrollback,
      search selection/next/previous, and font controls. Repeat with the new
      binary-safe clipboard API, safe/unsafe paste, and denied confirmation.
      Click immediately after showing/repositioning or switching a session.
- [ ] Close/restart at a password prompt or with the mouse hidden; host-owned
      Secure Input/cursor hiding must not remain enabled afterward.

### Sessions, appearance, notifications, and stability

- [ ] No-profile shell; script/command/cwd/title/default-profile settings;
      lazy/restarted cwd disappearance, quoted paths, and visible launch errors.
- [ ] Tab/index/cycle selection, Unicode labels, initial static Ghostty titles,
      retained exited-command output, and source-attributed close/restart.
- [ ] Profile edits report restart-required; loaded sessions survive config
      replacement and membership changes apply only after app restart.
- [ ] Repeated menubar disable/enable, theme changes while hidden, light/dark
      overrides, standalone theme defaults, and Ghostty config inheritance.
- [ ] Terminal notifications and independent source rate limits, macOS Focus,
      notification permissions, audible/visual BEL, and configured sounds.
- [ ] Measure ReleaseFast startup/show latency, idle CPU, memory, and repeated
      session/window activity. Record machine/OS/build/workload; no performance
      numbers are claimed yet.
- [ ] Instrument native allocations and surface/view/string ownership, queued
      notifications, and normal quit. Source teardown safeguards do not prove
      that AppKit's normal termination path runs Zig defers.
- [ ] Confirm image-drop temporary-file lifecycle, scoped to djinn-owned files.
- [x] Saved-size parsing now validates JSON integer bounds. One writer drains
      accepted debounce state using same-directory atomic replacement; tests
      cover serialization, shutdown gating, malformed dimensions, and replacement.
      This does not cover the pending cross-profile overwrite/name-truncation
      fixes above. Native resize/quit timing still needs manual acceptance.

## Packaging follow-ups

- Developer ID signing/notarization is separate from optional local signing.
  Ad-hoc distribution can trigger Gatekeeper friction. Review keychain-backed
  helpers before use; they are not part of automated/ad-hoc verification.
- Audit transitive binary/resource license notices before public distribution.
- Pure Nix packaging still needs system Xcode/Metal access. Retain deliberate
  dependency pins and host-side runners rather than expanding product scope.
- Do not add first-run wizards, profile editors, transports, or extra overlays
  as part of this reduction.
