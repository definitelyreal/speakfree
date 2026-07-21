// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import XCTest
@testable import SpeakFreeLib

/// The 2026-07-14 audio-routing work: microphone pinning, the contention detector,
/// dev mode, and the dual-capture prototype's pure pieces.
final class AudioRoutingTests: XCTestCase {

    // MARK: - Device catalog (smoke — CI runners may expose zero input devices)

    func testInputDeviceEnumerationDoesNotCrashAndFieldsArePopulated() {
        for device in AudioDeviceCatalog.inputDevices() {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
        }
    }

    func testDeviceLookupByUnknownUIDIsNil() {
        XCTAssertNil(AudioDeviceCatalog.device(withUID: "no-such-device-uid"))
    }

    func testCachePopulatesOffMainAndServesLookups() {
        // The cache is the only surface main-thread code may touch (2026-07-15 hang).
        AudioDeviceCatalog.startCache()
        let deadline = Date().addingTimeInterval(3)
        while AudioDeviceCatalog.cachedInputDevices.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // On a real Mac the cache fills; on a headless CI runner zero devices is legal.
        // Either way the cached accessors must be non-blocking and consistent.
        let devices = AudioDeviceCatalog.cachedInputDevices
        XCTAssertNil(AudioDeviceCatalog.cachedDevice(withUID: "no-such-device-uid"))
        if let builtIn = AudioDeviceCatalog.cachedBuiltInInput {
            XCTAssertTrue(devices.contains(builtIn))
            XCTAssertFalse(builtIn.isBluetooth, "a built-in mic is never Bluetooth")
        }
    }

    // MARK: - Contention detector

    /// Feed `count` events spaced `gap` seconds apart, starting at `t0`.
    /// Returns true if any event fired the notice.
    private func feedStorm(
        _ detector: inout ContentionDetector, from t0: Date, count: Int, gap: TimeInterval
    ) -> Bool {
        var fired = false
        for i in 0..<count {
            if detector.recordDisruption(at: t0.addingTimeInterval(Double(i) * gap)) {
                fired = true
            }
        }
        return fired
    }

    func testDetectorStaysQuietBelowThreshold() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(feedStorm(&detector, from: t0, count: detector.threshold - 1, gap: 3),
                       "even a rapid burst below the chain threshold stays quiet")
    }

    func testDetectorFiresOnRealStorm() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // The 2026-07-16 fight delivered 44 rebuild cycles in ~100s — events seconds apart.
        XCTAssertTrue(feedStorm(&detector, from: t0, count: detector.threshold, gap: 3),
                      "a sustained rapid chain = the multi-device fight signature")
    }

    func testDetectorIgnoresPocketCycles() {
        // 2026-07-21 false positive: AirPods in/out of a pocket. Each cycle emits a
        // small burst (disconnect + reconnect + a health-check rebuild), then silence.
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for cycle in 0..<10 {
            let cycleStart = t0.addingTimeInterval(Double(cycle) * 10 * 60)
            XCTAssertFalse(feedStorm(&detector, from: cycleStart, count: 3, gap: 20),
                           "pocket cycles minutes apart must never read as contention")
        }
    }

    func testDetectorGapResetsChain() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = feedStorm(&detector, from: t0, count: detector.threshold - 1, gap: 3)
        // A quiet stretch longer than chainGapSeconds breaks the chain…
        let t1 = t0.addingTimeInterval(20 * 60)
        XCTAssertFalse(feedStorm(&detector, from: t1, count: detector.threshold - 1, gap: 3),
                       "two sub-threshold bursts separated by silence must not accumulate")
    }

    func testDetectorCooldownSuppressesRepeatNotifications() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(feedStorm(&detector, from: t0, count: detector.threshold, gap: 3))
        // The storm rages on — no nagging within the 1-hour cooldown.
        let during = t0.addingTimeInterval(Double(detector.threshold) * 3)
        XCTAssertFalse(feedStorm(&detector, from: during, count: 20, gap: 3),
                       "within the 1-hour cooldown the user is not nagged again")
        // A fight that persists PAST the cooldown (fresh storm) notifies again.
        let t2 = t0.addingTimeInterval(2 * 60 * 60)
        XCTAssertTrue(feedStorm(&detector, from: t2, count: detector.threshold, gap: 3),
                      "after the cooldown a persisting fight may notify once more")
    }

    // MARK: - Dev mode

    func testEffectiveSaveRecordingsHonorsConfigWhenNotDev() {
        // The env seam forces dev mode OFF regardless of any marker on this machine.
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        defer { unsetenv("SPEAKFREE_DEV_MODE") }
        var config = Config.defaultConfig
        XCTAssertFalse(DevMode.effectiveSaveRecordings(config))
        config.saveRecordings = FlexBool(true)
        XCTAssertTrue(DevMode.effectiveSaveRecordings(config))
    }

    func testDevModeForcesSavingRegardlessOfConfig() {
        setenv("SPEAKFREE_DEV_MODE", "1", 1)
        defer { unsetenv("SPEAKFREE_DEV_MODE") }
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(false)
        XCTAssertTrue(DevMode.effectiveSaveRecordings(config),
                      "the dev machine's corpus must survive any settings state")
    }

    func testDevModeTagsMenuTitle() {
        XCTAssertTrue(SpeakFree.menuTitle(bundleID: "com.x.speakfree", buildChannel: "release",
                                          devMode: true).hasSuffix(" Dev"))
        XCTAssertFalse(SpeakFree.menuTitle(bundleID: "com.x.speakfree", buildChannel: "release",
                                           devMode: false).contains("Dev"))
    }

    // MARK: - Dual capture engagement (pure rule)

    func testDualCapturePinsPrimaryBeforeBluetoothAppears() {
        XCTAssertTrue(DualCapture.shouldUseBuiltInPrimary(
            flagOn: true, pinnedUID: nil, hasBuiltIn: true))
        XCTAssertFalse(DualCapture.shouldUseBuiltInPrimary(
            flagOn: false, pinnedUID: nil, hasBuiltIn: true))
        XCTAssertFalse(DualCapture.shouldUseBuiltInPrimary(
            flagOn: true, pinnedUID: "some-mic", hasBuiltIn: true))
    }

    func testDualCaptureEngagesOnlyWhenBluetoothIsAvailable() {
        XCTAssertTrue(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: nil, hasBuiltIn: true, hasBluetooth: true))
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: false, pinnedUID: nil, hasBuiltIn: true, hasBluetooth: true),
            "flag off = byte-identical legacy behavior")
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: "some-mic", hasBuiltIn: true, hasBluetooth: true),
            "an explicit user pin always wins")
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: nil, hasBuiltIn: true, hasBluetooth: false),
            "Bluetooth need not be default, but it must be available")
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: nil, hasBuiltIn: false, hasBluetooth: true),
            "no built-in mic = no primary track to carry pre-roll")
    }

    func testPinnedAndDualPrimariesIgnoreDefaultRouteChanges() {
        XCTAssertFalse(DualCapture.primaryFollowsSystemDefault(
            flagOn: true, pinnedUID: nil, hasBuiltIn: true))
        XCTAssertFalse(DualCapture.primaryFollowsSystemDefault(
            flagOn: false, pinnedUID: "studio-mic", hasBuiltIn: true))
        XCTAssertTrue(DualCapture.primaryFollowsSystemDefault(
            flagOn: false, pinnedUID: nil, hasBuiltIn: true))
        XCTAssertTrue(DualCapture.primaryFollowsSystemDefault(
            flagOn: true, pinnedUID: nil, hasBuiltIn: false))
    }

    // MARK: - Token agreement

    func testTokenAgreementIdenticalIsOne() {
        XCTAssertEqual(DualCapture.tokenAgreement("Hello world, this works.",
                                                  "hello WORLD this works"), 1.0)
    }

    func testTokenAgreementDisjointIsZero() {
        XCTAssertEqual(DualCapture.tokenAgreement("alpha beta", "gamma delta"), 0.0)
    }

    func testTokenAgreementPartial() {
        // 3 of 4 tokens agree in order → 0.75.
        XCTAssertEqual(DualCapture.tokenAgreement("one two three four", "one two three x"),
                       0.75, accuracy: 0.001)
    }

    func testTokenAgreementEmptyStrings() {
        XCTAssertEqual(DualCapture.tokenAgreement("", ""), 1.0)
        XCTAssertEqual(DualCapture.tokenAgreement("words here", ""), 0.0)
    }

    // MARK: - Wav writer round-trip

    func testWriteWavRoundTripsSampleCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcap-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<32_000).map { Float(sin(Double($0) * 0.01)) * 0.3 }
        try DualCapture.writeWav(samples: samples, to: url)
        let back = try ProcessCommand.loadSamples(from: url)
        XCTAssertEqual(back.count, samples.count)
    }
}
