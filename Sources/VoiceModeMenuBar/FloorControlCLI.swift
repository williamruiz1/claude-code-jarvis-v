import Foundation
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "FloorControlCLI")

/// Thin Swift wrapper over `convomode-floor.py` — the canonical single
/// writer/reader of `~/.voicemode/floor-queue.json`.
///
/// **Design contract (per the build dispatch).** The Swift widget MUST drive
/// floor-control INTENTS by shelling out to this CLI — it MUST NOT reimplement
/// the JSON state machine in Swift. The only Swift-side state work is READING
/// `floor-queue.json` for rendering (that lives in `FloorQueueStore`). Every
/// mutation — advance / pause / proceed / promote — routes through here.
///
/// All invocations run on a background queue and are fire-and-forget from the
/// caller's perspective (UI buttons flash-acknowledge immediately; the resulting
/// state change arrives via the `FloorQueueStore` file-watch). If the CLI is
/// missing or errors, the call is logged and a `false` result is returned to the
/// optional completion so callers can degrade (e.g. disable the control strip).
enum FloorControlCLI {

    /// Resolve the CLI path at runtime. Canonical location is
    /// `~/.local/bin/founder-os/convomode-floor.py`; `$HOME` resolved live.
    /// Returns nil if the script isn't present (control strip degrades to
    /// disabled with a tooltip in that case).
    static func resolvePath() -> String? {
        let candidate = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/bin/founder-os/convomode-floor.py")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// True if the CLI is present + executable (cached per-call; cheap stat).
    static var isAvailable: Bool { resolvePath() != nil }

    /// Locate a python3 interpreter. Prefer `/usr/bin/python3` (always present on
    /// modern macOS via the Command Line Tools shim); fall back to a PATH lookup.
    private static func resolvePython() -> String {
        let usrBin = "/usr/bin/python3"
        if FileManager.default.isExecutableFile(atPath: usrBin) { return usrBin }
        // Fallback: common Homebrew / pyenv locations.
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return usrBin // last resort; Process.run will surface the error if absent
    }

    // MARK: - Intents (the four widget controls + targeting)

    /// `request-advance` — boundary-safe: the holder yields at its next turn
    /// boundary (the soft "next" gesture). The widget's ⏭ Advance button.
    static func requestAdvance(completion: ((Bool) -> Void)? = nil) {
        run(["request-advance"], completion: completion)
    }

    /// `advance` — force the hand-off NOW (the rapid double-press / force path).
    static func advance(completion: ((Bool) -> Void)? = nil) {
        run(["advance"], completion: completion)
    }

    /// `pause` — global hold; freezes all handoffs. The widget's ⏸ Pause button.
    static func pause(completion: ((Bool) -> Void)? = nil) {
        run(["pause"], completion: completion)
    }

    /// `proceed` — resume from a global hold. The widget's ▶ Proceed button.
    static func proceed(completion: ((Bool) -> Void)? = nil) {
        run(["proceed"], completion: completion)
    }

    /// `promote --agent <slug>` — targeting / jump: move the agent to the head
    /// of the queue AND give it the floor immediately (per design §4.2c +
    /// §9.2: row click → jump). The widget's per-row click.
    static func promote(agent: String, completion: ((Bool) -> Void)? = nil) {
        run(["promote", "--agent", agent], completion: completion)
    }

    // MARK: - Runner

    /// Execute `python3 convomode-floor.py <args...>` on a background queue.
    /// Completion (if provided) is delivered on the MAIN thread with the
    /// success bool (exit 0 + no thrown error == true).
    private static func run(_ args: [String], completion: ((Bool) -> Void)?) {
        guard let scriptPath = resolvePath() else {
            log.error("convomode-floor.py not found; intent \(args.joined(separator: " "), privacy: .public) dropped.")
            if let completion = completion {
                DispatchQueue.main.async { completion(false) }
            }
            return
        }
        let python = resolvePython()
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: python)
            task.arguments = [scriptPath] + args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            var ok = false
            do {
                try task.run()
                task.waitUntilExit()
                ok = (task.terminationStatus == 0)
                if !ok {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errStr = String(data: errData ?? Data(), encoding: .utf8) ?? ""
                    log.error("convomode-floor.py \(args.joined(separator: " "), privacy: .public) exit=\(task.terminationStatus) err=\(errStr, privacy: .public)")
                }
            } catch {
                log.error("convomode-floor.py launch failed: \(String(describing: error), privacy: .public)")
                ok = false
            }
            if let completion = completion {
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }
}
