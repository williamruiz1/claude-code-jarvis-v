#!/usr/bin/env bash
# install-piper-jarvis.sh
# Installs Piper TTS + the JARVIS (Iron Man) Marvel-trained Piper voice
# + a few high-quality fallback Piper voices, then stands up an
# OpenAI-compatible TTS endpoint via openedai-speech that VoiceMode can
# point at via VOICEMODE_TTS_BASE_URL / VOICEMODE_TTS_VOICE.
#
# Idempotent: re-running skips work that's already complete.
# Touches only:
#   - ~/.voicemode-monitor/{piper-venv,openedai-venv,openedai-speech,piper-models,logs}/
#   - ~/Library/LaunchAgents/com.williamruiz.voicemode-monitor.openedai-speech.plist
#   - this scripts/ directory (no writes elsewhere)

set -euo pipefail

# ---------- paths ----------
ROOT="${HOME}/.voicemode-monitor"
PIPER_VENV="${ROOT}/piper-venv"
OPENEDAI_VENV="${ROOT}/openedai-venv"
OPENEDAI_SRC="${ROOT}/openedai-speech"
MODELS_DIR="${ROOT}/piper-models"
LOG_DIR="${ROOT}/logs"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.williamruiz.voicemode-monitor.openedai-speech.plist"
PLIST_LABEL="com.williamruiz.voicemode-monitor.openedai-speech"
SERVER_HOST="127.0.0.1"
SERVER_PORT="8001"
UV_BIN="${HOME}/.local/bin/uv"

mkdir -p "${ROOT}" "${MODELS_DIR}" "${LOG_DIR}"

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install][WARN] %s\n' "$*" >&2; }
die() { printf '[install][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------- 1. preflight ----------
log "preflight: checking python toolchain"
PYTHON_BIN=""
if [ -x "${UV_BIN}" ]; then
    log "found uv at ${UV_BIN} (using uv to manage venvs)"
    USE_UV=1
else
    USE_UV=0
    if ! command -v python3 >/dev/null 2>&1; then
        die "python3 not found and uv unavailable; install Python 3.10+ or uv"
    fi
fi
PYTHON_BIN="$(command -v python3 || true)"
if [ -n "${PYTHON_BIN}" ]; then
    PY_VER="$("${PYTHON_BIN}" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
    log "system python3: ${PY_VER} at ${PYTHON_BIN}"
fi

# ---------- 2. piper venv ----------
log "step 2: installing piper-tts into ${PIPER_VENV}"
if [ ! -x "${PIPER_VENV}/bin/piper" ]; then
    if [ "${USE_UV}" = "1" ]; then
        # uv-managed venv with Python 3.11 (piper-tts works cleanly here;
        # piper-phonemize wheels avoid 3.13 issues some users hit)
        "${UV_BIN}" venv --python 3.11 "${PIPER_VENV}"
        "${UV_BIN}" pip install --python "${PIPER_VENV}/bin/python" piper-tts
    else
        "${PYTHON_BIN}" -m venv "${PIPER_VENV}"
        "${PIPER_VENV}/bin/pip" install --upgrade pip
        "${PIPER_VENV}/bin/pip" install piper-tts
    fi
else
    log "piper already installed; skipping"
fi

if ! "${PIPER_VENV}/bin/piper" --version >/dev/null 2>&1; then
    # piper-tts CLI prints version to stderr; both code paths are fine
    "${PIPER_VENV}/bin/piper" --help >/dev/null 2>&1 \
        || die "piper binary unusable at ${PIPER_VENV}/bin/piper"
fi
PIPER_VER="$("${PIPER_VENV}/bin/piper" --version 2>&1 | head -1 || echo unknown)"
log "piper ok: ${PIPER_VER}"

# ---------- 3+4. download models ----------
# format: <voice_id>|<onnx_url>|<json_url>
MODELS=(
    "jarvis|https://huggingface.co/jgkawell/jarvis/resolve/main/en/en_GB/jarvis/high/jarvis-high.onnx|https://huggingface.co/jgkawell/jarvis/resolve/main/en/en_GB/jarvis/high/jarvis-high.onnx.json"
    "en_GB-alan-medium|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium/en_GB-alan-medium.onnx|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium/en_GB-alan-medium.onnx.json"
    "en_GB-northern_english_male-medium|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx.json"
    "en_US-amy-medium|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json"
)

download_one() {
    local url="$1"
    local out="$2"
    local min_bytes="$3"
    if [ -f "${out}" ] && [ "$(wc -c <"${out}")" -ge "${min_bytes}" ]; then
        log "  cached: $(basename "${out}") ($(wc -c <"${out}") bytes)"
        return 0
    fi
    log "  fetching $(basename "${out}")"
    curl --fail --location --silent --show-error \
        --output "${out}.partial" "${url}"
    local sz
    sz="$(wc -c <"${out}.partial")"
    if [ "${sz}" -lt "${min_bytes}" ]; then
        # Sniff for HTML 404 body
        local first
        first="$(head -c 32 "${out}.partial" 2>/dev/null || true)"
        rm -f "${out}.partial"
        die "download too small (${sz} bytes) — likely a 404. URL: ${url}  first bytes: ${first}"
    fi
    mv "${out}.partial" "${out}"
    log "  saved: $(basename "${out}") (${sz} bytes)"
}

log "step 3+4: downloading Piper voices into ${MODELS_DIR}"
for entry in "${MODELS[@]}"; do
    voice_id="${entry%%|*}"
    rest="${entry#*|}"
    onnx_url="${rest%%|*}"
    json_url="${rest##*|}"
    voice_dir="${MODELS_DIR}/${voice_id}"
    mkdir -p "${voice_dir}"
    onnx_path="${voice_dir}/${voice_id}.onnx"
    json_path="${voice_dir}/${voice_id}.onnx.json"
    log "voice: ${voice_id}"
    # ONNX models are typically 60-160MB; require at least 5MB to catch 404 HTML
    download_one "${onnx_url}"  "${onnx_path}"  5000000
    # JSON config is usually 1-10KB; require at least 256 bytes
    download_one "${json_url}"  "${json_path}"  256
done

# ---------- 5. openedai-speech install ----------
log "step 5: installing openedai-speech into ${OPENEDAI_SRC} + ${OPENEDAI_VENV}"
if [ ! -d "${OPENEDAI_SRC}/.git" ]; then
    git clone --depth 1 https://github.com/matatonic/openedai-speech "${OPENEDAI_SRC}"
else
    log "openedai-speech repo already cloned; skipping git clone"
fi

if [ ! -x "${OPENEDAI_VENV}/bin/python" ]; then
    if [ "${USE_UV}" = "1" ]; then
        "${UV_BIN}" venv --python 3.11 "${OPENEDAI_VENV}"
    else
        "${PYTHON_BIN}" -m venv "${OPENEDAI_VENV}"
    fi
fi

# Install only the minimal (Piper-only) requirements — avoids torch/xtts.
log "installing openedai-speech minimal deps (piper-only path)"
if [ "${USE_UV}" = "1" ]; then
    "${UV_BIN}" pip install --python "${OPENEDAI_VENV}/bin/python" \
        -r "${OPENEDAI_SRC}/requirements-min.txt"
else
    "${OPENEDAI_VENV}/bin/pip" install --upgrade pip
    "${OPENEDAI_VENV}/bin/pip" install -r "${OPENEDAI_SRC}/requirements-min.txt"
fi

# ---------- 6. write voice_to_speaker.yaml ----------
# openedai-speech reads `config/voice_to_speaker.yaml` (relative to its
# WorkingDirectory). On first run it auto-copies the .default into config/;
# we overwrite that copy with our Piper-only mapping.
log "step 6: writing voice_to_speaker.yaml"
mkdir -p "${OPENEDAI_SRC}/config"
VOICE_YAML="${OPENEDAI_SRC}/config/voice_to_speaker.yaml"
cat > "${VOICE_YAML}" <<YAML
# Generated by install-piper-jarvis.sh — do not hand-edit (re-run installer).
# Maps OpenAI-style voice IDs to local Piper .onnx files.
tts-1:
  jarvis:
    model: ${MODELS_DIR}/jarvis/jarvis.onnx
    speaker:
  alan:
    model: ${MODELS_DIR}/en_GB-alan-medium/en_GB-alan-medium.onnx
    speaker:
  northern:
    model: ${MODELS_DIR}/en_GB-northern_english_male-medium/en_GB-northern_english_male-medium.onnx
    speaker:
  amy:
    model: ${MODELS_DIR}/en_US-amy-medium/en_US-amy-medium.onnx
    speaker:
  # Aliases for OpenAI's standard voice IDs so apps that hard-code
  # 'alloy'/'onyx'/etc. still get a sensible local Piper voice.
  alloy:
    model: ${MODELS_DIR}/en_US-amy-medium/en_US-amy-medium.onnx
    speaker:
  onyx:
    model: ${MODELS_DIR}/en_GB-alan-medium/en_GB-alan-medium.onnx
    speaker:
  echo:
    model: ${MODELS_DIR}/en_GB-northern_english_male-medium/en_GB-northern_english_male-medium.onnx
    speaker:
  fable:
    model: ${MODELS_DIR}/en_GB-northern_english_male-medium/en_GB-northern_english_male-medium.onnx
    speaker:
  nova:
    model: ${MODELS_DIR}/en_US-amy-medium/en_US-amy-medium.onnx
    speaker:
  shimmer:
    model: ${MODELS_DIR}/en_US-amy-medium/en_US-amy-medium.onnx
    speaker:
tts-1-hd:
  jarvis:
    model: ${MODELS_DIR}/jarvis/jarvis.onnx
    speaker:
YAML
log "voice config: ${VOICE_YAML}"

# ---------- 7. LaunchAgent ----------
log "step 7: writing LaunchAgent at ${PLIST_PATH}"
mkdir -p "$(dirname "${PLIST_PATH}")"

# If the plist already exists and is loaded, unload before rewriting so the
# new config takes effect.
if launchctl list | grep -q "${PLIST_LABEL}"; then
    log "  unloading existing agent ${PLIST_LABEL}"
    launchctl unload "${PLIST_PATH}" 2>/dev/null || true
fi

# Build PATH the agent will use. Add piper-venv first so speech.py finds piper.
AGENT_PATH="${PIPER_VENV}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/bin"

cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OPENEDAI_VENV}/bin/python</string>
        <string>${OPENEDAI_SRC}/speech.py</string>
        <string>--xtts_device</string>
        <string>none</string>
        <string>-H</string>
        <string>${SERVER_HOST}</string>
        <string>-P</string>
        <string>${SERVER_PORT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${OPENEDAI_SRC}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/openedai-speech.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/openedai-speech.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${AGENT_PATH}</string>
        <key>TTS_HOME</key>
        <string>${OPENEDAI_SRC}/voices</string>
        <key>HF_HOME</key>
        <string>${OPENEDAI_SRC}/voices</string>
    </dict>
</dict>
</plist>
PLIST

log "  loading agent"
launchctl load "${PLIST_PATH}"

# ---------- 8. wait for server ----------
# openedai-speech does NOT expose /v1/voices — its only routes are
# GET /, POST /v1/audio/speech, and the (stub) billing routes.
# We probe GET / for readiness, then POST a tiny synthesis to confirm
# the YAML config is being honored.
log "step 8: waiting for server at http://${SERVER_HOST}:${SERVER_PORT}"
ready=0
for i in $(seq 1 60); do
    if curl --silent --fail --max-time 2 \
        "http://${SERVER_HOST}:${SERVER_PORT}/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "${ready}" -ne 1 ]; then
    warn "server did not respond on / within 60s"
    warn "tailing ${LOG_DIR}/openedai-speech.err.log:"
    tail -n 40 "${LOG_DIR}/openedai-speech.err.log" 2>/dev/null || true
    die "openedai-speech server failed to start"
fi
log "server is up"
log "configured voices (from ${VOICE_YAML}):"
awk 'NR>1 && /^  [a-zA-Z0-9_-]+:$/ {sub(":",""); printf "  %s\n", $1}' "${VOICE_YAML}"

# ---------- 9. JARVIS audio test ----------
log "step 9: synthesising JARVIS test phrase"
TEST_AUDIO="${LOG_DIR}/jarvis-test.mp3"
HTTP_CODE="$(
  curl --silent --output "${TEST_AUDIO}" --write-out '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "http://${SERVER_HOST}:${SERVER_PORT}/v1/audio/speech" \
    -d '{"model":"tts-1","voice":"jarvis","input":"Good evening, William. All systems are online."}'
)"
if [ "${HTTP_CODE}" != "200" ]; then
    warn "synthesis returned HTTP ${HTTP_CODE}"
    warn "response body:"
    head -c 800 "${TEST_AUDIO}" >&2 || true
    die "JARVIS synthesis failed"
fi
AUDIO_SIZE="$(wc -c <"${TEST_AUDIO}")"
if [ "${AUDIO_SIZE}" -lt 1024 ]; then
    die "JARVIS audio suspiciously small (${AUDIO_SIZE} bytes)"
fi
log "  audio: ${TEST_AUDIO} (${AUDIO_SIZE} bytes)"
if command -v afplay >/dev/null 2>&1; then
    log "  playing via afplay"
    afplay "${TEST_AUDIO}" || warn "afplay returned non-zero"
fi

# ---------- 10. summary ----------
log ""
log "================================================================"
log " JARVIS / Piper install complete"
log "================================================================"
log " Server:        http://${SERVER_HOST}:${SERVER_PORT}"
log " LaunchAgent:   ${PLIST_LABEL}  (loaded, KeepAlive=true)"
log " Plist path:    ${PLIST_PATH}"
log " Logs:          ${LOG_DIR}/openedai-speech.{out,err}.log"
log " Voice config:  ${VOICE_YAML}"
log " Models dir:    ${MODELS_DIR}"
log ""
log " Voices available (model name 'tts-1' or 'tts-1-hd'):"
log "   jarvis      — Iron Man's JARVIS (Marvel-trained Piper, en_GB high)"
log "   alan        — en_GB-alan-medium (calm British male)"
log "   northern    — en_GB-northern_english_male-medium"
log "   amy         — en_US-amy-medium"
log "   alloy / onyx / echo / fable / nova / shimmer — aliases to the above"
log ""
log " To enable JARVIS in VoiceMode, add to:"
log "   ~/Library/Application Support/VoiceModeMonitor/voicemode-env.sh"
log "     export VOICEMODE_TTS_BASE_URL='http://${SERVER_HOST}:${SERVER_PORT}/v1'"
log "     export VOICEMODE_TTS_VOICE='jarvis'"
log "     export VOICEMODE_TTS_MODEL='tts-1'"
log ""
log " Re-verify any time with:"
log "   $(dirname "$0")/check-piper-jarvis.sh"
log "================================================================"
