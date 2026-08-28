#!/bin/bash
set -euo pipefail

# Add Homebrew to PATH so create-dmg and gh are available in non-interactive shells
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh — Automates the full release pipeline for HeyMate
#
# What it does (in order):
#   1. Validates explicit version + monotonic build metadata
#   2. Archives the app via xcodebuild
#   3. Exports a Developer ID-signed .app
#   4. Wraps it in a DMG with the drag-to-Applications background
#   5. Developer-ID-signs, notarizes, staples, and Gatekeeper-checks the DMG
#   6. Signs the DMG with your Sparkle EdDSA key
#   7. Generates/updates appcast.xml automatically
#   8. Creates a GitHub Release with the DMG and appcast attached
#
# Usage:
#   ./scripts/release.sh 2.0 10       Explicit marketing version + monotonic build
#
# Prerequisites (one-time setup):
#   - Xcode with your Developer ID signing certificate
#   - `brew install create-dmg gh`
#   - `gh auth login` (GitHub CLI authenticated)
#   - Sparkle EdDSA key in your Keychain (already generated)
#   - `xcrun notarytool store-credentials "AC_PASSWORD"` (Apple notarization credentials)
#   - Permanent public repository + Sparkle public key committed in ReleaseChannel.plist
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

SCHEME="leanring-buddy"
APP_NAME="HeyMate"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_OUTPUT_DIR="${BUILD_DIR}/dmg"
RELEASES_DIR="${PROJECT_DIR}/releases"  # where generate_appcast reads DMGs from
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
RELEASE_CHANNEL_CONFIG="${PROJECT_DIR}/ReleaseChannel.plist"

# Release counts are not build numbers: API pagination, drafts, or deletion can
# make them repeat. Require both values; later we also compare the build against
# metadata written into every release this script creates.
if [ "$#" -ne 2 ]; then
    echo "Usage: ./scripts/release.sh <marketing-version> <monotonic-build-number>" >&2
    echo "Example: ./scripts/release.sh 2.0 10" >&2
    exit 1
fi

MARKETING_VERSION="$1"
BUILD_NUMBER="$2"
if [[ ! "${MARKETING_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Marketing version must look like 2.0 or 2.0.1." >&2
    exit 1
fi
if [[ ! "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build number must be a positive integer." >&2
    exit 1
fi

normalize_marketing_version() {
    local version="${1#v}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "${version}"
    printf '%d.%d.%d\n' \
        "$((10#${major}))" \
        "$((10#${minor}))" \
        "$((10#${patch:-0}))"
}

marketing_version_is_greater() {
    awk -v candidate="$1" -v previous="$2" 'BEGIN {
        split(candidate, candidate_parts, ".")
        split(previous, previous_parts, ".")
        for (index = 1; index <= 3; index++) {
            if (candidate_parts[index] > previous_parts[index]) exit 0
            if (candidate_parts[index] < previous_parts[index]) exit 1
        }
        exit 1
    }'
}

if [ ! -f "${RELEASE_CHANNEL_CONFIG}" ]; then
    echo "ReleaseChannel.plist is missing." >&2
    exit 1
fi
GITHUB_REPO=$(/usr/libexec/PlistBuddy -c 'Print :Repository' "${RELEASE_CHANNEL_CONFIG}")
PINNED_SPARKLE_PUBLIC_ED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :PublicEDKey' "${RELEASE_CHANNEL_CONFIG}")
GITHUB_REPO=$(printf '%s' "${GITHUB_REPO}" | tr -d '[:space:]')
PINNED_SPARKLE_PUBLIC_ED_KEY=$(printf '%s' "${PINNED_SPARKLE_PUBLIC_ED_KEY}" | tr -d '[:space:]')

if [[ ! "${GITHUB_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Pin the permanent public owner/repository in ReleaseChannel.plist." >&2
    exit 1
fi
if ! PINNED_PUBLIC_KEY_BYTE_COUNT=$(printf '%s' "${PINNED_SPARKLE_PUBLIC_ED_KEY}" \
    | /usr/bin/base64 -D 2>/dev/null \
    | wc -c \
    | tr -d '[:space:]'); then
    PINNED_PUBLIC_KEY_BYTE_COUNT=0
fi
if [ "${PINNED_PUBLIC_KEY_BYTE_COUNT}" != "32" ]; then
    echo "Pin a valid 32-byte Sparkle Ed25519 public key in ReleaseChannel.plist." >&2
    exit 1
fi

if ! RELEASE_REPOSITORY_VISIBILITY=$(gh api \
    "repos/${GITHUB_REPO}" \
    --jq '.visibility'); then
    echo "Could not verify the configured release repository." >&2
    exit 1
fi
if [ "${RELEASE_REPOSITORY_VISIBILITY}" != "public" ]; then
    echo "Sparkle updates require anonymous release assets from an approved public repository." >&2
    echo "The configured release repository is not public; stopping before any build or upload." >&2
    exit 1
fi

if ! SOURCE_REPO_ROOT=$(git -C "${PROJECT_DIR}" rev-parse --show-toplevel 2>/dev/null); then
    echo "Release source is not inside a Git repository." >&2
    exit 1
fi
if [ -n "$(git -C "${SOURCE_REPO_ROOT}" status --porcelain --untracked-files=normal)" ]; then
    echo "Release source has tracked or untracked changes. Commit a reviewed clean tree first." >&2
    exit 1
fi
SOURCE_SHA=$(git -C "${SOURCE_REPO_ROOT}" rev-parse HEAD)
if ! REMOTE_SOURCE_SHA=$(gh api \
    "repos/${GITHUB_REPO}/commits/${SOURCE_SHA}" \
    --jq '.sha'); then
    echo "Current source commit is not present in the approved release repository." >&2
    echo "Push the reviewed commit before creating its release artifacts." >&2
    exit 1
fi
if [ "${REMOTE_SOURCE_SHA}" != "${SOURCE_SHA}" ]; then
    echo "GitHub returned a different source commit; refusing release." >&2
    exit 1
fi

# Each GitHub release carries both the DMG and its appcast. The stable `latest`
# URL avoids hard-coding an owner, repository, branch, or hosting account in
# the project while still giving every archived app a durable feed endpoint.
SPARKLE_FEED_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
SPARKLE_KEY_ACCOUNT="${HEYMATE_SPARKLE_KEY_ACCOUNT:-ed25519}"

# Public archives require a Developer ID Application certificate. Keep team
# and certificate local: detect them from Keychain or accept explicit values,
# but never check personal signing identifiers into the project.
DEVELOPMENT_TEAM="${HEYMATE_DEVELOPMENT_TEAM:-}"
RELEASE_SIGNING_IDENTITY="${HEYMATE_RELEASE_SIGNING_IDENTITY:-}"
IDENTITY_LISTING=$(security find-identity -v -p codesigning 2>/dev/null || true)
MATCHING_IDENTITIES=$(printf '%s\n' "$IDENTITY_LISTING" \
    | grep '"Developer ID Application:' || true)
if [ -n "$DEVELOPMENT_TEAM" ]; then
    MATCHING_IDENTITIES=$(printf '%s\n' "$MATCHING_IDENTITIES" \
        | grep -F "(${DEVELOPMENT_TEAM})\"" || true)
fi
if [ -n "$RELEASE_SIGNING_IDENTITY" ]; then
    if [[ "$RELEASE_SIGNING_IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]; then
        MATCHING_IDENTITIES=$(printf '%s\n' "$MATCHING_IDENTITIES" \
            | grep -i " ${RELEASE_SIGNING_IDENTITY} " || true)
    else
        MATCHING_IDENTITIES=$(printf '%s\n' "$MATCHING_IDENTITIES" \
            | grep -F "\"${RELEASE_SIGNING_IDENTITY}\"" || true)
    fi
fi
DEVELOPER_ID_LINE=$(printf '%s\n' "$MATCHING_IDENTITIES" | sed -n '1p')

if [ -z "$DEVELOPER_ID_LINE" ]; then
    echo "No installed Developer ID Application certificate matches the requested team/identity." >&2
    exit 1
fi

MATCHED_DEVELOPMENT_TEAM=$(printf '%s\n' "$DEVELOPER_ID_LINE" \
    | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p')
MATCHED_SIGNING_HASH=$(printf '%s\n' "$DEVELOPER_ID_LINE" \
    | sed -n 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) .*/\1/p')
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$MATCHED_DEVELOPMENT_TEAM}"
RELEASE_SIGNING_IDENTITY="${RELEASE_SIGNING_IDENTITY:-$MATCHED_SIGNING_HASH}"

if [ -z "$DEVELOPMENT_TEAM" ] || [ -z "$RELEASE_SIGNING_IDENTITY" ]; then
    echo "Could not derive one matching release team and signing identity." >&2
    exit 1
fi

# Sparkle tools (auto-discovered from Xcode's SPM cache)
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle tools not found. Build the project in Xcode first so SPM downloads Sparkle."
    exit 1
fi

# Read only the public half of the same Keychain key that sign_update and
# generate_appcast use below. Never export the private key into the repository
# or build directory.
if ! SPARKLE_PUBLIC_ED_KEY=$("${SPARKLE_BIN}/generate_keys" \
    --account "${SPARKLE_KEY_ACCOUNT}" \
    -p); then
    echo "❌ Could not read the existing Sparkle EdDSA key from Keychain." >&2
    exit 1
fi
SPARKLE_PUBLIC_ED_KEY=$(printf '%s' "${SPARKLE_PUBLIC_ED_KEY}" | tr -d '[:space:]')
if ! SPARKLE_PUBLIC_KEY_BYTE_COUNT=$(printf '%s' "${SPARKLE_PUBLIC_ED_KEY}" \
    | /usr/bin/base64 -D 2>/dev/null \
    | wc -c \
    | tr -d '[:space:]'); then
    SPARKLE_PUBLIC_KEY_BYTE_COUNT=0
fi
if [ "${SPARKLE_PUBLIC_KEY_BYTE_COUNT}" != "32" ]; then
    echo "❌ Existing Sparkle public key is not a 32-byte Ed25519 key." >&2
    exit 1
fi
if [ "${SPARKLE_PUBLIC_ED_KEY}" != "${PINNED_SPARKLE_PUBLIC_ED_KEY}" ]; then
    echo "The selected Keychain Sparkle key does not match ReleaseChannel.plist." >&2
    echo "Refusing to strand installed builds on a different update-signing key." >&2
    exit 1
fi

echo "🔍 Checking latest release on GitHub..."

if ! PUBLISHED_RELEASE_TAGS=$(gh api --paginate \
    "repos/${GITHUB_REPO}/releases?per_page=100" \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name'); then
    echo "Could not list existing GitHub releases; refusing to assume an empty release channel." >&2
    exit 1
fi
LATEST_TAG=""
if [ -n "${PUBLISHED_RELEASE_TAGS}" ]; then
    if ! LATEST_TAG=$(gh api \
        "repos/${GITHUB_REPO}/releases/latest" \
        --jq '.tag_name'); then
        echo "Published releases exist, but GitHub latest could not be resolved." >&2
        exit 1
    fi
    echo "   Latest release: ${LATEST_TAG}"
    if [[ ! "${LATEST_TAG}" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Latest release tag ${LATEST_TAG} is not a supported numeric marketing version." >&2
        echo "Resolve release ordering manually before publishing another latest release." >&2
        exit 1
    fi
    NORMALIZED_MARKETING_VERSION=$(normalize_marketing_version "${MARKETING_VERSION}")
    NORMALIZED_LATEST_VERSION=$(normalize_marketing_version "${LATEST_TAG}")
    if ! marketing_version_is_greater \
        "${NORMALIZED_MARKETING_VERSION}" \
        "${NORMALIZED_LATEST_VERSION}"; then
        echo "Marketing version ${MARKETING_VERSION} must exceed latest release ${LATEST_TAG}." >&2
        exit 1
    fi
else
    echo "   No previous releases found — starting from scratch"
fi

if ! RELEASE_BODIES=$(gh api --paginate \
    "repos/${GITHUB_REPO}/releases?per_page=100" \
    --jq '.[] | .body // ""'); then
    echo "Could not inspect existing release build metadata." >&2
    exit 1
fi
MAX_RECORDED_BUILD=$(printf '%s\n' "${RELEASE_BODIES}" \
    | awk '/^HeyMate-Build: [0-9]+$/ { if ($2 > max) max = $2 } END { if (max > 0) print max }')
if [ -n "${MAX_RECORDED_BUILD}" ] && [ "${BUILD_NUMBER}" -le "${MAX_RECORDED_BUILD}" ]; then
    echo "Build number must exceed recorded build ${MAX_RECORDED_BUILD}." >&2
    exit 1
fi

DMG_FILENAME="${APP_NAME}.dmg"
TAG="v${MARKETING_VERSION}"

# ── Safety checks ────────────────────────────────────────────────────────────

# A matching-refs list returns an empty array for absence but fails on API or
# authentication errors, so a transient outage can never masquerade as a free
# tag name.
if ! MATCHING_TAG_REF=$(gh api \
    "repos/${GITHUB_REPO}/git/matching-refs/tags/${TAG}" \
    --jq ".[] | select(.ref == \"refs/tags/${TAG}\") | .ref"); then
    echo "Could not verify whether tag ${TAG} already exists." >&2
    exit 1
fi
if [ -n "${MATCHING_TAG_REF}" ]; then
    echo ""
    echo "❌ Tag or release ${TAG} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo "   Choose a higher version and build number:"
    echo "     ./scripts/release.sh <higher-version> <higher-build>"
    exit 1
fi

echo ""
echo "🚀 Releasing ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "   Previous: ${LATEST_TAG:-none}"
echo "   Repository: ${GITHUB_REPO}"
echo "   Feed: ${SPARKLE_FEED_URL}"
echo "   Source commit: ${SOURCE_SHA}"
SPARKLE_KEY_FINGERPRINT=$(printf '%s' "${SPARKLE_PUBLIC_ED_KEY}" \
    | shasum -a 256 \
    | awk '{print substr($1, 1, 12)}')
echo "   Sparkle key fingerprint: ${SPARKLE_KEY_FINGERPRINT}"
echo ""

# Confirm with the user before proceeding
read -p "   Proceed? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   Aborted."
    exit 0
fi
echo ""

# ── Step 1: Clean build directory ────────────────────────────────────────────

echo "🧹 Cleaning build directory and stale DMGs..."
rm -rf "${BUILD_DIR}"
# Remove any leftover temp DMGs from create-dmg (rw.*.dmg) and the previous
# same-named DMG so create-dmg and generate_appcast don't choke on duplicates.
rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}" "${RELEASES_DIR}"

# ── Step 2: Archive ──────────────────────────────────────────────────────────

echo "📦 Archiving..."
xcodebuild archive \
    -project "${PROJECT_DIR}/leanring-buddy.xcodeproj" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    CODE_SIGN_IDENTITY="${RELEASE_SIGNING_IDENTITY}" \
    SPARKLE_FEED_URL="${SPARKLE_FEED_URL}" \
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    2>&1 | tail -5

echo "✅ Archive created"

# Fail before export, notarization, or upload if Xcode dropped or transformed
# either Sparkle value. A feed signed by a different key is unrecoverable from
# inside an already distributed app.
ARCHIVED_INFO_PLIST="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app/Contents/Info.plist"
if [ ! -f "${ARCHIVED_INFO_PLIST}" ]; then
    echo "❌ Archived Info.plist not found at ${ARCHIVED_INFO_PLIST}." >&2
    exit 1
fi
if ! ARCHIVED_SPARKLE_FEED_URL=$(/usr/libexec/PlistBuddy \
    -c 'Print :SUFeedURL' \
    "${ARCHIVED_INFO_PLIST}" 2>/dev/null); then
    echo "❌ Archive is missing SUFeedURL." >&2
    exit 1
fi
if ! ARCHIVED_SPARKLE_PUBLIC_ED_KEY=$(/usr/libexec/PlistBuddy \
    -c 'Print :SUPublicEDKey' \
    "${ARCHIVED_INFO_PLIST}" 2>/dev/null); then
    echo "❌ Archive is missing SUPublicEDKey." >&2
    exit 1
fi
if ! ARCHIVED_MARKETING_VERSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "${ARCHIVED_INFO_PLIST}" 2>/dev/null); then
    echo "❌ Archive is missing CFBundleShortVersionString." >&2
    exit 1
fi
if ! ARCHIVED_BUILD_NUMBER=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "${ARCHIVED_INFO_PLIST}" 2>/dev/null); then
    echo "❌ Archive is missing CFBundleVersion." >&2
    exit 1
fi
if [ "${ARCHIVED_SPARKLE_FEED_URL}" != "${SPARKLE_FEED_URL}" ]; then
    echo "❌ Archived SUFeedURL does not match the configured release repository." >&2
    exit 1
fi
if [ "${ARCHIVED_SPARKLE_PUBLIC_ED_KEY}" != "${SPARKLE_PUBLIC_ED_KEY}" ]; then
    echo "❌ Archived SUPublicEDKey does not match the Sparkle signing key." >&2
    exit 1
fi
if [ "${ARCHIVED_MARKETING_VERSION}" != "${MARKETING_VERSION}" ]; then
    echo "❌ Archived marketing version ${ARCHIVED_MARKETING_VERSION} does not match ${MARKETING_VERSION}." >&2
    exit 1
fi
if [ "${ARCHIVED_BUILD_NUMBER}" != "${BUILD_NUMBER}" ]; then
    echo "❌ Archived build ${ARCHIVED_BUILD_NUMBER} does not match ${BUILD_NUMBER}." >&2
    exit 1
fi
echo "✅ Archive contains verified version, build, Sparkle feed, and public key"

# ── Step 3: Export signed app ────────────────────────────────────────────────

# Create an export options plist for Developer ID distribution.
# This tells xcodebuild to export with the matching Developer ID certificate.
# The containing DMG is submitted for notarization in step 5.
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :teamID string ${DEVELOPMENT_TEAM}" "${EXPORT_OPTIONS}"
/usr/libexec/PlistBuddy -c "Add :signingStyle string manual" "${EXPORT_OPTIONS}"
/usr/libexec/PlistBuddy -c "Add :signingCertificate string ${RELEASE_SIGNING_IDENTITY}" "${EXPORT_OPTIONS}"

echo "📤 Exporting Developer ID-signed app..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    2>&1 | tail -5

echo "✅ Signed app export complete"

echo "🔎 Verifying exported app signature..."
codesign --verify --deep --strict --verbose=2 \
    "${EXPORT_DIR}/${APP_NAME}.app"
echo "✅ Exported app signature verified"

# ── Step 4: Create DMG ──────────────────────────────────────────────────────

DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"

echo "💿 Creating DMG..."
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | tail -3

echo "✅ DMG created: ${DMG_PATH}"

# ── Step 5: Sign, notarize, and verify the DMG ───────────────────────────────
# The .app inside the DMG is already signed with Developer ID, but the DMG
# itself also receives a Developer ID signature before Apple notarization.
# Requires stored credentials: xcrun notarytool store-credentials "AC_PASSWORD"

echo "✍️  Developer-ID-signing DMG..."
codesign --force \
    --sign "${RELEASE_SIGNING_IDENTITY}" \
    --timestamp \
    "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"

echo "🔏 Notarizing DMG with Apple (this may take a few minutes)..."
NOTARY_RESULT_PATH="${BUILD_DIR}/notary-result.json"
NOTARY_LOG_PATH="${BUILD_DIR}/notary-log.json"
if ! xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "AC_PASSWORD" \
    --wait \
    --output-format json > "${NOTARY_RESULT_PATH}"; then
    echo "❌ Apple notarization submission failed. Result retained at ${NOTARY_RESULT_PATH}." >&2
    exit 1
fi
if ! NOTARY_STATUS=$(/usr/bin/plutil -extract status raw "${NOTARY_RESULT_PATH}" 2>/dev/null); then
    echo "❌ Apple notarization result has no status. Result retained at ${NOTARY_RESULT_PATH}." >&2
    exit 1
fi
if ! NOTARY_SUBMISSION_ID=$(/usr/bin/plutil -extract id raw "${NOTARY_RESULT_PATH}" 2>/dev/null); then
    echo "❌ Apple notarization result has no submission ID." >&2
    exit 1
fi
if ! xcrun notarytool log "${NOTARY_SUBMISSION_ID}" \
    --keychain-profile "AC_PASSWORD" \
    "${NOTARY_LOG_PATH}"; then
    echo "❌ Could not retain Apple notarization log for ${NOTARY_SUBMISSION_ID}." >&2
    exit 1
fi
if [ "${NOTARY_STATUS}" != "Accepted" ]; then
    echo "❌ Apple notarization status is ${NOTARY_STATUS}." >&2
    echo "   Inspect ${NOTARY_LOG_PATH}." >&2
    exit 1
fi

echo "📎 Stapling notarization ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"
spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "${DMG_PATH}"

echo "✅ DMG notarized, stapled, and accepted by Gatekeeper"

# ── Step 6: Sign DMG with Sparkle EdDSA key ─────────────────────────────────

echo "🔐 Signing DMG with Sparkle EdDSA key..."
"${SPARKLE_BIN}/sign_update" \
    --account "${SPARKLE_KEY_ACCOUNT}" \
    "${DMG_PATH}"

# ── Step 7: Generate / update appcast.xml ────────────────────────────────────
# generate_appcast reads all DMGs in the releases/ directory, extracts version
# info from the app bundle inside each DMG, signs with your EdDSA key, and
# produces appcast.xml. The --download-url-prefix tells it where users will
# actually download the DMG from (GitHub Releases).

echo "📡 Generating appcast.xml..."
"${SPARKLE_BIN}/generate_appcast" \
    --account "${SPARKLE_KEY_ACCOUNT}" \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
    -o "${PROJECT_DIR}/appcast.xml" \
    "${RELEASES_DIR}"

echo "✅ appcast.xml updated"

# ── Step 8: Create GitHub Release ────────────────────────────────────────────
# Create the release first so the DMG download URL is live before we push the
# appcast that references it.

echo "🏷️  Creating GitHub Release ${TAG}..."
printf -v RELEASE_NOTES 'HeyMate v%s\n\nHeyMate-Build: %s\n' \
    "${MARKETING_VERSION}" \
    "${BUILD_NUMBER}"
gh release create "${TAG}" "${DMG_PATH}" "${PROJECT_DIR}/appcast.xml" \
    --repo "${GITHUB_REPO}" \
    --target "${SOURCE_SHA}" \
    --title "v${MARKETING_VERSION}" \
    --notes "${RELEASE_NOTES}" \
    --latest

if ! RELEASED_SOURCE_SHA=$(gh api \
    "repos/${GITHUB_REPO}/commits/${TAG}" \
    --jq '.sha'); then
    echo "❌ Release was created, but its source tag could not be verified." >&2
    echo "   Stop distribution and inspect ${TAG} manually." >&2
    exit 1
fi
if [ "${RELEASED_SOURCE_SHA}" != "${SOURCE_SHA}" ]; then
    echo "❌ Release tag ${TAG} does not resolve to approved source ${SOURCE_SHA}." >&2
    echo "   Stop distribution and inspect the release manually." >&2
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Release v${MARKETING_VERSION} (build ${BUILD_NUMBER}) complete!"
echo ""
echo "   DMG:      ${DMG_PATH}"
echo "   Appcast:  ${PROJECT_DIR}/appcast.xml"
echo "   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "   Download URL (always latest):"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo "═══════════════════════════════════════════════════════════════"
