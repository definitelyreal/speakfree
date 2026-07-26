// Claude · 2026-07-26 · Session: ec24b5ef-be6a-4c4b-be38-a3b84ca63074
//
// Artifact generator, not an assertion suite (same pattern as HUDVariantRenderTests):
// renders the Help window's topics to PNGs for visual review. Skips unless
// HELP_RENDER_DIR is set.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class HelpWindowRenderTests: XCTestCase {

    func test_renderHelpTopicsForReview() throws {
        guard let outDir = ProcessInfo.processInfo.environment["HELP_RENDER_DIR"] else {
            throw XCTSkip("HELP_RENDER_DIR not set — render harness only runs on demand")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let controller = HelpController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 780, height: 660))
        window.contentView?.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTableView }.first)

        for (index, topic) in HelpContent.topics(HelpFacts.live()).enumerated() {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.delegate?.tableViewSelectionDidChange?(
                Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.display()

            guard let contentView = window.contentView,
                  let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
            else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = String(format: "%02d-%@.png", index, topic.id)
            try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
        }
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
