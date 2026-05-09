import AppKit

/// Settings pane: app metadata + GitHub link + Sparkle "Check for Updates"
/// hook. Sparkle integration is wired but the appcast URL is a stub —
/// see README for publishing flow.
final class AboutPane: NSViewController {

    private let updateButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let appcastNoteLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? "VoiceMode Monitor"

        let icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "waveform.path.ecg",
                       accessibilityDescription: nil)?.withSymbolConfiguration(
                            .init(pointSize: 64, weight: .medium))
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: displayName)
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let versionLabel = NSTextField(labelWithString: "Version \(version) (build \(build))")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let blurb = NSTextField(wrappingLabelWithString:
            "Menu-bar companion for VoiceMode in Claude Code. Watches the system mic, " +
            "lists active claude sessions, and lets you configure TTS voice / model."
        )
        blurb.font = .systemFont(ofSize: 12)
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = 380

        let githubButton = NSButton(title: "Open GitHub Repo", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .rounded

        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        updateButton.bezelStyle = .rounded

        appcastNoteLabel.font = .systemFont(ofSize: 10)
        appcastNoteLabel.textColor = .tertiaryLabelColor
        appcastNoteLabel.alignment = .center
        appcastNoteLabel.maximumNumberOfLines = 2
        appcastNoteLabel.preferredMaxLayoutWidth = 380
        appcastNoteLabel.stringValue = SparkleBridge.shared.isOperational
            ? "Update channel: \(SparkleBridge.shared.appcastURLString)"
            : "Sparkle isn't bundled in this build — Check for Updates is a no-op."

        let buttonRow = NSStackView(views: [githubButton, updateButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [iconView, title, versionLabel, blurb, buttonRow, appcastNoteLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 24, bottom: 32, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])
        view = container
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/williamruiz1/voicemode-menubar") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        SparkleBridge.shared.checkForUpdates(sender: updateButton)
    }
}
