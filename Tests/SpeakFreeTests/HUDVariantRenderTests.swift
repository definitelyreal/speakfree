// Design-review harness (2026-07-25): renders the 5 prominent-banner variants to
// PNGs for adversarial visual review. Skips unless HUD_RENDER_DIR is set — this is
// an artifact generator, not an assertion suite. Three phases per style:
//   icon      — pre-speech record icon (explodeProgress 0)
//   exploding — mid-transition (explodeProgress 0.5)
//   waveform  — settled live bars (explodeProgress 1)

import XCTest
import AppKit
@testable import SpeakFreeLib

final class HUDVariantRenderTests: XCTestCase {

    func test_renderVariantsForDesignReview() throws {
        guard let outDir = ProcessInfo.processInfo.environment["HUD_RENDER_DIR"] else {
            throw XCTSkip("HUD_RENDER_DIR not set — render harness only runs on demand")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let bannerSize = OverlayContentView.prominentSize
        let settledSize = RecordingOverlay.settledSize
        // Deterministic mid-speech level pattern for the waveform phases.
        let levels: [CGFloat] = [0.3, 0.55, 0.8, 0.45, 0.9, 0.65, 0.35, 0.7,
                                 0.85, 0.5, 0.6, 0.95, 0.4, 0.75, 0.55, 0.3]

        // Style 6 is the retired Comet Dock (superseded 2026-08-12 by the locked
        // record-icon entry, which now owns style 5); it is unreachable from config
        // but still rendered here so the two can be compared side by side.
        for style in 1...6 {
            for (phase, heard, progress, settled) in [("icon", false, CGFloat(0), false),
                                             ("exploding", true, CGFloat(0.5), false),
                                             ("waveform", true, CGFloat(1.0), false),
                                             ("settled", true, CGFloat(1.0), true)] {
                let size = settled ? settledSize : bannerSize
                let view = OverlayContentView(frame: NSRect(origin: .zero, size: size))
                view.overlayState = .recording
                view.prominent = true
                view.style = style
                view.heardSpeech = heard
                view.explodeProgress = progress
                view.settleProgress = settled ? 1 : 0
                view.renderElapsedOverride = 83  // 1:23 on the settled timer
                view.tick = 13  // fixed pulse phase
                view.borderWidth = 1
                if heard { view.seedLevelsForRender(levels) }

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    XCTFail("no bitmap rep for style \(style)"); continue
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("no png for style \(style)"); continue
                }
                let path = "\(outDir)/style\(style)-\(phase).png"
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
        // The locked record-icon entry (2026-08-12) is a continuous 520ms sequence,
        // so a 4-phase sample is too coarse to review. Walk it in 10% steps on its
        // own (larger) canvas, plus a silent frame so the armed state can be judged.
        let emergenceDir = "\(outDir)/emergence"
        try FileManager.default.createDirectory(atPath: emergenceDir, withIntermediateDirectories: true)
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let view = OverlayContentView(
                frame: NSRect(origin: .zero, size: OverlayContentView.emergenceSize))
            view.overlayState = .recording
            view.prominent = true
            view.style = 5
            view.heardSpeech = progress > 0
            view.explodeProgress = progress
            view.tick = 13
            view.borderWidth = 1
            view.renderElapsedOverride = 0.62  // pins the idle ring's phase
            view.seedLevelsForRender(levels)

            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                XCTFail("no bitmap rep for emergence p=\(progress)"); continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("no png for emergence p=\(progress)"); continue
            }
            try png.write(to: URL(fileURLWithPath:
                String(format: "%@/p%02d.png", emergenceDir, step * 10)))
        }
        // Armed: no speech yet, silent bars — the bare dot + ring Michael specified.
        let armed = OverlayContentView(
            frame: NSRect(origin: .zero, size: OverlayContentView.emergenceSize))
        armed.overlayState = .recording
        armed.prominent = true
        armed.style = 5
        armed.borderWidth = 1
        armed.renderElapsedOverride = 0.62
        if let rep = armed.bitmapImageRepForCachingDisplay(in: armed.bounds) {
            armed.cacheDisplay(in: armed.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "\(emergenceDir)/armed.png"))
            }
        }

        print("HUD variants rendered to \(outDir)")
    }
}
