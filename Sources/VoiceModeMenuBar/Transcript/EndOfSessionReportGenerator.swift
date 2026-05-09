import AppKit

/// Produces a markdown end-of-session transcript dump per the v2 spec.
///
/// Format (one block per turn, both sides timestamped, hallucination-flagged
/// turns annotated):
///
///     # Voice session — <session-name> — <date>
///
///     ## 14:32:18  You
///     > what's the status on the dashboard
///
///     ## 14:32:25  Claude
///     > Three PRs merged this morning, two still in review.
///
///     ---
///
/// `sessionName` is whatever human label the host has (e.g. the Terminal tab
/// title). Falls back to the session ID.
enum EndOfSessionReportGenerator {

    /// Generate a markdown transcript dump for `store`.
    static func generate(store: TranscriptStore, sessionName: String? = nil) -> String {
        return generate(turns: store.snapshot(), sessionId: store.sessionId, sessionName: sessionName)
    }

    /// Lower-level entry point — useful when the caller has already loaded
    /// turns from disk for an old session.
    static func generate(turns: [Turn], sessionId: String, sessionName: String?) -> String {
        var out = ""
        let title = sessionName?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? sessionName!
            : sessionId
        let dateLabel = dateFormatter.string(from: turns.first?.timestamp ?? Date())
        out += "# Voice session — \(title) — \(dateLabel)\n\n"

        // Filter out the synthetic "(STT hallucination on silence — input ignored)"
        // system turns — they're an in-app render artifact. The hallucination is
        // surfaced inline on the user turn instead, per the spec sample.
        let visible = turns.filter { turn in
            !(turn.role == .system && turn.text.contains("(STT hallucination on silence"))
        }

        for (idx, turn) in visible.enumerated() {
            out += turnBlock(turn)
            // HR between turns; not after the last one.
            if idx < visible.count - 1 {
                out += "---\n\n"
            }
        }
        return out
    }

    /// Copy the generated markdown to NSPasteboard. Returns true on success.
    /// Convenience for hosts that wire a "Copy transcript" button.
    @discardableResult
    static func copyToClipboard(store: TranscriptStore, sessionName: String? = nil) -> Bool {
        let markdown = generate(store: store, sessionName: sessionName)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(markdown, forType: .string)
    }

    private static func turnBlock(_ turn: Turn) -> String {
        let time = timeFormatter.string(from: turn.timestamp)
        let speaker: String
        switch turn.role {
        case .user: speaker = "You"
        case .claude: speaker = "Claude"
        case .system: speaker = "System"
        }
        var block = "## \(time)  \(speaker)\n"
        if turn.flags.hallucinationDetected {
            block += "> \(turn.text)\n"
            block += "> _(STT hallucination on silence — input ignored)_\n\n"
        } else {
            // Multi-line text → each line gets a leading "> " so the whole reply
            // renders as one blockquote in markdown.
            for line in turn.text.split(separator: "\n", omittingEmptySubsequences: false) {
                block += "> \(line)\n"
            }
            block += "\n"
        }
        return block
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
