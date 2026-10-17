#!/bin/bash
# Build an unsigned-for-distribution local Hermes candidate; never publishes or installs.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${HEYMATE_HERMES_RUNTIME:?Set HEYMATE_HERMES_RUNTIME to the prepared sealed Hermes payload}"
CANDIDATE_ROOT="${HEYMATE_CANDIDATE_ROOT:-/private/tmp/heymate-hermes-candidate}"
CANDIDATE_ARCHS="${HEYMATE_CANDIDATE_ARCHS:-arm64}"
CANDIDATE_BUNDLE_ID="${HEYMATE_CANDIDATE_BUNDLE_ID:-com.heymate.HermesCandidate}"
CANDIDATE_VERSION="${HEYMATE_CANDIDATE_VERSION:-1.0.65}"
CANDIDATE_BUILD="${HEYMATE_CANDIDATE_BUILD:-65}"
SOURCE_DIGEST="$(/usr/bin/python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
paths = sorted(p for p in (root / "HeyMate").rglob("*") if p.is_file() and p.name != ".DS_Store")
paths.append(root / "HeyMate.xcodeproj/project.pbxproj")
digest = hashlib.sha256()
for path in paths:
    digest.update(str(path.relative_to(root)).encode() + b"\0")
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
)"
PACKAGE_OPTIONS=()
if [[ -n "${HEYMATE_SOURCE_PACKAGES:-}" ]]; then
  PACKAGE_OPTIONS=(-clonedSourcePackagesDirPath "$HEYMATE_SOURCE_PACKAGES")
fi
mkdir -p "$CANDIDATE_ROOT"
ARCHS="$CANDIDATE_ARCHS" /usr/bin/python3 "$PROJECT_DIR/scripts/hermes-runtime-stage.py" \
  --source "$HEYMATE_HERMES_RUNTIME" --destination "$CANDIDATE_ROOT/verify/Hermes" --verify-only
xcodebuild -project "$PROJECT_DIR/HeyMate.xcodeproj" -scheme HeyMate \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$CANDIDATE_ROOT/DerivedData" "${PACKAGE_OPTIONS[@]}" -jobs 4 \
  ARCHS="$CANDIDATE_ARCHS" ONLY_ACTIVE_ARCH=NO ENABLE_CODE_COVERAGE=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  HEYMATE_APP_BUNDLE_IDENTIFIER="$CANDIDATE_BUNDLE_ID" SPARKLE_FEED_URL= SPARKLE_PUBLIC_ED_KEY= \
  MARKETING_VERSION="$CANDIDATE_VERSION" CURRENT_PROJECT_VERSION="$CANDIDATE_BUILD" \
  HEYMATE_BUILD_SOURCE_SHA256="$SOURCE_DIGEST" HEYMATE_BUILD_KIND=local-integrated \
  build > "$CANDIDATE_ROOT/build.log" 2>&1
APP="$CANDIDATE_ROOT/DerivedData/Build/Products/Release/HeyMate.app"
codesign --verify --deep --strict "$APP"
ARCHS="$CANDIDATE_ARCHS" /usr/bin/python3 "$PROJECT_DIR/scripts/hermes-runtime-stage.py" \
  --source "$APP/Contents/Resources/Hermes" --destination "$CANDIDATE_ROOT/verify/Hermes" --verify-only
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$CANDIDATE_ROOT/HeyMate.zip"
printf 'Local candidate: %s\nAd-hoc signature verified. Not published, installed, or notarized.\n' "$APP"
printf 'Source SHA256: %s\n' "$SOURCE_DIGEST"
