// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
// ai-suggestion:unverified · session:unknown · 2026-10-02
import Foundation

/// Dictation left the chosen headset for the Mac's own microphone.
struct CaptureFallback: Equatable {
    typealias Reason = HeadsetFallbackReason
    let uid: String
    let name: String
    let fallbackName: String
    let reason: Reason
}

/// Control state and sample delivery are serial; hardware workers never run here.
/// sync() is safe for recording boundaries because this queue does no driver I/O.
final class MicrophoneCaptureCoordinator {
    let queue = DispatchQueue(label: "com.speakfree.capturerouting", qos: .userInitiated)
    private let factory: () -> DeviceCapturing
    private let refresh: () -> Void
    private let now: () -> Double
    private let onSamples: ([Float], String) -> Void
    private let onStatus: (String) -> Void
    private var devices: [AudioInputDevice] = []
    private var systemDefault: AudioInputDevice?
    private var pin: String?
    /// UID of the headset "Stay on" routes dictation to; nil when the mode is off or paused.
    private var stayOn: String?
    /// Reports the Stay-on headset's health: true after sustained audio, false once its
    /// start attempts are exhausted. Called on `queue`; the owner hops to main.
    var onHeadsetHealth: ((String, Bool) -> Void)?
    private var reportedHealthy: Set<UUID> = []
    private var prelisten = true
    private var recording = false
    private var enabled = false
    private var suspended = false
    private var lastRecordingEnd = -Double.infinity
    private var base: AudioInputDevice?
    private var preferred: AudioInputDevice?
    private var timeline = CaptureTimeline()
    private var timer: DispatchSourceTimer?
    private var status = ""
    private var sessions: [String: Entry] = [:]
    private var retries: [String: Int] = [:]
    private var retryAfter: [String: Double] = [:]
    private var lastSource = "Microphone connecting"
    static let idleSeconds: Double = 30

    /// Called on `queue` when dictation leaves the chosen headset for the Mac's own microphone
    /// (static, a failure mid-take, or not ready at the start). The owner shows a notice.
    var onFallback: ((CaptureFallback) -> Void)?
    /// Called on `queue` inside a take: drop everything from sample `index` of the take on and
    /// append `samples` in its place (the headset stretch, replaced by the built-in audio).
    private let onReplace: (Int, [Float], String) -> Void
    /// Take bookkeeping (queue only). Indices count samples of the take including pre-roll.
    private var takeEmitted = 0
    private struct CaptureIdentity: Equatable {
        let uid: String
        let generation: UUID
    }
    private var secondarySegment: (index: Int, time: Double, identity: CaptureIdentity)?
    private var headsetEvidenceIdentity: CaptureIdentity?
    /// Last contiguous source run, including pre-listening before a take begins.
    private var latestSecondaryRun: (time: Double, identity: CaptureIdentity)?
    /// Headsets judged broken during this take; not reopened until it ends.
    private var quarantined: Set<String> = []
    private var noticedThisTake: Set<String> = []
    /// Consecutive takes in which a headset was judged static (reset by a take it served well).
    private var staticStrikes: [String: Int] = [:]
    /// Set while every stream is closed at once (sleep, wake, restart after a failed take):
    /// the Mac's microphone closes too, so "switched to it" would be wrong.
    private var quietRemoval = false
    /// 100 ms window shapes: the headset's during the take, the base's for the last 30 s.
    private var meters: [String: CaptureWindowMeter] = [:]
    private var headsetWindows: [CaptureWindowStats] = []
    /// Earliest window of the current consecutive run of static two-second stretches.
    /// Advanced once per new headset window, never rescanned on late base callbacks.
    private var staticRunStartWindow: Int?
    private var baseWindows: [CaptureWindowStats] = []
    static let baseWindowHistory = 300

    private struct Entry {
        let generation: UUID
        let device: AudioInputDevice
        let session: DeviceCapturing
        let started: Double
        var lastPacket: Double?
        var zeroFrames = 0
        var validFrames = 0
        var previousValidPacket: (start: Double, duration: Double)?
    }

    init(factory: @escaping () -> DeviceCapturing = { DeviceAudioSession() },
         samples: @escaping ([Float], String) -> Void, status: @escaping (String) -> Void,
         replace: @escaping (Int, [Float], String) -> Void = { _, _, _ in },
         refresh: @escaping () -> Void = { AudioDeviceCatalog.refreshNow() },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.factory = factory
        self.refresh = refresh
        self.now = now
        self.onSamples = samples
        self.onStatus = status
        self.onReplace = replace
    }

    /// The 3.5 mm headphone-jack input reports built-in transport. It must never win the
    /// "built-in" slot over the Mac's own microphone just by list order.
    static func isHeadphoneJack(_ device: AudioInputDevice) -> Bool {
        device.isBuiltIn && device.uid.localizedCaseInsensitiveContains("Headphone")
    }

    /// Routing (2026-09-24, "Stay on" redesign): with no pin, dictation uses this Mac's own
    /// microphone (built-in, else a wired mic). Bluetooth headsets are never chosen
    /// automatically; they are used only through an explicit pin or `stayOn`, the UID of
    /// the headset the person chose "Stay on <name>" for.
    private static func baseDevice(devices: [AudioInputDevice], systemDefault: AudioInputDevice?,
                                   pin: String?) -> AudioInputDevice? {
        if let d = devices.first(where: { $0.isBuiltIn && !isHeadphoneJack($0) }) { return d }
        if let d = devices.first(where: { $0.isBuiltIn }) { return d }
        if let d = devices.first(where: { $0.uid == pin && !$0.isBluetooth }) { return d }
        if let def = systemDefault,
           let d = devices.first(where: { $0.uid == def.uid && !$0.isBluetooth && !$0.isVirtual }) { return d }
        if let d = devices.first(where: { !$0.isBluetooth && !$0.isVirtual }) { return d }
        if let def = systemDefault, let d = devices.first(where: { $0.uid == def.uid }) { return d }
        return devices.first
    }

    static func routes(devices: [AudioInputDevice], systemDefault: AudioInputDevice?, pin: String?,
                       stayOn: String? = nil)
        -> (base: AudioInputDevice?, preferred: AudioInputDevice?) {
        let base = baseDevice(devices: devices, systemDefault: systemDefault, pin: pin)
        let preferred: AudioInputDevice?
        if let stayOn, let headset = devices.first(where: { $0.uid == stayOn }) { preferred = headset }
        else if let pin { preferred = devices.first { $0.uid == pin } ?? base }
        else { preferred = base }
        return (base, preferred)
    }

    func configure(devices: [AudioInputDevice], systemDefault: AudioInputDevice?, pin: String?, prelisten: Bool,
                   stayOn: String? = nil) {
        queue.async {
            let oldRoutes = Self.routes(devices: self.devices, systemDefault: self.systemDefault, pin: self.pin, stayOn: self.stayOn)
            let newRoutes = Self.routes(devices: devices, systemDefault: systemDefault, pin: pin, stayOn: stayOn)
            let changed = oldRoutes.base != newRoutes.base || oldRoutes.preferred != newRoutes.preferred
                || self.pin != pin || self.stayOn != stayOn
            self.devices = devices; self.systemDefault = systemDefault
            self.pin = pin; self.prelisten = prelisten; self.stayOn = stayOn
            if changed { self.retries = [:]; self.retryAfter = [:] }
            self.reconcile()
        }
    }

    func start() {
        queue.async {
            guard !self.enabled else { return }
            self.enabled = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkHealth() }
            self.timer = timer; timer.resume()
            self.reconcile()
        }
    }

    func stop() {
        queue.async {
            self.enabled = false
            self.timer?.cancel(); self.timer = nil
            for entry in self.sessions.values { entry.session.stop() }
            self.sessions = [:]; self.timeline.reset(); self.secondarySegment = nil
            self.latestSecondaryRun = nil
        }
    }

    /// Called inside the short, driver-free recording boundary on queue.
    /// `prerollSamples`: samples the recorder already put at the start of the take.
    func setRecording(_ value: Bool, prerollSamples: Int = 0) {
        dispatchPrecondition(condition: .onQueue(queue))
        recording = value
        if !value { lastRecordingEnd = now() }
        // A take the headset served for two judged seconds without being found static clears
        // its strikes; a short or unjudged take proves nothing either way.
        if !value, let preferred, preferred.uid != base?.uid, !quarantined.contains(preferred.uid),
           headsetWindows.count >= CaptureStaticJudge.minimumWindows,
           !CaptureStaticJudge.isStatic(headsetWindows) {
            staticStrikes[preferred.uid] = nil
        }
        resetHeadsetEvidence()
        meters = meters.filter { $0.key == base?.uid }
        noticedThisTake = []
        if value {
            retries = [:]; retryAfter = [:]
            let origin = (timeline.cursor ?? now()) - Double(prerollSamples) / 16_000
            takeEmitted = prerollSamples
            if timeline.prefersSecondary, let preferred, let entry = sessions[preferred.uid],
               let run = latestSecondaryRun {
                let identity = CaptureIdentity(uid: preferred.uid, generation: entry.generation)
                let start = max(origin, run.time)
                if run.identity == identity, let count = timeline.committedSamples(since: start), count <= prerollSamples {
                    secondarySegment = (prerollSamples - count, start, identity)
                    headsetEvidenceIdentity = identity
                }
            }
            timeline.keepFrom = origin - 0.5
            if let preferred, preferred.uid != base?.uid, preferred.uid == stayOn,
               sessions[preferred.uid]?.lastPacket == nil {
                // Stay on holds the headset open, so it should be ready. It is not.
                announceFallback(preferred, reason: .notReady)
            }
        } else {
            takeEmitted = 0; secondarySegment = nil
            timeline.keepFrom = nil
            quarantined = []
        }
        reconcile()
    }

    func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        reconsiderHeadset(allowShortTake: true)
        emitBase(timeline.flush())
    }

    func recover() {
        queue.async {
            self.retries = [:]; self.retryAfter = [:]
            self.checkHealth()
        }
    }

    /// A failed take is stronger evidence than recent callbacks: a driver can
    /// keep supplying perfectly timed buffers containing only zeros.
    func recoverFailedCapture() {
        queue.async {
            guard self.enabled, !self.suspended else { return }
            DiagnosticLogger.shared.log("Capture: restarting streams after failed recording")
            self.quietRemoval = true; for uid in Array(self.sessions.keys) { self.remove(uid) }; self.quietRemoval = false
            self.timeline.reset(); self.secondarySegment = nil
            self.retries = [:]; self.retryAfter = [:]
            self.refresh()
            self.reconcile()
        }
    }

    func suspend() {
        queue.async {
            self.suspended = true
            self.quietRemoval = true; for uid in Array(self.sessions.keys) { self.remove(uid) }; self.quietRemoval = false
            self.timeline.reset(); self.secondarySegment = nil
        }
    }

    func resume() {
        queue.async {
            self.suspended = false
            self.quietRemoval = true; for uid in Array(self.sessions.keys) { self.remove(uid) }; self.quietRemoval = false
            self.timeline.reset(); self.secondarySegment = nil; self.retries = [:]; self.retryAfter = [:]
            self.reconcile()
        }
    }

    private func reconcile() {
        guard enabled, !suspended else { return }
        let now = self.now()
        let routes = Self.routes(devices: devices, systemDefault: systemDefault, pin: pin, stayOn: stayOn)
        let oldBase = base?.uid, oldPreferred = preferred?.uid
        base = routes.base; preferred = routes.preferred
        if oldPreferred != preferred?.uid {
            resetHeadsetEvidence()
            latestSecondaryRun = nil
            emitBase(timeline.useBase())
        }
        if oldBase != base?.uid {
            timeline.reset(); baseWindows = []
            latestSecondaryRun = nil
            if let oldBase { meters[oldBase] = nil }
            secondarySegment = nil // the old base's history is gone; nothing to rewind to
        }
        var desired: [AudioInputDevice] = []
        // A Bluetooth base (a Mac whose only microphone is a headset) is opened per
        // dictation, never held for pre-listening: holding it would keep the headset in
        // call-quality audio all day without anyone choosing that.
        if let base, recording || base.uid == stayOn
            || (prelisten && (!base.isBluetooth || now - lastRecordingEnd < Self.idleSeconds)) {
            desired.append(base)
        }
        // While Stay on is on, its headset is held open between takes: that is the mode's
        // promise (no 1 to 8 second cold start per take), and its cost is stated in the menu.
        let holdHeadset = preferred != nil && preferred?.uid == stayOn
        if let preferred, preferred.uid != base?.uid, !quarantined.contains(preferred.uid),
           recording || holdHeadset || (prelisten && (!preferred.isBluetooth || now - lastRecordingEnd < Self.idleSeconds)) {
            desired.append(preferred)
        }
        for (uid, entry) in sessions {
            if !desired.contains(where: { $0.uid == uid && $0.id == entry.device.id && $0.nominalSampleRate == entry.device.nominalSampleRate }) {
                remove(uid)
            }
        }
        for device in desired where sessions[device.uid] == nil {
            guard (retries[device.uid] ?? 0) < 4, now >= (retryAfter[device.uid] ?? 0) else { continue }
            let generation = UUID(), session = factory()
            sessions[device.uid] = Entry(generation: generation, device: device, session: session, started: now)
            session.start(device: device, packet: { [weak self] packet in
                self?.queue.async { [weak self] in self?.receive(packet, uid: device.uid, generation: generation) }
            }, failure: { [weak self] reason in
                self?.queue.async { [weak self] in self?.failed(device.uid, generation: generation, reason: reason) }
            })
        }
        updateStatus()
    }

    private func remove(_ uid: String) {
        guard let entry = sessions.removeValue(forKey: uid) else { return }
        if headsetEvidenceIdentity == CaptureIdentity(uid: uid, generation: entry.generation) {
            resetHeadsetEvidence()
        }
        if latestSecondaryRun?.identity == CaptureIdentity(uid: uid, generation: entry.generation) {
            latestSecondaryRun = nil
        }
        reportedHealthy.remove(entry.generation)
        meters[uid] = nil
        // A headset that was supplying this take and is closed for any other reason (it left,
        // the catalog changed its id or rate, sleep): say so. Static says so where it is found.
        // Not when the person just chose another mic (the pin or Stay on no longer names it).
        if recording, !quietRemoval, uid != base?.uid, uid == stayOn || uid == pin, entry.lastPacket != nil, !quarantined.contains(uid) {
            announceFallback(entry.device, reason: .stopped)
        }
        entry.session.stop()
        if uid == preferred?.uid { emitBase(timeline.useBase()) }
    }

    private func receive(_ packet: CapturePacket, uid: String, generation: UUID) {
        guard var entry = sessions[uid], entry.generation == generation, enabled else { return }
        guard !packet.samples.isEmpty else { return }
        guard packet.start.isFinite, packet.samples.allSatisfy({ $0.isFinite }) else {
            failed(uid, generation: generation, reason: "Microphone delivered nonfinite audio or timestamps")
            return
        }
        let digitalSilence = packet.samples.allSatisfy { $0 == 0 }
        entry.zeroFrames = digitalSilence ? entry.zeroFrames + packet.samples.count : 0
        if entry.zeroFrames >= 16_000 {
            sessions[uid] = entry
            failed(uid, generation: generation, reason: "Microphone delivered only digital zeros for one second")
            return
        }
        if digitalSilence {
            entry.validFrames = 0
            entry.previousValidPacket = nil
        } else {
            if let previous = entry.previousValidPacket {
                let elapsed = packet.start - previous.start
                if elapsed <= 0 || abs(elapsed - previous.duration) > CaptureClockGuard.continuityTolerance(duration: previous.duration) {
                    entry.validFrames = 0
                }
            }
            entry.validFrames = min(80_001, entry.validFrames + packet.samples.count)
            entry.previousValidPacket = (packet.start, Double(packet.samples.count) / 16_000)
            entry.lastPacket = now()
        }
        sessions[uid] = entry
        // Five seconds of contiguous, finite, nonzero transport, not time since startup.
        // Quiet input qualifies: this is transport readiness, not proof of speech quality.
        if entry.validFrames > 80_000 {
            retries[uid] = 0
            if uid == stayOn, !reportedHealthy.contains(generation), staticStrikes[uid, default: 0] == 0 {
                reportedHealthy.insert(generation)
                onHeadsetHealth?(uid, true)
            }
        }
        // Never switch away from a working base microphone to a zero-filled
        // Bluetooth stream during startup or a mute/route failure.
        if digitalSilence && uid != base?.uid {
            emitBase(timeline.useBase())
            return
        }
        let isBase = uid == base?.uid
        let identity = CaptureIdentity(uid: uid, generation: generation)
        if recording, !isBase, headsetEvidenceIdentity != identity {
            resetHeadsetEvidence()
            headsetEvidenceIdentity = identity
        }
        let cursorBefore = timeline.cursor
        let samples = isBase ? timeline.receiveBase(packet) : timeline.receiveSecondary(packet)
        if !isBase, !samples.isEmpty {
            // Where the headset's own audio begins in the take (after any built-in gap fill).
            // A first headset packet that lies wholly behind the cursor adds nothing; the
            // segment starts with the first one that does.
            let headsetStart = max(packet.start, cursorBefore ?? packet.start)
            let headsetCount = min(samples.count, max(0, Int(((packet.end - headsetStart) * 16_000).rounded())))
            if headsetCount > 0 {
                if latestSecondaryRun?.identity != identity || samples.count > headsetCount {
                    latestSecondaryRun = (headsetStart, identity)
                }
                if recording, secondarySegment == nil {
                    secondarySegment = (takeEmitted + samples.count - headsetCount, headsetStart, identity)
                }
            }
        }
        if isBase { emitBase(samples) }
        else { emit(samples, source: entry.device.name) }
        judge(packet, uid: uid, isBase: isBase)
        updateStatus()
    }

    private func emit(_ samples: [Float], source: String) {
        guard !samples.isEmpty else { return }
        lastSource = source
        if recording { takeEmitted += samples.count }
        onSamples(samples, source)
    }

    private func emitBase(_ samples: [Float]) {
        if !samples.isEmpty { latestSecondaryRun = nil }
        emit(samples, source: base?.name ?? lastSource)
    }

    /// The chosen headset is judged against the Mac's own microphone over the same two
    /// seconds: static on the headset while the Mac heard a voice means the headset is not
    /// hearing the person. Only inside a take, only for a headset that is not the base.
    private func judge(_ packet: CapturePacket, uid: String, isBase: Bool) {
        guard isBase || (recording && uid == preferred?.uid) else { return }
        let windows = meters[uid, default: CaptureWindowMeter()].add(packet.samples, start: packet.start)
        if isBase {
            baseWindows += windows
            if baseWindows.count > Self.baseWindowHistory { baseWindows.removeFirst(baseWindows.count - Self.baseWindowHistory) }
            // The workers can deliver in either order. Even a partial window can finish the
            // replacement history after the headset's final callback.
            reconsiderHeadset()
            return
        }
        guard !windows.isEmpty else { return }
        let oldCount = headsetWindows.count
        headsetWindows += windows
        updateStaticRun(after: oldCount)
        reconsiderHeadset()
    }

    /// Reconsider the most recent headset stretch when either stream advances and at stop.
    /// Only stop may judge less than two seconds (from one second, as before).
    private func reconsiderHeadset(allowShortTake: Bool = false) {
        let minimum = allowShortTake ? CaptureStaticJudge.wholeTakeMinimumWindows : CaptureStaticJudge.minimumWindows
        guard recording, let preferred, preferred.uid != base?.uid, !quarantined.contains(preferred.uid),
              let entry = sessions[preferred.uid],
              headsetEvidenceIdentity == CaptureIdentity(uid: preferred.uid, generation: entry.generation),
              headsetWindows.count >= minimum else { return }
        let recent = Array(headsetWindows.suffix(CaptureStaticJudge.minimumWindows))
        switchIfStatic(preferred.uid, recent, minimumWindows: minimum)
    }

    private func switchIfStatic(_ uid: String, _ recent: [CaptureWindowStats], minimumWindows: Int) {
        guard CaptureStaticJudge.isStatic(recent, minimumWindows: minimumWindows),
              let first = recent.first, let last = recent.last, let base, let entry = sessions[uid] else { return }
        let span = baseWindows.filter { $0.start >= first.start - 0.25 && $0.start <= last.start + 0.25 }
        guard CaptureStaticJudge.isSpeech(span, floorRMS: CaptureStaticJudge.quietLevel(baseWindows)) else { return }
        if let segment = secondarySegment {
            guard segment.identity == CaptureIdentity(uid: uid, generation: entry.generation) else { return }
            // Replace only the static run (good headset audio before it stays), and never
            // reach back past the built-in history still held.
            let from = max(segment.time, staticRunStart(), timeline.oldestHeld ?? segment.time)
            guard let suffixCount = timeline.committedSamples(since: from) else { return }
            let index = takeEmitted - suffixCount
            guard index >= segment.index, index <= takeEmitted else { return }
            // Check packet bounds before materializing audio. A base gap or lag may persist
            // for the whole take; repeatedly copying its history would stall this queue.
            // At stop we deliberately preserve the original take if coverage is incomplete:
            // static is a statistical judgment, not permission to truncate possible words.
            guard let committedEnd = timeline.cursor,
                  timeline.canRewind(to: from, preservingThrough: committedEnd) else { return }
            let replacement = timeline.rewind(to: from)
            takeEmitted = index + replacement.count
            lastSource = base.name
            onReplace(index, replacement, base.name)
        }
        DiagnosticLogger.shared.log("Capture switch: \(entry.device.name) sounded like static (\(CaptureStaticJudge.describe(recent))) "
            + "while \(base.name) heard a voice; the take continues on \(base.name)")
        quarantined.insert(uid)
        secondarySegment = nil
        remove(uid)
        announceFallback(entry.device, reason: .staticNoise)
        staticStrikes[uid, default: 0] += 1
        if uid == stayOn, staticStrikes[uid, default: 0] >= Self.staticStrikesBeforeUnhealthy {
            // Static take after static take: tell Stay on the headset is not working, so it
            // backs off on its retry schedule instead of costing two seconds of every take.
            onHeadsetHealth?(uid, false)
        }
        updateStatus()
    }

    static let staticStrikesBeforeUnhealthy = 2

    private func resetHeadsetEvidence() {
        if let identity = headsetEvidenceIdentity { meters[identity.uid] = nil }
        headsetWindows = []
        staticRunStartWindow = nil
        headsetEvidenceIdentity = nil
        secondarySegment = nil
    }

    /// Host time where the headset's current static began: the earliest window from which
    /// every two-second stretch up to now is judged static. Static since the first judged
    /// window returns -infinity: the whole headset stretch goes, pre-roll included.
    private func staticRunStart() -> Double {
        let n = CaptureStaticJudge.minimumWindows
        guard headsetWindows.count >= n else { return -.infinity }
        let k = staticRunStartWindow ?? headsetWindows.count - n
        return k == 0 ? -.infinity : headsetWindows[k].start
    }

    private func updateStaticRun(after oldCount: Int) {
        let n = CaptureStaticJudge.minimumWindows
        guard headsetWindows.count >= n else { return }
        for k in max(0, oldCount - n + 1)...(headsetWindows.count - n) {
            if CaptureStaticJudge.isStatic(Array(headsetWindows[k..<(k + n)])) {
                if staticRunStartWindow == nil { staticRunStartWindow = k }
            } else {
                staticRunStartWindow = nil
            }
        }
    }

    private func announceFallback(_ device: AudioInputDevice, reason: CaptureFallback.Reason) {
        let key = "\(device.uid)|\(reason)"
        guard let base, base.uid != device.uid, !noticedThisTake.contains(key) else { return }
        noticedThisTake.insert(key)
        switch reason {
        case .staticNoise: break // logged with its measurements where it is decided
        case .stopped:
            DiagnosticLogger.shared.log("Capture switch: \(device.name) stopped sending audio; the take continues on \(base.name)")
        case .notReady:
            DiagnosticLogger.shared.log("Capture switch: \(device.name) had no verified audio at the start; using \(base.name)")
        }
        onFallback?(CaptureFallback(uid: device.uid, name: device.name, fallbackName: base.name, reason: reason))
    }

    private func failed(_ uid: String, generation: UUID, reason: String) {
        guard sessions[uid]?.generation == generation else { return }
        let entry = sessions[uid]!
        DiagnosticLogger.shared.log("Capture: \(entry.device.name) failed: \(reason); preserving fallback")
        if recording, uid == preferred?.uid, uid != base?.uid, entry.lastPacket != nil {
            announceFallback(entry.device, reason: .stopped)
        }
        remove(uid)
        refresh()
        let count = (retries[uid] ?? 0) + 1
        retries[uid] = count
        retryAfter[uid] = now() + min(4, Double(count) * 0.5)
        if uid == stayOn, count >= 4 { onHeadsetHealth?(uid, false) }
        updateStatus()
    }

    private func checkHealth() {
        guard enabled, !suspended else { return }
        let now = self.now()
        for (uid, entry) in sessions {
            let age = now - (entry.lastPacket ?? entry.started)
            let allowance = entry.lastPacket == nil ? 5.0 : 1.5
            if age > allowance { failed(uid, generation: entry.generation, reason: "No valid audio for \(String(format: "%.1f", age)) seconds") }
        }
        reconcile()
    }

    private func updateStatus() {
        let message: String
        if !prelisten && !recording { message = "Pre-listening off" }
        else if sessions[base?.uid ?? ""]?.lastPacket == nil && sessions[preferred?.uid ?? ""]?.lastPacket == nil {
            if sessions.isEmpty && retries.values.contains(where: { $0 >= 4 }) {
                message = "Microphone unavailable — no valid audio; retry when starting dictation"
            } else {
                message = recording ? "Microphone connecting — audio not ready yet" : "Starting pre-listening…"
            }
        }
        else if let pin, !devices.contains(where: { $0.uid == pin }) {
            message = "Selected microphone disconnected — using \(base?.name ?? "available microphone")"
        }
        else if let preferred, preferred.uid != base?.uid, quarantined.contains(preferred.uid) {
            message = "Using \(base?.name ?? "fallback microphone") · \(preferred.name) sounded like static"
        }
        else if let preferred, preferred.uid != base?.uid {
            if sessions[preferred.uid]?.lastPacket != nil {
                if sessions[base?.uid ?? ""]?.lastPacket != nil {
                    message = "Using \(preferred.name) · pre-listening protected by \(base?.name ?? "fallback microphone")"
                } else {
                    message = "Using \(preferred.name) · backup microphone unavailable"
                }
            } else if recording {
                message = "Using \(base?.name ?? "fallback microphone") while \(preferred.name) connects…"
            } else {
                message = "Pre-listening: \(base?.name ?? "microphone") · dictation: \(preferred.name)"
            }
        } else { message = "Pre-listening: \(base?.name ?? "waiting for microphone")" }
        guard message != status else { return }
        status = message
        DiagnosticLogger.shared.log("Capture route: \(message)")
        onStatus(message)
    }
}
