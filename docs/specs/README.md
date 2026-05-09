# Specs

Future-work specs for `voicemode-menubar`. Each file describes a single change scoped tightly enough that an agent (or future-William) can pick it up cold and execute without prior context.

## Format

Every spec includes:

- Title + severity + audit-finding cross-ref (when applicable)
- Current behavior with file/line snippets
- Desired behavior
- Acceptance criteria (testable)
- Estimated effort
- Dependencies
- What NOT to change

When a spec ships, leave the file in place and add a `**Status:** Shipped (PR #NN, YYYY-MM-DD)` line near the top.

## Index

| Spec | Severity | Component | Status |
|---|---|---|---|
| [F12 — URLSession async refactor (Test voice handler)](./F12-urlsession-async-refactor.md) | Low | Settings / Voice pane | Open |
| [F15 — Sparkle appcast publishing (enable auto-updates)](./F15-sparkle-appcast-publishing.md) | Low | Release process / Sparkle | Open |
| [F17 — HallucinationPatternsPane async disk load](./F17-hallucination-pane-async-load.md) | Medium | Settings / Hallucination Patterns pane | Open |

## Conventions

- File names are kebab-case and start with the audit ID when one exists (e.g. `F12-…`, `F17-…`). Specs without an audit lineage start with a topic prefix instead (e.g. `transcript-buffer-resize.md`).
- Cross-reference the audit at `_design/production-audit-2026-05-09.md` (or its successor) when the spec originates from one.
- New specs land here. Don't sprawl spec files into `_design/` — that's for higher-level design docs and post-mortems.
