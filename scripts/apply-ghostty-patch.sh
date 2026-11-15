#!/usr/bin/env bash
# apply-ghostty-patch.sh — patches the checkout-local upstream ghostty source
# in-place so `dep.artifact("ghostty")` resolves on darwin.
#
# WHY:
#   ghostty's build.zig gates its `install*` calls for the full
#   libghostty behind `if (!isDarwin)`. Zig's `dep.artifact()` lookup
#   reads the install registry, so on macOS the artifact is invisible
#   to djinn. The patch registers the shared renderer explicitly on
#   Darwin without changing upstream's other installation behavior.
#
# IDEMPOTENCY:
#   The script (a) locates the extracted ghostty dir from
#   build.zig.zon's pinned hash, (b) checks for a sentinel string the
#   patch introduces (`djinn local patch`), and (c) applies via
#   `patch -p1` only when the sentinel is absent. Re-runs are no-ops.
#
# WHEN TO RUN:
#   - After the first `zig build --fetch` on a fresh checkout
#   - After removing checkout-local zig-pkg/
#   - After bumping the ghostty pin in build.zig.zon (re-fetch
#     re-extracts pristine source; sentinel will be absent again)
#
# scripts/build.sh applies this before invoking the project build.
# This patch revision targets Ghostty v1.4.0.

set -euo pipefail

# The wrapper supplies the target OS; direct invocations default to the host.
# Linux does not instantiate Ghostty or need its Darwin artifact registration.
case "${1:-$(uname -s)}" in
    Darwin|macos) ;;
    *) exit 0 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$REPO_ROOT/patches/ghostty-001-darwin-install.patch"
SENTINEL="djinn local patch"

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "error: patch file missing at $PATCH_FILE" >&2
    exit 1
fi

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

if grep -q "$SENTINEL" "$PKG_DIR/build.zig" 2>/dev/null; then
    echo "patch already applied to $PKG_DIR — no-op"
    exit 0
fi

echo "applying ghostty-001-darwin-install.patch to $PKG_DIR"
patch -p1 -d "$PKG_DIR" < "$PATCH_FILE"
echo "done"
