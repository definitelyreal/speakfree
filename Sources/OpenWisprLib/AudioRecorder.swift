import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private var currentOutputURL: URL?
    private let writeQueue = DispatchQueue(label: "com.openwisprmod.audiowrite")
    private var pcmSamples: [Float] = []

    /// Current RMS audio level (0.0–1.0), updated from the audio tap.
    private(set) var currentLevel: Float = 0

    /// Timestamp of last audio buffer received — used by health check to detect dead engines.
    private var lastBufferTime: Date = Date()

    /// Whether the pre-buffer engine should run. When false, engine only starts on startRecording.
    var preBufferEnabled: Bool = true {
        didSet {
            if preBufferEnabled && audioEngine == nil {
                startEngine()
            } else if !preBufferEnabled && !isRecording {
                // Stop the engine when not recording
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine?.stop()
                audioEngine = nil
            }
        }
    }

    // MARK: - State (synchronized via stateLock)

    /// Lock protecting isRecording + prerollBuffer + audioFile access from audio thread
    private let stateLock = NSLock()
    private var _isRecording = false
    private var isRecording: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRecording }
        set { stateLock.lock(); _isRecording = newValue; stateLock.unlock() }
    }

    // MARK: - Pre-roll circular buffer

    private var prerollBuffer: [Float] = []
    private let prerollMaxSamples = 8000  // 500ms at 16kHz

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Shut down the audio engine. Call before app exit.
    func shutdown() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    /// Start the always-on audio engine. Call once on app launch.
    func warmUp() {
        guard preBufferEnabled else { return }
        startEngine()
        startDeviceChangeMonitor()
    }

    /// Verify audio is flowing. If the engine is dead, rebuild it.
    /// Call this before every recording to catch silent AirPods handoffs.
    /// Only rebuilds audio — never touches the whisper model.
    func ensureAudioHealthy() {
        guard preBufferEnabled else { return }

        // No engine at all — start one
        guard let engine = audioEngine else {
            DiagnosticLogger.shared.log("AudioRecorder: no engine — starting")
            startEngine()
            return
        }

        // Engine exists but not running
        if !engine.isRunning {
            DiagnosticLogger.shared.log("AudioRecorder: engine stopped — rebuilding")
            reinstallTap()
            return
        }

        // Engine running but no buffers flowing (silent death)
        let elapsed = Date().timeIntervalSince(lastBufferTime)
        if elapsed > 3.0 {
            DiagnosticLogger.shared.log("AudioRecorder: no audio buffers for \(Int(elapsed))s — rebuilding engine")
            reinstallTap()
        }
    }

    // MARK: - Audio device change monitoring

    private var deviceChangeObserver: NSObjectProtocol?

    /// Reinstall the audio tap when the input device changes (e.g. AirPods connect/disconnect).
    private func startDeviceChangeMonitor() {
        // AVAudioEngine notification — fires for most device changes.
        // IMPORTANT: this fires while AVAudioEngine's internal engine queue holds
        // its recursive_mutex during IOUnitConfigurationChanged(). Calling
        // removeTap/stop synchronously here re-enters that lock → deadlock.
        // Defer with a short delay to let the engine finish its internal reconfiguration.
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            DiagnosticLogger.shared.log("AudioRecorder: audio configuration changed — scheduling tap reinstall")

            // Don't touch the engine during active recording — defer until recording stops
            if self.isRecording {
                DiagnosticLogger.shared.log("AudioRecorder: deferring tap reinstall until recording stops")
                self.needsTapReinstall = true
                return
            }

            // Delay 0.5s to let AVAudioEngine finish its internal reconfiguration
            // before we tear down and rebuild. Without this, removeTap deadlocks
            // on the engine's recursive_mutex (AVAudioEngineImpl::IOUnitConfigurationChanged).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.reinstallTap()
            }
        }

        // CoreAudio listener — catches Bluetooth handoffs (AirPods switching between
        // devices) that AVAudioEngineConfigurationChange sometimes misses.
        // IMPORTANT: dispatch on a dedicated queue, NOT main — CoreAudio can deadlock
        // if the listener callback blocks the main thread during reconfiguration.
        var inputDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceQueue = DispatchQueue(label: "com.speakfree.audiodevice")
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputDeviceAddress,
            deviceQueue
        ) { [weak self] _, _ in
            guard let self = self else { return }
            DiagnosticLogger.shared.log("AudioRecorder: CoreAudio default input device changed")
            DispatchQueue.main.async {
                DiagnosticLogger.shared.log("AudioRecorder: device change — bounced to main, isRebuilding=\(self.isRebuilding)")
                if self.isRecording {
                    self.needsTapReinstall = true
                } else {
                    self.reinstallTap()
                }
            }
        }
    }

    private var needsTapReinstall = false
    private var isRebuilding = false

    /// Rebuild the audio engine from scratch after a device change.
    /// Tears down the old engine on a background thread to avoid deadlocking
    /// with CoreAudio's internal locks during reconfiguration.
    private func reinstallTap() {
        guard !isRebuilding else {
            DiagnosticLogger.shared.log("AudioRecorder: rebuild already in progress — skipping")
            return
        }
        isRebuilding = true
        DiagnosticLogger.shared.log("AudioRecorder: tearing down engine for device change (isMainThread=\(Thread.isMainThread))")

        // Capture the old engine and nil out our reference immediately
        let oldEngine = audioEngine
        audioEngine = nil
        audioConverter = nil

        // Clear stale pre-roll
        stateLock.lock()
        prerollBuffer = []
        stateLock.unlock()

        // Tear down on a background thread — removeTap/stop can deadlock
        // with CoreAudio's internal locks if called during a device-change callback
        DispatchQueue.global(qos: .userInitiated).async {
            if let engine = oldEngine {
                DiagnosticLogger.shared.log("AudioRecorder: removeTap starting (background thread)")
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                DiagnosticLogger.shared.log("AudioRecorder: old engine stopped")
            }

            // Rebuild on main after CoreAudio settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                DiagnosticLogger.shared.log("AudioRecorder: asyncAfter fired — starting engine rebuild")
                self.startEngine()
                self.needsTapReinstall = false
                self.isRebuilding = false
                DiagnosticLogger.shared.log("AudioRecorder: engine rebuilt for new audio device")
            }
        }
    }

    /// Internal: create and start the audio engine regardless of preBufferEnabled.
    private func startEngine() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("AudioRecorder: converter creation failed")
            return
        }
        audioConverter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleAudioBuffer(buffer, inputFormat: inputFormat, converter: conv)
        }

        do {
            try engine.start()
            audioEngine = engine
            print("AudioRecorder: audio engine started")
        } catch {
            print("AudioRecorder: engine start failed: \(error.localizedDescription)")
        }
    }

    /// Single tap callback — handles both pre-roll and recording modes.
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, converter: AVAudioConverter) {
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, convertedBuffer.frameLength > 0,
              let channelData = convertedBuffer.floatChannelData?[0] else { return }

        // Track last buffer time for health check
        self.lastBufferTime = Date()

        let count = Int(convertedBuffer.frameLength)

        // RMS level for visualizer
        var sum: Float = 0
        for i in 0..<count { sum += channelData[i] * channelData[i] }
        let rms = sqrtf(sum / Float(max(count, 1)))
        self.currentLevel = min(rms / 0.15, 1.0)

        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))

        // Atomically check state and dispatch to correct path
        stateLock.lock()
        let recording = _isRecording
        if !recording {
            // Pre-roll mode: fill circular buffer (while holding lock)
            prerollBuffer.append(contentsOf: samples)
            if prerollBuffer.count > prerollMaxSamples {
                prerollBuffer.removeFirst(prerollBuffer.count - prerollMaxSamples)
            }
            stateLock.unlock()
        } else {
            stateLock.unlock()
            // Recording mode: write to file + accumulate samples
            writeQueue.async {
                self.pcmSamples.append(contentsOf: samples)
                do {
                    try self.audioFile?.write(from: convertedBuffer)
                } catch {
                    fputs("AudioRecorder write error: \(error.localizedDescription)\n", stderr)
                }
            }
        }
    }

    // MARK: - Streaming Access

    /// Read the current accumulated PCM samples without stopping recording.
    /// Thread-safe: dispatches synchronously on the write queue.
    /// Returns an empty array if not currently recording.
    func currentSamples() -> [Float] {
        guard isRecording else { return [] }
        var samples: [Float] = []
        writeQueue.sync {
            samples = self.pcmSamples
        }
        return samples
    }

    // MARK: - Recording

    func startRecording(to outputURL: URL) throws {
        // Set up the file BEFORE flipping the flag, so the audio thread
        // doesn't try to write to a nil audioFile
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        currentOutputURL = outputURL

        // Atomically: drain pre-roll, set up file, flip to recording mode
        // This ensures no audio samples are lost between drain and flag flip
        stateLock.lock()
        guard !_isRecording else { stateLock.unlock(); return }

        let preroll = prerollBuffer
        prerollBuffer = []
        pcmSamples = preroll
        audioFile = file
        _isRecording = true
        stateLock.unlock()

        print("AudioRecorder: recording started, pre-roll: \(preroll.count) samples (\(Int(Double(preroll.count) / 16000.0 * 1000))ms)")
        DiagnosticLogger.shared.log("AudioRecorder: recording started, pre-roll \(preroll.count) samples (\(Int(Double(preroll.count) / 16000.0 * 1000))ms)")

        // Write pre-roll to WAV file (async, flag is already set so tap writes new audio too)
        if !preroll.isEmpty {
            writePrerollToFile(preroll)
        }

        // If engine isn't running (pre-buffer off), start it now
        if audioEngine == nil {
            startEngine()
        }
    }

    /// Write pre-roll Float32 samples to the WAV file.
    private func writePrerollToFile(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                channelData[i] = samples[i]
            }
        }
        writeQueue.async {
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                fputs("AudioRecorder pre-roll write error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func stopRecording() -> (url: URL, samples: [Float])? {
        // Atomically flip back to pre-roll mode
        stateLock.lock()
        guard _isRecording else { stateLock.unlock(); return nil }
        _isRecording = false
        stateLock.unlock()

        var samples: [Float] = []
        writeQueue.sync {
            self.audioFile = nil
            samples = self.pcmSamples
            self.pcmSamples = []
        }

        let duration = String(format: "%.1f", Double(samples.count) / 16000.0)
        print("AudioRecorder: recording stopped, \(samples.count) total samples (\(duration)s)")
        DiagnosticLogger.shared.log("AudioRecorder: recording stopped, \(samples.count) samples (\(duration)s)")

        // If pre-buffer is off, stop the engine until next recording
        if !preBufferEnabled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
        }

        // If a device change happened during recording, reinstall the tap now
        if needsTapReinstall {
            reinstallTap()
        }

        guard let url = currentOutputURL else { return nil }
        return (url: url, samples: samples)
    }
}
