// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import XCTest
@testable import SpeakFreeLib

// MARK: - Manifest schema

private struct GoldenFixture: Decodable {
    let wav: String
    let description: String?
    let modelSHA: String?
    let properties: [PropertyAssertion]
}

private struct PropertyAssertion: Decodable {
    let kind: String
    let expectedSpokenPeriodEnd: Bool?
    let name: String?
}

// MARK: - Test suite

final class AudioGoldenTests: XCTestCase {

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AudioFixtures")
    }

    private var fixtures: [GoldenFixture] {
        get throws {
            let manifestURL = fixtureDir.appendingPathComponent("manifest.json")
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode([GoldenFixture].self, from: data)
        }
    }

    func test_allFixtures() throws {
        // Pin the synthetic fixture smoke test independently of live user settings.
        var config = Config.defaultConfig
        config.engine = "whisper"
        config.modelSize = "tiny.en"
        config.spokenPunctuation = .hybrid
        config.whisperFallback = FlexBool(false)
        let previousEngine = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"]
        setenv("SPEAKFREE_ENGINE", "whisper", 1)
        defer {
            if let previousEngine { setenv("SPEAKFREE_ENGINE", previousEngine, 1) }
            else { unsetenv("SPEAKFREE_ENGINE") }
        }
        guard Transcriber.modelExists(modelSize: config.modelSize) else {
            throw XCTSkip("Whisper model not installed — skipping audio golden tests")
        }

        for fixture in try fixtures {
            let wavURL = fixtureDir.appendingPathComponent(fixture.wav)
            guard FileManager.default.fileExists(atPath: wavURL.path) else {
                XCTFail("Missing fixture: \(fixture.wav)")
                continue
            }
            let result = try ProcessCommand.run(wavURL: wavURL, config: config)
            for prop in fixture.properties {
                assert(property: prop, result: result, fixture: fixture.wav)
            }
        }
    }

    // MARK: - Property assertion dispatch

    private func assert(property: PropertyAssertion, result: ProcessResult, fixture: String) {
        switch property.kind {

        case "noCommaSpam":
            // No run of ≥4 word-comma pairs in a row in `processed`.
            // Matches the failure class (D) in ISSUE-TAXONOMY.md.
            let spamPattern = #"(?:\b\w+,\s*){4,}"#
            let spamRange = result.processed.range(of: spamPattern, options: .regularExpression)
            XCTAssertNil(spamRange,
                "[\(fixture)] noCommaSpam: comma-spam run found in: \(result.processed)")

        case "noApostropheSpace":
            // No whitespace before an apostrophe mid-word (e.g. "don 't", "I 'm").
            // Artifact from some Whisper versions that tokenize contractions with a space.
            let apostrophePattern = #"\w '\w"#
            let apostropheRange = result.styled.range(of: apostrophePattern, options: .regularExpression)
            XCTAssertNil(apostropheRange,
                "[\(fixture)] noApostropheSpace: apostrophe-space artifact in: \(result.styled)")

        case "spokenCommaConverted":
            XCTAssertTrue(result.processed.contains(","), "[\(fixture)] expected a comma")
            XCTAssertNil(result.processed.range(of: #"\bcomma\b"#,
                options: [.regularExpression, .caseInsensitive]))
            for token in [#"\b(?:one|1)\b"#, #"\b(?:two|2)\b"#, #"\b(?:three|3)\b"#] {
                XCTAssertNotNil(result.processed.range(of: token,
                    options: [.regularExpression, .caseInsensitive]),
                    "[\(fixture)] missing synthetic list item")
            }
            XCTAssertEqual(result.processed.filter { $0 == "," }.count, 2)

        case "spokenPeriodAtEnd":
            if property.expectedSpokenPeriodEnd == true {
                XCTAssertTrue(result.styled.localizedCaseInsensitiveContains("robot"))
                XCTAssertTrue(result.styled.localizedCaseInsensitiveContains("ready"))
                XCTAssertNil(result.styled.range(of: #"\bperiod\b"#,
                    options: [.regularExpression, .caseInsensitive]))
                XCTAssertTrue(result.styled.hasSuffix("."),
                    "[\(fixture)] spokenPeriodAtEnd: expected trailing '.', got: \(result.styled)")
            }

        case "containsName":
            if let name = property.name {
                XCTAssertTrue(
                    result.processed.localizedCaseInsensitiveContains(name),
                    "[\(fixture)] containsName: '\(name)' not found in: \(result.processed)")
            }

        default:
            XCTFail("[\(fixture)] Unknown property kind: \(property.kind)")
        }
    }
}
