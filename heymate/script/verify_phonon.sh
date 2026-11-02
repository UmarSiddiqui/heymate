#!/bin/bash
# Production speech code, canonical signed helper, isolated CLI profile. No GUI.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/heymate-phonon-probe.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 \
  HeyMate/PhononEngine.swift HeyMate/PhononTTSClient.swift \
  HeyMate/KokoroSpeechProcess.swift HeyMate/SpeechRunnerProtocol.swift \
  HeyMate/HeyMateDataDirectory.swift HeyMate/SpeechStylePreferences.swift \
  HeyMate/SpeechText.swift HeyMate/MacOSSpeechSynthesizerClient.swift \
  HeyMate/SpeechVoiceCatalog.swift HeyMate/ProviderProtocols.swift \
  script/phonon_probe.swift -o "$scratch/probe"
HEYMATE_TEST_DATA_ROOT="$scratch/profile" "$scratch/probe"
