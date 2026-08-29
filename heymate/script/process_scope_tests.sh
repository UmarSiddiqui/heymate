#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=process_scope.sh
source "$SCRIPT_DIR/process_scope.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

heymate_pgrep_by_name() {
  printf '%s\n' 101 102 103 104
}

heymate_process_executable() {
  case "$1" in
    101|102|104) printf '%s\n' '/tmp/HeyMate.app/Contents/MacOS/HeyMate' ;;
    103) printf '%s\n' '/Applications/HeyMate.app/Contents/MacOS/HeyMate' ;;
  esac
}

heymate_process_arguments() {
  case "$1" in
    101) printf '%s\n' '/tmp/HeyMate.app/Contents/MacOS/HeyMate' ;;
    102) printf '%s\n' '/tmp/HeyMate.app/Contents/MacOS/HeyMate --heymate-agent-runner run attempt 3' ;;
    103) printf '%s\n' '/Applications/HeyMate.app/Contents/MacOS/HeyMate' ;;
    104) printf '%s\n' '/tmp/HeyMate.app/Contents/MacOS/HeyMate --prompt=--heymate-agent-runner' ;;
  esac
}

expected_ui_pids=$'101\n104'
actual_ui_pids=$(heymate_find_ui_app_pids HeyMate '/tmp/HeyMate.app/Contents/MacOS/HeyMate')
[ "$actual_ui_pids" = "$expected_ui_pids" ] \
  || fail "UI PID selection included runner or wrong bundle: $actual_ui_pids"

first_ui_pid=$(heymate_find_first_ui_app_pid HeyMate '/tmp/HeyMate.app/Contents/MacOS/HeyMate')
[ "$first_ui_pid" = '101' ] || fail "first UI PID was $first_ui_pid"

signaled_pids=""
heymate_signal_process() {
  [ "$1" = '-TERM' ] || fail "unexpected signal $1"
  signaled_pids="${signaled_pids}${signaled_pids:+ }$2"
}

heymate_stop_ui_app_processes HeyMate '/tmp/HeyMate.app/Contents/MacOS/HeyMate'
[ "$signaled_pids" = '101 104' ] \
  || fail "stop targeted wrong PIDs: $signaled_pids"

heymate_arguments_are_detached_runner \
  '/tmp/HeyMate --heymate-agent-runner run attempt 3' \
  || fail 'runner flag was not detected'

if heymate_arguments_are_detached_runner \
  '/tmp/HeyMate --prompt=--heymate-agent-runner'; then
  fail 'substring was mistaken for runner flag'
fi

echo 'process scope tests passed'
