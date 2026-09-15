// ai-suggestion:unverified · session:unknown · 2026-09-15
import AppKit
import SwiftUI
import XCTest
@testable import SpeakFreeLib

/// Opt-in native image generation, not visual approval or macOS Larger Text validation.
/// Set SF_UI_RENDER_DIR to a retained output directory. BODY20 applies a real 20-point
/// inherited body font; explicitly styled headings/captions keep their production fonts.
/// Fixtures never become visible or accept clicks, and all config access is isolated.
@MainActor
final class RecordingsUIRenderTests: XCTestCase {
    private enum TextProfile: String, CaseIterable {
        case normal = "NORMAL"
        case body20 = "BODY20"

        var font: Font { self == .body20 ? .system(size: 20) : .body }
    }

    private enum SnapshotFailure: Error { case invalidSize, bitmapUnavailable, pngUnavailable }

    private let recordingCount = 18_710
    private let artifactCount = 76_144
    private let sampleFolderPath = "/Users/preview/Library/Application Support/SpeakFree UI Test/recordings"

    func testRenderNoticeComparisons() throws {
        try withIsolatedOutput { output, _ in
            let placements: [(String, Alignment)] = [
                ("LEFT", .leading), ("CENTER", .center), ("RIGHT", .trailing)
            ]
            for profile in TextProfile.allCases {
                for bold in [false, true] {
                    for (placement, alignment) in placements {
                        let view = RecordingsNoticeView(
                            initialRetention: 0,
                            folderPath: sampleFolderPath,
                            recordingCount: recordingCount,
                            artifactCount: artifactCount,
                            choiceIsBold: bold,
                            folderAlignment: alignment,
                            openFolder: { _ in },
                            onCommit: { _, _ in },
                            onContinue: { _ in },
                            trashAction: { _ in Self.inertRemovalResult() })
                        try snapshot(view, named: "notice-\(bold ? "BOLD" : "PLAIN")-\(placement)",
                                     profile: profile, width: 660, output: output)
                    }
                }
            }
        }
    }

    func testRenderSettingsEnginesAndViewports() throws {
        try withIsolatedOutput { output, _ in
            for profile in TextProfile.allCases {
                for engine in ["parakeet", "whisper"] {
                    for (extent, height) in [("full", CGFloat(2200)), ("viewport", CGFloat(800))] {
                        var config = Config.defaultConfig
                        config.engine = engine
                        config.parakeetModel = "parakeet-tdt-0.6b-v2"
                        config.modelSize = "small.en"
                        config.language = "en"
                        config.hotkey = HotkeyConfig(keyCode: KeyCodes.rightOptionKeyCode, modifiers: [])
                        config.saveRecordings = FlexBool(true)
                        config.maxRecordings = 0
                        config.screenContext = FlexBool(false)
                        config.localAPI = FlexBool(false)
                        let viewModel = SettingsViewModel(config: config)
                        let view = SettingsView(viewModel: viewModel, isReview: true)
                        try snapshot(view, named: "settings-\(engine)-\(extent)", profile: profile,
                                     width: 900, height: height, output: output)
                    }
                }
            }
        }
    }

    func testRenderTrashConfirmationAlignments() throws {
        try withIsolatedOutput { output, _ in
            for profile in TextProfile.allCases {
                for (placement, alignment) in [("LEFT", Alignment.leading), ("CENTER", Alignment.center)] {
                    let view = trashView(folderAlignment: alignment)
                    try snapshot(view, named: "trash-confirm-\(placement)", profile: profile,
                                 width: 500, output: output)
                }
            }
        }
    }

    func testRenderTrashProgressPhases() throws {
        try withIsolatedOutput { output, _ in
            let phases: [RecordingRemoval.Progress] = [
                .init(phase: .preparing, completed: 0, total: 0, elapsedSeconds: 0),
                .init(phase: .moving, completed: 38_072, total: artifactCount, elapsedSeconds: 2),
                .init(phase: .finishing, completed: artifactCount, total: artifactCount, elapsedSeconds: 4)
            ]
            for profile in TextProfile.allCases {
                for progress in phases {
                    let phase = progress.phase.rawValue
                    try snapshot(RecordingsTrashProgress(progress: progress).padding(20).frame(width: 500),
                                 named: "trash-progress-\(phase)", profile: profile, width: 500, output: output)
                    try snapshot(trashView(reviewState: .moving(progress)),
                                 named: "trash-sheet-\(phase)", profile: profile, width: 500, output: output)
                }
            }
        }
    }

    func testRenderTrashAndRestoreResults() throws {
        try withIsolatedOutput { output, scratch in
            let recovery = scratch.appendingPathComponent("Sample recovery folder", isDirectory: true)
            let success = RecordingRemoval.Result(
                removedFiles: artifactCount - 4, removedRecordings: recordingCount - 1,
                failedFiles: 0, retainedRecordings: 1, enumerationFailed: false,
                recoveryDirectory: nil,
                trashDirectory: scratch.appendingPathComponent("Sample Trash batch", isDirectory: true),
                elapsedSeconds: 4)
            let restored = RecordingRemoval.RestoreResult(
                restoredFiles: artifactCount - 4, restoredRecordings: recordingCount - 1,
                retainedFiles: 0, recoveryDirectory: nil)
            let restoreFailed = RecordingRemoval.RestoreResult(
                restoredFiles: artifactCount - 8, restoredRecordings: recordingCount - 2,
                retainedFiles: 4, recoveryDirectory: recovery)
            let trashFailed = RecordingRemoval.Result(
                removedFiles: artifactCount - 8, removedRecordings: recordingCount - 2,
                failedFiles: 4, retainedRecordings: 1, enumerationFailed: false,
                recoveryDirectory: recovery, trashDirectory: nil, elapsedSeconds: 4)
            let progress = RecordingRemoval.Progress(
                phase: .moving, completed: 38_072, total: artifactCount - 4, elapsedSeconds: 2)
            let states: [(String, RecordingsTrashConfirmView.ReviewState)] = [
                ("success-retained", .completed(success, nil, nil, false)),
                ("restoring", .completed(success, nil, progress, true)),
                ("restored", .completed(success, restored, nil, false)),
                ("restore-failed", .completed(success, restoreFailed, nil, false)),
                ("trash-failed", .failed(trashFailed))
            ]
            for profile in TextProfile.allCases {
                for (name, state) in states {
                    try snapshot(trashView(reviewState: state), named: "trash-result-\(name)",
                                 profile: profile, width: 500, output: output)
                }
            }
        }
    }

    private func trashView(folderAlignment: Alignment = .leading,
                           reviewState: RecordingsTrashConfirmView.ReviewState? = nil) -> RecordingsTrashConfirmView {
        RecordingsTrashConfirmView(
            fileCount: recordingCount, artifactCount: artifactCount, folderPath: sampleFolderPath,
            folderAlignment: folderAlignment, reviewState: reviewState,
            trashAction: { _ in Self.inertRemovalResult() },
            onDeleted: {}, onRestored: {}, onDismiss: {})
    }

    nonisolated private static func inertRemovalResult() -> RecordingRemoval.Result {
        .init(removedFiles: 0, failedFiles: 0, enumerationFailed: false,
              recoveryDirectory: nil, trashDirectory: nil, elapsedSeconds: 0)
    }

    private func withIsolatedOutput(_ body: (URL, URL) throws -> Void) throws {
        guard let path = ProcessInfo.processInfo.environment["SF_UI_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("SF_UI_RENDER_DIR is not set; native snapshot generation is opt-in")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let scratch = output.appendingPathComponent(".fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("recordings"),
                                                withIntermediateDirectories: true)
        let originalOverride = Config.configDirOverride
        let originalDeveloperMode = getenv("SPEAKFREE_DEV_MODE").map { String(cString: $0) }
        Config.configDirOverride = scratch
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        defer {
            Config.configDirOverride = originalOverride
            if let originalDeveloperMode { setenv("SPEAKFREE_DEV_MODE", originalDeveloperMode, 1) }
            else { unsetenv("SPEAKFREE_DEV_MODE") }
            try? FileManager.default.removeItem(at: scratch)
        }
        _ = NSApplication.shared
        try body(output, scratch)
    }

    private func snapshot<Content: View>(
        _ view: Content, named name: String, profile: TextProfile,
        width: CGFloat, height: CGFloat? = nil, output: URL
    ) throws {
        let root = view.font(profile.font)
            .environment(\.colorScheme, .light)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(window: window, host: host)

        let contentHeight = height ?? ceil(host.fittingSize.height)
        guard contentHeight.isFinite, contentHeight > 0 else {
            XCTFail("\(name)-\(profile.rawValue): invalid content height \(contentHeight)")
            throw SnapshotFailure.invalidSize
        }
        window.setContentSize(NSSize(width: width, height: contentHeight))
        host.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        settle(window: window, host: host)
        host.display()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("\(name)-\(profile.rawValue): AppKit could not allocate a snapshot bitmap")
            throw SnapshotFailure.bitmapUnavailable
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            XCTFail("\(name)-\(profile.rawValue): AppKit could not encode the snapshot PNG")
            throw SnapshotFailure.pngUnavailable
        }
        let destination = output.appendingPathComponent("\(name)-\(profile.rawValue).png")
        try data.write(to: destination, options: .atomic)
        print("SF_UI_RENDER \(destination.path) | content \(Int(width))x\(Int(contentHeight))pt"
              + " | bitmap \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)px")
    }

    private func settle<Content: View>(window: NSWindow, host: NSHostingView<Content>) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }
}
