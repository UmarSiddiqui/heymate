#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/heymate-dictation.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  HeyMate/DictationInserter.swift script/dictation_insertion_probe.swift \
  -o "$probe_dir/probe"
"$probe_dir/probe"
