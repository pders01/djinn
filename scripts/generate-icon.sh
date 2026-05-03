#!/usr/bin/env bash
# generate-icon.sh — produce assets/Djinn.icns from the swift renderer.
#
# Pipeline:
#   1. swift generate-icon.swift  → 1024x1024 PNG master
#   2. sips                       → fan out to the macOS iconset sizes
#   3. iconutil --convert icns    → pack into Djinn.icns
#
# Run once per icon-design change; commit the resulting .icns. CI
# doesn't regenerate (build hosts may lack a usable swift toolchain).
#
# Required: macOS with /usr/bin/swift, /usr/bin/sips, /usr/bin/iconutil.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$REPO/assets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/Djinn.iconset"
MASTER="$WORK/icon-1024.png"
mkdir -p "$ICONSET" "$ASSETS"

echo "rendering 1024x1024 master via swift…"
/usr/bin/swift "$REPO/scripts/generate-icon.swift" "$MASTER"

echo "fanning out via sips…"
# macOS .icns naming is by point size, with @2x doubling the pixel
# count. iconutil rejects iconsets that are missing any of these slots.
for pt in 16 32 128 256 512; do
    /usr/bin/sips -Z "$pt"        "$MASTER" --out "$ICONSET/icon_${pt}x${pt}.png"     >/dev/null
    /usr/bin/sips -Z "$((pt * 2))" "$MASTER" --out "$ICONSET/icon_${pt}x${pt}@2x.png" >/dev/null
done

echo "packing Djinn.icns…"
/usr/bin/iconutil --convert icns "$ICONSET" --output "$ASSETS/Djinn.icns"

echo "wrote $ASSETS/Djinn.icns"
ls -la "$ASSETS/Djinn.icns"
