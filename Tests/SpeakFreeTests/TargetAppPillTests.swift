import XCTest
@testable import SpeakFreeLib

final class TargetAppPillTests: XCTestCase {

    // MARK: - Style resolution

    func testUnsetOverlayStyleResolvesToThePill() {
        XCTAssertEqual(TargetAppPill.resolvedStyle(configured: nil), TargetAppPill.style)
        XCTAssertTrue(TargetAppPill.usesPill(style: TargetAppPill.resolvedStyle(configured: nil)))
    }

    func testLegacyStylesStaySelectable() {
        for legacy in 1...5 {
            XCTAssertEqual(TargetAppPill.resolvedStyle(configured: legacy), legacy)
            XCTAssertFalse(TargetAppPill.usesPill(style: legacy))
        }
    }

    func testOutOfRangeStyleClampsIntoTheValidRange() {
        XCTAssertEqual(TargetAppPill.resolvedStyle(configured: 0), 1)
        XCTAssertEqual(TargetAppPill.resolvedStyle(configured: 99), TargetAppPill.style)
    }

    func testOverlayDefaultsToThePillBeforeAnyRecording() {
        // Errors can be shown before the first record-start sets the style.
        XCTAssertTrue(TargetAppPill.usesPill(style: RecordingOverlay().style))
    }

    // MARK: - Scrolling waveform

    private let silence = [CGFloat](repeating: 0, count: TargetAppPill.historyLength)
    private let travel = TargetAppPill.maxBarHeight - TargetAppPill.dashHeight

    /// A one-frame burst of sound, then `frames` frames of silence.
    private func historyAfterBurst(frames: Int) -> [CGFloat] {
        var history = TargetAppPill.scrolled(silence, adding: 1)
        for _ in 0..<frames { history = TargetAppPill.scrolled(history, adding: 0) }
        return history
    }

    func testSilenceDrawsFlatDashes() {
        let heights = TargetAppPill.barHeights(history: silence)
        XCTAssertEqual(heights.count, TargetAppPill.barCount)
        XCTAssertTrue(heights.allSatisfy { $0 == TargetAppPill.dashHeight })
    }

    func testNewSoundRisesAtTheRightEdge() {
        let justHeard = TargetAppPill.barHeights(history: historyAfterBurst(frames: 0))
        XCTAssertGreaterThan(justHeard.last!, TargetAppPill.dashHeight)
        XCTAssertTrue(justHeard.dropLast().allSatisfy { $0 == TargetAppPill.dashHeight })
        let settled = TargetAppPill.barHeights(history: historyAfterBurst(frames: TargetAppPill.samplesPerBar))
        XCTAssertEqual(settled.last!, TargetAppPill.maxBarHeight, accuracy: 0.001)
    }

    func testABurstTravelsLeftAndLeaves() {
        var lastPeak = TargetAppPill.barCount - 1
        for frames in 0..<(TargetAppPill.historyLength - 1) {
            let heights = TargetAppPill.barHeights(history: historyAfterBurst(frames: frames))
            let peak = heights.firstIndex(of: heights.max()!)!
            XCTAssertLessThanOrEqual(peak, lastPeak, "frame \(frames) moved right")
            lastPeak = peak
        }
        XCTAssertEqual(lastPeak, 0)
        XCTAssertEqual(historyAfterBurst(frames: TargetAppPill.historyLength), silence)
    }

    func testTheWaveformGlidesBetweenBarsInsteadOfJumping() {
        // A burst is handed from bar to bar: no bar moves more than a fraction of its
        // travel per frame, and a bar is always lit while the burst is on the pill.
        let first = (TargetAppPill.samplesPerBar + 1) / 2
        var previous = TargetAppPill.barHeights(history: historyAfterBurst(frames: first - 1))
        for frames in first..<(TargetAppPill.historyLength - TargetAppPill.samplesPerBar) {
            let now = TargetAppPill.barHeights(history: historyAfterBurst(frames: frames))
            for (a, b) in zip(previous, now) {
                XCTAssertLessThanOrEqual(abs(a - b), travel / CGFloat(TargetAppPill.samplesPerBar) + 0.001)
            }
            XCTAssertGreaterThan(now.max()!, TargetAppPill.dashHeight + travel * 0.5)
            previous = now
        }
    }

    func testBarHeightIsClampedToTheLevelRange() {
        let loud = [CGFloat](repeating: 7, count: TargetAppPill.historyLength)
        let negative = [CGFloat](repeating: -3, count: TargetAppPill.historyLength)
        XCTAssertTrue(TargetAppPill.barHeights(history: loud).allSatisfy { $0 == TargetAppPill.maxBarHeight })
        XCTAssertTrue(TargetAppPill.barHeights(history: negative).allSatisfy { $0 == TargetAppPill.dashHeight })
    }

    func testTheViewScrollsALoudMomentAcrossAndOut() {
        let view = TargetAppPillView(frame: NSRect(origin: .zero, size: TargetAppPill.windowSize))
        view.overlayState = .recording
        view.audioLevel = 1
        view.advance()
        view.audioLevel = 0
        XCTAssertGreaterThan(view.barHeights.last!, TargetAppPill.dashHeight)
        for _ in 0..<TargetAppPill.historyLength { view.advance() }
        XCTAssertTrue(view.barHeights.allSatisfy { $0 == TargetAppPill.dashHeight })
    }

    func testTheWaveformRunsAt120StepsASecondAndCrossesInAboutOneSecond() {
        XCTAssertEqual(TargetAppPill.frameRate, 120)
        let seconds = Double(TargetAppPill.samplesPerBar * TargetAppPill.barCount) / Double(TargetAppPill.frameRate)
        XCTAssertGreaterThanOrEqual(seconds, 0.8)
        XCTAssertLessThanOrEqual(seconds, 1.3)
    }

    func testAnimationKeepsPaceWhateverTheDisplayRefreshRate() {
        // A 120Hz display advances one step per frame, a 60Hz display two.
        XCTAssertEqual(TargetAppPill.steps(elapsed: 1.0 / 120, carry: 0).steps, 1)
        XCTAssertEqual(TargetAppPill.steps(elapsed: 1.0 / 60, carry: 0).steps, 2)
        // Fractions of a step carry over instead of being lost.
        var carry = 0.0
        var total = 0
        for _ in 0..<90 {
            let result = TargetAppPill.steps(elapsed: 1.0 / 90, carry: carry)
            total += result.steps
            carry = result.carry
        }
        XCTAssertEqual(total, 120, accuracy: 1)
    }

    func testAStallDoesNotFastForwardTheWaveform() {
        XCTAssertLessThanOrEqual(TargetAppPill.steps(elapsed: 3, carry: 0).steps, 12)
    }

    func testTheViewAdvancesByElapsedTime() {
        let view = TargetAppPillView(frame: NSRect(origin: .zero, size: TargetAppPill.windowSize))
        view.overlayState = .recording
        view.audioLevel = 1
        view.advance(elapsed: 1.0 / 60)
        view.audioLevel = 0
        XCTAssertGreaterThan(view.barHeights.last!, TargetAppPill.dashHeight)
        for _ in 0..<TargetAppPill.historyLength { view.advance(elapsed: 1.0 / 120) }
        XCTAssertTrue(view.barHeights.allSatisfy { $0 == TargetAppPill.dashHeight })
    }

    func testTheWaveformStaysModest() {
        XCTAssertLessThanOrEqual(TargetAppPill.maxBarHeight, 16)
        XCTAssertLessThanOrEqual(TargetAppPill.barAlpha, 0.65)
    }

    // MARK: - Transcribing shimmer

    func testShimmerHighlightTravelsLeftToRight() {
        func peak(_ tick: Int) -> Int {
            let alphas = TargetAppPill.shimmerAlphas(tick: tick)
            return alphas.firstIndex(of: alphas.max()!)!
        }
        let alphas = TargetAppPill.shimmerAlphas(tick: 10)
        XCTAssertEqual(alphas.count, TargetAppPill.barCount)
        XCTAssertTrue(alphas.allSatisfy { $0 >= TargetAppPill.shimmerFloor && $0 <= 1 })
        // A third of a second apart, in animation steps.
        XCTAssertLessThan(peak(TargetAppPill.frameRate / 3), peak(TargetAppPill.frameRate * 2 / 3))
    }

    // MARK: - Following the frontmost app

    func testThePillFollowsTheAppYouSwitchTo() {
        XCTAssertTrue(TargetAppPill.adoptsTarget(bundleID: "com.apple.Notes", ownBundleID: "com.definitelyreal.speakfree"))
    }

    func testThePillNeverNamesSpeakfreeItselfOrAnUnknownApp() {
        XCTAssertFalse(TargetAppPill.adoptsTarget(bundleID: "com.definitelyreal.speakfree",
                                                  ownBundleID: "com.definitelyreal.speakfree"))
        XCTAssertFalse(TargetAppPill.adoptsTarget(bundleID: nil, ownBundleID: "com.definitelyreal.speakfree"))
    }

    // MARK: - Title

    func testRecordingShowsTheTargetAppName() {
        XCTAssertEqual(TargetAppPill.title(state: .recording, appName: "Notes", message: ""), "Notes")
        XCTAssertEqual(TargetAppPill.title(state: .transcribing, appName: "Notes", message: ""), "Notes")
    }

    func testMissingAppNameFallsBackToDictation() {
        XCTAssertEqual(TargetAppPill.title(state: .recording, appName: nil, message: ""), "Dictation")
        XCTAssertEqual(TargetAppPill.title(state: .recording, appName: "", message: ""), "Dictation")
    }

    func testErrorAndStatusMessagesReplaceTheAppName() {
        XCTAssertEqual(
            TargetAppPill.title(state: .error("Microphone unavailable"), appName: "Notes", message: ""),
            "Microphone unavailable")
        XCTAssertEqual(
            TargetAppPill.title(state: .transcribing, appName: "Notes", message: "Copied to clipboard"),
            "Copied to clipboard")
    }

    func testLiveTranscriptDoesNotReplaceTheAppNameWhileRecording() {
        XCTAssertEqual(
            TargetAppPill.title(state: .recording, appName: "Notes", message: "hello wor"), "Notes")
    }

    func testMessagesTakeTheFullRowInsteadOfSharingItWithTheWordmark() {
        XCTAssertTrue(TargetAppPill.showsWordmark(state: .recording, message: ""))
        XCTAssertTrue(TargetAppPill.showsWordmark(state: .recording, message: "hello wor"))
        XCTAssertTrue(TargetAppPill.showsWordmark(state: .transcribing, message: ""))
        XCTAssertFalse(TargetAppPill.showsWordmark(state: .transcribing, message: "Loading speech model…"))
        XCTAssertFalse(TargetAppPill.showsWordmark(
            state: .error("Mic went silent: audio is not being captured"), message: ""))
    }

    // MARK: - Placement

    func testPillSitsAtTheBottomCentreOfTheVisibleScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 805)
        let frame = TargetAppPill.windowFrame(screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.size, TargetAppPill.windowSize)
        // The window carries a glow margin; the visible pill clears the Dock by bottomMargin.
        XCTAssertEqual(frame.minY + TargetAppPill.glowMargin, visible.minY + TargetAppPill.bottomMargin)
    }

    // MARK: - Travelling glow

    func testGlowOrbitsThePillContinuously() {
        XCTAssertEqual(TargetAppPill.glowFraction(tick: 0), 0)
        XCTAssertEqual(TargetAppPill.glowFraction(tick: TargetAppPill.glowPeriodTicks), 0)
        var previous = TargetAppPill.glowFraction(tick: 0)
        for tick in 1..<TargetAppPill.glowPeriodTicks {
            let fraction = TargetAppPill.glowFraction(tick: tick)
            XCTAssertGreaterThan(fraction, previous)
            XCTAssertLessThan(fraction, 1)
            previous = fraction
        }
    }

    func testGlowTravelsAlongThePillEdge() {
        let rect = CGRect(x: 10, y: 20, width: 280, height: 66)
        for step in 0...40 {
            let point = TargetAppPill.perimeterPoint(of: rect, fraction: CGFloat(step) / 40)
            let onVerticalEdge = abs(point.x - rect.minX) < 0.001 || abs(point.x - rect.maxX) < 0.001
            let onHorizontalEdge = abs(point.y - rect.minY) < 0.001 || abs(point.y - rect.maxY) < 0.001
            XCTAssertTrue(onVerticalEdge || onHorizontalEdge, "step \(step) left the edge: \(point)")
            XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(point))
        }
    }

    func testGlowPathIsAClosedLoop() {
        let rect = CGRect(x: 10, y: 20, width: 280, height: 66)
        let start = TargetAppPill.perimeterPoint(of: rect, fraction: 0)
        let end = TargetAppPill.perimeterPoint(of: rect, fraction: 1)
        XCTAssertEqual(start.x, end.x, accuracy: 0.001)
        XCTAssertEqual(start.y, end.y, accuracy: 0.001)
        // Wraps rather than clamping, so a lobe trailing behind fraction 0 stays on the loop.
        let wrapped = TargetAppPill.perimeterPoint(of: rect, fraction: -0.25)
        let direct = TargetAppPill.perimeterPoint(of: rect, fraction: 0.75)
        XCTAssertEqual(wrapped.x, direct.x, accuracy: 0.001)
        XCTAssertEqual(wrapped.y, direct.y, accuracy: 0.001)
    }

    func testGlowIsRedWhileRecordingAndBlueWhileProcessing() {
        XCTAssertEqual(TargetAppPill.glowColour(state: .recording), .red)
        XCTAssertEqual(TargetAppPill.glowColour(state: .transcribing), .blue)
        XCTAssertEqual(TargetAppPill.glowColour(state: .error("Mic died")), .red)
    }

    func testGlowTravelsExceptForErrors() {
        XCTAssertTrue(TargetAppPill.glowTravels(state: .recording))
        XCTAssertTrue(TargetAppPill.glowTravels(state: .transcribing))
        XCTAssertFalse(TargetAppPill.glowTravels(state: .error("Mic died")))
    }

    func testGlowHugsTheEdgeInsteadOfSpillingOut() {
        XCTAssertLessThanOrEqual(TargetAppPill.outerGlowRadius, 12)
    }

    // MARK: - Hover controls

    func testHoveringTheTopHalfOffersFinishAndTheBottomHalfCancel() {
        let pill = CGRect(x: 30, y: 30, width: 280, height: 66)
        XCTAssertEqual(TargetAppPill.hoverAction(at: CGPoint(x: 170, y: 80), in: pill, state: .recording), .finish)
        XCTAssertEqual(TargetAppPill.hoverAction(at: CGPoint(x: 170, y: 40), in: pill, state: .recording), .cancel)
    }

    func testHoverControlsOnlyExistOverThePillWhileRecording() {
        let pill = CGRect(x: 30, y: 30, width: 280, height: 66)
        XCTAssertNil(TargetAppPill.hoverAction(at: CGPoint(x: 10, y: 80), in: pill, state: .recording))
        XCTAssertNil(TargetAppPill.hoverAction(at: CGPoint(x: 170, y: 80), in: pill, state: .transcribing))
        XCTAssertNil(TargetAppPill.hoverAction(at: CGPoint(x: 170, y: 80), in: pill, state: .error("x")))
    }

    func testClickingAHoverControlReportsIt() {
        let view = TargetAppPillView(frame: NSRect(origin: .zero, size: TargetAppPill.windowSize))
        view.overlayState = .recording
        var reported: [TargetAppPill.HoverAction] = []
        view.onHoverAction = { reported.append($0) }
        let pill = view.bounds.insetBy(dx: TargetAppPill.glowMargin, dy: TargetAppPill.glowMargin)
        view.click(at: CGPoint(x: pill.midX, y: pill.maxY - 5))
        view.click(at: CGPoint(x: pill.midX, y: pill.minY + 5))
        view.click(at: CGPoint(x: 2, y: 2))
        XCTAssertEqual(reported, [.finish, .cancel])
    }

    // MARK: - Rendering

    func testPillViewRendersEveryStateOffscreen() throws {
        for state: RecordingOverlay.OverlayState in [.recording, .transcribing, .error("Mic died")] {
            let view = TargetAppPillView(frame: NSRect(origin: .zero, size: TargetAppPill.windowSize))
            view.overlayState = state
            view.appName = "Notes"
            view.audioLevel = 0.8
            view.advance()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            // The centre of the pill body is painted (dark, near-opaque), not left transparent.
            let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            XCTAssertGreaterThan(centre.alphaComponent, 0.9, "state \(state)")
        }
    }
}
