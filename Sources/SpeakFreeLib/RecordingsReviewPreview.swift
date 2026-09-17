// ai-suggestion:unverified · session:01a0a336-fe39-7870-bdab-33c820f98955 · 2026-09-15
import AppKit
import SwiftUI

/// A separate, inert review application. Config and folder actions use its own scratch
/// directory; it never starts AppDelegate, records audio, or changes the installed app.
public enum RecordingsNoticePreview {
    private static var windows: [NSWindow] = []

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-ui-review-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("recordings"),
                                                    withIntermediateDirectories: true)
        } catch { print("Cannot create inert preview: \(error)"); return }
        Config.configDirOverride = directory
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        let draftURL = ProcessInfo.processInfo.environment["SPEAKFREE_REVIEW_DRAFT"]
            .map { URL(fileURLWithPath: $0) }
            ?? directory.appendingPathComponent("wording-review.json")
        let draft = NoticeReviewDraft(url: draftURL)
        let view = NoticeReviewControls(draft: draft, directory: directory)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "UI TEST — recordings review (no files will be moved)"
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 700, height: 500)
        let measure = NSHostingView(rootView: RecordingsNoticeView(
            folderPath: directory.appendingPathComponent("recordings").path,
            recordingCount: 18_710, artifactCount: 76_144, noteText: draft.values.note,
            onCommit: { _, _ in }, onContinue: { _ in }))
        let desiredHeight = ceil(measure.fittingSize.height) + 46
        window.setContentSize(NSSize(width: 700, height: min(desiredHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.installMinimalMenu()
        app.activate(ignoringOtherApps: true)
        print("notice-preview: inert review open; wording draft: \(draftURL.path)")
        app.run()
    }
}

private final class NoticeReviewDraft: ObservableObject {
    struct Values: Codable {
        var provenance = "ai-suggestion:unverified | session:01a0a336-fe39-7870-bdab-33c820f98955 | 2026-09-15"
        var source = "Sources/SpeakFreeLib/RecordingsNotice.swift → NoticeCopy.note"
        var note = NoticeCopy.note
        var choiceIsBold = true
        var folderAlignment = "Center"
    }
    @Published var values: Values
    @Published var status = ""
    let url: URL

    init(url: URL) {
        self.url = url
        values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(values).write(to: url, options: .atomic)
            status = "Draft saved. Source wording is unchanged until your edits are applied."
        } catch { status = "Draft could not be saved: \(error.localizedDescription)" }
    }
}

private struct NoticeReviewControls: View {
    @ObservedObject var draft: NoticeReviewDraft
    let directory: URL
    @State private var editing = false
    @State private var feedback = ""

    private var folderAlignment: Alignment {
        switch draft.values.folderAlignment {
        case "Center": return .center
        case "Right": return .trailing
        default: return .leading
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Bold ‘Your choice’", isOn: $draft.values.choiceIsBold).toggleStyle(.checkbox)
                Picker("Folder", selection: $draft.values.folderAlignment) {
                    ForEach(["Left", "Center", "Right"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).frame(width: 240)
                Button("Edit wording…") { editing = true }
            }
            .padding(10)
            Divider()
            ScrollView {
                RecordingsNoticeView(
                    folderPath: directory.appendingPathComponent("recordings").path,
                    recordingCount: 18_710, artifactCount: 76_144,
                    choiceIsBold: draft.values.choiceIsBold,
                    folderAlignment: folderAlignment,
                    noteText: draft.values.note,
                    onCommit: { selection, _ in feedback = "Preview only: \(RecordingRetention.title(selection)). No preferences changed." },
                    onContinue: { _ in feedback = "Preview only — no recordings or settings changed." },
                    trashAction: { progress in
                        for step in 0...10 {
                            Thread.sleep(forTimeInterval: 0.15)
                            progress(.init(phase: .moving, completed: step, total: 10, elapsedSeconds: 0))
                        }
                        return .init(removedFiles: 76_140, removedRecordings: 18_709, failedFiles: 0,
                                     retainedRecordings: 1, enumerationFailed: false,
                                     recoveryDirectory: nil, trashDirectory: nil, elapsedSeconds: 0)
                    })
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            if !feedback.isEmpty {
                Text(feedback).font(.callout).foregroundStyle(.secondary).padding(8)
            }
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit Michael’s note").font(.headline)
                Text("Saved edits map to NoticeCopy.note; saving this draft does not change the running app.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $draft.values.note).font(.body).frame(minHeight: 400)
                    .border(Color.secondary.opacity(0.3))
                if !draft.status.isEmpty { Text(draft.status).font(.callout) }
                HStack {
                    Button("Save Draft") { draft.save() }
                    Spacer()
                    Button("Show Preview") { draft.save(); editing = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 660)
        }
    }
}
