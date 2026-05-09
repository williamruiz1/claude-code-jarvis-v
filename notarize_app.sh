#!/usr/bin/env bash
# Submits a signed VoiceMode Monitor.app to Apple notarization via notarytool.
#
# Prereqs (one-time):
#   1. Generate an app-specific password at https://appleid.apple.com/account/manage
#      → Sign-In and Security → App-Specific Passwords → +.
#   2. Save it into Keychain so notarytool can read it without prompting:
#
#        xcrun notarytool store-credentials "VoiceModeNotary" \
#            --apple-id "<your Apple ID email>" \
#            --team-id "5RRHNS4ZZB" \
#            --password "<app-specific password>"
#
#      The profile name "VoiceModeNotary" is what this script reads via
#      --keychain-profile. Override with VOICEMODE_NOTARY_PROFILE if you
#      named yours differently.
#
# Usage:
#   ./notarize_app.sh                                  # uses default app path
#   ./notarize_app.sh "/path/to/VoiceMode Monitor.app" # explicit
#
# What this does:
#   1. Zip the .app for upload (notarytool wants a flat zip).
#   2. Submit to Apple, wait synchronously, print log on failure.
#   3. Staple the resulting ticket back into the .app so it works offline.
#
# Apple notarization can take 1-15 minutes; submit-and-wait is the
# simplest UX. Use `--no-wait` manually if you want to background it.

set -euo pipefail

APP_PATH="${1:-${HOME}/Applications/VoiceMode Monitor.app}"
PROFILE="${VOICEMODE_NOTARY_PROFILE:-VoiceModeNotary}"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: app not found at: $APP_PATH" >&2
    echo "Build it first with ./build_app.sh (release mode), then re-run." >&2
    exit 1
fi

echo "==> verifying signature before notarization"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Check that hardened runtime + secure timestamp are in place.
SIGN_INFO=$(codesign --display --verbose=2 "$APP_PATH" 2>&1)
if ! echo "$SIGN_INFO" | grep -q "runtime"; then
    echo "ERROR: app is not signed with hardened runtime." >&2
    echo "Re-run ./build_app.sh in release mode (without VOICEMODE_DEV_BUILD=1)." >&2
    exit 1
fi
if ! echo "$SIGN_INFO" | grep -q "Timestamp="; then
    echo "ERROR: signature lacks a secure timestamp (required by notarization)." >&2
    echo "Re-sign with --timestamp via build_app.sh release mode." >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ZIP_PATH="${WORKDIR}/VoiceModeMonitor.zip"
echo "==> zipping app for upload: $ZIP_PATH"
# /usr/bin/ditto preserves macOS extended attributes + symlinks correctly,
# unlike vanilla zip(1).
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> submitting to Apple notarization (profile: $PROFILE)"
echo "    this can take 1-15 minutes; --wait keeps the script blocked until done."

set +e
SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PROFILE" \
    --wait \
    --output-format json 2>&1)
SUBMIT_STATUS=$?
set -e

echo "$SUBMIT_OUTPUT"

if [ $SUBMIT_STATUS -ne 0 ]; then
    echo "ERROR: notarytool submit failed (exit $SUBMIT_STATUS)." >&2
    echo "Common fixes:" >&2
    echo "  - Confirm the keychain profile exists:  xcrun notarytool history --keychain-profile $PROFILE" >&2
    echo "  - Re-create the profile (see top of this script)" >&2
    exit $SUBMIT_STATUS
fi

# Parse the submission ID for log retrieval if status != Accepted.
SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(d.get("id",""))' 2>/dev/null || true)
STATUS=$(echo "$SUBMIT_OUTPUT" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(d.get("status",""))' 2>/dev/null || true)

echo "    submission id: $SUBMISSION_ID"
echo "    status:        $STATUS"

if [ "$STATUS" != "Accepted" ]; then
    echo "ERROR: notarization status is '$STATUS', not 'Accepted'." >&2
    if [ -n "$SUBMISSION_ID" ]; then
        echo "Fetching log from Apple…" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" || true
    fi
    exit 1
fi

echo "==> stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> verifying with Gatekeeper (assessment)"
spctl --assess --type execute --verbose=2 "$APP_PATH" || true
# spctl will return non-zero if Gatekeeper rules don't accept it; that's
# informational here — notarization succeeded if we got past the staple step.

echo ""
echo "==> done. App is signed, notarized, and stapled:"
echo "    $APP_PATH"
echo ""
echo "You can now distribute the .app or wrap it in a DMG via create-dmg."
