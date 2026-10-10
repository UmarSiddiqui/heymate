#!/bin/bash
#
# release.sh: cut a HeyMate release by hand, from this Mac.
#
#   ./scripts/release.sh <marketing-version> <build-number>
#   ./scripts/release.sh 2.0 10
#
# Merging to main already publishes a release through
# .github/workflows/release.yml. This script is the manual path for when that
# is unavailable. It refuses to start until every input is proven good, then:
#
#   archive → verify → export (Developer ID) → DMG → sign, notarize, staple
#   → Sparkle signature → appcast.xml → GitHub release → verify the tag
#
# One-time setup on this Mac:
#   - A Developer ID Application certificate in the login keychain
#   - brew install create-dmg gh, then gh auth login
#   - The Sparkle EdDSA key in the keychain (its public half is pinned in
#     ReleaseChannel.plist)
#   - xcrun notarytool store-credentials "AC_PASSWORD"
#   - One Xcode build of the project, so SwiftPM has fetched Sparkle's tools
#
# Optional environment:
#   HEYMATE_DEVELOPMENT_TEAM          pick a team when several certificates exist
#   HEYMATE_RELEASE_SIGNING_IDENTITY  a certificate name or SHA-1 hash
#   HEYMATE_SPARKLE_KEY_ACCOUNT       keychain account of the Sparkle key

set -euo pipefail

# Non-interactive shells miss Homebrew's PATH, and with it create-dmg and gh.
export PATH="/opt/homebrew/bin:$PATH"

readonly APP_NAME="HeyMate"
readonly SCHEME="HeyMate"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROJECT_DIR
readonly BUILD_DIR="${PROJECT_DIR}/build"
readonly ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
readonly ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
readonly EXPORT_DIR="${BUILD_DIR}/export"
readonly EXPORTED_APP="${EXPORT_DIR}/${APP_NAME}.app"
# generate_appcast reads every DMG in this folder.
readonly RELEASES_DIR="${PROJECT_DIR}/releases"
readonly DMG_FILENAME="${APP_NAME}.dmg"
readonly DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"
readonly DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
readonly RELEASE_CHANNEL_CONFIG="${PROJECT_DIR}/ReleaseChannel.plist"
readonly NOTARY_PROFILE="AC_PASSWORD"
readonly SPARKLE_KEY_ACCOUNT="${HEYMATE_SPARKLE_KEY_ACCOUNT:-ed25519}"

# shellcheck source=../script/code_signature_checks.sh
source "${PROJECT_DIR}/script/code_signature_checks.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
    local line
    for line in "$@"; do echo "❌ ${line}" >&2; done
    exit 1
}

step() {
    echo ""
    echo "$1"
}

strip_whitespace() {
    printf '%s' "$1" | tr -d '[:space:]'
}

# Prints one key of a plist, or fails when the key is missing.
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# True when the argument is base64 for exactly 32 bytes: an Ed25519 public key.
is_ed25519_public_key() {
    local byte_count
    byte_count=$(printf '%s' "$1" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d '[:space:]') || return 1
    [ "${byte_count}" = "32" ]
}

# "v2.1" → "2.1.0", with leading zeros dropped so versions compare as numbers.
normalized_version() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "${1#v}"
    printf '%d.%d.%d\n' "$((10#${major}))" "$((10#${minor}))" "$((10#${patch:-0}))"
}

# True when normalized version $1 is strictly newer than $2.
is_newer_version() {
    local candidate previous index
    IFS='.' read -r -a candidate <<< "$1"
    IFS='.' read -r -a previous <<< "$2"
    for index in 0 1 2; do
        (( candidate[index] > previous[index] )) && return 0
        (( candidate[index] < previous[index] )) && return 1
    done
    return 1
}

# ── Arguments ────────────────────────────────────────────────────────────────

# Both numbers are required. Counting past releases is not safe: drafts,
# deletions and pagination can make a count repeat, and Sparkle orders
# updates by build number.
if [ "$#" -ne 2 ]; then
    echo "Usage: ./scripts/release.sh <marketing-version> <build-number>" >&2
    echo "Example: ./scripts/release.sh 2.0 10" >&2
    exit 1
fi
readonly MARKETING_VERSION="$1"
readonly BUILD_NUMBER="$2"
readonly TAG="v${MARKETING_VERSION}"
[[ "${MARKETING_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Marketing version must look like 2.0 or 2.0.1."
[[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || die "Build number must be a positive integer."

# ── Release channel ──────────────────────────────────────────────────────────

[ -f "${RELEASE_CHANNEL_CONFIG}" ] || die "ReleaseChannel.plist is missing."
GITHUB_REPO=$(strip_whitespace "$(plist_value "${RELEASE_CHANNEL_CONFIG}" Repository)")
PINNED_SPARKLE_KEY=$(strip_whitespace "$(plist_value "${RELEASE_CHANNEL_CONFIG}" PublicEDKey)")
[[ "${GITHUB_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "Pin the permanent public owner/repository in ReleaseChannel.plist."
is_ed25519_public_key "${PINNED_SPARKLE_KEY}" \
    || die "Pin a valid 32-byte Sparkle Ed25519 public key in ReleaseChannel.plist."

# Sparkle downloads anonymously, so a private repository would strand users.
VISIBILITY=$(gh api "repos/${GITHUB_REPO}" --jq '.visibility') \
    || die "Could not verify the configured release repository."
[ "${VISIBILITY}" = "public" ] \
    || die "Sparkle updates need anonymous downloads from a public repository." \
           "${GITHUB_REPO} is not public; stopping before any build or upload."

# Every archived app keeps this URL forever. The `latest` redirect means it
# never names a tag, branch or hosting account.
readonly SPARKLE_FEED_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"

# ── Source ───────────────────────────────────────────────────────────────────

# Only a clean tree that GitHub already has can be released, so every DMG
# traces back to reviewed, public source.
SOURCE_ROOT=$(git -C "${PROJECT_DIR}" rev-parse --show-toplevel 2>/dev/null) \
    || die "The release source is not inside a Git repository."
[ -z "$(git -C "${SOURCE_ROOT}" status --porcelain --untracked-files=normal)" ] \
    || die "The source tree has tracked or untracked changes. Commit a reviewed clean tree first."
SOURCE_SHA=$(git -C "${SOURCE_ROOT}" rev-parse HEAD)
REMOTE_SHA=$(gh api "repos/${GITHUB_REPO}/commits/${SOURCE_SHA}" --jq '.sha') \
    || die "Commit ${SOURCE_SHA} is not in ${GITHUB_REPO}." "Push the reviewed commit before releasing it."
[ "${REMOTE_SHA}" = "${SOURCE_SHA}" ] || die "GitHub returned a different commit for ${SOURCE_SHA}; refusing to release."

# ── Signing identity ─────────────────────────────────────────────────────────

# Team and certificate stay on this Mac: detected from the keychain or given
# through the environment, never committed.
DEVELOPMENT_TEAM="${HEYMATE_DEVELOPMENT_TEAM:-}"
SIGNING_IDENTITY="${HEYMATE_RELEASE_SIGNING_IDENTITY:-}"
CANDIDATES=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' || true)
if [ -n "${DEVELOPMENT_TEAM}" ]; then
    CANDIDATES=$(printf '%s\n' "${CANDIDATES}" | grep -F "(${DEVELOPMENT_TEAM})\"" || true)
fi
if [[ "${SIGNING_IDENTITY}" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    CANDIDATES=$(printf '%s\n' "${CANDIDATES}" | grep -i " ${SIGNING_IDENTITY} " || true)
elif [ -n "${SIGNING_IDENTITY}" ]; then
    CANDIDATES=$(printf '%s\n' "${CANDIDATES}" | grep -F "\"${SIGNING_IDENTITY}\"" || true)
fi
CHOSEN=$(printf '%s\n' "${CANDIDATES}" | sed -n '1p')
[ -n "${CHOSEN}" ] || die "No installed Developer ID Application certificate matches the requested team or identity."

# A find-identity line reads: `  1) <SHA-1> "Developer ID Application: Name (TEAMID)"`.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(printf '%s\n' "${CHOSEN}" | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p')}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(printf '%s\n' "${CHOSEN}" | sed -n 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) .*/\1/p')}"
[ -n "${DEVELOPMENT_TEAM}" ] && [ -n "${SIGNING_IDENTITY}" ] \
    || die "Could not settle on one release team and signing identity."

# ── Sparkle key ──────────────────────────────────────────────────────────────

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/HeyMate*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    -maxdepth 0 2>/dev/null | head -1)
[ -n "${SPARKLE_BIN}" ] || die "Sparkle's tools are missing. Build the project in Xcode once so SwiftPM fetches them."

# Only the public half leaves the keychain; sign_update and generate_appcast
# use the private half in place.
SPARKLE_PUBLIC_KEY=$("${SPARKLE_BIN}/generate_keys" --account "${SPARKLE_KEY_ACCOUNT}" -p) \
    || die "Could not read the Sparkle EdDSA key from the keychain."
SPARKLE_PUBLIC_KEY=$(strip_whitespace "${SPARKLE_PUBLIC_KEY}")
is_ed25519_public_key "${SPARKLE_PUBLIC_KEY}" || die "The keychain's Sparkle public key is not a 32-byte Ed25519 key."
# Installed copies only trust the pinned key; signing with another would
# leave them unable to update, with no way to fix it from here.
[ "${SPARKLE_PUBLIC_KEY}" = "${PINNED_SPARKLE_KEY}" ] \
    || die "The keychain's Sparkle key does not match ReleaseChannel.plist." \
           "Refusing to strand installed copies on a different signing key."

# ── Version ordering ─────────────────────────────────────────────────────────

echo "🔍 Checking earlier releases on GitHub..."
PUBLISHED_TAGS=$(gh api --paginate "repos/${GITHUB_REPO}/releases?per_page=100" \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name') \
    || die "Could not list GitHub releases; refusing to assume there are none."
LATEST_TAG=""
if [ -n "${PUBLISHED_TAGS}" ]; then
    LATEST_TAG=$(gh api "repos/${GITHUB_REPO}/releases/latest" --jq '.tag_name') \
        || die "Releases exist, but GitHub's latest release could not be read."
    echo "   Latest release: ${LATEST_TAG}"
    [[ "${LATEST_TAG}" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
        || die "The latest tag ${LATEST_TAG} is not a numeric version." \
               "Sort out release ordering by hand before publishing another."
    is_newer_version "$(normalized_version "${MARKETING_VERSION}")" "$(normalized_version "${LATEST_TAG}")" \
        || die "Version ${MARKETING_VERSION} must be newer than the latest release, ${LATEST_TAG}."
else
    echo "   No earlier releases; this is the first."
fi

# Every release this script makes records its build as `HeyMate-Build: N`.
RELEASE_BODIES=$(gh api --paginate "repos/${GITHUB_REPO}/releases?per_page=100" --jq '.[] | .body // ""') \
    || die "Could not read the build numbers of earlier releases."
HIGHEST_BUILD=$(printf '%s\n' "${RELEASE_BODIES}" \
    | awk '/^HeyMate-Build: [0-9]+$/ { if ($2 > max) max = $2 } END { if (max > 0) print max }')
if [ -n "${HIGHEST_BUILD}" ] && [ "${BUILD_NUMBER}" -le "${HIGHEST_BUILD}" ]; then
    die "Build number must be higher than ${HIGHEST_BUILD}, the highest released so far."
fi

# matching-refs answers an empty list when the tag is free and fails on an
# outage, so an API error can never pass for a free tag.
EXISTING_TAG=$(gh api "repos/${GITHUB_REPO}/git/matching-refs/tags/${TAG}" \
    --jq ".[] | select(.ref == \"refs/tags/${TAG}\") | .ref") \
    || die "Could not check whether ${TAG} already exists."
[ -z "${EXISTING_TAG}" ] \
    || die "${TAG} already exists: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}" \
           "Pick a higher version and build: ./scripts/release.sh <version> <build>"

# ── Confirm ──────────────────────────────────────────────────────────────────

KEY_FINGERPRINT=$(printf '%s' "${SPARKLE_PUBLIC_KEY}" | shasum -a 256 | cut -c1-12)
cat <<SUMMARY

🚀 ${APP_NAME} ${MARKETING_VERSION} (build ${BUILD_NUMBER})
   Previous release:        ${LATEST_TAG:-none}
   Repository:              ${GITHUB_REPO}
   Update feed:             ${SPARKLE_FEED_URL}
   Source commit:           ${SOURCE_SHA}
   Sparkle key fingerprint: ${KEY_FINGERPRINT}

SUMMARY
read -p "   Proceed? (y/N) " -n 1 -r
echo ""
if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "   Aborted."
    exit 0
fi

# ── 1. Clean ─────────────────────────────────────────────────────────────────

step "🧹 Clearing the build folder and stale DMGs..."
rm -rf "${BUILD_DIR}"
# create-dmg leaves rw.*.dmg scratch files behind on failure, and an old DMG
# of the same name would confuse both it and generate_appcast.
rm -f "${RELEASES_DIR}"/rw.*.dmg "${DMG_PATH}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${RELEASES_DIR}"

# ── 2. Archive ───────────────────────────────────────────────────────────────

step "📦 Archiving..."
xcodebuild archive \
    -project "${PROJECT_DIR}/HeyMate.xcodeproj" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    SPARKLE_FEED_URL="${SPARKLE_FEED_URL}" \
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_KEY}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    2>&1 | tail -5

# Check what Xcode actually baked in before anything leaves this Mac. An app
# shipped with the wrong feed or key can never be corrected from outside it.
ARCHIVED_INFO="${ARCHIVED_APP}/Contents/Info.plist"
[ -f "${ARCHIVED_INFO}" ] || die "The archive has no Info.plist at ${ARCHIVED_INFO}."
expect_archived() {
    local key="$1" expected="$2" actual
    actual=$(plist_value "${ARCHIVED_INFO}" "${key}") || die "The archive is missing ${key}."
    [ "${actual}" = "${expected}" ] || die "The archive's ${key} is ${actual}, expected ${expected}."
}
expect_archived SUFeedURL "${SPARKLE_FEED_URL}"
expect_archived SUPublicEDKey "${SPARKLE_PUBLIC_KEY}"
expect_archived CFBundleShortVersionString "${MARKETING_VERSION}"
expect_archived CFBundleVersion "${BUILD_NUMBER}"
echo "✅ Archive has the expected version, build, update feed and key"

codesign --verify --deep --strict --verbose=2 "${ARCHIVED_APP}"
heymate_require_hardened_runtime "${ARCHIVED_APP}"
heymate_verify_embedded_agent_runner "${ARCHIVED_APP}" release
echo "✅ Archive is signed, hardened, and carries its own agent runner"

# ── 3. Export ────────────────────────────────────────────────────────────────

step "📤 Exporting the Developer ID-signed app..."
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
/usr/libexec/PlistBuddy \
    -c "Add :method string developer-id" \
    -c "Add :destination string export" \
    -c "Add :teamID string ${DEVELOPMENT_TEAM}" \
    -c "Add :signingStyle string manual" \
    -c "Add :signingCertificate string ${SIGNING_IDENTITY}" \
    "${EXPORT_OPTIONS}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    2>&1 | tail -5

codesign --verify --deep --strict --verbose=2 "${EXPORTED_APP}"
heymate_require_hardened_runtime "${EXPORTED_APP}"
heymate_verify_embedded_agent_runner "${EXPORTED_APP}" release
echo "✅ Exported app signature verified"

# ── 4. DMG ───────────────────────────────────────────────────────────────────

# Icon positions line up with the arrow drawn on dmg-background.png (660×400).
step "💿 Building ${DMG_FILENAME}..."
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORTED_APP}" \
    2>&1 | tail -3

# ── 5. Sign, notarize, staple ────────────────────────────────────────────────

# The app inside is already signed; the DMG gets its own Developer ID
# signature so Gatekeeper accepts the download itself.
step "✍️  Signing the DMG..."
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"

step "🔏 Notarizing with Apple (usually a few minutes)..."
NOTARY_RESULT="${BUILD_DIR}/notary-result.json"
NOTARY_LOG="${BUILD_DIR}/notary-log.json"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json \
    > "${NOTARY_RESULT}" \
    || die "Notarization submission failed. The result is in ${NOTARY_RESULT}."
NOTARY_STATUS=$(/usr/bin/plutil -extract status raw "${NOTARY_RESULT}" 2>/dev/null) \
    || die "Apple's notarization result has no status. It is in ${NOTARY_RESULT}."
NOTARY_ID=$(/usr/bin/plutil -extract id raw "${NOTARY_RESULT}" 2>/dev/null) \
    || die "Apple's notarization result has no submission ID."
# Kept whatever the outcome, so a rejection can be diagnosed.
xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" "${NOTARY_LOG}" \
    || die "Could not save the notarization log for ${NOTARY_ID}."
[ "${NOTARY_STATUS}" = "Accepted" ] || die "Notarization status is ${NOTARY_STATUS}. See ${NOTARY_LOG}."

xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
echo "✅ DMG notarized, stapled, and accepted by Gatekeeper"

# ── 6. Sparkle ───────────────────────────────────────────────────────────────

step "🔐 Signing the update with the Sparkle key..."
"${SPARKLE_BIN}/sign_update" --account "${SPARKLE_KEY_ACCOUNT}" "${DMG_PATH}"

# generate_appcast reads the app inside each DMG in releases/, signs the
# entry and points its download at this release's asset.
step "📡 Writing appcast.xml..."
"${SPARKLE_BIN}/generate_appcast" \
    --account "${SPARKLE_KEY_ACCOUNT}" \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
    -o "${PROJECT_DIR}/appcast.xml" \
    "${RELEASES_DIR}"

# ── 7. Publish ───────────────────────────────────────────────────────────────

# The DMG and the appcast that points at it go up together, so the feed is
# never live before its download is.
step "🏷️  Publishing ${TAG} on GitHub..."
printf -v RELEASE_NOTES '%s %s\n\nHeyMate-Build: %s\n' "${APP_NAME}" "${TAG}" "${BUILD_NUMBER}"
gh release create "${TAG}" "${DMG_PATH}" "${PROJECT_DIR}/appcast.xml" \
    --repo "${GITHUB_REPO}" \
    --target "${SOURCE_SHA}" \
    --title "${TAG}" \
    --notes "${RELEASE_NOTES}" \
    --latest

RELEASED_SHA=$(gh api "repos/${GITHUB_REPO}/commits/${TAG}" --jq '.sha') \
    || die "${TAG} was published, but its tag could not be checked." "Hold distribution and inspect ${TAG} by hand."
[ "${RELEASED_SHA}" = "${SOURCE_SHA}" ] \
    || die "${TAG} points at ${RELEASED_SHA}, not the approved ${SOURCE_SHA}." "Hold distribution and inspect the release by hand."

cat <<DONE

✅ ${APP_NAME} ${MARKETING_VERSION} (build ${BUILD_NUMBER}) is out.
   DMG:      ${DMG_PATH}
   Appcast:  ${PROJECT_DIR}/appcast.xml
   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}
   Download: https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}
DONE
