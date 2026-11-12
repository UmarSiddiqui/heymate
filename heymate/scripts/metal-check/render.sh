#!/usr/bin/env bash
# Render the model fixtures with the app's Metal renderer, offscreen. Usage: render.sh <out-dir> [yaw-degrees]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:?out dir}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/heymate-render.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
node "$HERE/models.mjs" "$SCRATCH/payloads" "${2:-32}" 2>/dev/null
swiftc -parse-as-library "$ROOT/HeyMate/DaVinciMetalRenderer.swift" "$HERE/render.swift" -o "$SCRATCH/render"
"$SCRATCH/render" "$ROOT" "$OUT" "$SCRATCH"/payloads/*.json
