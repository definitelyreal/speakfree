// Claude · 2026-08-12 · Session: 9bb7d552-ac60-4aeb-b987-841018c752be
import XCTest
@testable import SpeakFreeLib

/// Pins the single shared resolution of a missing `spokenPunctuation` key
/// (Michael's ruling 2026-08-12: "build the shared function and align the CLI").
///
/// The drift this ends: four sites resolved the missing key independently, ProcessCommand
/// said `.hybrid` while the app said `.off`, and Settings once displayed "Automatic &
/// Spoken" for configs whose dictation actually ran "Automatic Only".
final class PunctuationModeResolutionTests: XCTestCase {

    private func config(spokenPunctuation: PunctuationMode?) -> Config {
        var c = Config.defaultConfig
        c.spokenPunctuation = spokenPunctuation
        return c
    }

    func testMissingKeyResolvesToAutomaticOnly() {
        XCTAssertEqual(config(spokenPunctuation: nil).effectivePunctuationMode, .off,
                       "a config predating the key must keep its historical behavior")
    }

    func testExplicitValuesPassThroughUnchanged() {
        for mode in [PunctuationMode.off, .hybrid, .spoken] {
            XCTAssertEqual(config(spokenPunctuation: mode).effectivePunctuationMode, mode)
        }
    }

    /// The structural half: no production file may reintroduce a site-local `??` default
    /// on `spokenPunctuation` — that is exactly how the display-vs-runtime and CLI-vs-app
    /// drift happened. Only Config.swift (the shared property itself) may resolve it.
    func testNoSiteLocalDefaultsRemainInProductionSources() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourcesDir = testsDir
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/SpeakFreeLib")
        let files = try FileManager.default.contentsOfDirectory(at: sourcesDir,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Config.swift" }
        XCTAssertGreaterThan(files.count, 10, "source scan must actually see the library")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("spokenPunctuation ??"),
                           "\(file.lastPathComponent) resolves spokenPunctuation locally — "
                           + "use config.effectivePunctuationMode instead")
        }
    }
}
