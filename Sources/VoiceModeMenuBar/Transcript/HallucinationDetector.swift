import Foundation

/// Pure-Swift detector for classic Whisper-family hallucinations on near-silent
/// audio (the "If you enjoyed this video, please like and subscribe!" family).
///
/// The seed list is hardcoded; users can extend it via a JSON file at
/// `~/Library/Application Support/VoiceModeMonitor/hallucination-patterns.json`
/// (an array of strings). Patterns are case-insensitive and whitespace-normalized
/// before comparison — so `"  THANKS for  WATCHING!"` matches `"thanks for watching"`.
enum HallucinationDetector {

    /// Seed list per the v2 transcript spec. New entries added here ship with
    /// the binary; the user-extensible JSON layered on top via `extraPatterns()`.
    static let seedPatterns: [String] = [
        "if you enjoyed this video, please like and subscribe!",
        "if you enjoyed this video please like and subscribe",
        "thanks for watching!",
        "thanks for watching",
        "subscribe to the channel",
        "please subscribe to the channel",
        "like and subscribe",
        "don't forget to subscribe",
        "see you in the next video",
    ]

    /// Returns true when `text` matches a known Whisper hallucination pattern.
    /// Empty / whitespace-only input is also treated as a hallucination —
    /// nothing was said, but Whisper occasionally emits a near-empty token blob.
    static func isHallucination(_ text: String) -> Bool {
        let normalized = normalize(text)
        if normalized.isEmpty { return true }
        let patterns = seedPatterns + extraPatterns()
        for pattern in patterns {
            let p = normalize(pattern)
            if p.isEmpty { continue }
            if normalized == p || normalized.contains(p) {
                return true
            }
        }
        return false
    }

    /// Lowercase + collapse whitespace + trim trailing punctuation that Whisper
    /// sprinkles inconsistently (`.`, `!`, `?`, `,`).
    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let collapsed = lowered
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let stripped = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        return stripped
    }

    /// User-extensible patterns loaded from disk. Layered ON TOP of `seedPatterns`
    /// — never replaces them. Returns `[]` on missing file or any parse error.
    static func extraPatterns() -> [String] {
        let url = patternsFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    static func patternsFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("VoiceModeMonitor", isDirectory: true)
            .appendingPathComponent("hallucination-patterns.json")
    }
}
