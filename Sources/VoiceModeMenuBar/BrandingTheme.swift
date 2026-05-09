import AppKit
import QuartzCore

/// JARVIS V brand identity surface — colors, fonts, wordmark, and animation
/// helpers. Pure-AppKit + Core Animation; no SwiftUI, no instance state.
///
/// Visual register: warm-tech "console" aesthetic. Amber accent is the brand's
/// signature; system red is reserved for the live "listening" state so the two
/// signals coexist without clashing (idle = amber breath, active = red pulse).
///
/// All colors are dynamic (light/dark aware) so the HUD reads correctly under
/// either appearance without manual repaint hooks.
enum BrandingTheme {

    // MARK: - Colors

    /// Brand amber — the JARVIS V signature accent. Slightly warmer in dark
    /// mode (more yellow) so it pops on the HUD blur; slightly desaturated in
    /// light mode so it doesn't fluoresce on a white menu bar background.
    /// Hex anchor: #E89A3F (dark) / #C8772A (light).
    static let brandAccent: NSColor = NSColor(name: NSColor.Name("brandAccent")) { appearance in
        if BrandingTheme.isDark(appearance) {
            // #E89A3F — warm amber that sits comfortably alongside system red.
            return NSColor(srgbRed: 0xE8/255.0, green: 0x9A/255.0, blue: 0x3F/255.0, alpha: 1.0)
        } else {
            // #C8772A — same hue, dialed back for white-background contrast.
            return NSColor(srgbRed: 0xC8/255.0, green: 0x77/255.0, blue: 0x2A/255.0, alpha: 1.0)
        }
    }

    /// Muted neutral for the idle state's text + supporting glyphs. Tracks
    /// the system secondary label color so it adapts naturally to appearance.
    static let idleColor: NSColor = NSColor(name: NSColor.Name("brandIdle")) { appearance in
        if BrandingTheme.isDark(appearance) {
            // A touch warmer than pure secondaryLabelColor so it harmonizes
            // with the amber when both are visible at the same time.
            return NSColor(srgbRed: 0.78, green: 0.76, blue: 0.72, alpha: 0.75)
        } else {
            return NSColor(srgbRed: 0.32, green: 0.30, blue: 0.27, alpha: 0.70)
        }
    }

    /// Active "listening" tint — system red, nudged a hair warmer so it
    /// doesn't fight the amber accent next to it.
    static let activeColor: NSColor = NSColor(name: NSColor.Name("brandActive")) { appearance in
        if BrandingTheme.isDark(appearance) {
            // #FF4F4A — close to systemRed but slightly orange-leaning.
            return NSColor(srgbRed: 1.0, green: 0.31, blue: 0.29, alpha: 1.0)
        } else {
            // #D93B36 — denser red for white backgrounds.
            return NSColor(srgbRed: 0.85, green: 0.23, blue: 0.21, alpha: 1.0)
        }
    }

    /// Soft fill that overlays the existing HUD blur without muddying it.
    /// Low alpha — meant to be layered, not opaque.
    static let panelBackground: NSColor = NSColor(name: NSColor.Name("brandPanelBg")) { appearance in
        if BrandingTheme.isDark(appearance) {
            return NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.18)
        } else {
            return NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 0.18)
        }
    }

    /// Hairline border tint for the brand panel. Faintly amber-tinged in dark
    /// mode so the brand identity reaches all the way to the HUD edge.
    static let borderColor: NSColor = NSColor(name: NSColor.Name("brandBorder")) { appearance in
        if BrandingTheme.isDark(appearance) {
            return NSColor(srgbRed: 0xE8/255.0, green: 0x9A/255.0, blue: 0x3F/255.0, alpha: 0.22)
        } else {
            return NSColor(srgbRed: 0xC8/255.0, green: 0x77/255.0, blue: 0x2A/255.0, alpha: 0.18)
        }
    }

    // MARK: - Fonts

    /// "JARVIS V" wordmark font — monospaced, medium weight, ~9pt. The
    /// monospaced face gives the console / terminal feel; medium weight keeps
    /// the small size legible without shouting.
    static let wordmarkFont: NSFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)

    /// Status label font ("Idle" / "Listening" / etc.). System sans, slightly
    /// heavier than the wordmark so the live status reads first.
    static let statusFont: NSFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    // MARK: - Wordmark

    /// Renders the "JARVIS-V" wordmark as a tasteful console-style label.
    /// Uses `brandAccent` for color, `wordmarkFont` for face, and a touch of
    /// extra letter-spacing for the "console" vibe. The trailing "V" is
    /// rendered one weight up so the brand reads as JARVIS [V].
    final class WordmarkView: NSView {

        private let textField: NSTextField

        /// Creates a wordmark view. The default text is "JARVIS-V" — pass a
        /// custom string only if you have a specific reason (e.g. an internal
        /// build label like "JARVIS-V Δ").
        init(text: String = "JARVIS-V") {
            self.textField = NSTextField(labelWithAttributedString: NSAttributedString())
            super.init(frame: .zero)

            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true

            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.isBezeled = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.drawsBackground = false
            textField.attributedStringValue = WordmarkView.makeAttributedString(text)
            addSubview(textField)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: trailingAnchor),
                textField.topAnchor.constraint(equalTo: topAnchor),
                textField.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("WordmarkView is code-only; coder init not supported.")
        }

        /// The wordmark's natural size (as laid out by `textField`). Constraint
        /// systems can use this without an explicit width/height pin.
        override var intrinsicContentSize: NSSize {
            return textField.intrinsicContentSize
        }

        /// Re-render after appearance flips so the brand accent re-resolves.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            textField.attributedStringValue = WordmarkView.makeAttributedString(textField.stringValue)
        }

        /// Build the attributed wordmark: JARVIS-V with widened letter-spacing
        /// and a heavier weight on the trailing "V". If the input contains a
        /// hyphen, the segment after the last hyphen is the emphasized tail.
        private static func makeAttributedString(_ text: String) -> NSAttributedString {
            let result = NSMutableAttributedString()

            let head: String
            let tail: String
            if let hyphenIndex = text.lastIndex(of: "-") {
                head = String(text[..<hyphenIndex])
                tail = String(text[text.index(after: hyphenIndex)...])
            } else if text.count >= 2, text.hasSuffix("V") {
                // No hyphen — last char becomes the emphasis if it's a "V".
                head = String(text.dropLast())
                tail = String(text.suffix(1))
            } else {
                head = text
                tail = ""
            }

            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: BrandingTheme.wordmarkFont,
                .foregroundColor: BrandingTheme.brandAccent,
                .kern: 1.4, // widened letter-spacing for the console feel
            ]
            result.append(NSAttributedString(string: head, attributes: baseAttrs))

            if !tail.isEmpty {
                // Hyphen separator if the source had one — rendered dimmer so
                // the eye reads the two halves as a unit, not two words.
                if text.contains("-") {
                    var sepAttrs = baseAttrs
                    sepAttrs[.foregroundColor] = BrandingTheme.brandAccent.withAlphaComponent(0.45)
                    result.append(NSAttributedString(string: "-", attributes: sepAttrs))
                }
                var tailAttrs = baseAttrs
                tailAttrs[.font] = NSFont.monospacedSystemFont(
                    ofSize: BrandingTheme.wordmarkFont.pointSize,
                    weight: .bold
                )
                result.append(NSAttributedString(string: tail, attributes: tailAttrs))
            }

            return result
        }
    }

    // MARK: - Animations

    /// Animation key used by the idle "breath" alpha pulse. Exposed so callers
    /// can detect / remove just this animation without disturbing others.
    static let idleBreathKey = "brandingTheme.idleBreath"

    /// Animation key used by the active "pulse" effect.
    static let activePulseKey = "brandingTheme.activePulse"

    /// Apply a slow ~3s "breathing" alpha animation to a view's layer.
    /// Loops indefinitely. Safe to call repeatedly; replaces any existing
    /// animation under the same key.
    static func applyIdleBreath(to view: NSView) {
        ensureLayer(view)
        guard let layer = view.layer else { return }

        layer.removeAnimation(forKey: idleBreathKey)
        layer.removeAnimation(forKey: activePulseKey)

        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.6
        breath.toValue = 1.0
        breath.duration = 1.5
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        layer.add(breath, forKey: idleBreathKey)
    }

    /// Apply a sharper ~0.6s pulse to a view's layer. Used while the system is
    /// actively listening — more saturated, faster cadence than the idle
    /// breath. Loops indefinitely.
    static func applyActivePulse(to view: NSView) {
        ensureLayer(view)
        guard let layer = view.layer else { return }

        layer.removeAnimation(forKey: idleBreathKey)
        layer.removeAnimation(forKey: activePulseKey)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 0.3
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: activePulseKey)
    }

    /// Remove both branded animations from a view's layer and reset opacity
    /// to fully visible. Use when transitioning to a static state.
    static func removeAnimations(from view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: idleBreathKey)
        layer.removeAnimation(forKey: activePulseKey)
        layer.opacity = 1.0
    }

    // MARK: - Internals

    /// `NSView` doesn't auto-create a backing layer; CABasicAnimation needs one.
    /// `wantsLayer = true` is idempotent so this is safe to call repeatedly.
    private static func ensureLayer(_ view: NSView) {
        if view.layer == nil {
            view.wantsLayer = true
        }
    }

    /// Detect "dark mode" from a resolved appearance. Used inside dynamic
    /// `NSColor` providers. Falls back to false (light) if the appearance
    /// best-match returns nil — the same default the system uses.
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        switch match {
        case .some(.darkAqua), .some(.vibrantDark):
            return true
        default:
            return false
        }
    }
}
