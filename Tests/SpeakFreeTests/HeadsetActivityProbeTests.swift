// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import XCTest
import CoreAudio
@testable import SpeakFreeLib

final class HeadsetActivityProbeTests: XCTestCase {
    private func reader() -> HeadsetActivityProbe.Readers {
        .init(processes: { [10] }, runningInput: { _ in false }, runningOutput: { _ in true },
              bundleID: { _ in "com.example.music" }, inputDevices: { _ in nil },
              outputDevices: { _ in [20] })
    }

    private func classify(_ readers: HeadsetActivityProbe.Readers) -> HeadsetPlayback {
        HeadsetActivityProbe.classify(headsetIDs: [20], ownBundleID: "com.example.dictation", readers: readers)
    }

    func testUnreadableProcessListIsUnknownButSuccessfulEmptyListIsIdle() {
        var r = reader(); r.processes = { nil }
        XCTAssertEqual(classify(r), .unknown)
        r.processes = { [] }
        XCTAssertEqual(classify(r), .idle)
    }

    func testUnreadableActivityOrActiveRouteIsUnknown() {
        var r = reader(); r.runningInput = { _ in nil }
        XCTAssertEqual(classify(r), .unknown)
        r = reader(); r.runningOutput = { _ in nil }
        XCTAssertEqual(classify(r), .unknown)
        r = reader(); r.outputDevices = { _ in nil }
        XCTAssertEqual(classify(r), .unknown)
        r = reader(); r.runningInput = { _ in true }
        XCTAssertEqual(classify(r), .unknown)
    }

    func testActiveProcessWithoutIdentityIsUnknown() {
        var r = reader(); r.bundleID = { _ in nil }
        XCTAssertEqual(classify(r), .unknown)
        r.bundleID = { _ in "" }
        XCTAssertEqual(classify(r), .unknown)
    }

    func testInactiveDirectionsNeedNoRouteAndKnownPlaybackKeepsItsMeaning() {
        var r = reader()
        XCTAssertEqual(classify(r), .media)
        r.outputDevices = { _ in [30] }
        XCTAssertEqual(classify(r), .idle)
        r.runningInput = { _ in true }; r.inputDevices = { _ in [20] }
        XCTAssertEqual(classify(r), .call)
    }

    func testIncompleteOtherProcessCannotLookLikeACompletelyObservedCall() {
        var r = reader(); r.processes = { [10, 11] }
        r.runningInput = { $0 == 10 ? true : nil }; r.inputDevices = { _ in [20] }
        XCTAssertEqual(classify(r), .unknown)
    }

    func testUnknownPlaybackOffersInsteadOfAutomaticallyOpeningBluetoothMic() {
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: true, playback: .unknown,
            stayOnActive: false, lastAdvice: nil, now: Date(timeIntervalSince1970: 1)), .offer)
        XCTAssertEqual(LostTakeResponder.respond(headsetWithMic: true, playback: .unknown,
            stayOnActive: true, lastAdvice: nil, now: Date(timeIntervalSince1970: 1)), .nothing)
    }
}
