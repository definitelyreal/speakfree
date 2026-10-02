// ai-suggestion:unverified · session:unknown · 2026-08-24
import FluidAudio
import XCTest
@testable import SpeakFreeLib

private final class PunctuationModeSpyEngine: ConfidencePunctuationCorrectingEngine {
    let engineID = "mode-spy"
    let supportsStreaming = false
    let supportsPrompt = false
    var keepModelLoaded = "auto"
    var isLoaded = true
    private(set) var correctionFlags: [Bool] = []

    func loadModel(modelID: String) async throws {}
    func unloadModel() async {}
    func startMemoryPressureMonitoring() {}

    func transcribe(samples: [Float], language: String, prompt: String?,
                    suppressRegex: String?) async throws -> String {
        XCTFail("Transcriber bypassed the confidence-correcting capability")
        return "ordinary transcript"
    }

    func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                    enablePunctuationCommandCorrection: Bool) async throws -> String {
        correctionFlags.append(enablePunctuationCommandCorrection)
        return "ordinary transcript"
    }

    func transcribeStreaming(samples: [Float], language: String, prompt: String?,
                             suppressRegex: String?,
                             onPartialResult: @escaping (String) -> Void) async throws -> String {
        throw TranscriptionEngineError.streamingUnsupported
    }
}

final class PunctuationCommandCorrectorTests: XCTestCase {
    private struct WordSpec {
        let surface: String
        let confidence: Float
        let gap: TimeInterval

        init(_ surface: String, _ confidence: Float = 1, gap: TimeInterval = 0) {
            self.surface = surface
            self.confidence = confidence
            self.gap = gap
        }
    }

    private func timings(_ specs: [WordSpec]) -> [TokenTiming] {
        var end: TimeInterval = 0
        return specs.map { spec in
            let start = end + spec.gap
            end = start + 0.12
            return TokenTiming(token: "▁" + spec.surface, tokenId: 0,
                               startTime: start, endTime: end,
                               confidence: spec.confidence)
        }
    }

    private func correct(_ text: String, _ specs: [WordSpec])
        -> ParakeetEngine.PunctuationCommandCorrectionResult {
        ParakeetEngine.correctingPunctuationCommandHomophones(
            text: text, timings: timings(specs))
    }

    private func finish(_ text: String) -> String {
        TextPostProcessor.process(text, hybrid: true)
    }

    // MARK: ARM B -- corpus-positive shapes (synthetic wording)

    func testLowOutlierPairedAfterPauseBecomesPeriod() {
        let result = correct("But we could paired. Yeah", [
            WordSpec("But"), WordSpec("we"), WordSpec("could"),
            WordSpec("paired.", 0.381, gap: 0.32), WordSpec("Yeah"),
        ])
        XCTAssertEqual(finish(result.text), "But we could. Yeah")
        XCTAssertEqual(result.corrections.map(\.original), ["paired."])
    }

    func testStudyGammaOutlierAfterPauseBecomesComma() {
        // Ear-labeled case 3: confidence 0.539, 0.24 s gap, take median approximately 1.0.
        let result = correct("cover in this gamma, whether it works", [
            WordSpec("cover"), WordSpec("in"), WordSpec("this"),
            WordSpec("gamma,", 0.539, gap: 0.24), WordSpec("whether"),
            WordSpec("it"), WordSpec("works"),
        ])
        XCTAssertEqual(finish(result.text), "cover in this, whether it works")
    }

    func testStudyComeUsesTwoStrongCommandSignals() {
        // Ear-labeled case 24: "Sure, come, I'd...", confidence 0.349. Boundary plus the
        // candidate's own punctuation clears the stricter collision guard for "come".
        let result = correct("Sure, come, I'd be happy to", [
            WordSpec("Sure,"), WordSpec("come,", 0.349), WordSpec("I'd"),
            WordSpec("be"), WordSpec("happy"), WordSpec("to"),
        ])
        XCTAssertEqual(finish(result.text), "Sure, I'd be happy to")
    }

    func testStudyCountAfterClauseBoundaryBecomesComma() {
        let result = correct("Nadia staying longer. Count my potentially", [
            WordSpec("Nadia"), WordSpec("staying"), WordSpec("longer."),
            WordSpec("Count", 0.484), WordSpec("my"), WordSpec("potentially"),
        ])
        XCTAssertEqual(finish(result.text), "Nadia staying longer, my potentially")
    }

    func testQuestionerAndColumnLexiconEntriesUseTheSameGate() {
        let question = correct("Does that work. Questioner", [
            WordSpec("Does"), WordSpec("that"), WordSpec("work."),
            WordSpec("Questioner", 0.42),
        ])
        XCTAssertEqual(finish(question.text), "Does that work?")

        let column = correct("Yeah, column my replacement", [
            WordSpec("Yeah,"), WordSpec("column", 0.49),
            WordSpec("my"), WordSpec("replacement"),
        ])
        XCTAssertEqual(finish(column.text), "Yeah: my replacement")
    }

    func testArticleInsertionDeletesTheEngineAddedArticle() {
        let result = correct("We should stop an paired.", [
            WordSpec("We"), WordSpec("should"), WordSpec("stop"),
            WordSpec("an"), WordSpec("paired.", 0.40),
        ])
        XCTAssertEqual(finish(result.text), "We should stop.")

        let aResult = correct("We should stop a paired.", [
            WordSpec("We"), WordSpec("should"), WordSpec("stop"),
            WordSpec("a"), WordSpec("paired.", 0.40),
        ])
        XCTAssertEqual(finish(aResult.text), "We should stop.")
    }

    func testGrammaticalArticleNounsNeverBecomeCommands() {
        let cases: [(String, [WordSpec])] = [
            ("This is a common mistake", [WordSpec("This"), WordSpec("is"), WordSpec("a"),
                                           WordSpec("common", 0.30), WordSpec("mistake")]),
            ("This is a column", [WordSpec("This"), WordSpec("is"), WordSpec("a"),
                                  WordSpec("column", 0.30, gap: 0.25)]),
            ("That was a gamma ray", [WordSpec("That"), WordSpec("was"), WordSpec("a"),
                                      WordSpec("gamma", 0.30), WordSpec("ray")]),
            ("He was in a coma", [WordSpec("He"), WordSpec("was"), WordSpec("in"),
                                  WordSpec("a"), WordSpec("coma", 0.30, gap: 0.25)]),
        ]
        for (text, specs) in cases {
            XCTAssertEqual(correct(text, specs).text, text, "article noun changed: \(text)")
        }
    }

    // MARK: ARM B -- false-positive fences

    func testRealWordsWithoutACommandSlotAreUntouchedEvenWhenLowConfidence() {
        let cases: [(String, [WordSpec])] = [
            ("I paired the socks", [WordSpec("I"), WordSpec("paired", 0.30, gap: 0.25), WordSpec("the"), WordSpec("socks")]),
            ("gamma correction matters", [WordSpec("gamma", 0.30, gap: 0.25), WordSpec("correction"), WordSpec("matters")]),
            ("gamma rays travel", [WordSpec("gamma", 0.30, gap: 0.25), WordSpec("rays"), WordSpec("travel")]),
            ("the third column wins", [WordSpec("the"), WordSpec("third"), WordSpec("column", 0.30, gap: 0.25), WordSpec("wins")]),
            ("count the votes", [WordSpec("count", 0.30, gap: 0.25), WordSpec("the"), WordSpec("votes")]),
            ("I paired with Sam", [WordSpec("I"), WordSpec("paired", 0.30, gap: 0.25),
                                   WordSpec("with"), WordSpec("Sam")]),
            ("You can count on me", [WordSpec("You"), WordSpec("can"),
                                     WordSpec("count", 0.30, gap: 0.25),
                                     WordSpec("on"), WordSpec("me")]),
        ]
        for (text, specs) in cases {
            XCTAssertEqual(correct(text, specs).text, text, "false positive: \(text)")
        }
    }

    func testComePhrasalVerbsStayRealWords() {
        for phrase in ["come on", "come up"] {
            let parts = phrase.split(separator: " ").map(String.init)
            let result = correct(phrase, [WordSpec(parts[0], 0.30), WordSpec(parts[1])])
            XCTAssertEqual(result.text, phrase)
        }
    }

    func testLiteralCollisionPhrasesSurviveEvenAtAClauseBoundary() {
        let cases: [(String, [WordSpec])] = [
            ("Okay. Gamma correction matters", [WordSpec("Okay."), WordSpec("Gamma", 0.30),
                                                 WordSpec("correction"), WordSpec("matters")]),
            ("Okay. Gamma rays travel", [WordSpec("Okay."), WordSpec("Gamma", 0.30),
                                         WordSpec("rays"), WordSpec("travel")]),
            ("Okay. Count the votes", [WordSpec("Okay."), WordSpec("Count", 0.30),
                                       WordSpec("the"), WordSpec("votes")]),
            ("Okay. Common sense prevails", [WordSpec("Okay."), WordSpec("Common", 0.30),
                                             WordSpec("sense"), WordSpec("prevails")]),
            ("Okay. Common ground matters", [WordSpec("Okay."), WordSpec("Common", 0.30),
                                              WordSpec("ground"), WordSpec("matters")]),
            ("We reviewed the schema. Column A is required", [
                WordSpec("We"), WordSpec("reviewed"), WordSpec("the"), WordSpec("schema."),
                WordSpec("Column", 0.30), WordSpec("A"), WordSpec("is"), WordSpec("required"),
            ]),
            ("Questionnaire responses arrived", [WordSpec("Questionnaire", 0.30, gap: 0.25),
                                                  WordSpec("responses"), WordSpec("arrived")]),
            ("Pierre arrived today", [WordSpec("Pierre", 0.30, gap: 0.25),
                                      WordSpec("arrived"), WordSpec("today")]),
            ("I left a comment, which explains it", [WordSpec("I"), WordSpec("left"),
                WordSpec("a"), WordSpec("comment,", 0.30, gap: 0.25),
                WordSpec("which"), WordSpec("explains"), WordSpec("it")]),
            ("We used that questionnaire, which worked", [WordSpec("We"), WordSpec("used"),
                WordSpec("that"), WordSpec("questionnaire,", 0.30, gap: 0.25),
                WordSpec("which"), WordSpec("worked")]),
            ("Okay. Come on", [WordSpec("Okay."), WordSpec("Come", 0.30, gap: 0.25),
                               WordSpec("on")]),
        ]
        for (text, specs) in cases {
            XCTAssertEqual(correct(text, specs).text, text, "literal phrase changed: \(text)")
        }
    }

    func testEligibilityUsesImmutableOriginalWordsWithoutCascading() {
        let result = correct("Okay. Count common items", [
            WordSpec("Okay."), WordSpec("Count", 0.30),
            WordSpec("common", 0.30), WordSpec("items"),
        ])
        XCTAssertEqual(finish(result.text), "Okay, common items")
        XCTAssertEqual(result.corrections.map(\.original), ["Count"])
    }

    func testTranscriberPassesExplicitModeEvenWhenHybridPromptWasTruncated() async throws {
        let engine = PunctuationModeSpyEngine()
        let transcriber = Transcriber(engine: engine, modelID: "unused", language: "en")
        let truncatedPrompt = String(repeating: "glossary-term ", count: 100)
        XCTAssertFalse(truncatedPrompt.contains("Spoken punctuation:"))
        let samples = [Float](repeating: 0.1, count: 16_000)
        let url = URL(fileURLWithPath: "/tmp/punctuation-mode-spy.wav")

        _ = try await transcriber.transcribe(
            audioURL: url, samples: samples, prompt: truncatedPrompt, punctuationMode: .off)
        _ = try await transcriber.transcribe(
            audioURL: url, samples: samples, prompt: truncatedPrompt, punctuationMode: .hybrid)

        XCTAssertEqual(engine.correctionFlags, [false, true])
    }

    func testConfidenceMustBeBothAbsoluteLowAndRelativeOutlier() {
        let highAbsolute = correct("Okay. Gamma, next", [
            WordSpec("Okay."), WordSpec("Gamma,", 0.61), WordSpec("next", 1),
        ])
        XCTAssertEqual(highAbsolute.text, "Okay. Gamma, next")

        let notRelative = correct("Okay. Gamma, next", [
            WordSpec("Okay.", 0.70), WordSpec("Gamma,", 0.55), WordSpec("next", 0.70),
        ])
        XCTAssertEqual(notRelative.text, "Okay. Gamma, next")
    }

    func testConfirmedHighConfidenceColumnRemainsVisibleByDesign() {
        // Ear-labeled case 36 is a true colon command, but its 0.898 token confidence violates
        // the mandated loose <0.6 ceiling. Preserve the visible word rather than inventing a
        // false-positive exception; the labeled-set report records this one known false negative.
        let result = correct("Yeah, column my replacement", [
            WordSpec("Yeah,"), WordSpec("column", 0.898),
            WordSpec("my"), WordSpec("replacement"),
        ])
        XCTAssertEqual(result.text, "Yeah, column my replacement")
    }

    func testPunctuationTokenConfidenceDoesNotMakeAWordLookUncertain() {
        let result = ParakeetEngine.correctingPunctuationCommandHomophones(
            text: "Okay. Gamma, next",
            timings: [
                TokenTiming(token: "▁Okay", tokenId: 0, startTime: 0, endTime: 0.1, confidence: 1),
                TokenTiming(token: ".", tokenId: 0, startTime: 0.1, endTime: 0.2, confidence: 0.2),
                TokenTiming(token: "▁Gamma", tokenId: 0, startTime: 0.2, endTime: 0.3, confidence: 0.95),
                TokenTiming(token: ",", tokenId: 0, startTime: 0.3, endTime: 0.4, confidence: 0.1),
                TokenTiming(token: "▁next", tokenId: 0, startTime: 0.4, endTime: 0.5, confidence: 1),
            ])
        XCTAssertEqual(result.text, "Okay. Gamma, next")
    }

    func testVocabularyBoostChangeBeforeCandidateDoesNotBreakTimingAlignment() {
        // Timing text has the pre-boost "Errik" while the text reaching this pass has "Erik".
        // The later gamma must still align and correct; a greedy aligner lost every word after
        // the first mismatch.
        let result = ParakeetEngine.correctingPunctuationCommandHomophones(
            text: "Erik said okay. Gamma, next",
            timings: timings([
                WordSpec("Errik"), WordSpec("said"), WordSpec("okay."),
                WordSpec("Gamma,", 0.42), WordSpec("next"),
            ]))
        XCTAssertEqual(finish(result.text), "Erik said okay, next")
    }

    func testClauseBoundaryInsideClosingQuoteIsConsumed() {
        let result = correct("He said \"okay.\" Gamma, next", [
            WordSpec("He"), WordSpec("said"), WordSpec("\"okay.\""),
            WordSpec("Gamma,", 0.42), WordSpec("next"),
        ])
        XCTAssertEqual(finish(result.text), "He said \"okay\", next")
        XCTAssertEqual(result.text, "He said \"okay\", next",
                       "engine output itself must not retain whitespace before punctuation")
    }

    // MARK: ARM A -- literal commands, inserted articles, and noun guards

    func testLiteralLeakAfterExistingSymbolCollapsesCleanly() {
        XCTAssertEqual(finish("What does it look like? Question mark."),
                       "What does it look like?")
    }

    func testBareLiteralCommandsStillConvertMidClause() {
        XCTAssertEqual(finish("Use the first option comma then continue"),
                       "Use the first option, then continue")
        XCTAssertEqual(finish("This is final period do not revisit it"),
                       "This is final. Do not revisit it")
    }

    func testLiteralArticleInsertionDropsTheArticle() {
        XCTAssertEqual(finish("hover over a period"), "hover over.")
        XCTAssertEqual(finish("Like a comma"), "Like,")
        XCTAssertEqual(finish("Like a comma, what else would we want"),
                       "Like, what else would we want")
    }

    func testLikeACommaSpecialCaseIsBoundaryAnchoredAndPreservesCase() {
        XCTAssertEqual(finish("like a comma, what else"), "like, what else")
        XCTAssertEqual(finish("It looks like a comma, which is correct"),
                       "It looks like a comma, which is correct")
    }

    func testLiteralNounNegativesRemainUntouched() {
        let cases = [
            "a period of time",
            "the grace period",
            "comma separated values",
            "the question mark is a symbol",
            "question mark as a noun",
            "the word comma",
            "I said period",
            "I said question mark",
            "question mark usage varies",
            "question mark placement varies",
            "I drew a red question mark on the screen",
            "I drew a large exclamation mark on the screen",
            "I drew a bright exclamation mark on the screen",
            "I drew an upside-down question mark on the screen",
            "I drew that bright question mark on the screen",
            "I drew this upside-down question mark on the screen",
            "I drew that bright exclamation mark on the screen",
            "it should have been a comma.",
        ]
        for text in cases {
            XCTAssertEqual(finish(text), text, "literal noun changed: \(text)")
        }
    }

    func testCuratedNonWordAndSplitFormsConvert() {
        let forms = ["kamma", "kalma", "katma", "kanga", "gama", "comam", "comlette"]
        for form in forms {
            XCTAssertEqual(finish("First. \(form), second"), "First, second", "missed \(form)")
        }
        XCTAssertEqual(finish("Yeah, Ka Ma, it also becomes"),
                       "Yeah, it also becomes")
        XCTAssertEqual(finish("Vasco da Gama sailed to India"),
                       "Vasco da Gama sailed to India")
        XCTAssertEqual(finish("Kanga is Roo's mother"), "Kanga is Roo's mother")
        XCTAssertEqual(finish("We studied explorers. Gama sailed to India"),
                       "We studied explorers. Gama sailed to India")
        XCTAssertEqual(finish("We read Pooh. Kanga is Roo's mother"),
                       "We read Pooh. Kanga is Roo's mother")
        XCTAssertEqual(finish("Pooh paused. Kanga, however, continued"),
                       "Pooh paused. Kanga, however, continued")
        XCTAssertEqual(finish("We studied explorers. Gama, however, continued"),
                       "We studied explorers. Gama, however, continued")
    }
}
