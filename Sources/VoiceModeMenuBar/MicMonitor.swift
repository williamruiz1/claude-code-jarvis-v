import Foundation
import CoreAudio

/// Polls the default input audio device's "is running" state to detect when
/// any app is actively using the microphone. This is the same signal that
/// drives the macOS orange-dot indicator near the menu-bar clock.
///
/// Public API is read-only — we never claim the mic ourselves, so adding
/// this widget does NOT add an entry to the system "Microphone" privacy list.
final class MicMonitor {
    typealias StateHandler = (_ active: Bool) -> Void

    private let pollInterval: TimeInterval
    private let onChange: StateHandler
    private var timer: DispatchSourceTimer?
    private var lastActive: Bool = false

    init(pollInterval: TimeInterval = 0.5, onChange: @escaping StateHandler) {
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    func start() {
        let queue = DispatchQueue(label: "voicemode.mic-monitor", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let active = isAnyInputDeviceRunning()
        if active != lastActive {
            lastActive = active
            onChange(active)
        }
    }

    /// Returns true if any input audio device on the system has a running
    /// I/O proc (i.e., something is actively reading from the mic).
    private func isAnyInputDeviceRunning() -> Bool {
        for deviceID in inputDeviceIDs() {
            if isDeviceRunning(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) {
                return true
            }
        }
        return false
    }

    private func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { hasInputStreams(deviceID: $0) }
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private func isDeviceRunning(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
