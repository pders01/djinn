#!/usr/bin/env bash
# apply-ghostty-patch.sh — patches the cached upstream ghostty source
# in-place so `dep.artifact("ghostty")` resolves on darwin.
#
# WHY:
#   ghostty's build.zig gates its `install*` calls for the full
#   libghostty behind `if (!isDarwin)`. Zig's `dep.artifact()` lookup
#   reads the install registry, so on macOS the artifact is invisible
#   to djinn. Patching the cached source removes the guard locally
#   without forking ghostty.
#
# IDEMPOTENCY:
#   The script (a) locates the cached ghostty dir from
#   build.zig.zon's pinned hash, (b) checks for a sentinel string the
#   patch introduces (`djinn local patch`), and (c) applies via
#   `patch -p1` only when the sentinel is absent. Re-runs are no-ops.
#
# WHEN TO RUN:
#   - After the first `zig fetch` / `zig build` on a fresh checkout
#   - After `rm -rf ~/.cache/zig` or other cache wipes
#   - After bumping the ghostty pin in build.zig.zon (re-fetch
#     re-extracts pristine source; sentinel will be absent again)
#
# Not currently wired into `zig build` — Tier 5 hasn't started, the
# main build still uses `ghostty-vt-static` which needs no patching.

set -euo pipefail

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

# Resolve the global zig cache path. Default is `~/.cache/zig` on
# linux/darwin; ZIG_GLOBAL_CACHE_DIR overrides.
CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}"
PKG_DIR="$CACHE_DIR/p/$HASH"

if [[ ! -d "$PKG_DIR" ]]; then
    echo "ghostty cache not found at $PKG_DIR — run \`zig fetch\` or \`zig build\` first" >&2
    exit 1
fi

if grep -q "$SENTINEL" "$PKG_DIR/build.zig" 2>/dev/null; then
    echo "patch already applied to $PKG_DIR — no-op"
    exit 0
fi

echo "applying ghostty-001-darwin-install.patch to $PKG_DIR"
patch -p1 -d "$PKG_DIR" < "$PATCH_FILE"
echo "done"
