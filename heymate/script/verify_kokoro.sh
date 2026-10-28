#!/bin/bash
# Cached-model integration probe. Runs a CLI, never a second HeyMate GUI.
# First build/install through script/build_and_run.sh --verify.
set -euo pipefail
cd "$(dirname "$0")/.."
derived="${HEYMATE_PROBE_DERIVED_DATA:-$PWD/build/DerivedData}"
products="$derived/Build/Products/Debug"
fluid="$derived/SourcePackages/checkouts/FluidAudio"
nemo="$derived/SourcePackages/artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64/libtext_processing_rs.a"
if [[ ! -f "$products/FluidAudio.o" ]]; then
  echo 'Build dependencies first with script/build_and_run.sh --verify.' >&2
  exit 1
fi
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/heymate-kokoro-probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -profile-generate \
  -I "$products" \
  -I "$fluid/Sources/FastClusterWrapper/include" \
  -I "$fluid/Sources/MachTaskSelfWrapper/include" \
  -I "$products/include" \
  HeyMate/OnDeviceVoiceModels.swift HeyMate/SpeechStylePreferences.swift HeyMate/SpeechText.swift \
  script/kokoro_probe.swift "$products/FluidAudio.o" "$products/FastClusterWrapper.o" \
  "$products/MachTaskSelfWrapper.o" "$nemo" \
  -lc++ -framework Accelerate -framework CoreML -o "$probe_dir/kokoro-probe"
LLVM_PROFILE_FILE="$probe_dir/coverage.profraw" "$probe_dir/kokoro-probe"
