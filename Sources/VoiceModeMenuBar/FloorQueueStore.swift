import Foundation
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "FloorQueueStore")

/// Models the convomode floor-control state read from `~/.voicemode/floor-queue.json`
/// and the mic mute state read from `~/.voicemode/mute-state.json`.
///
/// **Read-side only.** This Swift type renders the queue and surfaces a polled
/// snapshot; it NEVER mutates the JSON state machine directly. All writes go
/// through `convomode-floor.py` (the single writer/reader of the queue) via
/// `FloorControlCLI`. We only READ these files here.
///
/// Both files may be absent or partially written (the CLI uses temp+rename so a
/// partial read is rare, but tolerated): on any decode failure we degrade to an
/// empty state rather than crash or surface stale garbage.

// MARK: - State models

/// One queue entry. Mirrors `convomode-floor.py`'s schema:
/// `{ "agent": str, "pid": int, "requested_at": iso, "intent": "speak"|"listen" }`.
struct FloorEntry: Equatable {
    let agent: String
    let pid: Int
    let requestedAt: String
    let intent: String
}

/// The floor holder. Schema: `{ "agent": str, "pid": int, "since": iso }`.
struct FloorHolder: Equatable {
    let agent: String
    let pid: Int
    let since: String
}

/// The full snapshot the widget renders from. Combines `floor-queue.json`
/// (holder + queue + paused + advance) and `mute-state.json` (mic mute).
struct FloorSnapshot: Equatable {
    var holder: FloorHolder?
    var queue: [FloorEntry]
    var queuePaused: Bool
    var advanceRequested: Bool
    /// From `mute-state.json`. nil = file absent / unreadable (treat as "unknown",
    /// rendered as not-muted but the source distinguishes it).
    var muted: Bool
    var muteSource: String?
    var muteDevice: String?

    static let empty = FloorSnapshot(
        holder: nil, queue: [], queuePaused: false, advanceRequested: false,
        muted: false, muteSource: nil, muteDevice: nil
    )

    /// Convenience — total participants (holder + queued).
    var depth: Int { (holder == nil ? 0 : 1) + queue.count }

    /// Is there any convomode activity at all? Used to gate the gesture tap
    /// (per design §8.3: capture only while convomode active AND depth > 1).
    var isActive: Bool { holder != nil || !queue.isEmpty }
}

// MARK: - Store

/// Reads `floor-queue.json` + `mute-state.json` and publishes a `FloorSnapshot`
/// to an observer whenever the on-disk state changes.
///
/// **Watch strategy.** Uses an FSEvents-free `DispatchSource.makeFileSystemObjectSource`
/// vnode watcher on the `~/.voicemode` directory when it exists, PLUS a low-cadence
/// poll fallback (the files may be created after we start watching, and vnode
/// watches don't survive temp+rename atomic replacement of the watched file —
/// so we watch the *directory* and re-read on any write event, and also poll as a
/// belt-and-suspenders backstop). All callbacks fire on the main queue.
final class FloorQueueStore {
    typealias SnapshotHandler = (FloorSnapshot) -> Void

    static var voiceDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".voicemode")
    }
    static var floorQueueURL: URL { voiceDir.appendingPathComponent("floor-queue.json") }
    static var muteStateURL: URL { voiceDir.appendingPathComponent("mute-state.json") }

    private let onChange: SnapshotHandler
    private let pollInterval: TimeInterval
    private var pollTimer: DispatchSourceTimer?
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var lastSnapshot: FloorSnapshot = .empty
    private let queue = DispatchQueue(label: "voicemode.floor-store", qos: .utility)

    init(pollInterval: TimeInterval = 0.6, onChange: @escaping SnapshotHandler) {
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    /// Begin watching. Idempotent — re-calling cancels any prior timer/watcher.
    func start() {
        stop()
        ensureVoiceDir()
        startDirWatcher()
        startPoll()
        // Emit an initial snapshot synchronously-ish (on the store queue) so the
        // widget paints immediately on show.
        queue.async { [weak self] in self?.readAndPublishIfChanged() }
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        dirWatcher?.cancel()
        dirWatcher = nil
        if dirFD >= 0 { close(dirFD); dirFD = -1 }
    }

    deinit { stop() }

    /// The most recent snapshot (main-thread accessor for synchronous reads,
    /// e.g. the gesture tap gating check). Returns `.empty` until the first read.
    private(set) var current: FloorSnapshot = .empty

    // MARK: - Watching

    private func ensureVoiceDir() {
        try? FileManager.default.createDirectory(at: Self.voiceDir, withIntermediateDirectories: true)
    }

    /// Watch the `~/.voicemode` directory for write/rename/extend events. The CLI
    /// replaces `floor-queue.json` via temp+rename — a vnode watch on the file
    /// itself would die on the first replace, so we watch the directory instead.
    private func startDirWatcher() {
        let path = Self.voiceDir.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            log.notice("FloorQueueStore: could not open \(path, privacy: .public) for watching; poll-only.")
            return
        }
        dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.readAndPublishIfChanged() }
        src.setCancelHandler { [weak self] in
            if let self = self, self.dirFD >= 0 { close(self.dirFD); self.dirFD = -1 }
        }
        src.resume()
        dirWatcher = src
    }

    private func startPoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.readAndPublishIfChanged() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Read + diff

    /// Read both files, build a snapshot, and publish to the observer only when
    /// it differs from the last published snapshot (avoids redundant repaints).
    private func readAndPublishIfChanged() {
        let snap = readSnapshot()
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.current = snap
            self.onChange(snap)
        }
    }

    /// Build a `FloorSnapshot` from the two JSON files. Tolerant of absent /
    /// partial / malformed files (degrades to empty fields).
    func readSnapshot() -> FloorSnapshot {
        var snap = FloorSnapshot.empty

        if let floor = readJSON(Self.floorQueueURL) {
            if let holderDict = floor["floor_holder"] as? [String: Any] {
                snap.holder = FloorHolder(
                    agent: (holderDict["agent"] as? String) ?? "?",
                    pid: intValue(holderDict["pid"]),
                    since: (holderDict["since"] as? String) ?? ""
                )
            }
            if let arr = floor["queue"] as? [[String: Any]] {
                snap.queue = arr.map { e in
                    FloorEntry(
                        agent: (e["agent"] as? String) ?? "?",
                        pid: intValue(e["pid"]),
                        requestedAt: (e["requested_at"] as? String) ?? "",
                        intent: (e["intent"] as? String) ?? "speak"
                    )
                }
            }
            snap.queuePaused = (floor["queue_paused"] as? Bool) ?? false
            snap.advanceRequested = (floor["advance_requested"] as? Bool) ?? false
        }

        if let mute = readJSON(Self.muteStateURL) {
            snap.muted = (mute["muted"] as? Bool) ?? false
            snap.muteSource = mute["source"] as? String
            snap.muteDevice = mute["device"] as? String
        }

        return snap
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Partial / mid-rename read — ignore this tick; the next read will
            // catch the completed file.
            return nil
        }
        return obj
    }

    /// JSON numbers decode as NSNumber via JSONSerialization; coerce safely.
    private func intValue(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }
}
