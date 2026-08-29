#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HeyMate"
BUNDLE_ID="com.heymate.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# shellcheck source=process_scope.sh
source "$ROOT_DIR/script/process_scope.sh"

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

XCODE_SIGNING_ARGUMENTS=()
if [ -n "$SIGNING_IDENTITY" ]; then
  # Supplying the exact identity with manual style avoids Xcode's legacy
  # "Mac Development" certificate lookup without repairing the bundle after
  # the build. Xcode signs HeyMate-owned code itself and leaves embedded
  # Sparkle code with Sparkle's own entitlements and hardened-runtime flags.
  XCODE_SIGNING_ARGUMENTS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
  )
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

# Detached coding-agent runners use this same executable. Stop only GUI
# instances from this build; name-only pkill would destroy background work.
heymate_stop_ui_app_processes "$APP_NAME" "$APP_BINARY"

run_xcodebuild() {
  xcodebuild \
    -project "$ROOT_DIR/leanring-buddy.xcodeproj" \
    -scheme leanring-buddy \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${XCODE_SIGNING_ARGUMENTS[@]}" \
    -quiet \
    "$@"
}

run_xcodebuild build

require_hardened_runtime() {
  local code_path="$1"
  local signing_details
  if ! signing_details=$(codesign -dvv "$code_path" 2>&1); then
    echo "Could not read code signature for $code_path" >&2
    return 1
  fi
  if ! printf '%s\n' "$signing_details" | grep -q 'flags=.*runtime'; then
    echo "Hardened runtime is missing from $code_path" >&2
    return 1
  fi
}

reject_app_only_nested_entitlements() {
  local code_path="$1"
  local entitlements
  entitlements=$(codesign -d --entitlements - "$code_path" 2>/dev/null || true)

  # Camera, microphone, and ScreenCaptureKit picker access belong only to the
  # UI app. Finding any of them on nested code means an outer-app entitlement
  # set was recursively applied with `codesign --deep`.
  if printf '%s\n' "$entitlements" | grep -Eq \
    'com\.apple\.security\.device\.(camera|audio-input)|com\.apple\.security\.temporary-exception\.mach-lookup\.global-name'; then
    echo "App-only entitlements leaked into nested code at $code_path" >&2
    return 1
  fi
}

verify_debug_signatures() {
  local nested_code_count=0
  local code_path

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || return 1
  require_hardened_runtime "$APP_BUNDLE" || return 1

  # Inspect each signed executable independently. Deep verification proves the
  # seals are intact; these checks also catch valid-but-wrong recursive signing
  # that copied app entitlements or dropped hardened-runtime flags.
  while IFS= read -r -d '' code_path; do
    [ "$code_path" = "$APP_BINARY" ] && continue
    if codesign -d "$code_path" >/dev/null 2>&1; then
      nested_code_count=$((nested_code_count + 1))
      require_hardened_runtime "$code_path" || return 1
      reject_app_only_nested_entitlements "$code_path" || return 1
    fi
  done < <(find "$APP_BUNDLE/Contents" -type f -perm -111 -print0)

  if [ "$nested_code_count" -eq 0 ]; then
    echo "No nested signed executables found in $APP_BUNDLE" >&2
    return 1
  fi
  echo "Verified app and $nested_code_count nested code signatures"
}

if ! verify_debug_signatures; then
  # Older versions of this script recursively re-signed the built app. Xcode's
  # incremental build considers those now-corrupted nested files up to date, so
  # one clean rebuild is required to restore the package-authored signatures.
  echo "Signature invariants failed; cleaning stale build products and rebuilding."
  run_xcodebuild clean
  run_xcodebuild build
  verify_debug_signatures
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

find_built_app_pid() {
  heymate_find_first_ui_app_pid "$APP_NAME" "$APP_BINARY"
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
