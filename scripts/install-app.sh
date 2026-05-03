#!/usr/bin/env bash
# Install a signed Djinn.app bundle into ~/Applications.
# Usage: scripts/install-app.sh <path-to-Djinn.app>
#
# rsync --delete keeps the destination an exact mirror so stale files
# from a previous build (Resources moved/renamed, _CodeSignature drift)
# don't linger and confuse Gatekeeper. We mkdir -p the destination
# parent because ~/Applications is created on demand by macOS the
# first time anything lands there.

set -euo pipefail

src="${1:?usage: $0 <path-to-Djinn.app>}"
if [[ ! -d "$src" ]]; then
  echo "error: '$src' is not a directory" >&2
  exit 1
fi
if [[ ! -f "$src/Contents/Info.plist" ]]; then
  echo "error: '$src' missing Contents/Info.plist — not an .app bundle" >&2
  exit 1
fi

dest_dir="$HOME/Applications"
dest="$dest_dir/Djinn.app"

mkdir -p "$dest_dir"

# rsync over cp -R so re-installs replace cleanly. -a preserves
# permissions + symlinks; --delete prunes anything in dest that's no
# longer in src.
rsync -a --delete "$src/" "$dest/"

echo "installed: $dest"
echo "launch with: open '$dest'"
echo "first launch needs Accessibility permission for the global hotkey."
