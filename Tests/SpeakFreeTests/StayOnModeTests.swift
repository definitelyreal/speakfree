// ai-suggestion:unverified · 2026-09-24
import XCTest
@testable import SpeakFreeLib

final class StayOnModeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let uid = "airpods-uid"
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let en = Locale(identifier: "en_US_POSIX")

    private func started(_ d: StayOnDuration = .twoHours, boot: String? = "boot-1") -> StayOnMode {
        var m = StayOnMode()
        m.start(deviceUID: uid, deviceName: "AirPods Pro", duration: d, now: t0, bootID: boot)
        return m
    }

    // MARK: Durations

    func testDecidedListOrderAndDefault() {
        XCTAssertEqual(StayOnDuration.standard, .twoHours)
        XCTAssertEqual(StayOnDuration.menuGroups.flatMap { $0 }.map(\.menuTitle), [
            "For 1 hour", "For 2 hours", "For 6 hours", "For 24 hours",
            "Until I turn it off", "Until computer sleeps for 20min", "Until restart"])
        XCTAssertEqual(StayOnDuration.menuGroups.map(\.count), [4, 1, 2])
    }

    func testStartRoutesToTheHeadset() {
        let m = started()
        XCTAssertEqual(m.routedHeadsetUID, uid)
        XCTAssertTrue(m.isActive(for: uid))
        XCTAssertFalse(m.isActive(for: "other"))
    }

    func testClockDurationsExpireOnTheirOwn() {
        for (d, secs) in [(StayOnDuration.oneHour, 3600.0), (.twoHours, 7200), (.sixHours, 21600), (.twentyFourHours, 86400)] {
            var m = started(d)
            XCTAssertNil(m.tick(now: t0.addingTimeInterval(secs - 1), recording: false))
            XCTAssertTrue(m.isActive)
            let ended = m.tick(now: t0.addingTimeInterval(secs), recording: false)
            XCTAssertEqual(ended?.reason, .expired)
            XCTAssertNil(m.routedHeadsetUID)
        }
    }

    func testDeadlineDuringATakeWaitsForTheTake() {
        var m = started(.oneHour)
        XCTAssertNil(m.tick(now: t0.addingTimeInterval(3700), recording: true))
        XCTAssertEqual(m.routedHeadsetUID, uid)
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(3710), recording: false)?.reason, .expired)
    }

    func testOpenEndedDurationsNeverExpireOnTime() {
        for d in [StayOnDuration.untilTurnedOff, .untilSleep, .untilRestart] {
            var m = started(d)
            XCTAssertNil(m.tick(now: t0.addingTimeInterval(30 * 86400), recording: false))
            XCTAssertTrue(m.isActive)
        }
    }

    func testExplicitEnds() {
        for reason in [StayOnEndReason.turnedOff, .choseOtherMic, .undone] {
            var m = started()
            XCTAssertEqual(m.end(reason, now: t0)?.reason, reason)
            XCTAssertFalse(m.isActive)
            XCTAssertNil(m.recentUnexpectedEnd(now: t0), "an end the person chose is not announced")
        }
        var m = StayOnMode()
        XCTAssertNil(m.end(.turnedOff, now: t0))
    }

    func testRestartingReplacesTheSessionAndClearsLastEnded() {
        var m = started(.oneHour)
        _ = m.tick(now: t0.addingTimeInterval(3600), recording: false)
        m.start(deviceUID: "jabra", deviceName: "Jabra Evolve2 65", duration: .sixHours, now: t0, bootID: nil)
        XCTAssertEqual(m.routedHeadsetUID, "jabra")
        XCTAssertNil(m.lastEnded)
    }

    // MARK: Disconnect and reconnect

    func testDisconnectNeverEndsTheModeAndReconnectResumes() {
        var m = started(.untilTurnedOff)
        m.devicesChanged(presentUIDs: ["built-in"], now: t0.addingTimeInterval(60))
        XCTAssertTrue(m.isActive, "a disconnect must not end Stay on")
        XCTAssertNil(m.routedHeadsetUID)
        XCTAssertEqual(m.status(now: t0), .waitingForReconnect(name: "AirPods Pro"))
        // Hours later, still waiting.
        XCTAssertNil(m.tick(now: t0.addingTimeInterval(10 * 3600), recording: false))
        m.devicesChanged(presentUIDs: ["built-in", uid], now: t0.addingTimeInterval(10 * 3600))
        XCTAssertEqual(m.routedHeadsetUID, uid)
    }

    func testClockStillRunsWhileDisconnected() {
        var m = started(.oneHour)
        m.devicesChanged(presentUIDs: [], now: t0.addingTimeInterval(10))
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(3600), recording: false)?.reason, .expired)
    }

    func testRepeatedDisconnectKeepsFirstAbsenceTime() {
        var m = started()
        m.devicesChanged(presentUIDs: [], now: t0.addingTimeInterval(10))
        m.devicesChanged(presentUIDs: [], now: t0.addingTimeInterval(20))
        XCTAssertEqual(m.session?.absentSince, t0.addingTimeInterval(10))
    }

    func testReconnectClearsFailureHistory() {
        var m = started()
        m.headsetFailed(now: t0)
        m.devicesChanged(presentUIDs: [], now: t0.addingTimeInterval(5))
        m.devicesChanged(presentUIDs: [uid], now: t0.addingTimeInterval(6))
        XCTAssertEqual(m.session?.failures, 0)
        XCTAssertEqual(m.routedHeadsetUID, uid)
    }

    func testRename() {
        var m = started()
        m.deviceRenamed(to: "Sam's AirPods Pro")
        XCTAssertEqual(m.session?.deviceName, "Sam's AirPods Pro")
        m.deviceRenamed(to: "")
        XCTAssertEqual(m.session?.deviceName, "Sam's AirPods Pro")
    }

    // MARK: Headset mic failure and the retry schedule

    func testRetryScheduleThreeTriesThenFiveTwentyAndHourly() {
        let delays = (1...12).map { StayOnMode.retryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [30, 30, 300, 30, 30, 1200, 30, 30, 3600, 30, 30, 3600])
        XCTAssertEqual(StayOnMode.retryDelay(afterFailures: 0), 0)
    }

    func testFailurePausesRoutingUntilTheRetryIsDueBetweenTakes() {
        var m = started()
        m.headsetFailed(now: t0)
        XCTAssertNil(m.routedHeadsetUID, "paused: dictation uses the Mac mic")
        XCTAssertEqual(m.status(now: t0), .retrying(name: "AirPods Pro", next: t0.addingTimeInterval(30)))
        m.tick(now: t0.addingTimeInterval(29), recording: false)
        XCTAssertNil(m.routedHeadsetUID)
        m.tick(now: t0.addingTimeInterval(40), recording: true)
        XCTAssertNil(m.routedHeadsetUID, "never start a retry at the start of or during a take")
        m.tick(now: t0.addingTimeInterval(41), recording: false)
        XCTAssertEqual(m.routedHeadsetUID, uid)
        XCTAssertEqual(m.session?.failures, 1, "failure count survives until the headset proves healthy")
    }

    func testThirdFailureWaitsFiveMinutes() {
        var m = started()
        var now = t0
        for _ in 0..<3 {
            m.headsetFailed(now: now)
            now = m.session!.nextAttemptAt!
            m.tick(now: now, recording: false)
        }
        XCTAssertEqual(m.session?.failures, 3)
        // After the third, the wait was 5 minutes.
        var check = started()
        check.headsetFailed(now: t0); check.tick(now: t0.addingTimeInterval(30), recording: false)
        check.headsetFailed(now: t0.addingTimeInterval(30)); check.tick(now: t0.addingTimeInterval(60), recording: false)
        check.headsetFailed(now: t0.addingTimeInterval(60))
        XCTAssertEqual(check.session?.nextAttemptAt, t0.addingTimeInterval(360))
    }

    func testFailureWhilePausedIsNotDoubleCounted() {
        var m = started()
        m.headsetFailed(now: t0)
        m.headsetFailed(now: t0.addingTimeInterval(1))
        XCTAssertEqual(m.session?.failures, 1)
    }

    func testHealthyAudioClearsFailures() {
        var m = started()
        m.headsetFailed(now: t0)
        m.tick(now: t0.addingTimeInterval(31), recording: false)
        m.headsetHealthy()
        XCTAssertEqual(m.session?.failures, 0)
        XCTAssertEqual(m.routedHeadsetUID, uid)
    }

    func testFailureWhileAbsentIsIgnored() {
        var m = started()
        m.devicesChanged(presentUIDs: [], now: t0)
        m.headsetFailed(now: t0)
        XCTAssertEqual(m.session?.failures, 0)
    }

    func testFailureNeverEndsTheMode() {
        var m = started(.untilTurnedOff)
        var now = t0
        for _ in 0..<20 {
            m.headsetFailed(now: now)
            now = m.session!.nextAttemptAt!
            m.tick(now: now, recording: false)
        }
        XCTAssertTrue(m.isActive)
    }

    // MARK: Sleep and wake

    func testUntilSleepEndsOnlyOnASleepOfTwentyMinutesOrMore() {
        var m = started(.untilSleep)
        m.sleepBegan(now: t0.addingTimeInterval(100))
        XCTAssertNil(m.sleepEnded(now: t0.addingTimeInterval(100 + 19 * 60)))
        XCTAssertTrue(m.isActive, "a short lid close to move rooms keeps it")
        m.sleepBegan(now: t0.addingTimeInterval(5000))
        let ended = m.sleepEnded(now: t0.addingTimeInterval(5000 + 20 * 60))
        XCTAssertEqual(ended?.reason, .sleptLong)
        XCTAssertEqual(m.recentUnexpectedEnd(now: t0.addingTimeInterval(5000 + 21 * 60))?.reason, .sleptLong)
    }

    func testSleepOfAnyLengthKeepsOtherDurations() {
        for d in [StayOnDuration.untilRestart, .untilTurnedOff, .twentyFourHours] {
            var m = started(d)
            m.sleepBegan(now: t0)
            XCTAssertNil(m.sleepEnded(now: t0.addingTimeInterval(8 * 3600)))
            XCTAssertTrue(m.isActive, "\(d)")
        }
    }

    func testClockThatRanOutDuringSleepEndsOnTheFirstTickAfterWake() {
        var m = started(.oneHour)
        m.sleepBegan(now: t0.addingTimeInterval(60))
        _ = m.sleepEnded(now: t0.addingTimeInterval(5 * 3600))
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(5 * 3600), recording: false)?.reason, .expired)
    }

    func testSleepEndedWithoutBeginIsANoOp() {
        var m = started(.untilSleep)
        XCTAssertNil(m.sleepEnded(now: t0.addingTimeInterval(9999)))
        XCTAssertTrue(m.isActive)
    }

    func testSecondSleepBeganKeepsTheEarliestStart() {
        var m = started(.untilSleep)
        m.sleepBegan(now: t0)
        m.sleepBegan(now: t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(m.sleepEnded(now: t0.addingTimeInterval(21 * 60))?.reason, .sleptLong)
    }

    // MARK: Restart, log out, relaunch

    func testPoweringOffEndsOnlyRestartScopedDurations() {
        var a = started(.untilRestart)
        XCTAssertEqual(a.poweringOff(now: t0)?.reason, .restarted)
        var b = started(.untilSleep)
        XCTAssertEqual(b.poweringOff(now: t0)?.reason, .restarted)
        for d in [StayOnDuration.untilTurnedOff, .twoHours] {
            var c = started(d)
            XCTAssertNil(c.poweringOff(now: t0))
            XCTAssertTrue(c.isActive)
        }
    }

    func testRelaunchInTheSameBootKeepsEveryDuration() {
        for d in StayOnDuration.allCases {
            var m = started(d, boot: "boot-1")
            XCTAssertNil(m.launched(bootID: "boot-1", now: t0.addingTimeInterval(60)), "\(d)")
            XCTAssertTrue(m.isActive)
        }
    }

    func testRelaunchAfterARestart() {
        var a = started(.untilRestart, boot: "boot-1")
        XCTAssertEqual(a.launched(bootID: "boot-2", now: t0)?.reason, .restarted)
        var b = started(.untilSleep, boot: "boot-1")
        XCTAssertEqual(b.launched(bootID: "boot-2", now: t0)?.reason, .restarted)
        var c = started(.untilTurnedOff, boot: "boot-1")
        XCTAssertNil(c.launched(bootID: "boot-2", now: t0.addingTimeInterval(7 * 86400)))
        XCTAssertTrue(c.isActive, "Until I turn it off survives restarts")
        var d = started(.sixHours, boot: "boot-1")
        XCTAssertNil(d.launched(bootID: "boot-2", now: t0.addingTimeInterval(3600)))
        XCTAssertTrue(d.isActive, "a clock time survives a restart until its time is up")
        var e = started(.sixHours, boot: "boot-1")
        XCTAssertEqual(e.launched(bootID: "boot-2", now: t0.addingTimeInterval(7 * 3600))?.reason, .expired)
    }

    func testRelaunchClearsASleepThatBeganBeforeQuit() {
        var m = started(.untilSleep)
        m.sleepBegan(now: t0)
        m.launched(bootID: "boot-1", now: t0.addingTimeInterval(3600))
        XCTAssertNil(m.session?.sleepStartedAt)
        XCTAssertTrue(m.isActive)
    }

    func testPersistenceRoundTripsThroughJSON() throws {
        var m = started(.sixHours)
        m.headsetFailed(now: t0)
        m.devicesChanged(presentUIDs: [], now: t0.addingTimeInterval(9))
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(StayOnMode.self, from: data)
        XCTAssertEqual(back, m)
        var ended = started(.oneHour)
        ended.tick(now: t0.addingTimeInterval(3600), recording: false)
        XCTAssertEqual(try JSONDecoder().decode(StayOnMode.self, from: JSONEncoder().encode(ended)), ended)
    }

    // MARK: Status text

    func testStatusDetail() {
        let m = started(.twoHours)
        XCTAssertEqual(m.status(now: t0, calendar: utc, locale: en),
                       .active(name: "AirPods Pro", detail: "until " + StayOnMode.clock(t0.addingTimeInterval(7200), now: t0, calendar: utc, locale: en)))
        XCTAssertEqual(m.status(now: t0.addingTimeInterval(7200 - 42 * 60), calendar: utc, locale: en),
                       .active(name: "AirPods Pro", detail: "42 min left"))
        XCTAssertEqual(m.status(now: t0.addingTimeInterval(7170), calendar: utc, locale: en),
                       .active(name: "AirPods Pro", detail: "ending now"))
        XCTAssertEqual(started(.untilRestart).status(now: t0), .active(name: "AirPods Pro", detail: "until restart"))
        XCTAssertEqual(started(.untilSleep).status(now: t0), .active(name: "AirPods Pro", detail: "until this Mac sleeps for 20 min"))
        XCTAssertEqual(StayOnMode().status(now: t0), .off)
    }

    func testClockFormatting() {
        let midnight: TimeInterval = 1_789_948_800 // 2026-09-21 00:00 UTC
        let noon = Date(timeIntervalSince1970: midnight + 43_500)
        XCTAssertEqual(StayOnMode.clock(noon, now: noon, calendar: utc, locale: en), "12:05pm")
        let early = noon.addingTimeInterval(13 * 3600)
        XCTAssertTrue(StayOnMode.clock(early, now: noon, calendar: utc, locale: en).hasSuffix(" 1:05am"))
        let m = started(.untilTurnedOff)
        if case .active(_, let detail) = m.status(now: t0.addingTimeInterval(3 * 86400), calendar: utc, locale: en) {
            XCTAssertTrue(detail.hasPrefix("on since "))
            XCTAssertTrue(detail.contains("day "), "an old start names the day: \(detail)")
        } else { XCTFail("An until-turned-off session must remain active after three days") }
    }

    func testUnexpectedEndIsShownOnlyForAWhile() {
        var m = started(.oneHour)
        m.tick(now: t0.addingTimeInterval(3600), recording: false)
        XCTAssertNotNil(m.recentUnexpectedEnd(now: t0.addingTimeInterval(3600 + 60)))
        XCTAssertNil(m.recentUnexpectedEnd(now: t0.addingTimeInterval(3600 + 31 * 60)))
        m.clearLastEnded()
        XCTAssertNil(m.recentUnexpectedEnd(now: t0.addingTimeInterval(3600 + 60)))
    }

    // MARK: Labels

    func testHeadsetLabels() {
        XCTAssertEqual(HeadsetLabel.short("AirPods Pro"), "AirPods Pro")
        XCTAssertEqual(HeadsetLabel.short("Sam's AirPods Pro (2)"), "AirPods Pro (2)")
        XCTAssertEqual(HeadsetLabel.short("Sam\u{2019}s AirPods Pro"), "AirPods Pro")
        let long = HeadsetLabel.short("Jabra Evolve2 65 Flex Link380")
        XCTAssertLessThanOrEqual(long.count, HeadsetLabel.maxLength)
        XCTAssertTrue(long.hasPrefix("Jabra Evolve2"))
        XCTAssertTrue(long.hasSuffix("Link380"))
        XCTAssertEqual(long, "Jabra Evolve2...Link380")
        XCTAssertEqual(HeadsetLabel.short("Mom's"), "Mom's")
    }
}
