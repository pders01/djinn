#!/usr/bin/env bash
# build.sh — wrapper around `zig build` that handles the Tier-5
# integration prereqs:
#
#   1. `zig fetch` to materialize ghostty in the global cache.
#   2. Apply patches/ghostty-001-darwin-install.patch via
#      scripts/apply-ghostty-patch.sh (idempotent).
#   3. Invoke `zig build` with the args we got, with environment
#      tweaks that let xcrun find the system Metal Toolchain instead
#      of nix's stripped Apple SDK.
#
# Why we need this:
#   djinn now links against the full libghostty (not just
#   ghostty-vt-static) so the surface API is reachable. ghostty's
#   build.zig has an upstream darwin install guard that the patch
#   removes, and ghostty's Metal renderer compiles `.metal` shaders
#   via `xcrun -sdk macosx metal` which needs the system toolchain
#   on PATH and `DEVELOPER_DIR` / `SDKROOT` un-overridden. The nix
#   dev shell sets those env vars to a stripped-down apple-sdk-14.4
#   that doesn't ship Metal.
#
# Prereqs the user has to satisfy once:
#   - Xcode + the optional Metal Toolchain component:
#       sudo xcodebuild -downloadComponent MetalToolchain
#   - Run from inside `nix develop` (or any shell with zig 0.15.2+).
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

# Step 1: ensure the ghostty source is in the cache. `zig fetch`
# without args is a no-op in 0.15; `zig build --fetch` does the
# resolve without compiling anything.
zig build --fetch >/dev/null 2>&1 || true

# Step 2: apply patches (idempotent).
"$REPO_ROOT/scripts/apply-ghostty-patch.sh"

# Step 3: build with the right env. Unset the nix-imposed Apple SDK
# overrides so xcrun falls back to system Xcode for the Metal
# Toolchain lookup. Prepend /usr/bin so the system xcrun (which
# resolves through Xcode) shadows the nix `xcbuild` shim.
unset DEVELOPER_DIR SDKROOT
PATH="/usr/bin:$PATH" exec zig build "$@"
