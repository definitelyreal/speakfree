// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.5 — Unit tests for RecordingOverlay screen selection.
//
// The pure function under test is `bestScreenIndex(windowFrame:screenFrames:)`.
// It is entirely geometric — no AppKit display state, no NSScreen objects needed.
//
// Test scenarios (per the task spec):
//   (A) Window fully on the secondary screen → secondary screen wins.
//   (B) Window straddling two screens → screen with larger overlap wins.
//   (C) Window nil → fallback (nil index).
//   (D) No screens → fallback (nil index).
//   (E) Window entirely off all screens → fallback (nil index).
//   (F) Window fully on primary (index 0) with secondary present → primary wins.
//   (G) Window straddling, exactly equal overlap → first matching screen wins (tie-break).

import XCTest
@testable import SpeakFreeLib

final class RecordingOverlayScreenTests: XCTestCase {

    // Two side-by-side screens:
    //   primary  (index 0): x=0..1920,     y=0..1080
    //   secondary (index 1): x=1920..3840, y=0..1080
    private let primaryFrame   = NSRect(x: 0,    y: 0, width: 1920, height: 1080)
    private let secondaryFrame = NSRect(x: 1920, y: 0, width: 1920, height: 1080)

    // MARK: (A) Window fully on secondary screen

    func test_windowOnSecondaryScreen_returnsSecondaryIndex() {
        let windowFrame = NSRect(x: 2000, y: 100, width: 800, height: 600)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame, secondaryFrame])
        XCTAssertEqual(result, 1, "Window fully on secondary (x=2000) must map to index 1")
    }

    // MARK: (B) Window straddling two screens — larger overlap wins

    func test_windowStraddling_largerOverlapWins() {
        // Window from x=1700 to x=2300: 220px on primary, 380px on secondary
        let windowFrame = NSRect(x: 1700, y: 100, width: 600, height: 400)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame, secondaryFrame])
        // Overlap with primary:   (1920-1700)*400 = 220*400 = 88_000
        // Overlap with secondary: (2300-1920)*400 = 380*400 = 152_000  ← larger
        XCTAssertEqual(result, 1, "Secondary overlap (152 000 px²) > primary (88 000 px²) → index 1")
    }

    func test_windowStraddling_largerOverlapOnPrimaryWins() {
        // Window from x=1500 to x=2100: 420px on primary, 180px on secondary
        let windowFrame = NSRect(x: 1500, y: 100, width: 600, height: 400)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame, secondaryFrame])
        // Overlap with primary:   (1920-1500)*400 = 420*400 = 168_000  ← larger
        // Overlap with secondary: (2100-1920)*400 = 180*400 =  72_000
        XCTAssertEqual(result, 0, "Primary overlap (168 000 px²) > secondary (72 000 px²) → index 0")
    }

    // MARK: (C) nil window frame → nil (caller falls back to main)

    func test_nilWindowFrame_returnsNil() {
        let result = bestScreenIndex(windowFrame: nil, screenFrames: [primaryFrame, secondaryFrame])
        XCTAssertNil(result, "nil windowFrame must return nil (caller uses main screen fallback)")
    }

    // MARK: (D) Empty screen list → nil

    func test_noScreens_returnsNil() {
        let windowFrame = NSRect(x: 100, y: 100, width: 800, height: 600)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [])
        XCTAssertNil(result, "Empty screen list must return nil")
    }

    // MARK: (E) Window entirely outside all screens → nil

    func test_windowOffAllScreens_returnsNil() {
        // Window to the right of both screens (x=4000)
        let windowFrame = NSRect(x: 4000, y: 100, width: 800, height: 600)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame, secondaryFrame])
        XCTAssertNil(result, "Window with zero intersection on any screen must return nil")
    }

    // MARK: (F) Window fully on primary with secondary present

    func test_windowOnPrimaryScreen_returnsPrimaryIndex() {
        let windowFrame = NSRect(x: 100, y: 100, width: 800, height: 600)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame, secondaryFrame])
        XCTAssertEqual(result, 0, "Window fully on primary (x=100) must map to index 0")
    }

    // MARK: (G) Equal overlap — first match (stable, deterministic)

    func test_equalOverlap_firstScreenWins() {
        // Window perfectly centered on the boundary: 300px on each side
        let windowFrame = NSRect(x: 1620, y: 100, width: 600, height: 400)
        // Overlap with primary:   (1920-1620)*400 = 300*400 = 120_000
        // Overlap with secondary: (2220-1920)*400 = 300*400 = 120_000
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame, secondaryFrame])
        // The loop uses strict `>` so the first maximum found (index 0) is kept on a tie.
        XCTAssertEqual(result, 0, "Tie should keep the first screen found (stable, deterministic)")
    }

    // MARK: Single-screen setup

    func test_singleScreen_alwaysReturnsThatScreen() {
        let windowFrame = NSRect(x: 200, y: 200, width: 400, height: 300)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [primaryFrame])
        XCTAssertEqual(result, 0)
    }

    // MARK: Vertical stack (stacked monitors, different Y origins)

    func test_verticalStack_windowOnTopScreen() {
        let bottomScreen = NSRect(x: 0, y:    0, width: 2560, height: 1440)
        let topScreen    = NSRect(x: 0, y: 1440, width: 2560, height: 1440)
        let windowFrame  = NSRect(x: 400, y: 1600, width: 800, height: 600)
        let result = bestScreenIndex(windowFrame: windowFrame, screenFrames: [bottomScreen, topScreen])
        XCTAssertEqual(result, 1, "Window at y=1600 is fully on the top screen (index 1)")
    }

    // MARK: - overlayScreenIndex fallback chain (the "overlay on wrong screen" fix)

    private let mouseOnSecondary = NSPoint(x: 2500, y: 500)
    private let mouseOnPrimary   = NSPoint(x: 500, y: 500)

    func test_focusedWindowWins_overMouse() {
        // Focused window known and on secondary → used even if mouse is on primary.
        let win = NSRect(x: 2000, y: 100, width: 800, height: 600)
        let idx = overlayScreenIndex(windowFrame: win, mouseLocation: mouseOnPrimary,
                                     screenFrames: [primaryFrame, secondaryFrame], mainIndex: 0)
        XCTAssertEqual(idx, 1, "focused window on secondary should win")
    }

    func test_nilWindow_fallsBackToMouseScreen_notMain() {
        // AX focused-window unavailable (the common Electron/fullscreen case): the
        // overlay must follow the MOUSE (secondary), NOT collapse to main (index 0).
        let idx = overlayScreenIndex(windowFrame: nil, mouseLocation: mouseOnSecondary,
                                     screenFrames: [primaryFrame, secondaryFrame], mainIndex: 0)
        XCTAssertEqual(idx, 1, "nil window + mouse on secondary → secondary, not main")
    }

    func test_nilWindow_mouseOffAllScreens_fallsBackToMain() {
        let off = NSPoint(x: -5000, y: -5000)
        let idx = overlayScreenIndex(windowFrame: nil, mouseLocation: off,
                                     screenFrames: [primaryFrame, secondaryFrame], mainIndex: 1)
        XCTAssertEqual(idx, 1, "no window, mouse off-screen → main index")
    }

    func test_nilEverything_fallsBackToFirstScreen_neverNilWithScreens() {
        let idx = overlayScreenIndex(windowFrame: nil, mouseLocation: NSPoint(x: -1, y: -1),
                                     screenFrames: [primaryFrame, secondaryFrame], mainIndex: nil)
        XCTAssertEqual(idx, 0, "with screens present, never nil — falls back to first")
    }

    func test_overlayScreenIndex_noScreens_returnsNil() {
        let idx = overlayScreenIndex(windowFrame: nil, mouseLocation: .zero,
                                     screenFrames: [], mainIndex: nil)
        XCTAssertNil(idx)
    }
}
