import XCTest
@testable import SpeakFreeLib

/// Key Mode migration must be lossless in BOTH directions: a legacy `toggleMode`-only config keeps
/// its exact behavior, a keyMode-only config resolves correctly, and a keyMode-nil config
/// round-trips with the key ABSENT (never `"keyMode": null`). This is the zero-behavior-change gate
/// for every existing hold/toggle user.
final class KeyModeTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-keymode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    // MARK: - Codable matrix (legacy bool only / new key only / both / neither)

    func testLegacyToggleBoolOnly() throws {
        let c = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en","toggleMode":true}
        """)
        XCTAssertNil(c.keyMode, "no keyMode key on disk")
        XCTAssertEqual(c.effectiveKeyMode, .toggle, "legacy toggleMode:true resolves to .toggle")
    }

    func testLegacyToggleBoolFalse() throws {
        let c = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en","toggleMode":false}
        """)
        XCTAssertNil(c.keyMode)
        XCTAssertEqual(c.effectiveKeyMode, .hold)
    }

    func testNewKeyOnly() throws {
        let c = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en","keyMode":"edit"}
        """)
        XCTAssertEqual(c.keyMode, .edit)
        XCTAssertEqual(c.effectiveKeyMode, .edit)
    }

    func testBothKeys_keyModeWins() throws {
        // keyMode is authoritative when both are present; the stale toggleMode is ignored.
        let c = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en","toggleMode":true,"keyMode":"edit"}
        """)
        XCTAssertEqual(c.effectiveKeyMode, .edit)
    }

    func testNeitherKey() throws {
        let c = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en"}
        """)
        XCTAssertNil(c.keyMode)
        XCTAssertEqual(c.effectiveKeyMode, .hold, "the default is Hold")
    }

    // MARK: - Lenient decode (forward-compat)

    func testUnknownKeyModeValueDegradesToHoldWithoutThrowing() throws {
        // A value written by a future build must not fail the whole Config decode.
        let c = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en","keyMode":"telepathy"}
        """)
        XCTAssertEqual(c.effectiveKeyMode, .hold)
        XCTAssertEqual(c.modelSize, "base.en", "the rest of the config still decoded")
    }

    // MARK: - Round-trip

    func testNilKeyModeRoundTripsAbsent() throws {
        var c = Config.defaultConfig
        c.keyMode = nil
        let data = try JSONEncoder().encode(c)
        let jsonString = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(jsonString.contains("keyMode"),
                       "a nil keyMode must not appear on disk (not even as null)")
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertNil(decoded.keyMode)
    }

    func testEachKeyModeRoundTrips() throws {
        for mode in [KeyMode.hold, .toggle, .edit] {
            var c = Config.defaultConfig
            c.keyMode = mode
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            XCTAssertEqual(decoded.keyMode, mode)
        }
    }

    func testKeyModeEncodesAsBareString() throws {
        var c = Config.defaultConfig
        c.keyMode = .edit
        let jsonString = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertTrue(jsonString.contains("\"keyMode\" : \"edit\"")
                        || jsonString.contains("\"keyMode\":\"edit\""),
                      "keyMode serializes as the raw string 'edit'")
    }

    // MARK: - Settings view-model sync (toConfig writes BOTH keys, synced)

    func testToConfigSyncsToggleModeFromKeyMode() throws {
        let vm = SettingsViewModel(config: Config.defaultConfig)

        vm.keyMode = .edit
        var out = vm.toConfig()
        XCTAssertEqual(out.keyMode, .edit)
        XCTAssertEqual(out.toggleMode?.value, false, "Edit downgrades to Toggle=false for legacy readers")

        vm.keyMode = .toggle
        out = vm.toConfig()
        XCTAssertEqual(out.keyMode, .toggle)
        XCTAssertEqual(out.toggleMode?.value, true)

        vm.keyMode = .hold
        out = vm.toConfig()
        XCTAssertEqual(out.keyMode, .hold)
        XCTAssertEqual(out.toggleMode?.value, false)
    }

    func testViewModelInitResolvesEffectiveKeyMode() throws {
        // A legacy toggleMode:true config with no keyMode surfaces as .toggle in the picker.
        let legacy = try decode("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base.en","language":"en","toggleMode":true}
        """)
        XCTAssertEqual(SettingsViewModel(config: legacy).keyMode, .toggle)
    }

    func testViewModelSaveThenReloadKeepsEditMode() throws {
        let vm = SettingsViewModel(config: Config.defaultConfig)
        vm.keyMode = .edit
        vm.save()  // writes into the scratch config dir
        let reloaded = Config.load()
        XCTAssertEqual(reloaded.effectiveKeyMode, .edit)
        XCTAssertEqual(reloaded.keyMode, .edit)
    }
}
