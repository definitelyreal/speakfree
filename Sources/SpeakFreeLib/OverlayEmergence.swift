// ai-suggestion:unverified · session:9bb7d552-ac60-4aeb-b987-841018c752be · 2026-08-12
//
// Recording-overlay ENTRY animation — pure math.
//
// Michael locked this sequence on 2026-08-12 ("I like it a lot."):
// build/26-08-12-record-icon-animation/LOCKED-SETTINGS.json — the "Ring Pulses"
// emergence mechanic crossed with the "Purple bloom" red→purple transition, at
// endScale 1.2. Every constant below is a dial value from that file, and every
// function below is a direct port of the corresponding function in the design
// lab (build/26-08-12-record-icon-animation/lab.html).
//
// The sequence, in order:
//   1. Armed (p = 0): a bare red record dot with a thin white ring that fires two
//      outward wavelets. No card. The purple bloom exists but is a disc exactly
//      the size of the dot, so it is completely hidden behind it.
//   2. First real speech starts the 520ms emergence: three ring pulses sweep
//      outward from the mark, each one solidifying the bars it passes one step
//      further, while the purple disc blooms out into the pill.
//   3. p = 1: the shipped purple card at 1.2×, with lilac bars whose heights and
//      corner radii track the live mic level. Nothing after this is scripted —
//      the steady state IS p = 1, redrawn every frame against real audio, which
//      is what "go back to what it was, animated in relation to speech" means.
//
// This file is deliberately AppKit-free (CoreGraphics types only) so the whole
// timeline is unit-testable without a display.

import CoreGraphics
import Foundation

/// Locked dial values + the pure timeline functions for the record-icon entry.
public enum OverlayEmergence {

    // MARK: - Locked dials (LOCKED-SETTINGS.json)

    /// Emergence duration. Lab dial `emergeMs: 520`.
    public static let emergeDuration: TimeInterval = 0.520
    /// Multiplier on every shipped card/waveform dimension. Lab dial `endScale: 1.2`.
    public static let endScale: CGFloat = 1.2

    // The record mark and its ring. NOT scaled by endScale (the lab does not
    // scale them either — the mark is the same size regardless of the end card).
    public static let dotRadius: CGFloat = 9         // dotR
    public static let ringGap: CGFloat = 4.5         // ringGap
    public static let ringWidth: CGFloat = 1.2       // ringW
    public static let ringAlpha: CGFloat = 0.7       // ringAlpha
    public static let ringFadeFraction: CGFloat = 0.35  // ringFade
    public static let idleAmp: CGFloat = 0.45        // idleAmp
    public static let idleRate: CGFloat = 1          // idleRate
    public static let endIconScale: CGFloat = 0.5    // endIconScale
    public static let endIconAlpha: CGFloat = 0      // endIconAlpha

    // The emergence mechanic.
    public static let pulseCount = 3                 // pulseCount
    public static let wakePx: CGFloat = 16           // wakePx (unscaled, as in the lab)

    // The end card + waveform — shipped geometry, multiplied by endScale in `geometry`.
    public static let barCount = 16                  // barCount
    public static let unscaledBarWidth: CGFloat = 2  // barW
    public static let unscaledBarGap: CGFloat = 3    // barGap
    public static let unscaledMaxBarHeight: CGFloat = 20   // maxH
    public static let unscaledCardPadH: CGFloat = 24 // cardPadH
    public static let unscaledCardPadV: CGFloat = 18 // cardPadV
    public static let unscaledCornerRadius: CGFloat = 20   // cardCornerR
    public static let unscaledBorderWidth: CGFloat = 1     // borderW
    public static let cardOpacity: CGFloat = 0.6     // cardOpacity
    public static let borderOpacity: CGFloat = 0.8   // borderOp
    public static let barAlpha: CGFloat = 0.75       // barAlpha
    public static let heat: CGFloat = 1              // heat

    // MARK: - Palette
    //
    // Lifted from the shipped overlay, except `barLilac`, which is the lab's
    // `BARS.lilac` (locked as `barColor: "lilac"`). Mixing happens component-wise
    // in sRGB, exactly as the lab's `mixc` does — NOT via NSColor.blended, whose
    // colour-space conversion lands somewhere else.

    public typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

    /// `bannerRed` #ED2231.
    public static let red: RGB = (0.93, 0.13, 0.19)
    /// The record disc #F23B40 — what the mark itself is painted with.
    public static let discRed: RGB = (0.95, 0.23, 0.25)
    /// Card gradient start #400D59.
    public static let purpleA: RGB = (0.25, 0.05, 0.35)
    /// Card gradient end #661A8C.
    public static let purpleB: RGB = (0.40, 0.10, 0.55)
    /// Card border #8026B3.
    public static let borderColor: RGB = (0.50, 0.15, 0.70)
    /// Locked bar colour (`barColor: "lilac"`).
    public static let barLilac: RGB = (217.0 / 255, 204.0 / 255, 230.0 / 255)
    /// Locked ring colour (`ringColor: "white"`).
    public static let ringColor: RGB = (1, 1, 1)

    public static func mix(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
        (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    // MARK: - Scalar helpers (lab: clamp01 / lerp / smooth / EASES.easeOutQuint)

    public static func clamp01(_ v: CGFloat) -> CGFloat { v < 0 ? 0 : (v > 1 ? 1 : v) }

    public static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// `smooth` in the lab: clamped smoothstep.
    public static func smoothstep(_ t: CGFloat) -> CGFloat {
        let c = clamp01(t)
        return c * c * (3 - 2 * c)
    }

    /// The locked easing (`easing: "easeOutQuint"`).
    public static func easeOutQuint(_ p: CGFloat) -> CGFloat {
        let c = clamp01(p)
        return 1 - pow(1 - c, 5)
    }

    // MARK: - Geometry (lab: `geom(W, H)`)

    /// Waveform + card geometry at `endScale`, centred on a point.
    ///
    /// At the locked 1.2×: 16 bars 2.4pt wide with 3.6pt gaps (92.4pt field),
    /// a 150 × 45.6pt card with a 24pt corner radius and a 1.2pt border.
    public struct Geometry {
        public let scale: CGFloat
        public let count: Int
        public let barWidth: CGFloat
        public let barGap: CGFloat
        public let fieldWidth: CGFloat
        /// Distance from centre to the centre of the outermost bar.
        public let half: CGFloat
        public let maxBarHeight: CGFloat
        public let cardWidth: CGFloat
        public let cardHeight: CGFloat
        public let cornerRadius: CGFloat
        public let borderWidth: CGFloat
        public let centerX: CGFloat
        public let centerY: CGFloat

        /// Resting x-centre of bar `i`.
        public func homeX(_ i: Int) -> CGFloat {
            centerX - half + CGFloat(i) * (barWidth + barGap)
        }

        /// Normalised 0…1 distance of bar `i` from the centre of the field.
        public func dist(_ i: Int) -> CGFloat {
            let mid = CGFloat(count - 1) / 2
            guard mid > 0 else { return 0 }
            return abs(CGFloat(i) - mid) / mid
        }

        /// Distance of bar `i` from the mark, in points — what a ring pulse has to
        /// travel before it solidifies that bar.
        public func distPx(_ i: Int) -> CGFloat {
            abs((CGFloat(i) - CGFloat(count - 1) / 2) * (barWidth + barGap))
        }

        /// Resting height of a bar at live level `level` (floor = bar width, so
        /// silence renders as round dots — the shipped behaviour).
        public func targetHeight(level: CGFloat) -> CGFloat {
            max(barWidth, maxBarHeight * max(0, level))
        }

        /// How far a ring pulse travels before it has solidified every bar.
        public var reach: CGFloat { half + wakePx }
    }

    public static func geometry(centerX: CGFloat, centerY: CGFloat,
                                scale: CGFloat = endScale) -> Geometry {
        let n = barCount
        let barW = unscaledBarWidth * scale
        let gap = unscaledBarGap * scale
        let field = CGFloat(n) * barW + CGFloat(n - 1) * gap
        return Geometry(
            scale: scale,
            count: n,
            barWidth: barW,
            barGap: gap,
            fieldWidth: field,
            half: (field - barW) / 2,
            maxBarHeight: unscaledMaxBarHeight * scale,
            cardWidth: field + 2 * unscaledCardPadH * scale,
            cardHeight: 2 * unscaledCardPadV * scale + barW,
            cornerRadius: unscaledCornerRadius * scale,
            borderWidth: unscaledBorderWidth * scale,
            centerX: centerX,
            centerY: centerY
        )
    }

    // MARK: - The emergence pulses (lab: VARIANTS "pulses")

    public struct RingStroke {
        public let radius: CGFloat
        public let lineWidth: CGFloat
        public let alpha: CGFloat
    }

    /// Radii of the `pulseCount` rings the mark fires, in firing order.
    ///
    /// Pulse `k` launches at eased progress `k / K * 0.55` and then covers the
    /// whole reach over the remaining progress, so the last pulse still lands by
    /// p = 1. Each fades linearly to nothing as it hits the reach.
    public static func emergencePulses(progress: CGFloat, geometry g: Geometry) -> [RingStroke] {
        let e = easeOutQuint(progress)
        let reach = g.reach
        var out: [RingStroke] = []
        for k in 0..<pulseCount {
            let t0 = CGFloat(k) / CGFloat(pulseCount) * 0.55
            let travelled = clamp01((e - t0) / max(0.001, 1 - t0)) * reach
            guard travelled > 0 else { continue }
            out.append(RingStroke(radius: dotRadius + ringGap + travelled,
                                  lineWidth: ringWidth * 1.4,
                                  alpha: ringAlpha * (1 - travelled / reach) * 0.75))
        }
        return out
    }

    /// How solid each bar is (0 = not yet born, 1 = fully formed).
    ///
    /// Every pulse that has swept past a bar contributes `1/pulseCount`, ramped
    /// over the 12pt behind its front — so a bar hardens in three visible steps
    /// rather than appearing at once.
    public static func solidity(progress: CGFloat, geometry g: Geometry) -> [CGFloat] {
        let e = easeOutQuint(progress)
        let reach = g.reach
        var solid = [CGFloat](repeating: 0, count: g.count)
        for k in 0..<pulseCount {
            let t0 = CGFloat(k) / CGFloat(pulseCount) * 0.55
            let travelled = clamp01((e - t0) / max(0.001, 1 - t0)) * reach
            guard travelled > 0 else { continue }
            for i in 0..<g.count {
                solid[i] += clamp01((travelled - g.distPx(i)) / 12) / CGFloat(pulseCount)
            }
        }
        return solid.map { clamp01($0) }
    }

    // MARK: - The purple bloom (lab: CARDS "bloom")

    public struct CardShape {
        public let width: CGFloat
        public let height: CGFloat
        public let cornerRadius: CGFloat
        public let alpha: CGFloat
        public let borderAlpha: CGFloat
    }

    /// The purple disc blooming out of the mark and relaxing into the pill.
    ///
    /// It reaches full size at p = 0.6 (easeOutQuint over the first 60%), so the
    /// last 40% of the sequence is the bars finishing inside an already-settled
    /// card. Fill opacity is constant; only the border fades up, from p = 0.35.
    public static func card(progress: CGFloat, geometry g: Geometry) -> CardShape {
        let p = clamp01(progress)
        let e = easeOutQuint(p / 0.6)
        let r0 = dotRadius
        return CardShape(
            width: lerp(r0 * 2, g.cardWidth, e),
            height: lerp(r0 * 2, g.cardHeight, e),
            cornerRadius: lerp(r0, g.cornerRadius, e),
            alpha: cardOpacity,
            borderAlpha: smoothstep((p - 0.35) / 0.5) * borderOpacity
        )
    }

    /// How much of the mark's red bar `i` is still carrying (0 = fully lilac).
    /// Bars near the mark stay red longest; everything cools to nothing at p = 1.
    public static func barRedness(index: Int, progress: CGFloat, geometry g: Geometry) -> CGFloat {
        let e = easeOutQuint(progress)
        return clamp01((1 - e) * (1 - g.dist(index) * 0.4)) * heat
    }

    /// Ink colour of bar `i` at this progress.
    public static func barColor(index: Int, progress: CGFloat, geometry g: Geometry) -> RGB {
        mix(barLilac, red, barRedness(index: index, progress: progress, geometry: g))
    }

    // MARK: - The record mark (lab: `markR` / `dot`)

    /// The red dot shrinks to `endIconScale` as the bars take over. The `e * 4`
    /// clamp makes it commit to shrinking in the first quarter of the eased
    /// progress rather than drifting for the whole sequence.
    public static func markRadius(progress: CGFloat) -> CGFloat {
        let e = easeOutQuint(progress)
        let sc = lerp(1, endIconScale, e)
        return lerp(dotRadius, dotRadius * sc, clamp01(e * 4))
    }

    /// The mark fades to `endIconAlpha` (0) — by p = 1 the bars are the only red-free
    /// object left and nothing of the dot remains.
    public static func markAlpha(progress: CGFloat) -> CGFloat {
        lerp(1, endIconAlpha, easeOutQuint(progress))
    }

    // MARK: - The idle ring (lab: `drawRing`, ringIdle = "pulse")

    /// The idle ring is gone by p = `ringFadeFraction` (0.35) — it belongs to the
    /// armed state, not to the emergence.
    public static func idleRingFade(progress: CGFloat) -> CGFloat {
        1 - clamp01(clamp01(progress) / max(0.001, ringFadeFraction))
    }

    /// The armed ring treatment: two outward wavelets on a 1.5s cycle plus the
    /// steady hairline, all fading out as the emergence starts. `time` is seconds
    /// since the overlay appeared.
    ///
    /// Returned in paint order (wavelets under the hairline), matching the lab.
    public static func idleRings(progress: CGFloat, time: CGFloat) -> [RingStroke] {
        let fade = idleRingFade(progress: progress)
        guard fade > 0 else { return [] }
        let base = markRadius(progress: progress) + ringGap
        var out: [RingStroke] = []
        let period = 1.5 / max(0.2, idleRate)
        let t = time * idleRate
        for k in 0..<2 {
            var phase = (t / period + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            out.append(RingStroke(radius: base + phase * 14 * idleAmp,
                                  lineWidth: ringWidth * 0.8,
                                  alpha: ringAlpha * fade * (1 - phase) * 0.6))
        }
        out.append(RingStroke(radius: base, lineWidth: ringWidth, alpha: ringAlpha * fade))
        return out
    }

    /// Furthest any ink travels from the mark, so the overlay window can be sized
    /// to never clip a pulse into an arc.
    public static func maxInkRadius(geometry g: Geometry) -> CGFloat {
        max(dotRadius + ringGap + g.reach,
            max(g.cardWidth, g.cardHeight) / 2)
    }
}
