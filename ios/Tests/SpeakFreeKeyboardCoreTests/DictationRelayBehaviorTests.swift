// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation
import XCTest
@testable import SpeakFreeKeyboardCore

/// Device-reported regressions, pinned as deterministic cases:
/// host text jumping while words revise, a relay tap that inserts nothing, and dictation that
/// never becomes sentence case.
final class DictationRelayBehaviorTests: XCTestCase {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    // MARK: - Cursor-local revision (host no longer jumps)

    func testGrowingHypothesisAppendsInsteadOfRetypingTheWholeUtterance() throws {
        var document = ""
        var state: DictationRevisionState?

        for (revision, text) in ["the qu", "the quick br", "the quick brown fox"].enumerated() {
            let decision = try DictationRevisionPlanner.plan(
                snapshot: snapshot(revision: UInt64(revision + 1), volatile: text),
                in: context(before: document),
                from: state,
                capitalization: .none
            )
            guard case let .apply(edit, next) = decision else {
                return XCTFail("Expected an applied edit, got \(decision)")
            }
            XCTAssertEqual(edit.deleteBackwardCount, 0, "A pure append must delete nothing")
            document = edit.applying(to: document)
            state = next
        }

        XCTAssertEqual(document, "the quick brown fox")
    }

    func testRevisedWordRewritesOnlyTheDivergentTail() throws {
        let first = try applyFirst(volatile: "recognize speach", into: "Note: ")
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 2, volatile: "recognize speech"),
            in: context(before: "Note: recognize speach"),
            from: first.state,
            capitalization: .none
        )

        // "recognize spe" is untouched: only "ach" is replaced, so the host relays out one word
        // instead of the entire hypothesis.
        XCTAssertEqual(
            edit(decision),
            TypingEdit(deleteBackwardCount: 3, insertion: "ech")
        )
    }

    func testTerminalReplacementRewritesOnlyWhatActuallyChanged() throws {
        let first = try applyFirst(volatile: "hello there", into: "")
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 2, phase: .finalized, finalized: "hello there."),
            in: context(before: "hello there"),
            from: first.state,
            capitalization: .none
        )

        XCTAssertEqual(edit(decision), TypingEdit(deleteBackwardCount: 0, insertion: "."))
    }

    func testEditDeeperThanTheProvenOwnedTailIsRefused() throws {
        let owned = String(repeating: "a", count: 300)
        let previous = DictationRevisionState(
            sessionID: sessionID,
            appliedRevision: 1,
            finalizedSegments: [],
            volatileText: owned,
            insertedText: owned,
            anchorSuffix: "Note ",
            documentIdentifier: "document-a",
            contextAfterInput: nil
        )

        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 2, volatile: String(repeating: "b", count: 300)),
            in: context(before: "Note " + owned),
            from: previous,
            capitalization: .none
        )

        XCTAssertEqual(decision, .reject(.editExceedsProvenOwnership))
    }

    // MARK: - Sentence capitalization

    func testFirstPartialIsCapitalizedInAnEmptyField() throws {
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 1, volatile: "hello"),
            in: context(before: ""),
            from: nil,
            capitalization: .sentences
        )

        XCTAssertEqual(edit(decision), TypingEdit(insertion: "Hello"))
        XCTAssertEqual(state(decision)?.insertedText, "Hello")
    }

    func testFirstPartialIsCapitalizedAfterASentenceEndingPrefix() throws {
        for prefix in ["Done. ", "Really? ", "Stop! ", "He left.\n"] {
            let decision = try DictationRevisionPlanner.plan(
                snapshot: snapshot(revision: 1, volatile: "then we"),
                in: context(before: prefix),
                from: nil,
                capitalization: .sentences
            )
            XCTAssertEqual(edit(decision), TypingEdit(insertion: "Then we"), "prefix \(prefix)")
        }
    }

    func testMidSentencePrefixIsNotCapitalized() throws {
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 1, volatile: "then we"),
            in: context(before: "and "),
            from: nil,
            capitalization: .sentences
        )

        XCTAssertEqual(edit(decision), TypingEdit(insertion: "then we"))
    }

    func testCapitalizationSurvivesLaterRawRevisionsAndTheFinalReplacement() throws {
        var document = ""
        var state: DictationRevisionState?
        let revisions: [(UInt64, DictationSnapshot)] = [
            (1, snapshot(revision: 1, volatile: "hello")),
            (2, snapshot(revision: 2, volatile: "hello there")),
            (3, snapshot(revision: 3, volatile: "hello there. how are you")),
            (4, snapshot(revision: 4, phase: .finalized, finalized: "hello there. how are you?")),
        ]

        for (_, next) in revisions {
            let decision = try DictationRevisionPlanner.plan(
                snapshot: next,
                in: context(before: document),
                from: state,
                capitalization: .sentences
            )
            guard case let .apply(edit, nextState) = decision else {
                return XCTFail("Expected an applied edit, got \(decision)")
            }
            document = edit.applying(to: document)
            state = nextState
        }

        // The recognizer never capitalized anything; the host field reads correctly anyway, and
        // ownership still matches the visible text exactly.
        XCTAssertEqual(document, "Hello there. How are you?")
        XCTAssertEqual(state?.insertedText, document)
        XCTAssertEqual(state?.anchorSuffix, "", "The host prefix is captured once, at claim time")
    }

    func testCapitalizationNeverRewritesTextThatAlreadyReadsCorrectly() throws {
        let first = try applyFirst(volatile: "hello", into: "", capitalization: .sentences)
        XCTAssertEqual(first.document, "Hello")

        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 2, volatile: "hello world"),
            in: context(before: first.document),
            from: first.state,
            capitalization: .sentences
        )

        XCTAssertEqual(edit(decision), TypingEdit(deleteBackwardCount: 0, insertion: " world"))
    }

    func testInternalBrandCasingIsPreservedAtASentenceStart() throws {
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 1, volatile: "iPhone batteries last"),
            in: context(before: ""),
            from: nil,
            capitalization: .sentences
        )

        XCTAssertEqual(edit(decision), TypingEdit(insertion: "iPhone batteries last"))
    }

    func testTruncatedBrandWordSelfCorrectsOnTheNextRevision() throws {
        let first = try applyFirst(volatile: "i", into: "", capitalization: .sentences)
        XCTAssertEqual(first.document, "I")

        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 2, volatile: "iPhone"),
            in: context(before: first.document),
            from: first.state,
            capitalization: .sentences
        )

        XCTAssertEqual(edit(decision), TypingEdit(deleteBackwardCount: 1, insertion: "iPhone"))
    }

    func testHostFieldTraitsDecideCasing() throws {
        let cases: [(DictationCapitalizationPolicy, String)] = [
            (.none, "hello there"),
            (.sentences, "Hello there"),
            (.words, "Hello There"),
            (.allCharacters, "HELLO THERE"),
        ]
        for (policy, expected) in cases {
            let decision = try DictationRevisionPlanner.plan(
                snapshot: snapshot(revision: 1, volatile: "hello there"),
                in: context(before: ""),
                from: nil,
                capitalization: policy
            )
            XCTAssertEqual(edit(decision), TypingEdit(insertion: expected), "policy \(policy)")
        }
    }

    // MARK: - Relay tap decisions

    func testTapInsertsWhenNothingHasClaimedThisField() {
        XCTAssertEqual(plan(ownership: .unclaimed), .insertFresh)
    }

    /// The device report: the transcript was visible in the candidate bar, but tapping the relay
    /// after switching apps inserted nothing because the session was claimed in the previous field.
    func testTapInAnotherFieldStillInsertsTheVisibleTranscript() {
        XCTAssertEqual(plan(ownership: .claimedInAnotherDocument), .insertFresh)
    }

    func testTapRevisesAFieldThisSessionAlreadyOwns() {
        let state = ownedState(appliedRevision: 3, insertedText: "hello")
        XCTAssertEqual(
            plan(ownership: .claimedHere(state), snapshotRevision: 4),
            .revise(state)
        )
    }

    func testTapOnAnAlreadyCurrentClaimSaysSoInsteadOfDoingNothing() {
        let state = ownedState(appliedRevision: 4, insertedText: "hello")
        let action = plan(ownership: .claimedHere(state), snapshotRevision: 4)

        XCTAssertEqual(action, .explainAlreadyCurrent)
        XCTAssertFalse(action.insertsText)
        XCTAssertEqual(action.explanation?.isEmpty, false)
    }

    func testTapBeforeAnyWordsExplainsThatNothingIsReadyYet() {
        let state = ownedState(appliedRevision: 4, insertedText: "")
        XCTAssertEqual(
            plan(ownership: .claimedHere(state), snapshotRevision: 4),
            .explainNothingToInsertYet
        )
    }

    func testTapFailsClosedWhenTheLastInsertCannotBeVerified() {
        XCTAssertEqual(plan(ownership: .unverifiable), .explainUnverifiableClaim)
    }

    func testTapExplainsMissingSessionUnsupportedFieldSelectionAndStorage() {
        XCTAssertEqual(
            DictationRelayTapPlanner.plan(request(fieldAcceptsDictation: false)),
            .explainUnsupportedField
        )
        XCTAssertEqual(
            DictationRelayTapPlanner.plan(request(relayStorageAvailable: false)),
            .explainRelayUnavailable
        )
        XCTAssertEqual(
            DictationRelayTapPlanner.plan(request(hasFreshSnapshot: false)),
            .explainNoSession
        )
        XCTAssertEqual(
            DictationRelayTapPlanner.plan(request(hasSelection: true)),
            .explainSelection
        )
    }

    func testEveryTapOutcomeEitherInsertsTextOrExplainsItself() {
        let actions: [DictationRelayTapAction] = [
            .insertFresh,
            .revise(ownedState(appliedRevision: 1, insertedText: "x")),
            .explainUnsupportedField,
            .explainRelayUnavailable,
            .explainNoSession,
            .explainSelection,
            .explainNothingToInsertYet,
            .explainAlreadyCurrent,
            .explainUnverifiableClaim,
        ]
        for action in actions {
            if action.insertsText {
                XCTAssertNil(action.explanation, "\(action)")
            } else {
                XCTAssertEqual(action.explanation?.isEmpty, false, "\(action) must not be silent")
            }
        }
    }

    func testOwnershipIsNeverResolvedBeforeTheCheaperGuardsPass() {
        var resolved = false
        _ = DictationRelayTapPlanner.plan(DictationRelayTapRequest(
            fieldAcceptsDictation: true,
            relayStorageAvailable: true,
            freshSnapshot: nil,
            hasSelection: false,
            resolveOwnership: { _ in
                resolved = true
                return .unclaimed
            }
        ))
        XCTAssertFalse(resolved)
    }

    // MARK: - Revision pacing

    func testActiveRevisionsAreCoalescedInsideTheWindowAndResumeAfterIt() {
        var pacer = DictationRevisionPacer(minimumActiveInterval: 0.4)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(pacer.admit(phase: .active, at: start), .apply)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(0.125)), .coalesce)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(0.375)), .coalesce)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(0.5)), .apply)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(0.6)), .coalesce)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(1.0)), .apply)
    }

    func testTerminalAndUserInitiatedRevisionsBypassPacing() {
        var pacer = DictationRevisionPacer(minimumActiveInterval: 5)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(pacer.admit(phase: .active, at: start), .apply)
        XCTAssertEqual(pacer.admit(phase: .finalized, at: start.addingTimeInterval(0.01)), .apply)
        XCTAssertEqual(pacer.admit(phase: .cancelled, at: start.addingTimeInterval(0.02)), .apply)
        XCTAssertEqual(
            pacer.admit(phase: .active, at: start.addingTimeInterval(0.03), userInitiated: true),
            .apply
        )
    }

    func testResetReleasesTheGateForANewClaim() {
        var pacer = DictationRevisionPacer(minimumActiveInterval: 5)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(pacer.admit(phase: .active, at: start), .apply)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(1)), .coalesce)
        pacer.reset()
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(1)), .apply)
    }

    func testABackwardsClockDoesNotStallRevisionsForever() {
        var pacer = DictationRevisionPacer(minimumActiveInterval: 5)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(pacer.admit(phase: .active, at: start), .apply)
        XCTAssertEqual(pacer.admit(phase: .active, at: start.addingTimeInterval(-30)), .apply)
    }

    /// A coalesced revision is never dropped: the caller keeps its applied-revision cursor, so the
    /// next poll re-offers the newest snapshot and the text still lands.
    func testCoalescedRevisionIsReofferedAndLandsCompletely() throws {
        var pacer = DictationRevisionPacer(minimumActiveInterval: 0.4)
        var document = ""
        var state: DictationRevisionState?
        let start = Date(timeIntervalSince1970: 1_000)
        let polls: [(TimeInterval, String)] = [
            (0.0, "one"),
            (0.125, "one two"),
            (0.250, "one two three"),
            (0.500, "one two three four"),
        ]

        for (offset, text) in polls {
            let next = snapshot(revision: UInt64(offset * 1_000) + 1, volatile: text)
            if let state, next.revision <= state.appliedRevision { continue }
            guard pacer.admit(phase: next.phase, at: start.addingTimeInterval(offset)) == .apply else {
                continue
            }
            let decision = try DictationRevisionPlanner.plan(
                snapshot: next,
                in: context(before: document),
                from: state,
                capitalization: .none
            )
            guard case let .apply(edit, nextState) = decision else {
                return XCTFail("Expected an applied edit, got \(decision)")
            }
            document = edit.applying(to: document)
            state = nextState
        }

        XCTAssertEqual(document, "one two three four")
        XCTAssertEqual(state?.insertedText, document)
    }

    // MARK: - Legacy receipts

    func testLegacyRevisionStateWithoutInsertedTextReconstructsRawOwnership() throws {
        let legacy: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "appliedRevision": 4,
            "finalizedSegments": [["id": "f", "text": "hello "]],
            "volatileText": "wor",
            "anchorSuffix": "Draft: hello ",
            "documentIdentifier": "document-a",
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try JSONDecoder().decode(DictationRevisionState.self, from: data)

        XCTAssertEqual(decoded.insertedText, "hello wor")
    }

    // MARK: - Helpers

    private func snapshot(
        revision: UInt64,
        phase: DictationSessionPhase = .active,
        finalized: String? = nil,
        volatile: String? = nil
    ) -> DictationSnapshot {
        DictationSnapshot(
            sessionID: sessionID,
            revision: revision,
            phase: phase,
            finalizedSegments: finalized.map { [DictationSegment(id: "final", text: $0)] } ?? [],
            volatileSegments: volatile.map { [DictationSegment(id: "volatile", text: $0)] } ?? []
        )
    }

    private func context(
        before: String?,
        selected: String? = nil,
        after: String? = nil
    ) -> DictationDocumentContext {
        DictationDocumentContext(
            documentIdentifier: "document-a",
            contextBeforeInput: before,
            selectedText: selected,
            contextAfterInput: after
        )
    }

    private func applyFirst(
        volatile: String,
        into document: String,
        capitalization: DictationCapitalizationPolicy = .none
    ) throws -> (document: String, state: DictationRevisionState) {
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot(revision: 1, volatile: volatile),
            in: context(before: document),
            from: nil,
            capitalization: capitalization
        )
        guard case let .apply(edit, state) = decision else {
            throw TestFailure.unexpectedDecision
        }
        return (edit.applying(to: document), state)
    }

    private func edit(_ decision: DictationRevisionDecision) -> TypingEdit? {
        guard case let .apply(edit, _) = decision else { return nil }
        return edit
    }

    private func state(_ decision: DictationRevisionDecision) -> DictationRevisionState? {
        switch decision {
        case let .apply(_, next), let .advanceWithoutEdit(next): return next
        case .reject: return nil
        }
    }

    private func ownedState(
        appliedRevision: UInt64,
        insertedText: String
    ) -> DictationRevisionState {
        DictationRevisionState(
            sessionID: sessionID,
            appliedRevision: appliedRevision,
            finalizedSegments: [],
            volatileText: insertedText,
            insertedText: insertedText,
            anchorSuffix: "",
            documentIdentifier: "document-a",
            contextAfterInput: nil
        )
    }

    private func request(
        fieldAcceptsDictation: Bool = true,
        relayStorageAvailable: Bool = true,
        hasFreshSnapshot: Bool = true,
        hasSelection: Bool = false,
        ownership: DictationRelayOwnership = .unclaimed
    ) -> DictationRelayTapRequest {
        DictationRelayTapRequest(
            fieldAcceptsDictation: fieldAcceptsDictation,
            relayStorageAvailable: relayStorageAvailable,
            freshSnapshot: hasFreshSnapshot ? snapshot(revision: 1, volatile: "hello") : nil,
            hasSelection: hasSelection,
            resolveOwnership: { _ in ownership }
        )
    }

    private func plan(
        ownership: DictationRelayOwnership,
        snapshotRevision: UInt64 = 1
    ) -> DictationRelayTapAction {
        DictationRelayTapPlanner.plan(DictationRelayTapRequest(
            fieldAcceptsDictation: true,
            relayStorageAvailable: true,
            freshSnapshot: snapshot(revision: snapshotRevision, volatile: "hello"),
            hasSelection: false,
            resolveOwnership: { _ in ownership }
        ))
    }

    private enum TestFailure: Error {
        case unexpectedDecision
    }
}
