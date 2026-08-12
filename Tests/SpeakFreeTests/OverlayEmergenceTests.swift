// ai-suggestion:unverified · session:9bb7d552-ac60-4aeb-b987-841018c752be · 2026-08-12
//
// Timeline tests for the locked record-icon entry (2026-08-12): Ring Pulses ×
// Purple bloom, build/26-08-12-record-icon-animation/LOCKED-SETTINGS.json.
//
// The drawing itself is visual and reviewed through HUD_RENDER_DIR stills; what
// is asserted here is the part that can silently drift: the geometry landing on
// the shipped card × 1.2, the sequence starting on a bare dot and ending on the
// finished pill, and every ring staying inside the window it is drawn into.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class OverlayEmergenceTests: XCTestCase {

    private typealias E = OverlayEmergence

    private func geo(_ scale: CGFloat = E.endScale) -> E.Geometry {
        E.geometry(centerX: 0, centerY: 0, scale: scale)
    }

    // MARK: - Geometry is the shipped card, scaled

    /// At scale 1 the emergence geometry must reproduce the shipping pill exactly,
    /// which is what makes `endScale` an honest multiplier rather than a redesign.
    func test_geometryAtScale1MatchesShippedPill() {
        let g = geo(1.0)
        let shipped = OverlayContentView.pillSize(for: .recording)
        XCTAssertEqual(g.cardWidth, shipped.width, accuracy: 0.001)
        XCTAssertEqual(g.cardHeight, shipped.height, accuracy: 0.001)
        XCTAssertEqual(g.count, 16)
        XCTAssertEqual(g.barWidth, 2, accuracy: 0.001)
        XCTAssertEqual(g.barGap, 3, accuracy: 0.001)
        XCTAssertEqual(g.cornerRadius, 20, accuracy: 0.001)
        XCTAssertEqual(g.borderWidth, 1, accuracy: 0.001)
        XCTAssertEqual(g.maxBarHeight, 20, accuracy: 0.001)
    }

    func test_geometryAtLockedScaleIs1Point2x() {
        let g = geo()
        let shipped = OverlayContentView.pillSize(for: .recording)
        XCTAssertEqual(g.cardWidth, shipped.width * 1.2, accuracy: 0.001)   // 150
        XCTAssertEqual(g.cardHeight, shipped.height * 1.2, accuracy: 0.001) // 45.6
        XCTAssertEqual(g.fieldWidth, 92.4, accuracy: 0.001)
        XCTAssertEqual(g.half, 45.0, accuracy: 0.001)
        XCTAssertEqual(g.cornerRadius, 24, accuracy: 0.001)
        XCTAssertEqual(g.borderWidth, 1.2, accuracy: 0.001)
    }

    func test_barsAreEvenlySpacedAndCentred() {
        let g = geo()
        XCTAssertEqual(g.homeX(0), -45, accuracy: 0.001)
        XCTAssertEqual(g.homeX(15), 45, accuracy: 0.001)
        for i in 1..<g.count {
            XCTAssertEqual(g.homeX(i) - g.homeX(i - 1), g.barWidth + g.barGap, accuracy: 0.001)
        }
        // The field is symmetric about the mark, so the outermost bars are equidistant.
        XCTAssertEqual(g.distPx(0), g.distPx(15), accuracy: 0.001)
        XCTAssertEqual(g.dist(0), 1, accuracy: 0.001)
        XCTAssertEqual(g.dist(7), 0.5 / 7.5, accuracy: 0.001)
    }

    /// Silence must render as a round dot, not a zero-height sliver.
    func test_barHeightFloorIsBarWidth() {
        let g = geo()
        XCTAssertEqual(g.targetHeight(level: 0), g.barWidth, accuracy: 0.001)
        XCTAssertEqual(g.targetHeight(level: -1), g.barWidth, accuracy: 0.001)
        XCTAssertEqual(g.targetHeight(level: 1), 24, accuracy: 0.001)
    }

    // MARK: - Easing

    func test_easeOutQuintEndpointsAndMonotonicity() {
        XCTAssertEqual(E.easeOutQuint(0), 0, accuracy: 1e-9)
        XCTAssertEqual(E.easeOutQuint(1), 1, accuracy: 1e-9)
        XCTAssertEqual(E.easeOutQuint(-5), 0, accuracy: 1e-9)
        XCTAssertEqual(E.easeOutQuint(5), 1, accuracy: 1e-9)
        // Quintic ease-out is front-loaded: half the progress is most of the motion.
        XCTAssertGreaterThan(E.easeOutQuint(0.5), 0.9)
        var last: CGFloat = -1
        for step in 0...100 {
            let v = E.easeOutQuint(CGFloat(step) / 100)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    func test_smoothstepEndpoints() {
        XCTAssertEqual(E.smoothstep(0), 0, accuracy: 1e-9)
        XCTAssertEqual(E.smoothstep(1), 1, accuracy: 1e-9)
        XCTAssertEqual(E.smoothstep(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(E.smoothstep(-3), 0, accuracy: 1e-9)
        XCTAssertEqual(E.smoothstep(3), 1, accuracy: 1e-9)
    }

    // MARK: - Armed state: a bare red dot, nothing else

    /// Michael's spec for the opening frame is "bare red record dot with a thin
    /// white pulsing ring — NO card". The bloom exists at p = 0 but is a disc
    /// exactly the size of the mark, so the mark covers it completely.
    func test_atProgressZeroTheCardIsHiddenBehindTheMark() {
        let g = geo()
        let card = E.card(progress: 0, geometry: g)
        XCTAssertEqual(card.width, E.dotRadius * 2, accuracy: 0.001)
        XCTAssertEqual(card.height, E.dotRadius * 2, accuracy: 0.001)
        XCTAssertEqual(card.cornerRadius, E.dotRadius, accuracy: 0.001)
        XCTAssertEqual(card.borderAlpha, 0, accuracy: 1e-9)
        // The mark is at full size and fully opaque, so it hides the disc entirely.
        XCTAssertEqual(E.markRadius(progress: 0), E.dotRadius, accuracy: 0.001)
        XCTAssertEqual(E.markAlpha(progress: 0), 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(E.markRadius(progress: 0), card.width / 2)
    }

    func test_atProgressZeroNoBarsAndNoEmergencePulses() {
        let g = geo()
        XCTAssertTrue(E.emergencePulses(progress: 0, geometry: g).isEmpty)
        XCTAssertEqual(E.solidity(progress: 0, geometry: g).reduce(0, +), 0, accuracy: 1e-9)
    }

    func test_idleRingIsPresentWhileArmedAndGoneByTheFadeFraction() {
        XCTAssertEqual(E.idleRingFade(progress: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(E.idleRingFade(progress: E.ringFadeFraction), 0, accuracy: 1e-9)
        XCTAssertEqual(E.idleRingFade(progress: 1), 0, accuracy: 1e-9)

        // Two outward wavelets plus the steady hairline, hairline painted last.
        let rings = E.idleRings(progress: 0, time: 0.3)
        XCTAssertEqual(rings.count, 3)
        let hairline = rings[2]
        XCTAssertEqual(hairline.radius, E.dotRadius + E.ringGap, accuracy: 0.001)
        XCTAssertEqual(hairline.lineWidth, E.ringWidth, accuracy: 0.001)
        XCTAssertEqual(hairline.alpha, E.ringAlpha, accuracy: 0.001)

        XCTAssertTrue(E.idleRings(progress: 0.5, time: 0.3).isEmpty)
    }

    /// The wavelets travel outward and dim as they go — that is the "pulsing" read.
    func test_idleWaveletsExpandAndFadeOverTheirCycle() {
        let base = E.dotRadius + E.ringGap
        var previous: E.RingStroke?
        // 1.5s period; sample the first wavelet across one full cycle.
        for step in 0..<15 {
            let t = CGFloat(step) * 0.1
            let w = E.idleRings(progress: 0, time: t)[0]
            XCTAssertGreaterThanOrEqual(w.radius, base - 0.001)
            XCTAssertLessThanOrEqual(w.radius, base + 14 * E.idleAmp + 0.001)
            if let p = previous, w.radius > p.radius {
                XCTAssertLessThan(w.alpha, p.alpha + 1e-9, "a wavelet must dim as it expands")
            }
            previous = w
        }
        // The two wavelets are half a cycle apart, so they are never coincident.
        let rings = E.idleRings(progress: 0, time: 0.37)
        XCTAssertNotEqual(rings[0].radius, rings[1].radius, accuracy: 0.001)
    }

    // MARK: - The emergence

    /// Three pulses, fired in sequence, each fading to nothing exactly at the reach.
    func test_pulsesFireInSequenceAndFadeOutAtTheReach() {
        let g = geo()
        XCTAssertEqual(g.reach, g.half + E.wakePx, accuracy: 0.001)

        XCTAssertEqual(E.emergencePulses(progress: 0.02, geometry: g).count, 1,
                       "only the first pulse has launched this early")
        let all = E.emergencePulses(progress: 0.5, geometry: g)
        XCTAssertEqual(all.count, E.pulseCount)

        // Fired in order, so the earliest pulse is always the outermost.
        for i in 1..<all.count {
            XCTAssertLessThan(all[i].radius, all[i - 1].radius)
        }
        for stroke in all {
            XCTAssertGreaterThanOrEqual(stroke.alpha, 0)
            XCTAssertLessThanOrEqual(stroke.alpha, E.ringAlpha)
        }
        // At p = 1 every pulse has reached full extent, so all have faded out.
        for stroke in E.emergencePulses(progress: 1, geometry: g) {
            XCTAssertEqual(stroke.alpha, 0, accuracy: 1e-9)
            XCTAssertEqual(stroke.radius, E.dotRadius + E.ringGap + g.reach, accuracy: 0.001)
        }
    }

    /// Each pulse hardens the bars it passes one step further, so solidity only
    /// ever rises and the centre leads the edges.
    func test_solidityRisesMonotonicallyAndSpreadsFromTheCentre() {
        let g = geo()
        var previous = [CGFloat](repeating: 0, count: g.count)
        for step in 0...100 {
            let p = CGFloat(step) / 100
            let solid = E.solidity(progress: p, geometry: g)
            XCTAssertEqual(solid.count, g.count)
            for i in 0..<g.count {
                XCTAssertGreaterThanOrEqual(solid[i], previous[i] - 1e-9,
                                            "bar \(i) unsolidified at p=\(p)")
                XCTAssertLessThanOrEqual(solid[i], 1 + 1e-9)
            }
            // Inner bars are nearer the mark, so a pulse always reaches them first.
            XCTAssertGreaterThanOrEqual(solid[8], solid[15] - 1e-9)
            XCTAssertGreaterThanOrEqual(solid[7], solid[0] - 1e-9)
            previous = solid
        }
    }

    /// The stepwise read: solidity is the sum of exactly `pulseCount` ramps, each
    /// worth at most 1/K, so a bar can never be more solid than the pulses fired so
    /// far allow. (The ramps overlap — quintic easing launches pulse 2 before pulse
    /// 1 has cleared the inner bars — so these are soft steps, not plateaus.)
    func test_solidityIsCappedByTheNumberOfFiredPulses() {
        let g = geo()
        for step in 0...400 {
            let p = CGFloat(step) / 400
            let fired = E.emergencePulses(progress: p, geometry: g).count
            let cap = CGFloat(fired) / CGFloat(E.pulseCount)
            for value in E.solidity(progress: p, geometry: g) {
                XCTAssertLessThanOrEqual(value, cap + 1e-9,
                                         "only \(fired) pulse(s) fired at p=\(p)")
            }
        }
        // Every bar is fully solid once all three fronts have cleared it.
        XCTAssertEqual(E.solidity(progress: 1, geometry: g).min() ?? 0, 1, accuracy: 1e-9)
        // A single fired pulse can never finish a bar on its own.
        let early = E.solidity(progress: 0.02, geometry: g)
        XCTAssertEqual(E.emergencePulses(progress: 0.02, geometry: g).count, 1)
        XCTAssertLessThanOrEqual(early.max() ?? 0, 1.0 / CGFloat(E.pulseCount) + 1e-9)
    }

    /// The card blooms out of the mark, reaches full size at p = 0.6, and only
    /// then is the border allowed to be fully up.
    func test_cardBloomsMonotonicallyAndSettlesAt60Percent() {
        let g = geo()
        var lastW: CGFloat = -1
        var lastBorder: CGFloat = -1
        for step in 0...100 {
            let p = CGFloat(step) / 100
            let card = E.card(progress: p, geometry: g)
            XCTAssertGreaterThanOrEqual(card.width, lastW - 1e-9)
            XCTAssertGreaterThanOrEqual(card.borderAlpha, lastBorder - 1e-9)
            XCTAssertEqual(card.alpha, E.cardOpacity, accuracy: 1e-9,
                           "fill opacity is constant; only the size and border animate")
            lastW = card.width
            lastBorder = card.borderAlpha
        }
        let settled = E.card(progress: 0.6, geometry: g)
        XCTAssertEqual(settled.width, g.cardWidth, accuracy: 0.001)
        XCTAssertEqual(settled.height, g.cardHeight, accuracy: 0.001)
        XCTAssertEqual(settled.cornerRadius, g.cornerRadius, accuracy: 0.001)
        // The border starts fading up at 0.35 and is not fully on before then.
        XCTAssertEqual(E.card(progress: 0.35, geometry: g).borderAlpha, 0, accuracy: 1e-9)
    }

    // MARK: - The end state

    /// p = 1 is simultaneously the last frame of the entry and the permanent
    /// steady state: the shipped purple pill at 1.2×, lilac bars, no red left.
    func test_endStateIsTheShippedPillWithNoMarkAndNoRings() {
        let g = geo()
        let card = E.card(progress: 1, geometry: g)
        XCTAssertEqual(card.width, g.cardWidth, accuracy: 0.001)
        XCTAssertEqual(card.height, g.cardHeight, accuracy: 0.001)
        XCTAssertEqual(card.cornerRadius, g.cornerRadius, accuracy: 0.001)
        XCTAssertEqual(card.alpha, E.cardOpacity, accuracy: 1e-9)
        XCTAssertEqual(card.borderAlpha, E.borderOpacity, accuracy: 1e-9)

        XCTAssertEqual(E.markAlpha(progress: 1), 0, accuracy: 1e-9)
        XCTAssertTrue(E.idleRings(progress: 1, time: 12.3).isEmpty)

        for i in 0..<g.count {
            XCTAssertEqual(E.barRedness(index: i, progress: 1, geometry: g), 0, accuracy: 1e-9)
            let color = E.barColor(index: i, progress: 1, geometry: g)
            XCTAssertEqual(color.r, E.barLilac.r, accuracy: 1e-9)
            XCTAssertEqual(color.g, E.barLilac.g, accuracy: 1e-9)
            XCTAssertEqual(color.b, E.barLilac.b, accuracy: 1e-9)
        }
    }

    /// Bars are born out of the mark's red and cool outward-in, never the reverse.
    func test_barsCoolFromRedToLilacAndTheCentreStaysReddest() {
        let g = geo()
        XCTAssertEqual(E.barRedness(index: 8, progress: 0, geometry: g), 1 - g.dist(8) * 0.4,
                       accuracy: 1e-9)
        XCTAssertGreaterThan(E.barRedness(index: 8, progress: 0.3, geometry: g),
                             E.barRedness(index: 0, progress: 0.3, geometry: g))
        var last = CGFloat.greatestFiniteMagnitude
        for step in 0...100 {
            let v = E.barRedness(index: 8, progress: CGFloat(step) / 100, geometry: g)
            XCTAssertLessThanOrEqual(v, last + 1e-9)
            last = v
        }
        let born = E.barColor(index: 8, progress: 0, geometry: g)
        XCTAssertGreaterThan(born.r, born.b, "a newly born bar carries the mark's red")
    }

    func test_markShrinksAndFadesOut() {
        var lastR = CGFloat.greatestFiniteMagnitude
        var lastA = CGFloat.greatestFiniteMagnitude
        for step in 0...100 {
            let p = CGFloat(step) / 100
            let r = E.markRadius(progress: p)
            let a = E.markAlpha(progress: p)
            XCTAssertLessThanOrEqual(r, lastR + 1e-9)
            XCTAssertLessThanOrEqual(a, lastA + 1e-9)
            lastR = r
            lastA = a
        }
        XCTAssertEqual(E.markRadius(progress: 1), E.dotRadius * E.endIconScale, accuracy: 0.001)
    }

    func test_mixIsLinearAndHitsBothEndpoints() {
        let a: OverlayEmergence.RGB = (0, 0, 0)
        let b: OverlayEmergence.RGB = (1, 0.5, 0.25)
        XCTAssertEqual(E.mix(a, b, 0).r, 0, accuracy: 1e-9)
        XCTAssertEqual(E.mix(a, b, 1).g, 0.5, accuracy: 1e-9)
        XCTAssertEqual(E.mix(a, b, 0.5).b, 0.125, accuracy: 1e-9)
    }

    // MARK: - The window has to hold the whole animation

    /// A ring clipped by the window edge reads as a stray corner arc, which is the
    /// exact artifact the design lab was built to eliminate. Sweep the whole
    /// timeline and prove nothing ever leaves the canvas.
    func test_noRingOrCardEverLeavesTheOverlayWindow() {
        let size = OverlayContentView.emergenceSize
        let g = E.geometry(centerX: size.width / 2, centerY: size.height / 2)
        let halfW = size.width / 2
        let halfH = size.height / 2

        for step in 0...200 {
            let p = CGFloat(step) / 200
            for stroke in E.emergencePulses(progress: p, geometry: g) where stroke.alpha > 0.001 {
                let extent = stroke.radius + stroke.lineWidth / 2
                XCTAssertLessThanOrEqual(extent, halfH,
                                         "emergence pulse clipped vertically at p=\(p)")
                XCTAssertLessThanOrEqual(extent, halfW,
                                         "emergence pulse clipped horizontally at p=\(p)")
            }
            for stroke in E.idleRings(progress: p, time: CGFloat(step) * 0.05) {
                XCTAssertLessThanOrEqual(stroke.radius + stroke.lineWidth / 2, halfH)
            }
            let card = E.card(progress: p, geometry: g)
            XCTAssertLessThanOrEqual(card.width / 2, halfW)
            XCTAssertLessThanOrEqual(card.height / 2, halfH)
        }
        // Bars are inside the card, and the tallest possible bar still fits.
        XCTAssertLessThanOrEqual(g.maxBarHeight / 2, halfH)
        XCTAssertLessThanOrEqual(g.half + g.barWidth / 2, halfW)
    }

    func test_emergenceWindowIsBigEnoughForTheWidestInk() {
        let size = OverlayContentView.emergenceSize
        let g = E.geometry(centerX: 0, centerY: 0)
        XCTAssertGreaterThanOrEqual(min(size.width, size.height) / 2,
                                    E.maxInkRadius(geometry: g))
    }

    // MARK: - Which style gets it

    /// An unset `overlayStyle` resolves to 5 (`AppDelegate`: `min(5, max(1, ?? 5))`),
    /// so 5 is the variant Michael actually sees and the one that carries the entry.
    func test_onlyStyle5UsesTheEmergenceEntry() {
        for style in 1...4 {
            XCTAssertFalse(OverlayContentView.usesEmergenceEntry(style: style))
        }
        XCTAssertTrue(OverlayContentView.usesEmergenceEntry(style: 5))
        XCTAssertFalse(OverlayContentView.usesEmergenceEntry(style: 6))

        // Mirrors AppDelegate's resolution of an unset overlayStyle, without
        // reading the real config file.
        let unset: Int? = nil
        XCTAssertTrue(OverlayContentView.usesEmergenceEntry(style: min(5, max(1, unset ?? 5))))
    }

    // MARK: - Live wiring

    /// The waveform state used to advance only inside `drawBars`, which the
    /// prominent banner never calls — so its bars sat frozen at zero for the whole
    /// recording. The advance now lives on the animation tick.
    func test_advanceLevelsMovesBarsWithoutDrawing() {
        let view = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 340, height: 170))
        view.overlayState = .recording
        view.prominent = true
        view.style = 5
        view.audioLevel = 0.9
        for _ in 0..<12 { view.tick += 1; view.advanceLevels() }
        let moved = (0..<16).contains { view.levelForRender($0) > 0.05 }
        XCTAssertTrue(moved, "bars must react to the mic without a draw pass")
    }

    func test_advanceLevelsIsInertWhileTranscribing() {
        let view = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 340, height: 170))
        view.overlayState = .transcribing
        view.audioLevel = 1.0
        for _ in 0..<12 { view.tick += 1; view.advanceLevels() }
        for i in 0..<16 { XCTAssertEqual(view.levelForRender(i), 0, accuracy: 1e-9) }
    }

    // MARK: - DEFECT 1: recalibrated speech gate + onset (2026-08-12)
    //
    // Calibrated against 15 real dictations (~/.config/speakfree/recordings): per
    // 33ms window, room-tone `currentLevel` ≈ 0.012–0.028, speech ≈ 0.050–0.162.
    // These tests double as mutation tests — reverting the noise floor to the old
    // 0.08, or moving the onset threshold off the speech band, fails at least one.

    /// The gate must flatten room tone to nothing and lift ordinary speech into a
    /// visibly tall bar. The OLD 0.08 floor collapsed median speech (0.085) to ~0.03
    /// and is exactly what left the bars flat — so the p50 assertion is the guard.
    func test_waveformGateFlattensRoomToneAndLiftsSpeech() {
        XCTAssertEqual(E.waveformLevel(currentLevel: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(E.waveformLevel(currentLevel: 0.017), 0, accuracy: 1e-9) // silence p50
        XCTAssertEqual(E.waveformLevel(currentLevel: 0.028), 0, accuracy: 1e-9) // silence p90
        XCTAssertGreaterThan(E.waveformLevel(currentLevel: 0.050), 0.2)  // speech p10 visible
        XCTAssertGreaterThan(E.waveformLevel(currentLevel: 0.085), 0.4)  // speech p50 tall
        XCTAssertGreaterThan(E.waveformLevel(currentLevel: 0.162), 0.85) // speech p90 near full
        XCTAssertEqual(E.waveformLevel(currentLevel: 1.0), 1, accuracy: 1e-9)
    }

    func test_waveformGateIsMonotonicAndClamped() {
        var last: CGFloat = -1
        for step in 0...200 {
            let v = E.waveformLevel(currentLevel: CGFloat(step) / 200)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
            last = v
        }
        // Negative (impossible) input clamps to zero, not NaN from pow.
        XCTAssertEqual(E.waveformLevel(currentLevel: -1), 0, accuracy: 1e-9)
    }

    /// Onset must latch on ordinary speech within the hold window and NEVER on room
    /// tone. Raising the threshold above the speech level, or dropping it into room
    /// tone, breaks exactly one of these two — the required mutation coverage.
    func test_onsetLatchesOnSpeechWithinHoldTicks() {
        var d = E.SpeechOnsetDetector()
        let speech = E.waveformLevel(currentLevel: 0.085) // median speech
        var ticks = 0
        var fired = false
        for _ in 0..<10 {
            ticks += 1
            fired = d.update(audioLevel: speech)
            if fired { break }
        }
        XCTAssertTrue(fired, "median speech must latch the emergence")
        XCTAssertLessThanOrEqual(ticks, E.onsetHoldTicks) // ~66ms
    }

    func test_onsetNeverLatchesOnRoomTone() {
        var d = E.SpeechOnsetDetector()
        let tone = E.waveformLevel(currentLevel: 0.028) // silence p90 → 0
        for _ in 0..<300 { _ = d.update(audioLevel: tone) }
        XCTAssertFalse(d.fired)
    }

    /// A lone loud window (breath/keyboard click) must not latch — the reason onset
    /// needs `onsetHoldTicks` consecutive ticks instead of a bare peak trigger.
    func test_onsetRejectsSingleWindowSpike() {
        var d = E.SpeechOnsetDetector()
        _ = d.update(audioLevel: 1.0)
        XCTAssertFalse(d.fired, "one loud window is a click/breath, not onset")
        for _ in 0..<20 { _ = d.update(audioLevel: 0) }
        XCTAssertFalse(d.fired)
        _ = d.update(audioLevel: 0.6)
        XCTAssertTrue(d.update(audioLevel: 0.6), "sustained speech latches")
    }

    func test_onsetStaysLatchedOnceFired() {
        var d = E.SpeechOnsetDetector()
        for _ in 0..<E.onsetHoldTicks { _ = d.update(audioLevel: 0.6) }
        XCTAssertTrue(d.fired)
        for _ in 0..<50 { XCTAssertTrue(d.update(audioLevel: 0), "onset is a one-way door") }
    }

    /// End-to-end DEFECT-1 guard through the real content view: feeding the view a
    /// realistic per-tick speech level (median speech through the gate) must latch
    /// heardSpeech, while pure room tone must never latch it.
    func test_liveViewLatchesEmergenceOnSpeechButNotRoomTone() {
        let speechView = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        speechView.style = 5
        speechView.prominent = true
        let speech = E.waveformLevel(currentLevel: 0.085)
        for _ in 0..<4 where !speechView.heardSpeech {
            if speechView.onsetDetector.update(audioLevel: speech) { speechView.heardSpeech = true }
        }
        XCTAssertTrue(speechView.heardSpeech)

        let toneView = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        toneView.style = 5
        let tone = E.waveformLevel(currentLevel: 0.028)
        for _ in 0..<200 where !toneView.heardSpeech {
            if toneView.onsetDetector.update(audioLevel: tone) { toneView.heardSpeech = true }
        }
        XCTAssertFalse(toneView.heardSpeech)
    }

    // MARK: - DEFECT 2: streaming text can't disturb the emergence window

    func test_emergenceSuppressesStreamingTextOnlyDuringRecording() {
        XCTAssertTrue(OverlayContentView.emergenceSuppressesStreamingText(style: 5, state: .recording))
        // Post-release states are allowed through so the overlay exits normally.
        XCTAssertFalse(OverlayContentView.emergenceSuppressesStreamingText(style: 5, state: .transcribing))
        // Non-emergence styles keep their streaming-text pill.
        XCTAssertFalse(OverlayContentView.emergenceSuppressesStreamingText(style: 1, state: .recording))
        XCTAssertFalse(OverlayContentView.emergenceSuppressesStreamingText(style: 3, state: .recording))
    }

    // MARK: - DEFECT 3: bigger resting record mark, same end pill

    func test_recordMarkIsEnlargedButEndPillUnchanged() {
        XCTAssertGreaterThanOrEqual(E.dotRadius, 14, "the resting record mark must be meaningfully bigger")
        let g = geo()
        let shipped = OverlayContentView.pillSize(for: .recording)
        // The settled purple pill is still exactly the shipped pill × endScale.
        XCTAssertEqual(g.cardWidth, shipped.width * E.endScale, accuracy: 0.001)
        XCTAssertEqual(g.cardHeight, shipped.height * E.endScale, accuracy: 0.001)
        // The armed disc (card at p=0) is the enlarged mark's size…
        XCTAssertEqual(E.card(progress: 0, geometry: g).width, E.dotRadius * 2, accuracy: 0.001)
        // …and the window still holds the widest ink at the larger mark.
        let size = OverlayContentView.emergenceSize
        XCTAssertGreaterThanOrEqual(min(size.width, size.height) / 2, E.maxInkRadius(geometry: g))
    }

    // MARK: - DEFECT 4: adaptive outline contrast

    func test_luminanceOfKnownColors() {
        XCTAssertEqual(E.luminance((0, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(E.luminance((1, 1, 1)), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(E.luminance((0, 1, 0)), E.luminance((1, 0, 0)))  // green brightest
        XCTAssertGreaterThan(E.luminance((1, 0, 0)), E.luminance((0, 0, 1)))  // red over blue
    }

    func test_brightBackdropGivesDarkOutlineDarkGivesLight() {
        let onWhite = E.adaptiveOutlineColor(backgroundLuminance: E.luminance((0.95, 0.95, 0.95)))
        XCTAssertEqual(onWhite.r, E.outlineDark.r, accuracy: 1e-9)
        XCTAssertEqual(onWhite.g, E.outlineDark.g, accuracy: 1e-9)
        let onDark = E.adaptiveOutlineColor(backgroundLuminance: E.luminance((0.08, 0.08, 0.08)))
        XCTAssertEqual(onDark.r, E.outlineLight.r, accuracy: 1e-9)
        // The decision flips exactly at the threshold (bright side → dark).
        XCTAssertEqual(E.adaptiveOutlineColor(backgroundLuminance: E.outlineLumThreshold).r,
                       E.outlineDark.r, accuracy: 1e-9)
        XCTAssertEqual(E.adaptiveOutlineColor(backgroundLuminance: E.outlineLumThreshold - 0.001).r,
                       E.outlineLight.r, accuracy: 1e-9)
    }

    func test_averageLuminanceEmptyIsNilAndMeanIsCorrect() {
        XCTAssertNil(E.averageLuminance(of: []), "no pixels → nil so the caller fails safe")
        let mean = E.averageLuminance(of: [(0, 0, 0), (1, 1, 1)])
        XCTAssertNotNil(mean)
        XCTAssertEqual(mean!, 0.5, accuracy: 1e-9)
    }
}
