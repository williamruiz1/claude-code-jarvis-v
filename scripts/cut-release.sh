#!/usr/bin/env bash
# Cut a new release of VoiceMode Monitor.
#
# Implements the per-release workflow from
# docs/specs/F15-sparkle-appcast-publishing.md (Steps 1-8).
#
# Usage:
#   ./scripts/cut-release.sh <short-version> <build-number>
#
# Example:
#   ./scripts/cut-release.sh 0.3.0 21
#
# What this does:
#   1.  Sanity-checks prerequisites (notarytool profile, Sparkle CLI, signing certs).
#   2.  Bumps CFBundleShortVersionString + CFBundleVersion in Resources/Info.plist.
#   3.  Runs ./build_app.sh to produce a Developer-ID-signed, hardened-runtime build.
#   4.  Runs ./notarize_app.sh to submit + staple via Apple notarytool.
#   5.  Zips the .app with `ditto -c -k --keepParent` (canonical macOS app-zip).
#   6.  Moves the zip into docs/releases/.
#   7.  Runs Sparkle's generate_appcast against docs/releases/.
#   8.  Moves the resulting appcast.xml to docs/appcast.xml.
#   9.  Prompts the operator to review, commit, push, and tag.
#
# What this does NOT do automatically:
#   - git add/commit/push   (you review the diff first; explicit prompt at the end).
#   - git tag / push tags   (same).
#   - GitHub Release create (optional follow-up; see spec Step 8).
#   - Release notes HTML    (write docs/releases/<version>.html by hand; see spec Step 6).

set -euo pipefail

# Make absolutely sure a stale env doesn't sneak a Sparkle-less build through.
unset VOICEMODE_NO_SPARKLE
unset VOICEMODE_DEV_BUILD
unset VOICEMODE_SKIP_LAUNCH

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INFO_PLIST="${ROOT}/Resources/Info.plist"
APP_PATH="/Applications/VoiceMode Monitor.app"
RELEASES_DIR="${ROOT}/docs/releases"
APPCAST_DEST="${ROOT}/docs/appcast.xml"
NOTARY_PROFILE="${VOICEMODE_NOTARY_PROFILE:-VoiceModeNotary}"
PAGES_BASE_URL="https://williamruiz1.github.io/claude-code-jarvis-v"

# Sparkle CLI binaries land here after `swift build -c release` resolves the SPM
# artifact bundle. (Sparkle 2.x ships generate_keys/generate_appcast/sign_update
# inside a binary artifact, not as a build product.)
SPARKLE_BIN="${ROOT}/.build/artifacts/sparkle/Sparkle/bin"

usage() {
    cat >&2 <<EOF
Usage: $0 <short-version> <build-number>

Example:
  $0 0.3.0 21

short-version    semver string for CFBundleShortVersionString (user-facing).
build-number     monotonic integer for CFBundleVersion. MUST always increment.
EOF
    exit 1
}

[ "$#" -eq 2 ] || usage
NEW_SHORT="$1"
NEW_BUILD="$2"

# --- Validate args ---------------------------------------------------------

if ! [[ "$NEW_SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "ERROR: short-version '$NEW_SHORT' is not semver (e.g. 0.3.0 or 0.3.0-beta.1)." >&2
    exit 1
fi

if ! [[ "$NEW_BUILD" =~ ^[0-9]+$ ]]; then
    echo "ERROR: build-number '$NEW_BUILD' is not an integer." >&2
    exit 1
fi

# --- Step 0: prerequisites --------------------------------------------------

echo "==> checking prerequisites"

if [ ! -f "$INFO_PLIST" ]; then
    echo "ERROR: $INFO_PLIST not found." >&2
    exit 1
fi

# Sparkle CLI tools — repopulate via swift build if missing.
if [ ! -x "${SPARKLE_BIN}/generate_appcast" ]; then
    echo "    Sparkle CLI not found at ${SPARKLE_BIN}/. Running 'swift build -c release' to populate..."
    swift build -c release
fi
if [ ! -x "${SPARKLE_BIN}/generate_appcast" ]; then
    echo "ERROR: ${SPARKLE_BIN}/generate_appcast still missing after swift build. Aborting." >&2
    exit 1
fi

# notarytool profile must exist — checking via `history` is the canonical probe.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: notarytool keychain profile '$NOTARY_PROFILE' is missing or unreadable.

One-time setup required:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id "<your Apple ID email>" \\
        --team-id "5RRHNS4ZZB" \\
        --password "<app-specific password>"

App-specific passwords are generated at:
    https://appleid.apple.com/account/manage
    -> Sign-In and Security -> App-Specific Passwords -> +

Override the profile name with VOICEMODE_NOTARY_PROFILE=<name> if you used a different one.
EOF
    exit 1
fi

# Sparkle EdDSA private key must be in the keychain at Sparkle's default location.
# generate_keys -p prints the public key; if no keypair exists it errors.
if ! "${SPARKLE_BIN}/generate_keys" -p >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: no Sparkle EdDSA private key found in the login keychain.

Run once to create one:
    ${SPARKLE_BIN}/generate_keys

Then update Resources/Info.plist's SUPublicEDKey with the printed public key,
back up the private key (Bitwarden / encrypted disk), and re-run this script.
EOF
    exit 1
fi

# Confirm the public key in Info.plist matches the private key in the keychain.
KEYCHAIN_PUB="$(${SPARKLE_BIN}/generate_keys -p)"
PLIST_PUB="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
if [ "$KEYCHAIN_PUB" != "$PLIST_PUB" ]; then
    cat >&2 <<EOF
ERROR: SUPublicEDKey in $INFO_PLIST does not match the public key for the
private key currently in your login keychain.

  In Info.plist:  $PLIST_PUB
  From keychain:  $KEYCHAIN_PUB

If you re-ran generate_keys without updating Info.plist, signed updates will
fail verification on every user. Fix by either:

  - Updating Info.plist's SUPublicEDKey to the keychain value (if intentional), OR
  - Re-importing the original private key (generate_keys -f <backup.pem>).

See docs/specs/F15-sparkle-appcast-publishing.md § Failure modes (F-2).
EOF
    exit 1
fi

# Working tree should be clean before a release cut, so the bump commit is auditable.
if [ -n "$(git status --porcelain)" ]; then
    echo "WARN: working tree is not clean. The version bump + appcast changes will land" >&2
    echo "      alongside whatever else is uncommitted. Continuing in 5s..." >&2
    sleep 5
fi

# --- Step 1: bump version ---------------------------------------------------

OLD_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

echo "==> bumping version: ${OLD_SHORT} (${OLD_BUILD}) -> ${NEW_SHORT} (${NEW_BUILD})"

if [ "$NEW_BUILD" -le "$OLD_BUILD" ]; then
    echo "ERROR: new build number ${NEW_BUILD} must be > old ${OLD_BUILD}." >&2
    echo "       Sparkle uses CFBundleVersion to decide 'newer than installed'." >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_SHORT" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

# --- Step 2: build (release) ------------------------------------------------

echo "==> building release .app"
"${ROOT}/build_app.sh"

# build_app.sh installs to /Applications/VoiceMode Monitor.app. Confirm.
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: built app not found at $APP_PATH. build_app.sh may have failed silently." >&2
    exit 1
fi

# --- Step 3: notarize + staple ----------------------------------------------

echo "==> notarizing + stapling (this can take 1-15 minutes)"
"${ROOT}/notarize_app.sh" "$APP_PATH"

echo "==> verifying staple landed"
xcrun stapler validate "$APP_PATH"

# --- Step 4: zip the .app for distribution ----------------------------------

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${APP_PATH}/Contents/Info.plist")"
ZIP_NAME="VoiceMode-Monitor-${VERSION}.zip"
ZIP_PATH="${RELEASES_DIR}/${ZIP_NAME}"

mkdir -p "$RELEASES_DIR"
echo "==> zipping app -> ${ZIP_PATH}"
# ditto -c -k --keepParent is the canonical macOS app-zip incantation.
# (zip -r from BSD zip strips metadata Sparkle needs for staple validation.)
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# --- Step 5: regenerate the appcast ----------------------------------------

echo "==> running generate_appcast against ${RELEASES_DIR}/"
"${SPARKLE_BIN}/generate_appcast" \
    "$RELEASES_DIR" \
    --download-url-prefix "${PAGES_BASE_URL}/releases/"

# generate_appcast writes to <dir>/appcast.xml — relocate it to docs/appcast.xml
# so SUFeedURL (.../appcast.xml) resolves correctly via Pages.
GENERATED_APPCAST="${RELEASES_DIR}/appcast.xml"
if [ ! -f "$GENERATED_APPCAST" ]; then
    echo "ERROR: generate_appcast did not produce ${GENERATED_APPCAST}." >&2
    exit 1
fi

mv "$GENERATED_APPCAST" "$APPCAST_DEST"
echo "    appcast written to $APPCAST_DEST"

# --- Step 6: prompt for commit + push + tag --------------------------------

cat <<EOF

==> release artifacts ready for review

Files changed:
  Resources/Info.plist                                   (version bump)
  docs/appcast.xml                                       (regenerated)
  docs/releases/${ZIP_NAME}                              (new release zip)

Optional but recommended (do by hand BEFORE committing):
  - Write release notes HTML at: docs/releases/${VERSION}.html
    (template in docs/specs/F15-sparkle-appcast-publishing.md § Step 6)
  - Add <sparkle:releaseNotesLink>...${VERSION}.html</sparkle:releaseNotesLink>
    inside the matching <item> in docs/appcast.xml.

When you're satisfied, run:

  git add Resources/Info.plist docs/appcast.xml docs/releases/${ZIP_NAME}
  # plus docs/releases/${VERSION}.html if you wrote one
  git commit -m "release: ${VERSION}"
  git push origin main
  git tag "v${VERSION}"
  git push --tags

Then verify the appcast is live:
  ./scripts/verify-appcast.sh

EOF
