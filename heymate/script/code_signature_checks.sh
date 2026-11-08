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

# Release builds must be signed by HeyMate's Developer ID Application
# certificate. This requirement is what keeps TCC grants across updates, so a
# different signer must fail the release rather than reach users.
heymate_require_developer_id() {
  local code_path="$1" team_id="$2"
  local requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$team_id\""
  if ! codesign --verify --strict -R="$requirement" "$code_path"; then
    echo "$code_path is not signed with a Developer ID Application certificate for team $team_id" >&2
    codesign -dr - "$code_path" >&2 || true
    return 1
  fi
}

# Notarization rejects any Mach-O without a secure timestamp, and any
# executable without the hardened runtime. Checking up front gives a clear
# list instead of a rejected submission.
heymate_require_notarizable_bundle() {
  local bundle="$1"
  local failures=0 file kind details
  while IFS= read -r -d '' file; do
    kind=$(file -b "$file")
    case "$kind" in *Mach-O*) ;; *) continue ;; esac
    if ! details=$(codesign -dvv "$file" 2>&1); then
      echo "Unsigned Mach-O: $file" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! printf '%s\n' "$details" | grep -q '^Timestamp='; then
      echo "No secure timestamp: $file" >&2
      failures=$((failures + 1))
    fi
    case "$kind" in
      *executable*)
        if ! printf '%s\n' "$details" | grep -q 'flags=.*runtime'; then
          echo "Hardened runtime missing: $file" >&2
          failures=$((failures + 1))
        fi
        ;;
    esac
  done < <(find "$bundle" -type f -print0)
  if [ "$failures" -gt 0 ]; then
    echo "$failures nested signature problem(s) would fail notarization" >&2
    return 1
  fi
}

# get-task-allow lets other processes attach a debugger and run code with
# HeyMate's privacy grants. Development builds need it; releases never do.
heymate_reject_debug_entitlements_in_bundle() {
  local bundle="$1"
  local failures=0 file
  while IFS= read -r -d '' file; do
    case "$(file -b "$file")" in *Mach-O*) ;; *) continue ;; esac
    # plutil -extract reads the dots in the key as a path, so match the XML.
    if codesign -d --entitlements - --xml "$file" 2>/dev/null | tr -d ' \t\n' \
        | grep -q '<key>com.apple.security.get-task-allow</key><true/>'; then
      echo "get-task-allow is set: $file" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$bundle" -type f -print0)
  [ "$failures" -eq 0 ]
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
