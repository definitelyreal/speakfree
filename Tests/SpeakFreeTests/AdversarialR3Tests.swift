// Claude · 2026-07-15 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
//
// Round-3 lifecycle fixes:
//   L2  the dual-capture .bt.raw.txt sidecar write goes through RecordingStore.saveBluetoothRaw,
//       which takes the mutationLock and honors a wav-exists guard so a concurrent "Delete All"
//       can't resurrect an orphaned transcript sidecar.
//   L4  the AX SelectedText set is now three-way: .success → inserted, .cannotComplete (the 0.5s
//       messaging-cap timeout, which may have COMMITTED) → concealed clipboard (never retype/
//       duplicate), any other error → keystroke fallback. The per-element 2s messaging timeout is
//       removed. The AXError→decision mapping is the pure `TextInserter.axSetOutcome`.
//
// L1 (defer the ENTIRE config reload while fn is held) and L3 (HotkeyManager global-monitor
// lifecycle: no double-install; drop the fallback when the tap comes up) have NO unit-test seam —
// they live inside AppDelegate's private dictation lifecycle and real NSEvent-monitor / CGEventTap
// installation respectively. Those are covered by the code change + review, not a test here.

import XCTest
import ApplicationServices
@testable import SpeakFreeLib

final class AdversarialR3Tests: XCTestCase {

    // MARK: - L4: axSetOutcome three-way decision (pure)

    /// A committing set reports success → insert is done, no fallback.
    func test_l4_axSetOutcome_successIsInserted() {
        XCTAssertEqual(TextInserter.axSetOutcome(.success), .inserted)
    }

    /// The whole point of L4: `.cannotComplete` is the timeout code returned under the process-wide
    /// 0.5s messaging cap. The set MAY have committed, so we must NOT retype (would duplicate) —
    /// route to the concealed clipboard + notify instead.
    func test_l4_axSetOutcome_cannotCompleteConceals() {
        XCTAssertEqual(TextInserter.axSetOutcome(.cannotComplete), .concealClipboard,
                       "a 0.5s-cap timeout may have committed — conceal, never retype")
    }

    /// Any other AXError is a clean rejection (nothing was written) → safe to retype via keystrokes.
    func test_l4_axSetOutcome_otherErrorsFallBackToKeystrokes() {
        for error in [AXError.failure, .illegalArgument, .invalidUIElement,
                      .attributeUnsupported, .actionUnsupported, .notImplemented,
                      .apiDisabled, .noValue, .notEnoughPrecision] {
            XCTAssertEqual(TextInserter.axSetOutcome(error), .fallbackToKeystrokes,
                           "\(error) is a clean rejection — keystroke fallback, not conceal")
        }
    }

    // MARK: - L2: dual-capture bt sidecar write is lock-guarded + wav-existence gated

    private func withScratchConfigDir(_ body: (URL) throws -> Void) rethrows {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-r3-\(UUID().uuidString)")
        Config.configDirOverride = scratch
        defer {
            Config.configDirOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        try? FileManager.default.createDirectory(at: RecordingStore.recordingsDir,
                                                 withIntermediateDirectories: true)
        try body(scratch)
    }

    /// Happy path: the primary wav is still on disk, so the bt sidecar is written.
    func test_l2_saveBluetoothRaw_writesWhenRecordingPresent() throws {
        try withScratchConfigDir { _ in
            let mainURL = RecordingStore.newRecordingURL()
            let btURL = mainURL.deletingPathExtension().appendingPathExtension("bt.wav")
            try Data("primary-audio".utf8).write(to: mainURL)
            try Data("bt-audio".utf8).write(to: btURL)

            RecordingStore.saveBluetoothRaw(text: "hello world", btAudioURL: btURL, mainAudioURL: mainURL)

            let sidecar = btURL.deletingPathExtension().appendingPathExtension("raw.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path),
                          "bt sidecar must be written while the recording exists")
            XCTAssertEqual(try? String(contentsOf: sidecar, encoding: .utf8), "hello world")
        }
    }

    /// The race L2 fixes: a "Delete All" removed both wavs during the detached transcription. The
    /// guard must skip the write so no orphaned `.bt.raw.txt` is resurrected with no audio behind it.
    func test_l2_saveBluetoothRaw_skipsWhenRecordingDeleted() throws {
        try withScratchConfigDir { _ in
            let mainURL = RecordingStore.newRecordingURL()
            let btURL = mainURL.deletingPathExtension().appendingPathExtension("bt.wav")
            // Simulate Delete All having already run: neither wav is on disk.

            RecordingStore.saveBluetoothRaw(text: "resurrected", btAudioURL: btURL, mainAudioURL: mainURL)

            let sidecar = btURL.deletingPathExtension().appendingPathExtension("raw.txt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                           "a deleted recording must NOT resurrect a bt transcript sidecar")
        }
    }

    /// The bt.wav alone (main pruned, bt still present) also counts as "recording present".
    func test_l2_saveBluetoothRaw_writesWhenOnlyBtWavPresent() throws {
        try withScratchConfigDir { _ in
            let mainURL = RecordingStore.newRecordingURL()
            let btURL = mainURL.deletingPathExtension().appendingPathExtension("bt.wav")
            try Data("bt-audio".utf8).write(to: btURL)   // only the bt track survives

            RecordingStore.saveBluetoothRaw(text: "kept", btAudioURL: btURL, mainAudioURL: mainURL)

            let sidecar = btURL.deletingPathExtension().appendingPathExtension("raw.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path),
                          "bt sidecar must be written when the bt wav still exists")
        }
    }
}
