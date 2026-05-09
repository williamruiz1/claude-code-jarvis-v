# F12 — URLSession async refactor (Test voice handler)

**Severity:** Low (cosmetic / idiomaticity)
**Audit cross-ref:** `_design/production-audit-2026-05-09.md` row F12
**Component:** Settings — Voice pane
**Status:** Open

---

## Summary

The "Test voice" button in the Voice settings pane uses `URLSession.shared.dataTask` paired with a `DispatchSemaphore.wait()` to block the calling thread until the HTTP response arrives. The pattern is correct (the call site is already on a `DispatchQueue.global(qos: .userInitiated)` queue, so blocking it is harmless), but it is anti-idiomatic on macOS 13+ where `URLSession`'s `async`/`await` API is available. Replace the semaphore-blocked `dataTask` with the modern API and remove `DispatchSemaphore` from this flow.

---

## Current behavior

The Test-voice flow (entry point: `testVoice()` at `Sources/VoiceModeMenuBar/Settings/VoicePane.swift:419`) dispatches to a background queue and then calls one of two helpers depending on the selected backend:

1. **`fetchAndPlayOpenAILike(...)`** — used for OpenAI / Kokoro / Piper / Custom backends.
   `Sources/VoiceModeMenuBar/Settings/VoicePane.swift:541-549`
   ```swift
   let sem = DispatchSemaphore(value: 0)
   var data: Data?
   var http: HTTPURLResponse?
   var err: Error?
   URLSession.shared.dataTask(with: req) { d, r, e in
       data = d; http = r as? HTTPURLResponse; err = e
       sem.signal()
   }.resume()
   sem.wait()
   ```

2. **`fetchAndPlayElevenLabs(...)`** — used for the ElevenLabs backend.
   `Sources/VoiceModeMenuBar/Settings/VoicePane.swift:592-600`
   ```swift
   let sem = DispatchSemaphore(value: 0)
   var data: Data?
   var http: HTTPURLResponse?
   var err: Error?
   URLSession.shared.dataTask(with: req) { d, r, e in
       data = d; http = r as? HTTPURLResponse; err = e
       sem.signal()
   }.resume()
   sem.wait()
   ```

Each call site then proceeds synchronously — checks the error, validates the HTTP status (`200..<300`), and on success hands the audio data to `playAudio(...)`.

> Note: line numbers above reflect the file as of 2026-05-09. Re-verify before editing — the file is ~660 lines and may have drifted.

---

## Desired behavior

Replace the `DispatchSemaphore` + `dataTask` pattern with `URLSession`'s native async API. Two acceptable shapes:

### Option A (preferred) — async/await throughout

Mark the helpers `async throws` and call them from a `Task { ... }` block inside `testVoice()`. The deployment target is macOS 13 (`Package.swift:22 → .macOS(.v13)`), so `URLSession.data(for:)` is available without any availability fences inside this target.

```swift
private func fetchAndPlayOpenAILike(...) async {
    // ... build req ...
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            await MainActor.run { setTestStatus("No HTTP response.", color: .systemRed) }
            return
        }
        // ... validate + playAudio + status update on MainActor ...
    } catch {
        await MainActor.run { setTestStatus("Network error: \(error.localizedDescription)", color: .systemRed) }
    }
}
```

`testVoice()` then wraps the dispatch in `Task.detached { await self.fetchAndPlayOpenAILike(...) }` (or equivalent). The existing `setTestStatus(...)` helper continues to be called — it should already hop to main internally; if not, wrap the call sites in `await MainActor.run { ... }`.

### Option B (acceptable) — completion-handler dataTask without semaphore

If keeping a non-async helper signature is preferred for surface stability, drop the semaphore and accept a completion closure:

```swift
private func fetchAndPlayOpenAILike(..., completion: @escaping () -> Void) {
    URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
        // ... validate + playAudio (off-main is fine for AVAudioPlayer init) ...
        // ... setTestStatus on main ...
        completion()
    }.resume()
}
```

The `testButton.isEnabled = true` re-enable that the current `defer { ... }` handles must be pulled out of `defer` and invoked inside the completion. Option A is cleaner — prefer it unless there's a reason not to.

---

## Acceptance criteria

1. **No `DispatchSemaphore` in the Test-voice flow.** `grep -n DispatchSemaphore Sources/VoiceModeMenuBar/Settings/VoicePane.swift` returns zero matches.
2. **Test voice still plays cleanly** for at least one OpenAI-compatible backend (OpenAI, Kokoro, Piper, or Custom) and for ElevenLabs. The sample sentence audio plays end-to-end.
3. **Error reporting unchanged.** A bad URL, a 4xx/5xx HTTP status, and a network error each surface the same colored status text in the pane (red / orange / green) with the same prefix wording. Body excerpt cap stays at 200 characters.
4. **`testButton` is re-enabled in all paths** — success, network error, HTTP error, malformed-URL early return. No way to leave the button stuck disabled.
5. **Builds cleanly** with `swift build` against `.macOS(.v13)` deployment target. No new compiler warnings introduced.

---

## Estimated effort

- ~30-45 lines net change across two helpers (`fetchAndPlayOpenAILike`, `fetchAndPlayElevenLabs`) plus the `testVoice()` dispatch
- ~25 minutes for an agent already familiar with Swift Concurrency
- ~45 minutes if refactoring across `MainActor` boundaries cleanly is unfamiliar territory

---

## Dependencies

None. Deployment target is already macOS 13; async URLSession is available. No new package dependencies needed.

---

## What NOT to change

- **Don't introduce SwiftUI.** This is an AppKit settings pane; keep it that way.
- **Don't change the visible UI shape** — same button, same status label, same colors, same wording prefixes (`Network error:`, `HTTP \(code) from \(host).`, `Played \(bytes) bytes from \(host).`, etc.).
- **Don't refactor unrelated handlers.** `runSay(...)` (which uses `Process` + `waitUntilExit`) is correct as-is; `saveAndPropagate()` is unrelated. Touch only the two URLSession helpers and their invocation in `testVoice()`.
- **Don't change the AVAudioPlayer playback path.** `playAudio(...)` is fine as-is.
- **Don't add new error categories.** The current three (network error, no HTTP response, non-2xx status) are sufficient.
- **Don't introduce a third-party HTTP client.**

---

## Notes

- `setTestStatus(...)` is called from background context today and the implementation should already marshal to main; verify before adding extra `MainActor.run { ... }` wrappers (don't double-hop).
- `playAudio(...)` constructs an `AVAudioPlayer` and starts playback; AVAudioPlayer can be initialized off the main thread but its delegate callbacks come back on the queue that called `play()`. Current code does this off-main and it works — preserve that behavior unless a reason emerges otherwise.
- The deployment target is also relevant for `URLSession.data(for:)` vs the older `URLSession.data(for:delegate:)` overloads — both are available on macOS 12+, so no fence needed at v13.
