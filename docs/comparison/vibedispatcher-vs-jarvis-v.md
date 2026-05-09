# Comparison: VibeDispatcher vs. Claude Code Jarvis V

**Date:** 2026-05-09
**Author:** Marginalia Coordinator (Claude Opus 4.7)
**Purpose:** Identify capability overlap, unique value per tool, and where pulling shared code or features across the two would compound rather than fragment.

---

## TL;DR

VibeDispatcher (VD) and Claude Code Jarvis V (CCJV) solve adjacent problems with **30-40% architectural overlap** and **~5 high-value reusable subsystems**. They are not competitive products — they live on different surfaces (VD = VS Code + mobile, CCJV = Claude Code CLI). The synergy lies in **extracting shared substrate libraries** (TTS abstraction, Whisper hallucination filter, Keychain helper, floating-widget pattern, Terminal session discovery) so neither has to maintain divergent versions of the same primitives. There is also a **strategic synergy at the surface level**: VD's mobile Beacon could surface CCJV's voice transcripts, and CCJV's session discovery could feed VD's workspace list — turning the pair into a unified voice-control fabric across all of William's coding environments.

---

## At-a-glance feature map

### VibeDispatcher — VS Code-centric voice command center

| Layer | What it does |
|---|---|
| Menu bar app (Swift) | Status item, manages voice + core child processes, hotkey, away toggle |
| Voice process (Swift) | TTS, STT, AlertDispatcher, trickle queue, intent parsing |
| Core (Node.js) | Orchestrator, action registry, away mode, IPC server |
| VS Code extension (TS) | Per-workspace IPC, terminal monitoring, agent state detection |
| Away Relay (Node.js + Fly.io) | Cloud bridge for mobile, SSE streaming, push notifications |
| Beacon PWA (TS + Vite) | Mobile web app for remote monitoring/control |

### Claude Code Jarvis V — Claude Code CLI voice frontend

| Layer | What it does |
|---|---|
| Menu bar app (Swift) | Status item, mic state observation, brand wordmark, settings |
| Floating widget (Swift) | Always-on-top HUD with quick-pick voice + toggle row |
| Main window (Swift) | Sessions sidebar + transcript pane + toolbar |
| Settings panel (Swift) | Voice picker (5 backends), hallucination patterns, About + updates |
| TranscriptCoordinator (Swift) | Tails Claude Code session JSONL for live transcript |
| MCP wrapper (sh + .claude.json) | Injects OPENAI_API_KEY from Keychain into VoiceMode at MCP-launch time |
| openedai-speech LaunchAgent | Local Piper TTS server (Jarvis voice + 3 fallback voices) |

---

## The Venn — overlap, unique-to-each, and the white space

### 🟧 Overlap — shared primitives both tools maintain independently

These are the load-bearing patterns where today VD and CCJV each have their own implementation. **High-value extraction targets.**

| Capability | VD implementation | CCJV implementation | Extraction opportunity |
|---|---|---|---|
| **Multi-backend TTS** | `Speaker.swift` (macOS `say` + ElevenLabs) | `VoiceCatalog.swift` + `EnvFileWriter.swift` (OpenAI / Kokoro / Piper / ElevenLabs / macOS / Custom) | **High.** CCJV's catalog is more complete; could become the canonical voice library. |
| **Multi-backend STT** | `SpeechRecognizer.swift` (Apple) + `WhisperRecognizer.swift` (whisper.cpp) | OpenAI Whisper API via VoiceMode | **Medium.** VD's whisper.cpp wrapper is production-tested; CCJV could adopt for offline mode. |
| **Whisper hallucination filtering** | Implicit handling in ConversationWatcher | `HallucinationDetector.swift` (canonical seed list + user-extensible JSON) | **High.** CCJV's detector is the cleanest implementation; VD could adopt directly. |
| **Floating panel UI (NSPanel HUD)** | `TricklePanelController.swift` (6 modes: idle/playing/trickle/paused/returning/draft) | `FloatingWidget.swift` (idle/active states + quick-pick + toggle row) | **Medium.** Both built bespoke; could share an `NSPanelHUD` framework. |
| **Keychain-stored API keys** | `~/.vibedispatcher/secret` + `config.yaml` | `KeychainHelper.swift` + `security` CLI per the canonical pattern in `~/.claude/rules/mcp-integration.md` | **High.** CCJV uses macOS Keychain canonically; VD reads a flat file and is overdue for the upgrade (per its own Regression Report C2). |
| **Session/agent discovery** | `AgentMonitor.ts` (per-VS Code window) + `TerminalMonitor.swift` (non-VS Code terminals) | `SessionDiscovery.swift` (Terminal.app via AppleScript with status badge parsing) | **Medium.** Different surfaces; CCJV's badge-parsing logic could enrich VD's terminal monitor. |
| **Settings persistence (UserDefaults / config files)** | `config.yaml` | `UserDefaults` + `voicemode-env.sh` written from settings | **Low.** Different conventions; not worth unifying. |
| **macOS menu bar status item** | `AppDelegate.swift` (status item + hotkey + Away toggle) | `AppDelegate.swift` (status item + main-window opener + transcript copy) | **Low.** Trivial pattern; not worth abstracting. |

### 🟦 Unique to VibeDispatcher — what CCJV doesn't have

- **Mobile PWA "Beacon" + cloud relay** — entire away-mode capability with push notifications, SSE event streaming, command queue. Big build; CCJV has no equivalent.
- **VS Code extension** — per-workspace IPC, terminal output buffer, command whitelist, diagnostics streaming. Tied to VS Code surface.
- **Multi-workspace agent monitoring** — watches multiple Claude-in-VS-Code instances simultaneously with workspace-aware command routing (`@workspace-name`).
- **AI-powered intent routing** — `ClaudeRouter.swift` uses Claude Haiku to route voice replies to the right action; CCJV uses a hardcoded trigger phrase.
- **Trickle alert queue** — sophisticated alert management with auto-pause / quick-pause / auto-advance / replay. CCJV has no alert concept.
- **Away mode + escalation** — push notifications fired when alerts go unaddressed, regardless of mode.
- **Confirmation flow** — voice-based yes/no confirmation for destructive actions.
- **Hotkey push-to-talk + media key control** — global system-wide shortcuts.
- **macOS notification center observer** — watches iMessage, Slack, etc.

### 🟨 Unique to Claude Code Jarvis V — what VD doesn't have

- **Claude Code CLI integration** — operates against the claude command-line REPL via Terminal.app, not a VS Code extension. Surface VD doesn't reach.
- **JARVIS voice install path** — `scripts/install-piper-jarvis.sh` provisions Piper + the `jgkawell/jarvis` model + `openedai-speech` server + LaunchAgent end-to-end. VD has no Piper integration.
- **MCP wrapper for OpenAI key injection** — solves the "claude session inherits stale env" problem at the MCP-server-launch-time layer. Architecturally cleaner than shell-env dependence.
- **Transcript pane with minimal/chrome modes** — purpose-built rendering of voice exchanges with end-of-session report generator. VD's voice exchanges don't surface as a transcript view.
- **Voice catalog + multi-backend selector UI** — Settings → Voice with OpenAI / Kokoro / Piper / ElevenLabs / macOS / Custom backends and per-voice descriptions. VD's voice picker is narrower.
- **Sparkle auto-update infrastructure** — wired with EdDSA signing + GitHub Pages appcast + release-cut script. VD ships via its own build script.
- **Dynamic terminal-tab session discovery** — `SessionDiscovery.swift` enumerates Claude Code sessions across Terminal.app windows with status badge parsing. VD doesn't track Terminal.app.

---

## Strategic synergies — what compounds when you connect the two

Beyond shared substrate, there are **product-level synergies** that turn two tools into a unified fabric.

### 1. CCJV's voice transcripts → VD's mobile Beacon
- VD has the cloud relay + SSE streaming + mobile PWA already built. CCJV's transcripts could publish to that relay so William can read his Claude Code voice exchanges from his phone while away.
- Effort: small (CCJV publishes to relay's `/events` endpoint with workspace=`claude-code-cli`).
- Value: CCJV gets the away/mobile read surface for free.

### 2. CCJV's session discovery → VD's workspace list
- VD already monitors VS Code workspaces. Extending it to also surface Claude Code CLI sessions (using CCJV's `SessionDiscovery` or VD's `TerminalMonitor`) would unify the workspace-list view.
- Value: VD's mobile Beacon shows ALL of William's coding agents (VS Code + Claude Code CLI + future) in one list.

### 3. Shared TTS substrate library
- Extract `VoiceCatalog` + `EnvFileWriter` + `KeychainHelper` into a shared SPM package. Both tools depend on it.
- Single implementation; both products benefit when a new backend or voice ships (e.g., Cartesia, PlayHT).
- Value: ~60% reduction in voice-config code duplication.

### 4. Shared hallucination-filter library
- CCJV's `HallucinationDetector` is the canonical implementation. Extract as SPM package.
- VD's notification-summarization flow benefits from the same Whisper-corpus filter.
- Value: when a new hallucination pattern is added (Whisper releases drift), one update covers both products.

### 5. Shared NSPanel HUD framework
- Extract a `FloatingHUDPanel` library — handles draggable position persistence, brand-themed blur, light/dark adaptation. Both products use it.
- VD's TricklePanel and CCJV's FloatingWidget both inherit from one base.
- Value: less than 5% reduction in code per product, but a meaningful brand-consistency win.

### 6. Voice intent routing across both products
- VD's `ClaudeRouter` routes voice replies to actions via Haiku. CCJV today has a hardcoded "let's have a voice conversation" trigger.
- If CCJV adopted VD's intent router, it could handle commands like *"open Marginalia Coordinator session"* or *"switch to Jarvis voice"* without leaving the floating widget.
- Value: meaningfully better UX for CCJV; requires lifting the router into a shared component.

### 7. CCJV's MCP wrapper pattern → VD's API key handling
- VD currently stores API keys in a flat `config.yaml` (per its own audit, this is a security liability — Regression Report C2 noted "Anthropic API key in world-readable config.yaml").
- CCJV's MCP-wrapper-pulls-from-Keychain pattern is the canonical solution. VD could adopt it for any cloud key (ElevenLabs, Anthropic, etc.).
- Value: closes a known security finding in VD; reuses tested pattern.

### 8. Common branding system
- CCJV ships a `BrandingTheme.swift` with brand color, wordmark, animations. VD has bespoke styling.
- A shared `WilliamRuizBrandKit` SPM package (or even just inline-shared assets) could unify the visual register across both products.
- Value: portfolio-level visual coherence; small but compounds when the third menu-bar app ships.

---

## Recommendation — what to do next

**Tier 1 (high value, low effort):**
1. Extract `KeychainHelper` + `HallucinationDetector` into a shared SPM package (~1 day)
2. CCJV publishes voice events to VD's relay → mobile Beacon surfaces CCJV transcripts (~1-2 days)

**Tier 2 (medium value, medium effort):**
3. Shared `VoiceCatalog` SPM package — single source of truth for voice/backend definitions (~3-5 days; touches both products)
4. VD's `TerminalMonitor` enriched with CCJV's badge-parsing logic for unified non-VS-Code agent surfacing (~2 days)

**Tier 3 (high value, big build):**
5. Shared NSPanel HUD framework + brand kit + intent router (~1-2 weeks; ties both products together visually + functionally)

**Anti-pattern to avoid:** merging the two products. They have different surface targets (VS Code vs Claude Code CLI) and different mental models (alert-triage vs character-driven voice). The win is shared substrate + cross-publishing transcripts/sessions, not consolidation.

---

## Visual

See `venn.html` in this directory for an interactive Venn-diagram visualization of the same analysis. Open with `open docs/comparison/venn.html` from the repo root.

---

*Analysis 2026-05-09. Subject to revision as both products evolve. Cross-reference: `~/code/vibedispatcher/docs/architecture.md`, `~/code/voicemode-menubar/Sources/VoiceModeMenuBar/`.*
