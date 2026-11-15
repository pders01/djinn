# djinn — common dev tasks. Build recipes use the locked Nix environment
# and Zig 0.17.1 rather than accepting an incompatible host compiler.
# scripts/build.sh applies the Ghostty patch and preserves SDK discovery.
nix := "nix develop --command bash -c"

default:
    @just --list

# Build bare debug exe at zig-out/bin/djinn.
build *args:
    {{nix}} './scripts/build.sh {{args}}'

# Run unit suite (config, theme, hotkey, …).
test *args:
    {{nix}} './scripts/build.sh test {{args}}'

# Offline script/metadata and workflow fixtures (Python 3, Ruby and jq).
test-tooling:
    python3 scripts/test-tooling.py
    python3 scripts/test-release-workflows.py

# Build + launch from the dev cache (no .app bundle).
run *args:
    {{nix}} './scripts/build.sh run {{args}}'

# Build ReleaseFast bare exe — required for meaningful perf measurement.
release:
    {{nix}} './scripts/build.sh -Doptimize=ReleaseFast'

# Build Djinn.app under zig-out/Djinn.app (unsigned).
bundle:
    {{nix}} './scripts/build.sh bundle'

# Build and locally sign Djinn.app.
sign:
    {{nix}} './scripts/build.sh bundle-sign'

# Build + sign + rsync Djinn.app into ~/Applications.
install-app:
    {{nix}} './scripts/build.sh install-app'

# Arch (and Arch-likes): build ReleaseSafe + sudo-install the binary,
# .desktop entry, and systemd user unit under /usr/local. Pacman does
# not track these; for a tracked install use the PKGBUILD at
# contrib/packaging/arch/ (slower — makepkg clones from GitHub).
# Uses the same pinned Zig 0.17.1 dev shell and platform-aware wrapper.
# Neither desktop launch nor the user unit is automatically enabled.
# After install, run `systemctl --user daemon-reload` to pick up the
# user unit, and ensure `/usr/local/bin` is on $PATH.
# Arch (and Arch-likes): build ReleaseSafe + sudo-install under /usr/local.
install-arch:
    {{nix}} './scripts/build.sh -Doptimize=ReleaseSafe'
    sudo install -Dm755 zig-out/bin/djinn /usr/local/bin/djinn
    sudo install -Dm644 contrib/packaging/djinn.desktop /usr/local/share/applications/djinn.desktop
    # The packaged unit has ExecStart=/usr/bin/djinn (the AUR install
    # path); when landing under /usr/local we rewrite it in place so
    # systemd doesn't fail with status=203/EXEC against a missing
    # /usr/bin/djinn after a same-system AUR uninstall.
    sudo install -Dm644 contrib/packaging/djinn.service /usr/local/lib/systemd/user/djinn.service
    sudo sed -i 's|^ExecStart=/usr/bin/djinn$|ExecStart=/usr/local/bin/djinn|' /usr/local/lib/systemd/user/djinn.service
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

# One-shot install of a stable self-signed code-signing identity in the
# user's login keychain. Review the helper first: it changes keychain and
# trust settings and may remove a prior certificate with the same name.
# Native shortcut registration does not require this identity.
# Create an optional local signing identity (mutates the keychain).
dev-cert:
    ./scripts/dev-cert-create.sh

# Compile-check the platform host without linking Ghostty/GTK or invoking Metal.
# Cross-check Linux on Mac: just compile-check -Dtarget=x86_64-linux-gnu.
compile-check *args:
    {{nix}} './scripts/build.sh check {{args}}'

# Fast validation loop; use bundle separately for full linkage/Metal checks.
check: compile-check test

# One-shot deploy: build + sign + rsync the bundle, kill any running
# instance, relaunch via `open`. The killall step is the important
# bit: `open` brings an already-running djinn to front instead of
# launching the freshly-installed bundle, so without it the on-disk
# binary updates but the in-memory process keeps serving stale code.
# Native shortcut registration does not require Accessibility grants or
# privacy resets; any other running instance can still own the shortcut.
# Build, sign, install, and relaunch the app.
deploy: install-app
    killall djinn 2>/dev/null || true
    open ~/Applications/Djinn.app

# Print the pinned toolchain wrapper.
which-toolchain:
    @echo "{{nix}}"
