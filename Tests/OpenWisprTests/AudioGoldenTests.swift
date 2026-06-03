import XCTest
@testable import OpenWisprLib

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
        // Skip if no whisper model is installed (CI without models).
        guard Transcriber.modelExists(modelSize: Config.load().modelSize) else {
            throw XCTSkip("Whisper model not installed — skipping audio golden tests")
        }

        for fixture in try fixtures {
            let wavURL = fixtureDir.appendingPathComponent(fixture.wav)
            guard FileManager.default.fileExists(atPath: wavURL.path) else {
                XCTFail("Missing fixture: \(fixture.wav)")
                continue
            }
            let result = try ProcessCommand.run(wavURL: wavURL)
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

        case "spokenPeriodAtEnd":
            if property.expectedSpokenPeriodEnd == true {
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
