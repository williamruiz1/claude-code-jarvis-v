import AppKit

/// The main window. Three-zone layout:
///
///   ┌──────────────── NSToolbar ───────────────────────┐
///   │ [+ New voice] [Settings] [Refresh]               │
///   ├────────┬─────────────────────────────────────────┤
///   │ side-  │                                         │
///   │ bar    │     TranscriptHostView (placeholder)    │
///   │ (240)  │                                         │
///   ├────────┴─────────────────────────────────────────┤
///   │ Status bar: "OpenAI · onyx voice"                │
///   └──────────────────────────────────────────────────┘
///
/// Window remembers size + position via `setFrameAutosaveName`.
///
/// **Open paths:** the menu-bar item's "Open Main Window…" item AND the
/// floating widget's gear menu both call `presentAndFocus()` here. Decision:
/// we wired the menu-bar item rather than the widget's Sessions button —
/// the Sessions button keeps its existing meaning (quick session picker)
/// because that's what muscle memory wants. A separate "Open Main Window"
/// item was added to BOTH the menu-bar dropdown AND the floating widget's
/// menu so either entry point works.
final class MainWindowController: NSWindowController, NSToolbarDelegate {

    static let toolbarIdentifier = NSToolbar.Identifier("voicemode-monitor.main.toolbar")
    static let frameAutosaveName = NSWindow.FrameAutosaveName("voicemode-monitor.main.window")

    // Toolbar item identifiers
    private static let newConversationItemID = NSToolbarItem.Identifier("new-conversation")
    private static let settingsItemID        = NSToolbarItem.Identifier("settings")
    private static let refreshItemID         = NSToolbarItem.Identifier("refresh")
    private static let copyTranscriptItemID  = NSToolbarItem.Identifier("copy-transcript")

    private let sidebar = SessionSidebar()
    let transcriptHost = TranscriptHostView()
    private let statusBarLabel = NSTextField(labelWithString: "")
    private let mainSplit = NSSplitView()

    private let onStartVoiceConversation: () -> Void
    private let onOpenSettings: () -> Void

    init(onStartVoiceConversation: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.onStartVoiceConversation = onStartVoiceConversation
        self.onOpenSettings = onOpenSettings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceMode Monitor"
        window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)
        layoutContent()
        configureToolbar()
        sidebar.delegate = self
        statusBarLabel.stringValue = VoiceSettings.load().statusBarDescription
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceSettingsChanged),
            name: .voiceSettingsDidChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Optional transcript bridge. Set once by the app delegate; the host
    /// installs the live transcript view + toggle into the main window's
    /// placeholder zone on first present.
    var transcriptCoordinator: TranscriptCoordinator? {
        didSet { installTranscriptIfPossible() }
    }

    private var transcriptInstalled = false

    /// Bring the window to front. Activates the app (we're an .accessory app
    /// so this is a transient activation that ends when the window closes).
    func presentAndFocus() {
        // Refresh the sidebar each time we show the window — sessions could
        // have come/gone since last open.
        sidebar.reload()
        statusBarLabel.stringValue = VoiceSettings.load().statusBarDescription
        installTranscriptIfPossible()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Install the transcript view + a small toggle control bar at the top
    /// of the host area. Idempotent — multiple presents won't restack.
    private func installTranscriptIfPossible() {
        guard let coordinator = transcriptCoordinator, !transcriptInstalled else { return }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let toggle = coordinator.toggle
        toggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggle)

        let transcript = coordinator.view
        transcript.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(transcript)

        NSLayoutConstraint.activate([
            toggle.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            toggle.heightAnchor.constraint(equalToConstant: 22),

            transcript.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 8),
            transcript.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        transcriptHost.installContentView(container)
        transcriptInstalled = true
    }

    /// Toolbar / menu hook — copies the current transcript as the end-of-session
    /// markdown report.
    @objc func copyTranscriptReport() {
        transcriptCoordinator?.copyReportToClipboard()
        let alert = NSAlert()
        alert.messageText = "Transcript copied to clipboard"
        alert.informativeText = "Full session report (both sides, all timestamps) is on your clipboard."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: – Layout

    private func layoutContent() {
        guard let window = window else { return }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        // Main split: sidebar | host
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        transcriptHost.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.addArrangedSubview(sidebar)
        mainSplit.addArrangedSubview(transcriptHost)
        mainSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        mainSplit.autosaveName = NSSplitView.AutosaveName("voicemode-monitor.main.split")

        // Status bar
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusBarLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusBarLabel.textColor = .secondaryLabelColor
        statusBarLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusIcon = NSImageView()
        statusIcon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.translatesAutoresizingMaskIntoConstraints = false

        statusBar.addSubview(separator)
        statusBar.addSubview(statusIcon)
        statusBar.addSubview(statusBarLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            statusIcon.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusIcon.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 1),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),

            statusBarLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 6),
            statusBarLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 1),

            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

        content.addSubview(mainSplit)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: content.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Initial split position: 260pt sidebar.
        mainSplit.setPosition(260, ofDividerAt: 0)
        window.contentView = content
    }

    // MARK: – Toolbar

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .unified
        }
        window?.toolbar = toolbar
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newConversationItemID:
            return makeItem(id: itemIdentifier, label: "New voice conversation",
                            symbol: "plus.bubble", action: #selector(toolbarNewConversation))
        case Self.settingsItemID:
            return makeItem(id: itemIdentifier, label: "Settings",
                            symbol: "gearshape", action: #selector(toolbarSettings))
        case Self.refreshItemID:
            return makeItem(id: itemIdentifier, label: "Refresh",
                            symbol: "arrow.clockwise", action: #selector(toolbarRefresh))
        case Self.copyTranscriptItemID:
            return makeItem(id: itemIdentifier, label: "Copy transcript",
                            symbol: "doc.on.clipboard", action: #selector(copyTranscriptReport))
        default:
            return nil
        }
    }

    private func makeItem(id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            Self.newConversationItemID,
            Self.copyTranscriptItemID,
            .flexibleSpace,
            Self.refreshItemID,
            Self.settingsItemID,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            Self.newConversationItemID,
            Self.copyTranscriptItemID,
            Self.settingsItemID,
            Self.refreshItemID,
            .flexibleSpace,
            .space,
        ]
    }

    // MARK: – Toolbar actions

    @objc private func toolbarNewConversation() { onStartVoiceConversation() }
    @objc private func toolbarSettings() { onOpenSettings() }
    @objc private func toolbarRefresh() { sidebar.reload() }

    // MARK: – Notifications

    @objc private func voiceSettingsChanged() {
        statusBarLabel.stringValue = VoiceSettings.load().statusBarDescription
    }
}

// MARK: – Sidebar wiring

extension MainWindowController: SessionSidebarDelegate {

    func sessionSidebar(_ sidebar: SessionSidebar, didSelect session: ClaudeSession?) {
        // Forward into the host so the Transcript module (when wired) can load
        // the matching transcript.
        transcriptHost.onSessionSelected?(session)
        if session == nil {
            transcriptHost.setEmptyStateSubtitle("Pick a session from the sidebar on the left.")
            transcriptHost.showEmptyState()
        } else if transcriptHost.onSessionSelected == nil {
            // Transcript module hasn't wired in yet — show a friendly subtitle
            // explaining what would happen.
            transcriptHost.setEmptyStateSubtitle("Transcript module not yet attached. Selected: \(session?.title ?? "—")")
        }
    }

    func sessionSidebar(_ sidebar: SessionSidebar, didActivate session: ClaudeSession) {
        // Double-click → bring that terminal tab to the front and start voice.
        SessionDiscovery.focus(session, andTriggerVoice: true)
    }
}
