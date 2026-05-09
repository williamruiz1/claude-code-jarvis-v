# VoiceMode Menubar v2 — Architecture Recommendation

**Date:** 2026-05-08
**Audience:** Two parallel build agents (UI agent + Voice/IPC agent)
**Source repo:** `/Users/williamruiz/code/voicemode-menubar/` (Swift 5.9, AppKit, SPM, ~600 LOC, NSStatusItem + NSPanel)
**Target:** "Proper app" — main window, transcript pane, voice picker (Jarvis-style options), Sparkle auto-update, Developer ID-signed + notarized.

---

## 1. VoiceMode 8.6.1 voice configuration

VoiceMode is configured almost entirely through environment variables consumed by the `uvx voice-mode` MCP server. The variables we care about for the v2 voice picker:

### Core TTS env vars

| Variable | Purpose | Notes |
|---|---|---|
| `VOICEMODE_TTS_VOICE` | Default TTS voice | Single voice name (e.g. `nova`) |
| `VOICEMODE_VOICES` | Comma-separated allowlist of voices the picker can offer | e.g. `af_sky,nova,alloy` |
| `VOICEMODE_TTS_MODEL` | Default TTS model | e.g. `tts-1-hd`, `tts-1`, `gpt-4o-mini-tts` |
| `VOICEMODE_TTS_MODELS` | Comma-separated model list (preference order) | |
| `VOICEMODE_TTS_BASE_URLS` | Comma-separated OpenAI-compatible endpoints, **tried in order** | e.g. `http://127.0.0.1:8880/v1,https://api.openai.com/v1` |
| `VOICEMODE_TTS_SPEED` | Playback rate, 0.25–4.0 (default 1.0) | |
| `VOICEMODE_TTS_AUDIO_FORMAT` | `pcm`, `opus`, `mp3`, `wav`, `flac`, `aac` | |
| `OPENAI_API_KEY` | Used as fallback for cloud OpenAI TTS/STT | The single API-key env var documented for the cloud path |

### Core STT env vars

| Variable | Purpose | Notes |
|---|---|---|
| `VOICEMODE_STT_BASE_URLS` | OpenAI-compatible STT endpoints (Whisper) | |
| `VOICEMODE_WHISPER_MODEL` | e.g. `large-v2` | Local-whisper.cpp path |
| `VOICEMODE_WHISPER_LANGUAGE` | Default `auto` | |
| `VOICEMODE_WHISPER_PORT` | Local whisper.cpp server port (default `2022`) | |
| `VOICEMODE_STT_AUDIO_FORMAT` | Same format set as TTS | |

### Audio / log / data paths

| Variable | Default | Use to v2 |
|---|---|---|
| `VOICEMODE_DATA_DIR` | `~/.voicemode` | Root for everything else |
| `VOICEMODE_LOG_DIR` | `~/.voicemode/logs` | Where event logs land |
| `VOICEMODE_CACHE_DIR` | `~/.voicemode/cache` | |
| `VOICEMODE_SAVE_RECORDINGS` | `false` | Set `true` to keep mic input audio |
| `VOICEMODE_SAVE_TTS` | `false` | Set `true` to keep generated TTS audio |
| `VOICEMODE_SAVE_ALL` | `false` | Convenience: enables all save flags |
| `VOICEMODE_EVENT_LOG` | `false` | **v2-relevant** — enable to write event log file |
| `VOICEMODE_CONVERSATION_LOG` | `false` | **v2-relevant** — enable to write conversation transcripts |
| `VOICEMODE_LOG_LEVEL` | `info` | `debug` is loud but reveals timing |
| `VOICEMODE_DEBUG` | `false` | Convenience flag: verbose + saves all audio |
| `VOICEMODE_SAVE_AUDIO` | `false` | Saves audio to `~/.voicemode/audio/YYYY/MM/` |

### OpenAI TTS voices supported by VoiceMode (when pointed at `api.openai.com/v1`)

The supported set on `tts-1` / `tts-1-hd` (Whisper-1 STT pair): **alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer**. The `gpt-4o-mini-tts` model adds **marin** and **cedar**. Voice cost is the same regardless of choice.

### ElevenLabs path — the important constraint

**ElevenLabs does NOT publish an OpenAI-compatible `/v1/audio/speech` endpoint.** Pointing `VOICEMODE_TTS_BASE_URLS` directly at `https://api.elevenlabs.io/v1` will fail because the request shape and route don't match.

To wire ElevenLabs into VoiceMode we have to put a translation proxy in front of it. The two viable patterns:

**Option A — LiteLLM proxy (recommended).** LiteLLM translates OpenAI's `/v1/audio/speech` requests to ElevenLabs' native API. Spin up locally (`pip install 'litellm[proxy]' && litellm --config litellm.yaml`) with:

```yaml
# litellm.yaml
model_list:
  - model_name: elevenlabs-tts
    litellm_params:
      model: elevenlabs/eleven_multilingual_v2
      api_key: os.environ/ELEVENLABS_API_KEY
general_settings:
  master_key: sk-local-anything
```

Then in the menubar app's launch env: `VOICEMODE_TTS_BASE_URLS=http://127.0.0.1:4000/v1,https://api.openai.com/v1` and `VOICEMODE_TTS_VOICE=elevenlabs-tts`.

**Option B — Silero / open-webui style shim.** A standalone open-source proxy (`silero_openai_tts` or similar) that exposes `/v1/audio/speech` and routes to ElevenLabs. Lighter weight than LiteLLM but less actively maintained.

**Recommendation:** start with Option A, document Option B as a fallback if LiteLLM proves heavy. The menubar app should NOT bundle a Python runtime — instead, it ships a settings pane that detects whether a proxy is running on `127.0.0.1:4000` and surfaces a "Voice provider: ElevenLabs (via LiteLLM)" option only when it is.

### IPC / state-file exposure (from VoiceMode itself)

There is no documented IPC, socket, or state file VoiceMode exposes for an external app. Audio files written under `~/.voicemode/audio/YYYY/MM/` are post-hoc artifacts. `VOICEMODE_EVENT_LOG=true` and `VOICEMODE_CONVERSATION_LOG=true` write log files under `~/.voicemode/logs/` — but the docs do not specify file path, schema, or whether they're append-mode JSON-line. **Treat them as undocumented experimental sources** for v2 — verify by enabling and inspecting locally before relying on them.

### Sources

- `https://github.com/mbailey/voicemode/blob/master/docs/guides/configuration.md`
- `https://voice-mode.readthedocs.io/en/latest/guides/configuration/`
- `https://github.com/mbailey/voicemode`

---

## 2. Jarvis-style voices

Concrete options ranked by effort vs. quality:

### Option A — ElevenLabs Voice Library (highest quality, mid cost)

There is **no official "Jarvis" voice** in the ElevenLabs Voice Library — the name is trademarked. What's available:

- The **British detective / British male / Old male** category collections include several Jarvis-adjacent voices (calm British male, slight upper-class register). Browse `https://elevenlabs.io/voice-library/british-detective` and `https://elevenlabs.io/voice-library/adult-male-voices` — pick a voice in the dashboard, copy its **Voice ID** (a 20-character hash like `21m00Tcm4TlvDq8ikWAM`).
- Community voices labeled "Jarvis" exist as user uploads (search "jarvis" in the library) — these are clones of public-domain butler-character samples and quality varies. Treat as user-curated.
- For a true J.A.R.V.I.S. clone, ElevenLabs **Professional Voice Cloning** (Creator tier and up) lets the user upload 30 minutes of source audio. The character's actual voice is copyrighted, so this is for personal use only.

**Pricing:** Voice Library access requires the **Creator** tier at **$22/month** (100,000 characters of TTS, API access, professional voice cloning enabled). Free tier doesn't include API access for cloned/library voices in any production-suitable way.

**Wiring (with the LiteLLM proxy from §1):**
```bash
export ELEVENLABS_API_KEY=sk_xxx
# Override the litellm.yaml model line to use the chosen voice:
#   model: elevenlabs/<voice_id>
# Or pass voice= per request once LiteLLM exposes the param.
```

### Option B — OpenAI built-in `onyx` voice (zero extra cost)

`onyx` on `tts-1-hd` is the closest "deep authoritative male" voice in OpenAI's set. Not British, not as characterful, but free with the existing OpenAI key and zero new infrastructure. Reasonable default for v2 ship — surface it in the picker as "Onyx (built-in, deep male)".

```bash
export VOICEMODE_TTS_VOICE=onyx
export VOICEMODE_TTS_MODEL=tts-1-hd
```

### Option C — macOS built-in voices via `say -v` (free, lowest quality)

macOS ships premium voices `Daniel` (UK English, male) and `Oliver` (UK English, male) — these are the closest to a butler register among the free system voices. They are NOT routed through VoiceMode's TTS pipeline; they would require a separate "preview voice" or "speak this" feature in the menubar app that bypasses VoiceMode entirely:

```bash
say -v Daniel "At your service, sir."
say -v Oliver "Right away."
```

Useful only as a **preview button** in the voice picker so the user can hear the OS voice before deciding on a paid path. Don't try to make it the primary TTS — there is no streaming integration with the conversation flow.

### Option D — PlayHT / Cartesia (alternative paid providers)

Both expose OpenAI-compatible endpoints (Cartesia natively; PlayHT via LiteLLM). Lower cost per character than ElevenLabs at high volume; voice library smaller and less character-driven. Defer until ElevenLabs proves insufficient.

### Recommendation for v2

Ship the picker with three groups: **Built-in (OpenAI)** — alloy, echo, fable, onyx, nova, shimmer, ash, ballad, coral, sage, marin, cedar; **Custom (ElevenLabs)** — appears only if ElevenLabs API key is set in Settings; **System Preview (macOS)** — Daniel, Oliver, plus the user's installed premium voices, as a non-conversation preview row.

### Sources

- `https://elevenlabs.io/voice-library`
- `https://elevenlabs.io/pricing/api`
- `https://platform.openai.com/docs/guides/text-to-speech`

---

## 3. Live transcript IPC patterns

The constraint: VoiceMode runs as an MCP server inside Claude Code. Our menubar app does not own that process and cannot patch it for v2. We need to surface transcripts in a side pane.

### Compared approaches

**A. Tail Claude Code's per-session JSONL.** Claude Code writes `~/.claude/projects/<url-encoded-cwd>/<session-uuid>.jsonl` continuously. Each JSON line has `{message: {role, content[]}, toolUseResult, timestamp, ...}`. VoiceMode's `mcp__voicemode__converse` tool calls and their results land here as `tool_use` and `tool_result` content blocks. Pros: structured, durable, no extra config, tracks the actual conversation including model-side text. Cons: parsing is non-trivial (lines can be tens of KB; tool results may include base64 audio refs); we have to figure out which session JSONL is "the live one" (the one with the most recent mtime in the active project dir is a safe heuristic).

**B. Wrap VoiceMode with a stdout/stderr-capturing shim.** Create a small launcher script that runs `uvx voice-mode` with stdout/stderr piped to a fifo or rotating log file the menubar app can tail. Pros: simplest format. Cons: requires the user to launch VoiceMode through our shim instead of the standard install — fragile, breaks the "drop-in" promise, and only works if Claude Code's MCP launcher invokes our shim instead of `uvx`.

**C. AppleScript-scrape Terminal.app contents.** `tell application "Terminal" to get contents of selected tab of front window`. Pros: works without changes anywhere else. Cons: extremely fragile (assumes Terminal.app, assumes a specific tab is "the" Claude session, requires Automation permission, breaks under iTerm/Ghostty/Warp), and you get the entire styled terminal buffer including ANSI noise — parsing voicemode output from it is heuristic and lossy.

**D. Enable `VOICEMODE_CONVERSATION_LOG=true` and tail it.** Per §1, this is documented but the schema and path aren't. Worth verifying as a future signal — could supersede option A — but **don't depend on it for v2 without first inspecting the actual file format**.

**E. Patch VoiceMode upstream to add a Unix socket on `/tmp/voicemode.sock`.** The "right" answer; out of scope for this iteration per the README's own v2 deferral. Note as the long-term ideal.

### Primary recommendation: A (JSONL tail), fallback D (conversation log) once verified

JSONL tailing is the only approach that works with the user's existing setup, captures the actual conversation, and degrades gracefully (if no session file exists, the transcript pane just shows "No active session"). Implementation sketch the build agent should follow:

1. On app launch, scan `~/.claude/projects/` for session JSONLs modified in the last 5 minutes; surface the most recent as "Active session."
2. Use `DispatchSource.makeFileSystemObjectSource` (kqueue) on that file to get notified of writes; on each notification, seek to last-known offset and read new lines.
3. Per line: `JSONDecoder` into a minimal shape, filter where `message.content[]` includes a `tool_use` with `name == "mcp__voicemode__converse"` (capture the user-spoken phrase from the tool's input or assistant's reply text) or a `tool_result` referencing the same `tool_use_id` (capture the model's spoken response).
4. Append to an `[TranscriptEntry]` ObservableObject feeding the transcript NSTableView/NSScrollView.

If the user switches to a new Claude session (different JSONL), detect via filesystem watcher on the project directory and re-bind.

### Sources

- `https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b`
- `https://github.com/withLinda/claude-JSONL-browser`
- `https://github.com/daaain/claude-code-log`

---

## 4. STT hallucination patterns for OpenAI Whisper / `whisper-1`

About 1% of Whisper transcriptions on real audio contain hallucinated content; the rate spikes on silent or near-silent audio (the "non-vocal duration" signal). Roughly **35% of all hallucinations come from the top 2 phrases**, and **>50% from the top 10** — meaning a small static dictionary catches most of them.

### The known hallucination corpus

Documented across the OpenAI Whisper repo (issues #679, #1606), the whisper.cpp issue #1724, and academic studies (Calm-Whisper, Cornell 2024, Investigation of Whisper ASR Hallucinations 2025):

**YouTube-isms (Whisper trained on auto-captions):**
- "Thanks for watching!"
- "Thanks for watching."
- "Thank you for watching."
- "Like and subscribe."
- "Don't forget to like and subscribe."
- "See you in the next video."
- "Subtitles by the Amara.org community"
- "Transcript: Emily Beynon"
- "Thanks for watching and Electric Unicorn"

**Generic filler:**
- "you" (single word, on near-silence)
- "."  (single punctuation)
- "Bye." / "Bye-bye."
- " "  (whitespace token)
- "♪" (music marker, on noise)

**Multilingual translation injections** (Whisper mid-segment slips into another language):
- Chinese / Korean / Japanese subtitle-credit phrases (e.g. "字幕志愿者")
- Russian credits

**Subtitler attributions:**
- "Subtitles by..."
- "Translated by..."
- (Random proper names — these are the hardest because they look plausible)

### How reliable is detection?

- **Static phrase-list filter** is high-precision, low-recall: catches the top ~50% of hallucinations with near-zero false positives. Recommended as v2 baseline.
- **Silence-gating before send** is more effective than post-processing: if `RMS < threshold for >X seconds`, don't send the audio to Whisper at all. VoiceMode already does some of this, but the threshold is conservative — the menubar app can't easily tighten it without forking VoiceMode.
- **Repetition detection**: Whisper hallucinations often loop ("you you you you"). Trivial post-process: if any token repeats >5 times consecutively, drop the segment.
- **Calm-Whisper / Whisper-Zero** are research approaches that retrain the model — not applicable to v2 because we use the API, not a local model we control.

### v2 recommendation

Implement a **hallucination filter** in the transcript-display layer (NOT inside VoiceMode — we don't own it). Keep it as a small `Set<String>` of canonical phrases (lowercase, normalized punctuation), check each new transcript entry, and if it matches: don't drop the entry from the JSONL state, but flag it visually in the transcript pane (greyed-out + "(likely silence hallucination)"). Let the user see what was filtered so they can audit. Also add a "Report this as hallucination" right-click menu to grow the dictionary over time (write to `~/Library/Application Support/VoiceModeMenuBar/hallucinations.json`).

Be honest in the UI: "Filter is best-effort and catches roughly half of silence hallucinations."

### Sources

- `https://github.com/openai/whisper/discussions/679`
- `https://github.com/ggml-org/whisper.cpp/issues/1724`
- `https://arxiv.org/html/2501.11378v1` (Investigation of Whisper ASR Hallucinations Induced by Non-Speech Audio)

---

## 5. macOS menu-bar app production-polish best practices in 2026

### 5.1 Sparkle 2.x via Swift Package Manager

Sparkle 2 is the current major version, supports macOS 10.13+, supports SPM, and adds sandbox + custom UI support. Setup for an SPM-built app (no Xcode project):

**Add to `Package.swift`:**
```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
],
targets: [
    .executableTarget(
        name: "VoiceModeMenuBar",
        dependencies: [
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        ...
    )
]
```

**Required Info.plist keys:**
```xml
<key>SUFeedURL</key>
<string>https://williamruiz.github.io/voicemode-menubar/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>...base64 EdDSA public key from generate_keys...</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

**One-time setup:**
1. After SPM resolves, find Sparkle's bin dir at `.build/checkouts/Sparkle/bin/` (or `~/Library/Developer/Xcode/DerivedData/...`).
2. Run `./bin/generate_keys` once — stores private signing key in macOS Keychain, prints public key.
3. Paste public key into Info.plist as `SUPublicEDKey`.
4. For each release: build the `.app`, zip it, run `./bin/generate_appcast /path/to/release-folder/` to produce `appcast.xml` with EdDSA signatures.
5. Host `appcast.xml` and the `.zip` on HTTPS (GitHub Pages or `gh release` URLs both work; Pages is simpler for the appcast itself).

**Wire into AppKit (no MainMenu.xib in this repo):**

Programmatic wiring inside `AppDelegate`:
```swift
import Sparkle
let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
// Then add NSMenuItem with target=updaterController, action=#selector(SPUStandardUpdaterController.checkForUpdates(_:))
```

`SPUStandardUpdaterController` retains itself once `startingUpdater: true`; check for updates fires automatically every 24h by default.

### 5.2 Developer ID code-sign + notarization for an SPM-built app

Build agents must produce a `.app` bundle (the existing `build_app.sh` does this — extend it). The flow:

1. **Build the binary:** `swift build -c release --arch arm64 --arch x86_64` (universal).
2. **Assemble the .app bundle** (Contents/MacOS/VoiceModeMenuBar, Contents/Info.plist, Contents/Resources/AppIcon.icns, Contents/Frameworks/Sparkle.framework — Sparkle ships an XPC framework that must be inside the app's Frameworks dir).
3. **Sign nested frameworks first, then the app, with `--options runtime` (hardened runtime is mandatory for notarization):**
   ```bash
   codesign --force --options runtime --timestamp \
       --sign "Developer ID Application: William Ruiz (TEAMID)" \
       VoiceMode\ Monitor.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc
   codesign --force --options runtime --timestamp \
       --sign "Developer ID Application: William Ruiz (TEAMID)" \
       VoiceMode\ Monitor.app/Contents/Frameworks/Sparkle.framework
   codesign --force --options runtime --timestamp --deep \
       --sign "Developer ID Application: William Ruiz (TEAMID)" \
       VoiceMode\ Monitor.app
   ```
4. **Zip and submit to notarytool:**
   ```bash
   ditto -c -k --sequesterRsrc --keepParent VoiceMode\ Monitor.app VoiceMode-Monitor.zip
   xcrun notarytool submit VoiceMode-Monitor.zip \
       --keychain-profile "AC_NOTARY" \
       --wait
   ```
   First run: store credentials with `xcrun notarytool store-credentials AC_NOTARY --apple-id ... --team-id ... --password APP_SPECIFIC_PASSWORD`.
5. **Staple the ticket:**
   ```bash
   xcrun stapler staple VoiceMode\ Monitor.app
   ```
6. **Verify:** `spctl -a -vvv -t install VoiceMode\ Monitor.app` — should print `accepted` + `source=Notarized Developer ID`.

The existing `build_app.sh` already handles signing for the dev path; extend it with a `RELEASE=1` mode that adds notarization + stapling.

### 5.3 App icon generation: best free tool

The macOS-native sips + iconutil pipeline is the canonical free tool — no third-party install needed and produces the smallest correct `.icns`.

Single-file workflow given a 1024×1024 PNG:
```bash
mkdir AppIcon.iconset
for size in 16 32 64 128 256 512; do
    sips -z $size $size icon-1024.png --out AppIcon.iconset/icon_${size}x${size}.png
    sips -z $((size*2)) $((size*2)) icon-1024.png --out AppIcon.iconset/icon_${size}x${size}@2x.png
done
sips -z 1024 1024 icon-1024.png --out AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

For convenience, the open-source `BenSouchet/png-to-icns` shell script wraps this exact flow if the build agent prefers a single command. Avoid online "icon generator" SaaS — they upload your asset and add zero value over the local pipeline.

### 5.4 Preferences/Settings window (AppKit, not SwiftUI)

This app is AppKit-only and macOS 13+. The mature pattern:

- Use `sindresorhus/Settings` (Swift package, formerly `Preferences`) for the toolbar-style multi-pane window. Drop-in: declare each pane as a `SettingsPane` (NSViewController + identifier + display name + symbolic icon), instantiate `SettingsWindowController(panes:)`, present via `settingsWindowController.show()`.
- The package handles: NSToolbar with selectable items, window resize on pane switch, deep-linking to a specific pane, modal vs non-modal presentation.
- Recommended panes for v2: **General** (launch at login, dock-icon visibility, hotkey), **Voices** (provider radio: OpenAI / ElevenLabs / Local; voice picker scoped to provider; speed slider; preview button using `say -v Daniel`), **Transcript** (font, max history, hallucination-filter toggle, "Reveal logs in Finder"), **Updates** (Sparkle checkbox: auto-check, channel: stable/beta), **About** (version, GitHub link, license).
- Each pane: build with `NSGridView` in code (no IB — repo has no `.xib`s). Stack labels in column 0, controls in column 1, `setRowAlignment(.firstBaseline, ...)`.

If the agent prefers a hand-roll: subclass `NSWindowController`, attach `NSToolbar` with `selectionIndex`-driven content swap inside an `NSBox` or container `NSView`. The Settings package saves a week of fiddling for zero downside; recommend it.

### 5.5 Menu-bar + main-window coexistence

Default for v2: **`LSUIElement = true`** in Info.plist (no Dock icon, no menu bar). The "main window" is opened on demand from the status item menu and dismissed by closing it. Patterns:

- **Single source of truth: the AppDelegate owns one `MainWindowController`** (lazy-init). Status-item action: if the controller's window is visible, hide and `NSApp.setActivationPolicy(.accessory)`; if not, `NSApp.setActivationPolicy(.regular)`, `controller.showWindow(nil)`, `NSApp.activate(ignoringOtherApps: true)`. Toggling the activation policy is what makes the Dock icon and Cmd-Tab presence appear/disappear with the window — without this dance, the menu-bar app's NSWindow appears behind other apps and can't take focus.
- **Don't use `NSPopover` for the main window.** The current `NSPanel` floating widget is fine for a quick-glance UI from the status item. The transcript main window is too rich for a popover; use a real `NSWindow` with title bar, traffic lights, resize, and remember frame via `setFrameAutosaveName("MainWindow")`.
- **Closing the window doesn't terminate the app** (it's a menu-bar app). Implement `NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed` returning `false`, and on window close: `NSApp.setActivationPolicy(.accessory)` so the Dock icon vanishes again.
- **Settings window** uses the same activation-policy dance.
- **Hotkey to show/hide** the main window is a high-value v2 add — use `MASShortcut` or hand-roll via `RegisterEventHotKey`. Surface in the General settings pane.

### Sources

- `https://sparkle-project.org/documentation/`
- `https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution`
- `https://gist.github.com/jamieweavis/b4c394607641e1280d447deed5fc85fc` (sips/iconutil flow)
- `https://github.com/sindresorhus/Settings`
- `https://sarunw.com/posts/how-to-make-macos-menu-bar-app/`

---

## Recommended build order for the 2 parallel agents

Split the work along the obvious seam: **UI Agent** owns visible surfaces; **Voice/IPC Agent** owns the data plane. They share `AppDelegate` and a small `AppState` ObservableObject; everything else is independent.

### Agent A — "UI / Production Polish"

Owns:
1. Convert the existing single-file menu-bar app into a **proper `.app` bundle structure** with a real `MainWindowController` (per §5.5). Status item stays; main window is new.
2. Build the **transcript pane** as the primary content of the main window — `NSTableView` or `NSScrollView` containing an `NSTextView`-per-row layout. Bind to `AppState.transcriptEntries` (which Agent B fills).
3. Wire **Sparkle 2.x** per §5.1 — Package.swift dep, Info.plist keys, `SPUStandardUpdaterController` in AppDelegate, "Check for Updates…" menu item.
4. Build the **Settings window** using `sindresorhus/Settings` per §5.4 with the five panes listed. The Voices pane reads from a `[VoiceOption]` list Agent B exports; the picker UI is Agent A's job, the option-list source-of-truth is Agent B's.
5. **Icon pipeline**: take William's source PNG (he'll provide), run sips/iconutil, place `AppIcon.icns` in `Resources/`, reference in Info.plist via `CFBundleIconFile`.
6. **Extend `build_app.sh`** with `RELEASE=1` mode: hardened-runtime codesign of nested Sparkle framework first, then the app; notarytool submit + wait; stapler staple; verification.
7. **Hotkey** for show/hide main window — General settings pane.

Decisions Agent A should follow from the research:
- §5.1 — Sparkle 2.7+ via SPM, EdDSA keys, GitHub Pages for appcast hosting.
- §5.3 — sips + iconutil pipeline, no SaaS.
- §5.4 — `sindresorhus/Settings` package, NSGridView per pane.
- §5.5 — `LSUIElement = true`, activation-policy dance, real `NSWindow` not `NSPopover`.
- §4 — implement the hallucination-filter UI affordance (greyed entry + report-as-hallucination right-click); the actual filter logic is Agent B.

### Agent B — "Voice / IPC / Data Plane"

Owns:
1. Build a **`SessionWatcher` actor** that scans `~/.claude/projects/` for active session JSONL files (mtime within last 5 min) and tails the most-recently-modified one via `DispatchSource.makeFileSystemObjectSource` (per §3, primary recommendation).
2. Build a **`TranscriptParser`** that consumes JSONL lines and emits `TranscriptEntry { id, role: .user|.assistant, text, timestamp, isHallucination: Bool }`. Filters where `message.content[]` includes a `tool_use` named `mcp__voicemode__converse` or its corresponding `tool_result`.
3. Build the **hallucination-filter** dictionary (per §4) — bundled `.json` resource of known phrases + user-additions file in Application Support. Filter sets `isHallucination: true`; doesn't drop.
4. Build the **`VoiceCatalog`** — a static list grouped as **OpenAI built-ins** (alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, marin, cedar) + **ElevenLabs** (only present when `ELEVENLABS_API_KEY` is set in the app's stored secrets) + **macOS Preview** (Daniel, Oliver, plus other installed `say -v ?` results parsed at runtime).
5. Build **voice-selection persistence** — when the user picks a voice in Settings, write env vars (`VOICEMODE_TTS_VOICE`, `VOICEMODE_TTS_MODEL`, `VOICEMODE_TTS_BASE_URLS`) to a launchd plist or a shell-rc snippet so the next `claude` launch picks them up. Document explicitly: a running Claude Code session is unaffected; user must restart it. Surface that in the UI.
6. Build the **ElevenLabs detection** — on Settings open, probe `http://127.0.0.1:4000/v1/models` (LiteLLM default port) with a 200ms timeout. If reachable AND `ELEVENLABS_API_KEY` set, enable the ElevenLabs section in the voice picker. Otherwise show "ElevenLabs (requires LiteLLM proxy — see docs)" greyed out with a help link to the README's setup section.
7. Build the **preview button** in the voice picker that pipes `say -v <name> "Sample sentence"` for macOS voices, and a one-shot HTTP call to the active TTS endpoint for OpenAI/ElevenLabs voices, playing the returned audio via `AVAudioPlayer`.

Decisions Agent B should follow from the research:
- §1 — exact env var names; ElevenLabs requires LiteLLM proxy because there's no native OpenAI-compatible endpoint.
- §2 — voice catalog composition; `onyx` is the recommended built-in default; ElevenLabs voices identified by Voice ID hash, not name.
- §3 — JSONL tailing is primary; conversation log is fallback to verify later, not v2-blocking.
- §4 — phrase list seeded from documented hallucinations; filter flags rather than drops; user-extensible via right-click.

### Shared contract

Both agents touch `AppState` (an `@MainActor`-isolated `ObservableObject`-equivalent built on Combine or NotificationCenter — repo is AppKit-only, no SwiftUI). Define this contract once, before either agent starts:

```
AppState exposes:
- transcriptEntries: [TranscriptEntry]    (Agent B writes, Agent A reads)
- voiceOptions: [VoiceOption]              (Agent B writes, Agent A reads)
- selectedVoice: VoiceOption?              (Agent A writes, Agent B reads + persists to env)
- micState: .idle | .listening | .speaking (existing — keep MicMonitor intact)
- activeSessionPath: URL?                  (Agent B writes, Agent A displays in title bar)
```

That's the only seam — keep it small and the two agents won't collide.

### Out of scope for v2 (note for the agents — do not start these)

- Patching VoiceMode upstream to add a Unix socket (long-term, separate workstream).
- Bundling LiteLLM as a Python sidecar (security, packaging, signing nightmare).
- True streaming transcript with sub-100ms latency (requires VoiceMode IPC support).
- iOS / iPadOS port (different surface).

---

**End of v2 architecture recommendation.**
