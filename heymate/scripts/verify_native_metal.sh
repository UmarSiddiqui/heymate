#!/usr/bin/env bash
# Compile and exercise production Metal code without installing or launching HeyMate.
set -euo pipefail
METAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METAL_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/heymate-metal.XXXXXX")"
trap 'rm -rf "$METAL_SCRATCH"' EXIT
node --test "$METAL_ROOT/scripts/stage3d_tests.mjs"
node "$METAL_ROOT/scripts/metal-check/fixture.mjs" "$METAL_SCRATCH/fixture.json"
swiftc -typecheck "$METAL_ROOT/HeyMate/DaVinciMetalRenderer.swift" "$METAL_ROOT/HeyMate/DaVinciMetalOverlay.swift"
swiftc -parse-as-library "$METAL_ROOT/HeyMate/DaVinciMetalRenderer.swift" \
  "$METAL_ROOT/scripts/metal-check/main.swift" -o "$METAL_SCRATCH/check"
MTL_DEBUG_LAYER=1 "$METAL_SCRATCH/check" "$METAL_ROOT" "$METAL_SCRATCH/fixture.json"
