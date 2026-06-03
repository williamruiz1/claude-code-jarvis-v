import Foundation
import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "SessionDiscovery")

/// Status of a Claude Code session as reflected in its terminal title prefix.
///
/// Claude Code sets a leading status character on the terminal title via OSC
/// escape codes:
///   - **Braille pattern characters** (U+2800–U+28FF, e.g. `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ ⠐ ⠂`)
///     are spinner frames Claude rotates through while actively processing a
///     turn. Treated as ACTIVE.
///   - **Pinwheel / star characters** (U+2733 ✳, U+2736 ✶, U+2734 ✴) are the
///     idle marker — Claude has finished its turn and is waiting for the user.
///     Treated as IDLE.
///   - Anything else is UNKNOWN (we still display the session, just without a
///     confident status badge).
enum SessionStatus {
    case active
    case idle
    case unknown

    var label: String {
        switch self {
        case .active: return "Active"
        case .idle:   return "Idle"
        case .unknown: return "—"
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .active: return .systemGreen
        case .idle:   return .secondaryLabelColor
        case .unknown: return .tertiaryLabelColor
        }
    }
}

/// Identifies a single Claude Code terminal session by its location in
/// Terminal.app, the custom title the session set via `/rename`, and the
/// parsed activity status from the title's leading indicator character.
struct ClaudeSession: Equatable {
    let title: String          // Prefix-stripped, e.g. "Marginalia Coordinator"
    let status: SessionStatus  // Parsed from the title's leading char
    let windowID: Int
    let tabIndex: Int
    /// PID of the `claude` process running in this tab. This is the identity the
    /// convomode floor registers (`--pid $PPID`), so it's the stable key for
    /// mapping a floor-queue participant back to its renamed Terminal title.
    let claudePid: Int?
    /// Whether this session's `claude` started recently enough to have the
    /// voicemode env (the "+ New voice" menu only offers voice-capable ones).
    /// Name resolution for the floor queue ignores this — a floor participant is
    /// voice-capable by definition regardless of when its process started.
    let voiceCapable: Bool

    init(title: String, status: SessionStatus, windowID: Int, tabIndex: Int,
         claudePid: Int? = nil, voiceCapable: Bool = true) {
        self.title = title
        self.status = status
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.claudePid = claudePid
        self.voiceCapable = voiceCapable
    }
}

/// Lists Claude Code sessions by interrogating Terminal.app via AppleScript.
///
/// Heuristic: we treat every Terminal tab whose `custom title` differs from
/// its default (the cwd / running process display) as a candidate Claude
/// session. The cleanest signal is when you've run `/rename` inside Claude
/// Code — that escape code sets the tab's custom title.
///
/// False positives are possible (a manually renamed non-claude tab), but
/// rare enough in practice. False negatives happen when claude is running
/// in a tab without `/rename` having been issued — those tabs are titled
/// like "claude — 80×24" (Terminal default) and excluded.
enum SessionDiscovery {

    static func listSessions() -> [ClaudeSession] {
        // Detection strategy:
        //   1. Get the IDs of every Terminal window — yields some `missing value`
        //      entries for zombie windows. Iterate by ID, NOT `repeat with w in
        //      windows` (the latter chokes on missing values).
        //   2. For each valid ID, fetch parallel arrays of (custom title, tty,
        //      processes) across all tabs. Bulk-fetch syntax — works on Terminal
        //      where `tab i of w` does not.
        //   3. Include a tab only if its process list contains "claude" AND the
        //      claude process in that tty was launched after the voicemode MCP
        //      registration was set up to inject OPENAI_API_KEY. Older claude
        //      sessions still have voicemode running without the env var and
        //      cannot actually have voice conversations — so they are excluded.
        let script = """
        set out to ""
        tell application "Terminal"
            -- Iterate windows DIRECTLY. The prior version did `set winIDs to id of
            -- every window` then `first window whose id is wid` — that per-window
            -- re-lookup is chronically flaky with many windows open: it
            -- intermittently returns an empty result, which dropped the queue's
            -- name resolution back to the raw lowercase floor slug (the "name
            -- isn't exact / widget didn't update" bug). Direct iteration is
            -- verified reliable across repeated runs; `try` per window still skips
            -- any zombie / missing-value window.
            repeat with w in every window
                try
                    set wid to id of w
                    set titles to custom title of every tab of w
                    set procs to processes of every tab of w
                    set ttys to tty of every tab of w
                    set tabCount to count of titles
                    repeat with i from 1 to tabCount
                        set procList to (item i of procs) as string
                        if procList contains "claude" then
                            set tTitle to (item i of titles) as string
                            set tTty to (item i of ttys) as string
                            set out to out & tTitle & "\\t" & wid & "\\t" & i & "\\t" & tTty & "\\n"
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return out
        """

        // Caller contract: must NOT be invoked on the main thread.
        // AppleScript execution + ps fork below can take 100s of ms — running
        // on main freezes the UI. Internal asserts here so a regression is loud.
        if Thread.isMainThread {
            log.error("SessionDiscovery.listSessions called on main thread — UI will freeze. Move to background queue.")
            assertionFailure("SessionDiscovery.listSessions must be called off the main thread.")
        }
        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let output = appleScript.executeAndReturnError(&error)
        if let error = error {
            log.error("listSessions AppleScript failed: \(String(describing: error), privacy: .public)")
            return []
        }
        guard let raw = output.stringValue, !raw.isEmpty else { return [] }

        // Build a TTY → most-recent-claude-PID-start-time map ONCE via a single
        // `ps -A` call. O(processes) work happens once instead of O(sessions ×
        // ps spawn) — the per-session fork was the 2-3 second dropdown lag.
        let tty2info = mostRecentClaudeByTty()
        let cutoff = mcpRegistrationCutoff()

        var sessions: [ClaudeSession] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4,
                  let wid = Int(parts[1]),
                  let idx = Int(parts[2]) else { continue }
            let tty = parts[3]
            let (status, parsedTitle) = parseTitle(parts[0])
            let displayTitle = parsedTitle.isEmpty
                ? "Claude session (window \(wid))"
                : parsedTitle

            // Include EVERY claude tab; flag whether it's voice-capable (started
            // after the cutoff) rather than dropping it. The "+ New voice" menu
            // filters on the flag; the floor-queue name resolution uses all tabs
            // (a floor participant is voice-capable by definition, even if its
            // process predates the cutoff — which is exactly the case that made
            // a long-running session show its raw slug instead of its title).
            let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")
            let info = tty2info[ttyShort]
            let voiceCapable = info.map { $0.start > cutoff } ?? false

            sessions.append(ClaudeSession(title: displayTitle, status: status,
                                          windowID: wid, tabIndex: idx,
                                          claudePid: info?.pid, voiceCapable: voiceCapable))
        }
        return sessions
    }

    /// Single bulk `ps -A` call that returns a map from TTY (e.g. "ttys024")
    /// to the start time + PID of the *most recent* `claude` CLI process attached
    /// to it. Multiple claude restarts in the same tab → we keep the newest.
    /// The PID lets a floor-queue participant (registered with `--pid $PPID`) be
    /// resolved back to its Terminal tab — and thus its renamed title.
    private static func mostRecentClaudeByTty() -> [String: (start: Date, pid: Int)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "tty=,pid=,lstart=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return [:] }

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let stdout = String(data: data, encoding: .utf8) else { return [:] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        var result: [String: (start: Date, pid: Int)] = [:]
        for line in stdout.split(separator: "\n") {
            // Each line: "<tty> <pid> <Day Mon dd HH:MM:SS yyyy> <comm>"
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 8, let pid = Int(tokens[1]) else { continue }
            let tty = tokens[0]
            let comm = tokens[tokens.count - 1]
            guard comm == "claude" || comm.hasSuffix("/claude") else { continue }

            // lstart is the 5 tokens after tty+pid: "Day Mon dd HH:MM:SS yyyy".
            let lstart = tokens[2..<7].joined(separator: " ")
            guard let date = formatter.date(from: lstart) else { continue }

            // Keep only the most recent claude start per tty (handles restarts).
            if let existing = result[tty], existing.start > date { continue }
            result[tty] = (date, pid)
        }
        return result
    }

    /// Cutoff for "this claude was launched after the keychain-wrapper MCP
    /// registration was effective." Uses `~/.claude.json` mtime minus a 6-hour
    /// buffer to absorb the timing edge between when the wrapper was added and
    /// when the file's last subsequent write happened. Defaults to `.distantPast`
    /// on read failure so filtering becomes a no-op rather than hiding everything.
    private static func mcpRegistrationCutoff() -> Date {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return .distantPast
        }
        // 6-hour buffer — Claude Code itself touches .claude.json during normal
        // operation, so the strict mtime can land later than the actual wrapper
        // registration time. Permissive cutoff prevents legitimately-voice-capable
        // sessions from being false-negatived because of an unrelated file write.
        return mtime.addingTimeInterval(-6 * 60 * 60)
    }

    /// Parse a Terminal tab's custom title into (status, title without prefix).
    /// See `SessionStatus` doc for the prefix-character → status mapping.
    private static func parseTitle(_ raw: String) -> (status: SessionStatus, title: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let firstChar = trimmed.first,
              let scalar = firstChar.unicodeScalars.first else {
            return (.unknown, trimmed)
        }
        let value = scalar.value

        // Braille pattern range = active spinner frames
        if value >= 0x2800 && value <= 0x28FF {
            let stripped = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (.active, stripped)
        }

        // Pinwheel / star variants = idle marker
        if value == 0x2733 || value == 0x2736 || value == 0x2734 {
            let stripped = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (.idle, stripped)
        }

        // No recognized prefix — display as-is, status unknown.
        return (.unknown, trimmed)
    }

    /// Brings the given session's tab to the front. Optional `andTriggerVoice`
    /// will type the voice trigger phrase after activation (use this only if
    /// you know voice isn't already running in that tab — there's no reliable
    /// way to detect it from the outside).
    ///
    /// Hops to a background queue, runs the AppleScript, then calls
    /// `completion` on the main thread (or invoke without a completion to
    /// fire-and-forget). Callers from menu actions / table double-clicks can
    /// invoke this directly without freezing the UI.
    static func focus(_ session: ClaudeSession,
                      andTriggerVoice: Bool = false,
                      completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = focusBlocking(session, andTriggerVoice: andTriggerVoice)
            if let completion = completion {
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    /// Synchronous variant. Asserts when called on the main thread — use the
    /// async `focus` from UI actions. Exposed for tests / programmatic callers.
    @discardableResult
    static func focusBlocking(_ session: ClaudeSession, andTriggerVoice: Bool = false) -> Bool {
        if Thread.isMainThread {
            log.error("SessionDiscovery.focusBlocking called on main thread — UI will freeze.")
            assertionFailure("SessionDiscovery.focusBlocking must be called off the main thread.")
        }
        let voiceTrigger = andTriggerVoice
            ? """
              delay 0.4
              tell application "System Events"
                  keystroke "let's have a voice conversation"
                  keystroke return
              end tell
              """
            : ""
        let script = """
        tell application "Terminal"
            activate
            try
                set theWindow to (first window whose id is \(session.windowID))
                set frontmost of theWindow to true
                set selected tab of theWindow to tab \(session.tabIndex) of theWindow
            on error
                return "ERROR"
            end try
        end tell
        \(voiceTrigger)
        return "OK"
        """
        guard let s = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        let result = s.executeAndReturnError(&error)
        if let error = error {
            log.error("focus AppleScript failed: \(String(describing: error), privacy: .public)")
        }
        return result.stringValue == "OK"
    }
}
