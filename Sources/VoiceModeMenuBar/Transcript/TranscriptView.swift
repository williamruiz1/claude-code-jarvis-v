import AppKit

/// Render mode for `TranscriptView`. Persisted in UserDefaults across launches
/// per the v2 transcript spec — minimal-by-default with a deliberate user toggle
/// to chrome.
enum TranscriptRenderMode: String {
    case minimal   // only Claude's replies, plain text — default
    case chrome    // every turn, timestamped, labelled, blockquoted, with HRs
}

/// NSView that renders a `TranscriptStore` as a scrollable rich-text feed.
///
/// Observes `TranscriptStore.didAppendTurn` to incrementally append new turns
/// (no full re-layout per insert), and auto-scrolls to bottom when new content
/// arrives.
///
/// The render mode toggle is owned externally (via `TranscriptToggleControl`
/// or programmatically via `setMode(_:)`); this view just listens for the
/// `TranscriptView.modeDidChange` notification and re-renders.
final class TranscriptView: NSView {

    /// UserDefaults key for the persisted render mode.
    static let modeDefaultsKey = "voicemode-monitor.transcript.mode"

    /// Posted when the user toggles render mode. `userInfo["mode"]` is the new
    /// `TranscriptRenderMode.rawValue`.
    static let modeDidChange = Notification.Name("voicemode-monitor.transcript.modeDidChange")

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private weak var store: TranscriptStore?
    private var observers: [NSObjectProtocol] = []

    /// Hard cap on rendered turns. The text view only ever holds the most recent
    /// `maxRenderedTurns`; older turns are trimmed from the front of the text
    /// storage. This bounds TextKit layout cost to O(cap) per append instead of
    /// O(session-length) — the fix for the 100%-CPU main-thread peg where
    /// `scrollToEndOfDocument` re-laid-out a multi-hundred-MB document on every
    /// turn. The full history still lives on disk via `TranscriptStore`.
    private let maxRenderedTurns = 400

    /// Char length of each rendered turn segment, oldest→newest, so we can trim
    /// the exact prefix range when over `maxRenderedTurns`.
    private var segmentLengths: [Int] = []

    /// Coalesces scroll-to-bottom requests so a burst of appends triggers ONE
    /// scroll (one layout pass), not one per turn.
    private var scrollPending = false

    /// Current render mode. Setter persists to UserDefaults and re-renders.
    private(set) var mode: TranscriptRenderMode

    init(store: TranscriptStore? = nil, frame frameRect: NSRect = .zero) {
        let saved = UserDefaults.standard.string(forKey: TranscriptView.modeDefaultsKey)
            .flatMap(TranscriptRenderMode.init(rawValue:)) ?? .minimal
        self.mode = saved
        self.store = store
        super.init(frame: frameRect)
        buildSubviews()
        wireObservers()
        renderAll()
    }

    required init?(coder: NSCoder) {
        fatalError("TranscriptView is code-only; init(coder:) is not supported")
    }

    deinit {
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
    }

    /// Swap the store this view tracks. Useful when the host (AppDelegate / main
    /// window) follows the active session as William moves between Terminal tabs.
    func setStore(_ newStore: TranscriptStore?) {
        self.store = newStore
        renderAll()
    }

    /// Update the render mode, persist the choice, broadcast, and re-render.
    func setMode(_ newMode: TranscriptRenderMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: TranscriptView.modeDefaultsKey)
        NotificationCenter.default.post(
            name: TranscriptView.modeDidChange,
            object: self,
            userInfo: ["mode": newMode.rawValue]
        )
        renderAll()
    }

    // MARK: - Build

    private func buildSubviews() {
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        textView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    private func wireObservers() {
        let appendObs = NotificationCenter.default.addObserver(
            forName: TranscriptStore.didAppendTurn,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let storeObj = note.object as? TranscriptStore,
                  storeObj === self.store,
                  let turn = note.userInfo?["turn"] as? Turn else { return }
            self.appendTurn(turn)
        }
        observers.append(appendObs)

        let modeObs = NotificationCenter.default.addObserver(
            forName: TranscriptView.modeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  note.object as AnyObject? !== self,
                  let raw = note.userInfo?["mode"] as? String,
                  let mode = TranscriptRenderMode(rawValue: raw),
                  mode != self.mode else { return }
            self.mode = mode
            self.renderAll()
        }
        observers.append(modeObs)
    }

    // MARK: - Render

    /// Full re-render. Called on store-swap or mode-change. Per-turn appends
    /// use `appendTurn(_:)` to avoid the cost.
    private func renderAll() {
        let storage = textView.textStorage ?? NSTextStorage()
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString())
        segmentLengths.removeAll(keepingCapacity: true)
        if let turns = store?.snapshot() {
            // Only render the most recent `maxRenderedTurns`; the rest stay on disk.
            var first = true
            for turn in turns.suffix(maxRenderedTurns) {
                let piece = attributedString(for: turn, isFirst: first)
                guard piece.length > 0 else { continue } // minimal mode suppresses non-Claude turns
                storage.append(piece)
                segmentLengths.append(piece.length)
                first = false
            }
        }
        storage.endEditing()
        requestScrollToBottom(force: true)
    }

    private func appendTurn(_ turn: Turn) {
        let storage = textView.textStorage ?? NSTextStorage()
        let isFirst = storage.length == 0
        let piece = attributedString(for: turn, isFirst: isFirst)
        guard piece.length > 0 else { return } // minimal mode emits nothing for non-Claude turns

        // Don't yank the scroll if the user has deliberately scrolled up to read
        // back; only auto-follow when they're already near the bottom.
        let follow = isScrolledNearBottom()

        storage.beginEditing()
        storage.append(piece)
        segmentLengths.append(piece.length)
        // Trim oldest rendered turns so the document — and thus every layout pass —
        // stays bounded. Amortized O(1): one turn appended, ~one trimmed at steady state.
        while segmentLengths.count > maxRenderedTurns {
            let drop = segmentLengths.removeFirst()
            if drop > 0, drop <= storage.length {
                storage.deleteCharacters(in: NSRange(location: 0, length: drop))
            }
        }
        storage.endEditing()

        if follow { requestScrollToBottom(force: false) }
    }

    /// True when the viewport is already at (or within ~80pt of) the document
    /// bottom — the signal that the user wants to keep following new turns.
    private func isScrolledNearBottom() -> Bool {
        let clip = scrollView.contentView
        let docHeight = textView.frame.height
        guard docHeight > 0 else { return true }
        let visibleMaxY = clip.bounds.origin.y + clip.bounds.height
        return (docHeight - visibleMaxY) < 80
    }

    /// Coalesced scroll-to-bottom. Multiple calls in one runloop turn collapse to
    /// a single `scrollToEndOfDocument` — and because the document is capped to
    /// `maxRenderedTurns`, that call is now cheap regardless of session length.
    private func requestScrollToBottom(force: Bool) {
        if scrollPending { return }
        scrollPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scrollPending = false
            self.textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Attributed string construction

    private func attributedString(for turn: Turn, isFirst: Bool) -> NSAttributedString {
        switch mode {
        case .minimal:
            return minimalLine(for: turn)
        case .chrome:
            return chromeBlock(for: turn, isFirst: isFirst)
        }
    }

    /// Minimal mode: only render Claude's replies. User and system turns are
    /// suppressed entirely. Plain text, no labels, no timestamps.
    private func minimalLine(for turn: Turn) -> NSAttributedString {
        guard turn.role == .claude else { return NSAttributedString() }
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph(lineSpacing: 3, paragraphSpacing: 8),
        ]
        return NSAttributedString(string: turn.text + "\n", attributes: body)
    }

    /// Chrome mode: timestamp + bold speaker label + blockquote body + HR.
    private func chromeBlock(for turn: Turn, isFirst: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if !isFirst {
            // Horizontal rule separator. NSAttributedString has no native HR; use
            // a thin line of figure-dash characters in tertiary color, which
            // renders as a clean separator across the visible width.
            let hr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph(paragraphSpacing: 6, alignment: .left),
            ]
            result.append(NSAttributedString(string: String(repeating: "─", count: 30) + "\n", attributes: hr))
        }

        // "HH:MM:SS  Speaker:" header
        let timestamp = Self.timeFormatter.string(from: turn.timestamp)
        let header: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        result.append(NSAttributedString(string: "\(timestamp)  ", attributes: header))

        let label = speakerLabel(for: turn.role)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: speakerColor(for: turn.role),
        ]
        result.append(NSAttributedString(string: "\(label)\n", attributes: labelAttrs))

        // Blockquote: leading thick colored vertical bar via a paragraph head-indent
        // plus a NSTextAttachment-free trick — we use head indent and a glyph in
        // the line's leading whitespace position. Cheaper: prefix each wrapped line
        // with "▎ " using firstLineHeadIndent / headIndent via paragraph style.
        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.firstLineHeadIndent = 0
        quoteParagraph.headIndent = 14
        quoteParagraph.lineSpacing = 3
        quoteParagraph.paragraphSpacing = 6

        let bar: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: speakerColor(for: turn.role).withAlphaComponent(0.55),
            .paragraphStyle: quoteParagraph,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: turn.flags.hallucinationDetected
                ? NSColor.tertiaryLabelColor
                : NSColor.labelColor,
            .paragraphStyle: quoteParagraph,
        ]

        // The bar precedes the body inline. NSTextView doesn't render a CSS-style
        // border-left, so we fake it with a single thick char + a thin space.
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "▎", attributes: bar))
        line.append(NSAttributedString(string: " ", attributes: body))
        line.append(NSAttributedString(string: turn.text, attributes: body))
        if turn.flags.hallucinationDetected {
            let suffix: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular).withItalicTrait(),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: quoteParagraph,
            ]
            line.append(NSAttributedString(
                string: "  (STT hallucination on silence — input ignored)",
                attributes: suffix
            ))
        }
        line.append(NSAttributedString(string: "\n", attributes: body))
        result.append(line)
        return result
    }

    // MARK: - Helpers

    private func speakerLabel(for role: Turn.Role) -> String {
        switch role {
        case .user: return "You"
        case .claude: return "Claude"
        case .system: return "System"
        }
    }

    private func speakerColor(for role: Turn.Role) -> NSColor {
        switch role {
        case .user: return .systemBlue
        case .claude: return .systemPurple
        case .system: return .systemOrange
        }
    }

    private func paragraph(
        lineSpacing: CGFloat = 0,
        paragraphSpacing: CGFloat = 0,
        alignment: NSTextAlignment = .natural
    ) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = paragraphSpacing
        p.alignment = alignment
        return p
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - NSFont italic helper

private extension NSFont {
    /// Synthesize an italic variant of a system font when the family doesn't
    /// expose a true italic face. Falls back to the original if the manager
    /// can't produce one.
    func withItalicTrait() -> NSFont {
        let mgr = NSFontManager.shared
        let italic = mgr.convert(self, toHaveTrait: .italicFontMask)
        return italic
    }
}
