#!/bin/bash
# Exercises production IPC with disposable workers. Never launches a GUI.
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/heymate-voice-process.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  HeyMate/SpeechRunnerProtocol.swift HeyMate/KokoroSpeechProcess.swift \
  script/voice_process_probe.swift -o "$probe_dir/probe"
"$probe_dir/probe"
