import AudioToolbox
import CoreAudio
import Foundation

// Mute and volume through CoreAudio, in-process. Earlier versions ran osascript
// for every read and write: a process launch plus AppleScript plus an Apple
// Event, which under system load - typically in the busy seconds of a lock or
// sleep - could take longer than its 3s limit and leave the Mac unmuted.
//
// osascript remains the fallback for output devices that don't expose a
// settable mute (some HDMI and USB interfaces), so behavior there is unchanged.

/// Hands a result back from the worker thread in `withDeadline`.
private final class Box<T> {
    var value: T?
    let lock = NSLock()
}

/// Runs `work` on a worker thread and waits at most `seconds` for it. CoreAudio
/// calls are IPC to coreaudiod and can stall; the main thread, which also runs
/// the sleep/wake handlers and the menu, must never wait on that indefinitely.
private func withDeadline<T>(_ seconds: TimeInterval, _ label: String,
                             _ work: @escaping () -> T?) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        let value = work()
        box.lock.lock(); box.value = value; box.lock.unlock()
        done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        log("audio call timed out: \(label)")
        return nil
    }
    box.lock.lock(); defer { box.lock.unlock() }
    return box.value
}

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

private func defaultOutputDevice() -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

/// The default output's mute switch, when it has one CoreAudio can set.
private func muteControl() -> (device: AudioObjectID, addr: AudioObjectPropertyAddress)? {
    guard let device = defaultOutputDevice() else { return nil }
    var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    var settable: DarwinBoolean = false
    guard AudioObjectHasProperty(device, &addr),
          AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
          settable.boolValue else { return nil }
    return (device, addr)
}

private enum Reading { case value(Bool), unsupported, failed }

private func readMute() -> Reading {
    guard let control = muteControl() else { return .unsupported }
    var addr = control.addr
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(control.device, &addr, 0, nil, &size, &value) == noErr
    else { return .failed }
    return .value(value != 0)
}

/// False when the device has no settable mute, so the caller falls back.
private func writeMute(_ muted: Bool) -> Bool {
    guard let control = muteControl() else { return false }
    var addr = control.addr
    var value: UInt32 = muted ? 1 : 0
    return AudioObjectSetPropertyData(control.device, &addr, 0, nil,
                                      UInt32(MemoryLayout<UInt32>.size), &value) == noErr
}

/// Nil when the state couldn't be read in time. Callers treat that as
/// "unknown", not "unmuted", so the log never claims a change it can't see.
func isMuted() -> Bool? {
    switch withDeadline(3, "read mute", { readMute() }) {
    case .value(let muted)?: return muted
    case .unsupported?: return scriptIsMuted()
    case .failed?, nil: return nil
    }
}

func mute() { setMuted(true) }
func unmute() { setMuted(false) }

private func setMuted(_ muted: Bool) {
    if withDeadline(3, muted ? "mute" : "unmute", { writeMute(muted) }) != true {
        osascript("set volume output muted \(muted)")
    }
}

/// Mutes, then confirms, trying a few times before giving up: a mute that
/// can't be confirmed at sleep would otherwise leave the Mac unmuted until the
/// next wake. Returns the last reading (nil if it never answered).
@discardableResult
func muteAndConfirm(attempts: Int = 3) -> Bool? {
    var after: Bool?
    for attempt in 1...attempts {
        mute()
        after = isMuted()
        if after == true { return true }
        if attempt < attempts {
            log("mute not confirmed (attempt \(attempt) of \(attempts)); retrying")
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
    return after
}

/// Mute state and output volume for the menu. Nil when the output can't be read.
func audioState() -> (muted: Bool, volume: Int)? {
    let volume = withDeadline(3, "read volume") { () -> Int? in
        guard let device = defaultOutputDevice() else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &level) == noErr
        else { return nil }
        return Int((level * 100).rounded())
    }
    if let volume, let muted = isMuted() { return (muted, volume) }
    return scriptAudioState()
}

// MARK: - osascript fallbacks (devices without a settable CoreAudio mute)

private func scriptIsMuted() -> Bool? {
    switch osascript("output muted of (get volume settings)") {
    case "true": return true
    case "false": return false
    default: return nil
    }
}

private func scriptAudioState() -> (muted: Bool, volume: Int)? {
    // "output volume:40, input volume:27, alert volume:100, output muted:false"
    var fields: [String: String] = [:]
    for pair in osascript("get volume settings").split(separator: ",") {
        let kv = pair.split(separator: ":", maxSplits: 1)
        guard kv.count == 2 else { continue }
        fields[kv[0].trimmingCharacters(in: .whitespaces)] =
            kv[1].trimmingCharacters(in: .whitespaces)
    }
    guard let muted = fields["output muted"],
          let volume = fields["output volume"].flatMap({ Int($0) }) else { return nil }
    return (muted == "true", volume)
}
