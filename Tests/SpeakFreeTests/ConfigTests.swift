import XCTest
@testable import SpeakFreeLib

final class ConfigTests: XCTestCase {

    // MARK: - effectiveMaxRecordings

    func testEffectiveMaxRecordingsNilMeansKeepEverything() {
        // Default since 2026-06-11: recordings are kept forever (they are the
        // dictation corpus). Pruning requires an explicit user-set cap.
        XCTAssertEqual(Config.effectiveMaxRecordings(nil), 0)
    }

    func testEffectiveMaxRecordingsZero() {
        XCTAssertEqual(Config.effectiveMaxRecordings(0), 0)
    }

    func testEffectiveMaxRecordingsNegativeMeansKeepEverything() {
        XCTAssertEqual(Config.effectiveMaxRecordings(-5), 0)
    }

    func testEffectiveMaxRecordingsWithinRange() {
        XCTAssertEqual(Config.effectiveMaxRecordings(1), 1)
        XCTAssertEqual(Config.effectiveMaxRecordings(10), 10)
        XCTAssertEqual(Config.effectiveMaxRecordings(100), 100)
    }

    func testEffectiveMaxRecordingsClampsAbove100() {
        XCTAssertEqual(Config.effectiveMaxRecordings(200), 100)
        XCTAssertEqual(Config.effectiveMaxRecordings(999), 100)
    }

    // MARK: - FlexBool decoding

    func testFlexBoolDecodesBool() throws {
        let json = #"{"spokenPunctuation": true}"#.data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(FlexBoolWrapper.self, from: json)
        XCTAssertTrue(wrapper.spokenPunctuation.value)
    }

    func testFlexBoolDecodesStringTrue() throws {
        let json = #"{"spokenPunctuation": "yes"}"#.data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(FlexBoolWrapper.self, from: json)
        XCTAssertTrue(wrapper.spokenPunctuation.value)
    }

    func testFlexBoolDecodesStringFalse() throws {
        let json = #"{"spokenPunctuation": "no"}"#.data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(FlexBoolWrapper.self, from: json)
        XCTAssertFalse(wrapper.spokenPunctuation.value)
    }

    func testFlexBoolDecodesInt() throws {
        let json1 = #"{"spokenPunctuation": 1}"#.data(using: .utf8)!
        let wrapper1 = try JSONDecoder().decode(FlexBoolWrapper.self, from: json1)
        XCTAssertTrue(wrapper1.spokenPunctuation.value)

        let json0 = #"{"spokenPunctuation": 0}"#.data(using: .utf8)!
        let wrapper0 = try JSONDecoder().decode(FlexBoolWrapper.self, from: json0)
        XCTAssertFalse(wrapper0.spokenPunctuation.value)
    }

    // MARK: - Config JSON decoding

    func testConfigDecodesWithMaxRecordings() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en",
            "spokenPunctuation": false,
            "maxRecordings": 5
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertEqual(config.maxRecordings, 5)
        XCTAssertEqual(config.modelSize, "base.en")
    }

    func testConfigDecodesWithoutMaxRecordings() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "small.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertNil(config.maxRecordings)
        // A config that omits maxRecordings keeps everything (0 = no pruning).
        XCTAssertEqual(Config.effectiveMaxRecordings(config.maxRecordings), 0)
    }

    // MARK: - toggleMode decoding

    func testConfigDecodesToggleModeTrue() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en",
            "toggleMode": true
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertEqual(config.toggleMode?.value, true)
    }

    func testConfigDecodesToggleModeFalse() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en",
            "toggleMode": false
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertEqual(config.toggleMode?.value, false)
    }

    func testConfigDecodesWithoutToggleMode() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "base.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertNil(config.toggleMode)
    }

    func testConfigDefaultToggleModeIsFalse() {
        let config = Config.defaultConfig
        XCTAssertEqual(config.toggleMode?.value, false)
    }

    // MARK: - HotkeyConfig modifier flags

    func testModifierFlagsSingle() {
        let config = HotkeyConfig(keyCode: 49, modifiers: ["cmd"])
        XCTAssertEqual(config.modifierFlags, UInt64(1 << 20))
    }

    func testModifierFlagsMultiple() {
        let config = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "shift"])
        let expected = UInt64(1 << 20) | UInt64(1 << 17)
        XCTAssertEqual(config.modifierFlags, expected)
    }

    func testModifierFlagsEmpty() {
        let config = HotkeyConfig(keyCode: 63, modifiers: [])
        XCTAssertEqual(config.modifierFlags, 0)
    }

    func testModifierFlagsIgnoresUnknown() {
        let config = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "bogus"])
        XCTAssertEqual(config.modifierFlags, UInt64(1 << 20))
    }

    // MARK: - Default model

    func testDefaultEngineIsParakeetEnglish() {
        // Product default (Michael, 2026-06-11): new users get Parakeet ENGLISH.
        // v2 = English-only; v3 = multilingual (selected when language != en).
        let config = Config.defaultConfig
        XCTAssertEqual(config.engine, "parakeet")
        XCTAssertEqual(config.parakeetModel, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(Config.defaultEngine, "parakeet")
        XCTAssertEqual(Config.defaultParakeetModel, "parakeet-tdt-0.6b-v2")
    }

    func testDefaultWhisperModelIsLargeV3Turbo() {
        // Whisper default applies when the user switches engine to whisper.
        let config = Config.defaultConfig
        XCTAssertEqual(config.modelSize, "large-v3-turbo")
    }

    // MARK: - Vocabulary provenance-comment parsing

    func testStripInlineComment() {
        XCTAssertEqual(Config.stripInlineComment("Gaubert # brain"), "Gaubert")
        XCTAssertEqual(Config.stripInlineComment("Sari # auto"), "Sari")
        XCTAssertEqual(Config.stripInlineComment("Maryna # contacts"), "Maryna")
        XCTAssertEqual(Config.stripInlineComment("Rohrlich"), "Rohrlich")
        XCTAssertEqual(Config.stripInlineComment("  Bexx  "), "Bexx")
        // Full-line comment returned as-is (caller drops it via hasPrefix("#")).
        XCTAssertEqual(Config.stripInlineComment("# a heading"), "# a heading")
        // Hashes inside a term are not comment markers (no leading space-hash).
        XCTAssertEqual(Config.stripInlineComment("C#"), "C#")
    }

    func testLoadVocabularyStripsProvenanceTags() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Config.configDirOverride = dir
        defer { Config.configDirOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try """
        # heading comment
        Rohrlich
        Gaubert # brain
        Maryna # contacts
        Sari # auto

        """.write(to: Config.vocabularyFile, atomically: true, encoding: .utf8)

        let vocab = Config.loadVocabulary()
        XCTAssertEqual(vocab, "Rohrlich, Gaubert, Maryna, Sari")
    }
}

private struct FlexBoolWrapper: Codable {
    let spokenPunctuation: FlexBool
}
