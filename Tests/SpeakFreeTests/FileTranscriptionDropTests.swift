// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

/// Named pasteboards and synthetic scratch files only. No app window, real clipboard,
/// microphone, decoder, or user preferences are touched.
final class FileTranscriptionDropTests: XCTestCase {
    private var folder: URL!
    private var board: NSPasteboard!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("speakfree-file-drop-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("speakfree-file-drop-\(UUID())"))
    }

    override func tearDownWithError() throws {
        board.releaseGlobally()
        try FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private func put(_ urls: [URL]) {
        board.clearContents()
        XCTAssertTrue(board.writeObjects(urls.map { $0 as NSURL }))
    }

    func testExistingAudioAndMovieTypesSelectWithoutOpeningTheirContents() throws {
        for ext in ["wav", "m4a", "mp3", "flac", "aiff", "aif", "caf", "aac", "mp4", "mov", "WAV"] {
            let url = try file("synthetic.\(ext)")
            put([url])
            XCTAssertEqual(FileTranscriptionDropPolicy.singleMediaFile(on: board), url, ext)
        }
    }

    func testRejectsRemoteMissingUnsupportedFilesAndDirectories() throws {
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile([URL(string: "https://example.invalid/synthetic.wav")!]))
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile([URL(string: "file://example.invalid/synthetic.wav")!]))
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile([folder.appendingPathComponent("missing.wav")]))
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile([try file("synthetic.txt")]))
        let directory = folder.appendingPathComponent("directory.wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile([directory]))
    }

    func testRejectsWholeMultipleFileDragInsteadOfSelectingItsFirstFile() throws {
        let first = try file("one.wav"), second = try file("two.mp4")
        put([first, second])
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile(on: board))
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile([first, second]))
        put([first, try file("notes.txt")])
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile(on: board))
    }

    func testRejectsExtraNonFileItemsAndPlainStrings() throws {
        let url = try file("synthetic.wav")
        let fileItem = NSPasteboardItem()
        fileItem.setString(url.absoluteString, forType: .fileURL)
        let textItem = NSPasteboardItem()
        textItem.setString("synthetic", forType: .string)
        board.clearContents(); XCTAssertTrue(board.writeObjects([fileItem, textItem]))
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile(on: board))
        board.clearContents(); XCTAssertTrue(board.setString(url.absoluteString, forType: .string))
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile(on: board))
        board.clearContents()
        XCTAssertNil(FileTranscriptionDropPolicy.singleMediaFile(on: board))
    }

    func testRegisteredDestinationOffersCopyAndOnlyCallsSelectionAtDrop() throws {
        let url = try file("synthetic.wav"); put([url])
        let view = FileTranscriptionDropView(frame: .zero)
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
        var selected: [URL] = []
        view.canAcceptFile = { true }
        view.selectFile = { selected.append($0); return true }
        XCTAssertEqual(view.operation(for: board, sourceMask: [.copy, .move]), .copy)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertTrue(view.receive(board, sourceMask: .copy))
        XCTAssertEqual(selected, [url])
    }

    func testJobStartingAfterDragEnterRejectsTheDropAndPreservesSource() throws {
        let url = try file("synthetic.wav"); put([url])
        let view = FileTranscriptionDropView(frame: .zero)
        var busy = false, selected = false
        view.canAcceptFile = { !busy }
        view.selectFile = { _ in selected = true; return true }
        XCTAssertEqual(view.operation(for: board, sourceMask: .copy), .copy)
        busy = true
        XCTAssertEqual(view.operation(for: board, sourceMask: .copy), [])
        XCTAssertFalse(view.receive(board, sourceMask: .copy))
        XCTAssertFalse(selected)
    }

    func testPayloadAndSourceOperationAreRevalidatedAtDrop() throws {
        let url = try file("synthetic.wav"); put([url])
        let view = FileTranscriptionDropView(frame: .zero)
        view.canAcceptFile = { true }
        var calls = 0
        view.selectFile = { _ in calls += 1; return true }
        XCTAssertEqual(view.operation(for: board, sourceMask: .copy), .copy)
        XCTAssertFalse(view.receive(board, sourceMask: .move))
        put([url, try file("another.wav")])
        XCTAssertFalse(view.receive(board, sourceMask: .copy))
        put([url]); try FileManager.default.removeItem(at: url)
        XCTAssertFalse(view.receive(board, sourceMask: .copy))
        XCTAssertEqual(calls, 0)
    }

    func testSelectionRejectionAndDefaultAdmissionAreReturnedToDragSource() throws {
        put([try file("synthetic.wav")])
        let view = FileTranscriptionDropView(frame: .zero)
        XCTAssertFalse(view.receive(board, sourceMask: .copy))
        view.canAcceptFile = { true }
        view.selectFile = { _ in false }
        XCTAssertFalse(view.receive(board, sourceMask: .copy))
    }
}
