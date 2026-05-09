import AppKit
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "WidgetVoicePicker")

/// A compact NSPopUpButton for the floating widget that shortcuts the
/// Settings → Voice flow. Shows a curated list of FAVORITE voices (a small
/// quick-pick subset of `VoiceCatalog`) plus a "More voices…" item that
/// hands off to the full settings pane via `onOpenSettings`.
///
/// **Wiring contract.** Selecting a favorite writes the chosen
/// `(backend, voice)` pair via `VoiceSettings.save()`, then posts
/// `.voiceSettingsDidChange`. `EnvFileWriter` listens (transitively, via the
/// existing settings flow) and rewrites `voicemode-env.sh`. Already-running
/// Claude Code sessions are unaffected — the next session picks up the new
/// voice when its MCP wrapper sources the env file.
///
/// **Reflects external changes.** Observes `.voiceSettingsDidChange` so the
/// popup label stays in sync if the user changes the voice from the full
/// Settings pane while the widget is visible.
///
/// **Currently-selected voice not in favorites.** If the active voice isn't
/// one of the curated quick-picks (e.g. user picked "Northern English male"
/// in Settings), it's prepended as an "Active: …" item at the top of the
/// menu, separated by a divider. That way the user can always see what's
/// active and can re-select it without rebuilding the popup state.
///
/// **Pure AppKit.** No SwiftUI. No force-unwraps with meaningful failure
/// paths. All closures capturing self use `[weak self]`.
final class WidgetVoicePicker: NSView {

    // MARK: - Public API

    /// Invoked when the user picks "More voices…" — the coordinator wires
    /// this to `AppDelegate.showSettings()` (or equivalent) on integration.
    var onOpenSettings: (() -> Void)?

    // MARK: - Favorites

    /// One curated quick-pick.
    private struct Favorite {
        let backend: VoiceSettings.Backend
        let voiceId: String
        /// Short label for the widget popup (e.g. "Jarvis"). NOT the long
        /// catalog label — the widget is space-constrained.
        let shortLabel: String
    }

    /// The curated quick-pick list. Order matters — this is the menu order.
    /// Kept short on purpose; the full catalog lives in Settings.
    private static let favorites: [Favorite] = [
        Favorite(backend: .piper,  voiceId: "jarvis",          shortLabel: "Jarvis"),
        Favorite(backend: .piper,  voiceId: "en_GB-alan-medium", shortLabel: "Alan"),
        Favorite(backend: .macos,  voiceId: "Daniel",          shortLabel: "Daniel"),
        Favorite(backend: .openai, voiceId: "onyx",            shortLabel: "Onyx"),
        Favorite(backend: .kokoro, voiceId: "bm_george",       shortLabel: "George"),
        Favorite(backend: .kokoro, voiceId: "af_bella",        shortLabel: "Bella"),
    ]

    // MARK: - Subviews

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Background layer used for the brief "selection took" flash. We tint
    /// the view's own backing layer; this view is layer-backed.
    private var flashTimer: Timer?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.clear.cgColor

        configurePopup()
        addSubview(popup)
        popup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor),
            popup.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        rebuildMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalSettingsChanged(_:)),
            name: .voiceSettingsDidChange,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        flashTimer?.invalidate()
    }

    // MARK: - Layout

    /// The widget is space-constrained. We compute width from the longest
    /// favorite label plus the "▾" affordance plus a touch of padding.
    /// Height is the standard mini-control height (~22pt).
    override var intrinsicContentSize: NSSize {
        let font = Self.widgetFont()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        // Find the widest label we'd ever show. Includes a buffer for the
        // current selection's label which may be longer than any favorite
        // (e.g. an "Active: …" entry from Settings).
        var widest: CGFloat = 0
        for fav in Self.favorites {
            let w = (fav.shortLabel as NSString).size(withAttributes: attrs).width
            if w > widest { widest = w }
        }
        // Allow a generous floor so the popup doesn't visibly resize when the
        // user picks a slightly-longer label.
        let labelFloor: CGFloat = 56  // fits "Daniel" + "▾" comfortably
        let labelWidth = max(widest, labelFloor)
        // 18pt for the popup's chevron well + 8pt visual padding inside.
        let totalWidth = ceil(labelWidth + 18 + 8)
        return NSSize(width: totalWidth, height: 22)
    }

    // MARK: - Popup configuration

    private func configurePopup() {
        popup.bezelStyle = .rounded
        popup.controlSize = .small
        popup.font = Self.widgetFont()
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.autoenablesItems = false
        popup.setContentHuggingPriority(.required, for: .vertical)
    }

    // MARK: - Menu construction

    /// Rebuild the popup menu from `VoiceSettings.load()` + the favorites
    /// list. Idempotent.
    private func rebuildMenu() {
        let current = VoiceSettings.load()
        let menu = NSMenu()
        menu.autoenablesItems = false

        // If the active voice isn't a favorite, surface it at the top so the
        // user always sees what's currently active.
        let activeIsFavorite = Self.favorites.contains {
            $0.backend == current.backend && $0.voiceId == current.voice
        }
        if !activeIsFavorite {
            let activeLabel = "Active: \(prettyName(for: current))"
            let item = NSMenuItem(title: activeLabel, action: nil, keyEquivalent: "")
            // Tag with a sentinel; selecting a sentinel item is a no-op.
            item.tag = MenuTag.activeSentinel.rawValue
            item.state = .on
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        // Favorites.
        for (idx, fav) in Self.favorites.enumerated() {
            let item = NSMenuItem(title: fav.shortLabel, action: #selector(popupChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fav
            item.tag = MenuTag.favoriteBase.rawValue + idx
            if fav.backend == current.backend && fav.voiceId == current.voice {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let more = NSMenuItem(title: "More voices…", action: #selector(moreVoicesSelected(_:)), keyEquivalent: "")
        more.target = self
        more.tag = MenuTag.moreVoices.rawValue
        menu.addItem(more)

        popup.menu = menu

        // Set the displayed title to the friendly name of whatever is active.
        // NSPopUpButton normally tracks selectedItem; we use a synthetic title
        // so an "Active:" sentinel doesn't change the popup's chrome.
        popup.title = displayLabel(for: current)
        invalidateIntrinsicContentSize()
    }

    // MARK: - Actions

    @objc private func popupChanged(_ sender: Any?) {
        guard let item = popup.selectedItem else { return }
        // Sentinel ("Active: …") items are no-ops — the active voice didn't
        // change, the user just clicked the read-only header.
        if item.tag == MenuTag.activeSentinel.rawValue {
            // Repaint state in case AppKit toggled the title.
            rebuildMenu()
            return
        }
        guard let fav = item.representedObject as? Favorite else {
            // A "More voices…" or separator slipped through somehow.
            return
        }

        var settings = VoiceSettings.load()
        // Only mutate if it actually changed — avoids redundant disk + env
        // writes (and a no-op flash).
        if settings.backend == fav.backend && settings.voice == fav.voiceId {
            return
        }
        settings.backend = fav.backend
        settings.voice = fav.voiceId
        settings.save()
        EnvFileWriter.writeFromCurrentSettings()
        NotificationCenter.default.post(name: .voiceSettingsDidChange, object: nil)
        // Our own observer will run rebuildMenu(); call it directly so the
        // label updates synchronously even if NotificationCenter delivers
        // on a later runloop turn.
        rebuildMenu()
        flashAcknowledgement()
    }

    @objc private func moreVoicesSelected(_ sender: Any?) {
        // Restore the popup's displayed title — AppKit may have temporarily
        // shown "More voices…" while the menu was open.
        let current = VoiceSettings.load()
        popup.title = displayLabel(for: current)
        if let cb = onOpenSettings {
            cb()
        } else {
            log.notice("More voices… selected but no onOpenSettings callback wired")
        }
    }

    @objc private func externalSettingsChanged(_ note: Notification) {
        // Always rebuild on the main thread — NotificationCenter delivers on
        // the posting thread, and our menu work touches AppKit.
        if Thread.isMainThread {
            rebuildMenu()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.rebuildMenu()
            }
        }
    }

    // MARK: - Visual acknowledgement

    /// Brief brand-accent background flash so the user knows the selection
    /// landed. ~0.3s, then fade back to clear.
    private func flashAcknowledgement() {
        flashTimer?.invalidate()
        guard let layer = layer else { return }
        layer.backgroundColor = Self.accentFlashColor().cgColor
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Animate back to clear over a short fade.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            self.layer?.backgroundColor = NSColor.clear.cgColor
            CATransaction.commit()
        }
    }

    // MARK: - Display helpers

    /// Friendly name for the active settings — favorite short-label if known,
    /// otherwise the catalog label, otherwise the raw voice id.
    private func displayLabel(for s: VoiceSettings) -> String {
        let name = prettyName(for: s)
        return "\(name) \u{25BE}"  // ▾
    }

    private func prettyName(for s: VoiceSettings) -> String {
        if let fav = Self.favorites.first(where: { $0.backend == s.backend && $0.voiceId == s.voice }) {
            return fav.shortLabel
        }
        if let v = VoiceCatalog.voices(for: s.backend).first(where: { $0.id == s.voice }) {
            // Strip the parenthetical suffix — too long for the widget.
            // e.g. "George (UK male)" → "George"
            if let parenIdx = v.label.firstIndex(of: "(") {
                let trimmed = v.label[..<parenIdx].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            return v.label
        }
        // Custom / ElevenLabs / unknown — show the raw id, truncated.
        if s.voice.count > 12 {
            return String(s.voice.prefix(10)) + "…"
        }
        return s.voice.isEmpty ? "Voice" : s.voice
    }

    // MARK: - Theming

    /// Widget-scale font. The parallel `BrandingTheme` agent is providing
    /// `BrandingTheme.statusFont`; until that file lands, fall back to the
    /// system font. The coordinator should swap this to `BrandingTheme.statusFont`
    /// during integration if it differs from this fallback.
    /// TODO(coordinator): swap to BrandingTheme.statusFont once BrandingTheme.swift lands.
    private static func widgetFont() -> NSFont {
        return NSFont.systemFont(ofSize: 11, weight: .medium)
    }

    /// Brand accent used for the selection-acknowledgement flash. Falls back
    /// to a low-alpha system accent. The coordinator may swap this to a
    /// `BrandingTheme.accent` color during integration.
    /// TODO(coordinator): swap to BrandingTheme.accent once BrandingTheme.swift lands.
    private static func accentFlashColor() -> NSColor {
        return NSColor.controlAccentColor.withAlphaComponent(0.35)
    }

    // MARK: - Menu tags

    /// Tag namespace so `popupChanged(_:)` can distinguish item kinds without
    /// pointer comparisons. Favorite items use `favoriteBase + index`.
    private enum MenuTag: Int {
        case activeSentinel = 1000
        case moreVoices     = 1001
        case favoriteBase   = 2000
    }
}
