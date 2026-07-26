import AudioToolbox
import AVFoundation
import CoreAudio
import CTryCatch
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioFile: WavWriter?
    private var currentOutputURL: URL?
    private let writeQueue = DispatchQueue(label: "com.definitelyreal.speakfree.audiowrite")
    private var pcmSamples: [Float] = []

    /// Current RMS audio level (0.0–1.0), updated from the audio tap.
    private(set) var currentLevel: Float = 0

    /// Timestamp of last audio buffer received — used by health check to detect dead engines.
    /// Buffer-health state, guarded by its own lock (codex review #8: the bare `Date`
    /// was written on the audio thread and read from main — a real data race once the
    /// watchdog made it load-bearing). Monotonic uptime, not wall clock. `peakSinceCheck`
    /// accumulates the max |sample| between watchdog reads so the watchdog can tell a
    /// LIVE-BUT-SILENT capture (muted mic delivering zero-filled buffers — codex #4)
    /// from real speech; callbacks alone can't.
    /// Latch: log the first wav write failure per recording to DiagnosticLogger (review #13).
    private var wavWriteFailureLogged = false
    private let bufferHealthLock = NSLock()
    private var lastBufferUptime: Double = ProcessInfo.processInfo.systemUptime
    private var peakSinceCheck: Float = 0

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
        bufferHealthLock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - lastBufferUptime
        bufferHealthLock.unlock()
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

    // MARK: - Dual-mic capture

    /// When on and no explicit pin is set, the always-on engine is pinned to the
    /// built-in mic. Any available Bluetooth mic opens only during a recording.
    var dualCaptureEnabled = false {
        didSet {
            guard dualCaptureEnabled != oldValue else { return }
            DiagnosticLogger.shared.log("AudioRecorder: dual-mic capture → \(dualCaptureEnabled)")
            // Setup applies routing before warmUp. Starting a delayed rebuild with no
            // engine yet races warmUp's immediate start and can stop the new engine.
            guard audioEngine != nil else { return }
            reinstallTap()
        }
    }
    private let secondaryRecorder = SecondaryRecorder()
    /// Dedicated serial queue for the secondary (Bluetooth) capture stream's CoreAudio
    /// start/teardown. Keeps HAL calls off the main thread (2026-07-15 wedge): a stuck
    /// coreaudiod must never block a menu-bar click while speakfree holds the event tap.
    private let secondaryQueue = DispatchQueue(label: "com.speakfree.secondarycapture", qos: .utility)
    private func dualEngagedNow() -> Bool {
        // Cache-only: this runs inside startEngine (main thread via the rebuild path);
        // live HAL reads here contributed to the 2026-07-15 main-thread wedge.
        DualCapture.shouldEngage(
            flagOn: dualCaptureEnabled,
            pinnedUID: pinnedInputDeviceUID,
            hasBuiltIn: AudioDeviceCatalog.cachedBuiltInInput != nil,
            hasBluetooth: AudioDeviceCatalog.cachedBluetoothInput != nil)
    }

    private func usesBuiltInPrimaryNow() -> Bool {
        DualCapture.shouldUseBuiltInPrimary(
            flagOn: dualCaptureEnabled,
            pinnedUID: pinnedInputDeviceUID,
            hasBuiltIn: AudioDeviceCatalog.cachedBuiltInInput != nil)
    }

    private func primaryFollowsSystemDefaultNow() -> Bool {
        DualCapture.primaryFollowsSystemDefault(
            flagOn: dualCaptureEnabled,
            pinnedUID: pinnedInputDeviceUID,
            hasBuiltIn: AudioDeviceCatalog.cachedBuiltInInput != nil)
    }

    /// Change the capture device and rebuild the engine onto it.
    func setPinnedInputDevice(uid: String?) {
        guard uid != pinnedInputDeviceUID else { return }
        pinnedInputDeviceUID = uid
        DiagnosticLogger.shared.log(
            "AudioRecorder: microphone pin → \(uid ?? "system default") — rebuilding engine")
        guard audioEngine != nil else { return }
        reinstallTap()
    }

    /// Name of the device the recorder is actually capturing from (the pin when set and
    /// present, else the system default). Logged into each recording's meta sidecar.
    func currentCaptureDeviceName() -> String? {
        if let uid = pinnedInputDeviceUID, let dev = AudioDeviceCatalog.cachedDevice(withUID: uid) {
            return dev.name
        }
        if usesBuiltInPrimaryNow() {
            return AudioDeviceCatalog.cachedBuiltInInput?.name
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
            guard let self = self, let changedEngine = notification.object as? AVAudioEngine,
                  changedEngine === self.audioEngine else {
                return
            }

            // Device binding itself emits this notification within moments of the
            // engine build — reacting to it caused the 2026-07-20 self-induced rebuild
            // loop. But a LATER config change on a pinned engine is genuine (format
            // renegotiation): its tap is dead until rebuilt. The 2026-07-22 outage was
            // this exact blanket-ignore — every recording captured 0 samples and
            // "recovery" rebuilds died the same way. Ignore only the self-induced
            // window; rebuild on anything after it.
            if !self.primaryFollowsSystemDefaultNow() {
                if Date().timeIntervalSince(self.engineBuiltAt) < Self.selfInducedConfigWindowSeconds {
                    DiagnosticLogger.shared.log(
                        "AudioRecorder: primary configuration changed just after build — self-induced, keeping engine")
                    return
                }
                DiagnosticLogger.shared.log(
                    "AudioRecorder: pinned primary configuration changed after settle — rebuilding (stale-tap risk)")
            } else {
                DiagnosticLogger.shared.log(
                    "AudioRecorder: primary audio configuration changed — scheduling tap reinstall")
            }

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
                guard self.primaryFollowsSystemDefaultNow() else {
                    DiagnosticLogger.shared.log(
                        "AudioRecorder: default input changed but primary is pinned — no rebuild")
                    return
                }
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

    /// When the current engine was built. Config-change notifications inside this
    /// window after a build are the engine's own bind settling (ignoring them
    /// prevents the 2026-07-20 rebuild loop); ones after it are genuine and MUST
    /// rebuild even when pinned (the 2026-07-22 dead-tap outage).
    private var engineBuiltAt: Date = .distantPast
    static let selfInducedConfigWindowSeconds: TimeInterval = 2.0

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

    /// Storm detector for the AirPods multi-device fight (chained rapid events, so
    /// deliberate connect/disconnect pocket cycles don't false-positive). Fed from every
    /// route-disruption site below; fires `onContention` (throttled inside the
    /// detector) so AppDelegate can tell the user what is actually happening.
    private var contention = ContentionDetector()
    var onContention: ((String) -> Void)?

    /// Call from any disruption site (device change, engine death, buffer stall).
    /// Only counts while the capture path is Bluetooth — built-in mics don't fight.
    private func noteDisruption() {
        guard AudioDeviceCatalog.cachedBluetoothInput != nil else { return }
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
            ?? (usesBuiltInPrimaryNow() ? AudioDeviceCatalog.cachedBuiltInInput?.uid : nil)
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

        // DEVICE/input scope, not client/output scope (2026-07-22 dead-air outage):
        // after re-binding the input unit (pin to built-in while the system default
        // is AirPods), the client scope keeps reporting the OLD device's format
        // (24 kHz SCO) — a tap installed with it never receives a frame, and every
        // rebuild died the same way (0-sample recordings, all dropped). The
        // SecondaryRecorder learned this on 2026-07-20; the primary now matches.
        let inputFormat = inputNode.inputFormat(forBus: 0)

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
            // Restart the no-buffers health clock. It was initialized at recorder
            // INIT, so at launch the "no audio buffers for 3s" check fired against an
            // engine that had only just started (2026-07-22 log: spurious teardown +
            // rebuild on main 3s after startup). Buffers get their grace period from
            // engine start, not object creation.
            bufferHealthLock.lock()
            lastBufferUptime = ProcessInfo.processInfo.systemUptime
            bufferHealthLock.unlock()
            engineBuiltAt = Date()
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

        let count = Int(convertedBuffer.frameLength)

        // RMS level for visualizer + peak for the silence watchdog
        var sum: Float = 0
        var bufPeak: Float = 0
        for i in 0..<count {
            let v = channelData[i]
            sum += v * v
            bufPeak = max(bufPeak, abs(v))
        }
        let rms = sqrtf(sum / Float(max(count, 1)))
        self.currentLevel = min(rms / 0.15, 1.0)

        // Track buffer arrival + level for the health checks (locked: read from main)
        bufferHealthLock.lock()
        lastBufferUptime = ProcessInfo.processInfo.systemUptime
        peakSinceCheck = max(peakSinceCheck, bufPeak)
        bufferHealthLock.unlock()

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
                    try self.audioFile?.append(samples)
                } catch {
                    fputs("AudioRecorder write error: \(error.localizedDescription)\n", stderr)
                    // Once per recording (review #13): the crash-safety wav silently
                    // dying (disk full) must reach the diagnostic log — dictation
                    // still completes from memory, but recovery protection is gone.
                    if !self.wavWriteFailureLogged {
                        self.wavWriteFailureLogged = true
                        DiagnosticLogger.shared.log(
                            "AudioRecorder: wav write FAILING (\(error.localizedDescription)) — crash recovery unavailable for this recording")
                    }
                }
            }
            stateLock.unlock()
        }
    }

    /// Seconds since the last audio buffer arrived from the tap. Feeds the in-recording
    /// dead-audio watchdog (2026-07-25): a 60-minute hold previously had ZERO health
    /// checks between record-start and stop. Benign torn-read tolerated (Date is a
    /// single Double internally; a rare stale value only delays detection one tick).
    func secondsSinceLastBuffer() -> Double {
        bufferHealthLock.lock()
        defer { bufferHealthLock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastBufferUptime
    }

    /// Max |sample| observed since the previous call (then resets). The watchdog uses
    /// this to catch a mic that keeps DELIVERING buffers but only silence (codex #4) —
    /// buffer arrival alone cannot distinguish that from real capture.
    func peakSinceLastCheck() -> Float {
        bufferHealthLock.lock()
        defer { bufferHealthLock.unlock() }
        let p = peakSinceCheck
        peakSinceCheck = 0
        return p
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
        // Set up the file BEFORE flipping the flag, so the audio thread doesn't try to
        // write to a nil audioFile. WavWriter (not AVAudioFile): it re-patches the RIFF
        // header every ~5s, so a killed process loses seconds, not the whole recording —
        // AVAudioFile committed sizes only at close, and the 2026-07-25 recovery audit
        // found 94 corpus orphans (one 37 min long) unreadable for exactly that reason.
        // WavWriter creates the file 0o600 itself (no world-readable window).
        let file = try WavWriter(url: outputURL)
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
        writeQueue.async { self.wavWriteFailureLogged = false }

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
                stateLock.unlock()
                // Close on the WRITE QUEUE (review #9): a writePrerollToFile append may
                // be in flight there, and WavWriter is single-queue by contract — a
                // caller-thread close can interleave header seeks with an append.
                writeQueue.sync {
                    self.audioFile?.close()
                    self.audioFile = nil
                }
                stateLock.lock()
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
        if dualEngagedNow(), let bt = AudioDeviceCatalog.cachedBluetoothInput {
            secondaryQueue.async { _ = self.secondaryRecorder.start(device: bt) }
        }
    }

    /// Write pre-roll Float32 samples to the WAV file.
    private func writePrerollToFile(_ samples: [Float]) {
        writeQueue.async {
            do {
                try self.audioFile?.append(samples)
            } catch {
                fputs("AudioRecorder pre-roll write error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func stopRecording() -> (url: URL, samples: [Float], secondary: SecondaryCaptureResult)? {
        // Atomically flip back to pre-roll mode
        stateLock.lock()
        guard _isRecording else { stateLock.unlock(); return nil }
        _isRecording = false
        stateLock.unlock()

        var samples: [Float] = []
        writeQueue.sync {
            self.audioFile?.close()   // final header patch — the wav is valid from here
            self.audioFile = nil
            samples = self.pcmSamples
            self.pcmSamples = []
        }

        let duration = String(format: "%.1f", Double(samples.count) / 16000.0)
        // Level forensics: a "successful" capture of dead air (muted mic, stale input
        // route) is indistinguishable from real speech in every other log line — the
        // 2026-07-25 lost dictation took a python RMS pass over the wav to diagnose.
        // Speech RMS is typically >1% FS; silent captures sit near 0.1%.
        var sumSquares: Float = 0
        var peak: Float = 0
        for s in samples {
            sumSquares += s * s
            peak = max(peak, abs(s))
        }
        let rmsPctFS = samples.isEmpty ? 0 : sqrt(sumSquares / Float(samples.count)) * 100
        let levelNote = String(format: "rms %.2f%%FS peak %.1f%%FS", rmsPctFS, peak * 100)
        print("AudioRecorder: recording stopped, \(samples.count) total samples (\(duration)s, \(levelNote))")
        DiagnosticLogger.shared.log("AudioRecorder: recording stopped, \(samples.count) samples (\(duration)s, \(levelNote))")

        // Queue stop behind start on the SAME serial queue. The old main-thread buffer
        // snapshot could beat a slow Bluetooth start and return an empty track for short
        // dictations. Finalization awaits this result off-main.
        let secondary = SecondaryCaptureResult()
        secondaryQueue.async {
            let btSamples = self.secondaryRecorder.stop()
            if !btSamples.isEmpty {
                DiagnosticLogger.shared.log(
                    "AudioRecorder: dual capture collected \(btSamples.count) BT samples "
                    + "(\(String(format: "%.1f", Double(btSamples.count) / 16000.0))s)")
            }
            secondary.resolve(btSamples)
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
        return (url: url, samples: samples, secondary: secondary)
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
