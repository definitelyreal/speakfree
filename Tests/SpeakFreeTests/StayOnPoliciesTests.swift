// ai-suggestion:unverified · 2026-09-24
import XCTest
@testable import SpeakFreeLib

final class StayOnPoliciesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Connect notice

    private func style(_ r: HeadsetNoticeRecord, _ now: Date, mic: Bool = true, active: Bool = false) -> HeadsetNoticeStyle {
        HeadsetNoticePolicy.style(for: r, now: now, hasMic: mic, stayOnActiveForThisHeadset: active)
    }

    func testFirstTwoConnectionsShowFullThenCompact() {
        var r = HeadsetNoticeRecord()
        XCTAssertEqual(style(r, t0), .full)
        HeadsetNoticePolicy.shown(&r, now: t0)
        XCTAssertEqual(style(r, t0), .full)
        XCTAssertFalse(HeadsetNoticePolicy.offersDontShowAgain(r))
        HeadsetNoticePolicy.shown(&r, now: t0)
        XCTAssertEqual(style(r, t0), .compact)
        XCTAssertTrue(HeadsetNoticePolicy.offersDontShowAgain(r))
    }

    func testNeverWithoutAMicOrWhileStayOnIsActiveOrAfterDontShowAgain() {
        var r = HeadsetNoticeRecord()
        XCTAssertEqual(style(r, t0, mic: false), .none)
        XCTAssertEqual(style(r, t0, active: true), .none)
        r.dismissedForever = true
        XCTAssertEqual(style(r, t0), .none)
    }

    func testThreeIgnoredShowingsBackOffOneDayThreeDaysWeekly() {
        var r = HeadsetNoticeRecord()
        for _ in 0..<3 { HeadsetNoticePolicy.shown(&r, now: t0) }
        XCTAssertEqual(r.ignoredStreak, 3)
        XCTAssertEqual(style(r, t0.addingTimeInterval(3600)), .none)
        XCTAssertEqual(style(r, t0.addingTimeInterval(86400)), .compact)
        HeadsetNoticePolicy.shown(&r, now: t0.addingTimeInterval(86400))
        XCTAssertEqual(style(r, t0.addingTimeInterval(86400 * 3.9)), .none)
        XCTAssertEqual(style(r, t0.addingTimeInterval(86400 * 4)), .compact)
        HeadsetNoticePolicy.shown(&r, now: t0.addingTimeInterval(86400 * 4))
        XCTAssertEqual(style(r, t0.addingTimeInterval(86400 * 10)), .none)
        XCTAssertEqual(style(r, t0.addingTimeInterval(86400 * 11)), .compact)
    }

    func testUseAtAnyTimeResetsAndShowsEveryConnection() {
        var r = HeadsetNoticeRecord()
        for _ in 0..<5 { HeadsetNoticePolicy.shown(&r, now: t0) }
        XCTAssertEqual(style(r, t0.addingTimeInterval(60)), .none)
        HeadsetNoticePolicy.used(&r, now: t0.addingTimeInterval(20 * 60)) // chose it from the menu later
        XCTAssertEqual(r.ignoredStreak, 0)
        XCTAssertEqual(style(r, t0.addingTimeInterval(30 * 60)), .compact)
        for _ in 0..<4 { HeadsetNoticePolicy.shown(&r, now: t0.addingTimeInterval(40 * 60)) }
        XCTAssertEqual(style(r, t0.addingTimeInterval(50 * 60)), .compact, "recent use keeps it showing")
    }

    // MARK: Lost take

    func testLostTakeRule() {
        XCTAssertTrue(LostTakeDetector.isLost(durationSeconds: 20, noiseFloorDBFS: -34.8, transcriptChars: 5))
        XCTAssertFalse(LostTakeDetector.isLost(durationSeconds: 7.9, noiseFloorDBFS: -30, transcriptChars: 0), "short")
        XCTAssertFalse(LostTakeDetector.isLost(durationSeconds: 20, noiseFloorDBFS: -55, transcriptChars: 0), "quiet room: thinking, not lost")
        XCTAssertFalse(LostTakeDetector.isLost(durationSeconds: 20, noiseFloorDBFS: -48, transcriptChars: 0), "boundary is exclusive")
        XCTAssertFalse(LostTakeDetector.isLost(durationSeconds: 10, noiseFloorDBFS: -30, transcriptChars: 20), "2 chars/s is enough")
        XCTAssertTrue(LostTakeDetector.isLost(durationSeconds: 10, noiseFloorDBFS: -30, transcriptChars: 19))
        XCTAssertFalse(LostTakeDetector.isLost(durationSeconds: 10, noiseFloorDBFS: -30, transcriptChars: 0),
                       "nothing at all: likely an accidental hold, not lost speech")
    }

    func testNoiseFloorIsTheQuietTenth() {
        let window = 1600
        var samples: [Float] = []
        for i in 0..<100 {
            let amp: Float = i < 10 ? 0.01 : 0.5
            samples += [Float](repeating: amp, count: window)
        }
        let floor = try! XCTUnwrap(LostTakeDetector.noiseFloorDBFS(samples: samples))
        XCTAssertEqual(floor, 20 * log10(0.01), accuracy: 0.01)
        XCTAssertNil(LostTakeDetector.noiseFloorDBFS(samples: [0.1, 0.2]))
        XCTAssertLessThan(LostTakeDetector.noiseFloorDBFS(samples: [Float](repeating: 0, count: 3200))!, -150)
    }

    // MARK: Playback

    func testWhatIsPlayingOnTheHeadset() {
        typealias U = AudioProcessUse
        let own = "com.definitelyreal.speakfree"
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([], ownBundleID: own), .idle)
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: own, inputOnHeadset: true)], ownBundleID: own), .idle,
                       "speakfree itself is not a call")
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: "us.zoom.xos", inputOnHeadset: true, outputOnHeadset: true)], ownBundleID: own), .call)
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: "us.zoom.xos", outputOnHeadset: true)], ownBundleID: own), .call, "muted call")
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: "com.spotify.client", outputOnHeadset: true)], ownBundleID: own), .media)
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: "com.google.Chrome.helper", outputOnHeadset: true)], ownBundleID: own), .media,
                       "browser audio with no mic is treated as music")
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([
            U(bundleID: "com.google.Chrome.helper", outputOnHeadset: true),
            U(bundleID: "com.google.Chrome.helper", inputAnywhere: true)], ownBundleID: own), .call, "a Meet call in Chrome")
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: "com.example.unknown", outputOnHeadset: true)], ownBundleID: own), .media,
                       "unknown output stays on the safe side")
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([
            U(bundleID: "us.zoom.xos", outputOnHeadset: true),
            U(bundleID: "com.apple.Music", outputOnHeadset: true)], ownBundleID: own), .media)
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([
            U(bundleID: "com.spotify.client", outputOnHeadset: true),
            U(bundleID: "com.apple.avconferenced", inputOnHeadset: true)], ownBundleID: own), .call,
                       "the headset mic is already open for a call, so switching is free")
        XCTAssertEqual(HeadsetPlaybackClassifier.classify([U(bundleID: "com.spotify.client", outputOnHeadset: false, inputAnywhere: false)], ownBundleID: own), .idle)
        XCTAssertEqual(HeadsetPlaybackClassifier.appID("com.tinyspeck.slackmacgap.helper.Helper"), "com.tinyspeck.slackmacgap")
    }

    // MARK: Switch or offer

    func testLostTakeResponse() {
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: true, playback: .idle, stayOnActive: false, lastAdvice: nil, now: t0), .switchNow)
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: true, playback: .call, stayOnActive: false, lastAdvice: nil, now: t0), .switchNow)
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: true, playback: .media, stayOnActive: false, lastAdvice: nil, now: t0), .offer)
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: true, playback: .idle, stayOnActive: true, lastAdvice: nil, now: t0), .nothing)
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: false, playback: .idle, stayOnActive: false, lastAdvice: nil, now: t0), .advise)
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: false, playback: .idle, stayOnActive: false, lastAdvice: t0, now: t0.addingTimeInterval(1800)), .nothing,
                       "advice at most once an hour")
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: false, playback: .idle, stayOnActive: false, lastAdvice: t0, now: t0.addingTimeInterval(3600)), .advise)
    }
}
