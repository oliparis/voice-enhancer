import Foundation
import CoreAudio

/// HAL listener lifetime, separate from selection policy. The callback copies
/// no HAL data; it simply schedules a coalesced refresh/reconnect on main.
final class AudioDeviceMonitor {
    private let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice
    ]
    private let listener: AudioObjectPropertyListenerBlock
    private var registered: [AudioObjectPropertySelector] = []

    @MainActor
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        listener = { _, _ in Task { @MainActor in onChange() } }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, .main, listener) == noErr {
                registered.append(selector)
            }
        }
    }

    deinit {
        for selector in registered {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, .main, listener)
        }
    }
}
