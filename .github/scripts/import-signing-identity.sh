#!/bin/bash
# Imports HeyMate's Developer ID Application identity into a throwaway
# keychain and prints the identity's SHA-1 for CODE_SIGN_IDENTITY / codesign.
#
# Why Developer ID: macOS keys Accessibility, Screen Recording, Microphone and
# Input Monitoring grants to the app's designated requirement. A Developer ID
# requirement names Apple's anchor plus the team ID, so every release (and
# every renewed certificate from the same team) keeps the user's grants, and
# notarization removes the first-open Gatekeeper warning.
#
# Usage: import-signing-identity.sh <keychain-path>
#   env DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD, HEYMATE_TEAM_ID
set -euo pipefail

KEYCHAIN_PATH="$1"
: "${DEVELOPER_ID_P12_BASE64:?DEVELOPER_ID_P12_BASE64 is not set}"
: "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is not set}"
: "${HEYMATE_TEAM_ID:?HEYMATE_TEAM_ID is not set}"

KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
SCRATCH=$(mktemp -d -t heymate-signing)
trap 'rm -rf "$SCRATCH"' EXIT
P12_PATH="$SCRATCH/identity.p12"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$P12_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >&2
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >&2

# A p12 exported from Keychain Access usually holds only the leaf. codesign
# needs Apple's Developer ID intermediate to embed the full chain. A forged
# intermediate could not chain to Apple's root, so the identity check below
# would reject it.
for CA in DeveloperIDG2CA DeveloperIDCA; do
  if curl -fsSL --retry 3 "https://www.apple.com/certificateauthority/$CA.cer" -o "$SCRATCH/$CA.cer"; then
    security import "$SCRATCH/$CA.cer" -k "$KEYCHAIN_PATH" >&2 || true
  fi
done
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Xcode only looks for identities in the user's keychain search list.
EXISTING=$(security list-keychains -d user | tr -d '"')
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING >&2

# -v keeps only identities whose chain validates to Apple's root.
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
  | awk -v team="($HEYMATE_TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }')
if [ -z "$IDENTITY" ]; then
  echo "::error::No valid Developer ID Application identity for team $HEYMATE_TEAM_ID after import" >&2
  security find-identity -p codesigning "$KEYCHAIN_PATH" >&2 || true
  exit 1
fi
echo "$IDENTITY"
