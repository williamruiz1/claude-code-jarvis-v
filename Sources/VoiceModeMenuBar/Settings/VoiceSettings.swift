import Foundation

/// User-configurable voice/TTS settings, persisted to UserDefaults.
///
/// Keys are namespaced under `voicemode-monitor.tts.*` so they don't collide
/// with other apps and are easy to inspect via `defaults read
/// com.williamruiz.voicemode-monitor`.
///
/// Changing settings does NOT affect already-running Claude Code sessions.
/// The next session that boots voicemode will pick up the new values via
/// the env file written by `EnvFileWriter`.
struct VoiceSettings {

    enum Backend: String, CaseIterable {
        case openai
        case kokoro      // local Kokoro server on http://localhost:8880/v1 (free)
        case piper       // local Piper server on http://localhost:10200/v1 (free, install script required)
        case elevenlabs  // paid: Creator tier ($22/mo) for voice library API access
        case macos       // free; not routed through VoiceMode — wrapper pipes text through `/usr/bin/say`
        case custom

        var displayName: String {
            switch self {
            case .openai:     return "OpenAI"
            case .kokoro:     return "Kokoro (local)"
            case .piper:      return "Piper (local)"
            case .elevenlabs: return "ElevenLabs"
            case .macos:      return "macOS"
            case .custom:     return "Custom"
            }
        }
    }

    /// Built-in OpenAI voice descriptors — kept here for backwards-compat with
    /// any callers; the canonical source is `VoiceCatalog.openAI`.
    static var openAIVoices: [(id: String, blurb: String)] {
        VoiceCatalog.openAI.map { ($0.id, $0.blurb) }
    }

    var backend: Backend
    /// For OpenAI/Kokoro/Piper/macOS: a voice id from `VoiceCatalog`.
    /// For ElevenLabs: voice UUID. For custom: whatever string the user enters.
    var voice: String
    /// Used only when `backend == .custom` (overrides default model).
    var customModel: String
    /// Used only when `backend == .custom` (overrides default base URL).
    var customBaseURL: String

    static let backendKey      = "voicemode-monitor.tts.backend"
    static let voiceKey        = "voicemode-monitor.tts.voice"
    static let customModelKey  = "voicemode-monitor.tts.custom-model"
    static let customBaseURLKey = "voicemode-monitor.tts.custom-base-url"

    static func load() -> VoiceSettings {
        let d = UserDefaults.standard
        let backendRaw = d.string(forKey: backendKey) ?? Backend.openai.rawValue
        let backend = Backend(rawValue: backendRaw) ?? .openai
        let voice = d.string(forKey: voiceKey) ?? "onyx"
        let customModel = d.string(forKey: customModelKey) ?? ""
        let customBaseURL = d.string(forKey: customBaseURLKey) ?? ""
        return VoiceSettings(
            backend: backend,
            voice: voice,
            customModel: customModel,
            customBaseURL: customBaseURL
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(backend.rawValue, forKey: Self.backendKey)
        d.set(voice, forKey: Self.voiceKey)
        d.set(customModel, forKey: Self.customModelKey)
        d.set(customBaseURL, forKey: Self.customBaseURLKey)
    }

    /// Short single-line description for the main-window status bar.
    var statusBarDescription: String {
        let prettyVoice: String
        // For backends with a static catalog, prefer the human-readable label.
        if let v = VoiceCatalog.voices(for: backend).first(where: { $0.id == voice }) {
            prettyVoice = v.label
        } else if backend == .elevenlabs && voice.count > 8 {
            prettyVoice = "\(voice.prefix(8))…"
        } else {
            prettyVoice = voice
        }
        return "\(backend.displayName) · \(prettyVoice)"
    }
}
