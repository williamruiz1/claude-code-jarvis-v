import Foundation

/// Input adapter abstraction. A `TranscriptSource` produces `Turn`s from some
/// upstream signal (Claude Code session JSONL today, IPC tomorrow) and pushes
/// them into a `TranscriptStore`.
///
/// Sources are owned by a host (AppDelegate / main window) which calls `start()`
/// when a session becomes "the live session" and `stop()` when it goes away.
protocol TranscriptSource: AnyObject {
    var store: TranscriptStore { get }
    func start()
    func stop()
}

/// Tails Claude Code's per-session JSONL file at
/// `~/.claude/projects/<projectHash>/<sessionId>.jsonl` for `mcp__voicemode__converse`
/// tool calls and translates each call into a (claude reply, user transcript) pair
/// of turns.
///
/// JSONL shape (observed 2026-05-09 across sessions in
/// `~/.claude/projects/-Users-williamruiz/`):
///
///   `assistant` line, `message.content[].type == "tool_use"`, name
///   `mcp__voicemode__converse`, `input.message` = Claude's spoken reply.
///
///   matching `user` line, `message.content[].type == "tool_result"`,
///   `tool_use_id` matches the assistant's id, `content` is a JSON-encoded
///   string `{"result":"Voice response: <transcribed text> (STT: openai) | Timing: ..."}`
///   when `wait_for_response: true`. When false, it's `"✓ Message spoken successfully"`.
///
/// TODO(research): tool_result `content` shape varies — sometimes a string,
/// sometimes a `[{"type":"text","text":"..."}]` array. Both are handled here.
/// Verify with newer Claude Code versions; adapter may need a parser refresh.
///
/// TODO(research): assistant tool_use with `wait_for_response: false` only
/// produces a "spoken successfully" result — currently we still emit a Claude
/// turn but no user turn, which is the right behavior.
final class ClaudeSessionJsonlAdapter: TranscriptSource {

    let store: TranscriptStore
    private let fileURL: URL
    private var timer: DispatchSourceTimer?
    private let pollInterval: TimeInterval
    private var bytesConsumed: UInt64 = 0
    private var pairBuffer: [String: PendingPair] = [:]   // tool_use_id → partial
    private let queue = DispatchQueue(label: "voicemode.transcript-source.jsonl", qos: .utility)

    /// Holds the assistant side of a converse pair until the matching tool_result
    /// arrives (or vice versa). Either field may land first depending on session
    /// timing; we flush only when both halves are in.
    private struct PendingPair {
        var assistantMessage: String?
        var assistantTimestamp: Date?
        var userTranscript: String?
        var userTimestamp: Date?
    }

    init(store: TranscriptStore, jsonlURL: URL, pollInterval: TimeInterval = 1.0) {
        self.store = store
        self.fileURL = jsonlURL
        self.pollInterval = pollInterval
    }

    /// Convenience initialiser when the caller only knows the Claude session ID.
    /// Resolves via the standard project-hash directory layout under `~/.claude/projects/`.
    convenience init?(store: TranscriptStore, claudeSessionId: String, projectDirHash: String) {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects/\(projectDirHash)/\(claudeSessionId).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.init(store: store, jsonlURL: url)
    }

    func start() {
        // Live-tail: start reading at the CURRENT end of file so we only surface
        // NEW turns. The coordinator points us at whatever JSONL is freshest —
        // which is often a large, active *coding* session (hundreds of MB), not a
        // voice session. Reading from byte 0 replayed that whole file into the
        // store on every attach, pegging the main thread and ballooning RAM. The
        // transcript is a LIVE view, so skipping prior history is also correct.
        // Enqueued on the serial `queue` before the timer's first tick.
        queue.async { [weak self] in
            guard let self = self else { return }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
               let size = (attrs[.size] as? NSNumber)?.uint64Value {
                self.bytesConsumed = size
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        // If the file shrank (truncated / rotated / replaced), our saved offset is
        // now past EOF — re-anchor to the new end so we keep live-tailing instead
        // of going permanently deaf.
        let size = (try? handle.seekToEnd()) ?? 0
        if size < bytesConsumed { bytesConsumed = size }
        do {
            try handle.seek(toOffset: bytesConsumed)
        } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        bytesConsumed += UInt64(data.count)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            consume(line: String(line))
        }
    }

    /// Parse a single JSONL line and route it to the right half of a pending pair.
    private func consume(line: String) {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = raw["type"] as? String
        let timestamp = (raw["timestamp"] as? String).flatMap(Self.parseISO8601) ?? Date()

        guard let message = raw["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }

        if type == "assistant" {
            for item in content {
                guard item["type"] as? String == "tool_use",
                      item["name"] as? String == "mcp__voicemode__converse",
                      let id = item["id"] as? String,
                      let input = item["input"] as? [String: Any],
                      let claudeMessage = input["message"] as? String else { continue }
                var pair = pairBuffer[id] ?? PendingPair()
                pair.assistantMessage = claudeMessage
                pair.assistantTimestamp = timestamp
                pairBuffer[id] = pair
                tryFlush(id: id)
            }
        } else if type == "user" {
            for item in content {
                guard item["type"] as? String == "tool_result",
                      let tid = item["tool_use_id"] as? String else { continue }
                let resultText = Self.extractResultText(item["content"])
                let parsed = Self.parseConverseResult(resultText)
                var pair = pairBuffer[tid] ?? PendingPair()
                pair.userTranscript = parsed   // may be nil (e.g. "spoken successfully")
                pair.userTimestamp = timestamp
                pairBuffer[tid] = pair
                tryFlush(id: tid)
            }
        }
    }

    /// Emit any complete pairs (or pairs that only ever had one side, after the
    /// other side appears). Order matters for the transcript: Claude's spoken
    /// reply went out FIRST in real time (TTS plays before STT records the
    /// response), so the user turn is appended AFTER the claude turn.
    private func tryFlush(id: String) {
        guard let pair = pairBuffer[id] else { return }
        // Need at least the assistant message before we emit anything for this id.
        guard let claudeMessage = pair.assistantMessage,
              let claudeTs = pair.assistantTimestamp else { return }
        // If the user side is still pending and the result hasn't been seen yet,
        // wait for it. Once we've seen either a transcript or a "spoken successfully"
        // null, we flush.
        let userSeen = pair.userTimestamp != nil
        guard userSeen else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.store.append(role: .claude, text: claudeMessage, timestamp: claudeTs)
            if let userText = pair.userTranscript, !userText.isEmpty {
                let isHallucination = HallucinationDetector.isHallucination(userText)
                self.store.append(
                    role: .user,
                    text: userText,
                    timestamp: pair.userTimestamp ?? Date(),
                    hallucinationDetected: isHallucination
                )
                if isHallucination {
                    self.store.append(
                        role: .system,
                        text: "(STT hallucination on silence — input ignored)",
                        timestamp: pair.userTimestamp ?? Date()
                    )
                }
            }
        }
        pairBuffer.removeValue(forKey: id)
    }

    /// `tool_result.content` can be either a JSON string or an array of content
    /// blocks. Normalize both to a single string we can regex.
    private static func extractResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Pull the transcribed user input out of voicemode's result-string format:
    ///   `{"result":"Voice response: <transcript> (STT: openai) | Timing: ..."}`
    /// Returns nil for non-response results (e.g. `"✓ Message spoken successfully"`).
    static func parseConverseResult(_ raw: String) -> String? {
        // First, unwrap the JSON envelope if present.
        var text = raw
        if let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = dict["result"] as? String {
            text = inner
        }
        // Strip trailing "(STT: ...) | Timing: ..." suffix.
        let prefix = "Voice response:"
        guard let range = text.range(of: prefix) else { return nil }
        var body = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Trim the metadata tail. We look for the LAST "(STT" — Whisper transcripts
        // can themselves contain parens, so the conservative cut is the suffix.
        if let metaRange = body.range(of: " (STT:", options: .backwards) {
            body = String(body[..<metaRange.lowerBound])
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
