import AppKit

/// Settings pane: edit the JSON-encoded list of hallucination patterns the
/// transcript subsystem matches against. We don't import the Transcript
/// module — we just own the file at:
///
///   ~/Library/Application Support/VoiceModeMonitor/hallucination-patterns.json
///
/// The Transcript agent's HallucinationDetector reads from this same path.
/// Format is a JSON array of strings, e.g. `["Thank you.", "Thanks for watching!"]`.
final class HallucinationPatternsPane: NSViewController {

    /// File path the Transcript module also reads from.
    static var patternsFilePath: URL {
        return EnvFileWriter.supportDir.appendingPathComponent("hallucination-patterns.json")
    }

    /// Seed list — common Whisper hallucinations plus voicemode-specific filler.
    /// Used as defaults when the file doesn't exist yet.
    static let seedPatterns: [String] = [
        "Thank you.",
        "Thanks for watching!",
        "Thanks for watching.",
        "Subscribe to my channel.",
        "Please subscribe.",
        "you",
        "Bye.",
        "Bye-bye.",
        "[BLANK_AUDIO]",
        "[ Silence ]",
        ".",
        "Music",
        "(music)",
    ]

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    private var lastLoadedText: String = ""

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(wrappingLabelWithString:
            "One pattern per line. The transcript view filters out lines that exactly match any of these. " +
            "Stored as a JSON array at ~/Library/Application Support/VoiceModeMonitor/hallucination-patterns.json."
        )
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.preferredMaxLayoutWidth = 540

        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)

        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        revertButton.target = self
        revertButton.action = #selector(revertPressed)
        revertButton.bezelStyle = .rounded

        resetButton.target = self
        resetButton.action = #selector(resetPressed)
        resetButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [resetButton, NSView(), revertButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fill
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        root.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            buttonRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 580),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])

        view = root
        loadFromDisk()
    }

    // MARK: – I/O

    private func loadFromDisk() {
        let url = Self.patternsFilePath
        if let data = try? Data(contentsOf: url),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            let text = array.joined(separator: "\n")
            textView.string = text
            lastLoadedText = text
            statusLabel.stringValue = "Loaded \(array.count) pattern\(array.count == 1 ? "" : "s") from disk."
        } else {
            // File missing or malformed — show seed list, but don't write
            // until the user explicitly saves. Avoids creating the file on
            // first open with content the user didn't choose.
            let text = Self.seedPatterns.joined(separator: "\n")
            textView.string = text
            lastLoadedText = ""
            statusLabel.stringValue = "No file yet. Showing default seed list — Save to create."
        }
    }

    private func writeToDisk(_ patterns: [String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: EnvFileWriter.supportDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(patterns)
            try data.write(to: Self.patternsFilePath, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: – actions

    @objc private func savePressed() {
        let raw = textView.string
        let patterns = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if writeToDisk(patterns) {
            lastLoadedText = patterns.joined(separator: "\n")
            textView.string = lastLoadedText
            statusLabel.stringValue = "Saved \(patterns.count) pattern\(patterns.count == 1 ? "" : "s")."
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "Save failed — check folder permissions."
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func revertPressed() {
        loadFromDisk()
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func resetPressed() {
        let alert = NSAlert()
        alert.messageText = "Reset to defaults?"
        alert.informativeText = "Your current patterns will be replaced with the seed list. The file isn't written until you Save."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            textView.string = Self.seedPatterns.joined(separator: "\n")
            statusLabel.stringValue = "Reset to defaults (unsaved)."
            statusLabel.textColor = .secondaryLabelColor
        }
    }
}
