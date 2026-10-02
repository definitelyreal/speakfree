// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Artifact generator, not an assertion suite (same pattern as SettingsAppCompatRenderTests):
// renders the Report a Problem window in the state after "This works" on a less preferred
// method. Skips unless SETTINGS_RENDER_DIR is set. No config, clipboard or keystrokes.

import XCTest
import AppKit
import SwiftUI
@testable import SpeakFreeLib

final class AppProblemRenderTests: XCTestCase {

    func test_renderProblemWindow() throws {
        guard let outDir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("SETTINGS_RENDER_DIR not set, render harness only runs on demand")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let target = ProblemTarget(bundleID: "com.example.notes", appName: "Example Notes", appVersion: "3.2",
                                   classification: AppClassification(appClass: .native,
                                                                     reason: "no special handling detected"))
        let model = AppProblemModel(session: ProblemSession(target: target, setting: .automatic),
                                    speakfreeVersion: "1.9.0", macOSVersion: "Version 26.0",
                                    applySetting: { _ in }, recordConfirmation: { _ in })
        model.choose(.paste)
        model.observe(CompatibilityEvent(date: Date(), bundleID: "com.example.notes", appName: nil, appVersion: nil,
                                         appClass: .native, reason: "r", override: .paste,
                                         outcome: .pasted, multiLine: false))
        model.thisWorks()
        let host = NSHostingView(rootView: AppProblemView(model: model, onRetry: {},
                                                          onOpenIssue: {}, onCopy: {}))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("report-a-problem.png"))
    }
}
