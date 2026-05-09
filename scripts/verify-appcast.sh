#!/usr/bin/env bash
# Verifies the published Sparkle appcast for VoiceMode Monitor.
#
# Checks (per docs/specs/F15-sparkle-appcast-publishing.md § verify-appcast.sh):
#   1. Local docs/appcast.xml parses as XML.
#   2. Remote appcast at the SUFeedURL parses and matches the local copy
#      (mismatch -> warn; usually means a push hasn't deployed yet).
#   3. For each <item>: enclosure URL returns HTTP 200, EdDSA signature verifies
#      against the SUPublicEDKey in Resources/Info.plist using sign_update.
#   4. Items are sorted newest-first by CFBundleVersion (sparkle:version attribute).
#
# Usage:
#   ./scripts/verify-appcast.sh
#
# Exits 0 if all checks pass, non-zero if any item fails.
# Warns (but does not fail) on local/remote mismatch — Pages CDN can lag a few
# minutes after a push.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INFO_PLIST="${ROOT}/Resources/Info.plist"
LOCAL_APPCAST="${ROOT}/docs/appcast.xml"
PAGES_BASE_URL="https://williamruiz1.github.io/claude-code-jarvis-v"
REMOTE_APPCAST_URL="${PAGES_BASE_URL}/appcast.xml"

SPARKLE_BIN="${ROOT}/.build/artifacts/sparkle/Sparkle/bin"

# --- Step 0: prerequisites --------------------------------------------------

if [ ! -f "$LOCAL_APPCAST" ]; then
    echo "ERROR: local appcast not found at $LOCAL_APPCAST." >&2
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "ERROR: $INFO_PLIST not found." >&2
    exit 1
fi

if [ ! -x "${SPARKLE_BIN}/sign_update" ]; then
    echo "    sign_update missing — running 'swift build -c release' to populate Sparkle artifacts."
    swift build -c release
fi
if [ ! -x "${SPARKLE_BIN}/sign_update" ]; then
    echo "ERROR: ${SPARKLE_BIN}/sign_update still missing." >&2
    exit 1
fi

PUB_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
if [ -z "$PUB_KEY" ]; then
    echo "ERROR: SUPublicEDKey in Info.plist is empty. Cannot verify signatures." >&2
    exit 1
fi

# --- Step 1: local appcast parses ------------------------------------------

echo "==> checking local appcast parses as XML"
if ! xmllint --noout "$LOCAL_APPCAST" 2>/dev/null; then
    echo "ERROR: $LOCAL_APPCAST is not valid XML." >&2
    exit 1
fi

# --- Step 2: remote appcast parses and matches local -----------------------

REMOTE_TMP="$(mktemp)"
trap 'rm -f "$REMOTE_TMP"' EXIT

echo "==> fetching remote appcast: $REMOTE_APPCAST_URL"
REMOTE_HTTP_CODE="$(curl -sL -o "$REMOTE_TMP" -w '%{http_code}' "$REMOTE_APPCAST_URL" || echo 000)"

if [ "$REMOTE_HTTP_CODE" != "200" ]; then
    echo "WARN: remote appcast returned HTTP $REMOTE_HTTP_CODE — Pages may not be deployed yet." >&2
elif ! xmllint --noout "$REMOTE_TMP" 2>/dev/null; then
    echo "WARN: remote appcast is not valid XML." >&2
elif ! diff -q "$LOCAL_APPCAST" "$REMOTE_TMP" >/dev/null 2>&1; then
    echo "WARN: local and remote appcasts differ — recent push may still be deploying."
    echo "      (Pages CDN can lag 1-5 minutes. Re-run after a short wait.)"
else
    echo "    remote matches local."
fi

# --- Step 3: per-item enclosure URL + signature verification ---------------

# Extract enclosures via xmllint XPath. Each item's enclosure has url + length +
# sparkle:edSignature + sparkle:version attributes. We pull them in parallel
# arrays.
mapfile -t URLS < <(xmllint --xpath '//enclosure/@url' "$LOCAL_APPCAST" 2>/dev/null \
    | grep -oE 'url="[^"]+"' | sed -E 's/^url="(.+)"$/\1/')
mapfile -t SIGS < <(xmllint --xpath '//enclosure/@*[local-name()="edSignature"]' "$LOCAL_APPCAST" 2>/dev/null \
    | grep -oE 'edSignature="[^"]+"' | sed -E 's/^.*edSignature="(.+)"$/\1/')
mapfile -t VERS < <(xmllint --xpath '//enclosure/@*[local-name()="version"]' "$LOCAL_APPCAST" 2>/dev/null \
    | grep -oE 'version="[^"]+"' | sed -E 's/^.*version="(.+)"$/\1/')

ITEM_COUNT="${#URLS[@]}"

if [ "$ITEM_COUNT" -eq 0 ]; then
    echo ""
    echo "==> appcast contains zero <item> entries."
    echo "    This is normal before the first release cut. PASS (nothing to verify)."
    exit 0
fi

echo ""
echo "==> verifying $ITEM_COUNT release item(s)"

ANY_FAIL=0
PREV_VER=""

for i in "${!URLS[@]}"; do
    URL="${URLS[$i]}"
    SIG="${SIGS[$i]:-}"
    VER="${VERS[$i]:-}"

    echo ""
    echo "  [$((i+1))/$ITEM_COUNT] $URL  (build $VER)"

    # 3a: enclosure URL must return 200.
    HTTP_CODE="$(curl -sL -o /dev/null -w '%{http_code}' -I "$URL" || echo 000)"
    if [ "$HTTP_CODE" != "200" ]; then
        echo "    FAIL: HTTP $HTTP_CODE (expected 200)"
        ANY_FAIL=1
        continue
    fi
    echo "    ok  HTTP 200"

    # 3b: download bytes, verify signature.
    if [ -z "$SIG" ]; then
        echo "    FAIL: no sparkle:edSignature attribute on enclosure"
        ANY_FAIL=1
        continue
    fi

    DL_TMP="$(mktemp)"
    if ! curl -sL -o "$DL_TMP" "$URL"; then
        echo "    FAIL: download failed"
        rm -f "$DL_TMP"
        ANY_FAIL=1
        continue
    fi

    # sign_update --verify takes the public key and the signature; the file is
    # passed as a positional argument. Different Sparkle CLI versions accept
    # slightly different flags; both forms below are tried.
    if "${SPARKLE_BIN}/sign_update" --verify "$SIG" -p "$PUB_KEY" "$DL_TMP" >/dev/null 2>&1 \
        || "${SPARKLE_BIN}/sign_update" -p "$PUB_KEY" --verify "$SIG" "$DL_TMP" >/dev/null 2>&1; then
        echo "    ok  EdDSA signature verifies"
    else
        echo "    FAIL: EdDSA signature does not verify against SUPublicEDKey"
        ANY_FAIL=1
    fi
    rm -f "$DL_TMP"

    # 3c: ordering check (newest first by sparkle:version).
    if [ -n "$PREV_VER" ] && [ -n "$VER" ]; then
        if [ "$VER" -gt "$PREV_VER" ] 2>/dev/null; then
            echo "    WARN: items not sorted newest-first ($VER appears after $PREV_VER)"
        fi
    fi
    PREV_VER="$VER"
done

echo ""
if [ "$ANY_FAIL" -ne 0 ]; then
    echo "==> SUMMARY: FAIL — at least one item failed verification."
    exit 1
fi

echo "==> SUMMARY: PASS — all $ITEM_COUNT item(s) verified."
