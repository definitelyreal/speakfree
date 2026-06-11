import XCTest
@testable import OpenWisprLib

final class SettingsViewModelTests: XCTestCase {

    /// vm.save() writes config.json — redirect to a scratch dir so the suite can
    /// never touch the developer's real ~/.config/speakfree/config.json again.
    /// (A fixture write from this suite caused the 2026-06-11 dictation collapse.)
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    // MARK: - Init from Config

    func testInitLoadsFromConfig() throws {
        let json = """
        {
            "hotkey": {"keyCode": 49, "modifiers": ["cmd", "shift"]},
            "modelSize": "small.en",
            "language": "fr",
            "spokenPunctuation": "hybrid",
            "maxRecordings": 20,
            "toggleMode": true,
            "screenContext": true,
            "rememberWords": false
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        let vm = SettingsViewModel(config: config)

        XCTAssertEqual(vm.hotkeyKeyCode, 49)
        XCTAssertEqual(vm.hotkeyModifiers, ["cmd", "shift"])
        XCTAssertEqual(vm.modelSize, "small.en")
        XCTAssertEqual(vm.language, "fr")
        XCTAssertEqual(vm.punctuationMode, .hybrid)
        XCTAssertEqual(vm.maxRecordings, 20)
        XCTAssertTrue(vm.toggleMode)
        XCTAssertTrue(vm.screenContext)
    }

    // MARK: - Round-trip

    func testToConfigRoundTrips() throws {
        let json = """
        {
            "hotkey": {"keyCode": 36, "modifiers": ["ctrl"]},
            "modelSize": "medium.en",
            "language": "de",
            "spokenPunctuation": true,
            "maxRecordings": 10,
            "toggleMode": false,
            "screenContext": false,
            "rememberWords": true
        }
        """.data(using: .utf8)!
        let original = try Config.decode(from: json)
        let vm = SettingsViewModel(config: original)
        let roundTripped = vm.toConfig()

        XCTAssertEqual(roundTripped.hotkey.keyCode, 36)
        XCTAssertEqual(roundTripped.hotkey.modifiers, ["ctrl"])
        XCTAssertEqual(roundTripped.modelSize, "medium.en")
        XCTAssertEqual(roundTripped.language, "de")
        XCTAssertEqual(roundTripped.spokenPunctuation, .spoken)
        XCTAssertEqual(roundTripped.maxRecordings, 10)
        XCTAssertEqual(roundTripped.toggleMode?.value, false)
        XCTAssertEqual(roundTripped.screenContext?.value, false)
        // rememberWords is deprecated (learner removed) but must still round-trip
        // for config back-compat — it rides along via baseConfig.
        XCTAssertEqual(roundTripped.rememberWords?.value, true)
    }

    // MARK: - Settings save must not drop keys the UI doesn't manage

    func testToConfigPreservesUnmanagedKeys() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "large-v3-turbo",
            "language": "en",
            "preserveAllRecordings": true,
            "reuseStreamingPartial": false,
            "localAPIToken": "secret-token",
            "modelPath": "/custom/model/path.bin"
        }
        """.data(using: .utf8)!
        let original = try Config.decode(from: json)
        let vm = SettingsViewModel(config: original)
        vm.language = "fr"  // simulate the user changing one managed setting
        let saved = vm.toConfig()

        XCTAssertEqual(saved.language, "fr")
        XCTAssertEqual(saved.preserveAllRecordings?.value, true)
        XCTAssertEqual(saved.reuseStreamingPartial?.value, false)
        XCTAssertEqual(saved.localAPIToken, "secret-token")
        XCTAssertEqual(saved.modelPath, "/custom/model/path.bin")
    }

    // MARK: - Default values for nil optionals

    func testInitDefaultsNilOptionals() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        let vm = SettingsViewModel(config: config)

        // nil spokenPunctuation defaults to .hybrid (matching defaultConfig)
        XCTAssertEqual(vm.punctuationMode, .hybrid)
        // nil maxRecordings defaults to 0 = keep everything
        XCTAssertEqual(vm.maxRecordings, 0)
        // nil toggleMode defaults to false
        XCTAssertFalse(vm.toggleMode)
        // nil screenContext defaults to false (shipped: SettingsViewModel uses `?? false`)
        XCTAssertFalse(vm.screenContext)
    }

    // MARK: - Model description helpers

    func testModelMemoryDescription() {
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("tiny.en"), "~230 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("tiny"), "~230 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("base.en"), "~330 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("base"), "~330 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("small.en"), "~800 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("small"), "~800 MB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("medium.en"), "~2.1 GB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("medium"), "~2.1 GB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("large-v3"), "~3.9 GB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("large"), "~3.9 GB")
        XCTAssertEqual(SettingsViewModel.modelMemoryDescription("unknown"), "Unknown")
    }

    func testModelSpeedDescription() {
        XCTAssertEqual(SettingsViewModel.modelSpeedDescription("tiny.en"), "~0.6s")
        XCTAssertEqual(SettingsViewModel.modelSpeedDescription("base.en"), "~0.6s")
        XCTAssertEqual(SettingsViewModel.modelSpeedDescription("small.en"), "~0.6s")
        XCTAssertEqual(SettingsViewModel.modelSpeedDescription("medium.en"), "~1.3s")
        XCTAssertEqual(SettingsViewModel.modelSpeedDescription("large-v3"), "~2.1s")
        XCTAssertEqual(SettingsViewModel.modelSpeedDescription("unknown"), "Unknown")
    }

    // MARK: - Save callback

    func testSaveCallsOnSaveCallback() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        let vm = SettingsViewModel(config: config)

        var callbackCalled = false
        vm.onSave = { callbackCalled = true }
        vm.save()

        XCTAssertTrue(callbackCalled)
    }
}
