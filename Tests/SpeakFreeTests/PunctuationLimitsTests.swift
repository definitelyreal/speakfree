// Claude · 2026-09-25 · Session: 718d5e6d-50b3-4f35-9f63-485e474dadf3
//
// Two known limits of the punctuation pass, fixed at the maintainer's request (2026-09-25):
// 1. "a really bright comet," lost the word "comet": the comet-comma garble rule converted it.
//    It now needs evidence on both sides (see `TextPostProcessor.convertGarbledCometComma`).
// 2. "new line comma" back to back lost the line break: later passes read the break as
//    whitespace before the comma and deleted it. A dictated break now always survives.
// Every probe runs through the whole pipeline in each punctuation mode. The engine paths differ
// only in the raw text they hand over: Parakeet always adds its own punctuation; Whisper adds it
// in Automatic & Spoken and suppresses it in Spoken Only. Both raw shapes are covered.
// All sentences are invented.

import XCTest
@testable import SpeakFreeLib

final class PunctuationLimitsTests: XCTestCase {

    private func run(_ raw: String, _ mode: PunctuationMode) -> String {
        TextPipeline.run(TextPipeline.Input(raw: raw, punctuationMode: mode),
                         isRealWord: { _ in true }).finalText
    }

    private let convertingModes: [PunctuationMode] = [.hybrid, .spoken]

    // MARK: - Limit 1: comet

    /// Engine-punctuated raw (Parakeet in every mode, Whisper in Automatic & Spoken).
    func test_realCometKeepsItsWord_punctuatedRaw() {
        let inputs = [
            "We saw a really bright comet, and then it rained.",
            "We saw a really bright comet, it was huge.",
            "It was a really bright comet, honestly.",
            "Halley's comet, famously, returns.",
            "Halley's comet, It returns every lifetime.",
            "We saw a comet, it was huge.",
            "There was a big ice comet, then clouds.",
            "Look at that comet, it is so bright.",
            "Draw a smaller comet, it fits better.",
            "It was really bright comet, honestly.",
            "We watched the tail of the comet, and then left.",
            "Two comet, maybe three.",
            // Review round 1: degree phrases inside a noun phrase, participles, compounds.
            "We saw a much brighter comet, it was amazing.",
            "We saw a much larger comet, then it faded.",
            "That was a way cooler comet, I think.",
            "It was a lot bigger comet, and everyone saw it.",
            "We saw a little bit bigger comet, it was nice.",
            "a newly discovered comet, it was named.",
            "a recently spotted comet, it was bright.",
            "one newly found comet, it was dim.",
            "Scientists found another sungrazing comet, it broke apart.",
            "Dust and ice comet, that is what it is.",
            "space rock comet, it is called.",
            "The kids watched an ice comet, Dancer said.",
        ]
        for mode in convertingModes + [.off] {
            for input in inputs {
                XCTAssertTrue(run(input, mode).contains("comet"), "\(mode): \(input) -> \(run(input, mode))")
            }
        }
    }

    /// Whisper in Spoken Only suppresses its own punctuation, so the comma never arrives.
    func test_realCometKeepsItsWord_unpunctuatedRaw() {
        for input in ["we saw a really bright comet and then it rained",
                      "a really bright comet"] {
            XCTAssertTrue(run(input, .spoken).contains("comet"), input)
        }
    }

    /// The utterance-final shape the earlier verifier checked: the engine's trailing comma
    /// becomes a period and "comet" stays.
    func test_utteranceFinalCometStays() {
        for mode in convertingModes {
            XCTAssertEqual(run("a really bright comet,", mode), "a really bright comet.")
        }
    }

    /// The garble still converts when both sides agree: no noun phrase before, a clause opener
    /// or a capital after.
    func test_garbleWithEvidenceStillConverts() {
        for mode in convertingModes {
            XCTAssertEqual(run("A little bit smaller comet, it pulls focus away.", mode),
                           "A little bit smaller, it pulls focus away.")
            XCTAssertEqual(run("leave some room between them comet, not all of it", mode),
                           "leave some room between them, not all of it")
            XCTAssertEqual(run("A lot lower comet, then check again.", mode),
                           "A lot lower, then check again.")
            XCTAssertEqual(run("Trim the gap between them comet, Sam will check.", mode),
                           "Trim the gap between them, Sam will check.")
        }
    }

    /// Without right-hand evidence nothing converts, even with no noun phrase before.
    func test_noClauseOpenerAfterStaysLiteral() {
        XCTAssertEqual(run("leave room between them comet, blue sky.", .hybrid),
                       "leave room between them comet, blue sky.")
    }

    func test_offModeNeverConverts() {
        XCTAssertEqual(run("A little bit smaller comet, it pulls focus away.", .off),
                       "A little bit smaller comet, it pulls focus away.")
    }

    // MARK: - Limit 2: line break next to a spoken mark

    func test_newLineComma_keepsBreak_dropsComma() {
        let cases: [(String, String)] = [
            ("first part new line comma second part", "first part\nsecond part"),
            ("First part new line, comma, second part.", "First part\nsecond part."),
            ("First part. New line. Comma, second part.", "First part.\nSecond part."),
            ("First part, new line comma. Second part.", "First part,\nSecond part."),
            ("first part new line comma new line second part", "first part\n\nsecond part"),
        ]
        for mode in convertingModes {
            for (raw, expected) in cases {
                XCTAssertEqual(run(raw, mode), expected, "\(mode): \(raw)")
            }
        }
    }

    func test_newParagraphComma_keepsBreak() {
        for mode in convertingModes {
            XCTAssertEqual(run("first part new paragraph comma second part", mode),
                           "first part\n\nsecond part")
            XCTAssertEqual(run("First part. New paragraph. Comma, second part.", mode),
                           "First part.\n\nSecond part.")
        }
    }

    func test_commaNewLine_keepsBoth() {
        for mode in convertingModes {
            XCTAssertEqual(run("first part comma new line second part", mode),
                           "first part,\nsecond part")
            XCTAssertEqual(run("First part, comma, new line. Second part.", mode),
                           "First part,\nSecond part.")
        }
    }

    func test_periodNewLine_keepsBoth() {
        for mode in convertingModes {
            XCTAssertEqual(run("first part period new line second part", mode),
                           "first part.\nSecond part")
            XCTAssertEqual(run("First part. Period. New line. Second part.", mode),
                           "First part.\nSecond part.")
        }
    }

    /// A sentence mark said after the break moves before it: it still ends the sentence.
    func test_newLinePeriod_movesPeriodBeforeBreak() {
        for mode in convertingModes {
            XCTAssertEqual(run("first part new line period second part", mode),
                           "first part.\nSecond part")
            XCTAssertEqual(run("First part. New line. Period. Second part.", mode),
                           "First part.\nSecond part.")
            XCTAssertEqual(run("first part new line question mark second part", mode),
                           "first part?\nSecond part")
            XCTAssertEqual(run("first part new paragraph period second part", mode),
                           "first part.\n\nSecond part")
        }
    }

    /// At the end of the dictation the break stays in the text; the inserter decides whether
    /// to type a trailing break.
    func test_trailingNewLineComma() {
        for mode in convertingModes {
            XCTAssertEqual(run("first part new line comma", mode), "first part\n")
            XCTAssertEqual(run("first part new line", mode), "first part\n")
        }
    }

    /// A dictation that opens with "new line comma": the comma is dropped, never left as a word.
    func test_openingNewLineComma() {
        for mode in convertingModes {
            XCTAssertEqual(run("New line comma first part", mode), "\nfirst part")
        }
    }

    /// Review round 1: a spoken mark right before a second break keeps both breaks, and the
    /// double-mark and garble rules no longer read a break as a space.
    func test_breaksSurviveNeighbouringRules() {
        let cases: [(String, String)] = [
            ("first part new line comma new line comma second part", "first part\n\nsecond part"),
            ("first part new line period new line period second part", "first part.\n\nSecond part"),
            ("First part, new line comma separated values work.",
             "First part,\ncomma separated values work."),
            ("First part. New line. Period of time passed.", "First part.\nPeriod of time passed."),
            // A spoken comma consumes the mark after it on the same line too ("x comma
            // question mark y" -> "x, y"); here only the break matters.
            ("x new line comma question mark y", "x\ny"),
        ]
        for mode in convertingModes {
            for (raw, expected) in cases {
                XCTAssertEqual(run(raw, mode), expected, "\(mode): \(raw)")
            }
        }
        for raw in ["Hi. New line. Combo, so we go.", "Thanks. New line. Colin. Next",
                    "first part? New line. Quark. Second", "Hello. New line. Questioner second"] {
            XCTAssertTrue(run(raw, .hybrid).contains("\n"), raw)
        }
    }

    /// Review round 2: a final-position garble after a break must not strand its mark on a
    /// line of its own.
    func test_finalGarbleAfterBreak() {
        for mode in convertingModes {
            XCTAssertEqual(run("First part new line question market", mode), "First part?\n")
            XCTAssertEqual(run("First part new line question work", mode), "First part?\n")
        }
    }

    func test_decimalAtLineStartKeepsItsShape() {
        XCTAssertEqual(run("Total new line .5 percent", .hybrid), "Total\n.5 percent")
    }

    /// Unit level: the pass itself.
    func test_placeMarksAfterLineBreak() {
        XCTAssertEqual(TextPostProcessor.placeMarksAfterLineBreak("a\n, b"), "a\nb")
        XCTAssertEqual(TextPostProcessor.placeMarksAfterLineBreak("a\n\n; b"), "a\n\nb")
        XCTAssertEqual(TextPostProcessor.placeMarksAfterLineBreak("a \n. b"), "a.\nb")
        XCTAssertEqual(TextPostProcessor.placeMarksAfterLineBreak("\n. b"), "\nb")
        XCTAssertEqual(TextPostProcessor.placeMarksAfterLineBreak("a\nb, c"), "a\nb, c")
        XCTAssertEqual(TextPostProcessor.placeMarksAfterLineBreak("no break, here."), "no break, here.")
    }
}
