import Foundation
import CoreAudio
import os

private let log = Logger(subsystem: "com.williamruiz.voicemode-monitor", category: "MuteSentinel")

/// Watches the default input device's `kAudioDevicePropertyMute` (input scope,
/// main element) and writes the current mute state to `~/.voicemode/mute-state.json`
/// so the converse loop / `/convomode` skill can read it and enter STANDBY
/// instead of treating an empty recording as a real turn (design §3).
///
/// Schema written:
/// `{ "muted": bool, "device": str, "source": "coreaudio-property", "ts": iso }`
///
/// Mirrors the existing `MicMonitor` CoreAudio pattern. Two capabilities:
///   • LISTEN — `AudioObjectAddPropertyListenerBlock` on the device Mute property
///     → instant push on change → debounced write (no polling lag).
///   • SET    — `setMuted(_:)` flips the (settable) property directly. This is the
///     guaranteed-clean software-mute path the control strip's 🎙 button uses
///     (design §3.4), bypassing any AirPods-firmware ambiguity.
///
/// The default input device can change (AirPods connect/disconnect); we listen
/// for `kAudioHardwarePropertyDefaultInputDevice` and re-attach the mute listener
/// to whatever the new default is.
final class MuteSentinel {
    typealias MuteHandler = (_ muted: Bool) -> Void

    /// Optional observer fired (main thread) whenever the mute state changes —
    /// lets the widget update its mic pill without re-reading the file.
    var onChange: MuteHandler?

    private let debounce: TimeInterval
    private var debounceWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "voicemode.mute-sentinel", qos: .utility)

    /// The device we currently have a mute listener attached to (0 = none).
    private var watchedDevice: AudioDeviceID = 0
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var lastWrittenMuted: Bool?

    private static var stateURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".voicemode")
            .appendingPathComponent("mute-state.json")
    }

    init(debounce: TimeInterval = 0.25) {
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    /// Begin listening. Idempotent. Attaches a mute listener to the current
    /// default input device, plus a default-device-change listener so we follow
    /// AirPods connect/disconnect.
    func start() {
        ensureVoiceDir()
        attachDefaultDeviceChangeListener()
        reattachToCurrentDefaultInput()
        // Seed the file with the current state on launch.
        queue.async { [weak self] in
            guard let self = self else { return }
            let muted = self.readMute(device: self.currentDefaultInputDevice())
            self.writeState(muted: muted, force: true)
        }
    }

    func stop() {
        detachMuteListener()
        detachDefaultDeviceChangeListener()
    }

    deinit { stop() }

    // MARK: - Software mute toggle (the guaranteed-clean path, §3.4)

    /// Current mute state of the default input device (synchronous read).
    func isMuted() -> Bool { readMute(device: currentDefaultInputDevice()) }

    /// Flip the device's mute property. Returns true if the property was
    /// successfully set (i.e. the device exposes a settable Mute property).
    @discardableResult
    func toggle() -> Bool {
        let device = currentDefaultInputDevice()
        let now = readMute(device: device)
        return setMuted(!now, device: device)
    }

    /// Set the mute property explicitly. Returns true on success.
    @discardableResult
    func setMuted(_ muted: Bool, device: AudioDeviceID? = nil) -> Bool {
        let dev = device ?? currentDefaultInputDevice()
        guard dev != 0 else { return false }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else {
            log.notice("MuteSentinel.setMuted: device \(dev) has no Mute property; cannot software-mute.")
            return false
        }
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue == false {
            log.notice("MuteSentinel.setMuted: Mute property not settable on device \(dev).")
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value)
        if status != noErr {
            log.error("MuteSentinel.setMuted: AudioObjectSetPropertyData failed status=\(status)")
            return false
        }
        // The property listener will fire and write the file; but write
        // proactively too so the UI reflects it even if the listener lags.
        writeState(muted: muted, force: false)
        return true
    }

    // MARK: - Mute property read / address

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readMute(device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    // MARK: - Default input device

    private func currentDefaultInputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        ) == noErr else { return 0 }
        return device
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        guard device != 0 else { return "unknown" }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr else {
            return "unknown"
        }
        return name as String
    }

    // MARK: - Listeners

    private var defaultDeviceChangeBlock: AudioObjectPropertyListenerBlock?

    private func attachDefaultDeviceChangeListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reattachToCurrentDefaultInput()
        }
        defaultDeviceChangeBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
        )
        if status != noErr {
            log.error("MuteSentinel: failed to add default-device-change listener status=\(status)")
        }
    }

    private func detachDefaultDeviceChangeListener() {
        guard let block = defaultDeviceChangeBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
        )
        defaultDeviceChangeBlock = nil
    }

    /// (Re)attach the mute property listener to whatever the current default
    /// input device is. Detaches any prior listener first.
    private func reattachToCurrentDefaultInput() {
        detachMuteListener()
        let device = currentDefaultInputDevice()
        guard device != 0 else { return }
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else {
            // Device has no Mute property — fall back to nothing (the VAD-silence
            // fallback lives in the converse loop per design §3.1; this sentinel
            // only handles the device-property path). Still write the current
            // (false) state so the file exists.
            log.notice("MuteSentinel: default input device \(device) has no Mute property; property-path unavailable.")
            queue.async { [weak self] in self?.writeState(muted: false, force: false) }
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleMuteChange(device: device)
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &addr, queue, block)
        if status == noErr {
            watchedDevice = device
            muteListenerBlock = block
            // Push current state immediately on (re)attach.
            handleMuteChange(device: device)
        } else {
            log.error("MuteSentinel: failed to add mute listener to device \(device) status=\(status)")
        }
    }

    private func detachMuteListener() {
        guard watchedDevice != 0, let block = muteListenerBlock else { return }
        var addr = muteAddress()
        AudioObjectRemovePropertyListenerBlock(watchedDevice, &addr, queue, block)
        watchedDevice = 0
        muteListenerBlock = nil
    }

    /// Debounced handler — coalesces click-spam (design §4.4 "mute flips rapidly").
    private func handleMuteChange(device: AudioDeviceID) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let muted = self.readMute(device: device)
            self.writeState(muted: muted, force: false)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    // MARK: - File write

    private func ensureVoiceDir() {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".voicemode")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Write `mute-state.json` atomically (temp+rename) when the state changed
    /// (or `force`). Notifies `onChange` on the main thread.
    private func writeState(muted: Bool, force: Bool) {
        if !force, lastWrittenMuted == muted { return }
        lastWrittenMuted = muted
        let device = deviceName(currentDefaultInputDevice())
        let payload: [String: Any] = [
            "muted": muted,
            "device": device,
            "source": "coreaudio-property",
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        let url = Self.stateURL
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".mute-\(UUID().uuidString).json")
        do {
            try data.write(to: tmp)
            // Atomic replace.
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            // replaceItemAt removes tmp on success; if it returned nil without
            // throwing (target absent), fall back to a plain move.
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            log.error("MuteSentinel.writeState failed: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        if let handler = onChange {
            DispatchQueue.main.async { handler(muted) }
        }
    }
}
