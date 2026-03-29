import XCTest
@testable import OpenWisprLib

final class ConfigPersistenceTests: XCTestCase {

    // MARK: - Full round-trip

    func testAllFieldsRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 55, modifiers: ["cmd", "shift"]),
            modelPath: nil,
            modelSize: "medium.en",
            language: "fr",
            spokenPunctuation: .hybrid,
            maxRecordings: 42,
            toggleMode: FlexBool(true),
            screenContext: FlexBool(true),
            rememberWords: FlexBool(true)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(decoded.hotkey.keyCode, 55)
        XCTAssertEqual(decoded.hotkey.modifiers, ["cmd", "shift"])
        XCTAssertEqual(decoded.modelSize, "medium.en")
        XCTAssertEqual(decoded.language, "fr")
        XCTAssertEqual(decoded.spokenPunctuation, .hybrid)
        XCTAssertEqual(decoded.maxRecordings, 42)
        XCTAssertEqual(decoded.toggleMode?.value, true)
        XCTAssertEqual(decoded.screenContext?.value, true)
        XCTAssertEqual(decoded.rememberWords?.value, true)
    }

    // MARK: - Empty modifiers

    func testEmptyModifiersRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(decoded.hotkey.modifiers, [])
        XCTAssertEqual(decoded.hotkey.keyCode, 63)
    }

    // MARK: - Missing optional fields decode gracefully

    func testMissingOptionalsDecodeWithoutCrash() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "small.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)

        XCTAssertNil(config.modelPath)
        XCTAssertNil(config.spokenPunctuation)
        XCTAssertNil(config.maxRecordings)
        XCTAssertNil(config.toggleMode)
        XCTAssertNil(config.screenContext)
        XCTAssertNil(config.rememberWords)
        XCTAssertNil(config.preBuffer)
        XCTAssertNil(config.keepModelLoaded)
    }

    // MARK: - Corrupted JSON does not crash

    func testCorruptedJSONThrowsInsteadOfCrashing() {
        let garbage = "{ this is not valid json at all }}}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: garbage))
    }

    func testPartiallyCorruptedJSON() {
        // Valid JSON structure but wrong types
        let badTypes = """
        {
            "hotkey": "not an object",
            "modelSize": 12345,
            "language": true
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: badTypes))
    }

    func testEmptyJSONObjectMissingRequiredFields() {
        let empty = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: empty))
    }

    // MARK: - All three punctuation modes round-trip

    func testPunctuationModeOffRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en",
            spokenPunctuation: .off
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.spokenPunctuation, .off)
    }

    func testPunctuationModeSpokenRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en",
            spokenPunctuation: .spoken
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.spokenPunctuation, .spoken)
    }

    func testPunctuationModeHybridRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en",
            spokenPunctuation: .hybrid
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.spokenPunctuation, .hybrid)
    }

    // MARK: - keepModelLoaded round-trip

    func testKeepModelLoadedRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en",
            keepModelLoaded: "always"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.keepModelLoaded, "always")
    }

    func testKeepModelLoadedOffRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en",
            keepModelLoaded: "off"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.keepModelLoaded, "off")
    }

    func testKeepModelLoadedNilWhenMissing() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "small.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertNil(config.keepModelLoaded)
    }

    // MARK: - preBuffer round-trip

    func testPreBufferRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: nil,
            modelSize: "base.en",
            language: "en",
            preBuffer: FlexBool(false)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.preBuffer?.value, false)
    }

    func testPreBufferNilWhenMissing() throws {
        let json = """
        {
            "hotkey": {"keyCode": 63, "modifiers": []},
            "modelSize": "small.en",
            "language": "en"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertNil(config.preBuffer)
    }

    // MARK: - modelPath round-trip

    func testModelPathRoundTrip() throws {
        let config = Config(
            hotkey: HotkeyConfig(keyCode: 63, modifiers: []),
            modelPath: "/custom/path/to/model.bin",
            modelSize: "base.en",
            language: "en"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.modelPath, "/custom/path/to/model.bin")
    }
}
