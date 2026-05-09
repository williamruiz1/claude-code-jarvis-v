import Foundation
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "EnvFileWriter")

/// Writes `~/Library/Application Support/VoiceModeMonitor/voicemode-env.sh` —
/// a shell-sourceable file that exports the TTS env vars the voicemode MCP
/// server reads at launch.
///
/// **Wiring contract:** the user's voicemode MCP wrapper command in
/// `~/.claude.json` is expected to source this file before exec'ing
/// voicemode, e.g.:
///
/// ```
/// /bin/sh -c '. "$HOME/Library/Application Support/VoiceModeMonitor/voicemode-env.sh" 2>/dev/null; \
///             export OPENAI_API_KEY=$(security find-generic-password ...) && \
///             exec uvx voice-mode'
/// ```
///
/// Because the wrapper sources this file at every voicemode-server launch,
/// changes here take effect on the **next** Claude Code session that boots
/// voicemode. No restart of an already-running session — its server already
/// has the old env baked in.
///
/// We never read or write API keys here. Those live in macOS Keychain and are
/// fetched by the wrapper directly via `security find-generic-password`. This
/// file is for **non-secret** voice/model selection only.
///
/// ### Backend wiring (per `VoiceSettings.Backend`)
///
/// - **OpenAI** — `VOICEMODE_TTS_VOICE` only; voicemode defaults to OpenAI.
/// - **Kokoro (local)** — points `VOICEMODE_TTS_BASE_URL` at
///   `http://localhost:8880/v1` (the bundled FastAPI server) and sets
///   `VOICEMODE_TTS_VOICE` to the chosen Kokoro voice id (e.g. `bm_george`).
///   Kokoro is installed locally by the VoiceMode installer.
/// - **Piper (local)** — points `VOICEMODE_TTS_BASE_URL` at
///   `http://localhost:10200/v1` and sets `VOICEMODE_TTS_VOICE` to the
///   Piper voice id. Requires `./scripts/install-piper-jarvis.sh` (authored
///   separately) to provision the voice files + start the server.
/// - **ElevenLabs** — Creator tier ($22/mo) for voice library API access
///   required. Note that ElevenLabs does NOT publish a native
///   OpenAI-compatible `/v1/audio/speech` endpoint; in production wiring this
///   typically goes through a LiteLLM proxy (see `_design/v2-architecture.md`
///   §1). For this iteration we emit the env vars and trust the wrapper to
///   handle proxying.
/// - **macOS** — VoiceMode itself does NOT speak `say`. We emit a marker var
///   `VOICEMODE_MONITOR_SAY_VOICE` plus a small wrapper script
///   (`voicemode-say-tts.sh`) the user can hook into voicemode's
///   `VOICEMODE_TTS_COMMAND` (or use as a manual preview path). The Test
///   button in the picker calls `/usr/bin/say -v <voice>` directly.
/// - **Custom** — passes through whatever the user typed.
enum EnvFileWriter {

    static let supportDirName = "VoiceModeMonitor"
    static let envFileName = "voicemode-env.sh"
    static let sayWrapperFileName = "voicemode-say-tts.sh"

    /// Returns the absolute path the wrapper should source.
    static var envFilePath: String {
        return supportDir.appendingPathComponent(envFileName).path
    }

    /// `~/Library/Application Support/VoiceModeMonitor`
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(supportDirName, isDirectory: true)
    }

    /// Build the env file content from current settings and write it atomically.
    /// Safe to call repeatedly; only the file is touched, no UI side-effects.
    static func writeFromCurrentSettings() {
        let settings = VoiceSettings.load()
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let body = renderShellScript(settings)
            let path = supportDir.appendingPathComponent(envFileName)
            try body.data(using: .utf8)?.write(to: path, options: .atomic)
            // Make readable for sh -c sourcing (default umask is fine, but be explicit).
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

            // For the macOS backend, also drop the `say` wrapper script so the
            // user can hook it into voicemode's TTS_COMMAND or invoke directly.
            if settings.backend == .macos {
                writeSayWrapper(voice: settings.voice)
            }
        } catch {
            log.error("failed to write env file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func renderShellScript(_ s: VoiceSettings) -> String {
        var lines: [String] = [
            "# VoiceMode Monitor — generated env file. Edits will be overwritten.",
            "# Source from your voicemode MCP wrapper before exec'ing voice-mode.",
            "# Backend: \(s.backend.rawValue)   Voice: \(s.voice)",
            "",
        ]
        switch s.backend {
        case .openai:
            lines.append("export VOICEMODE_TTS_VOICE=\(shellQuote(s.voice))")
            lines.append("export VOICEMODE_TTS_MODEL=tts-1")
            // No base URL override — voicemode defaults to OpenAI.

        case .kokoro:
            // Kokoro is OpenAI-compatible — point at the local FastAPI server.
            // The chosen voice id maps directly to a Kokoro voice file.
            lines.append("export VOICEMODE_TTS_VOICE=\(shellQuote(s.voice))")
            lines.append("export VOICEMODE_TTS_MODEL=kokoro")
            lines.append("export VOICEMODE_TTS_BASE_URL=\(shellQuote(VoiceCatalog.kokoroBaseURL))")
            // Some VoiceMode versions read the plural form; emit both for safety.
            lines.append("export VOICEMODE_TTS_BASE_URLS=\(shellQuote(VoiceCatalog.kokoroBaseURL))")

        case .piper:
            // Piper local server (started by scripts/install-piper-jarvis.sh).
            lines.append("export VOICEMODE_TTS_VOICE=\(shellQuote(s.voice))")
            lines.append("export VOICEMODE_TTS_MODEL=piper")
            lines.append("export VOICEMODE_TTS_BASE_URL=\(shellQuote(VoiceCatalog.piperBaseURL))")
            lines.append("export VOICEMODE_TTS_BASE_URLS=\(shellQuote(VoiceCatalog.piperBaseURL))")

        case .elevenlabs:
            // NOTE: ElevenLabs has no native OpenAI-compatible /v1/audio/speech
            // endpoint — production wiring should put a LiteLLM proxy in front
            // (see _design/v2-architecture.md §1). For now we emit the env vars
            // the wrapper expects.
            lines.append("export VOICEMODE_TTS_VOICE=\(shellQuote(s.voice))")
            lines.append("export VOICEMODE_TTS_MODEL=eleven_turbo_v2_5")
            lines.append("export VOICEMODE_TTS_BASE_URL=https://api.elevenlabs.io/v1")

        case .macos:
            // VoiceMode itself doesn't speak `say`, so we DO NOT override
            // VOICEMODE_TTS_BASE_URL here (that would break the conversation
            // path). Instead we emit a marker var the wrapper can pick up
            // and a sibling script (written by writeSayWrapper) the user can
            // hook into VOICEMODE_TTS_COMMAND if their VoiceMode build
            // supports it. The picker's Test button invokes `say` directly.
            lines.append("export VOICEMODE_MONITOR_SAY_VOICE=\(shellQuote(s.voice))")
            lines.append("# macOS backend selected — VoiceMode is NOT routed through `say`.")
            lines.append("# The Settings → Voice Test button previews via /usr/bin/say.")
            lines.append("# A wrapper script is at: \(supportDir.appendingPathComponent(sayWrapperFileName).path)")

        case .custom:
            lines.append("export VOICEMODE_TTS_VOICE=\(shellQuote(s.voice))")
            if !s.customModel.isEmpty {
                lines.append("export VOICEMODE_TTS_MODEL=\(shellQuote(s.customModel))")
            }
            if !s.customBaseURL.isEmpty {
                lines.append("export VOICEMODE_TTS_BASE_URL=\(shellQuote(s.customBaseURL))")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Writes a small shell wrapper that pipes stdin through `/usr/bin/say -v <voice>`.
    /// Useful for users with a VoiceMode build that supports `VOICEMODE_TTS_COMMAND`,
    /// or for manual scripting. Idempotent.
    private static func writeSayWrapper(voice: String) {
        let path = supportDir.appendingPathComponent(sayWrapperFileName)
        let body = """
        #!/bin/sh
        # VoiceMode Monitor — generated `say` wrapper. Edits will be overwritten.
        # Pipes stdin through macOS' /usr/bin/say so you can preview the
        # selected voice without going through VoiceMode's TTS pipeline.
        # Usage:
        #   echo "Hello William." | \(path.path)
        exec /usr/bin/say -v \(shellQuote(voice))
        """
        do {
            try body.data(using: .utf8)?.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        } catch {
            log.error("failed to write say wrapper: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Single-quote escape for sh. Replaces any embedded single quotes with
    /// `'\''` (close-quote, escaped quote, re-open).
    private static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
