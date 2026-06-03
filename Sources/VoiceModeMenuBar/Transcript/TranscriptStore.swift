import Foundation

/// One conversational turn captured from a voice session.
///
/// `timestamp` is captured at the moment the turn is appended to the store —
/// never derived at render time. Per the v2 transcript spec, rendering must
/// not cost a clock round-trip per turn, so the cost lives here once.
struct Turn: Codable, Equatable {
    enum Role: String, Codable {
        case user      // William's transcribed input (Whisper STT)
        case claude    // Claude's spoken reply (TTS message)
        case system    // status / error frames (e.g. STT failure, "(input ignored)")
    }

    struct Flags: Codable, Equatable {
        var hallucinationDetected: Bool = false
    }

    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date
    var flags: Flags

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), flags: Flags = Flags()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.flags = flags
    }
}

/// In-memory ordered list of turns for a single voice session, with
/// disk-backed JSONL persistence per session and an NSNotification fan-out on
/// every insert.
///
/// The store is the single source of truth. Views observe via NotificationCenter
/// (`TranscriptStore.didAppendTurn`) and re-render incrementally.
///
/// Persistence path:
///   `~/Library/Application Support/VoiceModeMonitor/sessions/<sessionId>.jsonl`
///
/// JSONL is append-only — one Turn per line — so an interrupted session leaves
/// a recoverable artifact even if the app crashes mid-write.
final class TranscriptStore {

    /// Posted on the main thread whenever a turn is appended. `userInfo["turn"]`
    /// is the inserted `Turn`, `userInfo["sessionId"]` is the session string.
    static let didAppendTurn = Notification.Name("voicemode-monitor.transcript.didAppendTurn")

    let sessionId: String
    private(set) var turns: [Turn] = []

    /// Cap on in-memory turns. The on-disk JSONL keeps the full history; memory
    /// holds only the most recent window. Without this, tailing a long session
    /// (or loading a large persisted file) grew the array — and the rendered
    /// text view — without bound, which drove the app to multi-GB RSS.
    private let maxInMemoryTurns = 2000

    /// At most this many bytes are read from the tail of a persisted JSONL on
    /// load — so a previously-bloated session file can never be slurped whole
    /// into memory again.
    private let maxLoadBytes: UInt64 = 4 * 1024 * 1024

    private let fileURL: URL
    private let fileQueue = DispatchQueue(label: "voicemode.transcript-store.io", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(sessionId: String) {
        self.sessionId = sessionId
        let dir = TranscriptStore.sessionsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("\(sessionId).jsonl")
        loadFromDiskIfPresent()
    }

    /// Resolve and create (lazily) the application-support sessions directory.
    static func sessionsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("VoiceModeMonitor", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Append a turn — to memory immediately, to disk async (best-effort), and
    /// post the notification on the main thread so views update synchronously.
    @discardableResult
    func append(_ turn: Turn) -> Turn {
        turns.append(turn)
        // Keep memory bounded. Trim in batches (with slack) so this is amortized
        // O(1), not an O(n) removeFirst on every append once over the cap.
        if turns.count > maxInMemoryTurns + 256 {
            turns.removeFirst(turns.count - maxInMemoryTurns)
        }
        let id = self.sessionId
        fileQueue.async { [weak self] in self?.persist(turn) }

        let post = {
            NotificationCenter.default.post(
                name: TranscriptStore.didAppendTurn,
                object: self,
                userInfo: ["turn": turn, "sessionId": id]
            )
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }

        return turn
    }

    /// Convenience — build + append a turn in one call.
    @discardableResult
    func append(role: Turn.Role, text: String, timestamp: Date = Date(), hallucinationDetected: Bool = false) -> Turn {
        let turn = Turn(
            role: role,
            text: text,
            timestamp: timestamp,
            flags: .init(hallucinationDetected: hallucinationDetected)
        )
        return append(turn)
    }

    /// All turns in insertion order. Cheap copy — `Turn` is value-typed.
    func snapshot() -> [Turn] { turns }

    private func persist(_ turn: Turn) {
        guard let data = try? encoder.encode(turn) else { return }
        var line = data
        line.append(0x0A) // newline
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        } else {
            try? line.write(to: fileURL)
        }
    }

    private func loadFromDiskIfPresent() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        // Read at most the trailing `maxLoadBytes` — never the whole file. A
        // previously-bloated session file (the old replay bug produced a 392MB
        // one) must never be slurped into RAM again.
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxLoadBytes ? size - maxLoadBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // If we started mid-file, the first line is almost certainly a partial
        // record — drop it.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var loaded: [Turn] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let turn = try? decoder.decode(Turn.self, from: lineData) else { continue }
            loaded.append(turn)
        }
        if loaded.count > maxInMemoryTurns {
            loaded.removeFirst(loaded.count - maxInMemoryTurns)
        }
        turns = loaded
    }
}
