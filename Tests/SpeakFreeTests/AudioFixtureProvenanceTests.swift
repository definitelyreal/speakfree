// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import CryptoKit
import XCTest
@testable import SpeakFreeLib

final class AudioFixtureProvenanceTests: XCTestCase {
    private let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("AudioFixtures")

    func test_manifestHashesAndMinimalPCMContainersMatch() throws {
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [[String: Any]])
        XCTAssertEqual(manifest.count, 4)
        for fixture in manifest {
            let name = try XCTUnwrap(fixture["wav"] as? String)
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, fixture["sha256"] as? String, name)
            XCTAssertEqual(fixture["provenance"] as? String, "ai-suggestion:unverified")
            XCTAssertFalse(try XCTUnwrap(fixture["sourceText"] as? String).isEmpty)
            // The canonical writer emits only fmt/data, with no embedded artist/location tags.
            guard data.count >= 44 else { return XCTFail("Truncated WAV: \(name)") }
            XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
            XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
            XCTAssertEqual(Array(data[16..<20]), [16, 0, 0, 0])
            XCTAssertEqual(Array(data[20..<24]), [1, 0, 1, 0]) // PCM, mono
            XCTAssertEqual(Array(data[24..<28]), [128, 62, 0, 0]) // 16 kHz
            XCTAssertEqual(Array(data[34..<36]), [16, 0]) // 16 bit
            XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
            let count = try XCTUnwrap(fixture["sampleCount"] as? Int)
            XCTAssertEqual(data.count, 44 + count * 2, name)
        }
    }

    func test_silenceCanaryContainsIdenticalSpeechAndExactly400MillisecondsOfZeros() throws {
        let speech = try ProcessCommand.loadSamples(from:
            directory.appendingPathComponent("fixture-3-spoken-period-end.wav"))
        let padded = try ProcessCommand.loadSamples(from:
            directory.appendingPathComponent("fixture-4-trailing-silence-period.wav"))
        XCTAssertEqual(padded.count, speech.count + 6400)
        XCTAssertEqual(Array(padded.prefix(speech.count)), speech)
        XCTAssertTrue(padded.suffix(6400).allSatisfy { $0 == 0 })
    }
}
