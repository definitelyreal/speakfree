// ai-suggestion:unverified · 2026-09-24
import Foundation
import IOKit.ps

/// A notice the Stay-on system wants shown under the menu-bar icon.
public enum StayOnNotice: Equatable {
    /// A headset with a mic connected. `style` is full the first times, then compact.
    case connected(uid: String, name: String, usingName: String, style: HeadsetNoticeStyle, offerDontShowAgain: Bool)
    /// A take was lost in a noisy room and speakfree switched to the headset.
    case switched(uid: String, name: String, startedAt: Date)
    /// Same, but music is playing on the headset, so it asks instead.
    case offer(uid: String, name: String)
    /// Lost take and no headset with a mic: advice only.
    case advise
    /// An automatic switch (made because it was hard to hear you) ran out: offer more time.
    case endedAfterAutomaticSwitch(uid: String, name: String)
    /// Capture left the chosen headset for this Mac's microphone (2026-09-25: "It should flag a
    /// notice when it switches").
    case fellBack(uid: String, name: String, usingName: String, reason: HeadsetFallbackReason)
}

/// Why capture left the chosen headset.
public enum HeadsetFallbackReason: Equatable {
    /// The headset delivered static while this Mac's microphone heard a voice.
    case staticNoise
    /// The headset stopped delivering audio in the middle of a take.
    case stopped
    /// Stay on's headset had no verified audio when the take started.
    case notReady
}

/// What survives relaunches: the mode itself plus the notice history.
struct StayOnStore: Codable, Equatable {
    var mode = StayOnMode()
    var notices: [String: HeadsetNoticeRecord] = [:]
    var lastAdvice: Date?
    /// When the person last undid an automatic switch; for a day after, speakfree asks instead.
    var lastUndo: Date?
}

/// Owns the one StayOnMode in the running app. Main thread only. Feeds it time, device,
/// sleep, power and health events; persists it to `stay-on.json` in the config folder
/// (never config.json, so a Settings save cannot overwrite it); tells the app to reroute
/// capture and redraw the menu whenever the routed headset or status changes.
final class StayOnController {
    private(set) var store: StayOnStore
    var mode: StayOnMode { store.mode }
    private let fileURL: URL
    private let now: () -> Date
    private let bootID: String?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// True while a take is being recorded.
    var isRecording: () -> Bool = { false }
    /// Name of the mic dictation uses when Stay on is off ("MacBook Pro Microphone").
    var currentMicName: () -> String = { "this Mac's microphone" }
    /// False when a mic the person pinned (other than the built-in) would be switched away from.
    var autoSwitchAllowed: () -> Bool = { true }
    /// Reads what is playing on a headset (CoreAudio in the app, scripted in tests).
    var playbackProbe: (AudioInputDevice, @escaping (HeadsetPlayback) -> Void) -> Void = { device, done in
        HeadsetActivityProbe.playback(on: device, completion: done)
    }
    var onChange: (() -> Void)?
    var presentNotice: ((StayOnNotice) -> Void)?
    /// Last known playback per headset UID, refreshed while Stay on is on (menu third line).
    private(set) var playback: [String: HeadsetPlayback] = [:]

    private var headsets: [ConnectedHeadset] = []
    private var connectGeneration: [String: Int] = [:]
    private var hasSeenDevices = false
    /// Base UIDs and names of headsets that have offered a mic during this run.
    private var micSeen: Set<String> = []
    private var timer: Timer?

    static let tickInterval: TimeInterval = 15

    init(directory: URL, now: @escaping () -> Date = Date.init, bootID: String? = StayOnController.currentBootID(),
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.fileURL = directory.appendingPathComponent("stay-on.json")
        self.now = now
        self.bootID = bootID
        self.schedule = schedule
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let loaded = try? decoder.decode(StayOnStore.self, from: data) {
            store = loaded
        } else {
            store = StayOnStore()
        }
        if let ended = store.mode.launched(bootID: bootID, now: now()) {
            DiagnosticLogger.shared.log("Stay on: ended at launch (\(ended.reason.rawValue))")
        }
        save()
    }

    // MARK: - Lifecycle

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: - Commands

    func start(uid: String, name: String, duration: StayOnDuration, automatic: Bool = false) {
        let before = store.mode
        store.mode.start(deviceUID: uid, deviceName: name, duration: duration, now: now(), bootID: bootID, automatic: automatic)
        if !automatic { HeadsetNoticePolicy.used(&store.notices[uid, default: HeadsetNoticeRecord()], now: now()) }
        store.mode.devicesChanged(presentUIDs: Set(headsets.compactMap { $0.input?.uid }), now: now())
        DiagnosticLogger.shared.log("Stay on: \(name) \(duration.rawValue)\(automatic ? " (automatic)" : "")")
        changed(from: before)
        refreshPlayback()
    }

    func end(_ reason: StayOnEndReason) {
        let before = store.mode
        guard let ended = store.mode.end(reason, now: now()) else { return }
        DiagnosticLogger.shared.log("Stay on: ended (\(ended.reason.rawValue))")
        changed(from: before)
    }

    /// Undo after an automatic switch. Only undoes that same session, never a newer one,
    /// and remembers it so the next lost take asks instead of switching again.
    func undo(uid: String, startedAt: Date) {
        guard let s = store.mode.session, s.deviceUID == uid, s.startedAt == startedAt, s.automatic else { return }
        store.lastUndo = now()
        end(.undone)
    }

    /// Settings writes the current pin back on appear; only a different value is a choice.
    static func isNewSelection(_ value: String, current: String?) -> Bool { value != (current ?? "") }

    func dismissConnectNoticeForever(uid: String) {
        store.notices[uid, default: HeadsetNoticeRecord()].dismissedForever = true
        save()
    }

    // MARK: - Events

    func tick() {
        let before = store.mode
        let wasAutomatic = store.mode.session?.automatic ?? false
        let ended = store.mode.tick(now: now(), recording: isRecording())
        if let ended { handleUnexpectedEnd(ended, wasAutomatic: wasAutomatic) }
        changed(from: before)
        if store.mode.isActive { refreshPlayback() }
    }

    func devicesChanged(inputs: [AudioInputDevice], bluetoothOutputs: [AudioOutputDevice]) {
        let before = store.mode
        let previousWithMic = Set(headsets.filter(\.hasMic).map(\.uid))
        let all = HeadsetInventory.headsets(inputs: inputs, bluetoothOutputs: bluetoothOutputs)
        for h in all where h.hasMic { micSeen.insert(HeadsetInventory.baseUID(h.uid)); micSeen.insert(h.name) }
        // A Bluetooth speaker or mic-less headphones never offered a mic: leave them out
        // rather than claim "macOS is not offering its mic".
        let stayOnName = store.mode.session?.deviceName
        let stayOnBase = store.mode.session.map { HeadsetInventory.baseUID($0.deviceUID) }
        headsets = all.filter { h in
            h.hasMic || micSeen.contains(HeadsetInventory.baseUID(h.uid)) || micSeen.contains(h.name)
                || h.name == stayOnName || HeadsetInventory.baseUID(h.uid) == stayOnBase
        }
        let present = Set(inputs.map(\.uid))
        store.mode.devicesChanged(presentUIDs: present, now: now())
        if let s = store.mode.session, let device = inputs.first(where: { $0.uid == s.deviceUID }) {
            store.mode.deviceRenamed(to: device.name)
        }
        changed(from: before)
        // Headsets already connected when speakfree starts did not just connect.
        guard hasSeenDevices else { hasSeenDevices = true; return }
        for headset in headsets where headset.hasMic && !previousWithMic.contains(headset.uid) {
            scheduleConnectNotice(uid: headset.uid)
        }
    }

    func sleepBegan() { mutate { $0.sleepBegan(now: now()) } }

    func sleepEnded() {
        let before = store.mode
        if let ended = store.mode.sleepEnded(now: now()) { handleUnexpectedEnd(ended, wasAutomatic: false) }
        changed(from: before)
    }

    func headsetHealth(uid: String, healthy: Bool) {
        guard store.mode.isActive(for: uid) else { return }
        let before = store.mode
        if healthy { store.mode.headsetHealthy() } else {
            store.mode.headsetFailed(now: now())
            DiagnosticLogger.shared.log("Stay on: headset mic not responding; retrying on schedule")
        }
        changed(from: before)
    }

    /// After every finished take: the lost-take trigger, and "switch" or "offer".
    /// `noiseFloorDBFS` comes from `LostTakeDetector.noiseFloorDBFS`, computed off main.
    func noteFinishedTake(durationSeconds duration: Double, noiseFloorDBFS: Double?, transcriptChars: Int,
                          recordedOnHeadset: Bool) {
        guard !recordedOnHeadset, !store.mode.isActive, let floor = noiseFloorDBFS,
              LostTakeDetector.isLost(durationSeconds: duration, noiseFloorDBFS: floor, transcriptChars: transcriptChars)
        else { return }
        DiagnosticLogger.shared.log(String(format: "Stay on: lost take (%.1fs, floor %.1f dBFS, %d chars)", duration, floor, transcriptChars))
        let candidate = headsets.first(where: { $0.hasMic })
        guard let headset = candidate, let input = headset.input else {
            respond(.advise, headset: nil)
            return
        }
        playbackProbe(input) { [weak self] playback in
            self?.playback[headset.uid] = playback
            self?.respond(playback, headset: headset)
        }
    }

    // MARK: - Status for the menu

    var routedHeadsetUID: String? { store.mode.routedHeadsetUID }
    var connectedHeadsets: [ConnectedHeadset] { headsets }

    func status() -> StayOnStatus { store.mode.status(now: now()) }

    func recentUnexpectedEnd() -> StayOnEnded? { store.mode.recentUnexpectedEnd(now: now()) }

    /// True while Stay on is routed to a headset that is playing music or video.
    var musicPlayingOnStayOnHeadset: Bool {
        guard let uid = store.mode.routedHeadsetUID else { return false }
        return playback[uid] == .media
    }

    // MARK: - Internals

    private enum Response { case playback(HeadsetPlayback); case advise }

    private func respond(_ playback: HeadsetPlayback, headset: ConnectedHeadset) {
        respond(.playback(playback), headset: headset)
    }

    private func respond(_ r: Response, headset: ConnectedHeadset?) {
        let playback: HeadsetPlayback
        if case .playback(let p) = r { playback = p } else { playback = .idle }
        var decision = LostTakeResponder.respond(headsetWithMic: headset?.hasMic ?? false, playback: playback,
                                                 stayOnActive: store.mode.isActive, lastAdvice: store.lastAdvice, now: now())
        if decision == .switchNow {
            let recentlyUndone = store.lastUndo.map { now().timeIntervalSince($0) < LostTakeResponder.undoMemory } ?? false
            if recentlyUndone || !autoSwitchAllowed() { decision = .offer }
        }
        switch decision {
        case .switchNow:
            guard let h = headset else { return }
            switchWhenIdle(h, snapshot: store.mode, since: now(), waited: false)
        case .offer:
            guard let h = headset else { return }
            presentNotice?(.offer(uid: h.uid, name: h.name))
        case .advise:
            store.lastAdvice = now(); save()
            presentNotice?(.advise)
        case .nothing:
            break
        }
    }

    /// Never change the mic in the middle of the next take: wait for it to end (up to 10
    /// minutes). If anything about Stay on changed meanwhile, the person decided; drop it.
    /// After a wait, decide again from scratch (music, pins and Undo may have changed).
    private func switchWhenIdle(_ h: ConnectedHeadset, snapshot: StayOnMode, since: Date, waited: Bool) {
        guard store.mode == snapshot else { return }
        if isRecording() {
            guard now().timeIntervalSince(since) < 600 else { return }
            schedule(5) { [weak self] in self?.switchWhenIdle(h, snapshot: snapshot, since: since, waited: true) }
            return
        }
        if waited {
            guard let input = headsets.first(where: { $0.uid == h.uid })?.input else { return }
            playbackProbe(input) { [weak self] playback in
                guard let self, self.store.mode == snapshot else { return }
                self.playback[h.uid] = playback
                self.respond(.playback(playback), headset: h)
            }
            return
        }
        guard !store.mode.isActive, headsets.contains(where: { $0.uid == h.uid && $0.hasMic }) else { return }
        start(uid: h.uid, name: h.name, duration: .standard, automatic: true)
        presentNotice?(.switched(uid: h.uid, name: h.name, startedAt: store.mode.session?.startedAt ?? now()))
    }

    private func handleUnexpectedEnd(_ ended: StayOnEnded, wasAutomatic: Bool) {
        DiagnosticLogger.shared.log("Stay on: ended (\(ended.reason.rawValue))")
        guard ended.reason == .expired, wasAutomatic,
              headsets.contains(where: { $0.uid == ended.deviceUID && $0.hasMic }) else { return }
        presentNotice?(.endedAfterAutomaticSwitch(uid: ended.deviceUID, name: ended.deviceName))
    }

    private func scheduleConnectNotice(uid: String) {
        let generation = (connectGeneration[uid] ?? 0) + 1
        connectGeneration[uid] = generation
        schedule(HeadsetNoticePolicy.settleSeconds) { [weak self] in self?.connectNoticeDue(uid: uid, generation: generation) }
    }

    private func connectNoticeDue(uid: String, generation: Int) {
        guard connectGeneration[uid] == generation,
              let headset = headsets.first(where: { $0.uid == uid && $0.hasMic }) else { return }
        if isRecording() {
            // Never during a take; try again shortly after.
            schedule(5) { [weak self] in self?.connectNoticeDue(uid: uid, generation: generation) }
            return
        }
        var record = store.notices[uid] ?? HeadsetNoticeRecord()
        let style = HeadsetNoticePolicy.style(for: record, now: now(), hasMic: true,
                                              stayOnActiveForThisHeadset: store.mode.isActive(for: uid))
        guard style != .none else { return }
        let offerDismiss = HeadsetNoticePolicy.offersDontShowAgain(record)
        HeadsetNoticePolicy.shown(&record, now: now())
        store.notices[uid] = record
        save()
        let using = store.mode.routedHeadsetUID.flatMap { r in headsets.first { $0.uid == r }?.name } ?? currentMicName()
        presentNotice?(.connected(uid: uid, name: headset.name, usingName: using, style: style,
                                  offerDontShowAgain: offerDismiss))
    }

    private func refreshPlayback() {
        guard let uid = store.mode.routedHeadsetUID,
              let input = headsets.first(where: { $0.uid == uid })?.input else { return }
        playbackProbe(input) { [weak self] result in
            guard let self, self.playback[uid] != result else { return }
            self.playback[uid] = result
            self.onChange?()
        }
    }

    private func mutate(_ body: (inout StayOnMode) -> Void) {
        let before = store.mode
        body(&store.mode)
        changed(from: before)
    }

    private func changed(from before: StayOnMode) {
        guard before != store.mode else { return }
        save()
        onChange?()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(store).write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticLogger.shared.log("Stay on: could not save state: \(error.localizedDescription)")
        }
    }

    /// This boot's session UUID; a different value means the Mac restarted. (kern.boottime
    /// seconds can shift when the clock is stepped, which would fake a restart.)
    static func currentBootID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &chars, &size, nil, 0) == 0 else { return nil }
        let id = String(cString: chars)
        return id.isEmpty ? nil : id
    }

    /// Laptops count real system sleep; desktops also count display sleep, since many
    /// never sleep the computer itself (design H.3). A laptop is a Mac with an internal
    /// battery (Apple silicon model names no longer say "MacBook").
    static var isLaptop: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
