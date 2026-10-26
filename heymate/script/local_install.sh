#!/usr/bin/env bash

# Local installs keep the installed app's certificate and mutually compatible
# designated requirements. A matching path or bundle ID alone is insufficient.
# source code_signature_checks.sh before this file.

heymate_local_error() {
  printf 'HeyMate local install: %s\n' "$*" >&2
  return 1
}

heymate_local_requirement() {
  local requirement
  requirement=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p') || return 1
  [ -n "$requirement" ] || { heymate_local_error "No designated requirement for $1"; return 1; }
  printf '%s\n' "$requirement"
}

heymate_local_team() {
  codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | sed 's/^not set$//'
}

heymate_local_leaf_sha1() (
  certificate_dir=$(mktemp -d "${TMPDIR:-/tmp}/heymate-certificate.XXXXXX") || exit 1
  trap 'rm -rf "$certificate_dir"' EXIT
  codesign -d --extract-certificates="$certificate_dir/cert-" "$1" >/dev/null 2>&1 || exit 1
  [ -s "$certificate_dir/cert-0" ] || {
    heymate_local_error "$1 has no signing certificate. Ad-hoc builds cannot anchor local permissions."
    exit 1
  }
  shasum -a 1 "$certificate_dir/cert-0" | awk '{print toupper($1)}'
)

heymate_local_validate_bundle() {
  local bundle="$1"
  [ -d "$bundle" ] && [ ! -L "$bundle" ] \
    && [ -f "$bundle/Contents/Info.plist" ] && [ -x "$bundle/Contents/MacOS/HeyMate" ] || {
    heymate_local_error "Expected a real HeyMate app bundle at $bundle"; return 1;
  }
  codesign --verify --deep --strict "$bundle" || return 1
  [ "$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist")" = 'com.heymate.app' ] || {
    heymate_local_error "Unexpected bundle identifier at $bundle"; return 1;
  }
  [ "$(heymate_codesign_identifier "$bundle")" = 'com.heymate.app' ] || {
    heymate_local_error "Unexpected code-sign identifier at $bundle"; return 1;
  }
}

heymate_resolve_local_signing() {
  local installed="$1" listing candidates fingerprint name count=0 requested tab=$'\t'
  HEYMATE_LOCAL_SIGNER_SHA1=''
  HEYMATE_LOCAL_TEAM=''
  HEYMATE_LOCAL_REQUIREMENT=''
  HEYMATE_LOCAL_SIGNER_NAME=''
  HEYMATE_LOCAL_HAD_INSTALL=0
  requested="${HEYMATE_SIGNING_IDENTITY:-}"
  listing=$(security find-identity -v -p codesigning) || {
    heymate_local_error 'Cannot read code-signing identities. Unlock your login keychain and retry.'; return 1;
  }
  candidates=$(printf '%s\n' "$listing" \
    | sed -n "s/^[[:space:]]*[0-9]*) \\([A-Fa-f0-9]\\{40\\}\\) \"\\(.*\\)\"$/\\1${tab}\\2/p")

  if [ -e "$installed" ] || [ -L "$installed" ]; then
    heymate_local_validate_bundle "$installed" || return 1
    HEYMATE_LOCAL_HAD_INSTALL=1
    HEYMATE_LOCAL_SIGNER_SHA1=$(heymate_local_leaf_sha1 "$installed") || return 1
    HEYMATE_LOCAL_TEAM=$(heymate_local_team "$installed") || return 1
    HEYMATE_LOCAL_REQUIREMENT=$(heymate_local_requirement "$installed") || return 1
    if [ -n "${HEYMATE_DEVELOPMENT_TEAM:-}" ] \
      && [ "$HEYMATE_DEVELOPMENT_TEAM" != "$HEYMATE_LOCAL_TEAM" ]; then
      heymate_local_error 'Requested team differs from installed HeyMate. Refusing to change its privacy identity.'
      return 1
    fi
  fi

  while IFS=$'\t' read -r fingerprint name; do
    [ -n "$fingerprint" ] || continue
    fingerprint=$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]')
    if [ -n "$requested" ] && [ "$requested" != "$name" ] \
      && [ "$(printf '%s' "$requested" | tr '[:lower:]' '[:upper:]')" != "$fingerprint" ]; then
      continue
    fi
    if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 1 ]; then
      [ "$fingerprint" = "$HEYMATE_LOCAL_SIGNER_SHA1" ] || continue
    elif [ -z "$requested" ]; then
      # First install only: accept one unambiguous development identity.
      case "$name" in 'Apple Development: '*) ;; *) continue ;; esac
    fi
    if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 0 ] && [ -n "${HEYMATE_DEVELOPMENT_TEAM:-}" ]; then
      # The certificate name's final parentheses are not reliably the Team ID.
      # Check the actual signed build's TeamIdentifier before installing.
      HEYMATE_LOCAL_TEAM="$HEYMATE_DEVELOPMENT_TEAM"
    fi
    count=$((count + 1))
    HEYMATE_LOCAL_SIGNER_SHA1="$fingerprint"
    HEYMATE_LOCAL_SIGNER_NAME="$name"
  done <<< "$candidates"

  if [ "$count" -ne 1 ]; then
    heymate_local_error "Need exactly one valid private signing identity matching installed HeyMate (found $count). Restore/unlock its certificate and private key; never substitute ad-hoc signing. For a first install, set HEYMATE_SIGNING_IDENTITY to an explicit certificate SHA-1. A signer migration needs a separate intentional install and new macOS approvals."
    return 1
  fi
  printf 'Local signer: %s [%s]\nInstall path: %s\n' \
    "$HEYMATE_LOCAL_SIGNER_NAME" "$HEYMATE_LOCAL_SIGNER_SHA1" "$installed"
}

heymate_local_check_baseline() {
  local installed="$1"
  if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 0 ]; then
    [ ! -e "$installed" ] && [ ! -L "$installed" ] || {
      heymate_local_error 'HeyMate appeared during the build; retry against that installed identity.'; return 1;
    }
    return 0
  fi
  heymate_local_validate_bundle "$installed" || return 1
  [ "$(heymate_local_leaf_sha1 "$installed")" = "$HEYMATE_LOCAL_SIGNER_SHA1" ] \
    && [ "$(heymate_local_requirement "$installed")" = "$HEYMATE_LOCAL_REQUIREMENT" ] || {
    heymate_local_error 'Installed signing identity changed during the build. Nothing replaced.'; return 1;
  }
}

heymate_local_check_candidate() {
  local candidate="$1" installed="$2" candidate_requirement candidate_team
  heymate_local_validate_bundle "$candidate" || return 1
  [ "$(heymate_local_leaf_sha1 "$candidate")" = "$HEYMATE_LOCAL_SIGNER_SHA1" ] || {
    heymate_local_error 'Built app uses a different certificate. Installed app left untouched.'; return 1;
  }
  candidate_team=$(heymate_local_team "$candidate") || return 1
  if [ -n "$HEYMATE_LOCAL_TEAM" ] && [ "$candidate_team" != "$HEYMATE_LOCAL_TEAM" ]; then
    heymate_local_error 'Built app uses a different team. Installed app left untouched.'; return 1
  fi
  if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 1 ]; then
    heymate_local_check_baseline "$installed" || return 1
    candidate_requirement=$(heymate_local_requirement "$candidate") || return 1
    codesign --verify --strict -R="$HEYMATE_LOCAL_REQUIREMENT" "$candidate" \
      && codesign --verify --strict -R="$candidate_requirement" "$installed" || {
      heymate_local_error 'Designated requirements are incompatible. Refusing to invalidate privacy grants.'; return 1;
    }
  fi
}

# Caller stages and verifies the candidate, then quits only known GUI copies.
# Failed replacement or installed verification restores the untouched old bundle.
heymate_install_local_candidate() {
  local candidate="$1" installed="$2" backup="$3"
  heymate_local_check_candidate "$candidate" "$installed" || return 1
  [ ! -e "$backup" ] && [ ! -L "$backup" ] || {
    heymate_local_error "Backup already exists: $backup"; return 1;
  }
  mkdir -p "$(dirname "$backup")" || return 1
  if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 1 ]; then
    mv "$installed" "$backup" || return 1
  fi
  if ! mv "$candidate" "$installed"; then
    if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 1 ]; then mv "$backup" "$installed" || return 1; fi
    heymate_local_error 'Install failed; previous bundle restored.'; return 1
  fi
  if ! heymate_local_validate_bundle "$installed" \
    || [ "$(heymate_local_leaf_sha1 "$installed")" != "$HEYMATE_LOCAL_SIGNER_SHA1" ]; then
    mv "$installed" "$candidate" || return 1
    if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 1 ]; then mv "$backup" "$installed" || return 1; fi
    heymate_local_error 'Installed verification failed; previous bundle restored.'; return 1
  fi
  printf 'Installed: %s\n' "$installed"
  if [ "$HEYMATE_LOCAL_HAD_INSTALL" -eq 1 ]; then printf 'Previous app: %s\n' "$backup"; fi
}
