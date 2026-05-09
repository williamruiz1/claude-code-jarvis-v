import AppKit

/// macOS preferences-window pattern: NSToolbar across the top with one button
/// per pane (Voice / Hallucinations / About). Switching a pane swaps the
/// window's content view and animates window size.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {

    enum Pane: String, CaseIterable {
        case voice
        case hallucinations
        case about

        var label: String {
            switch self {
            case .voice:          return "Voice"
            case .hallucinations: return "Hallucinations"
            case .about:          return "About"
            }
        }

        var symbolName: String {
            switch self {
            case .voice:          return "waveform"
            case .hallucinations: return "text.badge.xmark"
            case .about:          return "info.circle"
            }
        }
    }

    static let toolbarIdentifier = NSToolbar.Identifier("voicemode-monitor.settings.toolbar")
    static let frameAutosaveName = NSWindow.FrameAutosaveName("voicemode-monitor.settings.window")

    private var paneControllers: [Pane: NSViewController] = [:]
    private var currentPane: Pane = .voice

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceMode Monitor – Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.init(window: window)
        configureToolbar()
        showPane(.voice, animated: false)
    }

    func presentAndFocus() {
        if let win = window {
            // Settings is a "real" window — bring the app forward briefly so
            // it's not stuck behind another active app. We're an .accessory
            // app, so this is a temporary activation that ends when the
            // window closes.
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.center()
        }
    }

    // MARK: – Toolbar

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .preference
        }
        window?.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(Pane.voice.rawValue)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.label
        item.paletteLabel = pane.label
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.label)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        item.isBordered = true
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Pane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        showPane(pane, animated: true)
    }

    // MARK: – Pane swapping

    private func paneController(for pane: Pane) -> NSViewController {
        if let cached = paneControllers[pane] { return cached }
        let vc: NSViewController
        switch pane {
        case .voice:          vc = VoicePane()
        case .hallucinations: vc = HallucinationPatternsPane()
        case .about:          vc = AboutPane()
        }
        paneControllers[pane] = vc
        return vc
    }

    private func showPane(_ pane: Pane, animated: Bool) {
        guard let window = window else { return }
        currentPane = pane
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)

        let vc = paneController(for: pane)
        // Force-load to make sure intrinsic content size is calculable.
        // macOS 13-compatible substitute for loadViewIfNeeded() (macOS 14+);
        // accessing .view triggers load lazily.
        _ = vc.view
        let newSize = vc.view.fittingSize

        // Compute new window frame keeping top-left corner pinned (preference-pane idiom).
        let oldFrame = window.frame
        let toolbarHeight = oldFrame.height - (window.contentView?.frame.height ?? oldFrame.height)
        let targetContent = NSSize(width: max(newSize.width, 540), height: max(newSize.height, 360))
        let targetWindow = NSSize(width: targetContent.width, height: targetContent.height + toolbarHeight)
        let newOrigin = NSPoint(x: oldFrame.origin.x, y: oldFrame.origin.y + (oldFrame.height - targetWindow.height))
        let targetFrame = NSRect(origin: newOrigin, size: targetWindow)

        window.contentViewController = vc
        window.title = "VoiceMode Monitor – \(pane.label)"
        window.setFrame(targetFrame, display: true, animate: animated)
    }
}
