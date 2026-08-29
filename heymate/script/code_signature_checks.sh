#!/usr/bin/env bash

# Shared signature checks for local builds, archives, and exported releases.

heymate_codesign_identifier() {
  codesign -dvv "$1" 2>&1 \
    | sed -n 's/^Identifier=//p' \
    | head -1
}

heymate_require_hardened_runtime() {
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

heymate_reject_app_only_nested_entitlements() {
  local code_path="$1"
  local entitlements
  entitlements=$(codesign -d --entitlements - "$code_path" 2>/dev/null || true)

  if printf '%s\n' "$entitlements" | grep -Eq \
    'com\.apple\.security\.device\.(camera|audio-input)|com\.apple\.security\.temporary-exception\.mach-lookup\.global-name|com\.apple\.screencapturekit\.picker'; then
    echo "App-only entitlements leaked into nested code at $code_path" >&2
    return 1
  fi
}

heymate_reject_get_task_allow() {
  local code_path="$1"
  local entitlements
  entitlements=$(codesign -d --entitlements - "$code_path" 2>/dev/null || true)
  if printf '%s\n' "$entitlements" \
    | grep -q 'com.apple.security.get-task-allow'; then
    echo "Release helper contains get-task-allow at $code_path" >&2
    return 1
  fi
}

heymate_verify_embedded_agent_runner() {
  local app_bundle="$1"
  local verification_mode="${2:-debug}"
  local app_binary="$app_bundle/Contents/MacOS/HeyMate"
  local runner_binary="$app_bundle/Contents/Helpers/HeyMateAgentRunner"
  local app_identifier runner_identifier

  if [ ! -f "$runner_binary" ] || [ ! -x "$runner_binary" ] || [ -L "$runner_binary" ]; then
    echo "Signed embedded runner missing or unsafe at $runner_binary" >&2
    return 1
  fi
  codesign --verify --strict --verbose=2 "$runner_binary" || return 1
  heymate_require_hardened_runtime "$runner_binary" || return 1
  heymate_reject_app_only_nested_entitlements "$runner_binary" || return 1

  app_identifier=$(heymate_codesign_identifier "$app_binary")
  runner_identifier=$(heymate_codesign_identifier "$runner_binary")
  if [ "$app_identifier" != "com.heymate.app" ]; then
    echo "Unexpected HeyMate code-sign identifier: $app_identifier" >&2
    return 1
  fi
  if [ "$runner_identifier" != "com.heymate.app.agent-runner" ]; then
    echo "Unexpected agent-runner code-sign identifier: $runner_identifier" >&2
    return 1
  fi
  if [ "$runner_identifier" = "$app_identifier" ]; then
    echo "Agent runner shares app code-sign identity" >&2
    return 1
  fi

  if [ "$verification_mode" = "release" ]; then
    heymate_reject_get_task_allow "$runner_binary" || return 1
  fi
}
