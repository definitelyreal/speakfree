// Claude · 2026-07-03 · Session: 6f785b82-a72f-49de-99dc-89f3a51601e4
//
// Pins the MANDATORY menu-title convention (project CLAUDE.md): the dropdown title must
// always identify which build is running, so an experimental/test build is never mistaken
// for the dogfood release. Born of the 2026-07-02 incident where two builds fought over
// the fn hotkey and one silently wasn't recording.

import XCTest
@testable import SpeakFreeLib

final class MenuTitleTests: XCTestCase {
    private let v = SpeakFree.version

    func testStreamingVariantIsAlwaysTagged() {
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree.streaming", buildChannel: nil),
            "SpeakFree Streaming \(v) Testing")
        // Even a release-stamped streaming build is a test build — variant wins over channel.
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree.streaming", buildChannel: "release"),
            "SpeakFree Streaming \(v) Testing")
    }

    func testBetaVariantIsAlwaysTagged() {
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree.beta", buildChannel: nil),
            "SpeakFree Beta \(v) Testing")
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree.beta", buildChannel: "release"),
            "SpeakFree Beta \(v) Testing")
    }

    func testProductionDevBuildIsTagged() {
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree", buildChannel: nil),
            "speakfree \(v) Testing")
        // Any non-"release" channel value is still a test build.
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree", buildChannel: "dev"),
            "speakfree \(v) Testing")
    }

    func testOnlyReleaseStampedProductionGetsCleanTitle() {
        XCTAssertEqual(
            SpeakFree.menuTitle(bundleID: "com.definitelyreal.speakfree", buildChannel: "release"),
            "speakfree \(v)")
    }

    func testUnknownBundleFallsBackToProductionRules() {
        XCTAssertEqual(SpeakFree.menuTitle(bundleID: "", buildChannel: nil),
                       "speakfree \(v) Testing")
    }
}
