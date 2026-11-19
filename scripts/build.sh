#!/usr/bin/env bash
# build.sh — cross-platform wrapper around `zig build`. Linux goes directly
# to Zig (GTK4/VTE via pkg-config); macOS handles the ghostty
# integration prerequisites:
#
#   1. `zig build --fetch` to materialize ghostty in checkout-local zig-pkg/.
#   2. Apply the checkout-local Ghostty patches via
#      scripts/apply-ghostty-patch.sh (idempotent).
#   3. Invoke `zig build` with the args we got, with environment
#      tweaks that let xcrun find the system Metal Toolchain instead
#      of nix's stripped Apple SDK.
#
# Why we need this:
#   djinn now links against the full libghostty (not just
#   ghostty-vt-static) so the surface API is reachable. ghostty's
#   build.zig does not register the full artifact on Darwin; the patch
#   adds that registration. ghostty's Metal renderer compiles `.metal` shaders
#   via `xcrun -sdk macosx metal` which needs the system toolchain
#   on PATH and `DEVELOPER_DIR` / `SDKROOT` un-overridden. The Nix
#   xcrun wrapper answers SDK discovery with the pinned Nix SDK (also
#   needed to link Zig's build runner), but delegates tool execution
#   to system Xcode, since the Nix SDK doesn't ship Metal.
#
# Prereqs the user has to satisfy once:
#   - Xcode + the optional Metal Toolchain component:
#       xcodebuild -downloadComponent MetalToolchain
#       xcrun -sdk macosx metal --version
#   - Run from inside `nix develop` (or a shell with Zig exactly 0.17.1).
#
# All args after `build.sh` are forwarded verbatim to `zig build`,
# e.g.:
#   ./scripts/build.sh                      # debug
#   ./scripts/build.sh -Doptimize=ReleaseFast
#   ./scripts/build.sh test
#   ./scripts/build.sh install-app

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Linux uses VTE and needs neither Ghostty extraction nor an Apple patch.
# Honor cross-target checks too, e.g. build.sh check -Dtarget=x86_64-linux-gnu.
TARGET_OS="$(uname -s)"
for arg in "$@"; do
    case "$arg" in
        -Dtarget=*-linux*) TARGET_OS=Linux ;;
        -Dtarget=*-macos*) TARGET_OS=Darwin ;;
        -Dtarget=native) TARGET_OS="$(uname -s)" ;;
    esac
done

if [[ "$TARGET_OS" == Darwin ]]; then
    # Preserve pinned SDK discovery; use system Xcode for Metal tools.
    unset DEVELOPER_DIR SDKROOT
    export PATH="${DJINN_XCRUN_BIN:+$DJINN_XCRUN_BIN:}/usr/bin:$PATH"

    # Graph resolution may fail before the first patch. The real build below
    # must still succeed; do not hide any of its diagnostics or exit status.
    zig build --fetch "$@" >/dev/null 2>&1 || true
    "$REPO_ROOT/scripts/apply-ghostty-patch.sh" macos
fi

exec zig build "$@"
