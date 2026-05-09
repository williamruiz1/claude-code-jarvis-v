import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "WidgetToggleBar")

/// Compact row of three quick controls intended to live inside the floating
/// HUD widget. Spares the user the trip to the menu bar / settings for the
/// most common in-flight actions:
///
///   1. **Transcript mode toggle** — segmented (Min | Full). Mirrors the
///      same persisted key + notification used by the main-window
///      `TranscriptToggleControl`, so flipping it here updates the main
///      window pane and vice versa.
///   2. **Stop voice** — best-effort interrupt that activates Terminal and
///      types "stop" + Return into the frontmost terminal. VoiceMode listens
///      for "stop"-class verbal/typed commands to break a converse loop.
///      LIMITATION: only works if the right Terminal window is already
///      foregrounded — there is no IPC to the active claude REPL. If no
///      Terminal is running or the wrong window is in front, the keystrokes
///      land elsewhere or the AppleScript errors silently. Acceptable v1.
///   3. **Open main window** — fires a coordinator-supplied callback. The
///      coordinator wires this to `AppDelegate.showMainWindow()` during
///      integration; the bar itself owns no window references.
///
/// Pure AppKit, no SwiftUI. Intrinsic content size = sum of children +
/// stack spacing, so the bar can drop into any container without an
/// explicit width pin.
final class WidgetToggleBar: NSView {

    // MARK: - Public API

    /// Coordinator-supplied callback for the "open main window" button.
    /// Wired to `AppDelegate.showMainWindow()` during FloatingWidget
    /// integration; remains optional so the bar can be instantiated +
    /// rendered standalone (tests, previews, etc.).
    var onOpenMainWindow: (() -> Void)?

    // MARK: - Subviews

    private let stack = NSStackView()
    private let segmented = NSSegmentedControl(
        labels: ["Min", "Full"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let stopButton = NSButton()
    private let openWindowButton = NSButton()

    private var modeObserver: NSObjectProtocol?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        wireObserver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WidgetToggleBar is code-only; init(coder:) is not supported")
    }

    deinit {
        if let modeObserver = modeObserver {
            NotificationCenter.default.removeObserver(modeObserver)
        }
    }

    // MARK: - Layout

    /// Width = sum of children + stack spacing; height = tallest child.
    /// `NSStackView.intrinsicContentSize` already gives us this when the
    /// children expose their own intrinsic sizes (segmented control + buttons
    /// all do), so we just forward.
    override var intrinsicContentSize: NSSize {
        return stack.intrinsicContentSize
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Segmented — small control size, abbreviated labels keep it compact
        // for the HUD. Initial selection mirrors the persisted mode.
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.controlSize = .small
        segmented.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        segmented.target = self
        segmented.action = #selector(handleSegmentChanged(_:))
        segmented.toolTip = "Transcript detail (Minimal vs Full)"
        let saved = UserDefaults.standard.string(forKey: TranscriptView.modeDefaultsKey)
            .flatMap(TranscriptRenderMode.init(rawValue:)) ?? .minimal
        segmented.selectedSegment = (saved == .minimal) ? 0 : 1

        // Stop button — symbol with text fallback. Bordered round-rect at small
        // size so it visually pairs with the segmented control. Image-only
        // unless the symbol is unavailable, in which case we fall back to a
        // plain "Stop" title.
        configureIconButton(
            stopButton,
            symbolName: "stop.circle",
            fallbackSymbolName: "xmark.circle",
            fallbackTitle: "Stop",
            tooltip: "Stop the active voice session (sends 'stop' to the frontmost Terminal)",
            action: #selector(handleStopVoice(_:))
        )

        // Open-main-window button — same treatment.
        configureIconButton(
            openWindowButton,
            symbolName: "macwindow",
            fallbackSymbolName: "rectangle.on.rectangle",
            fallbackTitle: "Open",
            tooltip: "Open the main window",
            action: #selector(handleOpenMainWindow(_:))
        )

        // Stack — horizontal, tight spacing, vertically centered.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.addArrangedSubview(segmented)
        stack.addArrangedSubview(stopButton)
        stack.addArrangedSubview(openWindowButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // TODO(branding): coordinator may inject `BrandingTheme.brandAccent`
        // (or similar) onto the buttons' contentTintColor at integration time
        // for the warm-amber HUD register. Defaults below use system colors so
        // this file builds and looks correct standalone.
        if #available(macOS 11.0, *) {
            stopButton.contentTintColor = NSColor.systemRed
            openWindowButton.contentTintColor = NSColor.secondaryLabelColor
        }
    }

    /// Configure a small icon button. Tries `symbolName` first, then
    /// `fallbackSymbolName`, finally falls back to a text title so the button
    /// is always usable even on a system where SF Symbols is missing the
    /// requested glyph.
    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        fallbackSymbolName: String,
        fallbackTitle: String,
        tooltip: String,
        action: Selector
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)

        let image: NSImage?
        if #available(macOS 11.0, *) {
            let primary = NSImage(systemSymbolName: symbolName, accessibilityDescription: fallbackTitle)
            let secondary = primary
                ?? NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: fallbackTitle)
            if let resolved = secondary {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                image = resolved.withSymbolConfiguration(config) ?? resolved
            } else {
                image = nil
            }
        } else {
            image = nil
        }

        if let image = image {
            button.image = image
            button.title = ""
        } else {
            // No symbol available — text fallback. Keep title short so the
            // button stays compact.
            button.image = nil
            button.title = fallbackTitle
            button.imagePosition = .noImage
        }
    }

    // MARK: - Notification sync

    /// Listen for external mode flips (e.g. the main-window toggle) so the
    /// segmented control stays in sync. Mirrors `TranscriptToggleControl`.
    private func wireObserver() {
        modeObserver = NotificationCenter.default.addObserver(
            forName: TranscriptView.modeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  note.object as AnyObject? !== self,
                  let raw = note.userInfo?["mode"] as? String,
                  let mode = TranscriptRenderMode(rawValue: raw) else { return }
            self.segmented.selectedSegment = (mode == .minimal) ? 0 : 1
        }
    }

    // MARK: - Actions

    @objc private func handleSegmentChanged(_ sender: NSSegmentedControl) {
        let mode: TranscriptRenderMode = (sender.selectedSegment == 0) ? .minimal : .chrome
        UserDefaults.standard.set(mode.rawValue, forKey: TranscriptView.modeDefaultsKey)
        // userInfo shape MUST match TranscriptToggleControl — TranscriptView
        // listens for `["mode": String]` where String is the raw value.
        NotificationCenter.default.post(
            name: TranscriptView.modeDidChange,
            object: self,
            userInfo: ["mode": mode.rawValue]
        )
    }

    @objc private func handleOpenMainWindow(_ sender: NSButton) {
        // No work owned by the bar — the coordinator decides what "open main
        // window" means in context. If no callback is wired (standalone /
        // test instance), this is a no-op rather than a crash.
        onOpenMainWindow?()
    }

    @objc private func handleStopVoice(_ sender: NSButton) {
        // Best-effort interrupt for an active claude voice session.
        //
        // VoiceMode has no IPC; the only general-purpose channel we have to
        // an in-flight `claude` REPL is keystroke injection. We type the
        // word "stop" + Return into the frontmost Terminal, which the
        // voicemode wrapper recognizes as a break-out command.
        //
        // LIMITATION: this only does the right thing if the user's Terminal
        // window with the active claude session is already in front. If not,
        // the keystrokes either land in the wrong window (relatively benign —
        // a stray "stop" line) or the AppleScript errors out (no Terminal
        // running, no Accessibility permission, etc.). The error path is
        // logged and we surface a permissions hint only for the specific
        // Accessibility-denied error codes — every other failure is silent so
        // we don't spam the user with alerts they can't act on.
        //
        // Mirrors `AppDelegate.startVoiceConversation`'s post-hardening
        // pattern: AppleScript runs on a background queue, errors bounce
        // back to the main thread for any UI work.
        let script = """
        tell application "Terminal"
            activate
        end tell
        tell application "System Events"
            tell process "Terminal"
                set frontmost to true
            end tell
            keystroke "stop"
            keystroke return
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let appleScript = NSAppleScript(source: script) else {
                log.error("WidgetToggleBar.stopVoice: failed to construct NSAppleScript")
                return
            }
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                log.error("WidgetToggleBar.stopVoice AppleScript failed: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.maybeShowAccessibilityHint(error: error)
                }
            }
        }
    }

    /// Show an alert ONLY for the Accessibility-permission-denied error
    /// codes. Every other AppleScript failure (no Terminal running, user
    /// canceled an in-flight script, etc.) is logged but swallowed — alerting
    /// on those would be noise in the v1 best-effort flow.
    private func maybeShowAccessibilityHint(error: NSDictionary) {
        let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
        guard code == -25211 || code == -1743 else { return }
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
        VoiceMode Monitor needs Accessibility permission to send the stop command to Terminal.

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
}
