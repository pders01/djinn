# djinn TODO

## Contract

Terminal-first native drop-down terminal for macOS and Linux: Ghostty/AppKit
on Apple Silicon macOS (arm64 only; Intel support retired), GTK4/VTE with
Wayland layer-shell on Linux. Retain native
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

## Release preparation and user-reported installation (0.1.0-alpha.2)

- `e84134a` synchronized application, bundle, Zig, Nix, Arch and Debian version
  metadata. Local tag `v0.1.0-alpha.2` was created at that commit; this record
  does not establish remote tag, workflow, or publication state.
- The user subsequently reported `just install-app` completing successfully at
  `~/Applications/Djinn.app`. This supersedes the older installed-baseline note
  below, but is not a report of native GUI, hotkey, login-item or macOS 13
  acceptance. The toolchain's `tic` warning can appear with exit status zero;
  Zig 0.17.1 misleadingly labels the stderr command as failed.
- Older counts and installation statements below are historical snapshots,
  not a live account of the current checkout or installed application.

## Tooling/documentation cleanup verification (working-tree snapshot after e84134a)

- Corrected repository URLs, terminal-child service policy, Debian notice
  coverage, and Arch version-tag normalization/failure handling. Added offline
  fixtures to macOS CI and `just test-tooling`; no package/service was installed.
- Installer advice no longer requests Accessibility/Input Monitoring grants.
  Controls/migration guidance distinguishes macOS from Linux; accepted legacy
  opacity/font keys now warn without reviving terminal fallbacks. Profiling,
  notification, portal, autostart, layout and toolchain comments were reconciled.
- `check test test-shared test-linux-models`: **19/19 build steps**; native macOS
  suite **148/148**, shared suite **68/68**, host Linux models **40/40**. These
  suites overlap and must not be summed as unique coverage. Added two config
  tests for legacy migration and order-independent modern settings.
- Unsigned repository-local macOS bundle: **121/121 build steps**. Both Linux
  `check test-compile` targets: **4/4 steps** each. These are not Linux link or
  runtime checks, and no built bundle was launched or installed.
- Offline tooling: **7 test groups**, including **16 mocked Arch version cases**
  with pipefail on/off. Workflow fixtures: **40 shell blocks, 18 tag cases,
  6 architecture cases, 4 installer refusals, 7 candidate gates, 7 rolling
  retirement cases**. Installer self-tests: **24 archive + 8 replacement/recovery
  fixtures**, confined to temporary directories. Fixture suites overlap.
- Shell syntax, Zig formatting, diff whitespace, recipe listing and Linux Nix
  homepage evaluation passed. Toolchain/deployment pins and the existing release
  tag are unchanged; no signing/keychain, registration, workflow or publication
  action was taken. Native package/service, desktop and release acceptance stay
  open; these checks do not establish a later native Linux CI result.

## Correctness/release-safety implementation

The previously unchecked source-review fixes below are now implemented by four
parallel workers and coordinator integration. Checked implementation items are
**not native desktop acceptance or publication approval**. The older recorded
verification further below remains historical; current checks are separate.

### Implemented release safeguards

- [x] macOS builds, flake outputs and CI/release bundles are Apple Silicon-only.
      Runner `ARM64` normalizes to `arm64` without changing Zig cache identities;
      Intel/unknown runners fail before Nix setup, and unsupported installer
      architectures fail before downloading or changing installation files.
      Linux x86_64 releases and x86_64/aarch64 compile checks are retained.
      Toolchain/deployment pins remain unchanged.
- [x] Manual version tags resolve (including annotated tags) to an exact commit
      before either platform checkout. Both candidates use that SHA; missing,
      malformed, non-commit, and moved tags fail closed. Versioned releases refuse
      overwriting an existing release.
- [x] One serialized publisher depends on the arm64 macOS and x86_64 Linux
      build/test/artifact verification. Both archives and checksums are required;
      extra candidates (including Intel macOS) fail the gate. No old release is
      deleted before validation. Historical versioned Intel assets are untouched;
      known Intel rolling assets retire only after successful publication.
      A failed candidate preserves previous downloads. Rolling promotion uploads
      only after validation; GitHub tag/asset updates are **not atomic**, and API
      failure can require manual recovery. Mixed ZIP/checksum pairs fail closed,
      but an old matching pair can briefly remain under the moved rolling tag.
- [x] Automatic `main` rolling publication is disabled. Rolling promotion is
      manual-only, selecting an existing version tag. This implements a safe
      default, not authorization to trigger, push, publish, or install.
- [x] Installer verifies checksum, bounded safe ZIP paths/types/symlinks, layout,
      plist identity, signatures, and native architecture before replacement.
      Same-filesystem staging/backup, cooperative lock, rollback and cleanup are
      implemented; rollback failure retains the backup for manual recovery.
      It never quits/launches sessions or strips quarantine; Accessibility advice
      was removed. Python 3 is required. Temporary fixtures test extraction and
      replacement; real installed-app/power-loss recovery remain unaccepted.

### Implemented terminal/configuration fixes

- [x] `scrollback-size` means lines: Ghostty `scrollback-limit-lines` and VTE
      scrollback-lines. Unset/zero/positive and retained future-session policy
      have pure/model coverage. Ghostty's independent byte cap defaults to 50 MB
      and can evict earlier. Reloaded Ghostty caps apply to **new/lazy/restarted
      surfaces**, not existing ones; VTE limits apply live to all terminals.
      Reductions may discard history; larger caps cannot recover it.
- [x] Linux startup passes positioning before initial map. Accepted reloads
      reconcile all nine layer-shell named anchors and zero margins. Absolute
      coordinates are reported unsupported with named-anchor fallback; plain
      GTK4 toplevel placement is reported compositor-controlled.
- [x] Removed Linux font/colors/palette/cursor/padding/opacity overrides reset
      instead of retaining old state. Complete replacement reaches active,
      inactive and future terminals; absent opacity no longer falls back to
      the legacy 0.95 value. Pure plans/CSS/session models are tested.
- [x] Absent `open-at-login` is leave-OS-state-alone; explicit bool is policy,
      reconciled at startup and every accepted reload. CLI strictly reads policy
      before actions; menus/status report actual OS state, approval/unknown and
      conflicts. Conflicting actions are rejected; no config writeback occurs.
      New starter files comment out policy; existing files are never rewritten.
- [x] Linux desktop-entry Exec uses desktop escaping (including quotes,
      backslashes, dollars, backticks and percent), not shell quoting. Launcher
      selection preserves absolute/relative original launchers, symlinks and PATH
      wrappers, preferring the public launcher over known Nix internal payloads.
      Fixture path selection is tested; real packaged wrapper environment and
      native registration remain acceptance items.
- [x] Geometry batches own exact profile names without truncation, including
      long/Unicode names. Latest geometry coalesces **per profile**, retaining
      other profiles' updates and work queued during a flush. Single writer,
      atomic replacement, acceptance gate and normal-shutdown drain are retained.
- [x] Persistence explicitly uses **300 ms periodic coalescing**, not trailing-edge
      debounce or one-write-per-drag. A first update starts a window; continuous
      input may checkpoint repeatedly. Shutdown closes acceptance and drains
      after at most an existing coalescing sleep; filesystem IO is not bounded.
      Real-worker blocked-flush fixtures cover updates and shutdown.

### Partial image cleanup and remaining gates

- [x] Failed image writes/handoffs clean only their exact owned paths. Linux
      uses private 0700 directories and 0600 images; macOS creates 0600 images
      exclusively. The unsafe macOS prefix/age reaper is removed.
- [ ] Automatic reclamation of **accepted** image paths: arbitrary shells/VTE
      provide no consumer-release acknowledgement. Accepted paths intentionally
      survive quit/relaunch; timers or shutdown cleanup would risk premature
      deletion. Consumer-aware protocol/product policy is still unresolved.
- [ ] Native Linux linking/tests, compositor/VTE/portal/tray/appearance/IME/drop
      acceptance and actual wrapped launcher environment. See Linux checklist.
- [ ] Installed-app Apple Silicon macOS acceptance and actual macOS 13 checks,
      login registration, and slow-consumer image acceptance.
- [ ] Measure Linux idle wakeups/CPU and drag write frequency before changing the
      inherited 500 ms geometry observer. No performance improvement is claimed.
- [ ] Developer ID signing/notarization and actual linked-resource licensing
      audit. Ad-hoc validation does not satisfy these release gates.
- [ ] Run CI/workflows only with authorization; no workflow was triggered here.

### Apple Silicon-only policy verification (snapshot at 0e055ea)

- Flake evaluation exposes exactly `aarch64-darwin`, `x86_64-linux`, and
  `aarch64-linux`; the lockfile and all toolchain/deployment pins are unchanged.
- macOS `check test test-shared test-linux-models`: **19/19 build steps** pass
  (test results cached). `bundle`: **121/121 steps** pass; both Mach-O artifacts
  are `arm64`, and the plist minimum remains `13.0`.
- Explicit `x86_64-macos` build fails with the intended unsupported-Intel message.
  Both Linux architectures still pass `check test-compile` (4/4 steps each);
  this is compile-only, not native Linux runtime acceptance.
- Explicit ad-hoc signing (no keychain lookup), bundle verification with clean
  relocated CLI, and a fresh arm64 ZIP/checksum `--verify-archive` all pass.
  No installation or GUI launch was performed.
- Installer fixtures: **24 archive + 8 replacement/recovery** pass. Offline
  workflow fixtures pass: **39 shell blocks, 18 tag cases, 6 architecture cases,
  4 early installer refusals, 7 candidate gates, and 7 rolling-asset retirement
  cases**, using a mocked GitHub CLI. No workflow or publication was triggered.
- Shell syntax, Zig formatting and diff whitespace checks pass. Installed-app,
  macOS 13 runtime, native Linux desktop and release acceptance remain open.

### Earlier correctness-fix verification (snapshot at 013295e)

- macOS arm64: **143/143 build steps succeeded** for bundle/check/test/resources/
  test-shared/test-linux-models. Native suite **146/146**, shared suite **66/66**
  (executed separately, cached in the final aggregate), and Linux host models
  **34/34** pass; these suites overlap, so counts are not unique coverage.
  Explicit ad-hoc signing and bundle verifier pass. A freshly zipped bundle also
  passes installer `--verify-archive` for arm64 (no installation). The verifier
  tests clean relocated CLI, not GUI behavior. Zig 0.17.1, Ghostty 1.4.0/matching objc,
  SDK 26.5, macOS 13.0 and baseline CPU are preserved.
- Host shared suite and filtered `test-linux-models` execute pure/model/filesystem
  fixtures without GTK or OS registration; native Linux API bodies are covered
  separately by compile-only `test-compile`.
- Both x86_64/aarch64 Linux `check test-compile` pass. This is semantic analysis
  and test compilation, **not Linux test execution or native linking**.
- Installer `--self-test`: 24 archive and 8 replacement/recovery fixtures pass.
  Offline `scripts/test-release-workflows.py` parses all three YAML files,
  syntax-checks **38 shell blocks** and tests **18 tag cases, 6 architecture cases,
  and 4 candidate-gate fixtures** with mocked API calls. No real publication occurs.
- Formatting checks pass. No Git commands, installation, GUI launch, personal
  configuration access, keychain helpers, real registration, containers/VMs or
  publication were performed. Earlier denied Git/Docker routes remain manual;
  `REDUCTION_PLAN.md` and unrelated user changes remain untouched.

### Parallel integration record

The four assigned workers completed release/installer, terminal/appearance,
autostart, and persistence/image changes without further delegation. Coordinator
reviewed source changes and wired config/startup/reload, facade APIs, safe macOS
image handling, build/test registration and docs. Preserve source IDs/generations,
callback leases and producer-first teardown; `persist.shutdown()` remains after
native geometry producers detach and before allocator/process IO teardown.

## Recorded automated verification (historical dependency-refresh snapshot)

The reconciled candidate uses **Ghostty 1.4.0**, its matching zig-objc revision,
Nix Zig **0.17.1**, and SDK **26.5** from the locked nixpkgs input. The results
below predate the implementation above; they do not verify those review fixes
or establish the current commit/push/promotion state. Snapshot promotion was
provided as a manual operation; its completion has not been confirmed here.
At that snapshot, only the earlier baseline had been installed. The newer
user-reported alpha.2 installation is recorded above; GUI acceptance stays open.
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
- [ ] Run on actual macOS 13 on Apple Silicon; the declared deployment floor
      is not proof of runtime compatibility. Intel macOS is no longer supported.

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
      accepted coalesced state using same-directory atomic replacement; current
      fixtures cover serialization, shutdown gating, malformed dimensions,
      replacement, long/Unicode names and cross-profile/during-flush updates.
      Native resize/quit timing still needs manual acceptance.

## Packaging follow-ups

- Developer ID signing/notarization is separate from optional local signing.
  Ad-hoc distribution can trigger Gatekeeper friction. Review keychain-backed
  helpers before use; they are not part of automated/ad-hoc verification.
- Audit transitive binary/resource license notices before public distribution.
- Pure Nix packaging still needs system Xcode/Metal access. Retain deliberate
  dependency pins and host-side runners rather than expanding product scope.
- Do not add first-run wizards, profile editors, transports, or extra overlays
  as part of this reduction.
