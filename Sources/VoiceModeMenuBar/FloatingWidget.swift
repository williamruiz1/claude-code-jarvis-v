import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "FloatingWidget")

/// Small always-on-top floating panel showing VoiceMode status + a Start
/// Voice button. Draggable from anywhere on its background. Hidden via the
/// menu-bar toggle. Position persists in UserDefaults across launches.
final class FloatingWidget: NSObject {
    typealias StartHandler = () -> Void

    /// Bumped key forces a one-time reset of the saved widget frame when the
    /// widget grows in size (e.g. v1 → v2 layout adding the toggle row;
    /// v3 adds the convomode queue panel + control strip).
    /// Saved frames keyed under prior names are left in UserDefaults but are
    /// no longer read; this is harmless drift that tidies on next save.
    private static let frameDefaultsKey = "voicemode-monitor.widget.frame.v3"

    private var panel: NSPanel?
    private var iconView: NSImageView!
    private var statusLabel: NSTextField!
    private var sessionsButton: NSPopUpButton!
    private var voicePicker: WidgetVoicePicker?
    private var toggleBar: WidgetToggleBar?
    private var queuePanel: WidgetQueuePanel?
    private var controlStrip: WidgetControlStrip?
    private var floorStore: FloorQueueStore?

    /// Wired by the owner (AppDelegate) so the control strip's 🎙 Mute button
    /// can flip the device mute property. Set BEFORE `show()` so the strip
    /// picks it up at build time.
    var muteSentinel: MuteSentinel? {
        didSet { controlStrip?.muteSentinel = muteSentinel }
    }

    private let onStart: StartHandler
    private let onOpenMainWindow: StartHandler
    private let onOpenSettings: StartHandler

    /// Cached session list shown in the pull-down. NSMenu's `menuNeedsUpdate`
    /// is invoked on the main thread immediately before the menu opens, so
    /// it cannot block on `SessionDiscovery.listSessions()` (AppleScript +
    /// `ps -A` fork). Strategy: on `menuWillOpen`, render whatever cache we
    /// have AND kick off a background refresh that re-renders when fresh data
    /// arrives. First open shows "Loading…" briefly; subsequent opens are
    /// instant. Always accessed on the main thread.
    private var cachedSessions: [ClaudeSession] = []
    private var hasLoadedSessionsOnce: Bool = false
    private var pendingMenuRefresh: Bool = false

    /// `onStart` fires "+ New voice conversation" picks (existing behavior).
    /// `onOpenMainWindow` fires when the user picks "Open Main Window…" from
    /// the widget's session menu OR clicks the toolbar button on the toggle row.
    /// `onOpenSettings` fires when the user picks "More voices…" from the
    /// quick voice picker on the widget.
    init(onStart: @escaping StartHandler,
         onOpenMainWindow: @escaping StartHandler = {},
         onOpenSettings: @escaping StartHandler = {}) {
        self.onStart = onStart
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
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
            iconView.contentTintColor = active ? BrandingTheme.activeColor : BrandingTheme.idleColor
        }
        statusLabel.stringValue = active ? "Listening" : "Idle"
        statusLabel.textColor = active ? BrandingTheme.activeColor : BrandingTheme.idleColor

        // Animate the icon: gentle breathing while idle, sharper pulse while active.
        BrandingTheme.removeAnimations(from: iconView)
        if active {
            BrandingTheme.applyActivePulse(to: iconView)
        } else {
            BrandingTheme.applyIdleBreath(to: iconView)
        }
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

        // Close (hide) chevron in the corner. SF Symbols ships "xmark" in every
        // macOS we support, but the API still returns Optional<NSImage>; if the
        // symbol ever resolves nil (corrupt system caches) we'd rather show a
        // text "x" than crash on launch.
        let closeIcon = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide widget")
            ?? NSImage(size: .zero)
        let closeButton = NSButton(image: closeIcon, target: self, action: #selector(handleCloseTapped))
        if closeIcon.size == .zero { closeButton.title = "x" }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .accessoryBar
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        blur.addSubview(closeButton)

        // Wordmark — small "JARVIS-V" brand label, top-left.
        let wordmark = BrandingTheme.WordmarkView()
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(wordmark)

        // Voice quick-pick — short list of favorite voices. "More voices…" opens
        // the full Settings → Voice pane via the onOpenSettings callback.
        let picker = WidgetVoicePicker()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onOpenSettings = { [weak self] in self?.onOpenSettings() }
        blur.addSubview(picker)
        self.voicePicker = picker

        // Toggle bar — transcript Min|Full + Stop voice + Open main window.
        let bar = WidgetToggleBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onOpenMainWindow = { [weak self] in self?.onOpenMainWindow() }
        blur.addSubview(bar)
        self.toggleBar = bar

        // Convomode queue divider — separates the voice controls (above) from
        // the floor-control queue surface (below).
        let queueDivider = NSView()
        queueDivider.translatesAutoresizingMaskIntoConstraints = false
        queueDivider.wantsLayer = true
        queueDivider.layer?.backgroundColor = NSColor(srgbRed: 0x33/255, green: 0x41/255, blue: 0x5c/255, alpha: 1).cgColor
        blur.addSubview(queueDivider)

        // Convomode queue panel — the live floor queue (holder + waiters).
        let queue = WidgetQueuePanel()
        queue.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(queue)
        self.queuePanel = queue

        // Control strip — Mute / Advance / Pause-Proceed (the gesture twins).
        let strip = WidgetControlStrip()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.muteSentinel = muteSentinel
        blur.addSubview(strip)
        self.controlStrip = strip

        // Live feed — pipe floor-queue.json + mute-state.json snapshots into the
        // panel + strip (this was the missing wire: the panel was never fed).
        let store = FloorQueueStore { [weak self] snap in
            guard let self = self else { return }
            self.queuePanel?.update(snapshot: snap, sessions: self.cachedSessions)
            self.controlStrip?.update(snapshot: snap)
            self.resizePanelToFitContent() // grow/shrink as participants come and go
        }
        store.start()
        self.floorStore = store
        // Kick a session-name refresh so click-to-jump can map slugs → tabs.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = SessionDiscovery.listSessions()
            DispatchQueue.main.async { self?.cachedSessions = sessions }
        }

        NSLayoutConstraint.activate([
            // Top row — wordmark | icon + status | sessions popup
            wordmark.topAnchor.constraint(equalTo: blur.topAnchor, constant: 8),
            wordmark.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),

            iconView.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 4),
            iconView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            sessionsButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            sessionsButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // Middle row — voice picker, left of toggle bar
            picker.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),

            // Toggle bar to the right of picker
            bar.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: picker.trailingAnchor, constant: 8),

            // --- Convomode queue surface (below the existing rows) ---
            queueDivider.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 10),
            queueDivider.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            queueDivider.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            queueDivider.heightAnchor.constraint(equalToConstant: 1),

            queue.topAnchor.constraint(equalTo: queueDivider.bottomAnchor, constant: 8),
            queue.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
            queue.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -8),

            strip.topAnchor.constraint(equalTo: queue.bottomAnchor, constant: 8),
            strip.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            strip.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            // `lessThanOrEqual` (not `equal`) so the content height is driven by
            // the top-anchored chain — letting `fittingSize` report the real
            // content height so `resizePanelToFitContent()` can grow/shrink the
            // panel to fit (the queue grows by one 34pt row per participant).
            strip.bottomAnchor.constraint(lessThanOrEqualTo: blur.bottomAnchor, constant: -12),

            // Close X — top-right, untouched
            closeButton.topAnchor.constraint(equalTo: blur.topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        self.panel = panel
        updateState(active: false)
        resizePanelToFitContent()
    }

    /// Size the panel's height to exactly fit its content, anchored at the top
    /// edge (the widget lives top-right and grows downward). Called after build
    /// and on every queue change so the convomode queue + control strip are
    /// never clipped — and the panel never carries dead space. Defensively
    /// clamped so a bad measurement can't produce an absurd panel.
    private func resizePanelToFitContent() {
        guard let panel = panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fit = content.fittingSize.height
        let visibleH = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000
        let target = max(160, min(fit, visibleH - 40))
        guard target > 1, abs(target - panel.frame.height) > 0.5 else { return }
        var f = panel.frame
        let topEdge = f.maxY            // keep the top fixed; grow/shrink downward
        f.size.height = target
        f.origin.y = topEdge - target
        panel.setFrame(f, display: true)
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
        // `focus` hops to a background queue internally so the menu close
        // animation stays smooth even if Terminal AppleScript is slow.
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
        // Height fits the full v3 layout (wordmark+icon+picker+divider+queue+control
        // strip ≈ 180pt empty); `resizePanelToFitContent()` then tunes it exactly.
        // The old 100pt default clipped the queue + control strip on first run.
        let size = NSSize(width: 300, height: 230)
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
        // CRITICAL: this delegate runs on the main thread immediately before
        // the menu opens. We MUST NOT call SessionDiscovery.listSessions()
        // here — it shells out to AppleScript + `ps -A` and takes 100s of ms,
        // which would freeze the menu open animation.
        //
        // Strategy:
        //   1. Render whatever cached session list we already have. First open
        //      shows an empty list with a "Loading sessions…" placeholder.
        //   2. Kick off a background refresh; when it returns, repopulate the
        //      menu in place. The user usually sees fresh data within a few
        //      hundred ms after the menu opens — and instantly on every
        //      subsequent open.
        renderMenu(menu, sessions: cachedSessions, isLoading: !hasLoadedSessionsOnce)
        scheduleBackgroundRefresh(for: menu)
    }

    /// Async refresh of `cachedSessions`. Coalesces concurrent requests so
    /// repeated menu opens don't pile up AppleScript invocations.
    private func scheduleBackgroundRefresh(for menu: NSMenu) {
        if pendingMenuRefresh { return }
        pendingMenuRefresh = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak menu] in
            let sessions = SessionDiscovery.listSessions()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingMenuRefresh = false
                self.cachedSessions = sessions
                self.hasLoadedSessionsOnce = true
                // Only repaint if the menu is still open / about to open.
                if let menu = menu {
                    self.renderMenu(menu, sessions: sessions, isLoading: false)
                }
            }
        }
    }

    private func renderMenu(_ menu: NSMenu, sessions: [ClaudeSession], isLoading: Bool) {
        // Preserve the title item (index 0) and rebuild everything below.
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }

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
        } else if isLoading {
            menu.addItem(NSMenuItem.separator())
            let loading = NSMenuItem(title: "Loading sessions…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
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
