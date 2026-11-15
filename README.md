# djinn

A terminal-first, Quake-style drop-down terminal for **macOS and Linux**.
A global shortcut shows or hides a native panel. macOS embeds **Ghostty**;
Linux uses **GTK4/VTE**, with Wayland layer-shell where the compositor
supports it. The terminal engines own the PTY, rendering, scrollback,
selection, and text input. Djinn adds panel/focus handling, find, optional
static session tabs, settings, and a small menubar/tray menu.

Run any CLI in the terminal. djinn has **no MCP server, agent adapters,
plugin service, or agent-status model**. There is no log UI, command
palette, keymap cheatsheet, or profile-editing/writeback UI. Profiles are
optional: with no profiles configured, djinn starts an ordinary default
shell. See [TODO.md](TODO.md) for outstanding verification.

## Build and test

Use **Zig 0.17.1**, supplied by the Nix development environment. Platform
backends and dependencies are selected at build time; Linux does not link
Ghostty's renderer or Apple frameworks.

### macOS

New macOS builds and releases require **Apple Silicon (arm64)**. Intel Macs
are no longer supported. The deployment target remains **macOS 13.0**; it is
separate from the macOS 15 CI runner OS and SDK version. Actual macOS 13
runtime acceptance remains outstanding.

Use full Xcode with its optional Metal Toolchain. If that component is missing,
install it manually once:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun -sdk macosx metal --version
```

Alternatively, install it through **Xcode → Settings → Components**.
Verify that `metal --version` succeeds before building; an asset being
listed as downloaded or installed does not by itself establish usability.

From the repository root:

```sh
nix develop --command ./scripts/build.sh                         # debug executable
nix develop --command ./scripts/build.sh test                    # unit tests
nix develop --command ./scripts/build.sh check                   # compile-only native host check (no Metal)
nix develop --command ./scripts/build.sh -Doptimize=ReleaseFast   # release executable
nix develop --command ./scripts/build.sh bundle                  # zig-out/Djinn.app
nix develop --command ./scripts/build.sh bundle-sign             # signed bundle
```

These are host-side builds using system Xcode/Metal, not a pure Nix
package build. `scripts/build.sh` prepares the existing Ghostty patches
and SDK/tool environment before invoking `zig build`. Use the wrapper
rather than bypassing those integration steps. The coordinated dependency
refresh pins **Ghostty 1.4.0** and its release-matched **zig-objc** revision.
Zig 0.17 extracts dependencies into checkout-local `zig-pkg/`, so the small
Darwin artifact-export patch no longer modifies shared cached sources.
The flake selects **SDK 26.5** from the locked nixpkgs input for Zig's SDK
discovery and Ghostty's CoreVideo headers, while delegating Metal tool
execution to system Xcode.
Bundle builds default to a macOS 13 deployment target and baseline CPU,
and load their bundled Ghostty library without Nix/build-cache rpaths.

Equivalent convenience runners include `nix run .#test` and
`nix run .#bundle` (the latter builds the signed bundle). The `just` build,
check, test, and bundle recipes also use the pinned Nix environment rather
than selecting a potentially incompatible host Zig. Use ReleaseFast for
performance checks; no startup, memory, or latency numbers are claimed here.

For ad-hoc verification without keychain-backed signing helpers:

```sh
nix develop --command ./scripts/build.sh bundle check test resources --summary all
codesign --force --sign - zig-out/Djinn.app/Contents/MacOS/libghostty.dylib
codesign --force --sign - zig-out/Djinn.app
./scripts/verify-bundle.sh
```

The verifier checks signatures, deployment targets, runtime linkage, and
resources, then runs relocated `--version`/`--help` in a clean environment
and checks which Ghostty library dyld loaded. CI and release workflows use
this verifier too. These are automated packaging/CLI checks, not GUI or
macOS 13 runtime acceptance.

### Linux

Use the Linux Nix development shell or install development packages for
GTK **4.12 or newer**, VTE's GTK4 variant, gtk4-layer-shell, GLib/GIO,
and pkg-config:

```sh
nix develop --command ./scripts/build.sh check
nix develop --command ./scripts/build.sh test
nix develop --command ./scripts/build.sh -Doptimize=ReleaseSafe
./zig-out/bin/djinn
```

Linux uses the existing VTE backend, not a Ghostty surface emulation. Its
Ghostty-style appearance configuration is a supported subset, not full
Ghostty runtime/configuration parity. Linux dynamically links its native
libraries; the macOS self-contained bundle verifier does not apply to it.

Wayland drop-down positioning depends on compositor layer-shell support.
Global shortcuts use the desktop portal when available; compositor bindings
can invoke `djinn --toggle`, `--show`, or `--hide` as a fallback. The local
control socket is only for these window/instance commands, not an agent API.
Portal approval and compositor policy are distinct from macOS registration.
Linux uses **Ctrl+Alt+R** to restart a session and **Ctrl+Shift+R** for a fresh
interactive shell; ordinary **Ctrl+R** remains available to the terminal's
reverse search. Background/inactive-session BEL can send ordinary desktop
notifications, respecting the enable/rate-limit settings; no agent API is used.

For a compile-only Linux check from a Mac, without GTK development libraries:

```sh
nix develop --command ./scripts/build.sh check test-compile -Dtarget=x86_64-linux-gnu
nix develop --command ./scripts/build.sh check test-compile -Dtarget=aarch64-linux-gnu
```

The shared config/session/persistence suite can run on either host without
linking a native UI backend:

```sh
nix develop --command ./scripts/build.sh test-shared test-linux-models
```

`test-linux-models` selects host-executable backend policy/model/temporary-file
fixtures without GTK linkage. Native Linux API-body checks remain in the
compile-only `test-compile` target and the native Linux test suite.

Release tooling can be checked without installation or publication:

```sh
bash scripts/install-from-release.sh --self-test
python3 scripts/test-release-workflows.py  # Python 3, Ruby YAML/JSON stdlib, jq
```

Cross-compilation is not a Linux link, runtime, or compositor test. Run the
Linux CI/build/test commands on Linux before treating this reconciliation
as Linux-ready. Packaging sources live in `contrib/packaging/`; system
installation is explicit (`-Dsystem-install=true`). A supplied systemd user
unit is optional and is not enabled by a developer build.

## macOS installation and signing

Build and install a signed bundle into `~/Applications`:

```sh
nix develop --command ./scripts/build.sh install-app
open ~/Applications/Djinn.app
```

`nix run .#install` is the equivalent runner. The bundle includes
`libghostty.dylib`, compiled terminfo, shell integration, and themes from
the pinned Ghostty sources; an installed Ghostty.app must not be required.
Verify that with the installed-app acceptance checks below, not just a
dev-tree launch.

Prebuilt bundles and the rolling `pre-release` installer are available at
[Releases](https://github.com/pders01/djinn/releases). Rolling publication is
manual-only pending explicit release approval; it validates the **arm64 macOS
ZIP and x86_64 Linux tarball**, each with a checksum, before replacing downloads.
Linux aarch64 compile-only checks remain supported; there is no aarch64 Linux
release tarball. Versioned releases resolve the requested tag to one exact commit
for both builds. Choose a versioned tag for a pinned release. Downloads are not Developer ID signed/notarized, so Gatekeeper may
require explicit approval. Historical versioned Intel assets are not modified;
known Intel rolling assets are retired only after successful replacement
publication. GitHub tag/asset updates and retirement are not atomic; a failure
can require manual recovery.

`scripts/install-from-release.sh` requires Apple Silicon macOS and refuses
Intel/x86_64 execution before downloading or changing installation files. On
Apple Silicon, run it natively, not under Rosetta. It stages and validates the
archive/checksum, bundle, signature, and native architecture before replacement,
keeping a same-filesystem rollback copy until replacement succeeds. Python 3 is
required for bounded safe ZIP validation/extraction. It
does not quit running sessions, launch the app, or remove quarantine attributes.
A checksum and ad-hoc signature detect corruption, not publisher identity;
Developer ID signing/notarization and native acceptance remain release gates.

The global toggle uses Carbon `RegisterEventHotKey` with exclusive
registration. It does not monitor keyboard events and requires neither
Accessibility nor Input Monitoring permission.

### Stable local signing

Optional: review the helper before running it. It changes the login
keychain and trust settings and may remove an existing certificate with
the same name. This path is not exercised by the ad-hoc verification above.

```sh
just dev-cert
```

This creates the local `DjinnLocalDev` signing identity in the login
keychain. The signing script uses it when available, otherwise falls back
to ad-hoc signing. A stable identity keeps the designated requirement
consistent across rebuilds. This is a local packaging identity, not a
hotkey requirement or a substitute for Developer ID/notarization. Do not
run keychain/signing helpers to fix hotkey registration.

Quit the old app before launching a rebuilt or installed bundle: installing
one does not replace an already running app, whose exclusive hotkey
registration can conflict with another instance.

### Diagnose a failing global hotkey

If menubar show/hide works but the shortcut does not, probe native hotkey
registration separately from the panel. **Quit running Djinn instances
first** to avoid a conflict with their exclusive registration. From the
repository root, invoke the executable directly:

```sh
./zig-out/Djinn.app/Contents/MacOS/djinn --diagnose-hotkey --hotkey ctrl+shift+space
```

`--diagnose-hotkey` accepts an optional `--hotkey` binding. Without that
option it tests the built-in **`ctrl+shift+space`** default, not the binding in
user config. It attempts exclusive native registration, immediately
unregisters on success, and reports the native `OSStatus`, executable path,
bundle identifier, and Secure Input status. It does not perform
Accessibility (AX) or permission-preflight checks, monitor/log keys, load
user config, start a shell, or sync login items.

Registration errors include the native `OSStatus`; an exclusive ownership
conflict is reported as `HotkeyConflict`. Check other running instances
and macOS/global shortcut owners. OS registration cannot discover ordinary
per-app shortcut bindings, and a successful probe does not prove runtime
keyboard delivery or panel behavior. Those still require manual testing.
Accessibility grants, privacy resets, and signing/keychain changes are not
hotkey remedies. If startup registration fails, Djinn temporarily enables
the menubar even when configured off, so Show/Hide and Settings remain
reachable. A rejected live rebind keeps the previous binding/settings;
`--hotkey` remains authoritative across config reloads.

### Launch at login

From a signed, installed bundle:

```sh
~/Applications/Djinn.app/Contents/MacOS/djinn --login-item-enable
~/Applications/Djinn.app/Contents/MacOS/djinn --login-item-status
~/Applications/Djinn.app/Contents/MacOS/djinn --login-item-disable
```

These wrap `SMAppService.mainAppService`; the raw development executable
is not a supported login-item home. Linux exposes the same CLI using an XDG
autostart desktop entry. When `open-at-login` is **omitted**, startup and reload
leave OS registration alone, so CLI/menu enable/disable choices survive restart.
Explicit `open-at-login = true|false` is policy, reconciled at startup and on
each accepted config reload; conflicting CLI/menu actions are rejected. Status
reports actual OS registration separately from policy, including approval or
unknown states. No action rewrites existing configuration. OS/desktop policy can
still prevent startup; enabled registration alone is not native acceptance.

## Configuration

Settings (Cmd+, or the menubar) opens `~/.config/djinn/config` in the default
text editor, creating a small starter file if missing. The format is
`key = value`, with full-line `#` comments. All keys are optional. See
[`config/default.conf`](config/default.conf) for the starter; the menubar
keeps a small mirrored skeleton because its Zig module cannot embed a
file outside `src/`.

```ini
hotkey = ctrl+shift+space
window-width = 800
window-height = 400
window-position = top_center
window-toggle-style = instant
window-topmost = true
hide-on-blur = false
inherit-ghostty = true

# Optional terminal/theme overrides
# font-family = Menlo
# font-size = 13
# padding-x = 8
# padding-y = 8
# scrollback-size = 100000
# opacity = 1.0
# background = #1a1a1e
# foreground = #cccccc
# cursor-color = #ffffff

bell-audible = true
bell-visual = false
bell-sound = Tink
system-notifications = true
notify-rate-limit-ms = 30000
menubar-icon = true
# Omit to leave OS registration under CLI/menu control.
# open-at-login = false
```

Booleans accept `true|yes|on|1` and `false|no|off|0`. Window positions accept
a nine-grid anchor (`top_left`, `top_center`, …, `bottom_right`, with
`center` for the middle) or `X,Y` in NSScreen coordinates. Optional
`window-position-x` / `window-position-y` override individual axes.
`window-toggle-style` is `instant` or `minimize` on macOS. Linux layer-shell
supports the nine named anchors at startup and reload; absolute screen
coordinates are not portable and are reported as unsupported. Without
layer-shell, the native toplevel/compositor controls placement and Djinn reports
that limitation instead of promising coordinate parity.

`scrollback-size` is a **line count**, not bytes: unset leaves backend defaults,
zero retains no scrollback, and a positive value bounds retained lines. macOS
uses Ghostty 1.4's `scrollback-limit-lines`; its independent byte cap may retain
fewer lines (the old `scrollback-limit` alias controls bytes). A macOS change
applies after config reload to **new/lazy/restarted sessions**; already-created
surfaces retain their original caps. Restart a session (or the app for all
sessions) to adopt changed caps. Linux applies VTE's line limit live to existing
terminals and remembers it for lazy/restarted sessions. Reducing a limit can
discard history; increasing/removing it cannot recover discarded history.

The default is **`ctrl+shift+space`**, avoiding the usual Ctrl+Space
input-source shortcut while keeping Space easy to reach across layouts.
Some IDEs use this for completion, so choose another binding if needed.
Existing config files are not rewritten; update their `hotkey` setting
explicitly to adopt the new default. Exclusive registration reports native
`OSStatus` errors and `HotkeyConflict` for ownership conflicts; it cannot
discover ordinary per-app shortcut bindings.

Hotkey config changes apply live: the replacement is registered before the
old binding is removed, and a failed replacement leaves the old binding
active. A config change can also recover registration after startup failed
to acquire a hotkey. A CLI `--hotkey` override remains authoritative during
config reloads. The existing `parseKeybinding` grammar and CG/NSEvent
modifier bits are unchanged; only native registration converts modifiers
to Carbon's representation.

### Optional static profiles

Each configured profile represents one terminal session. Without any,
djinn synthesizes a `default` shell session. Profiles do not select an
agent/provider type.

```ini
default-profile = work
profile.work.script = ~/.config/djinn/profiles/work.sh
profile.work.cwd = ~/projects/work
profile.work.title = Work

profile.shell.title = Shell
# profile.tools.command = /opt/local/bin/my-tool
# profile.tools.bell-audible = false
```

Launch precedence is **`script` > `command` > default shell**. An invalid
explicit script or working directory is a launch-configuration error, not
permission to fall back to another command. Explicit commands are passed
unchanged to Ghostty's shell-command interface; execution failures belong
to that command, not a silent default-shell fallback. Omitting launch
settings intentionally selects the default shell. An unknown
`default-profile` warns and selects the first configured profile.

Use an executable script for arguments, environment setup, version
managers, or secrets, and finish it with `exec`:

```sh
#!/bin/sh
# ~/.config/djinn/profiles/work.sh (make executable with chmod +x)
export PATH="$HOME/.local/bin:$PATH"
exec my-tool --interactive
```

The pinned embedding API interprets `command` as a shell command (not a
structured argv vector). Script paths are validated and shell-quoted as
literal executable paths. Keep complex invocation details in scripts. Profile definitions
are static: **restart djinn after profile changes**. Restarting a session
reuses the loaded profile; it does not reload profile definitions.
Closing a session does not rewrite the config or delete the profile; the
next show starts a fresh child. Saved geometry owns exact profile names and
coalesces each profile independently. Persistence uses 300 ms **periodic
coalescing**, not trailing-edge debounce: continuous resizing can checkpoint
repeatedly, rather than promising one write per drag. Normal shutdown drains
accepted updates after native resize producers detach. The inherited Linux
500 ms geometry observer remains unchanged pending measurements.

Exited command profiles retain Ghostty's
exit/error output until closed or explicitly restarted with Cmd+R. An
explicit profile title wins over the terminal's OSC title.

### Theme inheritance

By default, djinn reads Ghostty's user config and resolves its font,
palette, padding, opacity, blur, and `light:Day,dark:Night` theme choices.
User/system theme locations may be used when present, but Ghostty.app
must not be required to launch djinn. Set `inherit-ghostty = false` for
standalone defaults. Explicit djinn font/padding/color/opacity settings
override inherited values. Use `opacity = 1.0` if translucent rendering
looks too soft on your display.

### Terminal notifications and sound

Terminal-originated notifications are generic title/body messages,
associated with a stable session ID. Runtime policy suppresses banners
from the focused session while Djinn is active; background-tab and
hidden-panel messages are subject to
`system-notifications` and the per-session `notify-rate-limit-ms` window.
The notifier keeps bounded history (16 sources, FIFO eviction); revisiting
an evicted source can deliver immediately. Text is copied before main-queue
dispatch, capped at 256 title bytes and 4096 body bytes without splitting
UTF-8 codepoints. macOS notification settings/Focus can still suppress
banners.

Programs can use ordinary terminal sequences; no host integration service
is needed. For example, from a process with a controlling terminal:

```sh
printf '\033]2;Reference tools\007' > /dev/tty
printf '\033]777;notify;Djinn;Task finished\007' > /dev/tty
```

A hook whose stdout is captured must write to its session's terminal
(such as `/dev/tty`). A detached service without one is not supported by
this interface. Notifications do not inject input or take focus.

BEL sound/visual behavior is separate from banners. Sound names resolve
under `/System/Library/Sounds`; absolute sound paths are restricted to
that directory or `~/Library/Sounds`, with parent traversal rejected.
No agent-kind or per-client notification policy remains. On macOS,
clipboard access follows Ghostty's configured allow/deny policy; requests
requiring host confirmation are denied rather than silently approved
(no permission UI). Explicit user copy and safe paste remain available.
Paste/drop uses Ghostty's protection, including denying explicit user paste
when confirmation would be required. IME commits use a separate text path.
Linux delegates clipboard and IME behavior to GTK/VTE; Ghostty clipboard
permission settings are not a Linux policy layer.

Raw image drops create private, exclusively created temporary PNG files. Failed
writes/rejected handoffs clean only the exact file created by that operation.
Once a path is handed to a terminal, arbitrary programs can read it later—even
after Djinn quits—so there is no safe automatic completion signal. Accepted
files are intentionally retained; no prefix/age scan or quit-time reaper deletes
them. Consumer-aware cleanup remains open; remove a known image only after its
consumer has finished.

### Migration from the agent-oriented build

Removed keys are warned about and ignored; they do not recreate the old
services. Remove `provider`, `provider-command`, `profile.*.provider`,
`mcp-*`, `client.*`, `log-pane-*`, `attention-sound`, and the state gates
`notify-attention`, `notify-error`, `notify-done`, `notify-progress`.
`notify-rate-limit-ms` remains, now keyed by terminal session.

Remove keybinds for `toggle_log_pane`, `palette_open`, `log_filter_open`,
`cheatsheet_open`, `profile_duplicate`, `profile_close`, and `shell_session`.
Use `close_session` for in-memory session closure. Move old provider launch
choices into static `command` settings or executable scripts.

A profile's `command` is now preserved as a shell expression, not unquoted
as a configuration scalar. Keep shell-required quotes around an executable
path with spaces, but remove configuration-only quotes around a whole command
line such as `"tool --flag"` (write `tool --flag` instead).

Old user endpoint/token files, including `~/.config/djinn/mcp.json`, are
**left alone**. djinn no longer writes or consumes them. Remove obsolete
project MCP wiring and clean up those files manually if desired; there is
no automatic credential/config deletion or profile writeback.

## Controls

The menubar always uses the djinn brand mark. Its menu contains the active
session label, show/hide, Settings, OS-backed Launch at Login, and Quit.

| Action | Default binding |
|---|---|
| Show / hide | `Ctrl+Shift+Space` (configurable) |
| Copy / paste | `Cmd+C` / `Cmd+V` |
| Find / next / previous | `Cmd+F` / `Cmd+G` / `Cmd+Shift+G` |
| Increase / decrease / reset font | `Cmd+=` (also `Cmd++`) / `Cmd+-` / `Cmd+0` |
| Scroll page up / down | `Cmd+Up` / `Cmd+Down` |
| Clear scrollback | `Cmd+K` |
| Select session | `Cmd+1` … `Cmd+9` |
| Next / previous session | `Cmd+Shift+]` / `Cmd+Shift+[` |
| Restart session | `Cmd+R` |
| Close session | `Cmd+Shift+W` |
| Cycle theme override | `Cmd+Shift+T` |
| Settings | `Cmd+,` |
| Quit | `Cmd+Q` (menubar) |

Find rejects malformed UTF-8 and control-character payloads; oversized
search selections are truncated at a complete UTF-8 boundary. Rejected find
text/paste never falls through to the terminal.

Host overrides use `keybind = action=trigger`. The current host action table
contains `copy`, `paste`, `find_open`, `find_next`, `find_prev`, `font_inc`,
`font_inc_shift`, `font_dec`, `font_reset`, `scroll_page_up`,
`scroll_page_down`, `clear_scrollback`, `tab_1` … `tab_9`, `next_tab`,
`prev_tab`, `restart_session`, `close_session`, `theme_toggle`, and
`open_settings`. For example: `keybind = clear_scrollback=cmd+l`.

## Manual acceptance before release

- Launch the **installed signed app** outside the checkout/dev shell,
  with Ghostty.app absent; verify bundled dylib/resources and default shell.
- Verify native hotkey delivery without Accessibility/Input Monitoring
  grants, exclusive conflicts, live rebinding (including failed replacement
  retention and recovery after startup registration failure), and CLI
  `--hotkey` precedence on reload. A diagnostic probe is not keyboard acceptance.
- Verify repeated show/hide, blur policy, Cmd+Tab focus restoration,
  fullscreen/Spaces, resize, and multiple screens/scales.
- Test IME preedit/candidate placement, composed text, clipboard, drag/drop,
  hyperlink opening, scrollback, find, font changes, and session switching.
- Sleep/wake with active and hidden sessions; check rendering, input, and
  focus after waking and after screen changes.
- Test no-profile startup, static script/command profiles, explicit launch
  errors, restart/close behavior, and profile changes taking effect only
  after app restart. Confirm config is not rewritten.
- Send terminal notifications from focused, background, and hidden sessions; verify suppression,
  per-session rate boundaries, text truncation, macOS Focus, and BEL settings.
- Check settings creation/open, theme changes while hidden, login-item
  registration, clean quit, and relaunch of the installed app.
- Measure ReleaseFast launch/show latency, idle CPU, and memory over repeated
  session restarts and hide/show cycles. Record machine/build/workload;
  do not infer performance from debug builds or claim unmeasured targets.

These checks are not automated guarantees. Track results in [TODO.md](TODO.md).

## Acknowledgements and license

Built on [Ghostty](https://github.com/ghostty-org/ghostty),
[zig-objc](https://github.com/mitchellh/zig-objc), and Apple's macOS
frameworks, following the Quake-drop terminal lineage. See
[NOTICES.md](NOTICES.md) for third-party attribution. MIT — see [LICENSE](LICENSE).
