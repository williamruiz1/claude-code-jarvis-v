import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "WidgetControlStrip")

/// The three convomode control buttons — the on-screen twins of the AirPods
/// gestures (design §9.2, mockup strip). Lives at the bottom of the floating
/// widget's queue panel.
///
/// | Button            | Gesture twin     | Action                                            |
/// |-------------------|------------------|---------------------------------------------------|
/// | 🎙 Mute / Unmute  | single-click     | flip the device Mute property via `MuteSentinel`  |
/// | ⏭ Advance         | double-click     | `convomode-floor.py request-advance`              |
/// | ⏸ Pause / ▶ Proceed | global hold    | `convomode-floor.py pause` / `proceed`            |
///
/// Each button flash-acknowledges like `WidgetVoicePicker`. The mute + pause
/// buttons reflect current state (label/icon flip). If the floor CLI is
/// unavailable, Advance + Pause/Proceed disable with an explanatory tooltip
/// (the Mute button stays enabled — it only needs CoreAudio, not the CLI).
final class WidgetControlStrip: NSView {

    /// Owner supplies the live `MuteSentinel` so the 🎙 button can flip the
    /// device mute property (the guaranteed-clean path, design §3.4).
    var muteSentinel: MuteSentinel?

    private let stack = NSStackView()
    private let muteButton = NSButton()
    private let advanceButton = NSButton()
    private let pauseButton = NSButton()

    /// Cached state used to render labels/icons.
    private var isMuted = false
    private var isPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-only") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 38)
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        configureButton(muteButton, symbol: "mic.fill", title: "Mute",
                        tooltip: "Mute / unmute the mic (single-click gesture)",
                        action: #selector(handleMute))
        configureButton(advanceButton, symbol: "forward.end.fill", title: "Advance",
                        tooltip: "Advance to the next queued session (double-click gesture)",
                        action: #selector(handleAdvance))
        configureButton(pauseButton, symbol: "pause.fill", title: "Pause",
                        tooltip: "Pause all handoffs (global hold)",
                        action: #selector(handlePause))

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.addArrangedSubview(muteButton)
        stack.addArrangedSubview(advanceButton)
        stack.addArrangedSubview(pauseButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        applyCLIAvailability()
    }

    /// Configure a labeled icon button. SF Symbol with a text-title fallback.
    private func configureButton(_ button: NSButton, symbol: String, title: String,
                                 tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.imagePosition = .imageLeading
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.title = title
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            button.image = img.withSymbolConfiguration(cfg) ?? img
        }
    }

    /// Disable the CLI-dependent buttons when `convomode-floor.py` is missing.
    private func applyCLIAvailability() {
        let available = FloorControlCLI.isAvailable
        advanceButton.isEnabled = available
        pauseButton.isEnabled = available
        if !available {
            let hint = "convomode-floor.py not found at ~/.local/bin/founder-os/ — install the floor CLI to enable."
            advanceButton.toolTip = hint
            pauseButton.toolTip = hint
        }
    }

    // MARK: - State updates (from the FloorQueueStore snapshot)

    /// Reflect the latest snapshot's mute + paused flags in the button labels.
    func update(snapshot: FloorSnapshot) {
        setMuted(snapshot.muted)
        setPaused(snapshot.queuePaused)
    }

    private func setMuted(_ muted: Bool) {
        guard muted != isMuted || muteButton.title.isEmpty else { isMuted = muted; return }
        isMuted = muted
        muteButton.title = muted ? "Unmute" : "Mute"
        if #available(macOS 11.0, *) {
            let symbol = muted ? "mic.slash.fill" : "mic.fill"
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: muteButton.title) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                muteButton.image = img.withSymbolConfiguration(cfg) ?? img
            }
        }
        muteButton.contentTintColor = muted ? BrandingTheme.brandAccent : nil
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused || pauseButton.title.isEmpty else { isPaused = paused; return }
        isPaused = paused
        pauseButton.title = paused ? "Proceed" : "Pause"
        if #available(macOS 11.0, *) {
            let symbol = paused ? "play.fill" : "pause.fill"
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: pauseButton.title) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                pauseButton.image = img.withSymbolConfiguration(cfg) ?? img
            }
        }
        pauseButton.contentTintColor = paused
            ? NSColor(srgbRed: 0x48/255, green: 0xd5/255, blue: 0x97/255, alpha: 1.0) // green = proceed
            : nil
    }

    // MARK: - Actions

    @objc private func handleMute(_ sender: NSButton) {
        // The Mute button flips the device mute property directly (guaranteed-
        // clean path). It does NOT require the floor CLI.
        if let sentinel = muteSentinel {
            let ok = sentinel.toggle()
            if !ok {
                log.notice("WidgetControlStrip: device has no settable Mute property; mute toggle no-op.")
            }
        } else {
            log.notice("WidgetControlStrip: no MuteSentinel wired; mute button is a no-op.")
        }
        flash(sender)
    }

    @objc private func handleAdvance(_ sender: NSButton) {
        FloorControlCLI.requestAdvance()
        flash(sender)
    }

    @objc private func handlePause(_ sender: NSButton) {
        if isPaused {
            // Proceed: resume. Let speech play again, reopen the mic, unfreeze the queue.
            FloorControlCLI.clearLivePause()
            muteSentinel?.setMuted(false)
            FloorControlCLI.proceed()
        } else {
            // Pause: cut speech mid-sentence (flag), stop listening (mute), freeze the queue.
            FloorControlCLI.setLivePause()
            if let s = muteSentinel { s.setMuted(true) }
            FloorControlCLI.pause()
        }
        flash(sender)
    }

    // MARK: - Flash acknowledgement (mirrors WidgetVoicePicker)

    private var flashTimers: [ObjectIdentifier: Timer] = [:]

    private func flash(_ button: NSButton) {
        let id = ObjectIdentifier(button)
        flashTimers[id]?.invalidate()
        guard let layer = button.layer else { return }
        layer.backgroundColor = BrandingTheme.brandAccent.withAlphaComponent(0.35).cgColor
        flashTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak button] _ in
            guard let button = button else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            button.layer?.backgroundColor = NSColor.clear.cgColor
            CATransaction.commit()
        }
    }

    deinit { flashTimers.values.forEach { $0.invalidate() } }
}
