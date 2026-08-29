#!/usr/bin/env bash

# Process selection shared by build_and_run.sh and its regression tests.
# HeyMate's detached agent runner intentionally uses the same signed binary as
# the UI app, so matching only the executable name or path is not sufficient.

heymate_pgrep_by_name() {
  pgrep -x "$1" 2>/dev/null || true
}

heymate_process_executable() {
  ps -ww -p "$1" -o comm= 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

heymate_process_arguments() {
  ps -ww -p "$1" -o args= 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

heymate_arguments_are_detached_runner() {
  local arguments="${1:-}"
  case " $arguments " in
    *" --heymate-agent-runner "*) return 0 ;;
    *) return 1 ;;
  esac
}

heymate_is_ui_app_pid() {
  local candidate_pid="$1"
  local expected_executable="$2"
  local executable_path arguments

  [ -n "$candidate_pid" ] || return 1
  executable_path=$(heymate_process_executable "$candidate_pid")
  [ "$executable_path" = "$expected_executable" ] || return 1

  arguments=$(heymate_process_arguments "$candidate_pid")
  [ -n "$arguments" ] || return 1
  ! heymate_arguments_are_detached_runner "$arguments"
}

heymate_find_ui_app_pids() {
  local app_name="$1"
  local expected_executable="$2"
  local candidate_pid

  while IFS= read -r candidate_pid; do
    if heymate_is_ui_app_pid "$candidate_pid" "$expected_executable"; then
      printf '%s\n' "$candidate_pid"
    fi
  done < <(heymate_pgrep_by_name "$app_name")
}

heymate_find_first_ui_app_pid() {
  local app_name="$1"
  local expected_executable="$2"
  local candidate_pid

  while IFS= read -r candidate_pid; do
    if heymate_is_ui_app_pid "$candidate_pid" "$expected_executable"; then
      printf '%s\n' "$candidate_pid"
      return 0
    fi
  done < <(heymate_pgrep_by_name "$app_name")
  return 1
}

heymate_signal_process() {
  kill "$1" "$2"
}

heymate_stop_ui_app_processes() {
  local app_name="$1"
  local expected_executable="$2"
  local candidate_pid

  while IFS= read -r candidate_pid; do
    [ -n "$candidate_pid" ] || continue
    # Re-check immediately before signaling. This also closes a PID-reuse race
    # between discovery and delivery.
    if heymate_is_ui_app_pid "$candidate_pid" "$expected_executable"; then
      heymate_signal_process -TERM "$candidate_pid" 2>/dev/null || true
    fi
  done < <(heymate_find_ui_app_pids "$app_name" "$expected_executable")
}
