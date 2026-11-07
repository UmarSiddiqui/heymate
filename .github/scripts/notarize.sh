#!/usr/bin/env bash
# Submits one file to Apple's notary service and waits for the verdict.
#
# Usage: notarize.sh <file.zip|file.dmg> <log-dir>
# Needs NOTARY_KEY_P8_BASE64, NOTARY_KEY_ID and NOTARY_ISSUER_ID.
# Writes <log-dir>/result.json and <log-dir>/log.json, kept whatever the
# outcome so a rejection can be diagnosed. Exits non-zero unless Accepted.
set -euo pipefail

FILE="$1"
LOG_DIR="$2"

for NAME in NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [ -n "${!NAME:-}" ] || { echo "::error::$NAME secret is not set in the release environment"; exit 1; }
done

KEY_DIR=$(mktemp -d)
trap 'rm -rf "$KEY_DIR"' EXIT
KEY_PATH="$KEY_DIR/AuthKey_$NOTARY_KEY_ID.p8"
(umask 077; printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$KEY_PATH")
NOTARY_AUTH=(--key "$KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

mkdir -p "$LOG_DIR"
xcrun notarytool submit "$FILE" "${NOTARY_AUTH[@]}" --wait --timeout 45m --output-format json \
  > "$LOG_DIR/result.json" || true
cat "$LOG_DIR/result.json"
NOTARY_ID=$(/usr/bin/plutil -extract id raw "$LOG_DIR/result.json" 2>/dev/null || true)
NOTARY_STATUS=$(/usr/bin/plutil -extract status raw "$LOG_DIR/result.json" 2>/dev/null || true)
[ -n "$NOTARY_ID" ] || { echo "::error::Notarization submission for $(basename "$FILE") failed; no submission ID"; exit 1; }
xcrun notarytool log "$NOTARY_ID" "${NOTARY_AUTH[@]}" "$LOG_DIR/log.json" || true
cat "$LOG_DIR/log.json" 2>/dev/null || true
[ "$NOTARY_STATUS" = "Accepted" ] \
  || { echo "::error::Notarization of $(basename "$FILE") is ${NOTARY_STATUS:-unknown} (submission $NOTARY_ID)"; exit 1; }
