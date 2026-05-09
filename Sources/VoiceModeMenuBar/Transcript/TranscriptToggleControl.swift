import AppKit

/// Small AppKit control that flips `TranscriptView` between minimal and chrome
/// render modes. Visually a two-segment NSSegmentedControl labelled
/// "Minimal | Full". The selected segment reflects the persisted mode at init
/// time, and is kept in sync with external changes via `TranscriptView.modeDidChange`.
///
/// Wires to `TranscriptView` over NotificationCenter so callers can drop the
/// control anywhere in their view hierarchy without an explicit binding.
final class TranscriptToggleControl: NSView {

    private let segmented = NSSegmentedControl(labels: ["Minimal", "Full"], trackingMode: .selectOne, target: nil, action: nil)
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        wireObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("TranscriptToggleControl is code-only; init(coder:) is not supported")
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Intrinsic size — keeps the control compact in toolbars / sidebars.
    override var intrinsicContentSize: NSSize {
        return segmented.intrinsicContentSize
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.controlSize = .small
        segmented.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        segmented.target = self
        segmented.action = #selector(handleSegmentChanged(_:))
        addSubview(segmented)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: trailingAnchor),
            segmented.topAnchor.constraint(equalTo: topAnchor),
            segmented.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Initial selection from persisted state.
        let saved = UserDefaults.standard.string(forKey: TranscriptView.modeDefaultsKey)
            .flatMap(TranscriptRenderMode.init(rawValue:)) ?? .minimal
        segmented.selectedSegment = (saved == .minimal) ? 0 : 1
    }

    private func wireObserver() {
        observer = NotificationCenter.default.addObserver(
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

    @objc private func handleSegmentChanged(_ sender: NSSegmentedControl) {
        let mode: TranscriptRenderMode = (sender.selectedSegment == 0) ? .minimal : .chrome
        UserDefaults.standard.set(mode.rawValue, forKey: TranscriptView.modeDefaultsKey)
        NotificationCenter.default.post(
            name: TranscriptView.modeDidChange,
            object: self,
            userInfo: ["mode": mode.rawValue]
        )
    }
}
