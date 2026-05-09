# Local Piper / JARVIS TTS for VoiceMode

Two scripts that install and verify a local, OpenAI-compatible TTS endpoint
serving the Iron Man **JARVIS** Piper voice (and a few high-quality
fallbacks) so VoiceMode can use them in place of OpenAI's cloud voices.

## Files

- `install-piper-jarvis.sh` — one-shot installer (idempotent; safe to re-run)
- `check-piper-jarvis.sh` — health check (LaunchAgent status, server liveness,
  synthesis round-trip with audio playback)

## What gets installed

| Path | Purpose |
|---|---|
| `~/.voicemode-monitor/piper-venv/` | uv-managed venv with `piper-tts` |
| `~/.voicemode-monitor/openedai-venv/` | uv-managed venv with openedai-speech minimal deps (no torch/XTTS) |
| `~/.voicemode-monitor/openedai-speech/` | git clone of `matatonic/openedai-speech` |
| `~/.voicemode-monitor/openedai-speech/config/voice_to_speaker.yaml` | Generated voice → ONNX mapping |
| `~/.voicemode-monitor/piper-models/<voice>/` | `.onnx` + `.onnx.json` per voice |
| `~/.voicemode-monitor/logs/openedai-speech.{out,err}.log` | Server logs |
| `~/Library/LaunchAgents/com.williamruiz.voicemode-monitor.openedai-speech.plist` | KeepAlive launchd agent on `127.0.0.1:8001` |

No system-wide installs. No writes outside the paths above.

## Voices installed

| Voice ID | Source | Notes |
|---|---|---|
| `jarvis` | `jgkawell/jarvis` (en_GB high) | Marvel-trained Iron Man voice |
| `alan` | `rhasspy/piper-voices` `en_GB-alan-medium` | Calm British male |
| `northern` | `rhasspy/piper-voices` `en_GB-northern_english_male-medium` | Northern English |
| `amy` | `rhasspy/piper-voices` `en_US-amy-medium` | US English female |
| `alloy`, `onyx`, `echo`, `fable`, `nova`, `shimmer` | aliases | Map to one of the above so apps that hard-code OpenAI voice IDs still work |

## Wiring into VoiceMode

Edit `~/Library/Application Support/VoiceModeMonitor/voicemode-env.sh`:

```bash
export VOICEMODE_TTS_BASE_URL='http://127.0.0.1:8001/v1'
export VOICEMODE_TTS_VOICE='jarvis'
export VOICEMODE_TTS_MODEL='tts-1'
```

The MCP wrapper at `~/.claude.json` sources this file before launching
voicemode, so the next Claude Code session will use JARVIS.

## Usage

```bash
# Install / re-install (idempotent)
./install-piper-jarvis.sh

# Verify health any time
./check-piper-jarvis.sh
```

Manual probe:

```bash
curl -X POST http://127.0.0.1:8001/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","voice":"jarvis","input":"Good evening, sir."}' \
  --output /tmp/jarvis.mp3 && afplay /tmp/jarvis.mp3
```

## Notes / gotchas

- **No `/v1/voices` endpoint.** openedai-speech only exposes
  `POST /v1/audio/speech` (and a stub root + billing route). The check
  script probes `GET /` for liveness and validates voices by inspecting
  the local YAML.
- **Port 8001** was chosen to avoid the existing Kokoro server on `:8880`.
- **`requirements-min.txt`** is intentionally used instead of the full
  `requirements.txt` to skip torch/XTTS — Piper-only is ~150MB of deps
  vs ~5GB with XTTS, and JARVIS is a Piper model anyway.
- **`--xtts_device none`** is passed to `speech.py` so it never tries to
  load a torch backend even if XTTS deps were present.
- **upstream is archived.** The openedai-speech repo was archived
  2026-01-04. It still works fine for Piper, but if it ever bit-rots,
  Speaches.ai or Kokoro-FastAPI are documented alternatives.
- **Idempotent.** Re-running `install-piper-jarvis.sh` skips downloaded
  models, skips already-installed venvs, and reloads the LaunchAgent in
  place to pick up any config changes.
