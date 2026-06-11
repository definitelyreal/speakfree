// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// AR-2 round-1, finding 4 — clipboard restore guard used the wrong changeCount delta (+2), so the
// user's clipboard was NEVER restored after a paste insertion.
//
// `pasteViaClipboard` does `clearContents()` + `writeObjects()` then, after a delay, restores the
// prior clipboard IFF nothing else has touched it. The prior guard required
// `changeCount == before + 2` ("clearContents + setString"), but that whole write sequence advances
// `changeCount` by exactly ONE generation — so the equality was never satisfied and restore never
// ran. These tests pin the real changeCount contract on a NAMED (non-general) NSPasteboard so they
// neither clobber the developer's clipboard nor depend on a real Cmd+V.

import XCTest
import AppKit
@testable import OpenWisprLib

final class ClipboardRestoreTests: XCTestCase {

    /// A private, uniquely-named pasteboard so tests never touch `NSPasteboard.general`.
    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("speakfree.test.clipboard.\(UUID().uuidString)"))
    }

    // MARK: - The bug: changeCount delta is +1, not +2

    /// THE root-cause assertion. `clearContents()` + transient `writeObjects()` advances the
    /// pasteboard's changeCount by exactly ONE generation. The old guard expected +2, so it could
    /// never fire. This locks the real OS behavior the fix relies on.
    func test_transientWrite_advancesChangeCount_byExactlyOne() {
        let pb = makeScratchPasteboard()
        let before = pb.changeCount

        let afterWrite = TextInserter.writeTransientString("dictated text", to: pb)

        XCTAssertEqual(afterWrite, before + 1,
                       "clearContents + writeObjects must advance changeCount by exactly 1 (the old +2 guard was unreachable)")
    }

    // MARK: - Restore decision

    /// When nothing else touched the clipboard after our write, the restore must fire — the whole
    /// point of the fix (previously it never did).
    func test_shouldRestore_whenNothingElseTouchedClipboard_isTrue() {
        let pb = makeScratchPasteboard()
        let writtenChangeCount = TextInserter.writeTransientString("dictated text", to: pb)

        XCTAssertTrue(
            TextInserter.shouldRestoreClipboard(currentChangeCount: pb.changeCount,
                                                writtenChangeCount: writtenChangeCount),
            "restore must fire when our write is still the live clipboard content")
    }

    /// If the user (or another app) writes to the clipboard after our paste, we must NOT clobber
    /// their newer content — the restore is skipped.
    func test_shouldRestore_whenUserWroteAfter_isFalse() {
        let pb = makeScratchPasteboard()
        let writtenChangeCount = TextInserter.writeTransientString("dictated text", to: pb)

        // Simulate the user copying something else after our paste.
        pb.clearContents()
        pb.setString("user copied this", forType: .string)

        XCTAssertFalse(
            TextInserter.shouldRestoreClipboard(currentChangeCount: pb.changeCount,
                                                writtenChangeCount: writtenChangeCount),
            "restore must be skipped when the user/another app wrote to the clipboard after our paste")
    }

    /// The old `before + 2` predicate, evaluated against the REAL post-write changeCount, would
    /// have been false — documenting precisely why the original clipboard was never restored.
    func test_oldPlusTwoGuard_wouldHaveBeenUnreachable() {
        let pb = makeScratchPasteboard()
        let before = pb.changeCount
        _ = TextInserter.writeTransientString("dictated text", to: pb)

        XCTAssertNotEqual(pb.changeCount, before + 2,
                          "the old guard (== before + 2) never matched real OS behavior → restore was dead code")
    }

    // MARK: - End-to-end round-trip on a named pasteboard

    /// Full restore round-trip: a user's clipboard is saved, we overwrite it with dictated text,
    /// then (nothing else having touched it) we restore — and the user's original string is back.
    /// Mirrors what `pasteViaClipboard`'s delayed closure does, minus the real Cmd+V.
    func test_roundTrip_restoresOriginalUserClipboard() {
        let pb = makeScratchPasteboard()

        // User's pre-existing clipboard.
        pb.clearContents()
        pb.setString("USER-ORIGINAL-CLIPBOARD", forType: .string)
        let userValue = pb.string(forType: .string)
        XCTAssertEqual(userValue, "USER-ORIGINAL-CLIPBOARD")

        let inserter = TextInserter()
        let saved = inserter.savePasteboardForTest(pb)

        // Our dictated write.
        let writtenChangeCount = TextInserter.writeTransientString("DICTATED-TEXT", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "DICTATED-TEXT")

        // Restore decision fires (nothing else touched it).
        XCTAssertTrue(TextInserter.shouldRestoreClipboard(currentChangeCount: pb.changeCount,
                                                          writtenChangeCount: writtenChangeCount))
        inserter.restorePasteboardForTest(pb, items: saved)

        XCTAssertEqual(pb.string(forType: .string), "USER-ORIGINAL-CLIPBOARD",
                       "after restore, the user's original clipboard content must be back")
    }
}
