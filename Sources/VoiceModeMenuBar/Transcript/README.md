# Transcript subsystem

Self-contained module that owns the voice-conversation transcript pane.
Implements the v2 transcript spec ratified 2026-05-09 (see
`~/.claude/projects/-Users-williamruiz/memory/feedback_voice_transcript_format.md`).

## Pieces

| File | Role |
| ---- | ---- |
| `TranscriptStore.swift` | Model. Ordered `Turn`s, JSONL persistence per session, NSNotification fan-out on insert. |
| `TranscriptSource.swift` | Input adapter protocol + `ClaudeSessionJsonlAdapter` that tails Claude Code session JSONL files for `mcp__voicemode__converse` calls. |
| `HallucinationDetector.swift` | Pure function. Whisper "like and subscribe" guard. User-extensible via `~/Library/Application Support/VoiceModeMonitor/hallucination-patterns.json`. |
| `TranscriptView.swift` | NSView. Scrollable rich-text feed. Two render modes (minimal / chrome). Persists mode in UserDefaults under `voicemode-monitor.transcript.mode`. |
| `TranscriptToggleControl.swift` | NSView. NSSegmentedControl labelled "Minimal | Full". Wires to `TranscriptView` via NotificationCenter. |
| `EndOfSessionReportGenerator.swift` | Pure function. Markdown dump of the full transcript with both sides timestamped. `copyToClipboard(...)` helper. |

## Wiring (host responsibility)

The module is self-contained — it does NOT touch `AppDelegate`, `FloatingWidget`,
or any existing file. A host (the AppDelegate or the future MainWindow) wires
it together like this:

```swift
// 1. Build the store for the active voice session.
let store = TranscriptStore(sessionId: claudeSessionId)

// 2. Start tailing the Claude Code session JSONL.
//    Project hash for ~/code/voicemode-menubar is e.g. "-Users-williamruiz-code-voicemode-menubar".
//    For a session running outside any cwd, use "-Users-williamruiz".
let source = ClaudeSessionJsonlAdapter(
    store: store,
    claudeSessionId: claudeSessionId,
    projectDirHash: projectDirHash
)
source?.start()

// 3. Mount the view + toggle wherever the host wants.
let transcriptView = TranscriptView(store: store, frame: containerView.bounds)
transcriptView.autoresizingMask = [.width, .height]
containerView.addSubview(transcriptView)

let toggle = TranscriptToggleControl(frame: .zero)
toolbarView.addSubview(toggle)

// 4. End-of-session report — wire to a "Copy transcript" button or a
//    "Generate report" menu item.
EndOfSessionReportGenerator.copyToClipboard(store: store, sessionName: "<tab title>")
```

## Notification contract

| Name | Posted by | userInfo |
| ---- | --------- | -------- |
| `TranscriptStore.didAppendTurn` | `TranscriptStore.append(_:)` (main thread) | `{ "turn": Turn, "sessionId": String }` |
| `TranscriptView.modeDidChange` | `TranscriptView.setMode(_:)` and `TranscriptToggleControl` (main thread) | `{ "mode": String }` (rawValue of `TranscriptRenderMode`) |

Hosts that own multiple stores at once must filter on
`note.userInfo["sessionId"]` because the notification name is global.

## Persistence layout

```
~/Library/Application Support/VoiceModeMonitor/
├── sessions/
│   ├── <sessionId-1>.jsonl       # one Turn per line, ISO-8601 timestamps
│   └── <sessionId-2>.jsonl
└── hallucination-patterns.json   # optional, [String]; merged with seed list
```

## Spec compliance notes

- **Default mode is minimal.** UserDefaults read in `TranscriptView.init` falls
  back to `.minimal` when the key is missing.
- **No clock round-trip per render.** Timestamps are captured at `append` time
  on the model and stored on the `Turn`. Render reads `turn.timestamp` only.
- **No preface text in voice replies.** Out of scope for the transcript module;
  enforced by the converse-call author (Claude Code itself).
- **End-of-session report includes both sides** even when minimal mode hid
  William's turns live. `EndOfSessionReportGenerator` walks `store.snapshot()`
  unconditionally.
- **Hallucination guard.** Detector seeds the spec list and merges any
  user-supplied JSON. When the JSONL adapter detects one, it appends both the
  flagged user turn AND a system turn with the canonical
  "(STT hallucination on silence — input ignored)" message — minimal mode
  suppresses both (only Claude's reply shows); chrome mode renders the user
  turn dimmed with the inline annotation.
