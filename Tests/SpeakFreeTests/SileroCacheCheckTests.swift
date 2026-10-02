// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Silero endpointing on a Mac without the model cached: FluidAudio is pinned offline, so the
// engine must decide between an offline load (model on disk) and the sanctioned download gate
// (model missing). This pins the existence check that makes that choice. Scratch dirs only.

import XCTest
import FluidAudio
@testable import SpeakFreeLib

final class SileroCacheCheckTests: XCTestCase {

    private lazy var root: URL = {
        let dir = Bundle(for: SileroCacheCheckTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("silero-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeBundle(_ name: String, withData: Bool) throws {
        let dir = root.appendingPathComponent(Repo.vad.folderName).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withData {
            try Data([0]).write(to: dir.appendingPathComponent("coremldata.bin"))
        }
    }

    func test_emptyCache_isMissing() {
        XCTAssertFalse(ParakeetEngine.sileroModelCached(modelsDirectory: root))
    }

    func test_nilDirectory_isMissing() {
        XCTAssertFalse(ParakeetEngine.sileroModelCached(modelsDirectory: nil))
    }

    func test_bundleWithoutCompiledData_isMissing() throws {
        for name in ModelNames.VAD.requiredModels { try makeBundle(name, withData: false) }
        XCTAssertFalse(ParakeetEngine.sileroModelCached(modelsDirectory: root))
    }

    func test_allRequiredBundles_isCached() throws {
        for name in ModelNames.VAD.requiredModels { try makeBundle(name, withData: true) }
        XCTAssertTrue(ParakeetEngine.sileroModelCached(modelsDirectory: root))
    }

    func test_realCacheLayout_matchesFolderName() {
        // The folder FluidAudio downloads Silero into; the check must look in the same place.
        XCTAssertEqual(Repo.vad.folderName, "silero-vad")
    }
}
