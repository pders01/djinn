#!/usr/bin/env bash
#
# One-shot: create a self-signed code-signing cert in the login keychain
# so every `install-app` re-signs the bundle under the same identity.
# TCC keys grants on cdhash for ad-hoc-signed binaries, so each rebuild
# burns Accessibility / Input Monitoring grants. With a stable signing
# identity, the bundle's designated requirement stays constant across
# rebuilds and macOS treats every new build as the same app.
#
# Idempotent — re-running detects an existing identity and skips.
# Run once: `./scripts/dev-cert-create.sh`. Then deploy as usual; the
# bundle codesign step picks up the identity automatically when present.
#
# This is NOT a substitute for a paid Developer ID. Self-signed certs
# don't pass Gatekeeper notarization and won't survive distribution
# outside this machine. They're fine for solo local iteration.

set -euo pipefail

IDENTITY="DjinnLocalDev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if security find-identity -v -p codesigning login.keychain 2>/dev/null \
        | grep -q "\"$IDENTITY\""; then
    echo "identity '$IDENTITY' already present + valid in login.keychain — nothing to do"
    exit 0
fi

# Drop any prior partial install (cert without paired key, untrusted
# cert, etc.) before re-running. Avoids duplicate cert entries piling
# up in keychain on repeated invocations.
while security find-certificate -c "$IDENTITY" login.keychain >/dev/null 2>&1; do
    security delete-certificate -c "$IDENTITY" login.keychain >/dev/null 2>&1 || break
done

# OpenSSL config: codeSigning EKU is required for codesign to accept
# the cert. CA:false marks it as a leaf, not a root authority.
cat >"$WORKDIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
req_extensions = ext

[dn]
CN = $IDENTITY

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
    -config "$WORKDIR/cert.cnf" -extensions ext

# macOS's `security import` rejects empty PKCS12 passwords on some
# OS versions, so we use a fixed throwaway pass for the import handoff.
# `-legacy` + `-macalg SHA1` produce a PKCS12 the macOS security CLI
# accepts; modern OpenSSL defaults (AES-256 + SHA-256 MAC) trip
# `MAC verification failed` against Apple's keychain importer.
PASS="djinn-import-handoff"
openssl pkcs12 -export -legacy -macalg SHA1 \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -name "$IDENTITY" -out "$WORKDIR/bundle.p12" \
    -passout "pass:$PASS"

# `-T /usr/bin/codesign` whitelists codesign so it can use the private
# key without an interactive keychain prompt on every sign call.
security import "$WORKDIR/bundle.p12" \
    -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

# Self-signed cert isn't anchored to any system-trusted root, so
# `find-identity -v -p codesigning` filters it out by default. Marking
# the cert as trusted-for-code-signing in the *user's* login keychain
# (no sudo, no /Library/Keychains) makes codesign accept it locally
# without affecting the rest of the system.
security add-trusted-cert -d -r trustAsRoot -p codeSign \
    -k "$KEYCHAIN" "$WORKDIR/cert.pem" 2>/dev/null || true

# Re-binding the private key's partition list so codesign can use it
# without an interactive prompt. The empty -k password assumes the
# user's login keychain matches their account login (default).
# Failures here are non-fatal — codesign will still work, just with
# a one-time keychain unlock prompt on first sign.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "identity '$IDENTITY' installed in login.keychain"
echo "bundle codesign step will pick it up on next 'just deploy'"
