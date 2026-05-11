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
