// Claude · 2026-08-12 · Session: 9bb7d552-ac60-4aeb-b987-841018c752be
import XCTest
@testable import SpeakFreeLib

/// Locks the "option C" Spoken Only fix (2026-08-12): Spoken Only now runs the SAME guarded
/// substitution as Automatic & Spoken. The only intended difference is that Spoken Only suppresses
/// the engine's own auto-punctuation (an upstream Transcriber flag), which does not touch the text
/// pipeline. So through TextPipeline, .spoken and .hybrid must produce byte-identical text for any
/// given raw transcript.
final class SpokenModeGuardsTests: XCTestCase {

    private func processed(_ raw: String, _ mode: PunctuationMode) -> String {
        TextPipeline.run(TextPipeline.Input(raw: raw, punctuationMode: mode)).processedText
    }

    // MARK: - Card table (Spoken Only)

    func test_spoken_alwaysReplace_questionMark() {
        let out = processed("what time is it question mark", .spoken)
        XCTAssertTrue(out.hasSuffix("?"), "spoken 'question mark' → '?': \(out)")
        XCTAssertFalse(out.lowercased().contains("question mark"),
                       "the spoken command must be consumed: \(out)")
    }

    func test_spoken_periodOfTime_survivesUnchanged() {
        // The exact regression that option C fixes: the old unguarded spokenFallback made this
        // "a. Of time". The guarded path skips "period" before "of".
        XCTAssertEqual(processed("a period of time", .spoken), "a period of time")
    }

    func test_spoken_colonCancer_survivesUnchanged() {
        // Old unguarded spoken → ": cancer". Guarded path skips "colon" before "cancer".
        XCTAssertEqual(processed("colon cancer is treatable", .spoken), "colon cancer is treatable")
    }

    func test_spoken_spokenCommas_convert() {
        XCTAssertEqual(processed("I met Bob comma Alice comma and Carol", .spoken),
                       "I met Bob, Alice, and Carol")
    }

    // MARK: - Spoken == Hybrid word-handling (only engine auto-punct suppression differs,
    // and that is upstream of the text pipeline)

    func test_spokenEqualsHybrid_onSharedBattery() {
        let battery = [
            "what time is it question mark",
            "a period of time",
            "colon cancer is treatable",
            "I met Bob comma Alice comma and Carol",
            "hello period",
            "one comma two",
            "note colon",
            "wow exclamation mark",
            "I met Kamala today",
            "that is good karma",
            "we discussed the Oxford comma",
            "I need to track my period",
            "things like comma San Francisco",
            "first semicolon second",
            "he said open quote hello close quote",
            "new line please and new paragraph now",
        ]
        for raw in battery {
            let spoken = processed(raw, .spoken)
            let hybrid = processed(raw, .hybrid)
            XCTAssertEqual(spoken, hybrid,
                           "Spoken Only and Automatic & Spoken must handle words identically for " +
                           "raw=\"\(raw)\" — spoken=\"\(spoken)\" hybrid=\"\(hybrid)\"")
        }
    }

    // MARK: - Parakeet: the two modes coincide (suppression is a no-op there)

    /// On Parakeet the engine still emits its own punctuation (no suppression), and .spoken and
    /// .hybrid share the guarded substitution, so the SAME raw yields the SAME text in both modes.
    /// Simulated by feeding a raw that carries engine punctuation (as Parakeet would).
    func test_parakeetLikeRaw_spokenEqualsHybrid() {
        let raw = "I went to the store. It was closed comma so I left."
        XCTAssertEqual(processed(raw, .spoken), processed(raw, .hybrid))
    }
}
