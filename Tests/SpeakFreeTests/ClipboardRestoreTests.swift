// ai-suggestion:unverified · session:019fecb2-8ac5-7423-90a3-d70aac039387 · 2026-08-10
// Originally Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
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
@testable import SpeakFreeLib

final class ClipboardRestoreTests: XCTestCase {

    func test_localRestoreFinishesBeforeFollowUpPasteAtHalfSecond() {
        XCTAssertLessThan(TextInserter.localClipboardRestoreDelay, 0.5)
        XCTAssertGreaterThanOrEqual(TextInserter.localClipboardRestoreDelay, 0.2,
                                    "Electron/contenteditable targets need a settle beat")
        XCTAssertGreaterThan(TextInserter.remoteClipboardRestoreDelay,
                             TextInserter.localClipboardRestoreDelay)
    }

    /// A private, uniquely-named pasteboard so tests never touch `NSPasteboard.general`.
    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("speakfree.test.clipboard.\(UUID().uuidString)"))
    }

    // MARK: - The bug: changeCount delta is +1, not +2

    func test_codexAndChatGPTUseClipboardPastePath() {
        XCTAssertTrue(TextInserter.prefersClipboardPaste(bundleID: "com.openai.codex"))
        XCTAssertTrue(TextInserter.prefersClipboardPaste(bundleID: "com.openai.chat"))
    }

    /// 2026-07-28: dictation silently vanished in Claude for Desktop. It is Electron, but was
    /// absent from the clipboard-paste set, so insertion fell through to `insertViaAccessibility`
    /// — whose `AXUIElementSetAttributeValue` returned success into a contenteditable that never
    /// rendered the text. Routing it to clipboard paste also gives it the Electron AX-context
    /// unlock and the prepend-probe suppression, both keyed off this same predicate.
    func test_claudeDesktopUsesClipboardPastePath() {
        XCTAssertTrue(TextInserter.prefersClipboardPaste(bundleID: "com.anthropic.claudefordesktop"))
    }

    func test_ordinaryImageClipboardCanBeSavedButCapRemainsFinite() {
        XCTAssertTrue(TextInserter.canSafelySaveClipboard(byteSize: 4_610 * 1_024))
        XCTAssertFalse(TextInserter.canSafelySaveClipboard(byteSize: 32 * 1_024 * 1_024))
    }

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

    // MARK: - Backstop-only restore redesign (2026-08-14, post adversarial review)

    func test_backstopDelay_electronAndRemoteAreLong_nativeIsShort() {
        // Electron/remote must be long enough that a slow app reads the paste BEFORE restore.
        // (Not asserting an empirical consume latency — that is validated by the paste logs, not
        // by a constant compared to itself.)
        XCTAssertEqual(TextInserter.restoreBackstopDelay(route: .electron),
                       TextInserter.electronClipboardRestoreDelay)
        XCTAssertEqual(TextInserter.restoreBackstopDelay(route: .remote),
                       TextInserter.remoteClipboardRestoreDelay)
        XCTAssertEqual(TextInserter.restoreBackstopDelay(route: .native),
                       TextInserter.localClipboardRestoreDelay)
        XCTAssertGreaterThan(TextInserter.restoreBackstopDelay(route: .electron),
                             TextInserter.restoreBackstopDelay(route: .native))
    }

    /// Saved-original staleness (adversarial review F2): reuse the pending snapshot ONLY while our
    /// own write is still live. If the user copied something (changeCount moved) — no Command press
    /// needed — the snapshot is stale and must be re-taken so their fresh copy is what we restore.
    func test_shouldReusePendingSnapshot_onlyWhenOurWriteIsStillLive() {
        // No pending restore → always snapshot fresh.
        XCTAssertFalse(TextInserter.shouldReusePendingSnapshot(
            pendingWrittenChangeCount: nil, currentChangeCount: 5))
        // Pending and clipboard unchanged since our write → reuse the true original.
        XCTAssertTrue(TextInserter.shouldReusePendingSnapshot(
            pendingWrittenChangeCount: 7, currentChangeCount: 7))
        // Pending but the user copied since (changeCount advanced) → snapshot is stale, re-take.
        XCTAssertFalse(TextInserter.shouldReusePendingSnapshot(
            pendingWrittenChangeCount: 7, currentChangeCount: 9),
            "a user copy between dictations must not be clobbered by a stale snapshot")
    }

    /// Real save→overwrite→restore round-trip on a scratch pasteboard, exercising the restore
    /// decision the backstop uses (no timers): restore fires only when our write is still live.
    func test_restoreRoundTrip_restoresOriginalOnlyWhenWriteStillLive() {
        let pb = makeScratchPasteboard()
        let inserter = TextInserter()
        pb.clearContents()
        pb.setString("USER ORIGINAL", forType: .string)
        let saved = inserter.savePasteboardForTest(pb)

        let written = TextInserter.writeTransientString("dictation", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "dictation")

        // Nobody else touched it → restore.
        if TextInserter.shouldRestoreClipboard(currentChangeCount: pb.changeCount,
                                               writtenChangeCount: written) {
            inserter.restorePasteboardForTest(pb, items: saved)
        }
        XCTAssertEqual(pb.string(forType: .string), "USER ORIGINAL")

        // Now simulate the user copying AFTER our write → restore must be skipped.
        let written2 = TextInserter.writeTransientString("dictation2", to: pb)
        pb.clearContents(); pb.setString("USER COPIED THIS", forType: .string)
        XCTAssertFalse(TextInserter.shouldRestoreClipboard(currentChangeCount: pb.changeCount,
                                                           writtenChangeCount: written2))
    }

}
