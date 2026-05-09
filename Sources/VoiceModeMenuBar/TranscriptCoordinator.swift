import AppKit
import Foundation

/// Bridges the Transcript module into the rest of the app.
///
/// Owns one live `TranscriptView` whose backing `TranscriptStore` switches as
/// the user moves between voice sessions. The "active" session is whichever
/// `~/.claude/projects/<projectHash>/<sessionId>.jsonl` was most recently
/// touched — this is the right heuristic because Claude Code writes a JSONL
/// line for every turn, so the freshest mtime is the live conversation.
///
/// The coordinator also exposes the toggle control + an end-of-session report
/// helper for hosts to embed wherever convenient.
///
/// V1 limitation: a single global "live transcript" rather than one transcript
/// per Terminal tab. Mapping a Terminal tab to its specific Claude session id
/// requires Claude-Code-side surface that doesn't exist yet, and most users
/// only have one active voice conversation at a time, so the global stream is
/// the right cost/value trade for v1.
final class TranscriptCoordinator {

    let view: TranscriptView
    let toggle: TranscriptToggleControl

    private(set) var currentStore: TranscriptStore
    private var currentSource: ClaudeSessionJsonlAdapter?
    private var currentJsonlPath: String?

    private let watcherQueue = DispatchQueue(label: "voicemode.transcript-coordinator.watcher", qos: .utility)
    private var watcherTimer: DispatchSourceTimer?
    private let watchInterval: TimeInterval

    init(watchInterval: TimeInterval = 3.0) {
        self.watchInterval = watchInterval
        let bootSessionId = "boot-\(Int(Date().timeIntervalSince1970))"
        let store = TranscriptStore(sessionId: bootSessionId)
        self.currentStore = store
        self.view = TranscriptView(store: store, frame: .zero)
        self.toggle = TranscriptToggleControl(frame: .zero)
        startWatcher()
    }

    deinit {
        watcherTimer?.cancel()
        currentSource?.stop()
    }

    /// Returns a markdown dump of the current transcript with both sides
    /// timestamped — the end-of-session report per the v2 transcript spec.
    func currentReport(sessionName: String? = nil) -> String {
        return EndOfSessionReportGenerator.generate(
            store: currentStore,
            sessionName: sessionName ?? currentJsonlPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "session"
        )
    }

    /// Convenience: copies the report to the clipboard.
    func copyReportToClipboard(sessionName: String? = nil) {
        EndOfSessionReportGenerator.copyToClipboard(
            store: currentStore,
            sessionName: sessionName ?? currentJsonlPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "session"
        )
    }

    // MARK: - Active session watcher

    private func startWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: watcherQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: watchInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        watcherTimer = timer
    }

    private func tick() {
        guard let newest = mostRecentJsonl() else { return }
        if newest.path == currentJsonlPath { return }
        DispatchQueue.main.async { [weak self] in
            self?.switchTo(jsonlURL: newest)
        }
    }

    /// Walks `~/.claude/projects/<hash>/*.jsonl` and returns the file with the
    /// most recent mtime. Returns nil if the projects directory is empty.
    private func mostRecentJsonl() -> URL? {
        let projectsRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return nil }

        var best: (URL, Date)? = nil
        for project in projects {
            let projectDir = (projectsRoot as NSString).appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (projectDir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if let current = best {
                    if mtime > current.1 {
                        best = (URL(fileURLWithPath: path), mtime)
                    }
                } else {
                    best = (URL(fileURLWithPath: path), mtime)
                }
            }
        }
        return best?.0
    }

    private func switchTo(jsonlURL: URL) {
        currentSource?.stop()
        let sessionId = jsonlURL.deletingPathExtension().lastPathComponent
        let store = TranscriptStore(sessionId: sessionId)
        let source = ClaudeSessionJsonlAdapter(store: store, jsonlURL: jsonlURL)
        source.start()
        currentStore = store
        currentSource = source
        currentJsonlPath = jsonlURL.path
        view.setStore(store)
    }
}
