#!/usr/bin/env bash
# apply-ghostty-patch.sh — patches Djinn's checkout-local Ghostty source.
# One patch exposes the full libghostty artifact on Darwin. The other keeps
# Vaxis's uucode binding private to each Ghostty compile step so the Debug
# executable and ReleaseFast bundle can coexist in the same build graph.
# Each patch has its own marker; existing extractions only get missing patches.
#
# WHEN TO RUN:
#   - After the first `zig build --fetch` on a fresh checkout
#   - After removing checkout-local zig-pkg/
#   - After bumping the ghostty pin in build.zig.zon (re-fetch
#     re-extracts pristine source; sentinel will be absent again)
#
# scripts/build.sh applies this before invoking the project build.
# These patches target Ghostty v1.4.0.

set -euo pipefail

# The wrapper supplies the target OS; direct invocations default to the host.
# Linux does not instantiate Ghostty or need its Darwin artifact registration.
case "${1:-$(uname -s)}" in
    Darwin|macos) ;;
    *) exit 0 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pull the ghostty hash out of build.zig.zon. Zig package cache dirs
# embed the hash from .hash so `ghostty-<version>-<hash>` is the
# unique key per pin.
HASH=$(awk '/\.ghostty = \.{/,/}/' "$REPO_ROOT/build.zig.zon" \
    | grep -E '^\s*\.hash' \
    | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$HASH" ]]; then
    echo "error: could not parse ghostty hash from build.zig.zon" >&2
    exit 1
fi

# Zig 0.17 extracts packages locally; the global cache holds archives.
# Patch only this checkout's extraction, never another build's sources.
PKG_DIR="${ZIG_LOCAL_PKG_DIR:-$REPO_ROOT/zig-pkg}/$HASH"

if [[ ! -d "$PKG_DIR" ]]; then
    echo "ghostty source not found at $PKG_DIR — run \`zig build --fetch\` first" >&2
    exit 1
fi

apply_patch() {
    local patch_name="$1" source="$2" marker="$3"
    local patch_file="$REPO_ROOT/patches/$patch_name"
    if [[ ! -f "$patch_file" ]]; then
        echo "error: patch file missing at $patch_file" >&2
        return 1
    fi
    if grep -Fq -- "$marker" "$PKG_DIR/$source"; then
        echo "$patch_name already applied — no-op"
        return
    fi
    echo "applying $patch_name to $PKG_DIR"
    patch -p1 -d "$PKG_DIR" < "$patch_file"
}

apply_patch ghostty-001-darwin-install.patch build.zig \
    'djinn local patch: expose the full renderer artifact on Darwin.'
apply_patch ghostty-002-isolate-vaxis-uucode.patch src/build/SharedDeps.zig \
    "djinn local patch: don't mutate the cached Vaxis dependency."
