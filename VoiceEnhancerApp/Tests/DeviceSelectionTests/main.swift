import Foundation

@main
struct DeviceSelectionTests {
    static func main() throws {
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func rejects(_ uid: String?, _ devices: [AudioDevice], _ defaultID: UInt32?,
                     _ expected: InputSelectionError, _ message: String) {
            do {
                _ = try AudioDeviceEnumerator.captureInput(preferredUID: uid, devices: devices, defaultDeviceID: defaultID)
                expect(false, message)
            } catch let actual as InputSelectionError {
                expect(actual == expected, message)
            } catch { expect(false, message) }
        }
        let physical = AudioDevice(deviceID: 1, uid: "usb-mic", name: "USB Mic", hasInput: true)
        let sameName = AudioDevice(deviceID: 2, uid: "physical-same-name", name: "Voice Enhancer", hasInput: true)
        let virtual = AudioDevice(deviceID: 3, uid: AudioDeviceEnumerator.virtualDeviceUID, name: "Renamed Virtual Mic", hasInput: true)
        let output = AudioDevice(deviceID: 4, uid: "speakers", name: "Speakers", hasInput: false)
        let inventory = [physical, virtual, sameName, output]
        let selectable = AudioDeviceEnumerator.selectableInputs(from: inventory)
        expect(selectable == [physical, sameName], "only the own virtual UID and output-only devices are filtered")
        expect(AudioDeviceEnumerator.containsVoiceEnhancerDriver(in: inventory), "renamed driver remains detectable")
        expect(!AudioDeviceEnumerator.containsVoiceEnhancerDriver(in: [physical, sameName]), "same display name does not impersonate the driver")
        expect(try AudioDeviceEnumerator.captureInput(preferredUID: nil, devices: inventory, defaultDeviceID: 1) == physical,
               "physical default is selected explicitly")
        expect(try AudioDeviceEnumerator.captureInput(preferredUID: "usb-mic", devices: inventory, defaultDeviceID: 3) == physical,
               "explicit physical selection works when default is virtual")
        expect(try AudioDeviceEnumerator.captureInput(preferredUID: "missing", devices: inventory, defaultDeviceID: 1) == physical,
               "disconnected saved input falls back to safe default")
        expect(try AudioDeviceEnumerator.captureInput(preferredUID: "physical-same-name", devices: inventory, defaultDeviceID: 1) == sameName,
               "same-named physical microphone can be selected")
        rejects(nil, inventory, 3, .virtualMicrophoneDefault, "virtual system default cannot feed back into itself")
        rejects("missing", inventory, 3, .virtualMicrophoneDefault, "missing saved mic cannot fall back to virtual default")
        rejects(AudioDeviceEnumerator.virtualDeviceUID, inventory, 1, .virtualMicrophoneSelected, "legacy saved virtual selection is rejected")
        rejects(nil, [virtual], 3, .virtualMicrophoneDefault, "virtual-only inventory reports routing error")
        rejects(nil, [], nil, .noInputDevice, "empty inventory reports unavailable input")
        rejects(nil, inventory, 4, .noInputDevice, "output-only default cannot be captured")
        rejects(nil, inventory, 99, .noInputDevice, "vanished default cannot fall through to engine default")
        if CommandLine.arguments.contains("--live") {
            let visible = AudioDeviceEnumerator.listInputDevices()
            expect(!visible.contains { $0.uid == AudioDeviceEnumerator.virtualDeviceUID }, "live picker excludes own virtual input")
            expect(AudioDeviceEnumerator.hasVoiceEnhancerDriver(), "installed driver is still detected")
            let device = try AudioDeviceEnumerator.captureInput(preferredUID: nil)
            expect(device.uid != AudioDeviceEnumerator.virtualDeviceUID, "live default resolves to another microphone")
            print("Live default: \(device.name); selectable inputs: \(visible.count)")
        }
        print("Device selection: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
