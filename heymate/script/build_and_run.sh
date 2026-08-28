#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HeyMate"
BUNDLE_ID="com.heymate.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

HEYMATE_TEAM="${HEYMATE_DEVELOPMENT_TEAM:-}"
SIGNING_IDENTITY="${HEYMATE_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  IDENTITY_LISTING=$(security find-identity -v -p codesigning 2>/dev/null || true)
  if [ -n "$HEYMATE_TEAM" ]; then
    SIGNING_IDENTITY=$(printf '%s\n' "$IDENTITY_LISTING" \
      | grep -F "($HEYMATE_TEAM)" \
      | sed -n 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) "Apple Development:.*/\1/p' \
      | head -1 || true)
  else
    SIGNING_IDENTITY=$(printf '%s\n' "$IDENTITY_LISTING" \
      | sed -n 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) "Apple Development:.*/\1/p' \
      | head -1)
  fi
fi

if [ -n "$SIGNING_IDENTITY" ]; then
  echo "Final app will use local Apple Development identity."
else
  echo "No Apple Development identity found; using local ad-hoc signing."
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/leanring-buddy.xcodeproj" \
  -scheme leanring-buddy \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

# Xcode 26 asks for a legacy "Mac Development" certificate when a team is
# supplied on this project, even when a valid universal Apple Development
# identity exists. Build with Xcode's working ad-hoc path first, then replace
# that signature with the stable local identity while preserving Xcode's
# generated Debug entitlements. Stable signing keeps TCC grants across builds.
if [ -n "$SIGNING_IDENTITY" ]; then
  GENERATED_ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/heymate-entitlements.XXXXXX")
  codesign -d --entitlements :- "$APP_BUNDLE" > "$GENERATED_ENTITLEMENTS" 2>/dev/null
  codesign \
    --force \
    --deep \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$GENERATED_ENTITLEMENTS" \
    --timestamp=none \
    "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
  rm "$GENERATED_ENTITLEMENTS"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

find_built_app_pid() {
  local candidate_pid executable_path
  while IFS= read -r candidate_pid; do
    [ -n "$candidate_pid" ] || continue
    executable_path=$(ps -ww -p "$candidate_pid" -o comm= 2>/dev/null \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ "$executable_path" = "$APP_BINARY" ]; then
      printf '%s\n' "$candidate_pid"
      return 0
    fi
  done < <(pgrep -x "$APP_NAME" || true)
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    BUILT_APP_PID=""
    for _ in {1..10}; do
      if BUILT_APP_PID=$(find_built_app_pid); then
        break
      fi
      sleep 1
    done
    if [ -z "$BUILT_APP_PID" ]; then
      echo "$APP_NAME did not launch from $APP_BINARY" >&2
      exit 1
    fi

    # Catch immediate startup crashes instead of accepting one transient PID.
    for _ in {1..3}; do
      sleep 1
      CURRENT_EXECUTABLE=$(ps -ww -p "$BUILT_APP_PID" -o comm= 2>/dev/null \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ "$CURRENT_EXECUTABLE" != "$APP_BINARY" ]; then
        echo "$APP_NAME exited during startup verification" >&2
        exit 1
      fi
    done
    echo "$APP_NAME launched from $APP_BUNDLE and remained alive"
    ;;
esac
