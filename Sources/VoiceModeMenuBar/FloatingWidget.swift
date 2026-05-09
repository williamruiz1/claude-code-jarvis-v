import AppKit

/// Small always-on-top floating panel showing VoiceMode status + a Start
/// Voice button. Draggable from anywhere on its background. Hidden via the
/// menu-bar toggle. Position persists in UserDefaults across launches.
final class FloatingWidget: NSObject {
    typealias StartHandler = () -> Void

    private static let frameDefaultsKey = "voicemode-monitor.widget.frame"

    private var panel: NSPanel?
    private var iconView: NSImageView!
    private var statusLabel: NSTextField!
    private var sessionsButton: NSPopUpButton!
    private let onStart: StartHandler
    private let onOpenMainWindow: StartHandler

    /// `onStart` fires "+ New voice conversation" picks (existing behavior).
    /// `onOpenMainWindow` fires when the user picks "Open Main Window…" from
    /// the widget's session menu — added as a second entry point so users
    /// who live in the floating widget don't need to chase the menu-bar item.
    init(onStart: @escaping StartHandler,
         onOpenMainWindow: @escaping StartHandler = {}) {
        self.onStart = onStart
        self.onOpenMainWindow = onOpenMainWindow
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() { isVisible ? hide() : show() }

    func updateState(active: Bool) {
        guard let _ = panel else { return }
        let symbolName = active ? "waveform.path.ecg" : "waveform.path"
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            iconView.image = image
            iconView.contentTintColor = active ? .systemRed : .secondaryLabelColor
        }
        statusLabel.stringValue = active ? "Listening" : "Idle"
        statusLabel.textColor = active ? .systemRed : .secondaryLabelColor
    }

    private func buildPanel() {
        let initialFrame = loadSavedFrame() ?? defaultFrame()
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.hidesOnDeactivate = false

        // HUD-style blurred background.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialFrame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        blur.layer?.borderWidth = 0.5
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        // Icon
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        blur.addSubview(iconView)

        // Status label
        statusLabel = NSTextField(labelWithString: "Idle")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        blur.addSubview(statusLabel)

        // Sessions popup button — replaces the simple "Start voice" button.
        // Built lazily on each click so the session list is fresh.
        sessionsButton = NSPopUpButton()
        sessionsButton.translatesAutoresizingMaskIntoConstraints = false
        sessionsButton.bezelStyle = .rounded
        sessionsButton.controlSize = .small
        sessionsButton.pullsDown = true
        sessionsButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sessionsButton.menu = NSMenu()
        sessionsButton.menu?.delegate = self
        // Title cell — first item is the visible label (pull-down convention).
        let titleItem = NSMenuItem(title: "Sessions ▾", action: nil, keyEquivalent: "")
        sessionsButton.menu?.addItem(titleItem)
        blur.addSubview(sessionsButton)

        // Close (hide) chevron in the corner
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide widget")!, target: self, action: #selector(handleCloseTapped))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .accessoryBar
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        blur.addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: blur.centerYAnchor),

            sessionsButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            sessionsButton.centerYAnchor.constraint(equalTo: blur.centerYAnchor),

            closeButton.topAnchor.constraint(equalTo: blur.topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        self.panel = panel
        updateState(active: false)
    }

    @objc private func handleStartTapped() {
        onStart()
    }

    @objc private func handleCloseTapped() {
        hide()
    }

    @objc private func handleSessionPicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? ClaudeSession else { return }
        // Click an existing session = focus it AND trigger voice. The whole
        // value of the list is the ability to converse with that session;
        // focus-only would be a passive "where did I leave that tab" feature.
        SessionDiscovery.focus(session, andTriggerVoice: true)
    }

    @objc private func handleNewSession() {
        onStart()
    }

    @objc private func handleOpenMainWindow() {
        onOpenMainWindow()
    }

    // MARK: Frame persistence

    private func loadSavedFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else { return nil }
        let r = NSRectFromString(raw)
        return r.isEmpty ? nil : r
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)
    }

    private func defaultFrame() -> NSRect {
        // Default: top-right corner of the main screen, 16pt inset from edges, below menu bar.
        let size = NSSize(width: 240, height: 56)
        if let visible = NSScreen.main?.visibleFrame {
            return NSRect(
                x: visible.maxX - size.width - 16,
                y: visible.maxY - size.height - 16,
                width: size.width,
                height: size.height
            )
        }
        return NSRect(x: 100, y: 100, width: size.width, height: size.height)
    }
}

extension FloatingWidget: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        saveFrame(panel.frame)
    }
}

extension FloatingWidget: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Preserve the title item (index 0) and rebuild everything below.
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }

        let sessions = SessionDiscovery.listSessions()

        let newSessionItem = NSMenuItem(
            title: "+ New voice conversation",
            action: #selector(handleNewSession),
            keyEquivalent: ""
        )
        newSessionItem.target = self
        menu.addItem(newSessionItem)

        let openMainItem = NSMenuItem(
            title: "Open Main Window…",
            action: #selector(handleOpenMainWindow),
            keyEquivalent: ""
        )
        openMainItem.target = self
        menu.addItem(openMainItem)

        if !sessions.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "Existing sessions", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            // Sort active first, then idle, then unknown, alphabetical within each.
            let sorted = sessions.sorted { lhs, rhs in
                func order(_ s: SessionStatus) -> Int {
                    switch s {
                    case .active: return 0
                    case .idle:   return 1
                    case .unknown: return 2
                    }
                }
                let l = order(lhs.status), r = order(rhs.status)
                return l != r ? l < r : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

            for session in sorted {
                let item = NSMenuItem(
                    title: "",
                    action: #selector(handleSessionPicked(_:)),
                    keyEquivalent: ""
                )
                item.attributedTitle = makeSessionTitle(session)
                item.target = self
                item.representedObject = session
                menu.addItem(item)
            }
        } else {
            menu.addItem(NSMenuItem.separator())
            let empty = NSMenuItem(title: "No voice-capable sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            let hint1 = NSMenuItem(title: "Use \"+ New voice conversation\" above, or", action: nil, keyEquivalent: "")
            hint1.isEnabled = false
            menu.addItem(hint1)
            let hint2 = NSMenuItem(title: "restart an existing claude session (/exit then claude).", action: nil, keyEquivalent: "")
            hint2.isEnabled = false
            menu.addItem(hint2)
        }
    }

    /// Build "[BADGE]  Session Title" as an NSAttributedString with the badge
    /// rendered as a tinted rounded pill. NSMenuItem renders attributedTitle
    /// faithfully, so this gives us real visual badges in the menu.
    private func makeSessionTitle(_ session: ClaudeSession) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let badgeText = " \(session.status.label.uppercased()) "
        let badgeColor = session.status.badgeColor

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .backgroundColor: badgeColor.withAlphaComponent(0.22),
            .foregroundColor: badgeColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 2, weight: .bold),
            .kern: 0.4,
        ]
        result.append(NSAttributedString(string: badgeText, attributes: badgeAttrs))

        // Two-space gap to separate badge from title.
        result.append(NSAttributedString(string: "  ", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]))

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        result.append(NSAttributedString(string: session.title, attributes: titleAttrs))

        return result
    }
}
