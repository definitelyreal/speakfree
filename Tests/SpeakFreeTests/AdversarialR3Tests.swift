// Claude · 2026-07-15 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
//
// Round-3 lifecycle fixes:
//   L2  covered the dual-capture .bt.raw.txt sidecar WRITE path (RecordingStore.saveBluetoothRaw).
//       Dual capture was removed 2026-08-12, and with it that write path and these tests; the
//       .bt.* READ/exclusion/deletion filters remain (the archive still holds real dual takes).
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
}
