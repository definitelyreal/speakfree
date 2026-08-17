// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class TypingBehaviorTests: XCTestCase {
    func testExplicitCapitalizationOverridesAutomaticSentenceCase() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.tap("a", before: "", capitalization: .lowercase),
            TypingEdit(insertion: "a")
        )
        XCTAssertEqual(
            engine.tap("b", before: "middle", capitalization: .shifted),
            TypingEdit(insertion: "B")
        )
        XCTAssertEqual(
            engine.tap("c", before: "middle", capitalization: .capsLocked),
            TypingEdit(insertion: "C")
        )
    }

    func testVerbatimPolicyDoesNotCorruptURLsOrEmailAddresses() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.tap("c", before: "example.", policy: .verbatim, capitalization: .lowercase),
            TypingEdit(insertion: "c")
        )
        XCTAssertEqual(
            engine.tap(".", before: "example ", policy: .verbatim),
            TypingEdit(insertion: ".")
        )
        XCTAssertEqual(
            engine.tap("'", before: "o", policy: .verbatim),
            TypingEdit(insertion: "'")
        )
        XCTAssertEqual(
            engine.commitSpace(replacingWith: "example", before: "exampel", policy: .verbatim),
            TypingEdit(insertion: " ")
        )
        XCTAssertEqual(
            engine.commitSpace(replacingWith: nil, before: "example ", policy: .verbatim),
            .none
        )
    }
    func testCapitalizationAtDocumentSentenceAndLineStarts() {
        XCTAssertEqual(TypingBehaviorEngine.capitalizationState(before: ""), .shifted)
        XCTAssertEqual(TypingBehaviorEngine.capitalizationState(before: "Hello. "), .shifted)
        XCTAssertEqual(TypingBehaviorEngine.capitalizationState(before: "Really?!   "), .shifted)
        XCTAssertEqual(TypingBehaviorEngine.capitalizationState(before: "Heading\n"), .shifted)
        XCTAssertEqual(TypingBehaviorEngine.capitalizationState(before: "hello "), .lowercased)
        XCTAssertEqual(TypingBehaviorEngine.capitalizationState(before: "version 2.0 "), .lowercased)
    }

    func testTapCompositionCapitalizesAndTracksApostrophes() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(engine.tap("h", before: ""), TypingEdit(insertion: "H"))
        XCTAssertEqual(engine.tap("w", before: "Hello. "), TypingEdit(insertion: "W"))
        XCTAssertEqual(engine.tap("w", before: "Hello "), TypingEdit(insertion: "w"))
        XCTAssertEqual(engine.tap("'", before: "I"), TypingEdit(insertion: "’"))
        XCTAssertEqual(
            TypingBehaviorEngine.composition(before: "I’m"),
            TypingComposition(word: "I’m", replacementLength: 3)
        )
    }

    func testDoubleSpaceProducesPeriodAndDoesNotDuplicateTerminalPunctuation() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.tap(" ", before: "Hello "),
            TypingEdit(deleteBackwardCount: 1, insertion: ". ")
        )
        XCTAssertEqual(engine.tap(" ", before: "Hello. "), .none)
        XCTAssertEqual(engine.tap(" ", before: "Hello, "), .none)
        XCTAssertEqual(engine.tap(" ", before: ""), .none)
        XCTAssertEqual(engine.tap(" ", before: "Hello"), TypingEdit(insertion: " "))
    }

    func testPunctuationRemovesSpacesAndNextLetterAddsOne() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.tap(",", before: "hello  "),
            TypingEdit(deleteBackwardCount: 2, insertion: ",")
        )
        XCTAssertEqual(engine.tap("w", before: "Hello."), TypingEdit(insertion: " W"))
        XCTAssertEqual(engine.tap("w", before: "Hello,"), TypingEdit(insertion: " w"))
        XCTAssertEqual(engine.tap("5", before: "2."), TypingEdit(insertion: "5"))
    }

    func testAcceptSuggestionMatchesCaseAndBackspaceRestoresOriginal() {
        var engine = TypingBehaviorEngine()
        let acceptance = engine.acceptSuggestion("the", before: "Teh")
        XCTAssertEqual(acceptance, TypingEdit(deleteBackwardCount: 3, insertion: "The"))
        XCTAssertEqual(engine.lastReplacement, TypingReplacement(original: "Teh", accepted: "The"))

        let corrected = acceptance.applying(to: "Teh")
        let restoration = engine.backspace(before: corrected)
        XCTAssertEqual(restoration.applying(to: corrected), "Teh")
        XCTAssertNil(engine.lastReplacement)
    }

    func testSelectingAlreadyTypedCandidateIsANoOp() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(engine.acceptSuggestion("hello", before: "hello"), .none)
        XCTAssertNil(engine.lastReplacement)
    }

    func testSpaceCommitAutocorrectsAndBackspaceRestoresWithoutSpace() {
        var engine = TypingBehaviorEngine()
        let commit = engine.commitSpace(replacingWith: "the", before: "I saw teh")
        XCTAssertEqual(commit, TypingEdit(deleteBackwardCount: 3, insertion: "the "))
        XCTAssertEqual(
            engine.lastReplacement,
            TypingReplacement(
                original: "teh",
                accepted: "the",
                committedTrailingSpace: true
            )
        )

        let corrected = commit.applying(to: "I saw teh")
        XCTAssertEqual(corrected, "I saw the ")
        XCTAssertEqual(engine.backspace(before: corrected).applying(to: corrected), "I saw teh")
        XCTAssertNil(engine.lastReplacement)
    }

    func testSpaceCommitPreservesCapitalization() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.commitSpace(replacingWith: "the", before: "TEH"),
            TypingEdit(deleteBackwardCount: 3, insertion: "THE ")
        )
    }

    func testSpaceCommitWithoutCorrectionBehavesLikeSpaceTap() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.commitSpace(replacingWith: nil, before: "hello"),
            TypingEdit(insertion: " ")
        )
        XCTAssertEqual(
            engine.commitSpace(replacingWith: "hello", before: "hello"),
            TypingEdit(insertion: " ")
        )
        XCTAssertNil(engine.lastReplacement)
    }

    func testSpaceCommitRejectsPhraseSuggestion() {
        var engine = TypingBehaviorEngine()
        XCTAssertEqual(
            engine.commitSpace(replacingWith: "hello there", before: "hello"),
            TypingEdit(insertion: " ")
        )
        XCTAssertNil(engine.lastReplacement)
    }

    func testSpaceAfterExplicitCandidateKeepsOriginalForUndo() {
        var engine = TypingBehaviorEngine()
        let acceptance = engine.acceptSuggestion("the", before: "teh")
        let corrected = acceptance.applying(to: "teh")
        let commit = engine.commitSpace(replacingWith: "the", before: corrected)
        let committed = commit.applying(to: corrected)

        XCTAssertEqual(committed, "the ")
        XCTAssertEqual(engine.backspace(before: committed).applying(to: committed), "teh")
    }

    func testOnlyImmediateBackspaceUndoesSpaceCorrection() {
        var engine = TypingBehaviorEngine()
        let commit = engine.commitSpace(replacingWith: "the", before: "teh")
        let corrected = commit.applying(to: "teh")
        _ = engine.tap("n", before: corrected)

        XCTAssertEqual(
            engine.backspace(before: corrected + "n").applying(to: corrected + "n"),
            corrected
        )
    }

    func testAcceptingAnotherCandidateStillRestoresTypedWord() {
        var engine = TypingBehaviorEngine()
        let first = engine.acceptSuggestion("the", before: "teh")
        let firstContext = first.applying(to: "teh")
        let second = engine.acceptSuggestion("ten", before: firstContext)
        let secondContext = second.applying(to: firstContext)

        XCTAssertEqual(secondContext, "ten")
        XCTAssertEqual(engine.backspace(before: secondContext).applying(to: secondContext), "teh")
    }

    func testAnyInterveningTapInvalidatesCorrectionRestore() {
        var engine = TypingBehaviorEngine()
        let acceptance = engine.acceptSuggestion("the", before: "teh")
        let corrected = acceptance.applying(to: "teh")
        _ = engine.tap(" ", before: corrected)
        XCTAssertEqual(engine.backspace(before: corrected + " "), TypingEdit(deleteBackwardCount: 1))
    }

    func testOrdinaryBackspaceIsGraphemeSafe() {
        var engine = TypingBehaviorEngine()
        let context = "go 👨‍👩‍👧‍👦"
        XCTAssertEqual(engine.backspace(before: context).applying(to: context), "go ")
        XCTAssertEqual(engine.backspace(before: ""), .none)
    }

    func testDeleteWordBoundaries() {
        XCTAssertEqual(TypingBehaviorEngine.deleteWordBackwardCount(before: "hello world"), 5)
        XCTAssertEqual(TypingBehaviorEngine.deleteWordBackwardCount(before: "hello world  "), 7)
        XCTAssertEqual(TypingBehaviorEngine.deleteWordBackwardCount(before: "we’re"), 5)
        XCTAssertEqual(TypingBehaviorEngine.deleteWordBackwardCount(before: "hello..."), 3)
        XCTAssertEqual(TypingBehaviorEngine.deleteWordBackwardCount(before: "   "), 3)
        XCTAssertEqual(TypingBehaviorEngine.deleteWordBackwardCount(before: ""), 0)
    }

    func testDeleteWordEditClearsReplacement() {
        var engine = TypingBehaviorEngine()
        _ = engine.acceptSuggestion("the", before: "teh")
        let edit = engine.deleteWord(before: "hello world")
        XCTAssertEqual(edit.applying(to: "hello world"), "hello ")
        XCTAssertNil(engine.lastReplacement)
    }

    func testDeleteWordRemovesAHostSelectionExactlyOnce() {
        var engine = TypingBehaviorEngine()

        XCTAssertEqual(
            engine.deleteWord(before: "prefix ", selectedText: "selected text"),
            .deleteSelection
        )
        XCTAssertEqual(
            engine.deleteWord(before: "prefix word", selectedText: nil),
            .edit(TypingEdit(deleteBackwardCount: 4))
        )
    }
}
