// Claude · 2026-09-25 · Session: agent-a9177db3
//
// 2026-09-25 ruling: "Kama" is not a name in practice. Parakeet hears the spoken word "comma" as
// "Kama". The punctuation-preceded shapes were already converted; the leftovers were the ones
// with no pause before the word ("Hey Kama, are y'all…", "…with Priya Kama. If you…"), which an
// earlier pass wrongly read as a person's name. Standalone "Kama" is now a comma in every mode
// that converts spoken punctuation. Inputs below are synthetic sentences built to the same
// shapes as the archive failures.

import XCTest
@testable import SpeakFreeLib

final class KamaCommaTests: XCTestCase {

    private func hybrid(_ text: String) -> String {
        TextPostProcessor.process(text, hybrid: true)
    }

    // MARK: - Standalone Kama converts

    func test_vocativeShapeBecomesComma() {
        XCTAssertEqual(hybrid("Hey Kama how are you"), "Hey, how are you")
        XCTAssertEqual(hybrid("Hey Kama, are y'all going to the museum with Rosa on Sunday?"),
                       "Hey, are y'all going to the museum with Rosa on Sunday?")
        XCTAssertEqual(hybrid("Hey Kama, do you know anyone who is pretty good at fixing bikes?"),
                       "Hey, do you know anyone who is pretty good at fixing bikes?")
    }

    /// The spoken comma outranks the engine's period after it, and the capital it left behind
    /// is lowered, as for the punctuation-preceded family ("unreal. Kama have" -> "unreal, have").
    func test_nameThenKamaPeriodBecomesComma() {
        XCTAssertEqual(
            hybrid("I just had a lunch with Priya Kama. If you can get it from the notes, please do so."),
            "I just had a lunch with Priya, if you can get it from the notes, please do so.")
    }

    func test_anyCase() {
        XCTAssertEqual(hybrid("Hey KAMA how are you"), "Hey, how are you")
        XCTAssertEqual(hybrid("Hey kama how are you"), "Hey, how are you")
    }

    func test_utteranceFinalKama() {
        XCTAssertEqual(hybrid("Thanks so much Kama."), "Thanks so much,")
    }

    func test_doubledPunctuationIsCollapsed() {
        XCTAssertEqual(hybrid("Hey, Kama, how are you"), "Hey, how are you")
        XCTAssertEqual(hybrid("Okay. Kama. So let's go"), "Okay, so let's go")
        XCTAssertEqual(hybrid("Hey Kama, , how are you"), "Hey, how are you")
    }

    /// Review round 1: opening the utterance, there is nothing for a comma to follow, so the
    /// garble is dropped instead of leaving a leading ",".
    func test_utteranceInitialKamaIsDropped() {
        XCTAssertEqual(hybrid("Kama let's go now"), "Let's go now")
        XCTAssertEqual(hybrid("Kama, what are you talking about?"), "What are you talking about?")
        XCTAssertEqual(hybrid("kama so we ship it"), "so we ship it")
        // The whole non-word family behaves the same at the start.
        XCTAssertEqual(hybrid("Kamma so we ship it"), "So we ship it")
    }

    /// A dictation that is only the garble is a spoken comma, like a correctly heard "Comma."
    func test_loneKamaIsAComma() {
        XCTAssertEqual(hybrid("Kama."), ",")
        XCTAssertEqual(hybrid("Kama"), ",")
    }

    func test_kamaRiverKeepsItsWord() {
        XCTAssertEqual(hybrid("We sailed down the Kama river"), "We sailed down the Kama river")
    }

    func test_kaimaStandaloneBecomesComma() {
        XCTAssertEqual(hybrid("going to the market Kaima, so they are right in that row."),
                       "going to the market, so they are right in that row.")
    }

    // MARK: - What stays

    func test_realPhraseAndPossessiveStay() {
        XCTAssertEqual(hybrid("I read the Kama Sutra last year"), "I read the Kama Sutra last year")
        XCTAssertEqual(hybrid("That was Kama's idea"), "That was Kama's idea")
        XCTAssertEqual(hybrid("the kamala harris speech"), "the kamala harris speech")
    }

    /// Protected near-homophones that are plausible names: Kamo, Karma, kima. None may join the
    /// standalone rule.
    func test_protectedNamesStay() {
        XCTAssertEqual(hybrid("Okay, Kamo, yeah, I love that."), "Okay, Kamo, yeah, I love that.")
        XCTAssertEqual(hybrid("Hey Karma, are you free now?"), "Hey Karma, are you free now?")
        XCTAssertEqual(hybrid("Hey Karma how are you"), "Hey Karma how are you")
        XCTAssertEqual(hybrid("Kima way less busy these days."), "Kima way less busy these days.")
        XCTAssertEqual(hybrid("Ask kima about it"), "Ask kima about it")
    }

    // MARK: - Sibling garbles decided from the archive

    func test_comboPunctuatedOnBothSidesBecomesComma() {
        XCTAssertEqual(hybrid("It seems like a small risk. Combo, but at the same time it works."),
                       "It seems like a small risk, but at the same time it works.")
        XCTAssertEqual(hybrid("Plates and napkins, combo, okay, you need to go into this."),
                       "Plates and napkins, okay, you need to go into this.")
    }

    func test_comboAsNounStays() {
        for input in ["I ordered the combo, and it was great.",
                      "The burger combo is cheap.",
                      "That combo of colors works.",
                      "I got the burger, combo, and a drink.",
                      "We had the number three. Combo, please."] {
            XCTAssertEqual(hybrid(input), input)
        }
    }

    func test_cometBeforeCommaBecomesComma() {
        XCTAssertEqual(hybrid("A little bit smaller comet, it fits in the box better."),
                       "A little bit smaller, it fits in the box better.")
        XCTAssertEqual(hybrid("smooth out the gaps between them comet, not necessarily all of it"),
                       "smooth out the gaps between them, not necessarily all of it")
    }

    func test_cometAsNounStays() {
        for input in ["We saw the comet, it was bright.",
                      "There was a bright comet, then clouds.",
                      "Halley's comet, famously, returns.",
                      "We saw Halley comet, it was bright.",
                      "The ISON comet, it broke up.",
                      "I'll open Comet, then go to settings.",
                      "It was a shooting star or comet, I'm not sure.",
                      "The comet was bright."] {
            XCTAssertEqual(hybrid(input), input)
        }
    }

    /// "gamma" stays: a gamma rule was ruled out on 2026-08-20, because it is a real word in
    /// color grading ("changing the gamma").
    func test_gammaStays() {
        XCTAssertEqual(hybrid("It's way too slow. Gamma could be a bit less."),
                       "It's way too slow. Gamma could be a bit less.")
    }

    // MARK: - Modes, through the whole pipeline

    /// Both modes that convert spoken punctuation convert standalone Kama, even when an old
    /// "kama" -> "Karma" override is still in someone's overrides file. Off leaves it.
    func test_pipelineModes() {
        let overrides = ["kama": "Karma"]
        for mode in [PunctuationMode.hybrid, .spoken] {
            let out = TextPipeline.run(
                TextPipeline.Input(raw: "Hey Kama how are you", punctuationMode: mode,
                                   overrides: overrides),
                isRealWord: { _ in true }).finalText
            XCTAssertFalse(out.lowercased().contains("kama") || out.contains("Karma"),
                           "\(mode): \(out)")
            XCTAssertTrue(out.hasPrefix("Hey,"), "\(mode): \(out)")
        }
    }
}
