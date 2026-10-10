import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os
#if canImport(VoiceEnhancerTapSupport)
import VoiceEnhancerTapSupport
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
///   * Buffer size is 512 frames at 48 kHz (~10.7 ms). Good balance of
///     latency vs. CPU efficiency.
///   * Connect the input in its native format to a mixer that converts to
///     48 kHz float32. Tap the mixer and copy its first channel to the mono
///     DSP buffer. A tap on the input node cannot request a different format.
final class MicCapture {
    /// AVAudioEngine can hand us much larger blocks than the requested tap
    /// buffer size during route changes and on some built-in devices. Keep
    /// ample headroom so those blocks don't get dropped before DSP.
    private static let maxProcessingFrames = 16_384

    private let logger = Logger(subsystem: "tech.aheadly.voice-enhancer", category: "MicCapture")
    private let engineBridge: AudioEngineBridge
    private let ringBridge: RingBufferBridge
    private var avEngine = AVAudioEngine()
    private var captureMixer = AVAudioMixerNode()
    var engineConfigurationChangeHandler: (() -> Void)?

    /// Optional tap that receives raw pre-DSP audio (48 kHz mono float32).
    /// Used by VoicePreview to capture a test clip. RT-safe requirement:
    /// the closure must not allocate or lock.
    var rawAudioTap: ((UnsafePointer<Float>, Int) -> Void)?

    /// The target format the ring expects. Fixed: 48 kHz, mono, float32.
    /// The mixer handles rate conversion. Channel 0 is copied to this mono
    /// contract after conversion, preserving the first-channel policy.
    private let ringFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Scratch buffer holding mono 48 kHz samples for DSP processing.
    /// Sized generously — some macOS input paths hand us ~4800-frame blocks
    /// even when the tap requests 512, and route changes can briefly grow that.
    private var processingBuffer = [Float](repeating: 0, count: MicCapture.maxProcessingFrames)

    // An installation can throw after mutating the node, so cleanup must
    // attempt removal even when installation did not return successfully.
    private var tapMayBeInstalled = false
    private var engineConfigurationObserver: NSObjectProtocol?
    private var hasLoggedFirstInputBuffer = false

    init(engineBridge: AudioEngineBridge, ringBridge: RingBufferBridge) {
        self.engineBridge = engineBridge
        self.ringBridge = ringBridge
        observeEngineConfiguration()
    }

    private func observeEngineConfiguration() {
        self.engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
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
    func start(deviceID: AudioDeviceID? = nil) async throws {
        try await requestMicrophonePermission()

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
        let block: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }
        do {
            // The input scope describes the hardware rate/channel count.
            let nativeFormat = input.inputFormat(forBus: 0)
            guard nativeFormat.sampleRate.isFinite, nativeFormat.sampleRate > 0,
                  nativeFormat.channelCount > 0,
                  let captureFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: ringFormat.sampleRate,
                    channels: nativeFormat.channelCount,
                    interleaved: false
                  ) else {
                throw MicCaptureError.inputConfigurationFailed("The microphone has no valid input format.")
            }
            if let error = VEConfigureCaptureGraphSafely(avEngine, input, captureMixer, nativeFormat, captureFormat) {
                throw MicCaptureError.inputConfigurationFailed(error.localizedDescription)
            }
            tapMayBeInstalled = true
            if let error = VEInstallInputTapSafely(captureMixer, 0, 512, captureFormat, block) {
                throw MicCaptureError.tapInstallationFailed(error.localizedDescription)
            }
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

    func stop() {
        stopCaptureGraph()
    }

    private func stopCaptureGraph(discardGraph: Bool = false) {
        var removalFailed = false
        if tapMayBeInstalled {
            if let error = VERemoveInputTapSafely(captureMixer, 0) {
                logger.warning("Audio tap removal failed: \(error.localizedDescription, privacy: .public)")
                removalFailed = true
            }
            tapMayBeInstalled = false
        }
        avEngine.stop()
        hasLoggedFirstInputBuffer = false
        if removalFailed || discardGraph {
            discardCaptureGraph()
        }
    }

    private func discardCaptureGraph() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        avEngine = AVAudioEngine()
        captureMixer = AVAudioMixerNode()
        observeEngineConfiguration()
    }

    // MARK: - Processing

    /// Handle one tapped input buffer on the audio thread.
    ///
    /// IMPORTANT: This runs on the audio thread. No allocations, no locks,
    /// no Swift concurrency. Anything non-trivial happens inside the C++
    /// engine or the lock-free ring. The buffer handling here is deliberately
    /// minimal.
    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, frameCount <= processingBuffer.count else { return }
        guard let channelData = buffer.floatChannelData else { return }

        if !hasLoggedFirstInputBuffer {
            hasLoggedFirstInputBuffer = true
            DispatchQueue.main.async { [weak self, frameCount] in
                self?.logger.notice("First converted input buffer: \(frameCount, privacy: .public) frames @ 48 kHz")
            }
        }

        // Copy channel 0 into the processing scratch buffer.
        // The conversion mixer supplies 48 kHz float32 and preserves the
        // input channels. Take only channel 0; conversion has already run.
        processingBuffer.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            base.update(from: channelData[0], count: frameCount)
            rawAudioTap?(UnsafePointer(base), frameCount)
            engineBridge.process(buffer: base, numFrames: Int32(frameCount))
            ringBridge.write(base, numFrames: Int32(frameCount))
        }
    }

    private func handleEngineConfigurationChange() {
        logger.notice("AVAudioEngine configuration changed; running=\(self.avEngine.isRunning, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.engineConfigurationChangeHandler?()
        }
    }

    // MARK: - Device binding

    /// Bind `avEngine.inputNode` to a specific Core Audio device.
    ///
    /// AVAudioEngine doesn't expose a "set input device" API directly on
    /// macOS — you set the underlying AUHAL unit's CurrentDevice property.
    /// Must be called before `avEngine.start()`; later changes require a
    /// full stop/start cycle to pick up.
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
    case microphonePermissionDenied
    case deviceBindingFailed(code: Int)
    case tapInstallationFailed(String)
    case inputConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
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
