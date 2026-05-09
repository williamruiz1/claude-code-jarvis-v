# Locked Design Decisions

This document lists patterns in the `voicemode-menubar` codebase that **look like bugs at first glance but are intentional and correct by design**. Each entry was raised in a production-hardening audit, reviewed, and explicitly closed as "no fix needed — here is why." The rationale is locked here so it does not have to be re-derived every time someone new reads the code.

**For future audit passes:** consult this doc BEFORE filing a finding against any pattern listed here. If you believe the rationale no longer holds (e.g. the surrounding code changed and the precondition no longer applies), say so explicitly in the new audit and propose a behavioral change — do not silently re-flag the same pattern.

**For future contributors:** do NOT "improve" or refactor these patterns without a documented behavioral change and an explicit override of the lock. The patterns are load-bearing in subtle ways (threading discipline, user-experience contract, graceful degradation). A well-meaning cleanup that misses the rationale will regress real behavior.

Audit findings remain in `_design/production-audit-*.md`. This file is the persistent reference; the audit files are the historical record.

---

## F13 — Synchronous mtime read in `mcpRegistrationCutoff()`

- **File:** `Sources/VoiceModeMenuBar/SessionDiscovery.swift` ~line 179
- **Audit finding:** F13 (Low). See [`_design/production-audit-2026-05-09.md`](../../_design/production-audit-2026-05-09.md).
- **Locked on:** 2026-05-09

### What it looks like

`mcpRegistrationCutoff()` calls a synchronous filesystem `stat` (mtime read) on `~/.claude.json` with no `await`, no completion handler, and no explicit dispatch. To a reader scanning for "anything synchronous touching disk," this is a red flag.

### Why it is correct

The function has exactly one caller: `listSessions()`. `listSessions()` is enforced off the main thread by a thread guard added in the F4 fix — it cannot execute on the main queue. So by the time `mcpRegistrationCutoff()` runs, we are already on a background queue, and a synchronous filesystem stat is the natural, clearest way to express the read.

A filesystem stat against a local file is fast. The alternative — wrapping it in an async boundary or a callback — would add indirection without changing the wall-clock cost or the safety of the call. The whole `listSessions()` data flow is a linear pipeline; introducing an async hop in the middle of it for cosmetic reasons would make the function harder to read.

### Risk if changed

Converting this to async/callback-based would:

- Add a callback boundary mid-pipeline that complicates the otherwise linear `listSessions` data flow.
- Force every caller (current and future) to await, even though the work doesn't need it.
- Provide zero user-visible benefit — the operation is already off-main.

In short: more code, more indirection, no behavioral improvement.

---

## F14 — `NSAlert.runModal()` on main thread in transcript-copy confirmation

- **File:** `Sources/VoiceModeMenuBar/MainWindow/MainWindowController.swift` ~line 131
- **Audit finding:** F14 (Low). See [`_design/production-audit-2026-05-09.md`](../../_design/production-audit-2026-05-09.md).
- **Locked on:** 2026-05-09

### What it looks like

The `copyTranscriptReport` toolbar action calls `NSAlert.runModal()` on the main thread. To a reader scanning for "anything blocking on main," this looks like a UI-thread freeze.

### Why it is correct

This is the explicit "transcript copied to clipboard" confirmation alert that appears after the user copies a transcript. **Modal alerts SHOULD block the user briefly — that is the entire point of a modal dialog.** This isn't a freeze; it's user-acknowledged synchronous UI. The user pressed a button, a confirmation alert appears, the user dismisses it, the app continues. That is exactly the contract macOS users expect from a confirmation dialog.

The macOS Human Interface Guidelines explicitly endorse modal alerts for short confirmations of user-initiated actions. This is the textbook use case.

### Risk if changed

If converted to a non-modal sheet or a transient toast, the UI would violate user expectations:

- A confirmation dialog that the user can ignore or that disappears on its own breaks the "I did the thing, please confirm" feedback loop.
- A non-modal sheet still blocks the parent window — same effective behavior, more code.
- A toast is appropriate for *passive* notifications (e.g. background save completed), not for confirming a user-initiated action.

The current implementation is the right pattern.

---

## F16 — Settings v1 → v2 migration falls back to OpenAI/onyx for unknown values

- **File:** `Sources/VoiceModeMenuBar/Settings/VoiceSettings.swift` ~line 54
- **Audit finding:** F16 (Medium). See [`_design/production-audit-2026-05-09.md`](../../_design/production-audit-2026-05-09.md).
- **Locked on:** 2026-05-09

### What it looks like

The migration code uses `Backend(rawValue:)` and falls back to `.openai` when the raw value isn't recognized. The `voice` field defaults to `"onyx"` regardless of which backend was previously configured. To a reader thinking about strict validation, this looks lossy — "we're losing the user's previous selection on edge cases."

### Why it is correct

This is **graceful degradation by construction**. There are three scenarios this code has to survive, and the lenient fallback handles all three:

1. **v1 user upgrading to v2.** Original v1 build was OpenAI-only with voice="echo". On migration, the backend raw value resolves to `.openai` and the voice resolves to `"echo"` (or to `"onyx"` if the value is missing entirely). Either way, the user lands in a working OpenAI session. Nothing breaks.

2. **User on a future v3 with a backend case that is later removed (e.g. a deprecated provider).** The unknown raw value falls back to `.openai`, voice falls back to `"onyx"`. The user still has a functional session and just needs to re-pick their preferred backend in Settings. They don't see a crash or a broken-empty state.

3. **Corrupted `UserDefaults` entry.** Same fallback path. The user gets a default-but-functional session and can reconfigure.

In all three scenarios the user **never sees a crash, never sees an empty/broken state, and can always recover by re-selecting their preferences**. That is the right tradeoff for a personal-use menu-bar utility where uninterrupted launch is far more valuable than strict preservation of every legacy preference value.

### Risk if changed

Replacing the lenient fallback with stricter validation (e.g. throwing an error, refusing to launch, surfacing a "settings corrupted" modal) would introduce a "first-launch-after-upgrade is broken" failure mode for some subset of users. Specifically:

- Anyone who upgrades through a backend that's later renamed or removed would hit a broken state on first launch.
- Anyone whose `UserDefaults` got corrupted (rare but real — disk full, force-quit during write) would be locked out of the app instead of getting a working default.

Both failure modes are **strictly worse than silently using a sensible default**. The cost of a stricter check is real harm to real users; the benefit (catching invalid values earlier) is hypothetical and chiefly serves developer aesthetics.

---

## How entries get added here

A finding from an audit (`_design/production-audit-*.md`) becomes a locked design decision when **the audit itself explicitly closes it as "no fix needed, here's why."** When that happens:

1. Copy the rationale into a new section in this file using the same structure as F13/F14/F16 above (title, file:line, audit finding ID + cross-link, "what it looks like," "why it is correct," "risk if changed," "locked on" date).
2. Annotate the corresponding line in the audit doc with: `Locked. See docs/design-decisions/locked-design-decisions.md.`
3. Leave the audit finding intact — the audit is the historical record, this file is the persistent reference.

Audit findings that are *fixed* (not locked) do not belong here — they're already resolved in code. Only findings that are explicitly **closed without a fix because the pattern is correct** get an entry.

If a future audit revisits a locked decision and concludes the rationale no longer holds (e.g. the surrounding precondition has changed), the proper move is: open a new audit finding, propose a behavioral change, and once that change is implemented, remove (or rewrite) the corresponding entry here. Do not silently delete entries.
