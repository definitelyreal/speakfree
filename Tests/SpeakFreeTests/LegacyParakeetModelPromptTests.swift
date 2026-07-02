import XCTest
@testable import SpeakFreeLib

/// Legacy configs (pre-Parakeet-first) can have engine=parakeet with no
/// `parakeetModel` key. `resolveLegacyParakeetModel` must prompt exactly once
/// (via the `_legacyModelPrompter` seam here — never a real NSAlert in tests),
/// persist the answer, and never prompt when the config already carries an
/// explicit choice. Added with the 2026-07-01 audit remediation.
final class LegacyParakeetModelPromptTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-legacy-prompt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        scratchDir = nil
        super.tearDown()
    }

    private func makeDelegate(parakeetModel: String?) -> AppDelegate {
        let delegate = AppDelegate()
        var config = Config.defaultConfig
        config.engine = "parakeet"
        config.parakeetModel = parakeetModel
        delegate.config = config
        return delegate
    }

    func test_legacyConfigWithoutModel_promptsOnceAndPersists() {
        let delegate = makeDelegate(parakeetModel: nil)
        var promptCount = 0
        delegate._legacyModelPrompter = { _ in
            promptCount += 1
            return "parakeet-tdt-0.6b-v2"
        }

        XCTAssertEqual(delegate.resolveLegacyParakeetModel(), "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(promptCount, 1, "must prompt exactly once for a legacy config")

        // The choice is persisted, so a reloaded config carries it explicitly …
        XCTAssertEqual(Config.load().parakeetModel, "parakeet-tdt-0.6b-v2")
        // … and a second resolution never re-prompts.
        XCTAssertEqual(delegate.resolveLegacyParakeetModel(), "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(promptCount, 1, "explicit choice must suppress further prompts")
    }

    func test_explicitModel_neverPrompts() {
        let delegate = makeDelegate(parakeetModel: "parakeet-tdt-0.6b-v3")
        delegate._legacyModelPrompter = { _ in
            XCTFail("prompt must not fire when parakeetModel is explicit")
            return "parakeet-tdt-0.6b-v2"
        }
        XCTAssertEqual(delegate.resolveLegacyParakeetModel(), "parakeet-tdt-0.6b-v3",
                       "an explicit v3 choice is respected, never silently migrated")
    }

    func test_v3Choice_persistsV3() {
        let delegate = makeDelegate(parakeetModel: nil)
        delegate._legacyModelPrompter = { _ in "parakeet-tdt-0.6b-v3" }
        XCTAssertEqual(delegate.resolveLegacyParakeetModel(), "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(Config.load().parakeetModel, "parakeet-tdt-0.6b-v3")
    }
}
