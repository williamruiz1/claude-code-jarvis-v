import AppKit

/// Placeholder host view in the main window's center pane. The Transcript
/// subsystem (built in parallel by another agent at
/// `Sources/VoiceModeMenuBar/Transcript/`) injects its own NSView into here
/// after both subsystems land. The coordinator handles the wiring.
///
/// **Integration contract for the Transcript module:**
///
///   - Get the host: `appDelegate.mainWindowController.transcriptHostView`.
///   - Inject a view: `host.installContentView(yourTranscriptView)`.
///     This will replace whatever was there before (including the empty
///     state) and pin the new view to all four edges of the host.
///   - Tell us a session was selected: the host's `delegate` (the
///     MainWindowController) calls back into the sidebar selection
///     events. Subscribe via `host.onSessionSelected = { session in ... }`.
///   - To go back to the empty state (e.g. after the selected session
///     vanishes): `host.showEmptyState()`.
///
/// Until the Transcript module wires in, this view shows a quiet empty
/// state and any session selection from the sidebar is a no-op apart from
/// updating the empty-state subtitle.
final class TranscriptHostView: NSView {

    /// Called when the user picks a session in the sidebar. The Transcript
    /// module is expected to assign this and load the corresponding transcript.
    /// The argument may be nil to indicate "no session selected".
    var onSessionSelected: ((ClaudeSession?) -> Void)?

    private let emptyStateView = NSView()
    private let emptyStateTitle = NSTextField(labelWithString: "Select a session to view its transcript.")
    private let emptyStateSubtitle = NSTextField(labelWithString: "Pick a session from the sidebar on the left.")
    private var injectedContent: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpEmptyState()
        showEmptyState()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpEmptyState()
        showEmptyState()
    }

    /// Replace the current center content (empty state or previously-injected
    /// view) with `view`. Pinned to the host's edges via Auto Layout.
    func installContentView(_ view: NSView) {
        teardownInjected()
        emptyStateView.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        injectedContent = view
    }

    /// Switch back to the placeholder empty state. Tears down any injected view.
    func showEmptyState() {
        teardownInjected()
        if emptyStateView.superview == nil {
            addSubview(emptyStateView)
            NSLayoutConstraint.activate([
                emptyStateView.topAnchor.constraint(equalTo: topAnchor),
                emptyStateView.bottomAnchor.constraint(equalTo: bottomAnchor),
                emptyStateView.leadingAnchor.constraint(equalTo: leadingAnchor),
                emptyStateView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }

    /// Update the empty-state subtitle to reflect a transient state — e.g.
    /// "Loading transcript…" or "No transcript available for this session yet."
    /// Called by both this class internally and (eventually) the Transcript module.
    func setEmptyStateSubtitle(_ text: String) {
        emptyStateSubtitle.stringValue = text
    }

    private func teardownInjected() {
        if let injected = injectedContent {
            injected.removeFromSuperview()
            injectedContent = nil
        }
    }

    private func setUpEmptyState() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .light))
        icon.contentTintColor = .tertiaryLabelColor

        emptyStateTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyStateTitle.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateTitle.textColor = .secondaryLabelColor
        emptyStateTitle.alignment = .center

        emptyStateSubtitle.translatesAutoresizingMaskIntoConstraints = false
        emptyStateSubtitle.font = .systemFont(ofSize: 12)
        emptyStateSubtitle.textColor = .tertiaryLabelColor
        emptyStateSubtitle.alignment = .center

        let stack = NSStackView(views: [icon, emptyStateTitle, emptyStateSubtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyStateView.widthAnchor, constant: -32),
        ])
    }
}
