// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

final class PasteboardAccessTests: XCTestCase {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("speakfree.snapshot.\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testDeniedReadCannotBecomeAnEmptyRestorableSnapshot() {
        let pb = board()
        pb.setString("untouched", forType: .string)
        let count = pb.changeCount
        XCTAssertThrowsError(try PasteboardAccess.snapshot(pb, maximumBytes: 100, denied: true)) {
            XCTAssertEqual($0 as? PasteboardAccess.Failure, .denied)
        }
        XCTAssertEqual(pb.changeCount, count)
        XCTAssertEqual(pb.string(forType: .string), "untouched")
    }

    func testMultiItemRichSnapshotPreservesBytesAndOrder() throws {
        let pb = board()
        let first = NSPasteboardItem()
        first.setString("  styled\n", forType: .string)
        first.setData(Data("{\\rtf1 styled}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([1, 0, 2, 255]), forType: .png)
        pb.writeObjects([first, second])
        let snapshot = try PasteboardAccess.snapshot(pb, maximumBytes: 1000)
        XCTAssertEqual(snapshot.count, 2)
        // AppKit may append an automatically converted UTF-16 representation.
        XCTAssertEqual(Array(snapshot[0].prefix(2)).map { $0.0 }, [.string, .rtf])
        XCTAssertEqual(snapshot[0].map { $0.0 }, pb.pasteboardItems?.first?.types)
        XCTAssertEqual(snapshot[0][0].1, Data("  styled\n".utf8))
        XCTAssertEqual(snapshot[1][0].1, Data([1, 0, 2, 255]))
    }

    func testOversizeSnapshotFailsWithoutChangingClipboard() {
        let pb = board()
        pb.setString("1234567890", forType: .string)
        let count = pb.changeCount
        XCTAssertThrowsError(try PasteboardAccess.snapshot(pb, maximumBytes: 5)) {
            XCTAssertEqual($0 as? PasteboardAccess.Failure, .tooLarge)
        }
        XCTAssertEqual(pb.changeCount, count)
    }

    func testUnfulfilledRepresentationIsNotSilentlyDiscarded() {
        final class Missing: NSObject, NSPasteboardItemDataProvider {
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {}
        }
        let pb = board()
        let provider = Missing()
        let item = NSPasteboardItem()
        item.setString("has text", forType: .string)
        item.setDataProvider(provider, forTypes: [.rtf])
        pb.writeObjects([item])
        XCTAssertThrowsError(try PasteboardAccess.snapshot(pb, maximumBytes: 1000)) {
            XCTAssertEqual($0 as? PasteboardAccess.Failure, .unreadable)
        }
        withExtendedLifetime(provider) {}
    }
    func testChangedGenerationStopsBeforeReadingRemainingRepresentations() {
        let pb = board()
        let item = NSPasteboardItem()
        item.setData(Data("first".utf8), forType: .rtf)
        item.setData(Data("later".utf8), forType: .html)
        XCTAssertTrue(pb.writeObjects([item]))
        var reads: [NSPasteboard.PasteboardType] = []
        XCTAssertThrowsError(try PasteboardAccess.snapshot(pb, maximumBytes: 1000, read: { item, type in
            reads.append(type)
            let data = item.data(forType: type)
            if reads.count == 1 {
                pb.clearContents()
                XCTAssertTrue(pb.setString("fresh copy", forType: .string))
            }
            return data
        })) {
            XCTAssertEqual($0 as? PasteboardAccess.Failure, .changed)
        }
        XCTAssertEqual(reads, [.rtf], "A stale snapshot must not materialize later formats")
        XCTAssertEqual(pb.string(forType: .string), "fresh copy")
    }

}
