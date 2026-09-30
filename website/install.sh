#!/bin/bash
# HeyMate installer. Usage: curl -fsSL https://getheymate.vercel.app/install.sh | bash
#
# Downloads the latest HeyMate.dmg with curl, which does not set the macOS
# quarantine flag, so Gatekeeper never shows "could not verify HeyMate is free
# of malware". Source: https://github.com/UmarSiddiqui/heymate
set -euo pipefail

URL="https://github.com/UmarSiddiqui/heymate/releases/latest/download/HeyMate.dmg"
APP="HeyMate.app"
DEST="/Applications"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "HeyMate is a macOS app." >&2
  exit 1
fi

TMP="$(mktemp -d)"
MOUNT="$TMP/mount"
cleanup() {
  status=$?
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$TMP"
  if [ "$status" -ne 0 ]; then
    echo "" >&2
    echo "HeyMate did not install. Stuck? Open an issue or email me:" >&2
    echo "  https://github.com/UmarSiddiqui/heymate/issues/new?template=install.yml" >&2
    echo "  umarsiddiqui3037+heymate@gmail.com" >&2
  fi
}
trap cleanup EXIT

echo "Downloading HeyMate..."
curl -fL --progress-bar -o "$TMP/HeyMate.dmg" "$URL"

mkdir -p "$MOUNT"
hdiutil attach "$TMP/HeyMate.dmg" -mountpoint "$MOUNT" -nobrowse -quiet

if [ ! -d "$MOUNT/$APP" ]; then
  echo "Could not find $APP in the disk image." >&2
  exit 1
fi

# Quit a running copy so the replacement isn't in use.
osascript -e 'tell application "HeyMate" to quit' >/dev/null 2>&1 || true

echo "Installing to $DEST..."
if [ -w "$DEST" ]; then
  rm -rf "$DEST/$APP"
  cp -R "$MOUNT/$APP" "$DEST/"
else
  sudo rm -rf "$DEST/$APP"
  sudo cp -R "$MOUNT/$APP" "$DEST/"
fi

# Belt and braces: make sure no quarantine flag is left on the installed app.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "Installed. Opening HeyMate..."
open "$DEST/$APP"
