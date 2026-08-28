#!/bin/bash
# Typechecks the app (and optionally the tests) without touching the real,
# signed HeyMate.app that Xcode manages.
#
# `xcodebuild` from the terminal against the project's own DerivedData
# re-signs that app bundle, which invalidates its TCC grants — screen
# recording, accessibility, the lot — and the app then has to ask for all of
# them again. This script still uses `xcodebuild`, because that is the only
# way to get Xcode's actual per-target build settings and Swift frontend
# invocations, but it points -derivedDataPath at a throwaway directory in
# /tmp and passes CODE_SIGNING_ALLOWED=NO / CODE_SIGNING_REQUIRED=NO, so it
# never writes to or signs the real app bundle. Verified: the real
# DerivedData's HeyMate.app mtime is untouched after running this.
#
# A hand-reconstructed `swiftc -typecheck` invocation was tried first and
# abandoned: even with every build setting matched flag-for-flag
# (SWIFT_DEFAULT_ACTOR_ISOLATION, SWIFT_APPROACHABLE_CONCURRENCY, the
# upcoming-feature list), it silently accepted code with a real main-actor
# isolation violation that a genuine Xcode build rejects — apparently
# because `-default-isolation MainActor` on a bare swiftc invocation doesn't
# reproduce however Xcode's build system actually threads that setting
# through cross-module isolation checking. Two real bugs
# (HeadlessAgentLauncher.presentablePlanText, then VoiceIntentClassifier's
# static helpers) reached a real Xcode test build while the old version of
# this script reported clean. `xcodebuild build[-for-testing]` against a
# scratch DerivedData path closes that gap by construction: it's the same
# per-target settings and the same frontend invocations Xcode itself uses,
# not a re-guess of them.
#
# Usage: scripts/typecheck.sh [--tests]
set -uo pipefail
cd "$(dirname "$0")/.."

DD="${TMPDIR:-/tmp}/heymate-typecheck-dd"

ACTION="build"
if [ "${1:-}" = "--tests" ]; then
  ACTION="build-for-testing"
fi

echo "▸ ${ACTION} (scratch DerivedData at $DD)"

OUTPUT=$(xcodebuild \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -destination 'platform=macOS' \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  "$ACTION" 2>&1)
STATUS=$?

echo "$OUTPUT" | grep -E "error:"

if [ "$STATUS" -eq 0 ]; then
  if [ "$ACTION" = "build-for-testing" ]; then
    echo "✓ app and tests typecheck"
  else
    echo "✓ app typechecks"
  fi
else
  if [ "$ACTION" = "build-for-testing" ]; then
    echo "✗ app or tests have errors"
  else
    echo "✗ app has errors"
  fi
fi

exit "$STATUS"
