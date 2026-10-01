#!/bin/bash
# Imports HeyMate's self-signed code-signing identity into a throwaway
# keychain and prints the identity's SHA-1 for CODE_SIGN_IDENTITY.
#
# Why self-signed and not ad-hoc: macOS keys Accessibility, Screen Recording
# and Microphone grants to the app's designated requirement. An ad-hoc
# signature's requirement is the binary's own hash, so every release looked
# like a new app and every update wiped the user's permissions. A certificate
# that never changes gives every release the same requirement, so grants
# survive updates. It does not remove the first-open Gatekeeper warning —
# only a paid Developer ID with notarization does that.
#
# Usage: import-signing-identity.sh <keychain-path>
#   env HEYMATE_SIGNING_P12_BASE64, HEYMATE_SIGNING_P12_PASSWORD
set -euo pipefail

KEYCHAIN_PATH="$1"
: "${HEYMATE_SIGNING_P12_BASE64:?HEYMATE_SIGNING_P12_BASE64 is not set}"
: "${HEYMATE_SIGNING_P12_PASSWORD:?HEYMATE_SIGNING_P12_PASSWORD is not set}"

KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
P12_PATH=$(mktemp -t heymate-signing).p12
trap 'rm -f "$P12_PATH"' EXIT
printf '%s' "$HEYMATE_SIGNING_P12_BASE64" | base64 --decode > "$P12_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >&2
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$HEYMATE_SIGNING_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >&2
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Xcode only looks for identities in the user's keychain search list.
EXISTING=$(security list-keychains -d user | tr -d '"')
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING >&2

# Untrusted self-signed identities are left out of `-v` (valid-only), so
# list them all and take the HeyMate one.
IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN_PATH" \
  | awk '/HeyMate Open Source Signing/ { print $2; exit }')
test -n "$IDENTITY" || { echo "::error::signing identity not found after import" >&2; exit 1; }
echo "$IDENTITY"
