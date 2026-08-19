// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import AppKit
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
    private var recordingGeneration = 0
    private var firstBufferArrived = false
    static let firstBufferGuardSeconds: TimeInterval = 1.0

    /// Whether the pre-buffer engine should run. When false, engine only starts on startRecording.
    var preBufferEnabled: Bool = true {
        didSet {
            if preBufferEnabled && audioEngine == nil {
                startEngine()
            } else if !preBufferEnabled && !isRecording {
                // Stop the engine when not recording
                stopBoundDeviceWatch()
                boundDeviceUID = nil
                boundDeviceID = nil
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
        stopBoundDeviceWatch()
        boundDeviceUID = nil
        boundDeviceID = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        releaseEngineOffMain(&audioEngine)
    }

    /// Start the always-on audio engine. Call once on app launch.
    ///
    /// Bounced to main: `setup()` runs off-main, and every engine-lifecycle field here
    /// (`audioEngine`, `isRebuilding`, `boundDevice*`, `pendingReinstall`) is main-thread
    /// state with no lock of its own.
    func warmUp() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.warmUp() }
            return
        }
        // The device monitors run even with the pre-buffer off, so a device change while
        // idle still leaves a correct binding for the next on-demand engine start.
        startDeviceChangeMonitor()
        guard preBufferEnabled else { return }
        startEngine()
    }

    /// Verify audio is flowing. If the engine is dead, rebuild it.
    /// Call this before every recording to catch silent AirPods handoffs.
    /// Only rebuilds audio — never touches the whisper model.
    func ensureAudioHealthy() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.ensureAudioHealthy() }
            return
        }
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

    /// Consecutive engine builds whose device bind FAILED while the device was present.
    /// Caps how many times a device-list event may retry the same failing bind (see the
    /// finding-2 comment at the bind site). Reset on any successful or pin-free build.
    private var consecutiveBindFailures = 0
    static let bindRetryCap = 3
    /// Delay before re-attempting a pin bind that returned `kAudioHardwareIllegalOperationError`
    /// ('nope'). That failure is transient and clusters immediately after wake-from-sleep, when
    /// coreaudiod is still re-initializing the device and rejects the CurrentDevice set. Give it
    /// room to settle rather than living on the fallback device for the rest of the session.
    static let bindRetryDelaySeconds: TimeInterval = 2.0

    // MARK: - Effective capture device (default-pin rule, 2026-08-12)

    /// THE capture-device rule: an explicit user pin always wins; with no pin,
    /// speakfree captures the BUILT-IN microphone whenever the Mac has one; only a
    /// machine with no built-in input (a Mac mini with USB mics only) follows the
    /// system default. `nil` means "follow the system default".
    ///
    /// Why the built-in is the default: macOS silently flips the default input to
    /// AirPods the moment they connect. That both degrades their audio (the HFP/SCO
    /// downgrade) and captures a microphone the user never chose — 11.9% of the local
    /// recording archive was captured that way. Pinning the built-in makes the flip a
    /// no-op; anyone who genuinely wants another mic picks it in the menu-bar selector.
    static func effectivePin(explicitPin: String?, builtInUID: String?) -> String? {
        explicitPin ?? builtInUID
    }

    /// `effectivePin` against the current device cache. Cache-only by design: this runs
    /// on the main thread inside startEngine and the rebuild path, and live HAL reads
    /// here contributed to the 2026-07-15 main-thread wedge.
    private func effectivePinNow() -> String? {
        Self.effectivePin(
            explicitPin: pinnedInputDeviceUID,
            builtInUID: AudioDeviceCatalog.cachedBuiltInInput?.uid)
    }

    /// A primary bound to a specific device (explicitly or by the built-in default)
    /// does not need rebuilding when the system default changes. This is also the
    /// circuit break that prevents our own device binding from creating an
    /// AVAudioEngine configuration-change feedback loop.
    private func primaryFollowsSystemDefaultNow() -> Bool {
        effectivePinNow() == nil
    }

    // MARK: - Bound-device tracking (device-churn resilience, 2026-08-12)
    //
    // The pin is UID-keyed, but the ENGINE is bound to a numeric AudioDeviceID, and
    // CoreAudio renumbers those across re-enumeration (sleep/wake, USB replug, Bluetooth
    // rejoin). A pin that still resolves while the engine talks to a dead ID is the
    // ghost-pepper bug class: everything looks healthy and no audio arrives. So the
    // numeric ID we actually bound is retained ALONGSIDE the UID, purely so a device-list
    // change can be compared against it. Nothing else may key off `boundDeviceID`.

    private var boundDeviceUID: String?
    private var boundDeviceID: AudioDeviceID?
    private var boundDeviceListeners: [AudioDeviceCatalog.DeviceListenerToken] = []
    /// Per-device CoreAudio alerts land here — never main (a blocking main-thread HAL
    /// callback is the 2026-07-15 wedge) and never the HAL's own thread.
    private let deviceWatchQueue = DispatchQueue(
        label: "com.speakfree.capturedevicewatch", qos: .utility)

    /// Why a device-list change invalidates the current engine binding, or nil when it
    /// does not. Pure: the whole rule is visible here and testable without hardware.
    ///
    /// - An engine following the system default is not covered here — the default-input
    ///   listener already owns it, and reacting twice re-creates the 2026-07-20 loop.
    /// - A bound UID that is gone, or that came back on a different `AudioDeviceID`, is a
    ///   dead binding.
    /// - A pin that was ABSENT at build time (engine fell back to the system default) and
    ///   is now present must also rebuild — otherwise reconnecting the chosen microphone
    ///   never takes effect.
    static func deviceListRebuildReason(
        boundUID: String?, boundID: AudioDeviceID?,
        effectivePinTarget: String? = nil, engineExists: Bool = false,
        bindRetryExhausted: Bool = false,
        devices: [AudioInputDevice]
    ) -> String? {
        guard let uid = boundUID else {
            // Cold-start heal (adversarial VERIFY 2026-08-12, blocker 2): the first engine
            // build can beat the catalog's async first scan, in which case an unpinned
            // user's engine binds NOTHING and follows the system default (AirPods!) while
            // `currentCaptureDeviceName` reports the built-in mic into every sidecar. The
            // default-input listener won't repair it (its guard asks what SHOULD happen,
            // not what did), so this branch closes the disagreement: a live engine with no
            // binding, when the pin target is now enumerable, is an orphan — rebuild it.
            if engineExists, let target = effectivePinTarget,
               devices.contains(where: { $0.uid == target }) {
                return "engine is unbound but pin target \(target) is now present (cold-start heal)"
            }
            return nil
        }
        let match = devices.first { $0.uid == uid }
        switch (boundID, match) {
        case (nil, nil):
            return nil
        case (nil, .some(let device)):
            // Retry budget (finding 2): this state is EITHER a device that was absent and
            // returned (retry immediately, always) OR a bind that keeps failing while the
            // device sits present (retry only until the cap, or every device event storms
            // a rebuild that fails the same way).
            guard !bindRetryExhausted else { return nil }
            return "pinned device \(device.name) is present again"
        case (.some, nil):
            return "bound capture device \(uid) departed"
        case (.some(let old), .some(let device)):
            guard old != device.id else { return nil }
            return "bound capture device \(device.name) was renumbered (\(old) → \(device.id))"
        }
    }

    /// Whether a per-device property alert on the bound capture device warrants a rebuild.
    ///
    /// `presentInDeviceList` is the authority and is checked FIRST: a departed device can
    /// keep reporting `IsAlive == true` with a valid ID, so `IsAlive` is never trusted on
    /// its own. The settle window is the same circuit break the configuration-change path
    /// uses — binding the unit makes the device's own rate/stream properties move, and
    /// treating that as an external change is exactly the 2026-07-20 self-induced rebuild
    /// loop. A DEPARTURE is never self-induced, so it skips the window.
    static func shouldRebuildForDeviceAlert(
        selector: AudioObjectPropertySelector,
        isAlive: Bool?,
        presentInDeviceList: Bool,
        secondsSinceEngineBuilt: TimeInterval
    ) -> Bool {
        if !presentInDeviceList { return true }
        if secondsSinceEngineBuilt < selfInducedConfigWindowSeconds { return false }
        if selector == kAudioDevicePropertyDeviceIsAlive { return isAlive == false }
        // HasChanged / StreamConfiguration / NominalSampleRate: the format under the
        // installed tap may have moved, and a tap on a stale format receives nothing.
        return true
    }

    /// What waking (or returning from a fast-user-switch) should do to the capture engine.
    ///
    /// Sleep is a known-blind window: device IDs can be renumbered and the input unit's
    /// stream description can go stale, with no notification that survives the sleep. An
    /// existing engine is therefore ALWAYS discarded and rebuilt rather than inspected —
    /// there is no cheap way to prove a post-wake engine is still live, and a rebuild
    /// costs about a second of pre-roll while a stale engine costs a whole dictation.
    enum ResumeAction: Equatable { case none, startEngine, rebuild }

    static func resumeAction(preBufferEnabled: Bool, engineExists: Bool) -> ResumeAction {
        if engineExists { return .rebuild }
        return preBufferEnabled ? .startEngine : .none
    }

    /// Whether the input format the engine reports can be trusted enough to install a tap.
    ///
    /// Zero rate or zero channels is the AirPods SCO-negotiation race (installTap throws,
    /// which libggml's terminate hook turns into SIGABRT). A rate that disagrees with the
    /// hardware's own nominal rate is the documented stale-format trap: after re-binding,
    /// the input unit can keep reporting the PREVIOUS device's stream description, and a
    /// tap installed with it never receives a frame (the 2026-07-22 dead-air outage).
    /// Hardware values are optional because an unreadable device must not veto capture.
    ///
    /// The rate cross-check is skipped for Bluetooth devices: their nominal rate reflects
    /// the OUTPUT (A2DP) side, while the mic path legitimately runs lower (AirPods Pro
    /// deliver 24 kHz input against a 48 kHz nominal). Treating that split as stale made
    /// every pin-to-AirPods start fail with "the microphone couldn't be used" until the
    /// retry budget ran out (2026-08-19 airplane logs, 14:19 and 15:35 EDT).
    static func isCaptureFormatUsable(
        engineRate: Double, engineChannels: UInt32, deviceRate: Double?, deviceChannels: Int?,
        deviceIsBluetooth: Bool = false
    ) -> Bool {
        guard engineRate > 0, engineChannels > 0 else { return false }
        if !deviceIsBluetooth,
           let deviceRate = deviceRate, deviceRate > 0, abs(engineRate - deviceRate) > 1.0 {
            return false
        }
        if let deviceChannels = deviceChannels, deviceChannels > 0,
           Int(engineChannels) > deviceChannels {
            return false
        }
        return true
    }

    /// Skip-and-retry, but bounded: after `maxRetries` the suspect format is accepted
    /// anyway. No engine at all is a worse failure than a suspect one — a stale format is
    /// caught by the in-recording watchdog, while an engineless recorder captures nothing
    /// and has nothing left to recover from.
    static func shouldSkipUnusableFormat(retriesSoFar: Int, maxRetries: Int = 3) -> Bool {
        retriesSoFar < maxRetries
    }

    private var unusableFormatRetries = 0

    /// Change the capture device and rebuild the engine onto it.
    func setPinnedInputDevice(uid: String?) {
        guard uid != pinnedInputDeviceUID else { return }
        pinnedInputDeviceUID = uid
        DiagnosticLogger.shared.log(
            "AudioRecorder: microphone pin → \(uid ?? "system default") — rebuilding engine")
        guard audioEngine != nil else { return }
        reinstallTap()
    }

    /// Name of the device the recorder is actually capturing from: the explicit pin when
    /// set and present, else the built-in mic (the default-pin rule), else the system
    /// default. Logged into each recording's meta sidecar.
    func currentCaptureDeviceName() -> String? {
        if let uid = pinnedInputDeviceUID {
            // An explicit pin whose device has vanished is NOT replaced by the built-in:
            // startEngine leaves the unit on the system default and says so in the log.
            return AudioDeviceCatalog.cachedDevice(withUID: uid)?.name
                ?? AudioDeviceCatalog.cachedDefaultInput?.name
        }
        return AudioDeviceCatalog.cachedBuiltInInput?.name
            ?? AudioDeviceCatalog.cachedDefaultInput?.name
    }

    private var deviceChangeObserver: NSObjectProtocol?
    private var resumeObservers: [NSObjectProtocol] = []
    private var deviceMonitorsStarted = false

    /// Reinstall the audio tap when the input device changes (e.g. AirPods connect/disconnect).
    private func startDeviceChangeMonitor() {
        guard !deviceMonitorsStarted else { return }
        deviceMonitorsStarted = true
        startDeviceListMonitor()
        startResumeObservers()

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

            // A pinned built-in engine can still lose its tap when AirPods join/leave.
            // Deferring this rebuild until key-up guarantees capture loss: the dead tap
            // cannot resume on its own. Rebuild in place; `_isRecording`, `pcmSamples`,
            // and the open WavWriter survive the engine swap, so audio after the short
            // route-settle gap appends to the same take.
            if self.isRecording {
                DiagnosticLogger.shared.log(
                    "AudioRecorder: configuration changed during recording — rebuilding tap in place")
                self.reinstallTap()
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
                    DiagnosticLogger.shared.log(
                        "AudioRecorder: default input changed during recording — rebuilding tap in place")
                    self.reinstallTap()
                } else {
                    self.scheduleReinstallDebounced()
                }
            }
        }
    }

    // MARK: - Device-list watch (the authoritative churn signal, 2026-08-12)

    /// `kAudioHardwarePropertyDevices` is the signal that actually fires for Bluetooth
    /// re-registration; AVFoundation's connect/disconnect notifications do not fire
    /// reliably for it, which leaves an app recording from a device that no longer
    /// exists. AudioDeviceCatalog already owns that HAL listener, so this subscribes to
    /// the catalog rather than registering a competing one — one list, one refresh order.
    private func startDeviceListMonitor() {
        AudioDeviceCatalog.onDeviceListChanged = { [weak self] _, current in
            // Catalog callbacks already arrive on main.
            self?.handleDeviceListChanged(current)
        }
        // Reconcile against the cache that already exists (VERIFY round 2, finding 1):
        // the catalog's FIRST scan can land between engine build and this subscription,
        // and a delta published before the subscriber exists is silently dropped — which
        // is exactly the scan the cold-start heal was built to catch. Evaluating once at
        // install time makes the repair deterministic instead of waiting on a second
        // device event that may never come.
        handleDeviceListChanged(AudioDeviceCatalog.cachedInputDevices)
    }

    /// Main-thread. Internal so tests can drive the rule with a synthetic device list.
    func handleDeviceListChanged(_ devices: [AudioInputDevice]) {
        guard let reason = Self.deviceListRebuildReason(
            boundUID: boundDeviceUID, boundID: boundDeviceID,
            effectivePinTarget: effectivePinNow(), engineExists: audioEngine != nil,
            bindRetryExhausted: consecutiveBindFailures >= Self.bindRetryCap,
            devices: devices) else { return }
        noteDisruption()
        DiagnosticLogger.shared.log("AudioRecorder: device list changed — \(reason)")
        if isRecording {
            reinstallTap()
        } else {
            scheduleReinstallDebounced()
        }
    }

    // MARK: - Per-device watch on the bound capture device

    /// Watch the device we are actually capturing from, not just the system's device list:
    /// a device can change its stream format or start dying without the list changing at
    /// all, and the tap installed on the old format then receives nothing.
    private func startBoundDeviceWatch(deviceID: AudioDeviceID) {
        stopBoundDeviceWatch()
        boundDeviceListeners = AudioDeviceCatalog.addCaptureDeviceListeners(
            deviceID: deviceID, queue: deviceWatchQueue
        ) { [weak self] selector in
            // Already off-main on our own queue: safe to do the blocking HAL reads the
            // decision needs, and required — never tear an engine down inside a CoreAudio
            // callback (Apple's documented deadlock).
            guard let self = self else { return }
            let isAlive = AudioDeviceCatalog.deviceIsAlive(deviceID)
            let present = AudioDeviceCatalog.inputDevices().contains { $0.id == deviceID }
            DispatchQueue.main.async {
                guard self.boundDeviceID == deviceID else { return }  // stale callback
                let shouldRebuild = Self.shouldRebuildForDeviceAlert(
                    selector: selector, isAlive: isAlive, presentInDeviceList: present,
                    secondsSinceEngineBuilt: Date().timeIntervalSince(self.engineBuiltAt))
                guard shouldRebuild else { return }
                self.noteDisruption()
                DiagnosticLogger.shared.log(
                    "AudioRecorder: capture device alert \(Self.selectorLabel(selector)) "
                    + "(alive=\(isAlive.map(String.init) ?? "unknown"), inList=\(present)) — rebuilding")
                if self.isRecording {
                    self.reinstallTap()
                } else {
                    self.scheduleReinstallDebounced()
                }
            }
        }
    }

    private func stopBoundDeviceWatch() {
        guard !boundDeviceListeners.isEmpty else { return }
        AudioDeviceCatalog.removeCaptureDeviceListeners(boundDeviceListeners)
        boundDeviceListeners = []
    }

    static func selectorLabel(_ selector: AudioObjectPropertySelector) -> String {
        switch selector {
        case kAudioDevicePropertyDeviceHasChanged: return "DeviceHasChanged"
        case kAudioDevicePropertyDeviceIsAlive: return "DeviceIsAlive"
        case kAudioDevicePropertyStreamConfiguration: return "StreamConfiguration"
        case kAudioDevicePropertyNominalSampleRate: return "NominalSampleRate"
        default: return "selector \(selector)"
        }
    }

    // MARK: - Sleep / wake / fast-user-switch

    /// Sleep and fast-user-switch are blind windows for audio in a way no notification
    /// covers: devices can be renumbered while the machine is asleep, and the input unit
    /// can come back holding a stale stream description. The catalog is refreshed FIRST so
    /// the rebuild resolves the pin against post-wake IDs — rebuilding against the
    /// pre-sleep cache would bind an AudioDeviceID that no longer exists.
    private func startResumeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "wake from sleep"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "fast-user-switch return"),
        ]
        for (name, reason) in events {
            resumeObservers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.handleSystemResume(reason)
                })
        }
    }

    /// Main-thread. Internal so tests can drive it without posting workspace notifications.
    func handleSystemResume(_ reason: String) {
        DiagnosticLogger.shared.log("AudioRecorder: \(reason) — re-enumerating devices")
        AudioDeviceCatalog.refreshNow { [weak self] in
            guard let self = self else { return }
            switch Self.resumeAction(
                preBufferEnabled: self.preBufferEnabled, engineExists: self.audioEngine != nil) {
            case .none:
                DiagnosticLogger.shared.log(
                    "AudioRecorder: \(reason) — pre-buffer off and no engine, nothing to rebuild")
            case .startEngine:
                DiagnosticLogger.shared.log("AudioRecorder: \(reason) — starting engine")
                self.startEngine()
            case .rebuild:
                DiagnosticLogger.shared.log(
                    "AudioRecorder: \(reason) — discarding the pre-sleep engine and rebuilding")
                self.reinstallTap()
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
        // Every caller must land on main. `ensureAudioHealthy` runs from an off-main
        // startup path, and the CoreAudio/HAL callbacks below are on their own queues —
        // a rebuild from any of those would race main over `isRebuilding`/`audioEngine`
        // AND risk tearing an engine down inside a CoreAudio callback (Apple's documented
        // deadlock). Async, never sync: a sync hop from a HAL callback is the deadlock.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reinstallTap() }
            return
        }
        guard !isRebuilding else {
            DiagnosticLogger.shared.log("AudioRecorder: rebuild already in progress — skipping")
            return
        }
        isRebuilding = true
        DiagnosticLogger.shared.log("AudioRecorder: tearing down engine for device change (isMainThread=\(Thread.isMainThread))")

        // Stop watching the device this engine was bound to BEFORE the teardown, so a
        // late per-device alert can never schedule a rebuild against a retired binding.
        stopBoundDeviceWatch()
        boundDeviceUID = nil
        boundDeviceID = nil

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

    /// Last-resort recovery when the in-recording watchdog sees that no buffers are arriving.
    /// Device notifications are not reliable during every Bluetooth handoff, so the watchdog
    /// must be able to revive the tap without waiting for key-up. The recording's accumulated
    /// samples and open WavWriter remain intact across `reinstallTap()`.
    func recoverDeadCaptureDuringRecording() {
        guard isRecording else { return }
        DiagnosticLogger.shared.log(
            "AudioRecorder: watchdog rebuilding dead tap during active recording")
        reinstallTap()
    }

    /// Bounded retry after a skipped engine start. Without it a skip waits for the next
    /// device event, and if none ever comes the recorder sits engineless — the 0-sample
    /// dictation. Bounded because an unbounded self-scheduled rebuild IS the storm.
    private func scheduleFormatRetry(_ detail: String) {
        guard Self.shouldSkipUnusableFormat(retriesSoFar: unusableFormatRetries) else {
            DiagnosticLogger.shared.log(
                "AudioRecorder: \(detail) — retry budget spent; waiting for the next device event")
            return
        }
        unusableFormatRetries += 1
        DiagnosticLogger.shared.log("AudioRecorder: \(detail) — retry \(unusableFormatRetries)")
        scheduleReinstallDebounced()
    }

    /// Bounded, delayed rebuild after a pin bind that failed while the device was present
    /// (`kAudioHardwareIllegalOperationError`). Unlike `scheduleFormatRetry`, this can't wait
    /// for a device-list event: a post-wake bind failure produces no such event, so without
    /// this the engine would capture from the fallback device (possibly AirPods) for the rest
    /// of the session. Bounded by `bindRetryCap` and self-cancelling — any later successful
    /// bind resets `consecutiveBindFailures`, and the fire-time guard no-ops if the pin is
    /// already bound or was cleared. Runs on main (startEngine's thread); reinstallTap's own
    /// `isRebuilding` guard is clear by the time this fires.
    private func scheduleBindRetry() {
        guard consecutiveBindFailures <= Self.bindRetryCap else {
            DiagnosticLogger.shared.log(
                "AudioRecorder: pin bind still failing after \(Self.bindRetryCap) retries — staying on system default")
            return
        }
        let attempt = consecutiveBindFailures
        DiagnosticLogger.shared.log(
            "AudioRecorder: pin bind failed (coreaudiod not ready) — scheduling rebuild retry \(attempt) in \(Self.bindRetryDelaySeconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bindRetryDelaySeconds) { [weak self] in
            guard let self = self else { return }
            // A later build may already have bound the pin, or the pin was cleared — nothing to do.
            guard self.effectivePinNow() != nil, self.boundDeviceID == nil else { return }
            self.reinstallTap()
        }
    }

    /// Internal: create and start the audio engine regardless of preBufferEnabled.
    private func startEngine() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startEngine() }
            return
        }
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Apply the microphone pin BEFORE reading the input format — the format below
        // reflects whichever device the input unit is bound to. With no explicit pin the
        // engine binds the BUILT-IN mic (see `effectivePin`), so an AirPods connect can
        // never silently move capture off the microphone the user chose.
        let effectivePin = effectivePinNow()
        if pinnedInputDeviceUID == nil, effectivePin != nil {
            DiagnosticLogger.shared.log(
                "AudioRecorder: no explicit microphone pin — defaulting capture to the built-in mic")
        }
        // The device this engine ends up genuinely bound to, or nil when it is following
        // the system default. Recorded into `boundDevice*` only once the engine actually
        // STARTS: a binding retained for an engine that never came up would compare equal
        // on the next device-list change and suppress the rebuild that would fix it.
        var boundDevice: AudioInputDevice?
        // True when the pinned device WAS present but the CurrentDevice set failed (as
        // opposed to the device being absent). Only this case warrants the timed rebuild
        // retry — an absent device is already recovered by the device-list listener.
        var pinBindFailed = false
        if let uid = effectivePin {
            if let dev = AudioDeviceCatalog.cachedDevice(withUID: uid), let unit = inputNode.audioUnit {
                var deviceID = dev.id
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                DiagnosticLogger.shared.log(
                    "AudioRecorder: pinned capture to \(dev.name)"
                    + (status == noErr ? "" : " FAILED (err \(status)) — using default"))
                // A failed bind leaves the unit on the system default, so no device is
                // retained: nothing of ours is bound to it, and the next device-list
                // change should try again rather than compare against a bind that never
                // happened.
                if status == noErr { boundDevice = dev } else { pinBindFailed = true }
            } else {
                DiagnosticLogger.shared.log(
                    "AudioRecorder: pinned device \(uid) not present — using system default")
            }
        }

        // DEVICE/input scope, not client/output scope (2026-07-22 dead-air outage):
        // after re-binding the input unit (pin to built-in while the system default
        // is AirPods), the client scope keeps reporting the OLD device's format
        // (24 kHz SCO) — a tap installed with it never receives a frame, and every
        // rebuild died the same way (0-sample recordings, all dropped).
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
            scheduleFormatRetry("input format not yet valid")
            return
        }

        // Stale-format guard: cross-check the unit's reported format against the hardware
        // it was just bound to. Applied ONLY when we actually re-bound the unit, which is
        // the case the trap is documented for — after `kAudioOutputUnitProperty_CurrentDevice`
        // the unit can keep answering with the PREVIOUS device's stream description, and a
        // tap installed on it never receives a frame. (System-default engines are left
        // alone: nothing re-bound them, so a cache/unit disagreement there is a race in
        // the check, not in the format.)
        if let dev = boundDevice,
           !Self.isCaptureFormatUsable(
                engineRate: inputFormat.sampleRate, engineChannels: inputFormat.channelCount,
                deviceRate: dev.nominalSampleRate, deviceChannels: dev.inputChannels,
                deviceIsBluetooth: dev.isBluetooth) {
            let detail = "input format \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch"
                + " disagrees with \(dev.name) hardware"
                + " (\(dev.nominalSampleRate)Hz/\(dev.inputChannels)ch) — stale unit format"
            if Self.shouldSkipUnusableFormat(retriesSoFar: unusableFormatRetries) {
                scheduleFormatRetry(detail)
                return
            }
            DiagnosticLogger.shared.log(
                "AudioRecorder: \(detail); accepting it anyway — a suspect engine beats no engine")
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
            unusableFormatRetries = 0
            // Retain the binding and watch the device we are actually on — only after a
            // successful start, so neither a listener nor a comparison baseline can
            // outlive an engine that never existed.
            boundDeviceUID = effectivePin
            boundDeviceID = boundDevice?.id
            // Bind-retry budget (VERIFY round 2, finding 2): a bind that FAILED while the
            // device was present lands in the same (uid, nil-id) state as an absent
            // device, so every device-list event would retry it — likely failing the same
            // way, a rebuild-per-event storm during AirPods churn. Retry up to the cap,
            // then stop letting list events re-trigger; wake/config-reload paths still
            // recover the device later.
            if boundDevice != nil || effectivePin == nil {
                consecutiveBindFailures = 0
            } else {
                consecutiveBindFailures += 1
                // A present-but-unbindable pin ('nope', transient post-wake) leaves the
                // engine on the system default — which after wake may be AirPods, the exact
                // silent wrong-mic capture the built-in pin exists to prevent. Retry the
                // rebuild once coreaudiod has settled; an absent device is left to the
                // device-list listener instead.
                if pinBindFailed { scheduleBindRetry() }
            }
            if let dev = boundDevice { startBoundDeviceWatch(deviceID: dev.id) }
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
            firstBufferArrived = true
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

    static func shouldRecoverMissingFirstBuffer(
        isRecording: Bool,
        scheduledGeneration: Int,
        currentGeneration: Int,
        firstBufferArrived: Bool
    ) -> Bool {
        isRecording && scheduledGeneration == currentGeneration && !firstBufferArrived
    }

    // MARK: - Recording

    func startRecording(to outputURL: URL) throws {
        // Sub-phase timing (2026-08-13 perf audit): "Recording start slow" in AppDelegate
        // pins the delay to this whole call but not to a phase inside it. Real dogfood logs
        // showed 1.2-3.7s stalls here on ~25% of takes with no correlated device-list change,
        // engine teardown, or concurrent build — the four most obvious causes were each
        // checked against real logs and ruled out. Split the phases so the NEXT occurrence
        // is self-diagnosing instead of another round of blind hypotheses.
        let phaseStart = CFAbsoluteTimeGetCurrent()

        // Set up the file BEFORE flipping the flag, so the audio thread doesn't try to
        // write to a nil audioFile. WavWriter (not AVAudioFile): it re-patches the RIFF
        // header every ~5s, so a killed process loses seconds, not the whole recording —
        // AVAudioFile committed sizes only at close, and the 2026-07-25 recovery audit
        // found 94 corpus orphans (one 37 min long) unreadable for exactly that reason.
        // WavWriter creates the file 0o600 itself (no world-readable window).
        let file = try WavWriter(url: outputURL)
        currentOutputURL = outputURL
        let wavWriterDoneAt = CFAbsoluteTimeGetCurrent()

        // Atomically: drain pre-roll, set up file, flip to recording mode
        // This ensures no audio samples are lost between drain and flag flip
        stateLock.lock()
        guard !_isRecording else { stateLock.unlock(); return }

        let preroll = prerollBuffer
        prerollBuffer = []
        pcmSamples = preroll
        audioFile = file
        _isRecording = true
        recordingGeneration += 1
        let guardGeneration = recordingGeneration
        firstBufferArrived = false
        stateLock.unlock()
        writeQueue.async { self.wavWriteFailureLogged = false }
        let stateFlipDoneAt = CFAbsoluteTimeGetCurrent()

        print("AudioRecorder: recording started, pre-roll: \(preroll.count) samples (\(Int(Double(preroll.count) / 16000.0 * 1000))ms)")
        let device = currentCaptureDeviceName() ?? "unknown"
        DiagnosticLogger.shared.log("AudioRecorder: recording started, pre-roll \(preroll.count) samples (\(Int(Double(preroll.count) / 16000.0 * 1000))ms), input device: \(device)")
        let logDoneAt = CFAbsoluteTimeGetCurrent()

        // Write pre-roll to WAV file (async, flag is already set so tap writes new audio too)
        if !preroll.isEmpty {
            writePrerollToFile(preroll)
        }
        let engineWasWarm = audioEngine != nil

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

        let engineCheckDoneAt = CFAbsoluteTimeGetCurrent()
        let totalElapsed = engineCheckDoneAt - phaseStart
        if totalElapsed >= 0.25 {
            DiagnosticLogger.shared.log(String(
                format: "AudioRecorder: slow startRecording — wavWriter=%.2fs stateFlip=%.2fs "
                    + "diagLog=%.2fs engineCheck=%.2fs (engineWasWarm=%@) total=%.2fs",
                wavWriterDoneAt - phaseStart,
                stateFlipDoneAt - wavWriterDoneAt,
                logDoneAt - stateFlipDoneAt,
                engineCheckDoneAt - logDoneAt,
                engineWasWarm ? "true" : "false",
                totalElapsed))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstBufferGuardSeconds) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let recover = Self.shouldRecoverMissingFirstBuffer(
                isRecording: self._isRecording,
                scheduledGeneration: guardGeneration,
                currentGeneration: self.recordingGeneration,
                firstBufferArrived: self.firstBufferArrived)
            self.stateLock.unlock()
            guard recover else { return }
            DiagnosticLogger.shared.log(
                "AudioRecorder: first-buffer guard found no tap buffer after 1.0s; rebuilding tap")
            self.reinstallTap()
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

    /// If the crash-safety wav came out HEADER-ONLY while we captured real audio, rewrite it from
    /// the in-memory buffer. Two deliberate safeguards (adversarial review, 2026-08-14):
    ///   * Guard is header-only (≤64B), NOT "half expected". The observed bug is always exactly the
    ///     44-byte header (audioFile nil for the take's buffers). A file that lost only its second
    ///     half (a mid-take streaming failure) still holds real audio we must NOT clobber.
    ///   * Write to a sibling temp file, then atomically replace. A rewrite that fails (disk full is
    ///     a plausible *correlated* cause) leaves the original file exactly as it was, never worse.
    /// Skips sub-second takes (taps not worth recovering; avoids log noise). s16 mono @ 16 kHz.
    static let archiveRecoveryMinSamples = 16_000            // 1.0s
    static let archiveHeaderOnlyMaxBytes = 64               // a real wav has ≥1 buffer of PCM
    static func recoverArchiveIfHeaderOnly(url: URL, samples: [Float]) {
        guard samples.count >= archiveRecoveryMinSamples else { return }
        let byteSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteSize <= archiveHeaderOnlyMaxBytes else { return }
        DiagnosticLogger.shared.log(
            "AudioRecorder: archive wav is header-only (\(byteSize)B) for \(samples.count) samples "
            + "— rewriting from memory")
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).recover-\(UUID().uuidString).tmp")
        do {
            let writer = try WavWriter(url: tmp)
            try writer.append(samples)
            writer.close()
            // Atomic replace: the original is only removed once the temp is fully written.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            DiagnosticLogger.shared.log("AudioRecorder: archive rewrite OK (\(samples.count) samples)")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            DiagnosticLogger.shared.log(
                "AudioRecorder: archive rewrite FAILED — \(error.localizedDescription)")
        }
    }

    func stopRecording() -> (url: URL, samples: [Float])? {
        // Atomically flip back to pre-roll mode
        stateLock.lock()
        guard _isRecording else { stateLock.unlock(); return nil }
        _isRecording = false
        recordingGeneration += 1
        stateLock.unlock()

        var samples: [Float] = []
        writeQueue.sync {
            self.audioFile?.close()   // final header patch — the wav is valid from here
            self.audioFile = nil
            samples = self.pcmSamples
            self.pcmSamples = []
            // Archive-integrity backstop (2026-08-14): 13 real dictations were found archived as
            // 44-byte header-only wavs — correct transcript, no audio — because the crash-safety
            // streaming write was skipped (audioFile nil for the take's buffers) while the
            // in-memory buffer filled normally. No write error was ever thrown, so it was silent.
            // We hold the full samples here, so if the on-disk wav came out header-only, rewrite it
            // from memory. Still on writeQueue (WavWriter's single-queue contract); audioFile is nil.
            if let url = self.currentOutputURL {
                AudioRecorder.recoverArchiveIfHeaderOnly(url: url, samples: samples)
            }
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
