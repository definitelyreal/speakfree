import XCTest
@testable import SpeakFreeLib

/// Test-safety (2026-09-25 fix/test-real-config): `Transcriber.findModel` / `.modelExists`
/// probe `Config.configDir` on disk (Transcriber.swift:874) — without an override that reaches
/// the REAL ~/.config/speakfree/models, so results depend on whatever models happen to be
/// installed there. Every test here redirects to an empty scratch dir (2026-06-11 rule).
final class TranscriberFallbackTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-transcriber-fallback-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        scratchDir = nil
        super.tearDown()
    }

    // MARK: - findModel

    func testFindModelReturnsNilForMissingModel() {
        // A model that definitely doesn't exist
        XCTAssertNil(Transcriber.findModel(modelSize: "nonexistent-model-xyz"))
    }

    func testModelExistsMatchesFindModel() {
        let exists = Transcriber.modelExists(modelSize: "nonexistent-model-xyz")
        XCTAssertFalse(exists)
    }

    func testModelExistsConsistentWithFindModel() {
        // Consistency: modelExists should return true iff findModel returns non-nil
        for size in ["tiny.en", "base.en", "small.en", "medium.en", "large-v3"] {
            let found = Transcriber.findModel(modelSize: size)
            let exists = Transcriber.modelExists(modelSize: size)
            XCTAssertEqual(found != nil, exists, "Inconsistency for model '\(size)': findModel=\(found != nil), modelExists=\(exists)")
        }
    }

    // MARK: - findWhisperBinary

    func testFindWhisperBinaryReturnsValidPathOrNil() {
        // If whisper is installed, the path should be a real file
        if let path = Transcriber.findWhisperBinary() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "findWhisperBinary returned \(path) but file does not exist")
        }
        // If nil, that's also acceptable (whisper not installed)
    }

    // MARK: - Transcriber init

    func testTranscriberInitDoesNotLoadModel() {
        // Creating a transcriber should not eagerly load the model
        let transcriber = Transcriber(engine: WhisperEngine(), modelID: "nonexistent-model-xyz", language: "en")
        XCTAssertFalse(transcriber.engine.isLoaded)
    }

    func testSuppressAutoPunctuationDefault() {
        let transcriber = Transcriber(engine: WhisperEngine(), modelID: "base.en", language: "en")
        XCTAssertFalse(transcriber.suppressAutoPunctuation)
    }
}
