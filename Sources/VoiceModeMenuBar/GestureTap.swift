import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "GestureTap")

/// Captures the system-defined media key **Next Track** (`NX_KEYTYPE_NEXT`)
/// so an AirPods double-press (configured to "Next Track" in Bluetooth
/// settings) can advance the convomode floor queue hands-free (design §8.3).
///
/// **Gating (load-bearing — design §8.3).** The tap only CONSUMES the Next-Track
/// event when convomode is active AND the floor queue depth > 1. Otherwise the
/// event passes through untouched so it never steals "next track" from music.
///
/// **Press semantics (design §8.4):**
///   • single qualifying press  → `convomode-floor.py request-advance` (boundary-safe)
///   • a second press within ~1.5s → `convomode-floor.py advance` (force-now)
///
/// **Permission.** A CGEventTap requires Input Monitoring / Accessibility. We
/// detect the grant; if absent, the tap simply never installs and the global
/// hotkey + widget buttons remain the guaranteed fallback (design §8.3 caveat).
///
/// **Fallback hotkey.** ⌥⌘→ (Option-Command-RightArrow) is registered as a
/// global Carbon hotkey that always calls `request-advance` regardless of the
/// AirPods path — the guaranteed-works trigger.
final class GestureTap {

    /// Provides the live convomode state used for gating. The owner wires this
    /// to read `FloorQueueStore.current`. Returns `(isActive, depth)`.
    typealias GatingProvider = () -> (active: Bool, depth: Int)

    private let gating: GatingProvider
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastPressAt: Date?
    private let doublePressWindow: TimeInterval = 1.5

    /// Carbon global hotkey plumbing (⌥⌘→).
    private var hotKeyMonitor: Any?

    init(gating: @escaping GatingProvider) {
        self.gating = gating
    }

    // MARK: - Lifecycle

    /// Install the event tap (if permitted) and the global hotkey fallback.
    /// Idempotent. Safe to call when permission is absent — degrades to the
    /// hotkey + widget buttons.
    func start() {
        installHotKeyFallback()
        installEventTap()
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let monitor = hotKeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotKeyMonitor = nil
        }
    }

    deinit { stop() }

    /// Whether the event tap is actually installed (i.e. Input Monitoring
    /// granted and the tap created). When false, only the hotkey/widget path
    /// is available — surface this to the user as a one-time prompt.
    private(set) var tapInstalled: Bool = false

    // MARK: - Event tap (Next Track capture)

    private func installEventTap() {
        // NX (system-defined) events arrive as CGEvent type 14
        // (`kCGEventNull`-adjacent custom value `NSSystemDefined` == 14).
        let mask: CGEventMask = (1 << 14) // NSEvent.EventType.systemDefined raw == 14
        // refcon carries `self` so the C callback can route back.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<GestureTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            // Tap creation fails when Input Monitoring isn't granted.
            log.notice("GestureTap: CGEvent.tapCreate returned nil — Input Monitoring likely not granted. Falling back to hotkey/buttons.")
            tapInstalled = false
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = src
        self.tapInstalled = true
        log.notice("GestureTap: Next-Track event tap installed.")
    }

    /// The C-callback trampoline. Must return the (possibly consumed) event.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap can be auto-disabled by the system under load / timeout —
        // re-enable it so we don't silently go deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // We only care about system-defined (type 14) media-key events.
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        // System-defined media-key subtype == 8.
        guard nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        // data1 high word = key code; bits in low word: 0xA == key-DOWN flag,
        // 0x1 == repeat. Decode the standard media-key encoding.
        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = (keyState == 0x0A)

        // NX_KEYTYPE_NEXT == 17 (and NX_KEYTYPE_FAST == 19 on some HW — we only
        // act on NEXT).
        let NX_KEYTYPE_NEXT: Int32 = 17
        guard keyCode == NX_KEYTYPE_NEXT else {
            return Unmanaged.passUnretained(event)
        }

        // GATE: only consume when convomode is active AND depth > 1.
        let (active, depth) = gating()
        guard active && depth > 1 else {
            // Pass through — let music apps get their Next-Track.
            return Unmanaged.passUnretained(event)
        }

        // Act on key-DOWN only (avoid double-firing on the up event).
        if isKeyDown {
            handleQualifyingPress()
        }
        // CONSUME the event so it doesn't also skip the user's music.
        return nil
    }

    /// Single press → request-advance (boundary-safe). A second press within the
    /// window → advance (force-now). Per design §8.4.
    private func handleQualifyingPress() {
        let now = Date()
        if let last = lastPressAt, now.timeIntervalSince(last) <= doublePressWindow {
            // Rapid second press → force advance now.
            lastPressAt = nil
            log.notice("GestureTap: rapid double Next-Track → force advance")
            DispatchQueue.main.async { FloorControlCLI.advance() }
        } else {
            lastPressAt = now
            log.notice("GestureTap: Next-Track → request-advance (boundary-safe)")
            DispatchQueue.main.async { FloorControlCLI.requestAdvance() }
        }
    }

    // MARK: - Global hotkey fallback (⌥⌘→)

    /// Register ⌥⌘→ as a global "advance" hotkey using an NSEvent global
    /// monitor. Global monitors require Accessibility but NOT a tap; they fire
    /// for key events even when the app is in the background. This is the
    /// guaranteed fallback when the Next-Track tap isn't available.
    private func installHotKeyFallback() {
        // 0x7C == kVK_RightArrow. Modifiers: option + command.
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return }
            let wantMods: NSEvent.ModifierFlags = [.option, .command]
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == wantMods, event.keyCode == 0x7C else { return }
            // Fallback always uses the boundary-safe request-advance.
            log.notice("GestureTap: ⌥⌘→ hotkey → request-advance")
            DispatchQueue.main.async { FloorControlCLI.requestAdvance() }
        }
        hotKeyMonitor = monitor
        if monitor == nil {
            log.notice("GestureTap: global hotkey monitor not installed (Accessibility may be needed).")
        }
    }
}
