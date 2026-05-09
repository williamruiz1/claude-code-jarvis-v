#!/usr/bin/env bash
# check-piper-jarvis.sh
# Re-runnable health check for the local Piper / openedai-speech stack.
# Exits 0 on green; non-zero with a clear failure reason otherwise.

set -euo pipefail

SERVER_HOST="127.0.0.1"
SERVER_PORT="8001"
PLIST_LABEL="com.williamruiz.voicemode-monitor.openedai-speech"
ROOT="${HOME}/.voicemode-monitor"
LOG_DIR="${ROOT}/logs"
TEST_AUDIO="${LOG_DIR}/jarvis-healthcheck.mp3"

mkdir -p "${LOG_DIR}"

ok()   { printf '[check][ OK ] %s\n' "$*"; }
fail() { printf '[check][FAIL] %s\n' "$*" >&2; FAILED=1; }
info() { printf '[check][....] %s\n' "$*"; }

FAILED=0

# 1. LaunchAgent loaded?
info "LaunchAgent: ${PLIST_LABEL}"
if launchctl list | awk '{print $3}' | grep -qx "${PLIST_LABEL}"; then
    PID="$(launchctl list | awk -v l="${PLIST_LABEL}" '$3==l{print $1}')"
    if [ "${PID}" = "-" ] || [ -z "${PID}" ]; then
        fail "agent registered but no running PID (likely crash-looping; check ${LOG_DIR}/openedai-speech.err.log)"
    else
        ok "agent loaded, pid=${PID}"
    fi
else
    fail "agent not registered with launchctl"
fi

# 2. Port reachable?
# openedai-speech doesn't expose /v1/voices; probe / for liveness and
# rely on a synthesis round-trip (step 3) for real validation.
info "endpoint: http://${SERVER_HOST}:${SERVER_PORT}/"
if curl --silent --fail --max-time 5 "http://${SERVER_HOST}:${SERVER_PORT}/" >/dev/null; then
    ok "server alive on ${SERVER_HOST}:${SERVER_PORT}"
else
    fail "server unreachable on ${SERVER_HOST}:${SERVER_PORT}"
fi

# Voices from local YAML (source of truth for what's configured)
VOICE_YAML="${ROOT}/openedai-speech/config/voice_to_speaker.yaml"
if [ -f "${VOICE_YAML}" ]; then
    info "configured voices (from ${VOICE_YAML}):"
    awk 'NR>1 && /^  [a-zA-Z0-9_-]+:$/ {sub(":",""); printf "         %s\n", $1}' "${VOICE_YAML}"
    if grep -q "^  jarvis:" "${VOICE_YAML}"; then
        ok "jarvis configured in voice_to_speaker.yaml"
    else
        fail "jarvis NOT configured in voice_to_speaker.yaml"
    fi
else
    fail "voice_to_speaker.yaml missing at ${VOICE_YAML}"
fi

# 3. Synthesis round-trip
info "synthesising test phrase via jarvis"
HTTP_CODE="$(
  curl --silent --output "${TEST_AUDIO}" --write-out '%{http_code}' --max-time 30 \
    -H 'Content-Type: application/json' \
    -X POST "http://${SERVER_HOST}:${SERVER_PORT}/v1/audio/speech" \
    -d '{"model":"tts-1","voice":"jarvis","input":"Health check passed."}' \
    || echo "000"
)"
if [ "${HTTP_CODE}" = "200" ]; then
    SZ="$(wc -c <"${TEST_AUDIO}")"
    if [ "${SZ}" -ge 1024 ]; then
        ok "synthesis OK (${SZ} bytes at ${TEST_AUDIO})"
        if command -v afplay >/dev/null 2>&1; then
            info "playing audio (afplay)"
            afplay "${TEST_AUDIO}" || fail "afplay returned non-zero"
        fi
    else
        fail "audio response too small (${SZ} bytes) — likely an error body"
    fi
else
    fail "synthesis HTTP ${HTTP_CODE}"
    head -c 400 "${TEST_AUDIO}" >&2 || true
    printf '\n' >&2
fi

if [ "${FAILED}" -eq 0 ]; then
    printf '\n[check] all green\n'
    exit 0
else
    printf '\n[check] failures detected — see [FAIL] lines above\n'
    printf '       last 20 stderr lines from server:\n'
    tail -n 20 "${LOG_DIR}/openedai-speech.err.log" 2>/dev/null | sed 's/^/         /'
    exit 1
fi
