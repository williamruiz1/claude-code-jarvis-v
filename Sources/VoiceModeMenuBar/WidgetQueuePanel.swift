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

    /// Last snapshot rendered — used to skip redundant rebuilds.
    private var lastSnapshot: FloorSnapshot?

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
    func update(snapshot: FloorSnapshot, sessions: [ClaudeSession]) {
        // Rebuild the slug→session map every update (cheap; sessions list is small).
        var map: [String: ClaudeSession] = [:]
        for s in sessions { map[Self.slug(forTitle: s.title)] = s }
        sessionsBySlug = map

        // Skip redundant rebuilds when nothing visible changed.
        if lastSnapshot == snapshot { return }
        lastSnapshot = snapshot

        // Clear existing rows.
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        var rows: [RowSpec] = []
        if let holder = snapshot.holder {
            rows.append(RowSpec(agent: holder.agent,
                                badge: snapshot.queuePaused ? .hold : .live,
                                meta: snapshot.queuePaused ? "holds floor · standby"
                                                           : "holding floor · live",
                                dimmed: snapshot.queuePaused))
        }
        for (i, entry) in snapshot.queue.enumerated() {
            rows.append(RowSpec(agent: entry.agent,
                                badge: .queued(i + 2), // holder is #1; first queued is #2
                                meta: "queued",
                                dimmed: snapshot.queuePaused))
        }

        emptyLabel.isHidden = !rows.isEmpty
        for spec in rows {
            stack.addArrangedSubview(makeRow(spec))
        }
        invalidateIntrinsicContentSize()
    }

    // MARK: - Row model

    private struct RowSpec {
        let agent: String
        let badge: Badge
        let meta: String
        let dimmed: Bool
    }

    private func makeRow(_ spec: RowSpec) -> NSView {
        let row = QueueRowView(agent: spec.agent) { [weak self] agent in
            self?.handleRowClick(agent: agent)
        }
        row.configure(badge: spec.badge, meta: spec.meta, dimmed: spec.dimmed)
        return row
    }

    // MARK: - Row click → promote + focus (design §9.2)

    private func handleRowClick(agent: String) {
        let slug = Self.slug(forAgent: agent)
        // 1) Promote to floor head immediately (intent via CLI — the single writer).
        FloorControlCLI.promote(agent: slug)
        // 2) Jump to the Terminal session if we can map the slug to one.
        if let session = sessionsBySlug[slug] {
            SessionDiscovery.focus(session, andTriggerVoice: false)
        } else {
            log.notice("WidgetQueuePanel: no Terminal session mapped for slug \(slug, privacy: .public); promoted only.")
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
    private let agent: String
    private let onClick: (String) -> Void

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let jumpLabel = NSTextField(labelWithString: "jump →")
    private var trackingArea: NSTrackingArea?

    init(agent: String, onClick: @escaping (String) -> Void) {
        self.agent = agent
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
        nameLabel.stringValue = agent
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
