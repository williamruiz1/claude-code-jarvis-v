import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "WidgetQueuePanel")

/// Row badge state. File-scope so both `WidgetQueuePanel` (RowSpec) and the
/// sibling `QueueRowView.configure(...)` can reference it.
private enum Badge: Equatable {
    case live
    case hold
    case queued(Int)
}

/// Renders the convomode floor queue inside the floating widget (design §9.2,
/// mockup `convomode-queue-widget-mockup-2026-05-31.html`).
///
/// One row per `floor-queue` entry, FIFO order:
///   • the floor-holder row is badged **LIVE** (green) with a status dot
///   • queued rows show `#2`, `#3` …  with a hover "jump →"
///
/// **Row click → jump (design §9.2 / §4.2c).** Promotes that session to the
/// head of the queue (immediate, per the locked decision) by shelling
/// `convomode-floor.py promote --agent <slug>` AND focuses that Terminal
/// session via `SessionDiscovery.focus(...)`. The `<slug>` is derived from the
/// session's `/rename` title (lowercased first token) — see `slug(for:)`.
///
/// Pure AppKit; no SwiftUI. Mirrors the dark-HUD styling of the existing panel.
final class WidgetQueuePanel: NSView {

    /// Vertical stack of rows; rebuilt on each snapshot.
    private let stack = NSStackView()
    /// Placeholder shown when there are no participants.
    private let emptyLabel = NSTextField(labelWithString: "No active convomode")

    /// Map agent-slug → discovered ClaudeSession, so a row click can focus the
    /// right Terminal tab. Refreshed alongside snapshots. Main-thread only.
    private var sessionsBySlug: [String: ClaudeSession] = [:]

    /// Map claude-PID → discovered ClaudeSession. The floor registers each
    /// participant with `--pid $PPID`, so this is the identity-stable way to show
    /// the participant's renamed Terminal title (e.g. "Admin") instead of the raw
    /// registration slug (e.g. "fleet"). Main-thread only.
    private var sessionsByPid: [Int: ClaudeSession] = [:]

    /// Map floor agent-name → its registered PID (from the live snapshot), so a
    /// row click can resolve the session by PID for the focus/jump.
    private var pidByAgent: [String: Int] = [:]

    /// Last snapshot rendered — used to skip redundant rebuilds.
    private var lastSnapshot: FloorSnapshot?

    /// Signature of the sessions list last rendered. The display name resolves
    /// against the sessions list, so a sessions refresh (e.g. a slug→title
    /// resolution arriving) must force a rebuild even when the snapshot is
    /// unchanged.
    private var lastSessionsKey: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-only") }

    override var intrinsicContentSize: NSSize {
        // Width is flexible (pinned by container); height = stack's natural height.
        NSSize(width: NSView.noIntrinsicMetric, height: stack.fittingSize.height)
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 4
        addSubview(stack)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        emptyLabel.textColor = .tertiaryLabelColor
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        ])
    }

    // MARK: - Public API

    /// Update the rendered queue. Call on the main thread. `sessions` is the
    /// latest `SessionDiscovery.listSessions()` result so row clicks can focus
    /// the matching Terminal tab.
    /// True when the last render had a participant whose name could not be
    /// resolved to a Terminal session (so it showed the raw slug). The host uses
    /// this to trigger a one-shot session refresh.
    private(set) var lastRenderHadUnresolved = false

    @discardableResult
    func update(snapshot: FloorSnapshot, sessions: [ClaudeSession]) -> Bool {
        // Rebuild the lookup maps every update (cheap; sessions list is small).
        var bySlug: [String: ClaudeSession] = [:]
        var byPid: [Int: ClaudeSession] = [:]
        for s in sessions {
            bySlug[Self.slug(forTitle: s.title)] = s
            if let pid = s.claudePid { byPid[pid] = s }
        }
        sessionsBySlug = bySlug
        sessionsByPid = byPid

        // agent-name → registered PID, from the live snapshot (for row-click focus).
        var pidMap: [String: Int] = [:]
        if let h = snapshot.holder { pidMap[h.agent] = h.pid }
        for e in snapshot.queue { pidMap[e.agent] = e.pid }
        pidByAgent = pidMap

        // Skip redundant rebuilds only when BOTH the snapshot AND the sessions
        // list are unchanged — a sessions refresh can change a displayed name
        // (slug → renamed title) even when the floor snapshot is identical.
        let sessionsKey = sessions
            .map { "\($0.claudePid ?? 0):\($0.title)" }
            .sorted()
            .joined(separator: "|")
        if lastSnapshot == snapshot && lastSessionsKey == sessionsKey { return lastRenderHadUnresolved }
        lastSnapshot = snapshot
        lastSessionsKey = sessionsKey

        // Track whether any participant with a PID couldn't be matched to a
        // Terminal session this render (→ it's showing the raw slug).
        var hadUnresolved = false
        func markIfUnresolved(agent: String, pid: Int) {
            let resolved = (pid != 0 && sessionsByPid[pid] != nil) || sessionsBySlug[Self.slug(forAgent: agent)] != nil
            if !resolved { hadUnresolved = true }
        }
        if let h = snapshot.holder { markIfUnresolved(agent: h.agent, pid: h.pid) }
        for e in snapshot.queue { markIfUnresolved(agent: e.agent, pid: e.pid) }
        lastRenderHadUnresolved = hadUnresolved

        // Clear existing rows.
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        var rows: [RowSpec] = []
        if let holder = snapshot.holder {
            rows.append(RowSpec(agent: holder.agent,
                                displayName: displayName(agent: holder.agent, pid: holder.pid),
                                badge: snapshot.queuePaused ? .hold : .live,
                                meta: snapshot.queuePaused ? "holds floor · standby"
                                                           : "holding floor · live",
                                dimmed: snapshot.queuePaused))
        }
        for (i, entry) in snapshot.queue.enumerated() {
            rows.append(RowSpec(agent: entry.agent,
                                displayName: displayName(agent: entry.agent, pid: entry.pid),
                                badge: .queued(i + 2), // holder is #1; first queued is #2
                                meta: "queued",
                                dimmed: snapshot.queuePaused))
        }

        emptyLabel.isHidden = !rows.isEmpty
        for spec in rows {
            stack.addArrangedSubview(makeRow(spec))
        }
        invalidateIntrinsicContentSize()
        return hadUnresolved
    }

    /// Resolve the name to SHOW for a floor participant: the renamed Terminal
    /// session title, found first by PID (identity-stable), then by slug, and
    /// finally falling back to the raw registration name if no session maps yet.
    private func displayName(agent: String, pid: Int) -> String {
        if pid != 0, let s = sessionsByPid[pid] { return s.title }
        if let s = sessionsBySlug[Self.slug(forAgent: agent)] { return s.title }
        return agent
    }

    // MARK: - Row model

    private struct RowSpec {
        let agent: String        // raw floor registration name (slug) — used for the CLI
        let displayName: String  // renamed Terminal title to show — falls back to agent
        let badge: Badge
        let meta: String
        let dimmed: Bool
    }

    private func makeRow(_ spec: RowSpec) -> NSView {
        let row = QueueRowView(agent: spec.agent, displayName: spec.displayName) { [weak self] agent in
            self?.handleRowClick(agent: agent)
        }
        row.configure(badge: spec.badge, meta: spec.meta, dimmed: spec.dimmed)
        return row
    }

    // MARK: - Row click → promote + focus (design §9.2)

    private func handleRowClick(agent: String) {
        // 1) Promote to floor head immediately. Use the RAW agent name — that's
        //    the exact value in the queue the CLI matches on (re-slugging a
        //    multi-word name here would fail to match the queue entry).
        FloorControlCLI.promote(agent: agent)
        // 2) Jump to the Terminal session — resolve by PID first (identity-stable),
        //    then by slug.
        let session = pidByAgent[agent].flatMap { sessionsByPid[$0] }
            ?? sessionsBySlug[Self.slug(forAgent: agent)]
        if let session = session {
            SessionDiscovery.focus(session, andTriggerVoice: false)
        } else {
            log.notice("WidgetQueuePanel: no Terminal session mapped for agent \(agent, privacy: .public); promoted only.")
        }
    }

    // MARK: - Slug mapping

    /// Map a display agent name → its slug (lowercased first whitespace-delimited
    /// token). The convomode floor agents identify by a slug; the menubar derives
    /// the same slug from a session's `/rename` title. Keep this trivial + total.
    /// e.g. "YCM Coordinator" → "ycm", "Plinthkeep" → "plinthkeep".
    static func slug(forTitle title: String) -> String {
        return slug(forAgent: title)
    }

    static func slug(forAgent agent: String) -> String {
        let firstToken = agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" })
            .first
            .map(String.init) ?? agent
        return firstToken.lowercased()
    }
}

// MARK: - QueueRowView

/// A single clickable queue row: [status dot] name + meta … [badge] [jump →].
/// Click anywhere in the row → promote/jump. Hover reveals the "jump →" hint.
private final class QueueRowView: NSView {
    private let agent: String       // raw registration name passed back on click (for the CLI)
    private let displayName: String // renamed Terminal title shown in the row
    private let onClick: (String) -> Void

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let jumpLabel = NSTextField(labelWithString: "jump →")
    private var trackingArea: NSTrackingArea?

    init(agent: String, displayName: String, onClick: @escaping (String) -> Void) {
        self.agent = agent
        self.displayName = displayName
        self.onClick = onClick
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-only") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        addSubview(dot)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.stringValue = displayName
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        addSubview(metaLabel)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .heavy)
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 8
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false   // layer provides the rounded pill bg; textfield draws text only — fixes the dark-box render
        badgeLabel.isEditable = false
        addSubview(badgeLabel)

        jumpLabel.translatesAutoresizingMaskIntoConstraints = false
        jumpLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        jumpLabel.textColor = NSColor(srgbRed: 0x6a/255, green: 0xa8/255, blue: 1.0, alpha: 1.0)
        jumpLabel.alphaValue = 0 // hover reveals
        addSubview(jumpLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),

            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),

            jumpLabel.trailingAnchor.constraint(equalTo: badgeLabel.leadingAnchor, constant: -8),
            jumpLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(badge: Badge, meta: String, dimmed: Bool) {
        metaLabel.stringValue = meta
        alphaValue = dimmed ? 0.5 : 1.0
        setDotPulsing(false)   // default off; .live re-enables the on-air pulse

        switch badge {
        case .live:
            dot.layer?.backgroundColor = NSColor(srgbRed: 0x3f/255, green: 0xe0/255, blue: 0x8f/255, alpha: 1.0).cgColor
            setDotPulsing(true)   // gentle on-air pulse on the live holder's dot
            badgeLabel.stringValue = " LIVE "
            badgeLabel.textColor = NSColor(srgbRed: 0x04/255, green: 0x1e/255, blue: 0x13/255, alpha: 1.0)
            badgeLabel.layer?.backgroundColor = NSColor(srgbRed: 0x3f/255, green: 0xe0/255, blue: 0x8f/255, alpha: 1.0).cgColor
            layer?.backgroundColor = NSColor(srgbRed: 0x48/255, green: 0xd5/255, blue: 0x97/255, alpha: 0.12).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(srgbRed: 0x48/255, green: 0xd5/255, blue: 0x97/255, alpha: 0.45).cgColor
        case .hold:
            dot.layer?.backgroundColor = NSColor(srgbRed: 0x48/255, green: 0xd5/255, blue: 0x97/255, alpha: 1.0).cgColor
            badgeLabel.stringValue = " HOLD "
            badgeLabel.textColor = NSColor(srgbRed: 0x3a/255, green: 0x2a/255, blue: 0x05/255, alpha: 1.0)
            badgeLabel.layer?.backgroundColor = NSColor(srgbRed: 0xf4/255, green: 0xb7/255, blue: 0x40/255, alpha: 1.0).cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        case .queued(let n):
            dot.layer?.backgroundColor = NSColor(srgbRed: 0x5b/255, green: 0x6b/255, blue: 0x86/255, alpha: 1.0).cgColor
            badgeLabel.stringValue = " #\(n) "
            badgeLabel.textColor = .secondaryLabelColor
            badgeLabel.layer?.backgroundColor = NSColor(srgbRed: 0x22/255, green: 0x30/255, blue: 0x4a/255, alpha: 1.0).cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }
        // Only queued rows show the "jump →" hover hint (the holder is already live).
        jumpLabel.isHidden = { if case .queued = badge { return false } else { return true } }()
    }

    /// Gentle "on-air" pulse on the status dot — only the live floor-holder.
    private func setDotPulsing(_ on: Bool) {
        let key = "livePulse"
        dot.layer?.removeAnimation(forKey: key)
        guard on else { dot.layer?.opacity = 1.0; return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.35
        a.duration = 1.1
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(a, forKey: key)
    }

    // MARK: - Hover + click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        if !jumpLabel.isHidden { jumpLabel.animator().alphaValue = 1 }
        if layer?.borderWidth == 0 {
            layer?.backgroundColor = NSColor(srgbRed: 0x6a/255, green: 0xa8/255, blue: 1.0, alpha: 0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        jumpLabel.animator().alphaValue = 0
        if layer?.borderWidth == 0 {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Brief press feedback, then fire the click handler.
        onClick(agent)
    }
}
