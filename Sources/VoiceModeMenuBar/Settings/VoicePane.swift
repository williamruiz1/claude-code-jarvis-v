import AppKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "VoicePane")

/// Settings pane: choose TTS backend (OpenAI / Kokoro / Piper / ElevenLabs /
/// macOS / Custom), choose / enter the voice ID, and (for ElevenLabs) manage
/// the API key stored in macOS Keychain.
///
/// All changes are wired live — selecting a new voice immediately
/// (a) saves to UserDefaults and (b) regenerates the env file the
/// voicemode wrapper sources. Changes apply to the **next** voicemode
/// session that boots; running sessions are unaffected.
///
/// ### Two-level picker
///
/// First control:  Backend popup
/// Second control: Voice popup (driven from `VoiceCatalog.voices(for:)`)
///                 or a free-form text field for ElevenLabs / Custom.
///
/// A "Test voice" button is always present. It saves current settings,
/// then plays a fixed sample sentence through whichever backend is
/// selected — HTTP for OpenAI/Kokoro/Piper/ElevenLabs (returned audio
/// played via `AVAudioPlayer`), `/usr/bin/say -v` for macOS.
final class VoicePane: NSViewController {

    private var settings = VoiceSettings.load()

    private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voicePopup   = NSPopUpButton(frame: .zero, pullsDown: false)
    private let elevenVoiceField = NSTextField()
    private let customVoiceField = NSTextField()
    private let customModelField = NSTextField()
    private let customBaseURLField = NSTextField()
    private let voiceDescriptionLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Test voice", target: nil, action: nil)
    private let testStatusLabel = NSTextField(labelWithString: "")
    private let backendHelpLabel = NSTextField(labelWithString: "")

    // ElevenLabs key row
    private let apiKeyField = NSSecureTextField()
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")

    // Form rows we hide/show by backend.
    private var voicePopupRow: NSStackView!     // shared by openai/kokoro/piper/macos
    private var elevenVoiceRow: NSStackView!
    private var customRows: NSStackView!
    private var elevenKeyRows: NSStackView!

    // Audio player kept as a property so it isn't deallocated mid-playback.
    private var testPlayer: AVAudioPlayer?

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        // --- Backend selector
        let backendLabel = NSTextField(labelWithString: "TTS Backend")
        backendLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        backendPopup.removeAllItems()
        for b in VoiceSettings.Backend.allCases {
            backendPopup.addItem(withTitle: b.displayName)
            backendPopup.lastItem?.representedObject = b.rawValue
        }
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)
        let backendRow = makeRow(label: backendLabel, control: backendPopup, controlWidth: 200)
        root.addArrangedSubview(backendRow)

        backendHelpLabel.font = .systemFont(ofSize: 11)
        backendHelpLabel.textColor = .secondaryLabelColor
        backendHelpLabel.maximumNumberOfLines = 0
        backendHelpLabel.preferredMaxLayoutWidth = 480
        root.addArrangedSubview(indentedDescription(backendHelpLabel))

        // --- Voice popup row (used for openai / kokoro / piper / macos)
        let voicePopupLabel = NSTextField(labelWithString: "Voice")
        voicePopupLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        voicePopup.target = self
        voicePopup.action = #selector(voicePopupChanged)
        voiceDescriptionLabel.font = .systemFont(ofSize: 11)
        voiceDescriptionLabel.textColor = .secondaryLabelColor
        voiceDescriptionLabel.maximumNumberOfLines = 0
        voiceDescriptionLabel.preferredMaxLayoutWidth = 480

        voicePopupRow = NSStackView(views: [
            makeRow(label: voicePopupLabel, control: voicePopup, controlWidth: 280),
            indentedDescription(voiceDescriptionLabel),
        ])
        voicePopupRow.orientation = .vertical
        voicePopupRow.alignment = .leading
        voicePopupRow.spacing = 4
        root.addArrangedSubview(voicePopupRow)

        // --- ElevenLabs voice ID row (free-form text)
        let elevenVoiceLabel = NSTextField(labelWithString: "Voice ID")
        elevenVoiceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        elevenVoiceField.placeholderString = "ElevenLabs voice UUID"
        elevenVoiceField.target = self
        elevenVoiceField.action = #selector(elevenVoiceChanged(_:))
        elevenVoiceField.delegate = self
        elevenVoiceField.identifier = NSUserInterfaceItemIdentifier("elevenVoice")
        elevenVoiceField.stringValue = settings.backend == .elevenlabs ? settings.voice : ""
        elevenVoiceRow = NSStackView(views: [
            makeRow(label: elevenVoiceLabel, control: elevenVoiceField, controlWidth: 280),
        ])
        elevenVoiceRow.orientation = .vertical
        elevenVoiceRow.alignment = .leading
        root.addArrangedSubview(elevenVoiceRow)

        // --- ElevenLabs API key rows.
        // ElevenLabs requires an API key (in macOS Keychain) AND the Creator tier
        // ($22/mo) for full voice library + cloning API access. The key is shared
        // with whatever VoiceMode wrapper actually proxies the request.
        let apiKeyLabel = NSTextField(labelWithString: "API Key (Keychain)")
        apiKeyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        apiKeyField.placeholderString = "Paste ElevenLabs API key"
        apiKeyField.target = self
        apiKeyField.action = nil
        let saveKeyButton = NSButton(title: "Save Key", target: self, action: #selector(saveElevenLabsKey))
        saveKeyButton.bezelStyle = .rounded
        let clearKeyButton = NSButton(title: "Clear", target: self, action: #selector(clearElevenLabsKey))
        clearKeyButton.bezelStyle = .rounded

        let keyRow = NSStackView(views: [apiKeyField, saveKeyButton, clearKeyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.alignment = .firstBaseline
        apiKeyField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor

        elevenKeyRows = NSStackView(views: [
            makeRow(label: apiKeyLabel, control: keyRow, controlWidth: 380),
            indentedDescription(apiKeyStatusLabel),
        ])
        elevenKeyRows.orientation = .vertical
        elevenKeyRows.alignment = .leading
        elevenKeyRows.spacing = 8
        root.addArrangedSubview(elevenKeyRows)

        // --- Custom backend rows
        let customVoiceLabel = NSTextField(labelWithString: "Voice")
        customVoiceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        customVoiceField.placeholderString = "Voice identifier"
        customVoiceField.delegate = self
        customVoiceField.identifier = NSUserInterfaceItemIdentifier("customVoice")
        customVoiceField.stringValue = settings.backend == .custom ? settings.voice : ""

        let customModelLabel = NSTextField(labelWithString: "Model (optional)")
        customModelLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        customModelField.placeholderString = "e.g. tts-1-hd"
        customModelField.delegate = self
        customModelField.identifier = NSUserInterfaceItemIdentifier("customModel")
        customModelField.stringValue = settings.customModel

        let customBaseURLLabel = NSTextField(labelWithString: "Base URL (optional)")
        customBaseURLLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        customBaseURLField.placeholderString = "https://api.example.com/v1"
        customBaseURLField.delegate = self
        customBaseURLField.identifier = NSUserInterfaceItemIdentifier("customBaseURL")
        customBaseURLField.stringValue = settings.customBaseURL

        customRows = NSStackView(views: [
            makeRow(label: customVoiceLabel, control: customVoiceField, controlWidth: 280),
            makeRow(label: customModelLabel, control: customModelField, controlWidth: 280),
            makeRow(label: customBaseURLLabel, control: customBaseURLField, controlWidth: 340),
        ])
        customRows.orientation = .vertical
        customRows.alignment = .leading
        customRows.spacing = 8
        root.addArrangedSubview(customRows)

        // --- Test button row (always visible).
        testButton.target = self
        testButton.action = #selector(testVoice)
        testButton.bezelStyle = .rounded
        testStatusLabel.font = .systemFont(ofSize: 11)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.maximumNumberOfLines = 0
        testStatusLabel.preferredMaxLayoutWidth = 480
        let testRow = NSStackView(views: [testButton, testStatusLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 12
        testRow.alignment = .firstBaseline
        root.addArrangedSubview(testRow)

        // --- Footer note
        let note = NSTextField(wrappingLabelWithString:
            "Voice changes take effect on the next Claude Code session that launches voicemode. " +
            "Already-running sessions keep their current voice until you restart claude in that tab."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 480
        root.addArrangedSubview(note)

        // Container
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        view = container
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true

        applyInitialSelection()
        rebuildVoicePopup()
        refreshVisibility()
        updateVoiceDescription()
        updateBackendHelp()
        refreshKeyStatus()
    }

    // MARK: – helpers

    private func makeRow(label: NSView, control: NSView, controlWidth: CGFloat) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        if let lbl = label as? NSTextField {
            lbl.widthAnchor.constraint(equalToConstant: 140).isActive = true
            lbl.alignment = .right
        }
        if !(control is NSStackView) {
            control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        }
        return row
    }

    private func indentedDescription(_ label: NSTextField) -> NSStackView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 152).isActive = true
        let row = NSStackView(views: [spacer, label])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .top
        return row
    }

    private func applyInitialSelection() {
        backendPopup.selectItem(withTitle: settings.backend.displayName)
    }

    /// Rebuild the voice popup contents from `VoiceCatalog` for the current
    /// backend, then select the persisted voice (or the default for that
    /// backend if the persisted voice isn't valid here).
    private func rebuildVoicePopup() {
        voicePopup.removeAllItems()
        let voices = VoiceCatalog.voices(for: settings.backend)
        for v in voices {
            voicePopup.addItem(withTitle: v.label)
            voicePopup.lastItem?.representedObject = v.id
            voicePopup.lastItem?.toolTip = v.blurb
        }
        // Select the persisted voice if it exists in the catalog;
        // otherwise fall back to the backend's default and persist that.
        if let item = voicePopup.itemArray.first(where: { ($0.representedObject as? String) == settings.voice }) {
            voicePopup.select(item)
        } else if !voices.isEmpty {
            settings.voice = VoiceCatalog.defaultVoiceId(for: settings.backend)
            voicePopup.selectItem(at: 0)
            if let id = voicePopup.selectedItem?.representedObject as? String {
                settings.voice = id
            }
        }
    }

    private func refreshVisibility() {
        // Voice popup is shown for backends that have a static catalog.
        let backendsWithPopup: Set<VoiceSettings.Backend> = [.openai, .kokoro, .piper, .macos]
        voicePopupRow.isHidden  = !backendsWithPopup.contains(settings.backend)
        elevenVoiceRow.isHidden = (settings.backend != .elevenlabs)
        elevenKeyRows.isHidden  = (settings.backend != .elevenlabs)
        customRows.isHidden     = (settings.backend != .custom)
    }

    private func updateVoiceDescription() {
        let voices = VoiceCatalog.voices(for: settings.backend)
        let blurb = voices.first(where: { $0.id == settings.voice })?.blurb ?? ""
        voiceDescriptionLabel.stringValue = blurb
    }

    private func updateBackendHelp() {
        switch settings.backend {
        case .openai:
            backendHelpLabel.stringValue = "Cloud TTS via OpenAI. Uses your existing OPENAI_API_KEY (Keychain). Per-character billing."
        case .kokoro:
            backendHelpLabel.stringValue = "Local TTS via Kokoro on \(VoiceCatalog.kokoroBaseURL). Free, runs offline. Installed by the VoiceMode installer."
        case .piper:
            backendHelpLabel.stringValue = "Local TTS via Piper on \(VoiceCatalog.piperBaseURL). Free, runs offline. Run ./scripts/install-piper-jarvis.sh once to provision the voices and start the server."
        case .elevenlabs:
            backendHelpLabel.stringValue = "ElevenLabs cloud voice library. Requires an API key + Creator tier ($22/mo) for the full voice library and cloning API. Voice ID is the 20-character hash from the ElevenLabs dashboard."
        case .macos:
            backendHelpLabel.stringValue = "macOS built-in voices via /usr/bin/say. Free, ships with every Mac. NOT routed through VoiceMode — Test button below previews the voice; the full conversation flow stays on your previous backend."
        case .custom:
            backendHelpLabel.stringValue = "Free-form: enter any voice / model / OpenAI-compatible base URL. Use this for self-hosted endpoints."
        }
    }

    private func refreshKeyStatus() {
        // Optimistic placeholder so the panel doesn't render with an empty
        // status line while the background check runs.
        apiKeyStatusLabel.stringValue = "Checking Keychain…"
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        // KeychainHelper.read forks `/usr/bin/security`, which can take 50–
        // 200 ms (and may show a Keychain prompt on first access). Doing
        // that on the main thread froze settings-pane open / re-show.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasKey = KeychainHelper.readElevenLabsKey() != nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                if hasKey {
                    self.apiKeyStatusLabel.stringValue = "Stored in Keychain (service: elevenlabs-api-key)."
                    self.apiKeyStatusLabel.textColor = .systemGreen
                } else {
                    self.apiKeyStatusLabel.stringValue = "No key stored. Voicemode will fail to call ElevenLabs without one."
                    self.apiKeyStatusLabel.textColor = .systemOrange
                }
            }
        }
    }

    private func saveAndPropagate() {
        settings.save()
        EnvFileWriter.writeFromCurrentSettings()
        NotificationCenter.default.post(name: .voiceSettingsDidChange, object: nil)
    }

    private func setTestStatus(_ s: String, color: NSColor = .secondaryLabelColor) {
        DispatchQueue.main.async {
            self.testStatusLabel.stringValue = s
            self.testStatusLabel.textColor = color
        }
    }

    // MARK: – actions

    @objc private func backendChanged() {
        guard let raw = backendPopup.selectedItem?.representedObject as? String,
              let b = VoiceSettings.Backend(rawValue: raw) else { return }
        settings.backend = b
        // When switching backends, pick a sensible default voice that exists
        // in the new backend's catalog (if any) — otherwise leave whatever
        // free-form value the user typed in for elevenlabs/custom.
        let catalog = VoiceCatalog.voices(for: b)
        if !catalog.isEmpty && !catalog.contains(where: { $0.id == settings.voice }) {
            settings.voice = VoiceCatalog.defaultVoiceId(for: b)
        }
        rebuildVoicePopup()
        refreshVisibility()
        updateVoiceDescription()
        updateBackendHelp()
        setTestStatus("")
        saveAndPropagate()
    }

    @objc private func voicePopupChanged() {
        guard let id = voicePopup.selectedItem?.representedObject as? String else { return }
        settings.voice = id
        updateVoiceDescription()
        setTestStatus("")
        saveAndPropagate()
    }

    @objc private func elevenVoiceChanged(_ sender: NSTextField) {
        settings.voice = sender.stringValue
        saveAndPropagate()
    }

    @objc private func saveElevenLabsKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Always clear the field BEFORE awaiting the write — we don't want the
        // plaintext lingering even in a secure field while we wait on the fork.
        apiKeyField.stringValue = ""
        // Background the keychain write — `security add-generic-password`
        // forks a process and can prompt the user, neither of which should
        // happen on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = KeychainHelper.writeElevenLabsKey(key)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok {
                    self.refreshKeyStatus()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save key"
                    alert.informativeText = "The `security` CLI returned an error. Try again, or run `security add-generic-password -s elevenlabs-api-key -a $USER -w <key> -U` manually."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @objc private func clearElevenLabsKey() {
        // Background the delete for the same reason as save — keep main free.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            KeychainHelper.delete(service: KeychainHelper.elevenLabsService, account: KeychainHelper.currentUser)
            DispatchQueue.main.async { self?.refreshKeyStatus() }
        }
    }

    // MARK: – Test voice

    @objc private func testVoice() {
        // Always re-save first so the env file is in sync with what we're about to test.
        saveAndPropagate()
        testButton.isEnabled = false
        setTestStatus("Testing…")

        let backend = settings.backend
        let voice = settings.voice
        let sample = VoiceCatalog.sampleSentence

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { DispatchQueue.main.async { self?.testButton.isEnabled = true } }
            switch backend {
            case .macos:
                self?.runSay(voice: voice, text: sample)
            case .openai:
                self?.fetchAndPlayOpenAILike(
                    baseURL: "https://api.openai.com/v1",
                    voice: voice,
                    model: "tts-1",
                    text: sample,
                    apiKeyService: "openai-api-key"
                )
            case .kokoro:
                self?.fetchAndPlayOpenAILike(
                    baseURL: VoiceCatalog.kokoroBaseURL,
                    voice: voice,
                    model: "kokoro",
                    text: sample,
                    apiKeyService: nil
                )
            case .piper:
                self?.fetchAndPlayOpenAILike(
                    baseURL: VoiceCatalog.piperBaseURL,
                    voice: voice,
                    model: "piper",
                    text: sample,
                    apiKeyService: nil
                )
            case .elevenlabs:
                if voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.setTestStatus("Enter an ElevenLabs voice ID first.", color: .systemOrange)
                    return
                }
                self?.fetchAndPlayElevenLabs(voiceID: voice, text: sample)
            case .custom:
                let base = self?.settings.customBaseURL ?? ""
                let model = self?.settings.customModel ?? ""
                if base.isEmpty {
                    self?.setTestStatus("Set a Custom Base URL first.", color: .systemOrange)
                    return
                }
                self?.fetchAndPlayOpenAILike(
                    baseURL: base,
                    voice: voice,
                    model: model.isEmpty ? "tts-1" : model,
                    text: sample,
                    apiKeyService: nil
                )
            }
        }
    }

    /// macOS `say -v <voice> <text>`. Runs synchronously on the calling
    /// queue (already a background queue). Reports availability errors.
    private func runSay(voice: String, text: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = ["-v", voice, text]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            setTestStatus("Couldn't run /usr/bin/say: \(error.localizedDescription)", color: .systemRed)
            return
        }
        if task.terminationStatus == 0 {
            setTestStatus("Played via /usr/bin/say -v \(voice).", color: .systemGreen)
        } else {
            // Most common cause: voice not installed. Tell the user where
            // to download it.
            let msg = (try? stderr.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            setTestStatus("`say` failed (\(task.terminationStatus)). \(msg)\nVoice may not be installed — System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.", color: .systemOrange)
        }
    }

    /// POST `<baseURL>/audio/speech` with the OpenAI-compatible body, then
    /// hand the returned audio to AVAudioPlayer. Used for OpenAI / Kokoro /
    /// Piper / Custom — they all speak the same shape.
    private func fetchAndPlayOpenAILike(
        baseURL: String,
        voice: String,
        model: String,
        text: String,
        apiKeyService: String?
    ) {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/audio/speech") else {
            setTestStatus("Invalid base URL: \(baseURL)", color: .systemRed)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let svc = apiKeyService,
           let key = KeychainHelper.read(service: svc, account: KeychainHelper.currentUser) {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "voice": voice,
            "input": text,
            "response_format": "mp3",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var http: HTTPURLResponse?
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, r, e in
            data = d; http = r as? HTTPURLResponse; err = e
            sem.signal()
        }.resume()
        sem.wait()

        if let err = err {
            setTestStatus("Network error: \(err.localizedDescription)", color: .systemRed)
            return
        }
        guard let http = http else {
            setTestStatus("No HTTP response.", color: .systemRed)
            return
        }
        guard (200..<300).contains(http.statusCode), let audio = data, !audio.isEmpty else {
            let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200)
            setTestStatus("HTTP \(http.statusCode) from \(url.host ?? "server"). \(body)", color: .systemRed)
            return
        }
        playAudio(audio)
        setTestStatus("Played \(audio.count) bytes from \(url.host ?? baseURL).", color: .systemGreen)
    }

    /// ElevenLabs has a non-OpenAI shape. POST
    /// `https://api.elevenlabs.io/v1/text-to-speech/<voice_id>` with the
    /// `xi-api-key` header (NOT `Authorization: Bearer`). Returns audio/mpeg.
    private func fetchAndPlayElevenLabs(voiceID: String, text: String) {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            setTestStatus("Invalid voice ID for URL.", color: .systemRed)
            return
        }
        guard let key = KeychainHelper.readElevenLabsKey() else {
            setTestStatus("No ElevenLabs API key saved — set it above first.", color: .systemOrange)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue(key, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var http: HTTPURLResponse?
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, r, e in
            data = d; http = r as? HTTPURLResponse; err = e
            sem.signal()
        }.resume()
        sem.wait()

        if let err = err {
            setTestStatus("Network error: \(err.localizedDescription)", color: .systemRed)
            return
        }
        guard let http = http else {
            setTestStatus("No HTTP response from ElevenLabs.", color: .systemRed)
            return
        }
        guard (200..<300).contains(http.statusCode), let audio = data, !audio.isEmpty else {
            let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200)
            setTestStatus("ElevenLabs HTTP \(http.statusCode). \(body)", color: .systemRed)
            return
        }
        playAudio(audio)
        setTestStatus("Played \(audio.count) bytes from ElevenLabs.", color: .systemGreen)
    }

    private func playAudio(_ data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            // Retain the player as a property so it isn't deallocated before
            // playback finishes.
            DispatchQueue.main.async {
                self.testPlayer = player
                player.prepareToPlay()
                player.play()
            }
        } catch {
            setTestStatus("Couldn't decode returned audio: \(error.localizedDescription)", color: .systemRed)
        }
    }
}

// MARK: – live text-field updates

extension VoicePane: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let id = field.identifier?.rawValue else { return }
        switch id {
        case "elevenVoice":
            settings.voice = field.stringValue
        case "customVoice":
            settings.voice = field.stringValue
        case "customModel":
            settings.customModel = field.stringValue
        case "customBaseURL":
            settings.customBaseURL = field.stringValue
        default:
            return
        }
        saveAndPropagate()
    }
}

extension Notification.Name {
    /// Posted when any voice-setting changes. The main window's status bar
    /// observes this to refresh its "OpenAI · onyx voice" label.
    static let voiceSettingsDidChange = Notification.Name("voicemode-monitor.voiceSettingsDidChange")
}
