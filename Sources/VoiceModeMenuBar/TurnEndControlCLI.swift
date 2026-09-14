import Foundation
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "TurnEndControlCLI")

/// Thin Swift wrapper over `convomode-turn-end.sh` (W3b push-to-talk dispatch,
/// 2026-09-13) — the push-to-talk "I'm done" control. Mirrors `FloorControlCLI`'s
/// shape (resolve-path / background-run / main-thread completion) but shells
/// out to a plain bash script, not `convomode-floor.py`, so it gets its own
/// tiny wrapper rather than overloading `FloorControlCLI`'s python-runner.
///
/// What pressing this button actually does: drops
/// `~/.voicemode/turn-end.signal`, the exact file voicemode's own
/// `converse.py` polls while a turn is already listening, ending that listen
/// window on its next ~0.1s poll instead of waiting for silence-detection.
/// It is NOT a mic toggle and does not call voicemode's MCP server directly —
/// see the script's own header for the full mechanism and for why this can
/// only END a turn already in progress, never START one from outside the
/// voicemode process.
enum TurnEndControlCLI {

    /// Canonical location, same convention as `FloorControlCLI.resolvePath()`.
    static func resolvePath() -> String? {
        let candidate = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/bin/founder-os/convomode-turn-end.sh")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    static var isAvailable: Bool { resolvePath() != nil }

    /// `convomode-turn-end.sh end` — the widget's push-to-talk button.
    static func end(completion: ((Bool) -> Void)? = nil) {
        run(["end"], completion: completion)
    }

    /// Execute `convomode-turn-end.sh <args...>` on a background queue.
    /// Fire-and-forget from the caller's perspective, same contract as
    /// `FloorControlCLI.run` (completion, if given, lands on the main thread).
    private static func run(_ args: [String], completion: ((Bool) -> Void)?) {
        guard let scriptPath = resolvePath() else {
            log.error("convomode-turn-end.sh not found; intent \(args.joined(separator: " "), privacy: .public) dropped.")
            if let completion = completion {
                DispatchQueue.main.async { completion(false) }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptPath] + args
            let errPipe = Pipe()
            task.standardError = errPipe
            var ok = false
            do {
                try task.run()
                task.waitUntilExit()
                ok = (task.terminationStatus == 0)
                if !ok {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    log.error("convomode-turn-end.sh \(args.joined(separator: " "), privacy: .public) exit=\(task.terminationStatus) err=\(errStr, privacy: .public)")
                }
            } catch {
                log.error("convomode-turn-end.sh launch failed: \(String(describing: error), privacy: .public)")
                ok = false
            }
            if let completion = completion {
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }
}
