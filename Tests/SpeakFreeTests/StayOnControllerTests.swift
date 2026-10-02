// ai-suggestion:unverified · 2026-09-24
import XCTest
@testable import SpeakFreeLib

final class StayOnControllerTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var notices: [StayOnNotice] = []
    private var recording = false
    private var playback: HeadsetPlayback = .idle

    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isBuiltIn: true, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let airPods = AudioInputDevice(id: 2, uid: "AA-BB:input", name: "AirPods Pro", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 24_000, inputChannels: 1)
    private let airPodsOut = AudioOutputDevice(id: 3, uid: "AA-BB:output", name: "AirPods Pro")
    private let speaker = AudioOutputDevice(id: 9, uid: "CC-DD", name: "Beats Pill")

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stayon-\(UUID().uuidString)")
        scheduled = []; notices = []; recording = false; playback = .idle
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func make(boot: String = "boot-1") -> StayOnController {
        let c = StayOnController(directory: dir, now: { [unowned self] in self.clock }, bootID: boot,
                                 schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) })
        c.isRecording = { [unowned self] in self.recording }
        c.currentMicName = { "MacBook Pro Microphone" }
        c.playbackProbe = { [unowned self] _, done in done(self.playback) }
        c.presentNotice = { [unowned self] in self.notices.append($0) }
        return c
    }

    func testHeadsetAlreadyConnectedAtLaunchGetsNoConnectNotice() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        runScheduled()
        XCTAssertTrue(notices.isEmpty)
    }

    private func runScheduled() {
        let work = scheduled; scheduled = []
        for (_, w) in work { w() }
    }

    func testStateSurvivesRelaunchAndIsStoredOutsideConfigJSON() throws {
        let a = make()
        a.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        a.start(uid: airPods.uid, name: airPods.name, duration: .sixHours)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stay-on.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        clock = clock.addingTimeInterval(3600)
        let b = make()
        XCTAssertTrue(b.mode.isActive(for: airPods.uid))
        XCTAssertEqual(b.routedHeadsetUID, airPods.uid)
    }

    func testUntilRestartEndsAfterARebootButNotAnAppRelaunch() {
        let a = make(boot: "boot-1")
        a.start(uid: airPods.uid, name: airPods.name, duration: .untilRestart)
        XCTAssertTrue(make(boot: "boot-1").mode.isActive)
        XCTAssertFalse(make(boot: "boot-2").mode.isActive)
        XCTAssertEqual(make(boot: "boot-2").recentUnexpectedEnd()?.reason, .restarted)
    }

    func testConnectNoticeWaitsTwentySecondsAndNeverInterruptsATake() {
        let c = make()
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        XCTAssertEqual(scheduled.map(\.0), [20])
        XCTAssertTrue(notices.isEmpty)
        recording = true
        runScheduled()
        XCTAssertTrue(notices.isEmpty, "held while recording")
        recording = false
        runScheduled()
        XCTAssertEqual(notices, [.connected(uid: airPods.uid, name: "AirPods Pro", usingName: "MacBook Pro Microphone", style: .full, offerDontShowAgain: false)])
    }

    func testConnectThatDoesNotSettleShowsNothing() {
        let c = make()
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        runScheduled()
        XCTAssertTrue(notices.isEmpty)
    }

    func testReconnectWithinTheSettleWindowRestartsTheWait() {
        let c = make()
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        runScheduled()
        XCTAssertEqual(notices.count, 1, "only the latest connection counts")
    }

    func testSpeakerThatNeverOfferedAMicIsNotListed() {
        let c = make()
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [speaker])
        runScheduled()
        XCTAssertTrue(notices.isEmpty)
        XCTAssertTrue(c.connectedHeadsets.isEmpty)
    }

    func testHeadsetWhoseMicMacOSStoppedOfferingIsListedWithoutAMic() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [airPodsOut])
        runScheduled()
        XCTAssertEqual(c.connectedHeadsets.map(\.name), ["AirPods Pro"])
        XCTAssertFalse(c.connectedHeadsets[0].hasMic)
    }

    func testAutomaticSwitchWaitsForTheNextTakeToEnd() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        recording = true
        lostTake(c)
        XCTAssertFalse(c.mode.isActive, "never change the mic mid-take")
        runScheduled()
        XCTAssertFalse(c.mode.isActive)
        recording = false
        runScheduled()
        XCTAssertTrue(c.mode.isActive)
        XCTAssertEqual(c.mode.session?.automatic, true)
    }

    func testNoticeGetsSmallerAfterTwoShowings() {
        let c = make()
        for _ in 0..<3 {
            c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
            c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
            runScheduled()
        }
        let styles: [HeadsetNoticeStyle] = notices.compactMap {
            if case .connected(_, _, _, let style, _) = $0 { return style } else { return nil }
        }
        XCTAssertEqual(styles, [.full, .full, .compact])
    }

    func testNoConnectNoticeWhileStayOnIsAlreadyOnForThatHeadset() {
        let c = make()
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .untilTurnedOff)
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        runScheduled()
        XCTAssertTrue(notices.isEmpty)
    }

    func testDisconnectWaitsAndReconnectResumesRouting() {
        let c = make()
        var changes = 0
        c.onChange = { changes += 1 }
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .twoHours)
        XCTAssertEqual(c.routedHeadsetUID, airPods.uid)
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [])
        XCTAssertNil(c.routedHeadsetUID)
        XCTAssertEqual(c.status(), .waitingForReconnect(name: "AirPods Pro"))
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        XCTAssertEqual(c.routedHeadsetUID, airPods.uid)
        XCTAssertGreaterThanOrEqual(changes, 3)
    }

    func testDeadlineWaitsForTheTake() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .oneHour)
        clock = clock.addingTimeInterval(3601)
        recording = true
        c.tick()
        XCTAssertTrue(c.mode.isActive)
        recording = false
        c.tick()
        XCTAssertFalse(c.mode.isActive)
    }

    func testHeadsetFailurePausesThenRetriesBetweenTakes() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .twoHours)
        c.headsetHealth(uid: airPods.uid, healthy: false)
        XCTAssertNil(c.routedHeadsetUID)
        if case .retrying = c.status() {} else { XCTFail("expected retrying") }
        clock = clock.addingTimeInterval(31)
        c.tick()
        XCTAssertEqual(c.routedHeadsetUID, airPods.uid)
        c.headsetHealth(uid: "other", healthy: false)
        XCTAssertEqual(c.routedHeadsetUID, airPods.uid, "reports for another device are ignored")
    }

    func testSleepRule() {
        let c = make()
        c.start(uid: airPods.uid, name: airPods.name, duration: .untilSleep)
        c.sleepBegan(); clock = clock.addingTimeInterval(10 * 60); c.sleepEnded()
        XCTAssertTrue(c.mode.isActive)
        c.sleepBegan(); clock = clock.addingTimeInterval(25 * 60); c.sleepEnded()
        XCTAssertFalse(c.mode.isActive)
        XCTAssertEqual(c.recentUnexpectedEnd()?.reason, .sleptLong)
    }

    // MARK: Lost take

    private func lostTake(_ c: StayOnController, onHeadset: Bool = false) {
        c.noteFinishedTake(durationSeconds: 20, noiseFloorDBFS: -34.8, transcriptChars: 5, recordedOnHeadset: onHeadset)
    }

    func testLostTakeSwitchesToTheHeadsetForTwoHoursWithUndo() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        lostTake(c)
        XCTAssertEqual(notices.last, .switched(uid: airPods.uid, name: "AirPods Pro", startedAt: clock))
        XCTAssertEqual(c.mode.session?.duration, .twoHours)
        XCTAssertEqual(c.mode.session?.automatic, true)
        XCTAssertEqual(c.routedHeadsetUID, airPods.uid)
        c.undo(uid: airPods.uid, startedAt: clock)
        XCTAssertFalse(c.mode.isActive)
        XCTAssertNil(c.recentUnexpectedEnd(), "undo is not announced")
        // After an Undo, the next lost take asks instead of switching again.
        lostTake(c)
        XCTAssertEqual(notices.last, .offer(uid: airPods.uid, name: "AirPods Pro"))
        XCTAssertFalse(c.mode.isActive)
        clock = clock.addingTimeInterval(25 * 3600)
        lostTake(c)
        XCTAssertTrue(c.mode.isActive, "a day later it switches again")
    }

    func testLostTakeOnlyOffersWhenMusicIsPlaying() {
        playback = .media
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        lostTake(c)
        XCTAssertEqual(notices.last, .offer(uid: airPods.uid, name: "AirPods Pro"))
        XCTAssertFalse(c.mode.isActive)
    }

    func testLostTakeWithACallOnTheHeadsetSwitches() {
        playback = .call
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        lostTake(c)
        XCTAssertTrue(c.mode.isActive)
    }

    func testLostTakeWithoutAHeadsetAdvisesAtMostHourly() {
        let c = make()
        c.devicesChanged(inputs: [builtIn], bluetoothOutputs: [speaker])
        lostTake(c)
        lostTake(c)
        XCTAssertEqual(notices, [.advise])
        clock = clock.addingTimeInterval(3600)
        lostTake(c)
        XCTAssertEqual(notices, [.advise, .advise])
    }

    func testTakesThatAreFineOrOnTheHeadsetDoNothing() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.noteFinishedTake(durationSeconds: 20, noiseFloorDBFS: -34.8, transcriptChars: 200, recordedOnHeadset: false)
        c.noteFinishedTake(durationSeconds: 20, noiseFloorDBFS: -60, transcriptChars: 0, recordedOnHeadset: false)
        c.noteFinishedTake(durationSeconds: 20, noiseFloorDBFS: nil, transcriptChars: 0, recordedOnHeadset: false)
        lostTake(c, onHeadset: true)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertFalse(c.mode.isActive)
    }

    func testAutomaticSwitchThatRunsOutOffersMoreTime() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        lostTake(c)
        clock = clock.addingTimeInterval(2 * 3600)
        c.tick()
        XCTAssertFalse(c.mode.isActive)
        XCTAssertEqual(notices.last, .endedAfterAutomaticSwitch(uid: airPods.uid, name: "AirPods Pro"))
    }

    func testChosenStayOnThatRunsOutEndsQuietly() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .oneHour)
        clock = clock.addingTimeInterval(3600)
        c.tick()
        XCTAssertTrue(notices.isEmpty)
        XCTAssertEqual(c.recentUnexpectedEnd()?.reason, .expired, "the menu's first row still says it ended")
    }

    func testMusicLineReflectsPlaybackOnTheStayOnHeadset() {
        playback = .media
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut])
        c.start(uid: airPods.uid, name: airPods.name, duration: .twoHours)
        XCTAssertTrue(c.musicPlayingOnStayOnHeadset)
        playback = .idle
        c.tick()
        XCTAssertFalse(c.musicPlayingOnStayOnHeadset)
    }

    func testChoosingStayOnCountsAsUseForNoticeCadence() {
        let c = make()
        c.start(uid: airPods.uid, name: airPods.name, duration: .twoHours)
        XCTAssertNotNil(c.store.notices[airPods.uid]?.lastUsed)
        c.end(.turnedOff)
        lostTake(c) // automatic start does not count as the person's choice
        c.undo(uid: airPods.uid, startedAt: clock)
        XCTAssertEqual(c.store.notices[airPods.uid]?.ignoredStreak, 0)
    }

    func testInventoryPairsHeadsetHalves() {
        XCTAssertEqual(HeadsetInventory.baseUID("AA-BB:input"), "AA-BB")
        let otherPairOut = AudioOutputDevice(id: 11, uid: "EE-FF:output", name: "AirPods Pro")
        XCTAssertEqual(HeadsetInventory.headsets(inputs: [airPods], bluetoothOutputs: [otherPairOut]).count, 2,
                       "a second pair with the same name is not merged into the first")
        XCTAssertEqual(HeadsetInventory.headsets(inputs: [builtIn, airPods], bluetoothOutputs: [airPodsOut, speaker]).map(\.name), ["AirPods Pro", "Beats Pill"])
        XCTAssertEqual(HeadsetInventory.deviceIDs(for: airPods, bluetoothOutputs: [airPodsOut, speaker]), [2, 3])
    }

    func testLateUndoNeverEndsANewerSession() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        lostTake(c)
        let autoStart = clock
        clock = clock.addingTimeInterval(60)
        c.start(uid: airPods.uid, name: airPods.name, duration: .sixHours)
        c.undo(uid: airPods.uid, startedAt: autoStart)
        XCTAssertEqual(c.mode.session?.duration, .sixHours)
    }

    func testNoAutomaticSwitchAwayFromAPinnedMic() {
        let c = make()
        c.autoSwitchAllowed = { false }
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        lostTake(c)
        XCTAssertFalse(c.mode.isActive)
        XCTAssertEqual(notices.last, .offer(uid: airPods.uid, name: "AirPods Pro"))
    }

    func testSettingsReSavingTheCurrentPinIsNotASelection() {
        XCTAssertFalse(StayOnController.isNewSelection("", current: nil))
        XCTAssertFalse(StayOnController.isNewSelection("usb", current: "usb"))
        XCTAssertTrue(StayOnController.isNewSelection("usb", current: nil))
        XCTAssertTrue(StayOnController.isNewSelection("", current: "usb"))
    }

    func testConnectNoticeNamesTheStayOnHeadsetWhenItIsLive() {
        let jabra = AudioInputDevice(id: 6, uid: "jabra", name: "Jabra Evolve2", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 16_000, inputChannels: 1)
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .twoHours)
        c.devicesChanged(inputs: [builtIn, airPods, jabra], bluetoothOutputs: [])
        runScheduled()
        XCTAssertEqual(notices.last, .connected(uid: "jabra", name: "Jabra Evolve2", usingName: "AirPods Pro", style: .full, offerDontShowAgain: false))
    }

    func testRetryBlocksThroughTheController() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        c.start(uid: airPods.uid, name: airPods.name, duration: .untilTurnedOff)
        var waits: [TimeInterval] = []
        for _ in 0..<12 {
            let failedAt = clock
            c.headsetHealth(uid: airPods.uid, healthy: false)
            XCTAssertNil(c.routedHeadsetUID)
            let next = c.mode.session!.nextAttemptAt!
            waits.append(next.timeIntervalSince(failedAt))
            clock = next.addingTimeInterval(-1); c.tick()
            XCTAssertNil(c.routedHeadsetUID, "not before the wait is over")
            clock = next; c.tick()
            XCTAssertEqual(c.routedHeadsetUID, airPods.uid)
        }
        XCTAssertEqual(waits, [30, 30, 300, 30, 30, 1200, 30, 30, 3600, 30, 30, 3600])
        c.headsetHealth(uid: airPods.uid, healthy: true)
        XCTAssertEqual(c.mode.session?.failures, 0)
    }

    func testDeferredSwitchYieldsToAChoiceMadeDuringTheTake() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        recording = true
        lostTake(c)
        c.start(uid: airPods.uid, name: airPods.name, duration: .oneHour)
        c.end(.turnedOff)
        recording = false
        runScheduled()
        XCTAssertFalse(c.mode.isActive, "he ended Stay on himself; no automatic switch afterwards")
    }

    func testDeferredSwitchRechecksMusic() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        recording = true
        lostTake(c)
        playback = .media
        recording = false
        runScheduled()
        XCTAssertFalse(c.mode.isActive)
        XCTAssertEqual(notices.last, .offer(uid: airPods.uid, name: "AirPods Pro"))
    }

    func testDeferredSwitchGivesUpAfterTenMinutes() {
        let c = make()
        c.devicesChanged(inputs: [builtIn, airPods], bluetoothOutputs: [])
        recording = true
        lostTake(c)
        clock = clock.addingTimeInterval(601)
        runScheduled()
        XCTAssertTrue(scheduled.isEmpty)
        recording = false
        XCTAssertFalse(c.mode.isActive)
    }
}
