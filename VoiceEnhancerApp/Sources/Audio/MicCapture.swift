import Foundation
import AVFoundation
import AppKit
import CoreAudio
import AudioToolbox
import os
#if canImport(VoiceEnhancerTapSupport)
import VoiceEnhancerTapSupport
#endif
#if canImport(CaptureLifecycle)
import CaptureLifecycle
#endif

/// Microphone capture + routing using `AVAudioEngine`.
///
/// Responsibilities:
///   * Set up an input node tap on a user-selected input device.
///   * For each captured buffer, call into the ``AudioEngineBridge`` to
///     process audio in place.
///   * Publish the processed audio into the shared-memory ring so the
///     virtual HAL driver (running inside coreaudiod) can serve it as a
///     microphone to any recording app.
///
/// Design notes:
///   * Mono processing. We take the first channel of the input and treat it
///     as the voice signal. Stereo mics (rare for voice work) get the left
///     channel only. This keeps the DSP path simple and matches how meeting
///     apps treat microphones anyway.
///   * The tap requests 512 native frames; AVAudioEngine may deliver more.
///     Conversion splits these into bounded blocks for DSP processing.
///   * Tap the input at its native rate and channel count. A streaming
///     converter supplies 48 kHz mono without opening a hardware output.
final class MicCapture {
    /// DSP preparation retains its existing capacity; conversion emits blocks
    /// of at most 1024 frames even when the hardware tap delivers much more.
    private static let maxProcessingFrames = 16_384

    private let logger = Logger(subsystem: "tech.aheadly.voice-enhancer", category: "MicCapture")
    private let engineBridge: AudioEngineBridge
    private let ringBridge: RingBufferBridge
    private var avEngine = AVAudioEngine()
    private let startCoordinator: CaptureStartCoordinator
    var engineConfigurationChangeHandler: (() -> Void)?

    /// Optional tap that receives raw pre-DSP audio (48 kHz mono float32).
    /// Used by VoicePreview to capture a test clip. RT-safe requirement:
    /// the closure must not allocate or lock.
    var rawAudioTap: ((UnsafePointer<Float>, Int) -> Void)?

    /// The target format the ring expects. Fixed: 48 kHz, mono, float32.
    /// Channel 0 is converted to this contract, preserving the first-channel policy.
    private let ringFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
    }()

    // An installation can throw after mutating the node, so cleanup must
    // attempt removal even when installation did not return successfully.
    private var tapMayBeInstalled = false
    private var activeNativeFormat: AVAudioFormat?
    private var engineConfigurationObserver: NSObjectProtocol?

    @MainActor
    init(engineBridge: AudioEngineBridge, ringBridge: RingBufferBridge) {
        self.startCoordinator = CaptureStartCoordinator()
        self.engineBridge = engineBridge
        self.ringBridge = ringBridge
        observeEngineConfiguration()
    }

    @MainActor
    private func observeEngineConfiguration() {
        let observedEngine = avEngine
        let handleChange: @MainActor @Sendable () -> Void = { [weak self, weak observedEngine] in
            guard let self, let observedEngine, observedEngine === self.avEngine else { return }
            // Binding a split USB device can post a delayed notification
            // after a successful start. Rebuilding a healthy graph in
            // response produces the same notification and a restart loop.
            let hardware = observedEngine.inputNode.inputFormat(forBus: 0)
            if observedEngine.isRunning, let active = self.activeNativeFormat,
               hardware.sampleRate == active.sampleRate,
               hardware.channelCount == active.channelCount {
                return
            }
            self.logger.notice("Capture format changed or engine stopped; restarting capture")
            self.engineConfigurationChangeHandler?()
        }
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: .main
        ) { _ in
            Task { @MainActor in handleChange() }
        }
    }

    deinit {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
    }

    // MARK: - Lifecycle

    /// Start capture.
    ///
    /// - Parameter deviceID: Optional Core Audio device ID to bind the input
    ///   to. Pass `nil` to use the system default. Passing a specific device
    ///   is how the user "picks a microphone" in the UI.
    ///
    /// Throws on permission denial, device binding failure, or engine setup
    /// failure.
    @MainActor
    func start(deviceID: AudioDeviceID? = nil) async throws {
        try await startCoordinator.start(after: requestMicrophonePermission) {
            // Xcode and manually opened builds can run alongside each other.
            // The shared ring supports one producer, so reject a second app
            // before preparing DSP or publishing a new writer generation.
            if let identifier = Bundle.main.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
                   !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
               }) {
                throw MicCaptureError.anotherInstanceRunning
            }
            try configureCaptureGraph(deviceID: deviceID)
        }
    }

    @MainActor
    private func configureCaptureGraph(deviceID: AudioDeviceID?) throws {

        // Rebuild connections for the selected device's current native format.
        stopCaptureGraph(discardGraph: true)

        if let id = deviceID {
            try bindInputDevice(id)
        }

        // The DSP engine always runs at the ring's rate (48 kHz mono).
        try engineBridge.prepare(
            sampleRate: ringFormat.sampleRate,
            maxBlockSize: Int32(Self.maxProcessingFrames)
        )

        // Mark a new writer session so the driver resyncs its read head.
        ringBridge.bumpGeneration()

        let input = avEngine.inputNode
        do {
            // The input scope describes the hardware rate/channel count.
            let nativeFormat = input.inputFormat(forBus: 0)
            guard nativeFormat.sampleRate.isFinite, nativeFormat.sampleRate > 0,
                  nativeFormat.channelCount > 0,
                  let captureFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: nativeFormat.sampleRate,
                    channels: nativeFormat.channelCount,
                    interleaved: false
                  ) else {
                throw MicCaptureError.inputConfigurationFailed("The microphone has no valid input format.")
            }
            let conversion = try CaptureConversion(sampleRate: nativeFormat.sampleRate)
            let block: AVAudioNodeTapBlock = { [weak self, conversion] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                // Conversion owns bounded scratch buffers and retains its state
                // for this tap's lifetime, including callbacks during teardown.
                VEPCMConverterProcess(conversion.handle, channels[0], buffer.frameLength, { context, samples, frames in
                    guard let context, let samples else { return }
                    let capture = Unmanaged<MicCapture>.fromOpaque(context).takeUnretainedValue()
                    capture.handleConvertedSamples(samples, count: Int(frames))
                }, Unmanaged.passUnretained(self).toOpaque())
            }
            tapMayBeInstalled = true
            if let error = VEInstallInputTapSafely(input, 0, 512, captureFormat, block) {
                throw MicCaptureError.tapInstallationFailed(error.localizedDescription)
            }
            activeNativeFormat = nativeFormat
            try avEngine.start()
            logger.notice("Capture started: \(nativeFormat.channelCount, privacy: .public)ch @ \(nativeFormat.sampleRate, privacy: .public) Hz -> 48 kHz, channel 1")
        } catch {
            // Preserve the original setup error, even if removal also fails.
            // A fresh graph prevents partially installed or duplicate taps
            // from leaking into a later start.
            stopCaptureGraph(discardGraph: true)
            throw error
        }
    }

    @MainActor
    func stop() {
        startCoordinator.invalidate()
        stopCaptureGraph()
    }

    @MainActor
    private func stopCaptureGraph(discardGraph: Bool = false) {
        var removalFailed = false
        if tapMayBeInstalled {
            if let error = VERemoveInputTapSafely(avEngine.inputNode, 0) {
                logger.warning("Audio tap removal failed: \(error.localizedDescription, privacy: .public)")
                removalFailed = true
            }
            tapMayBeInstalled = false
        }
        avEngine.stop()
        activeNativeFormat = nil
        if removalFailed || discardGraph {
            discardCaptureGraph()
        }
    }

    @MainActor
    private func discardCaptureGraph() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        avEngine = AVAudioEngine()
        observeEngineConfiguration()
    }

    // MARK: - Processing

    /// Handle one tapped input buffer on the audio thread.
    ///
    /// IMPORTANT: This runs on the audio thread. No allocations, no locks,
    /// no Swift concurrency. Anything non-trivial happens inside the C++
    /// engine or the lock-free ring. The buffer handling here is deliberately
    /// minimal.
    private func handleConvertedSamples(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        rawAudioTap?(UnsafePointer(samples), count)
        engineBridge.process(buffer: samples, numFrames: Int32(count))
        ringBridge.write(samples, numFrames: Int32(count))
    }

    // MARK: - Device binding

    /// Bind `avEngine.inputNode` to a specific Core Audio device.
    ///
    /// AVAudioEngine doesn't expose a "set input device" API directly on
    /// macOS — you set the underlying AUHAL unit's CurrentDevice property.
    /// Must be called before `avEngine.start()`; later changes require a
    /// full stop/start cycle to pick up.
    @MainActor
    private func bindInputDevice(_ id: AudioDeviceID) throws {
        let audioUnit = avEngine.inputNode.audioUnit
        guard let unit = audioUnit else {
            throw MicCaptureError.deviceBindingFailed(code: -1)
        }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw MicCaptureError.deviceBindingFailed(code: Int(status))
        }
    }

    // MARK: - Permissions

    /// Request microphone permission asynchronously using a checked
    /// continuation. This avoids blocking the MainActor thread (which
    /// DispatchSemaphore.wait would do) and correctly suspends the Swift
    /// concurrency task until TCC responds.
    private func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw MicCaptureError.microphonePermissionDenied
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    continuation.resume(returning: ok)
                }
            }
            if !granted { throw MicCaptureError.microphonePermissionDenied }
        @unknown default:
            throw MicCaptureError.microphonePermissionDenied
        }
    }
}

enum MicCaptureError: LocalizedError {
    case anotherInstanceRunning
    case microphonePermissionDenied
    case deviceBindingFailed(code: Int)
    case tapInstallationFailed(String)
    case inputConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .anotherInstanceRunning:
            return "Another copy of Voice Enhancer is running. Quit the other copy, then reopen this app to start microphone capture."
        case .microphonePermissionDenied:
            return "Microphone permission was not granted. Enable it in System Settings → Privacy & Security → Microphone."
        case .deviceBindingFailed(let code):
            return "Could not bind to the selected input device (code \(code))."
        case .tapInstallationFailed(let message):
            return "Could not install the microphone tap: \(message)"
        case .inputConfigurationFailed(let message):
            return "Could not configure microphone capture: \(message)"
        }
    }
}

/// Owned by the tap block so an in-flight callback never sees a freed converter.
private final class CaptureConversion {
    let handle: OpaquePointer

    init(sampleRate: Double) throws {
        var status: OSStatus = noErr
        guard let handle = VEPCMConverterCreate(sampleRate, &status) else {
            throw MicCaptureError.inputConfigurationFailed("Could not convert microphone audio to 48 kHz (code \(status)).")
        }
        self.handle = handle
    }

    deinit { VEPCMConverterDestroy(handle) }
}
