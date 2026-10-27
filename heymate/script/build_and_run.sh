#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HeyMate"
BUNDLE_ID="com.heymate.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALL_BUNDLE="/Applications/$APP_NAME.app"
INSTALL_BINARY="$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--check|check) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--check]" >&2
    exit 2
    ;;
esac

# shellcheck source=process_scope.sh
source "$ROOT_DIR/script/process_scope.sh"
# shellcheck source=code_signature_checks.sh
source "$ROOT_DIR/script/code_signature_checks.sh"
# shellcheck source=local_install.sh
source "$ROOT_DIR/script/local_install.sh"

heymate_resolve_local_signing "$INSTALL_BUNDLE"

# Every checkout installs to the same /Applications/HeyMate.app, so the last
# install wins. A branch that lacks main's commits silently drops shipped work
# (another session's notch or harness changes) from the app you use.
if [ "${HEYMATE_ALLOW_STALE_INSTALL:-0}" != 1 ] \
  && git -C "$ROOT_DIR" rev-parse --verify -q origin/main >/dev/null \
  && ! git -C "$ROOT_DIR" merge-base --is-ancestor origin/main HEAD; then
  heymate_local_error "This checkout ($(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)) is missing $(git -C "$ROOT_DIR" rev-list --count HEAD..origin/main) commits from origin/main. Merge main first so the installed app keeps everyone's work, or set HEYMATE_ALLOW_STALE_INSTALL=1."
  exit 1
fi
if [ "$MODE" = '--check' ] || [ "$MODE" = 'check' ]; then
  echo 'Signing preflight passed. No build, install, quit, launch, or privacy changes.'
  exit 0
fi

# One lock across worktrees. Build and stage before asking the running app to
# quit; a failed build/signature check must not interrupt the user's session.
INSTALL_LOCK='/Applications/.heymate-local-install.lock'
if ! mkdir "$INSTALL_LOCK" 2>/dev/null; then
  heymate_local_error "Cannot acquire $INSTALL_LOCK. Check for another local build or /Applications write access. Never use sudo to build."
  exit 1
fi
STAGE_DIR=''
cleanup_local_install() {
  if [ -n "$STAGE_DIR" ]; then rm -rf "$STAGE_DIR"; fi
  rm -f "$INSTALL_LOCK/pid"
  rmdir "$INSTALL_LOCK"
}
trap cleanup_local_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$INSTALL_LOCK/pid"

# Xcode signs its own outputs; never recursively re-sign embedded code.
XCODE_SIGNING_ARGUMENTS=(
  CODE_SIGN_STYLE=Manual
  "CODE_SIGN_IDENTITY=$HEYMATE_LOCAL_SIGNER_SHA1"
  "DEVELOPMENT_TEAM=$HEYMATE_LOCAL_TEAM"
  PROVISIONING_PROFILE_SPECIFIER=
  "HEYMATE_APP_BUNDLE_IDENTIFIER=$BUNDLE_ID"
)

run_xcodebuild() {
  xcodebuild \
    -project "$ROOT_DIR/HeyMate.xcodeproj" \
    -scheme HeyMate \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    "${XCODE_SIGNING_ARGUMENTS[@]}" \
    ENABLE_CODE_COVERAGE=NO \
    -quiet \
    "$@"
}

# Stage the Pi harness from this checkout. Without it the app keeps whatever
# harness payload an earlier build left in DerivedData.
if [ -z "${HEYMATE_PI_RUNTIME:-}" ]; then
  HEYMATE_PI_RUNTIME="$ROOT_DIR/build/MateAgent"
  rm -rf "$HEYMATE_PI_RUNTIME"
  python3 "$ROOT_DIR/scripts/pi-runtime-build.py" --out "$HEYMATE_PI_RUNTIME"
fi
export HEYMATE_PI_RUNTIME

run_xcodebuild build

verify_debug_signatures() {
  local nested_code_count=0
  local code_path

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || return 1
  heymate_require_hardened_runtime "$APP_BUNDLE" || return 1
  heymate_verify_embedded_agent_runner "$APP_BUNDLE" debug || return 1

  # Inspect each signed executable independently. Deep verification proves the
  # seals are intact; these checks also catch valid-but-wrong recursive signing
  # that copied app entitlements or dropped hardened-runtime flags.
  while IFS= read -r -d '' code_path; do
    [ "$code_path" = "$APP_BINARY" ] && continue
    if codesign -d "$code_path" >/dev/null 2>&1; then
      nested_code_count=$((nested_code_count + 1))
      heymate_require_hardened_runtime "$code_path" || return 1
      heymate_reject_app_only_nested_entitlements "$code_path" || return 1
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

heymate_local_check_candidate "$APP_BUNDLE" "$INSTALL_BUNDLE"
STAGE_DIR=$(mktemp -d '/Applications/.heymate-stage.XXXXXX')
STAGED_BUNDLE="$STAGE_DIR/HeyMate.app"
ditto "$APP_BUNDLE" "$STAGED_BUNDLE"
heymate_local_check_candidate "$STAGED_BUNDLE" "$INSTALL_BUNDLE"

require_known_ui_apps() {
  local pid executable arguments
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    arguments=$(heymate_process_arguments "$pid")
    [ -n "$arguments" ] || continue
    if heymate_arguments_are_detached_runner "$arguments"; then continue; fi
    executable=$(heymate_process_executable "$pid")
    case "$executable" in
      "$APP_BINARY"|"$INSTALL_BINARY"|'') ;;
      *) heymate_local_error "Another HeyMate copy is running at $executable (PID $pid). Quit it before installing."; return 1 ;;
    esac
  done < <(heymate_pgrep_by_name "$APP_NAME")
}

quit_known_ui_apps() {
  local bundle executable pid attempts
  require_known_ui_apps || return 1
  for bundle in "$INSTALL_BUNDLE" "$APP_BUNDLE"; do
    executable="$bundle/Contents/MacOS/$APP_NAME"
    if heymate_find_first_ui_app_pid "$APP_NAME" "$executable" >/dev/null; then
      # Normal application quit runs termination/save hooks. If it is refused,
      # abort rather than force-kill the UI or its detached agent runners.
      /usr/bin/osascript - "$bundle" <<'APPLESCRIPT' || return 1
on run argv
  tell application (item 1 of argv) to quit
end run
APPLESCRIPT
    fi
    for attempts in {1..15}; do
      if ! heymate_find_first_ui_app_pid "$APP_NAME" "$executable" >/dev/null; then break; fi
      sleep 1
    done
    if pid=$(heymate_find_first_ui_app_pid "$APP_NAME" "$executable"); then
      heymate_local_error "HeyMate did not quit (PID $pid). Finish pending work and quit it; installed app left untouched."
      return 1
    fi
  done
  require_known_ui_apps
}

quit_known_ui_apps
BACKUP_ROOT="$HOME/Library/Application Support/HeyMate Install Backups"
BACKUP_BUNDLE="$BACKUP_ROOT/$(date +%Y-%m-%d-%H%M%S)-$$/HeyMate.app"
heymate_install_local_candidate "$STAGED_BUNDLE" "$INSTALL_BUNDLE" "$BACKUP_BUNDLE"

# One HeyMate on this Mac: keep at most the rollback copy from this install,
# and stop LaunchServices offering the build-products copy as a second app.
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -path "$(dirname "$BACKUP_BUNDLE")" -exec rm -rf {} +
# Keep Spotlight from listing the build-products copy as a second HeyMate.
touch "$ROOT_DIR/build/.metadata_never_index"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$(dirname "$BACKUP_BUNDLE")/HeyMate.app" >/dev/null 2>&1 || true

open_app() {
  # Reuse the canonical instance; never create an extra DerivedData instance.
  /usr/bin/open "$INSTALL_BUNDLE"
}

find_built_app_pid() {
  heymate_find_first_ui_app_pid "$APP_NAME" "$INSTALL_BINARY"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALL_BINARY"
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
      echo "$APP_NAME did not launch from $INSTALL_BINARY" >&2
      exit 1
    fi

    # Catch immediate startup crashes instead of accepting one transient PID.
    for _ in {1..3}; do
      sleep 1
      CURRENT_EXECUTABLE=$(ps -ww -p "$BUILT_APP_PID" -o comm= 2>/dev/null \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ "$CURRENT_EXECUTABLE" != "$INSTALL_BINARY" ]; then
        echo "$APP_NAME exited during startup verification" >&2
        exit 1
      fi
    done
    require_known_ui_apps
    INSTANCE_COUNT=$(heymate_find_ui_app_pids "$APP_NAME" "$INSTALL_BINARY" | awk 'END {print NR}')
    [ "$INSTANCE_COUNT" -eq 1 ] || { heymate_local_error "Expected one installed UI instance; found $INSTANCE_COUNT"; exit 1; }
    echo "$APP_NAME launched from $INSTALL_BUNDLE and remained alive (PID $BUILT_APP_PID)"
    # Verified: the rollback copy is no longer needed.
    rm -rf "$(dirname "$BACKUP_BUNDLE")"
    ;;
esac
