import Foundation

/// Static catalog of (Backend, VoiceID, displayLabel, description) tuples
/// covering every voice the picker can offer across every backend.
///
/// **Why a separate file?** The picker is a two-level chooser (backend → voice)
/// and the voice list per backend will grow over time (new Kokoro voices,
/// new Piper packs, more macOS premium voices). Centralising the catalog here
/// keeps `VoicePane` and `EnvFileWriter` from each owning their own copy.
///
/// FREE tier rule of thumb (used to decide what ships in the picker today):
/// - Kokoro = free, runs locally on `http://localhost:8880/v1` if installed
/// - macOS `say` = free, ships with every Mac
/// - Piper = free, requires `./scripts/install-piper-jarvis.sh` first
/// - OpenAI = paid (per character) but already wired
/// - ElevenLabs = paid ($22/mo Creator tier for voice library API access)
enum VoiceCatalog {

    /// One concrete voice option for one backend.
    struct Voice {
        let id: String          // value passed to VOICEMODE_TTS_VOICE / `say -v` / piper voice file
        let label: String       // human-readable name shown in the popup
        let blurb: String       // 1-line description shown under the picker
    }

    // MARK: - OpenAI

    /// Voices supported by VoiceMode against `api.openai.com/v1`.
    /// Source: openai.com/docs/guides/text-to-speech (tts-1 / tts-1-hd).
    static let openAI: [Voice] = [
        Voice(id: "alloy",   label: "Alloy",   blurb: "Balanced, neutral baseline voice."),
        Voice(id: "echo",    label: "Echo",    blurb: "Calm, even-keeled male tone."),
        Voice(id: "fable",   label: "Fable",   blurb: "Warm British accent, story-teller cadence."),
        Voice(id: "onyx",    label: "Onyx",    blurb: "Deep, authoritative male voice."),
        Voice(id: "nova",    label: "Nova",    blurb: "Bright, friendly female voice."),
        Voice(id: "shimmer", label: "Shimmer", blurb: "Soft, gentle female voice."),
    ]

    // MARK: - Kokoro (local, port 8880)

    /// Seed list per spec — verified against a live Kokoro server on this
    /// machine where possible. `bf_isabella` was not in the live listing
    /// (the deployed model has `bf_v0isabella` instead) but we ship the
    /// canonical id; the Test button will surface any 404 at preview time.
    /// Full voice list: huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
    static let kokoro: [Voice] = [
        Voice(id: "bm_george",    label: "George (UK male)",     blurb: "British male, calm — closest to a Jarvis-style butler voice."),
        Voice(id: "bm_lewis",     label: "Lewis (UK male)",      blurb: "British male, alternate timbre."),
        Voice(id: "am_adam",      label: "Adam (US male)",       blurb: "American male, neutral."),
        Voice(id: "am_michael",   label: "Michael (US male)",    blurb: "American male, warmer."),
        Voice(id: "af_bella",     label: "Bella (US female)",    blurb: "American female, neutral."),
        Voice(id: "af_sarah",     label: "Sarah (US female)",    blurb: "American female, warmer."),
        Voice(id: "bf_emma",      label: "Emma (UK female)",     blurb: "British female."),
        Voice(id: "bf_isabella",  label: "Isabella (UK female)", blurb: "British female, alternate."),
    ]

    /// Default base URL — Kokoro's bundled FastAPI server.
    static let kokoroBaseURL = "http://localhost:8880/v1"

    // MARK: - Piper (local, requires install script)

    /// Piper voices the install script (`scripts/install-piper-jarvis.sh`,
    /// authored separately) is expected to provision. The install script
    /// downloads voice files into `~/.voicemode/piper/voices/` and starts
    /// a local HTTP server compatible with VoiceMode's TTS shape.
    static let piper: [Voice] = [
        Voice(id: "jarvis",                              label: "Jarvis",                  blurb: "JARVIS from Iron Man (jgkawell/jarvis on Hugging Face)."),
        Voice(id: "en_GB-alan-medium",                   label: "Alan (UK male)",          blurb: "UK male, calm — Jarvis-adjacent."),
        Voice(id: "en_GB-northern_english_male-medium",  label: "Northern English male",   blurb: "UK male, northern accent."),
        Voice(id: "en_GB-cori-medium",                   label: "Cori (UK female)",        blurb: "UK female."),
        Voice(id: "en_US-amy-medium",                    label: "Amy (US female)",         blurb: "US female."),
    ]

    /// Default base URL the Piper install script binds to.
    /// (Convention: install-piper-jarvis.sh runs piper on :10200.)
    static let piperBaseURL = "http://localhost:10200/v1"

    // MARK: - macOS built-in `say`

    /// macOS premium voices for English. Some (Oliver, Alex) require the
    /// user to download via System Settings → Accessibility → Spoken Content;
    /// the Test button reports if a voice is not installed.
    static let macOS: [Voice] = [
        Voice(id: "Daniel",    label: "Daniel (UK male)",      blurb: "UK male, deep, dignified — Jarvis-adjacent."),
        Voice(id: "Oliver",    label: "Oliver (UK male)",      blurb: "UK male, alternate (may require download in System Settings)."),
        Voice(id: "Karen",     label: "Karen (AU female)",     blurb: "Australian female, distinct accent."),
        Voice(id: "Samantha",  label: "Samantha (US female)",  blurb: "US female, neutral."),
        Voice(id: "Alex",      label: "Alex (US male)",        blurb: "US male, classic Mac voice (may require download in System Settings)."),
        Voice(id: "Fred",      label: "Fred (US male)",        blurb: "US male, classic novelty voice."),
    ]

    // MARK: - Lookup

    /// Returns the catalog of voices for a backend.
    /// For ElevenLabs and Custom we return an empty list — those backends
    /// take a free-form voice ID typed by the user.
    static func voices(for backend: VoiceSettings.Backend) -> [Voice] {
        switch backend {
        case .openai:     return openAI
        case .kokoro:     return kokoro
        case .piper:      return piper
        case .macos:      return macOS
        case .elevenlabs: return []
        case .custom:     return []
        }
    }

    /// First voice id for a backend — used as the default when switching
    /// backends and the previously-selected voice doesn't apply.
    static func defaultVoiceId(for backend: VoiceSettings.Backend) -> String {
        switch backend {
        case .openai:     return "onyx"
        case .kokoro:     return "bm_george"
        case .piper:      return "jarvis"
        case .macos:      return "Daniel"
        case .elevenlabs: return ""
        case .custom:     return ""
        }
    }

    /// Sample sentence used by the Test button. Short, varied phonemes,
    /// easy to evaluate quality / accent / cadence on.
    static let sampleSentence = "Hello William. I'm your voice assistant. How can I help you today?"
}
