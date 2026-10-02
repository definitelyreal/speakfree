import XCTest
@testable import SpeakFreeLib

/// The span-edit applier bounds what an untrusted cleanup model can do to a segment: it applies a
/// repair ONLY on a unique exact anchor, never overlapping, never introducing a control char or
/// newline. Every rejection is recorded with a cause. The parser strictly rejects anything that is
/// not the contracted bare JSON array.
final class SpanEditTests: XCTestCase {

    private func edit(_ find: String, _ replace: String, _ reason: String = "r") -> SpanEdit {
        SpanEdit(find: find, replace: replace, reason: reason)
    }

    // MARK: - Applier: matching

    func testUniqueMatchApplies() {
        let r = SpanEditApplier.apply([edit("teh", "the")], to: "teh cat sat")
        XCTAssertEqual(r.text, "the cat sat")
        XCTAssertEqual(r.applied, [edit("teh", "the")])
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testNoMatchRejected() {
        let r = SpanEditApplier.apply([edit("dog", "cat")], to: "teh cat sat")
        XCTAssertEqual(r.text, "teh cat sat", "text unchanged")
        XCTAssertTrue(r.applied.isEmpty)
        XCTAssertEqual(r.rejected.map { $0.cause }, [.noMatch])
    }

    func testAmbiguousMatchRejected() {
        // "at" occurs twice ("cat", "sat"? — "at" appears in both) → not a unique anchor.
        let r = SpanEditApplier.apply([edit("at", "AT")], to: "cat sat")
        XCTAssertEqual(r.text, "cat sat")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.ambiguousMatch])
    }

    func testOverlappingEditsSecondRejected() {
        // Both anchor uniquely, but their matched ranges overlap; the later one is rejected.
        let r = SpanEditApplier.apply([edit("abcd", "X"), edit("bc", "Y")], to: "abcd")
        XCTAssertEqual(r.text, "X")
        XCTAssertEqual(r.applied, [edit("abcd", "X")])
        XCTAssertEqual(r.rejected.map { $0.cause }, [.overlap])
    }

    func testMultipleNonOverlappingEditsAllApply() {
        let r = SpanEditApplier.apply([edit("teh", "the"), edit("kat", "cat")], to: "teh kat")
        XCTAssertEqual(r.text, "the cat")
        XCTAssertEqual(r.applied, [edit("teh", "the"), edit("kat", "cat")])
    }

    func testApplyOrderDoesNotCorruptOffsets() {
        // Two edits where the first-in-text is listed second: applying last-to-first keeps indices valid.
        let r = SpanEditApplier.apply([edit("world", "WORLD"), edit("hello", "HELLO")],
                                      to: "hello world")
        XCTAssertEqual(r.text, "HELLO WORLD")
    }

    // MARK: - Applier: validation

    func testEmptyFindRejected() {
        let r = SpanEditApplier.apply([edit("", "x")], to: "abc")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.emptyFind])
    }

    func testNoOpRejected() {
        let r = SpanEditApplier.apply([edit("abc", "abc")], to: "abc")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.noOp])
        XCTAssertEqual(r.text, "abc")
    }

    func testNewlineInReplacementRejected() {
        let r = SpanEditApplier.apply([edit("x", "a\nb")], to: "x")
        XCTAssertEqual(r.text, "x", "a newline would split the paragraph/segment — rejected, not stripped")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.invalidReplacement])
    }

    func testControlCharInjectionRejected() {
        // A NUL or bell smuggled into the replacement is rejected outright (untrusted output, C6).
        let r = SpanEditApplier.apply([edit("x", "a\u{0007}b")], to: "x")
        XCTAssertEqual(r.text, "x")
        XCTAssertEqual(r.rejected.map { $0.cause }, [.invalidReplacement])
    }

    // MARK: - Applier: unicode + emoji

    func testUnicodeAndEmojiAreValidReplacements() {
        let r = SpanEditApplier.apply([edit("cafe", "café 🎉")], to: "a cafe here")
        XCTAssertEqual(r.text, "a café 🎉 here")
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testEmojiAnchorMatchesUniquely() {
        let r = SpanEditApplier.apply([edit("👍", "👎")], to: "rate this 👍 please")
        XCTAssertEqual(r.text, "rate this 👎 please")
    }

    func testCombiningMarksNotTreatedAsControl() {
        // e + combining acute accent — a mark, not a control char; must be allowed.
        let r = SpanEditApplier.apply([edit("e", "e\u{0301}")], to: "e")
        XCTAssertEqual(r.text, "e\u{0301}")
        XCTAssertTrue(r.rejected.isEmpty)
    }

    // MARK: - Parser

    func testParseBareArray() {
        let out = #"[{"find":"teh","replace":"the","reason":"typo"}]"#
        XCTAssertEqual(SpanEditParser.parse(out), .parsed([edit("teh", "the", "typo")]))
    }

    func testParseBareArrayWithSurroundingWhitespace() {
        let out = "\n  [{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]  \n"
        XCTAssertEqual(SpanEditParser.parse(out), .parsed([edit("a", "b", "c")]))
    }

    func testParseEmptyArrayMeansNoEdits() {
        XCTAssertEqual(SpanEditParser.parse("[]"), .parsed([]))
    }

    func testParseEmptyOutputRejected() {
        XCTAssertEqual(SpanEditParser.parse("   \n  "), .rejected(.empty))
    }

    // Real CLI calls (2026-09-29): Haiku fenced 11 of 12 answers, Sonnet 2 of 12. A whole-output
    // fence is packaging; its body is parsed under the same strict rules.
    func testParseWholeOutputJSONFenceAccepted() {
        let out = "```json\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```"
        XCTAssertEqual(SpanEditParser.parse(out), .parsed([edit("a", "b", "c")]))
    }

    func testParseWholeOutputBareFenceAndTrailingNewlineAccepted() {
        let out = "```\n[\n  {\"find\": \"a\", \"replace\": \"b\", \"reason\": \"c\"}\n]\n```\n"
        XCTAssertEqual(SpanEditParser.parse(out), .parsed([edit("a", "b", "c")]))
    }

    func testParseFencedEmptyArrayMeansNoEdits() {
        XCTAssertEqual(SpanEditParser.parse("```json\n[]\n```"), .parsed([]))
    }

    func testParseProseBeforeFenceRejected() {
        let out = "Here are the fixes:\n```json\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```"
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseProseAfterFenceRejected() {
        let out = "```json\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```\nHope that helps."
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseTwoFencesRejected() {
        let out = "```json\n[]\n```\n```json\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```"
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseOtherLanguageFenceRejected() {
        let out = "```python\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```"
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseFenceWithProseInsideRejected() {
        let out = "```json\nSure: [{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]\n```"
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseUnclosedFenceRejected() {
        let out = "```json\n[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]"
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseProseWrappedRejected() {
        let out = #"Sure! Here are the edits: [{"find":"a","replace":"b","reason":"c"}]"#
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseTrailingProseRejected() {
        let out = #"[{"find":"a","replace":"b","reason":"c"}] hope that helps"#
        XCTAssertEqual(SpanEditParser.parse(out), .rejected(.notJSONArray))
    }

    func testParseMalformedJSONRejected() {
        XCTAssertEqual(SpanEditParser.parse("[this is not, valid json]"), .rejected(.malformed))
    }

    func testParseWrongShapeRejected() {
        // Valid JSON array, but of strings — not {find,replace,reason}.
        XCTAssertEqual(SpanEditParser.parse(#"["a","b"]"#), .rejected(.wrongShape))
    }

    func testParseMissingKeyRejected() {
        // Object missing "reason".
        XCTAssertEqual(SpanEditParser.parse(#"[{"find":"a","replace":"b"}]"#), .rejected(.wrongShape))
    }
}

// Claude · 2026-09-29 · real-call fixes: spoken punctuation must not leave "milk , bread"
final class SpanEditPunctuationSpacingTests: XCTestCase {

    private func edit(_ f: String, _ r: String) -> SpanEdit { SpanEdit(find: f, replace: r, reason: "t") }

    func testCommaReplacingAWordTakesTheSpaceBeforeIt() {
        let app = SpanEditApplier.apply([edit("Kama", ",")], to: "Pick up milk Kama bread.")
        XCTAssertEqual(app.text, "Pick up milk, bread.")
        XCTAssertEqual(app.applied, [edit(" Kama", ",")], "the recorded edit is the one that ran")
    }

    func testCommaWithTrailingSpaceInBothSides() {
        let app = SpanEditApplier.apply([edit("Kama ", ", ")], to: "Pick up milk Kama bread.")
        XCTAssertEqual(app.text, "Pick up milk, bread.")
    }

    func testPeriodAndColonToo() {
        let app = SpanEditApplier.apply([edit("paired.", "."), edit("column", ":")],
                                        to: "It is faster column it opens in a lemon paired.")
        XCTAssertEqual(app.text, "It is faster: it opens in a lemon.")
    }

    func testFindThatAlreadyCarriesTheSpaceIsUnchanged() {
        let app = SpanEditApplier.apply([edit(" Kama", ",")], to: "Milk Kama bread.")
        XCTAssertEqual(app.text, "Milk, bread.")
        XCTAssertEqual(app.applied, [edit(" Kama", ",")])
    }

    func testWordReplacementIsNotWidened() {
        let app = SpanEditApplier.apply([edit("Their", "They're")], to: "So Their going.")
        XCTAssertEqual(app.text, "So They're going.")
    }

    func testNothingBeforeTheWordMeansNoWidening() {
        let app = SpanEditApplier.apply([edit("Kama", ",")], to: "Kama bread.")
        XCTAssertEqual(app.text, ", bread.")
    }

    func testAmbiguousFindIsStillRejected() {
        let app = SpanEditApplier.apply([edit("Kama", ",")], to: "Kama milk Kama bread.")
        XCTAssertEqual(app.rejected.map(\.cause), [.ambiguousMatch])
        XCTAssertEqual(app.text, "Kama milk Kama bread.")
    }

    func testUndoOfAWidenedEditRestoresTheTextExactly() {
        let before = "Pick up milk Kama bread."
        let app = SpanEditApplier.apply([edit("Kama", ",")], to: before)
        let e = app.applied[0]
        let undo = SpanEditApplier.apply([SpanEdit(find: e.replace, replace: e.find, reason: "undo")],
                                         to: app.text)
        XCTAssertEqual(undo.text, before)
    }

    func testPromptTreatsSelfCorrectionAsTheOneException() {
        let prompt = CleanupService.buildPrompt(raw: "r", pipelineText: "p")
        XCTAssertTrue(prompt.contains("SELF-CORRECTIONS ARE THE ONE EXCEPTION"))
        XCTAssertTrue(prompt.contains(#"[{"find": "Tuesday no wait Wednesday", "replace": "Wednesday""#))
        XCTAssertTrue(prompt.contains("Adding commas around the marker is wrong"))
        XCTAssertFalse(prompt.contains("  "), "line continuations must not leave double spaces")
    }
}

// Claude · 2026-09-29 · review round 1 (pass 1 real calls + pass 2 code review)
final class SpanEditReviewRound1Tests: XCTestCase {

    private func e(_ f: String, _ r: String) -> SpanEdit { SpanEdit(find: f, replace: r, reason: "t") }

    // Pass 1, real Sonnet output: fixes anchored on shared neighbouring words.
    func testOverlappingContextFixesAllLandOnARetry() {
        let text = "here is the shopping list column eggs Kama bread Kama and butter"
        let edits = [e("list column eggs", "list: eggs"), e("eggs Kama bread", "eggs, bread"),
                     e("bread Kama and butter", "bread, and butter")]
        let app = SpanEditApplier.apply(CleanupFaithfulness.screen(edits).kept, to: text)
        XCTAssertEqual(app.text, "here is the shopping list: eggs, bread, and butter")
        XCTAssertEqual(app.applied, edits, "all three ran, in proposal order")
        XCTAssertTrue(app.rejected.isEmpty)
    }

    func testRetryStillRequiresAUniqueMatch() {
        // The second fix's anchor is gone after the first one: rejected as overlap, text safe.
        let app = SpanEditApplier.apply([e("Tuesday no wait Wednesday", "Wednesday"),
                                         e("no wait Wednesday at six", "Wednesday at six")],
                                        to: "Meet Tuesday no wait Wednesday at six.")
        XCTAssertEqual(app.text, "Meet Wednesday at six.")
        XCTAssertEqual(app.rejected.map(\.cause), [.overlap])
    }

    func testDotNetAndDecimalsAreNotGluedToThePreviousWord() {
        XCTAssertEqual(SpanEditApplier.apply([e("dot net", ".NET")], to: "I use dot net daily").text,
                       "I use .NET daily")
        XCTAssertEqual(SpanEditApplier.apply([e("point five", ".5")], to: "it costs point five dollars").text,
                       "it costs .5 dollars")
    }

    func testEllipsisAndSentenceBreakStillAttach() {
        XCTAssertEqual(SpanEditApplier.apply([e("dot dot dot", "...")], to: "and then dot dot dot").text,
                       "and then...")
        XCTAssertEqual(SpanEditApplier.apply([e("paired then", ". Then")], to: "the lemon paired then go").text,
                       "the lemon. Then go")
    }

    func testCommaIsNotLostWhenItsSpaceTouchesANeighbouringFix() {
        let app = SpanEditApplier.apply([e("milk ", "Milk "), e("Kama", ",")], to: "buy milk Kama bread")
        XCTAssertEqual(app.text, "buy Milk, bread")
        XCTAssertEqual(app.applied.count, 2)
    }

    func testRejectionsRecordWhatTheModelProposed() {
        let app = SpanEditApplier.apply([e("Kama", ",")], to: "Kama milk Kama bread")
        XCTAssertEqual(app.rejected.first?.edit, e("Kama", ","))
    }

    func testUndoNeverWidens() {
        let before = "milk , but bread"
        let fix = SpanEditApplier.apply([e(", but", "but")], to: before, absorbSpace: true)
        XCTAssertEqual(fix.text, "milk but bread")
        let ran = fix.applied[0]
        let undo = SpanEditApplier.apply([e(ran.replace, ran.find)], to: fix.text, absorbSpace: false)
        XCTAssertEqual(undo.text, before)
    }

    // Pass 2: a marker that opens the span is ordinary speech, not a correction.
    func testSentenceOpeningMarkerIsNotACorrection() {
        XCTAssertNotNil(CleanupFaithfulness.rejection(for: e("I mean it when I say thanks", "thanks")))
        XCTAssertNotNil(CleanupFaithfulness.rejection(for: e("Actually, the report looks great", "the report looks great")))
        XCTAssertNotNil(CleanupFaithfulness.rejection(for: e("no wait Friday", "Friday")),
                        "dropping only the marker keeps the false start: not a correction")
    }

    func testRealCorrectionsStillPass() {
        XCTAssertNil(CleanupFaithfulness.rejection(for: e("Tuesday no wait Wednesday", "Wednesday")))
        XCTAssertNil(CleanupFaithfulness.rejection(for: e("Marco I mean to Priya", "Priya")))
        XCTAssertNil(CleanupFaithfulness.rejection(for: e("40,000 sorry 50,000", "50,000")))
        XCTAssertNil(CleanupFaithfulness.rejection(for: e("The recital is on Thursday no wait Friday at six.",
                                                          "The recital is on Friday at six.")))
    }
}

// Claude · 2026-09-29 · review round 2
final class SpanEditReviewRound2Tests: XCTestCase {
    private func e(_ f: String, _ r: String) -> SpanEdit { SpanEdit(find: f, replace: r, reason: "t") }

    func testExactDuplicateEditAppliesOnce() {
        let app = SpanEditApplier.apply([e("Tom", "Tom,"), e("Tom", "Tom,")], to: "Hi Tom how are you")
        XCTAssertEqual(app.text, "Hi Tom, how are you")
        XCTAssertEqual(app.applied.count, 1)
    }

    func testRetryNeverAnchorsInsideAnotherFixsText() {
        let app = SpanEditApplier.apply([e("cat", "the cat"), e("cat now", "cat, now")], to: "feed cat now")
        // "cat now" loses the overlap; on retry "cat" sits inside "the cat" but "cat now" straddles
        // its edge, so it applies once.
        XCTAssertEqual(app.text, "feed the cat, now")
        let dup = SpanEditApplier.apply([e("cat", "the cat"), e("cat", "the  cat")], to: "feed cat now")
        XCTAssertEqual(dup.text, "feed the cat now", "a second fix wholly inside the first one's text is refused")
    }

    func testListCaseStillLandsAfterTheInsideRule() {
        let text = "here is the shopping list column eggs Kama bread Kama and butter"
        let app = SpanEditApplier.apply([e("list column eggs", "list: eggs"), e("eggs Kama bread", "eggs, bread"),
                                         e("bread Kama and butter", "bread, and butter")], to: text)
        XCTAssertEqual(app.text, "here is the shopping list: eggs, bread, and butter")
    }

    /// Known residual (review round 2, nit B): a sentence-opening marker after an unrelated word
    /// still counts as a correction. Pinned so a later tightening is a visible change.
    func testKnownResidualMarkerAfterUnrelatedWord() {
        XCTAssertNil(CleanupFaithfulness.rejection(for: e("Thanks. Actually, the report is late", "the report is late")))
    }
}

// Claude · 2026-09-29 · review round 3: conflicts judged on each fix's changed core
final class SpanEditChangedCoreTests: XCTestCase {
    private func e(_ f: String, _ r: String) -> SpanEdit { SpanEdit(find: f, replace: r, reason: "t") }

    func testSameCommaThroughTwoAnchorsAppliesOnce() {
        let app = SpanEditApplier.apply([e("Tom", "Tom,"), e("Hi Tom", "Hi Tom,")], to: "Hi Tom how are you")
        XCTAssertEqual(app.text, "Hi Tom, how are you")
        XCTAssertEqual(app.rejected.map(\.cause), [.duplicate])
    }

    func testInsertionAtTheEdgeOfAnotherChangeIsRefused() {
        let app = SpanEditApplier.apply([e("b Kama Tom", "b, Tom,"), e("a Kama b", "a, b"), e("Tom", "Tom,")],
                                        to: "a Kama b Kama Tom d")
        XCTAssertEqual(app.text, "a, b, Tom, d")
        XCTAssertEqual(app.rejected.map(\.cause), [.duplicate])
        let reversed = SpanEditApplier.apply([e("Tom", "Tom,"), e("b Kama Tom", "b, Tom,"), e("a Kama b", "a, b")],
                                             to: "a Kama b Kama Tom d")
        XCTAssertEqual(reversed.text, "a, b, Tom, d")
        let short = SpanEditApplier.apply([e("Tom", "Tom,"), e("b Kama Tom", "b, Tom,")], to: "a b Kama Tom how")
        XCTAssertEqual(short.text, "a b, Tom, how", "the Kama comma still lands; only the repeat is dropped")
        let ran = short.applied[1]
        XCTAssertEqual(ran.replace, "b, Tom")
        XCTAssertEqual(SpanEditApplier.apply([e(ran.replace, ran.find)], to: short.text, absorbSpace: false).text,
                       "a b Kama Tom, how", "undoing the trimmed fix leaves the other comma")
    }

    func testListWithEmojiAndAccents() {
        let text = "the list column 👨‍👩‍👧 eggs Kama café Kama and butter"
        let app = SpanEditApplier.apply([e("list column 👨‍👩‍👧", "list: 👨‍👩‍👧"), e("eggs Kama café", "eggs, café"),
                                         e("café Kama and", "café, and")], to: text)
        XCTAssertEqual(app.text, "the list: 👨‍👩‍👧 eggs, café, and butter")
        XCTAssertTrue(app.rejected.isEmpty)
    }

    func testTwoFixesChangingTheSameWordStillConflict() {
        let app = SpanEditApplier.apply([e("Kama bread", ", bread"), e("milk Kama", "milk;")], to: "milk Kama bread")
        XCTAssertEqual(app.rejected.map(\.cause), [.overlap])
        XCTAssertEqual(app.text, "milk, bread", "the first fix (with its absorbed space) wins")
    }

    func testEachListFixUndoesOnItsOwn() {
        let text = "here is the shopping list column eggs Kama bread Kama and butter"
        let app = SpanEditApplier.apply([e("list column eggs", "list: eggs"), e("eggs Kama bread", "eggs, bread"),
                                         e("bread Kama and butter", "bread, and butter")], to: text)
        let middle = app.applied[1]
        let undo = SpanEditApplier.apply([e(middle.replace, middle.find)], to: app.text, absorbSpace: false)
        XCTAssertEqual(undo.text, "here is the shopping list: eggs Kama bread, and butter")
    }

    func testDuplicateOfAnInvalidEditKeepsItsOwnCause() {
        let app = SpanEditApplier.apply([e("a", "b\n"), e("a", "b\n")], to: "a")
        XCTAssertEqual(app.rejected.map(\.cause), [.invalidReplacement, .invalidReplacement])
    }
}

// Claude · 2026-09-29 · fresh review round 4
final class SpanEditReviewRound4Tests: XCTestCase {
    private func e(_ f: String, _ r: String) -> SpanEdit { SpanEdit(find: f, replace: r, reason: "t") }

    func testCommaAfterANameFixBothLand() {
        XCTAssertEqual(SpanEditApplier.apply([e("Hi Katy", "Hi Katy,"), e("Katy", "Katie")],
                                             to: "Hi Katy how are you").text, "Hi Katie, how are you")
        XCTAssertEqual(SpanEditApplier.apply([e("Katy", "Katie"), e("Katy how", "Katy, how")],
                                             to: "Hi Katy how are you").text, "Hi Katie, how are you")
    }

    func testInsertionAtTheStartOfAChangeStillConflicts() {
        let app = SpanEditApplier.apply([e("Katy", "Katie"), e("Katy", "Kat-y")], to: "Hi Katy")
        XCTAssertEqual(app.rejected.map(\.cause), [.overlap])
    }

    func testOverlappingRepeatsAreAmbiguous() {
        XCTAssertEqual(SpanEditApplier.apply([e("aba", "X")], to: "ababa").rejected.map(\.cause), [.ambiguousMatch])
        XCTAssertEqual(SpanEditApplier.apply([e("I I", "I")], to: "I I I think").rejected.map(\.cause), [.ambiguousMatch])
    }
}

// Claude · 2026-09-29 · review round 5
final class SpanEditReviewRound5Tests: XCTestCase {
    private func e(_ f: String, _ r: String) -> SpanEdit { SpanEdit(find: f, replace: r, reason: "t") }

    func testNoPunctuationRepeatAcrossTouchingChanges() {
        XCTAssertFalse(SpanEditApplier.apply([e("u s a", "U.S.A."), e("a now", "a. Now")],
                                             to: "in the u s a now we").text.contains(".."))
        XCTAssertFalse(SpanEditApplier.apply([e("wait dot dot dot", "wait..."), e("dot dot dot so", "dot dot dot. So")],
                                             to: "and wait dot dot dot so").text.contains("...."))
    }

    func testUndoListUsesTheApplierCount() {
        XCTAssertEqual(SpanEditApplier.allRanges(of: "aa", in: "aaa").count, 2)
    }
}
