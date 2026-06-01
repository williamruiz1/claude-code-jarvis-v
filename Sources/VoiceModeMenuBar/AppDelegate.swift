import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: MicMonitor!
    private var statusMenuItem: NSMenuItem!
    private var widget: FloatingWidget!
    private var toggleWidgetItem: NSMenuItem!
    private var muteSentinel: MuteSentinel!
    private var gestureTap: GestureTap!

    private(set) var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private let transcriptCoordinator = TranscriptCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make sure the env file reflects current settings whenever the app
        // boots — covers the case where the user edited it externally then
        // launched the app fresh.
        EnvFileWriter.writeFromCurrentSettings()
        // Touch SparkleBridge so its background update check kicks off if wired.
        _ = SparkleBridge.shared

        // Convomode mute sentinel — CoreAudio mute-property listener that writes
        // ~/.voicemode/mute-state.json (+ exposes the settable software-mute).
        muteSentinel = MuteSentinel()
        muteSentinel.start()

        // Convomode gesture tap — Next-Track media key → advance intent, gated so
        // it only consumes the event when a convomode queue exists (>1 participant);
        // otherwise the key passes through to music. start() requests Input Monitoring.
        gestureTap = GestureTap(gating: {
            let p = NSString(string: "~/.voicemode/floor-queue.json").expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return (active: false, depth: 0) }
            let holder = (obj["floor_holder"] is [String: Any]) ? 1 : 0
            let queued = (obj["queue"] as? [Any])?.count ?? 0
            return (active: holder > 0, depth: holder + queued)
        })
        gestureTap.start()

        // Floating widget — summoned on demand (NOT always present). Show/Hide via
        // the menu-bar item below, or the widget's own ✕.
        widget = FloatingWidget(
            onStart: { [weak self] in self?.startVoiceConversation() },
            onOpenMainWindow: { [weak self] in self?.showMainWindow() },
            onOpenSettings: { [weak self] in self?.showSettings() }
        )
        widget.muteSentinel = muteSentinel

        // Menu bar — secondary surface (toggle widget visibility, About, Quit).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon(active: false)

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let openMainItem = NSMenuItem(title: "Open Main Window…", action: #selector(showMainWindow), keyEquivalent: "0")
        openMainItem.target = self
        menu.addItem(openMainItem)

        toggleWidgetItem = NSMenuItem(title: "Show floating widget", action: #selector(toggleWidget), keyEquivalent: "")
        toggleWidgetItem.target = self
        menu.addItem(toggleWidgetItem)

        let startVoiceItem = NSMenuItem(title: "Start voice conversation…", action: #selector(startVoiceConversation), keyEquivalent: "")
        startVoiceItem.target = self
        menu.addItem(startVoiceItem)

        let openClaudeItem = NSMenuItem(title: "Open Claude Code (no voice)…", action: #selector(openClaudeCode), keyEquivalent: "")
        openClaudeItem.target = self
        menu.addItem(openClaudeItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let aboutItem = NSMenuItem(title: "About VoiceMode Monitor", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        monitor = MicMonitor { [weak self] active in
            DispatchQueue.main.async {
                self?.applyIcon(active: active)
                self?.statusMenuItem.title = active ? "Status: mic active" : "Status: idle"
                self?.widget.updateState(active: active)
            }
        }
        monitor.start()
    }

    @objc private func toggleWidget() {
        widget.toggle()
        toggleWidgetItem.title = widget.isVisible ? "Hide floating widget" : "Show floating widget"
    }

    @objc func showMainWindow() {
        if mainWindowController == nil {
            let controller = MainWindowController(
                onStartVoiceConversation: { [weak self] in self?.startVoiceConversation() },
                onOpenSettings: { [weak self] in self?.showSettings() }
            )
            controller.transcriptCoordinator = transcriptCoordinator
            mainWindowController = controller
        }
        mainWindowController?.presentAndFocus()
    }

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.presentAndFocus()
    }

    @objc private func checkForUpdates() {
        SparkleBridge.shared.checkForUpdates(sender: self)
    }

    private func applyIcon(active: Bool) {
        // SF Symbols pair — waveform-style, less generic than mic.
        // Idle  = "waveform.path"          (clean line waveform, neutral)
        // Active = "waveform.path.ecg"     (heartbeat-style peaks, "live signal")
        let symbolName = active ? "waveform.path.ecg" : "waveform.path"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: active ? "VoiceMode active" : "VoiceMode idle")?
            .withSymbolConfiguration(config)
        image?.isTemplate = !active // template = adapts to menu-bar light/dark; active uses tinted color
        if active, let img = image {
            img.isTemplate = false
            statusItem.button?.image = tinted(img, color: .systemRed)
        } else {
            statusItem.button?.image = image
        }
    }

    private func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    @objc private func openClaudeCode() {
        // Open Terminal.app with `claude` running. Uses AppleScript so we don't depend on user shell setup.
        // Run on background queue — NSAppleScript.executeAndReturnError can take
        // hundreds of ms (Terminal launch + script bridge); blocking the main
        // thread freezes the menu-bar pull-down for that whole window.
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error = error {
                log.error("openClaudeCode AppleScript failed: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { self?.showAccessibilityHintIfNeeded(error: error) }
            }
        }
    }

    @objc func startVoiceConversation() {
        // Open Terminal + claude, wait for it to boot, then type the voice trigger phrase.
        // The 3-second delay accounts for claude's REPL initialization on first launch.
        // Requires Accessibility permission for "VoiceMode Monitor" (granted via
        // System Settings → Privacy → Accessibility on first run).
        //
        // The voicemode MCP wrapper (registered in ~/.claude.json) is responsible for
        // sourcing ~/Library/Application Support/VoiceModeMonitor/voicemode-env.sh and
        // injecting any keychain-stored secrets at server-launch time. So the bare
        // `claude` command is sufficient — we don't need to manage env here.
        //
        // The 3-second `delay` inside the script means the AppleScript itself
        // takes 3+ seconds to return — running it on the main thread froze the
        // menu/widget for the duration. Off-main here.
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        delay 3
        tell application "System Events"
            tell process "Terminal"
                set frontmost to true
            end tell
            keystroke "let's have a voice conversation"
            keystroke return
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error = error {
                log.error("startVoiceConversation AppleScript failed: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { self?.showAccessibilityHintIfNeeded(error: error) }
            }
        }
    }

    private func showAccessibilityHintIfNeeded(error: NSDictionary) {
        // Error code -1719 = "User canceled" or related; -25211 = no Accessibility permission.
        let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
        guard code == -25211 || code == -1743 else { return }
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
        VoiceMode Monitor needs Accessibility permission to type the voice trigger phrase into Terminal.

        Open System Settings → Privacy & Security → Accessibility, then enable VoiceMode Monitor.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "VoiceMode Monitor"
        alert.informativeText = """
        Menu-bar companion for VoiceMode in Claude Code.

        Watches the system microphone state and reflects it in the menu bar:
        • mic outlined = idle
        • mic filled (red tint) = listening

        Use the Settings panel to choose the TTS voice and configure ElevenLabs.

        Version \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
