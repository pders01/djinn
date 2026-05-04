#!/usr/bin/env bash
#
# One-liner installer for djinn pre-release builds. Downloads the
# latest rolling bundle from GitHub Releases, drops it in
# `~/Applications`, opens it. Requires only `curl` + `unzip`
# (preinstalled on macOS).
#
# Usage:
#     curl -fsSL https://github.com/pders01/djinn/releases/download/pre-release/install.sh | bash
#
# Or with a specific tag:
#     curl -fsSL https://github.com/pders01/djinn/releases/download/<tag>/install.sh | bash
#
# Set DJINN_TAG in the env to override the default `pre-release` tag.

set -euo pipefail

REPO="pders01/djinn"
TAG="${DJINN_TAG:-pre-release}"
ARCH="$(uname -m)"            # arm64 or x86_64
DEST="$HOME/Applications"
APP_NAME="Djinn.app"
ZIP_NAME="Djinn-${TAG}-${ARCH}.zip"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "djinn is macOS-only; refusing to install on $(uname -s)" >&2
    exit 1
fi

echo "→ downloading $URL"
tmp_zip="$(mktemp -t djinn-install.XXXXXX).zip"
trap 'rm -f "$tmp_zip"' EXIT

curl --fail --location --progress-bar -o "$tmp_zip" "$URL"

mkdir -p "$DEST"

# Wipe any prior install at the target path so the unzip lands fresh.
# `~/Applications` is owned by the user — no sudo needed.
if [ -d "$DEST/$APP_NAME" ]; then
    echo "→ replacing existing $DEST/$APP_NAME"
    rm -rf "$DEST/$APP_NAME"
fi

echo "→ unpacking into $DEST"
unzip -q -o "$tmp_zip" -d "$DEST"

# Strip macOS's Gatekeeper quarantine xattr that any-zip-from-internet
# inherits. Without this the user gets a "downloaded from the
# internet" prompt on first launch even though the bundle is signed
# (ad-hoc signature doesn't satisfy Gatekeeper notarization).
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

echo "→ launching $APP_NAME"
open "$DEST/$APP_NAME"

cat <<EOF

djinn installed at $DEST/$APP_NAME

First launch will prompt for Accessibility permission (needed for
the global hotkey). Grant it in System Settings → Privacy & Security
→ Accessibility, then re-launch.
EOF
