// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation
import XCTest
@testable import SpeakFreeKeyboardCore

final class DictationHandoffTests: XCTestCase {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let otherSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Snapshot validation and rendering

    func testSnapshotRendersExactSegmentSpansWithoutAddingSeparators() throws {
        let snapshot = makeSnapshot(
            finalized: [segment("f1", "Hello"), segment("f2", ", ")],
            volatile: [segment("v1", "world"), segment("v2", "!")]
        )

        try snapshot.validate()
        XCTAssertEqual(snapshot.finalizedText, "Hello, ")
        XCTAssertEqual(snapshot.volatileText, "world!")
        XCTAssertEqual(snapshot.renderedText, "Hello, world!")
    }

    func testSnapshotRejectsUnsupportedSchemaVersion() {
        let snapshot = makeSnapshot(schemaVersion: 999)

        XCTAssertThrowsError(try snapshot.validate()) { error in
            XCTAssertEqual(
                error as? DictationSnapshotValidationError,
                .unsupportedSchemaVersion(999)
            )
        }
    }

    func testSnapshotRejectsEmptyIdentifierInEitherSegmentCollection() {
        for snapshot in [
            makeSnapshot(finalized: [segment("", "final")]),
            makeSnapshot(volatile: [segment("", "draft")]),
        ] {
            XCTAssertThrowsError(try snapshot.validate()) { error in
                XCTAssertEqual(error as? DictationSnapshotValidationError, .emptySegmentIdentifier)
            }
        }
    }

    func testSnapshotRejectsDuplicateIdentifierWithinAndAcrossCollections() {
        let snapshots = [
            makeSnapshot(finalized: [segment("same", "a"), segment("same", "b")]),
            makeSnapshot(volatile: [segment("same", "a"), segment("same", "b")]),
            makeSnapshot(
                finalized: [segment("same", "a")],
                volatile: [segment("same", "b")]
            ),
        ]

        for snapshot in snapshots {
            XCTAssertThrowsError(try snapshot.validate()) { error in
                XCTAssertEqual(
                    error as? DictationSnapshotValidationError,
                    .duplicateSegmentIdentifier("same")
                )
            }
        }
    }

    func testTerminalSnapshotsRejectVolatileSegmentsButAllowFinalizedSegments() throws {
        for phase in [DictationSessionPhase.finalized, .cancelled] {
            XCTAssertThrowsError(
                try makeSnapshot(phase: phase, volatile: [segment("v", "draft")]).validate()
            ) { error in
                XCTAssertEqual(
                    error as? DictationSnapshotValidationError,
                    .volatileSegmentsInTerminalSnapshot
                )
            }

            try makeSnapshot(phase: phase, finalized: [segment("f", "done")]).validate()
        }
    }

    // MARK: - Atomic snapshot store

    func testStoreReturnsNilWhenNoSnapshotExistsAndRemoveIsIdempotent() throws {
        try withStore { store, _ in
            XCTAssertNil(try store.read())
            XCTAssertNoThrow(try store.remove())
            XCTAssertNoThrow(try store.remove())
        }
    }

    func testStoreAtomicallyRoundTripsAndReplacesSnapshotJSON() throws {
        try withStore { store, directory in
            let first = makeSnapshot(revision: 1, volatile: [segment("v", "café")])
            let second = makeSnapshot(
                revision: 2,
                finalized: [segment("v", "café ")],
                volatile: [segment("v2", "👋🏽")]
            )

            try store.write(first)
            XCTAssertEqual(try store.read(), first)
            try store.write(second)
            XCTAssertEqual(try store.read(), second)

            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(entries.map(\.lastPathComponent), [DictationSnapshotStore.defaultFilename])
            let encoded = try Data(contentsOf: store.snapshotURL)
            XCTAssertEqual(try JSONDecoder().decode(DictationSnapshot.self, from: encoded), second)
        }
    }

    func testStoreRejectsStaleRevisionWithinSessionWithoutChangingPersistedValue() throws {
        try withStore { store, _ in
            let current = makeSnapshot(revision: 8, volatile: [segment("v", "current")])
            let stale = makeSnapshot(revision: 7, volatile: [segment("v", "stale")])
            try store.write(current)

            XCTAssertThrowsError(try store.write(stale)) { error in
                XCTAssertEqual(
                    error as? DictationSnapshotStoreError,
                    .staleRevision(existing: 8, proposed: 7)
                )
            }
            XCTAssertEqual(try store.read(), current)
        }
    }

    func testStoreRejectsConflictingSameRevisionButAllowsIdempotentRewrite() throws {
        try withStore { store, _ in
            let original = makeSnapshot(revision: 4, volatile: [segment("v", "one")])
            let conflict = makeSnapshot(revision: 4, volatile: [segment("v", "two")])
            try store.write(original)
            XCTAssertNoThrow(try store.write(original))

            XCTAssertThrowsError(try store.write(conflict)) { error in
                XCTAssertEqual(error as? DictationSnapshotStoreError, .conflictingRevision(4))
            }
            XCTAssertEqual(try store.read(), original)
        }
    }

    func testStoreRejectsNewSessionWhileExistingSessionIsActive() throws {
        try withStore { store, _ in
            let existing = makeSnapshot(revision: 99, volatile: [segment("old", "old")])
            try store.write(existing)
            let replacement = makeSnapshot(
                sessionID: otherSessionID,
                revision: 0,
                volatile: [segment("new", "new")]
            )

            XCTAssertThrowsError(try store.write(replacement)) { error in
                XCTAssertEqual(
                    error as? DictationSnapshotStoreError,
                    .activeSessionConflict(existing: sessionID, proposed: otherSessionID)
                )
            }
            XCTAssertEqual(try store.read(), existing)
        }
    }

    func testStoreAllowsNewSessionAtLowerRevisionAfterTerminalSnapshot() throws {
        try withStore { store, _ in
            try store.write(
                makeSnapshot(
                    revision: 99,
                    phase: .finalized,
                    finalized: [segment("old", "old")]
                )
            )
            let replacement = makeSnapshot(
                sessionID: otherSessionID,
                revision: 0,
                volatile: [segment("new", "new")]
            )

            try store.write(replacement)
            XCTAssertEqual(try store.read(), replacement)
        }
    }

    func testTerminalOutboxSurvivesReplacementOfTheLiveSessionSlot() throws {
        try withStore { store, _ in
            let terminal = makeSnapshot(
                revision: 4,
                phase: .finalized,
                finalized: [segment("done", "final text")]
            )
            try store.write(terminal)
            try store.write(makeSnapshot(
                sessionID: otherSessionID,
                revision: 0,
                volatile: [segment("new", "next")]
            ))

            XCTAssertEqual(try store.readTerminal(sessionID: sessionID), terminal)
            XCTAssertEqual(try store.read()?.sessionID, otherSessionID)
        }
    }

    func testTerminalOutboxCleanupUsesBoundedRetention() throws {
        try withStore { store, _ in
            let terminal = makeSnapshot(revision: 1, phase: .cancelled)
            try store.write(terminal)
            let terminalURL = store.terminalDirectoryURL
                .appendingPathComponent(sessionID.uuidString + ".json")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: terminalURL.path
            )

            store.removeTerminalSnapshots(
                olderThan: 60,
                now: Date(timeIntervalSince1970: 120)
            )

            XCTAssertNil(try store.readTerminal(sessionID: sessionID))
        }
    }

    func testStoreValidatesBeforeWritingAndValidatesDecodedJSON() throws {
        try withStore { store, _ in
            let invalid = makeSnapshot(schemaVersion: 2)
            XCTAssertThrowsError(try store.write(invalid)) { error in
                XCTAssertEqual(
                    error as? DictationSnapshotValidationError,
                    .unsupportedSchemaVersion(2)
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))

            try FileManager.default.createDirectory(
                at: store.snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(invalid)
            try data.write(to: store.snapshotURL, options: .atomic)
            XCTAssertThrowsError(try store.read()) { error in
                XCTAssertEqual(
                    error as? DictationSnapshotValidationError,
                    .unsupportedSchemaVersion(2)
                )
            }
        }
    }

    // MARK: - Revision planning

    func testFirstSnapshotInsertsRenderedTextAndCapturesOwnershipProof() throws {
        let snapshot = makeSnapshot(
            revision: 1,
            finalized: [segment("f", "Hello ")],
            volatile: [segment("v", "wor")]
        )
        let context = makeContext(before: "Draft: ", after: " suffix")

        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot,
            in: context,
            from: nil
        )

        XCTAssertEqual(
            decision,
            .apply(
                edit: TypingEdit(insertion: "Hello wor"),
                nextState: DictationRevisionState(
                    sessionID: sessionID,
                    appliedRevision: 1,
                    finalizedSegments: [segment("f", "Hello ")],
                    volatileText: "wor",
                    anchorSuffix: "Draft: Hello ",
                    documentIdentifier: "document-a",
                    contextAfterInput: " suffix"
                )
            )
        )
    }

    func testEmptyFirstSnapshotAdvancesWithoutEditing() throws {
        let decision = try DictationRevisionPlanner.plan(
            snapshot: makeSnapshot(revision: 1),
            in: makeContext(before: "existing"),
            from: nil
        )

        XCTAssertEqual(
            decision,
            .advanceWithoutEdit(
                nextState: DictationRevisionState(
                    sessionID: sessionID,
                    appliedRevision: 1,
                    finalizedSegments: [],
                    volatileText: "",
                    anchorSuffix: "existing",
                    documentIdentifier: "document-a",
                    contextAfterInput: nil
                )
            )
        )
    }

    func testRevisionReplacesOnlyPreviouslyOwnedVolatileSuffix() throws {
        let previous = try stateAfterFirst(
            makeSnapshot(
                revision: 1,
                finalized: [segment("f", "Speech: ")],
                volatile: [segment("v", "recog")]
            ),
            contextBefore: "Note. "
        )
        let next = makeSnapshot(
            revision: 2,
            finalized: [segment("f", "Speech: ")],
            volatile: [segment("v", "recognition")]
        )

        let decision = try DictationRevisionPlanner.plan(
            snapshot: next,
            in: makeContext(before: "Note. Speech: recog"),
            from: previous
        )

        XCTAssertEqual(
            edit(from: decision),
            TypingEdit(deleteBackwardCount: 5, insertion: "recognition")
        )
        XCTAssertEqual(state(from: decision)?.volatileText, "recognition")
        XCTAssertEqual(state(from: decision)?.finalizedSegments, [segment("f", "Speech: ")])
        XCTAssertEqual(state(from: decision)?.anchorSuffix, "Note. Speech: ")
    }

    func testRevisionPromotesVolatileSegmentAndAppendsNewVolatileText() throws {
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, volatile: [segment("s1", "hel")]),
            contextBefore: "Prefix "
        )
        let next = makeSnapshot(
            revision: 2,
            finalized: [segment("s1", "hello ")],
            volatile: [segment("s2", "wor")]
        )

        let decision = try DictationRevisionPlanner.plan(
            snapshot: next,
            in: makeContext(before: "Prefix hel"),
            from: previous
        )

        XCTAssertEqual(
            edit(from: decision),
            TypingEdit(deleteBackwardCount: 3, insertion: "hello wor")
        )
        XCTAssertEqual(state(from: decision)?.finalizedSegments, [segment("s1", "hello ")])
        XCTAssertEqual(state(from: decision)?.volatileText, "wor")
        XCTAssertEqual(state(from: decision)?.anchorSuffix, "Prefix hello ")
    }

    func testFinalizedTerminalRevisionPromotesTextAndClearsVolatileOwnership() throws {
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, volatile: [segment("s", "hel")]),
            contextBefore: ""
        )
        let terminal = makeSnapshot(
            revision: 2,
            phase: .finalized,
            finalized: [segment("s", "hello")]
        )

        let decision = try DictationRevisionPlanner.plan(
            snapshot: terminal,
            in: makeContext(before: "hel"),
            from: previous
        )

        XCTAssertEqual(edit(from: decision), TypingEdit(deleteBackwardCount: 3, insertion: "hello"))
        XCTAssertEqual(state(from: decision)?.volatileText, "")
        XCTAssertEqual(state(from: decision)?.finalizedSegments, [segment("s", "hello")])
    }

    func testCancelledTerminalRevisionDeletesOnlyVolatileText() throws {
        let finalized = [segment("f", "kept ")]
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, finalized: finalized, volatile: [segment("v", "draft")]),
            contextBefore: "Before "
        )
        let cancelled = makeSnapshot(revision: 2, phase: .cancelled, finalized: finalized)

        let decision = try DictationRevisionPlanner.plan(
            snapshot: cancelled,
            in: makeContext(before: "Before kept draft"),
            from: previous
        )

        XCTAssertEqual(edit(from: decision), TypingEdit(deleteBackwardCount: 5))
        XCTAssertEqual(state(from: decision)?.volatileText, "")
        XCTAssertEqual(state(from: decision)?.finalizedSegments, finalized)
    }

    func testNoTextChangeAdvancesRevisionWithoutEdit() throws {
        let finalized = [segment("f", "fixed")]
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, finalized: finalized),
            contextBefore: "Before "
        )
        let next = makeSnapshot(revision: 2, finalized: finalized)

        let decision = try DictationRevisionPlanner.plan(
            snapshot: next,
            in: makeContext(before: "Before fixed"),
            from: previous
        )

        guard case let .advanceWithoutEdit(nextState) = decision else {
            return XCTFail("Expected state-only revision advance, got \(decision)")
        }
        XCTAssertEqual(nextState.appliedRevision, 2)
        XCTAssertEqual(nextState.finalizedSegments, finalized)
    }

    func testUnicodeReplacementCountsExtendedGraphemeClusters() throws {
        let volatile = "café 👩‍💻 🇺🇸"
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, volatile: [segment("v", volatile)]),
            contextBefore: "Prompt: "
        )
        let next = makeSnapshot(revision: 2, volatile: [segment("v", "café revised")])

        let decision = try DictationRevisionPlanner.plan(
            snapshot: next,
            in: makeContext(before: "Prompt: " + volatile),
            from: previous
        )

        XCTAssertEqual(
            edit(from: decision),
            TypingEdit(deleteBackwardCount: volatile.count, insertion: "café revised")
        )
        XCTAssertEqual(volatile.count, 8)
    }

    func testAnchorIsBoundedToLastSixtyFourCharacters() throws {
        let prefix = String(repeating: "x", count: 100)
        let snapshot = makeSnapshot(
            revision: 1,
            finalized: [segment("f", "final")],
            volatile: [segment("v", "draft")]
        )

        let state = try stateAfterFirst(snapshot, contextBefore: prefix)

        XCTAssertEqual(state.anchorSuffix.count, DictationRevisionPlanner.maximumAnchorLength)
        XCTAssertEqual(state.anchorSuffix, String((prefix + "final").suffix(64)))
    }

    func testPlannerRejectsUnavailableContextAndChangedSelection() throws {
        let snapshot = makeSnapshot(revision: 1, volatile: [segment("v", "text")])

        XCTAssertEqual(
            try DictationRevisionPlanner.plan(
                snapshot: snapshot,
                in: makeContext(before: nil),
                from: nil
            ),
            .reject(.unavailableContext)
        )
        XCTAssertEqual(
            try DictationRevisionPlanner.plan(
                snapshot: snapshot,
                in: makeContext(before: "", selected: "selected"),
                from: nil
            ),
            .reject(.selectedTextChanged)
        )
    }

    func testPlannerRejectsDocumentChange() throws {
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, volatile: [segment("v", "old")]),
            contextBefore: ""
        )
        let context = DictationDocumentContext(
            documentIdentifier: "document-b",
            contextBeforeInput: "old",
            selectedText: nil,
            contextAfterInput: nil
        )

        XCTAssertEqual(
            try DictationRevisionPlanner.plan(
                snapshot: makeSnapshot(revision: 2, volatile: [segment("v", "new")]),
                in: context,
                from: previous
            ),
            .reject(.documentChanged)
        )
    }

    func testPlannerRejectsCursorMoveOrChangesOnEitherSide() throws {
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, volatile: [segment("v", "old")]),
            contextBefore: "prefix ",
            contextAfter: " after"
        )
        let next = makeSnapshot(revision: 2, volatile: [segment("v", "new")])

        XCTAssertEqual(
            try DictationRevisionPlanner.plan(
                snapshot: next,
                in: makeContext(before: "prefix old", after: " changed"),
                from: previous
            ),
            .reject(.cursorOrSurroundingTextChanged)
        )
        XCTAssertEqual(
            try DictationRevisionPlanner.plan(
                snapshot: next,
                in: makeContext(before: "prefix edited-old", after: " after"),
                from: previous
            ),
            .reject(.cursorOrSurroundingTextChanged)
        )
    }

    func testPlannerRejectsSessionChangeAndNonIncreasingRevision() throws {
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 7, volatile: [segment("v", "old")]),
            contextBefore: ""
        )
        let context = makeContext(before: "old")

        XCTAssertEqual(
            try DictationRevisionPlanner.plan(
                snapshot: makeSnapshot(
                    sessionID: otherSessionID,
                    revision: 8,
                    volatile: [segment("v", "new")]
                ),
                in: context,
                from: previous
            ),
            .reject(.sessionChanged)
        )

        for revision: UInt64 in [6, 7] {
            XCTAssertEqual(
                try DictationRevisionPlanner.plan(
                    snapshot: makeSnapshot(revision: revision, volatile: [segment("v", "new")]),
                    in: context,
                    from: previous
                ),
                .reject(.staleRevision)
            )
        }
    }

    func testPlannerRejectsTruncatedReorderedOrMutatedFinalizedHistory() throws {
        let oldFinalized = [segment("f1", "one "), segment("f2", "two ")]
        let previous = try stateAfterFirst(
            makeSnapshot(revision: 1, finalized: oldFinalized),
            contextBefore: ""
        )
        let context = makeContext(before: "one two ")
        let invalidHistories: [[DictationSegment]] = [
            [oldFinalized[0]],
            [oldFinalized[1], oldFinalized[0]],
            [segment("f1", "ONE "), oldFinalized[1]],
            [oldFinalized[0], segment("different-id", "two ")],
        ]

        for finalized in invalidHistories {
            XCTAssertEqual(
                try DictationRevisionPlanner.plan(
                    snapshot: makeSnapshot(revision: 2, finalized: finalized),
                    in: context,
                    from: previous
                ),
                .reject(.finalizedHistoryChanged)
            )
        }
    }

    func testPlannerValidatesSnapshotBeforeConsideringDocumentContext() {
        let invalid = makeSnapshot(schemaVersion: 5)

        XCTAssertThrowsError(
            try DictationRevisionPlanner.plan(
                snapshot: invalid,
                in: makeContext(before: nil, selected: "changed"),
                from: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? DictationSnapshotValidationError,
                .unsupportedSchemaVersion(5)
            )
        }
    }

    func testClaimStoreRoundTripsPendingAndCommittedTransactionReceipts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakFree-ClaimTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationClaimStore(receiptURL: directory.appendingPathComponent("claim.json"))
        let snapshot = makeSnapshot(revision: 3, volatile: [segment("volatile", "hello")])
        let state = try stateAfterFirst(snapshot, contextBefore: "Before ", contextAfter: " after")
        let edit = TypingEdit(deleteBackwardCount: 2, insertion: "world")

        let pending = DictationClaimReceipt(
            pending: state,
            edit: edit,
            contextBeforeInput: "Before he",
            contextAfterInput: " after"
        )
        try store.write(pending)
        XCTAssertEqual(try store.read(), pending)

        let committed = DictationClaimReceipt(revisionState: state)
        try store.write(committed)
        XCTAssertEqual(try store.read(), committed)
    }

    func testLegacyClaimReceiptDecodesAsCommitted() throws {
        struct LegacyReceipt: Codable {
            let revisionState: DictationRevisionState
            let savedAt: Date
        }
        let snapshot = makeSnapshot(revision: 1, volatile: [segment("volatile", "hello")])
        let state = try stateAfterFirst(snapshot, contextBefore: "")
        let date = Date(timeIntervalSince1970: 123)
        let data = try JSONEncoder().encode(LegacyReceipt(revisionState: state, savedAt: date))

        let decoded = try JSONDecoder().decode(DictationClaimReceipt.self, from: data)

        XCTAssertEqual(decoded.phase, .committed)
        XCTAssertEqual(decoded.revisionState, state)
        XCTAssertEqual(decoded.savedAt, date)
        XCTAssertNil(decoded.plannedEdit)
    }

    func testTerminalClaimReceiptRedactsTranscriptAndNearbyContext() throws {
        let snapshot = makeSnapshot(
            revision: 7,
            phase: .finalized,
            finalized: [segment("final", "sensitive dictated text")]
        )
        let state = try stateAfterFirst(snapshot, contextBefore: "nearby host text")

        let receipt = DictationClaimReceipt(
            revisionState: state,
            redactingTerminalText: true
        )

        XCTAssertEqual(receipt.revisionState.sessionID, state.sessionID)
        XCTAssertEqual(receipt.revisionState.appliedRevision, 7)
        XCTAssertEqual(receipt.revisionState.documentIdentifier, state.documentIdentifier)
        XCTAssertTrue(receipt.revisionState.finalizedSegments.isEmpty)
        XCTAssertEqual(receipt.revisionState.volatileText, "")
        XCTAssertEqual(receipt.revisionState.anchorSuffix, "")
        XCTAssertNil(receipt.revisionState.contextAfterInput)
    }

    // MARK: - Helpers

    private func segment(_ id: String, _ text: String) -> DictationSegment {
        DictationSegment(id: id, text: text)
    }

    private func makeSnapshot(
        schemaVersion: Int = DictationSnapshot.currentSchemaVersion,
        sessionID: UUID? = nil,
        revision: UInt64 = 0,
        phase: DictationSessionPhase = .active,
        finalized: [DictationSegment] = [],
        volatile: [DictationSegment] = []
    ) -> DictationSnapshot {
        DictationSnapshot(
            schemaVersion: schemaVersion,
            sessionID: sessionID ?? self.sessionID,
            revision: revision,
            phase: phase,
            finalizedSegments: finalized,
            volatileSegments: volatile
        )
    }

    private func makeContext(
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

    private func stateAfterFirst(
        _ snapshot: DictationSnapshot,
        contextBefore: String,
        contextAfter: String? = nil
    ) throws -> DictationRevisionState {
        let decision = try DictationRevisionPlanner.plan(
            snapshot: snapshot,
            in: makeContext(before: contextBefore, after: contextAfter),
            from: nil
        )
        guard let state = state(from: decision) else {
            throw TestFailure.missingState
        }
        return state
    }

    private func edit(from decision: DictationRevisionDecision) -> TypingEdit? {
        guard case let .apply(edit, _) = decision else { return nil }
        return edit
    }

    private func state(from decision: DictationRevisionDecision) -> DictationRevisionState? {
        switch decision {
        case let .apply(_, nextState), let .advanceWithoutEdit(nextState):
            return nextState
        case .reject:
            return nil
        }
    }

    private func withStore(
        _ body: (DictationSnapshotStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakFree-DictationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationSnapshotStore(appGroupContainerURL: directory)
        try body(store, directory)
    }

    private enum TestFailure: Error {
        case missingState
    }
}
