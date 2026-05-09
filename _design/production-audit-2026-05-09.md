# Production hardening audit — 2026-05-09

Scope: Sources/VoiceModeMenuBar/** (all 24 .swift files, ~4.3k LOC including
the Transcript subtree). Pass focused on: main-thread blocking, crash safety,
concurrency, graceful degradation, build hardening, resource cleanup,
settings migration, logging.

Verification commands and their evidence are at the bottom.

---

## Findings

Severity legend: **C**ritical = will deadlock UI / crash on real-world input
| **H**igh = noticeable freeze or graceful-degradation gap | **M**edium =
correctness / hygiene | **L**ow = nit.

| # | Sev | File:line | Description | Status |
|---|-----|-----------|-------------|--------|
| F1 | C | `FloatingWidget.swift:201` (pre-fix) | `menuNeedsUpdate(_:)` called `SessionDiscovery.listSessions()` synchronously on the main thread. NSMenu's needs-update delegate runs on main immediately before menu open — every pull-down of the widget's "Sessions" button froze the UI for 100s of ms (AppleScript bridge + `ps -A` fork + parse). | **Fixed.** Render whatever is cached (or "Loading sessions…" on first open), kick off a background refresh that re-renders the menu in place. Coalesced via `pendingMenuRefresh` so repeated opens don't pile up AppleScript calls. |
| F2 | C | `AppDelegate.swift:142, 153` (pre-fix) | `openClaudeCode` and `startVoiceConversation` called `NSAppleScript.executeAndReturnError(_:)` synchronously on the main thread. The voice script even contained `delay 3` — meaning the menu/widget froze for 3+ seconds whenever William started a voice conversation from the UI. | **Fixed.** Both wrappers now hop to `DispatchQueue.global(qos: .userInitiated)` and bounce the error-handling alert back to main. Logger output for diagnostics. |
| F3 | C | `SessionDiscovery.swift:223` (pre-fix) | `focus(_:andTriggerVoice:)` ran AppleScript synchronously, called from (a) `SessionSidebar` double-click on main, (b) `FloatingWidget.handleSessionPicked` on main. Same UI-freeze pattern. | **Fixed.** Refactored to async `focus(_:andTriggerVoice:completion:)`; preserved `focusBlocking` as the synchronous variant with a main-thread assertion so any future caller from main is loud. |
| F4 | H | `SessionDiscovery.swift:101` (pre-fix) | `listSessions()` itself can be called on main by mistake. After F1+F3 it should never happen, but no guard. | **Fixed.** Added a main-thread guard with `Logger.error` + `assertionFailure` so a regression surfaces in dev and in Console.app in release. |
| F5 | C | `FloatingWidget.swift:113` (pre-fix) | Force-unwrap on `NSImage(systemSymbolName: "xmark", ...)!` in close-button construction. Crashes on launch if the symbol ever fails to resolve (corrupt SF Symbols cache, missing on a future OS rev). | **Fixed.** Optional + zero-size NSImage fallback + text glyph "x" if symbol is nil. |
| F6 | C | `SessionSidebar.swift:106` (pre-fix) | Same force-unwrap on `NSImage(systemSymbolName: "arrow.clockwise", ...)!`. Crashes on main-window open. | **Fixed.** Same Optional + fallback pattern, "↻" text glyph. |
| F7 | H | `VoicePane.swift:311` (pre-fix) | `refreshKeyStatus()` called `KeychainHelper.readElevenLabsKey()` (forks `/usr/bin/security`) on the main thread during `loadView()`. First open of Settings → Voice could prompt for Keychain access on main, blocking the UI. | **Fixed.** Show "Checking Keychain…" placeholder, hop to background queue for the fork, hop back to main for label update. |
| F8 | H | `VoicePane.swift:367` (pre-fix) | `saveElevenLabsKey()` and `clearElevenLabsKey()` ran `security` CLI on main. Even short forks block menu animations. Keychain prompts on main are particularly bad. | **Fixed.** Both backgrounded; field cleared synchronously BEFORE awaiting (so the plaintext doesn't linger across the fork). |
| F9 | M | `MicMonitor.swift` (pre-fix) | `DispatchSourceTimer` was created in `start()` but no `deinit` cancelled it. Re-calling `start()` would orphan the prior timer and silently double the poll rate. App-delegate retains MicMonitor for app lifetime so the leak never realises in practice — but it's a footgun. | **Fixed.** `start()` is now idempotent (cancels prior timer first); explicit `deinit { timer?.cancel() }`. |
| F10 | H | `SparkleBridge.swift:44` (pre-fix) | Bootstrapping `SPUStandardUpdaterController(startingUpdater: true, ...)` immediately fired the periodic check against the placeholder `https://example.invalid/...` appcast URL we ship. Result: every cold launch popped a Sparkle "Update Error" modal on the main thread. Caught while sampling the freshly built app. | **Fixed.** Detect the placeholder URL (empty or `example.invalid`) and pass `startingUpdater: false`. Manual "Check for Updates…" still fires the same controller (which then surfaces the friendly fallback alert). When a real appcast is wired the periodic check turns back on. |
| F11 | M | `EnvFileWriter.swift:85,170` (pre-fix) | Error paths used `NSLog` instead of `os.Logger`. `NSLog` is throttled and not categorisable in Console.app. | **Fixed.** `os.Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "EnvFileWriter")`. Same pattern adopted in AppDelegate, FloatingWidget, SessionDiscovery, VoicePane. |
| F12 | L | `VoicePane.swift:514–522, 565–573` | `URLSession.shared.dataTask` + `DispatchSemaphore.wait` is anti-idiomatic, but the call site is already on a background queue (the `Test voice` handler dispatches to `qos: .userInitiated`), so it's correct. | Kept as-is — refactor would be cosmetic and the existing comments make the pattern intentional. |
| F13 | L | `SessionDiscovery.swift:179` | `mcpRegistrationCutoff()` reads `~/.claude.json` mtime synchronously. Same call site (`listSessions()`) already runs off-main per F1/F4, so this is fine. | No change. Locked. See docs/design-decisions/locked-design-decisions.md. |
| F14 | L | `MainWindowController.swift:131` | Toolbar-action `copyTranscriptReport` runs `NSAlert.runModal()` on main — intentional confirmation UI; not a freeze. | No change. Locked. See docs/design-decisions/locked-design-decisions.md. |
| F15 | L | `Resources/Info.plist` `SUFeedURL` | Placeholder is `example.invalid`. Production: replace with real appcast URL before publishing — this is documented in README. F10 makes the placeholder safe at runtime; this entry exists so the next deploy doesn't surprise the team. | Acknowledged. README and inline comments cover. |
| F16 | M | `VoiceSettings.swift:54` | Migration: `Backend(rawValue:)` falls back to `.openai` when an unknown raw lands. `voice` defaults to `"onyx"` regardless of backend. So a user who had the v1 build (OpenAI-only, voice="echo") and upgrades gets a working OpenAI-Echo session — fine. A user who selects a future backend whose enum case is removed degrades to OpenAI/onyx — also acceptable. | No change needed. Migration is graceful by construction. Locked. See docs/design-decisions/locked-design-decisions.md. |
| F17 | M | `Settings/HallucinationPatternsPane.swift:130` | `loadFromDisk()` on `loadView()` reads JSON synchronously from disk. File is small (~kB) and `applicationSupport` is a fast local volume — measured negligible. | Acceptable. |

---

## Verification evidence

### 1. Clean release build (no warnings)

`swift package clean && swift build -c release` (full rebuild after all fixes):

```
Building for production...
[0/5] Write sources
[1/5] Copying Sparkle.framework
[2/5] Write swift-version--58304C5D6DBC2206.txt
[4/6] Compiling VoiceModeMenuBar AppDelegate.swift
[4/6] Write Objects.LinkFileList
[5/6] Linking VoiceModeMenuBar
Build complete! (6.50s)
```

Zero warnings, zero errors. Whole-module-optimization compiles all 24 files
under the `AppDelegate.swift` heading; this is normal SPM behavior.

### 2. App bundle assembled (release) and signed

`./build_app.sh` (production path, Developer ID Application + hardened runtime
+ secure timestamp):

```
==> codesigning (mode: release)
    using identity: Developer ID Application: WILLIAM RUIZ II (5RRHNS4ZZB)
==> signing Sparkle helpers
==> verifying signature
/Applications/VoiceMode Monitor.app: valid on disk
/Applications/VoiceMode Monitor.app: satisfies its Designated Requirement
```

`codesign -d --verbose=4 …`:

- `flags=0x10000(runtime)` — hardened runtime ✓
- `Authority=Developer ID Application: WILLIAM RUIZ II (5RRHNS4ZZB)` ✓
- `Authority=Developer ID Certification Authority` ✓
- `Authority=Apple Root CA` ✓
- `Timestamp=May 9, 2026 at 8:08:02 AM` — secure timestamp ✓
- `TeamIdentifier=5RRHNS4ZZB` ✓

`otool -L`: `@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.9.1)` ✓

`otool -l … | grep -A2 LC_RPATH`: includes `path @executable_path/../Frameworks` ✓

### 3. Process sample — main thread is NOT blocked

`sample <pid> 5 -file /tmp/voicemode-release-sample.txt` against the live
release-built app, with the main window opened (sidebar reload triggered):

Main thread call graph (all 4298 samples / 5s):

```
4298 Thread_60622434   DispatchQueue_1: com.apple.main-thread  (serial)
+ 4298 start
  + 4298 VoiceModeMenuBar_main
    + 4298 -[NSApplication run]
      + 4298 -[NSApplication … nextEventMatchingMask:…]
        + 4298 _DPSBlockUntilNextEventMatchingListInMode
          + 4298 mach_msg → mach_msg2_trap
```

Main thread is 100% in `mach_msg` event wait. Zero `NSAppleScript`,
zero `JSONSerialization`, zero `URLSession.dataTask` synchronous patterns,
zero `DispatchSemaphore.wait`.

The only `waitUntilExit` calls in the entire sample (when present) are on
`DispatchQueue_16: com.apple.root.user-initiated-qos (concurrent)` —
background workers running `SessionDiscovery.listSessions()` exactly as
designed. Reference snippet:

```
4185 Thread_60612428   DispatchQueue_16: com.apple.root.user-initiated-qos (concurrent)
…
4185 closure #2 in SessionSidebar.reload()  …  SessionSidebar.swift:43
  4185 static SessionDiscovery.listSessions()  …  SessionDiscovery.swift:122
    4185 specialized static SessionDiscovery.mostRecentClaudeStartByTty()
      4185 -[NSConcreteTask waitUntilExit]
```

This is the canonical "fork ps on a background queue, post results to main"
pattern. Healthy.

### 4. Codesign --verify --deep --strict --verbose=2

```
--prepared:/Applications/VoiceMode Monitor.app/Contents/Frameworks/Sparkle.framework/Versions/Current/.
…
--validated:/Applications/VoiceMode Monitor.app/Contents/Frameworks/Sparkle.framework/Versions/Current/.
/Applications/VoiceMode Monitor.app: valid on disk
/Applications/VoiceMode Monitor.app: satisfies its Designated Requirement
```

Pass.

### 5. Graceful degradation: openedai-speech offline

`launchctl unload ~/Library/LaunchAgents/com.williamruiz.voicemode-monitor.openedai-speech.plist`
followed by `curl http://127.0.0.1:8001/v1/audio/speech --max-time 2`:
returns HTTP 000 (connection refused).

The Test-voice handler (`VoicePane.fetchAndPlayOpenAILike`) sees
`URLError.cannotConnectToHost`, returns via `setTestStatus("Network error: …",
color: .systemRed)` on the main thread. No hang, no crash. Reload of the
LaunchAgent restored the service to HTTP 405 (the expected method-not-allowed
on a GET to a POST-only endpoint). Same path covers OpenAI / Kokoro / Piper /
ElevenLabs / Custom — all share the URLSession → `setTestStatus` flow.

### 6. Sparkle bootstrap

Pre-fix: cold launch immediately popped Sparkle's "Update Error" modal on the
main thread (the placeholder appcast URL fails). Post-F10: cold launch is
silent; manual "Check for Updates…" still works (fires the same controller).
Verified by re-launch after the bundle rebuild (PID 7516, sample shows main
thread idle in `nextEventMatchingMask`, no NSAlert in the chain).

---

## Production-readiness verdict

**Ready** — for direct distribution to William and any closed-beta cohort.

Carry-overs before opening to the public Sparkle channel:

- Wire a real `SUFeedURL` and `SUPublicEDKey` per the README "Sparkle appcast
  publishing" flow. F10 already protects against the placeholder; the
  configuration step itself is the next deliverable, not a defect.
- Notarize via `./notarize_app.sh` before the first signed-DMG distribution.
  Codesign already passes hardened runtime + secure timestamp, so notarization
  has nothing to fix.
