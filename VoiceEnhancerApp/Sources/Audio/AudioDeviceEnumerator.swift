import Foundation
import CoreAudio

/// Enumerates Core Audio input devices.
///
/// The HAL's property-address API is verbose and easy to misuse; this type
/// is the single place that deals with it. Everyone else gets back Swift
/// ``AudioDevice`` values.
///
/// Why not use `AVAudioSession`? That's iOS. On macOS we go straight to HAL.
enum AudioDeviceEnumerator {
    // Keep synchronized with VirtualDriver/src/Common.h. Display names can
    // change and can also belong to an unrelated physical microphone.
    static let virtualDeviceUID = "tech.aheadly.voice-enhancer.device"

    /// Return every device on the system that can provide input.
    ///
    /// Thread-safe: the underlying HAL calls are safe from any thread and
    /// we do no shared state. Runs in a few hundred microseconds — fine to
    /// call from the main thread during UI refresh.
    static func listInputDevices() -> [AudioDevice] {
        selectableInputs(from: allInputDevices())
    }

    static func selectableInputs(from devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { $0.hasInput && $0.uid != virtualDeviceUID }
    }

    private static func allInputDevices() -> [AudioDevice] {
        let deviceIDs = allDeviceIDs()
        return deviceIDs.compactMap { id -> AudioDevice? in
            // Skip devices that have zero input channels. We only want mics.
            guard hasInputStreams(deviceID: id) else { return nil }

            guard let uid  = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id: id, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }

            return AudioDevice(deviceID: id, uid: uid, name: name, hasInput: true)
        }
    }

    /// Resolve a persisted UID back to a live ``AudioDeviceID``. Returns
    /// nil if the device is no longer present (unplugged, etc.).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        listInputDevices().first { $0.uid == uid }?.deviceID
    }

    /// Resolve explicitly before binding capture. Passing nil to AVAudioEngine
    /// would let it choose the virtual mic when that is the system default.
    static func captureInput(preferredUID: String?) throws -> AudioDevice {
        try captureInput(preferredUID: preferredUID, devices: allInputDevices(),
                         defaultDeviceID: systemDefaultInputID())
    }

    // The same policy is exercised with device-list fixtures in regression tests.
    static func captureInput(preferredUID: String?, devices: [AudioDevice],
                             defaultDeviceID: AudioDeviceID?) throws -> AudioDevice {
        if preferredUID == virtualDeviceUID { throw InputSelectionError.virtualMicrophoneSelected }
        let inputs = selectableInputs(from: devices)
        if let preferredUID, let device = inputs.first(where: { $0.uid == preferredUID }) {
            return device
        }
        if let defaultDeviceID,
           let device = devices.first(where: { $0.deviceID == defaultDeviceID && $0.hasInput }) {
            guard device.uid != virtualDeviceUID else { throw InputSelectionError.virtualMicrophoneDefault }
            return device
        }
        throw InputSelectionError.noInputDevice
    }

    /// The current system-default selectable input, if one is set.
    static func defaultInputDevice() -> AudioDevice? {
        guard let id = systemDefaultInputID() else { return nil }
        return listInputDevices().first { $0.deviceID == id }
    }

    private static func systemDefaultInputID() -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    /// Driver detection uses the unfiltered inventory and stable identity.
    static func hasVoiceEnhancerDriver() -> Bool {
        containsVoiceEnhancerDriver(in: allInputDevices())
    }

    static func containsVoiceEnhancerDriver(in devices: [AudioDevice]) -> Bool {
        devices.contains { $0.uid == virtualDeviceUID && $0.hasInput }
    }

    // MARK: - Private helpers

    /// Fetch every AudioDeviceID the HAL knows about.
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let getStatus = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil, &size, base
            )
        }
        guard getStatus == noErr else { return [] }
        return ids
    }

    /// True if `id` exposes any input stream configuration.
    private static func hasInputStreams(deviceID id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        // Any buffer with at least one channel qualifies as an input stream.
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    /// Read a CFString property and bridge it to a Swift string.
    private static func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cf as String
    }
}

enum InputSelectionError: LocalizedError, Equatable {
    case virtualMicrophoneSelected
    case virtualMicrophoneDefault
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .virtualMicrophoneSelected:
            return "Voice Enhancer cannot capture its own virtual microphone. Choose another microphone in Settings."
        case .virtualMicrophoneDefault:
            return "The system default input is Voice Enhancer. Choose another microphone in Settings."
        case .noInputDevice:
            return "No input microphone is available. Connect a microphone and choose it in Settings."
        }
    }
}
