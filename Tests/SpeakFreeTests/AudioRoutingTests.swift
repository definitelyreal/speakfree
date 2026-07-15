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

    func testDetectorStaysQuietBelowThreshold() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(detector.recordDisruption(at: t0))
        XCTAssertFalse(detector.recordDisruption(at: t0.addingTimeInterval(60)))
    }

    func testDetectorFiresAtThresholdWithinWindow() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = detector.recordDisruption(at: t0)
        _ = detector.recordDisruption(at: t0.addingTimeInterval(300))
        XCTAssertTrue(detector.recordDisruption(at: t0.addingTimeInterval(600)),
                      "3 disruptions in 10 minutes = the multi-device fight signature")
    }

    func testDetectorIgnoresEventsOutsideWindow() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = detector.recordDisruption(at: t0)
        _ = detector.recordDisruption(at: t0.addingTimeInterval(31 * 60))
        XCTAssertFalse(detector.recordDisruption(at: t0.addingTimeInterval(62 * 60)),
                       "events spread beyond the 30-minute window must not accumulate")
    }

    func testDetectorCooldownSuppressesRepeatNotifications() {
        var detector = ContentionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = detector.recordDisruption(at: t0)
        _ = detector.recordDisruption(at: t0.addingTimeInterval(60))
        XCTAssertTrue(detector.recordDisruption(at: t0.addingTimeInterval(120)))
        XCTAssertFalse(detector.recordDisruption(at: t0.addingTimeInterval(180)),
                       "within the 1-hour cooldown the user is not nagged again")
        // A fight that persists PAST the cooldown (fresh burst of events) notifies again.
        let t2 = t0.addingTimeInterval(2 * 60 * 60)
        _ = detector.recordDisruption(at: t2)
        _ = detector.recordDisruption(at: t2.addingTimeInterval(60))
        XCTAssertTrue(detector.recordDisruption(at: t2.addingTimeInterval(120)),
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

    func testDualCaptureEngagesOnlyInTheExactConfiguration() {
        XCTAssertTrue(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: nil, defaultIsBluetooth: true, hasBuiltIn: true))
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: false, pinnedUID: nil, defaultIsBluetooth: true, hasBuiltIn: true),
            "flag off = byte-identical legacy behavior")
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: "some-mic", defaultIsBluetooth: true, hasBuiltIn: true),
            "an explicit user pin always wins")
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: nil, defaultIsBluetooth: false, hasBuiltIn: true),
            "nothing to consolidate when the default input isn't Bluetooth")
        XCTAssertFalse(DualCapture.shouldEngage(
            flagOn: true, pinnedUID: nil, defaultIsBluetooth: true, hasBuiltIn: false),
            "no built-in mic = no primary track to carry pre-roll")
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
