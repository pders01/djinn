#!/usr/bin/env bash
#
# Sign Djinn.app with a stable identity if one's available, else fall
# back to ad-hoc. A stable identity keeps the bundle's designated
# requirement constant across rebuilds, so macOS's TCC database
# preserves Accessibility / Input Monitoring grants instead of treating
# every new cdhash as a new app.
#
# Identity is `DjinnLocalDev` (created by `scripts/dev-cert-create.sh`)
# unless `DJINN_SIGN_IDENTITY` overrides. Falls back to ad-hoc when
# neither is found — local builds still launch, but every install-app
# burns TCC grants as before.

set -euo pipefail

bundle="$1"
identity="${DJINN_SIGN_IDENTITY:-DjinnLocalDev}"

# `find-identity -v` filters out self-signed identities that aren't
# anchored to a system-trusted root, even though codesign itself
# accepts them. Probe by certificate presence instead, then attempt
# the signed path with a fallback to ad-hoc on failure.
#
# codesign's stderr is preserved so a failed signed-path sign
# (expired cert, keychain locked, entitlement clash, …) shows a
# diagnostic before the ad-hoc fallback masks it as success.
if security find-certificate -c "$identity" login.keychain >/dev/null 2>&1; then
    if codesign --force --sign "$identity" --deep "$bundle"; then
        exit 0
    fi
    echo "codesign with '$identity' failed; falling back to ad-hoc" >&2
fi

codesign --force --sign - --deep "$bundle"
