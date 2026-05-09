# F17 — HallucinationPatternsPane async disk load

**Severity:** Medium (main-thread file I/O hygiene)
**Audit cross-ref:** `_design/production-audit-2026-05-09.md` row F17
**Component:** Settings — Hallucination Patterns pane
**Status:** Open

---

## Summary

`HallucinationPatternsPane.loadView()` reads `~/Library/Application Support/VoiceModeMonitor/hallucination-patterns.json` synchronously on the main thread. The file is small (~kB) and reads have been measured negligible, but main-thread disk I/O is anti-idiomatic and a hazard if the patterns list ever grows or the volume gets slow. Move the read to a background queue, paint a placeholder synchronously, and update the textview on main when the read completes.

---

## Current behavior

`Sources/VoiceModeMenuBar/Settings/HallucinationPatternsPane.swift:125`

```swift
override func loadView() {
    // ... build root view, install constraints ...
    view = root
    loadFromDisk()   // <-- synchronous main-thread read
}
```

`Sources/VoiceModeMenuBar/Settings/HallucinationPatternsPane.swift:130-147`

```swift
private func loadFromDisk() {
    let url = Self.patternsFilePath
    if let data = try? Data(contentsOf: url),
       let array = try? JSONDecoder().decode([String].self, from: data) {
        let text = array.joined(separator: "\n")
        textView.string = text
        lastLoadedText = text
        statusLabel.stringValue = "Loaded \(array.count) pattern\(array.count == 1 ? "" : "s") from disk."
    } else {
        let text = Self.seedPatterns.joined(separator: "\n")
        textView.string = text
        lastLoadedText = ""
        statusLabel.stringValue = "No file yet. Showing default seed list — Save to create."
    }
}
```

Both `Data(contentsOf:)` and `JSONDecoder().decode(...)` run on whatever thread called `loadFromDisk()`. From `loadView()` that's main; from `revertPressed()` (line 180) that's also main.

---

## Desired behavior

1. In `loadView()`, after building the view, paint a synchronous placeholder before any I/O:
   ```swift
   textView.string = ""
   statusLabel.stringValue = "Loading patterns…"
   ```
2. Refactor `loadFromDisk()` so the disk read and JSON decode run on a background queue, and the textview / status updates run on main:
   ```swift
   private func loadFromDisk() {
       let url = Self.patternsFilePath
       DispatchQueue.global(qos: .userInitiated).async { [weak self] in
           let result: (text: String, count: Int?, lastLoaded: String) = {
               if let data = try? Data(contentsOf: url),
                  let array = try? JSONDecoder().decode([String].self, from: data) {
                   let joined = array.joined(separator: "\n")
                   return (joined, array.count, joined)
               } else {
                   return (Self.seedPatterns.joined(separator: "\n"), nil, "")
               }
           }()
           DispatchQueue.main.async {
               guard let self else { return }
               self.textView.string = result.text
               self.lastLoadedText = result.lastLoaded
               if let n = result.count {
                   self.statusLabel.stringValue = "Loaded \(n) pattern\(n == 1 ? "" : "s") from disk."
               } else {
                   self.statusLabel.stringValue = "No file yet. Showing default seed list — Save to create."
               }
           }
       }
   }
   ```
3. `revertPressed()` continues to call `loadFromDisk()` — same hop happens, no special-casing needed.

> Note: line numbers above reflect the file as of 2026-05-09 (`HallucinationPatternsPane.swift` is ~197 lines). Re-verify before editing.

---

## Acceptance criteria

1. **Zero file I/O on the main thread when Settings opens.** Verifiable by setting a breakpoint at `Data(contentsOf:)` inside `loadFromDisk()` and confirming `Thread.isMainThread == false` at the breakpoint, OR by asserting `dispatchPrecondition(condition: .notOnQueue(.main))` immediately before the read in a debug build.
2. **Initial UI shows the placeholder.** When opening Settings → Hallucination Patterns for the first time in a session, the user sees `"Loading patterns…"` (or similar) in the status label before the pattern list materializes.
3. **Final UI is unchanged** — same textview content, same `"Loaded N patterns from disk."` / `"No file yet. Showing default seed list — Save to create."` status messages, same colors.
4. **`revertPressed()` still works.** Clicking "Revert" replaces the textview with the on-disk patterns (or seed list if missing) within ~1 frame.
5. **No race with user input.** If the user types into the textview before the load completes (unlikely given file size, but theoretically possible), the load result must NOT clobber their unsaved input. Acceptable mitigation: only apply the loaded text if `textView.string.isEmpty || textView.string == "<placeholder>"`. Document the chosen mitigation in code comment.

---

## Estimated effort

- ~20-25 lines net change to `loadFromDisk()` and `loadView()`
- ~15 minutes for an agent familiar with `DispatchQueue.global` + `DispatchQueue.main.async` patterns

---

## Dependencies

None.

---

## What NOT to change

- **Don't introduce Swift Concurrency (`async`/`await`)** for this file. Keep the GCD pattern — the rest of the file is callback-style AppKit and switching one method to `Task { ... }` creates inconsistency for marginal benefit.
- **Don't change the visible UI shape** — same textview, same status label position, same buttons, same wording.
- **Don't change the file format** (`[String]` JSON array) or the file path (`patternsFilePath`).
- **Don't refactor `writeToDisk(...)` or `savePressed()`** — those run on main currently and that's acceptable for now (user-initiated, small payload, atomic write).
- **Don't add a file watcher / reload-on-change mechanism** — out of scope; if needed, file separately.
- **Don't modify the `seedPatterns` list.**

---

## Notes

- `EnvFileWriter.supportDir` is referenced via `Self.patternsFilePath`; that property is fine to read off-main (URL composition only, no I/O).
- The pane is a `NSViewController`. `loadView()` runs on main by AppKit contract — preserve that. The hop is from inside `loadView()` outward, not the reverse.
- If the read genuinely takes <1ms on William's hardware, the placeholder may flash imperceptibly — that's fine. The discipline (no main-thread I/O) is what we're after, not user-visible loading UX.
