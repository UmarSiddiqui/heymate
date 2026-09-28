#!/usr/bin/env bash
# Writes Markdown release notes for the commits between the previous release
# tag and HEAD, grouped by Conventional Commit type.
#
# Usage: release-notes.sh <version> <previous-tag-or-empty> > notes.md
set -euo pipefail

VERSION="$1"
PREVIOUS_TAG="${2:-}"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-UmarSiddiqui/heymate}"

if [ -n "$PREVIOUS_TAG" ]; then
  RANGE="${PREVIOUS_TAG}..HEAD"
else
  RANGE="HEAD"
fi

features=()
fixes=()
other=()
while IFS=$'\t' read -r sha subject; do
  [ -z "$sha" ] && continue
  line="- ${subject} ([\`${sha}\`](${REPO_URL}/commit/${sha}))"
  case "$subject" in
    feat*) features+=("$line") ;;
    fix*) fixes+=("$line") ;;
    *) other+=("$line") ;;
  esac
done < <(git log --no-merges --format='%h%x09%s' "$RANGE")

echo "## Download"
echo
echo "**[HeyMate.dmg](${REPO_URL}/releases/download/v${VERSION}/HeyMate.dmg)**: open it and drag HeyMate into Applications."
echo
echo "This build is ad-hoc signed, not Developer ID-signed, so the first time you open it, Control-click HeyMate and choose **Open**. Requires macOS 14.2 or later (Apple silicon or Intel)."
echo

if [ ${#features[@]} -gt 0 ]; then
  echo "## New"
  printf '%s\n' "${features[@]}"
  echo
fi
if [ ${#fixes[@]} -gt 0 ]; then
  echo "## Fixed"
  printf '%s\n' "${fixes[@]}"
  echo
fi
if [ ${#other[@]} -gt 0 ]; then
  echo "## Other changes"
  printf '%s\n' "${other[@]}"
  echo
fi
if [ ${#features[@]} -eq 0 ] && [ ${#fixes[@]} -eq 0 ] && [ ${#other[@]} -eq 0 ]; then
  echo "Rebuild of the current source."
  echo
fi

if [ -n "$PREVIOUS_TAG" ]; then
  echo "**Full changelog:** ${REPO_URL}/compare/${PREVIOUS_TAG}...v${VERSION}"
fi
