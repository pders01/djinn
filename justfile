# djinn — common dev tasks. Build recipes prefer the host's zig if it's
# 0.15.2+; otherwise they fall through to `nix develop` so the bundled
# flake can supply a compatible toolchain. scripts/build.sh applies the
# ghostty darwin patch + unsets nix's Apple SDK overrides so xcrun
# finds the system Metal toolchain.

# Detect a compatible host zig at parse time. `sort -V -C` exits 0 when
# its stdin is already in version-sorted order — so feeding it
# `0.15.2\n<host>` succeeds iff host >= 0.15.2. When the check fails
# (no zig, old zig, or version probe failed), wrap recipes with
# `nix develop` so the flake's pinned zig_0_15 takes over.
nix := if `command -v zig >/dev/null 2>&1 && printf '0.15.2\n%s\n' "$(zig version 2>/dev/null)" | sort -V -C 2>/dev/null && echo yes || echo no` == "yes" { "bash -c" } else { "nix develop --command bash -c" }

# Arch-native zig: prefer the AUR `zig0.15` binary at /usr/bin/zig-0.15
# (matches contrib/packaging/arch/PKGBUILD's makedepend), fall back to
# the nix dev shell when AUR isn't installed. The plain `zig` binary
# on Arch is the stock 0.16 package, which ghostty's `requireZig`
# rejects with a @compileError — never use it directly.
arch_zig := if `command -v zig-0.15 >/dev/null 2>&1 && echo yes || echo no` == "yes" { "zig-0.15" } else { "nix develop --command zig" }

default:
    @just --list

# Build bare debug exe at zig-out/bin/djinn.
build *args:
    {{nix}} './scripts/build.sh {{args}}'

# Run unit suite (config, theme, MCP dispatch+tools, hotkey, …).
test *args:
    {{nix}} './scripts/build.sh test {{args}}'

# Build + launch from the dev cache (no .app bundle).
run *args:
    {{nix}} './scripts/build.sh run {{args}}'

# Build ReleaseFast bare exe — required for meaningful perf measurement.
release:
    {{nix}} './scripts/build.sh -Doptimize=ReleaseFast'

# Build Djinn.app under zig-out/Djinn.app (unsigned).
bundle:
    {{nix}} './scripts/build.sh bundle'

# Build + ad-hoc codesign Djinn.app for Gatekeeper.
sign:
    {{nix}} './scripts/build.sh bundle-sign'

# Build + sign + rsync Djinn.app into ~/Applications.
install-app:
    {{nix}} './scripts/build.sh install-app'

# Arch (and Arch-likes): build ReleaseSafe + sudo-install the binary,
# .desktop entry, and systemd user unit under /usr/local. Pacman does
# not track these; for a tracked install use the PKGBUILD at
# contrib/packaging/arch/ (slower — makepkg clones from GitHub).
# Bypasses scripts/build.sh because its `PATH=/usr/bin:$PATH` prefix
# is darwin-specific (Metal Toolchain discovery) and would shadow the
# AUR zig0.15 with Arch's stock zig 0.16 on linux. The ghostty patch
# is also darwin-only, so we skip it here.
# After install, run `systemctl --user daemon-reload` to pick up the
# user unit, and ensure `/usr/local/bin` is on $PATH.
# Arch (and Arch-likes): build ReleaseSafe + sudo-install under /usr/local.
install-arch:
    {{arch_zig}} build -Doptimize=ReleaseSafe
    sudo install -Dm755 zig-out/bin/djinn /usr/local/bin/djinn
    sudo install -Dm644 contrib/packaging/djinn.desktop /usr/local/share/applications/djinn.desktop
    sudo install -Dm644 contrib/packaging/djinn.service /usr/local/lib/systemd/user/djinn.service
    @echo "djinn installed under /usr/local. Run 'systemctl --user daemon-reload' if you plan to enable the user unit."

# Remove a system install made by `just install-arch`. Idempotent.
uninstall-arch:
    sudo rm -f /usr/local/bin/djinn
    sudo rm -f /usr/local/share/applications/djinn.desktop
    sudo rm -f /usr/local/lib/systemd/user/djinn.service
    @echo "djinn removed from /usr/local."

# Apply patches/ghostty-001-darwin-install.patch (idempotent).
patch:
    ./scripts/apply-ghostty-patch.sh

# Wipe build artifacts (zig-out + .zig-cache). Leaves global zig package cache.
clean:
    rm -rf zig-out .zig-cache

# Sample running djinn via macOS `sample`. Requires `just release` first.
profile duration="10":
    ./scripts/profile.sh {{duration}}

# Reset TCC grants so next launch re-prompts for Accessibility + PostEvent.
tcc-reset:
    tccutil reset All com.pders01.djinn

# One-shot install of a stable self-signed code-signing identity in the
# user's login keychain. Re-running is safe; a present + valid identity
# short-circuits. After this, every `install-app` rebuilds with a stable
# designated requirement so TCC grants persist instead of burning on
# each cdhash change.
dev-cert:
    ./scripts/dev-cert-create.sh

# Smoke loop: build + test in one shot.
check: build test

# One-shot deploy: build + sign + rsync the bundle, kill any running
# instance, relaunch via `open`. The killall step is the important
# bit: `open` brings an already-running djinn to front instead of
# launching the freshly-installed bundle, so without it the on-disk
# binary updates but the in-memory process keeps serving stale code.
# When `dev-cert` has been run, the bundle's designated requirement
# stays stable across rebuilds — so this no longer needs to reset TCC
# every time. First launch still prompts for Accessibility; subsequent
# launches skip the prompt.
deploy: install-app
    killall djinn 2>/dev/null || true
    open ~/Applications/Djinn.app

# Print the active toolchain wrapper (`bash -c` vs `nix develop ... bash -c`).
which-toolchain:
    @echo "{{nix}}"
