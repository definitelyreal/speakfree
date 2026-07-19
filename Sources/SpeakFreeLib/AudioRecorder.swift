import AudioToolbox
import AVFoundation
import CoreAudio
import CTryCatch
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private var currentOutputURL: URL?
    private let writeQueue = DispatchQueue(label: "com.definitelyreal.speakfree.audiowrite")
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
                releaseEngineOffMain(&audioEngine)
            }
        }
    }

    /// Drop the last reference to an engine on a background queue, never on main:
    /// -[AVAudioEngine dealloc] dispatch_syncs onto its internal queue, and mid-device-change
    /// that sync can never return — main deadlocked with the overlay stuck on screen
    /// (observed live 2026-07-17; see reinstallTap's retirement comment).
    private func releaseEngineOffMain(_ engine: inout AVAudioEngine?) {
        guard let doomed = engine else { return }
        engine = nil
        DispatchQueue.global(qos: .utility).async { _ = doomed }
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
        releaseEngineOffMain(&audioEngine)
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
            noteDisruption()
            reinstallTap()
            return
        }

        // Engine running but no buffers flowing (silent death)
        let elapsed = Date().timeIntervalSince(lastBufferTime)
        if elapsed > 3.0 {
            DiagnosticLogger.shared.log("AudioRecorder: no audio buffers for \(Int(elapsed))s — rebuilding engine")
            noteDisruption()
            reinstallTap()
        }
    }

    // MARK: - Audio device change monitoring

    /// Microphone pin (2026-07-14): CoreAudio device UID to capture from; nil = system
    /// default. Set via `setPinnedInputDevice` from the menu-bar selector. If the pinned
    /// device is missing at engine build time, capture falls back to the default (logged).
    private(set) var pinnedInputDeviceUID: String?

    // MARK: - Dual-mic capture (2026-07-14, flag-gated prototype)

    /// When on AND the default input is Bluetooth AND no explicit pin is set, the
    /// always-on engine is pinned to the built-in mic and a second stream captures
    /// the Bluetooth mic during each recording for comparison. See DualCapture.swift.
    var dualCaptureEnabled = false {
        didSet {
            guard dualCaptureEnabled != oldValue else { return }
            DiagnosticLogger.shared.log("AudioRecorder: dual-mic capture → \(dualCaptureEnabled)")
            reinstallTap()
        }
    }
    private let secondaryRecorder = SecondaryRecorder()
    /// Dedicated serial queue for the secondary (Bluetooth) capture stream's CoreAudio
    /// start/teardown. Keeps HAL calls off the main thread (2026-07-15 wedge): a stuck
    /// coreaudiod must never block a menu-bar click while speakfree holds the event tap.
    private let secondaryQueue = DispatchQueue(label: "com.speakfree.secondarycapture", qos: .utility)
    /// The Bluetooth comparison track from the most recent recording (empty when dual
    /// capture didn't engage). Consumed by finalize for the corpus diagnostics.
    private(set) var lastSecondarySamples: [Float] = []

    private func dualEngagedNow() -> Bool {
        // Cache-only: this runs inside startEngine (main thread via the rebuild path);
        // live HAL reads here contributed to the 2026-07-15 main-thread wedge.
        DualCapture.shouldEngage(
            flagOn: dualCaptureEnabled,
            pinnedUID: pinnedInputDeviceUID,
            defaultIsBluetooth: AudioDeviceCatalog.cachedDefaultIsBluetooth(),
            hasBuiltIn: AudioDeviceCatalog.cachedBuiltInInput != nil)
    }

    /// Change the capture device and rebuild the engine onto it.
    func setPinnedInputDevice(uid: String?) {
        guard uid != pinnedInputDeviceUID else { return }
        pinnedInputDeviceUID = uid
        DiagnosticLogger.shared.log(
            "AudioRecorder: microphone pin → \(uid ?? "system default") — rebuilding engine")
        reinstallTap()
    }

    /// Name of the device the recorder is actually capturing from (the pin when set and
    /// present, else the system default). Logged into each recording's meta sidecar.
    func currentCaptureDeviceName() -> String? {
        if let uid = pinnedInputDeviceUID, let dev = AudioDeviceCatalog.cachedDevice(withUID: uid) {
            return dev.name
        }
        return AudioDeviceCatalog.cachedDefaultInput?.name
    }

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

            // Debounced: also gives AVAudioEngine time to finish its internal
            // reconfiguration before teardown (removeTap during
            // IOUnitConfigurationChanged deadlocks on the engine's recursive_mutex).
            self.scheduleReinstallDebounced()
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
                self.noteDisruption()
                if self.isRecording {
                    self.needsTapReinstall = true
                } else {
                    self.scheduleReinstallDebounced()
                }
            }
        }
    }

    private var needsTapReinstall = false
    private var isRebuilding = false

    /// Trailing-edge coalescing for device-change events. A Bluetooth handoff storm
    /// (AirPods flapping, degraded coreaudiod) delivers dozens of configuration-change
    /// events in seconds; each used to run its own teardown+rebuild ON MAIN (44 cycles
    /// in ~100s observed 2026-07-16), making the whole app sluggish for the storm's
    /// duration. Every event now just re-arms this work item, so one rebuild runs after
    /// the burst goes quiet.
    private var pendingReinstall: DispatchWorkItem?
    static let reinstallDebounceSeconds: TimeInterval = 0.7

    /// Main-thread only. Re-arms the debounced reinstall; checks recording state at
    /// FIRE time (a recording may have started while the burst was in flight).
    private func scheduleReinstallDebounced() {
        pendingReinstall?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingReinstall = nil
            if self.isRecording {
                self.needsTapReinstall = true
            } else {
                self.reinstallTap()
            }
        }
        pendingReinstall = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.reinstallDebounceSeconds, execute: item)
    }

    // MARK: - Multi-device contention detection (2026-07-14)

    /// Sliding-window detector for the AirPods multi-device fight. Fed from every
    /// route-disruption site below; fires `onContention` (throttled inside the
    /// detector) so AppDelegate can tell the user what is actually happening.
    private var contention = ContentionDetector()
    var onContention: ((String) -> Void)?

    /// Call from any disruption site (device change, engine death, buffer stall).
    /// Only counts while the capture path is Bluetooth — built-in mics don't fight.
    private func noteDisruption() {
        guard AudioDeviceCatalog.cachedDefaultIsBluetooth() else { return }
        if contention.recordDisruption(at: Date()) {
            DiagnosticLogger.shared.log("Contention detected: \(ContentionDetector.noticeText)")
            onContention?(ContentionDetector.noticeText)
        }
    }

    /// Audio engines retired by a device-change teardown, kept alive briefly before release.
    ///
    /// AVFoundation installs its own property listener on the input audio unit
    /// (`AVAudioIOUnit::IOUnitPropertyListener`) and fires it on a private dispatch queue
    /// when the hardware reconfigures. During an AirPods device-change storm, that callback
    /// can fire SECONDS after we've torn the engine down — and if the `AVAudioEngine` has
    /// already deallocated, it messages a freed audio unit → `objc_msgSend` on freed memory
    /// → `EXC_BAD_ACCESS` (the 2026-06-15 crash). Holding a strong reference past teardown
    /// keeps the audio unit alive until the OS finishes reconfiguring; we release it after a
    /// delay that comfortably exceeds the observed ~5 s callback latency. A stopped,
    /// tap-removed engine costs only its memory, and the `isRebuilding` guard serializes
    /// teardowns so at most a handful are ever retained at once.
    private var retiredEngines: [AVAudioEngine] = []
    private let retiredEnginesLock = NSLock()
    private static let retiredEngineLingerSeconds: TimeInterval = 8.0

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

        // Keep the retired engine alive past teardown (see `retiredEngines`) so a late
        // AVFoundation IO-unit property-listener callback during the device change can never
        // message a freed audio unit. Released after the OS settles. reinstallTap() always
        // runs on main; the lock guards against any future off-main caller regardless.
        if let oldEngine = oldEngine {
            retiredEnginesLock.lock()
            retiredEngines.append(oldEngine)
            retiredEnginesLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retiredEngineLingerSeconds) { [weak self] in
                guard let self = self else { return }
                self.retiredEnginesLock.lock()
                self.retiredEngines.removeAll { $0 === oldEngine }
                self.retiredEnginesLock.unlock()
                // NEVER let the last engine reference drop on the main thread:
                // -[AVAudioEngine dealloc] dispatch_syncs onto the engine's internal
                // queue, and if that queue is mid-device-change the sync never returns —
                // main deadlocks with the recording overlay stuck on screen (observed
                // live 2026-07-17, sampled: dispose → _Block_release → AVAudioEngine
                // dealloc → _dispatch_sync_f_slow, 4-hour wedge). Handing the reference
                // to a background queue moves the dealloc (and any wait) off main.
                DispatchQueue.global(qos: .utility).async { _ = oldEngine }
            }
        }

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
                DiagnosticLogger.shared.log("AudioRecorder: old engine stopped (retained \(Int(Self.retiredEngineLingerSeconds))s to outlive late device-change callbacks)")
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

        // Apply the microphone pin BEFORE reading the input format — the format below
        // reflects whichever device the input unit is bound to. Dual capture pins the
        // always-on engine to the built-in mic implicitly (Bluetooth stays released
        // until a recording actually starts).
        let effectivePin = pinnedInputDeviceUID
            ?? (dualEngagedNow() ? AudioDeviceCatalog.cachedBuiltInInput?.uid : nil)
        if let uid = effectivePin {
            if let dev = AudioDeviceCatalog.cachedDevice(withUID: uid), let unit = inputNode.audioUnit {
                var deviceID = dev.id
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                DiagnosticLogger.shared.log(
                    "AudioRecorder: pinned capture to \(dev.name)"
                    + (status == noErr ? "" : " FAILED (err \(status)) — using default"))
            } else {
                DiagnosticLogger.shared.log(
                    "AudioRecorder: pinned device \(uid) not present — using system default")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Guard against the AirPods/Bluetooth-handoff race: during SCO negotiation the
        // input node briefly reports a 0-channel / 0-rate format. Calling installTap
        // with that throws an NSException which (with libggml's terminate hook) becomes
        // SIGABRT. Skip + wait for the next AVAudioEngineConfigurationChange to retry.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            DiagnosticLogger.shared.log(
                "AudioRecorder: skip startEngine — input format not yet valid "
                + "(rate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)); will retry on next config change"
            )
            return
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("AudioRecorder: converter creation failed")
            return
        }
        audioConverter = conv

        // Wrap installTap in a try/catch shim — even with the format guard above, AVAudioEngine
        // can still throw on edge-case formats from external devices. Crashing is worse than
        // missing one tap install: the next configuration-change notification will retry.
        var tapErr: NSError?
        let tapOK = CTryCatch({
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.handleAudioBuffer(buffer, inputFormat: inputFormat, converter: conv)
            }
        }, &tapErr)
        guard tapOK else {
            DiagnosticLogger.shared.log(
                "AudioRecorder: installTap raised NSException — "
                + "\(tapErr?.localizedDescription ?? "unknown"); will retry on next config change"
            )
            return
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
            // Recording mode: write to file + accumulate samples.
            // Enqueue the write BEFORE releasing stateLock so it is ordered ahead of any
            // drain in stopRecording(): stop() can't take stateLock (to flip _isRecording)
            // until this closure is already on the serial writeQueue, so the final buffer
            // can never lose the race and be dropped. The closure takes no stateLock, so
            // enqueuing under the lock cannot deadlock.
            writeQueue.async {
                self.pcmSamples.append(contentsOf: samples)
                do {
                    try self.audioFile?.write(from: convertedBuffer)
                } catch {
                    fputs("AudioRecorder write error: \(error.localizedDescription)\n", stderr)
                }
            }
            stateLock.unlock()
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

    /// R3: current sample count WITHOUT copying the growing PCM buffer. Matches
    /// `currentSamples().count` exactly (both `guard isRecording` then read pcmSamples
    /// under `writeQueue`), so it is a drop-in for the `.count`-only call sites.
    func currentSampleCount() -> Int {
        guard isRecording else { return 0 }
        var count = 0
        writeQueue.sync { count = self.pcmSamples.count }
        return count
    }

    /// R3: the trailing slice of captured audio after `index`, copying ONLY the tail
    /// under `writeQueue` so the 30ms post-buffer poll stops materializing the full
    /// (growing) sample array on every tick. Byte-identical to the old inline
    /// `currentSamples()[index...]` computation — see `trailingSlice`.
    func samples(after index: Int) -> [Float] {
        guard isRecording else { return [] }
        var tail: [Float] = []
        writeQueue.sync { tail = AudioRecorder.trailingSlice(self.pcmSamples, after: index) }
        return tail
    }

    /// Pure slice used by `samples(after:)`, extracted so the old-vs-new equivalence is
    /// unit-testable on a synthetic buffer with no real audio. Preserves the prior
    /// post-buffer computation exactly: `all.count > index ? Array(all[index...]) : []`.
    static func trailingSlice(_ samples: [Float], after index: Int) -> [Float] {
        return samples.count > index ? Array(samples[index...]) : []
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
        // Lock the recording down to owner-only before any audio lands in it (mirrors
        // DualCapture's comparison-track wav). AVAudioFile creates with the default umask,
        // so without this the capture is group/other-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
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
        let device = currentCaptureDeviceName() ?? "unknown"
        DiagnosticLogger.shared.log("AudioRecorder: recording started, pre-roll \(preroll.count) samples (\(Int(Double(preroll.count) / 16000.0 * 1000))ms), input device: \(device)")

        // Write pre-roll to WAV file (async, flag is already set so tap writes new audio too)
        if !preroll.isEmpty {
            writePrerollToFile(preroll)
        }

        // If engine isn't running (pre-buffer off), start it now
        if audioEngine == nil {
            startEngine()
            // startEngine() can no-op (invalid input format, converter/tap failure) and leave
            // audioEngine nil. With pre-buffer off there is no always-on stream to fall back
            // on, so the flag would be set with nothing capturing — a silent empty dictation.
            // Unwind: drop back to not-recording, close/remove the file, and surface the
            // failure so the caller (AppDelegate) resets its UI instead of "recording".
            if audioEngine == nil {
                DiagnosticLogger.shared.log(
                    "AudioRecorder: engine failed to start with pre-buffer off — aborting recording")
                stateLock.lock()
                _isRecording = false
                audioFile = nil
                prerollBuffer = preroll  // coherent: pre-buffer off means preroll is empty
                pcmSamples = []
                stateLock.unlock()
                currentOutputURL = nil
                try? FileManager.default.removeItem(at: outputURL)
                throw AudioRecorderError.engineStartFailed
            }
        }

        // Dual capture: open the Bluetooth comparison stream for this recording only.
        // CoreAudio start runs on the dedicated secondary queue, never main (AU-D).
        lastSecondarySamples = []
        if dualEngagedNow(), let bt = AudioDeviceCatalog.cachedDefaultInput, !bt.isBuiltIn {
            secondaryQueue.async { _ = self.secondaryRecorder.start(device: bt) }
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

        // Close the Bluetooth comparison stream (no-op when dual capture didn't engage).
        // Read the captured samples synchronously — collectSamples() is a cheap lock-guarded
        // buffer read, NO CoreAudio — so the caller has the comparison track the moment
        // stopRecording() returns. The actual HAL teardown (removeTap/stop) runs off main on
        // the secondary queue so a stuck coreaudiod can't wedge the main thread (AU-D).
        lastSecondarySamples = secondaryRecorder.collectSamples()
        secondaryQueue.async { self.secondaryRecorder.teardown() }
        if !lastSecondarySamples.isEmpty {
            DiagnosticLogger.shared.log(
                "AudioRecorder: dual capture collected \(lastSecondarySamples.count) BT samples "
                + "(\(String(format: "%.1f", Double(lastSecondarySamples.count) / 16000.0))s)")
        }

        // If pre-buffer is off, stop the engine until next recording
        if !preBufferEnabled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            releaseEngineOffMain(&audioEngine)
        }

        // If a device change happened during recording, reinstall the tap now
        if needsTapReinstall {
            reinstallTap()
        }

        guard let url = currentOutputURL else { return nil }
        return (url: url, samples: samples)
    }
}

enum AudioRecorderError: LocalizedError {
    /// The capture engine could not be started (pre-buffer off path), so there is no
    /// stream to record from. Thrown from `startRecording` so the caller can reset its UI.
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .engineStartFailed:
            return "Audio engine failed to start"
        }
    }
}
