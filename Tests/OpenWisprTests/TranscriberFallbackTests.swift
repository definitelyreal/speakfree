import XCTest
@testable import OpenWisprLib

final class TranscriberFallbackTests: XCTestCase {

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
        let transcriber = Transcriber(modelSize: "nonexistent-model-xyz", language: "en")
        XCTAssertFalse(transcriber.engine.isLoaded)
    }

    func testSuppressAutoPunctuationDefault() {
        let transcriber = Transcriber()
        XCTAssertFalse(transcriber.suppressAutoPunctuation)
    }
}
