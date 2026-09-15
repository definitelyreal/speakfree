// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-14
import AppKit
import SwiftUI

/// New-user saving consent is independent of model availability. Established explicit
/// preferences and the legacy recordings notice keep their existing behavior.
enum RecordingsSetup {
    static func shouldPresent(config: Config, hasRecordings: Bool, developerMode: Bool) -> Bool {
        guard !developerMode, config.recordingsSetupCompleted != true else { return false }
        guard config.saveRecordings == nil else { return false }
        if config.recordingsNoticeDecision == "keep" || config.recordingsNoticeDecision == "delete" { return false }
        // Existing users who were never told about the old default receive Michael's
        // full notice, which contains both the saving toggle and the Trash choice.
        if hasRecordings && config.recordingsNoticeDecision == nil { return false }
        return true
    }

    /// Read fresh config so a model/download or Settings update cannot be overwritten
    /// by a snapshot taken before the user finished reviewing their recordings.
    static func persist(save: Bool, existingDecision: String) throws {
        var config = Config.load()
        config.saveRecordings = FlexBool(save)
        config.recordingsSetupCompleted = true
        config.recordingsNoticeDecision = existingDecision
        try config.save()
    }
}

enum RecordingsSetupCopy {
    static let title = "Would you like to save your dictations?"
    static let body = "Keep the audio and transcript of each dictation on this Mac. "
        + "You can review past dictations and use them to help improve SpeakFree for the way you speak."
    static let optional = "Saving is optional. Speech recognition runs locally either way. "
        + "You can change this in Settings."
    static let save = "Save recordings and transcripts"
    static let decline = "Don’t save recordings"
    static let existingTitle = "You already have recordings on this Mac."
    static let existingBody = "Turning off saving affects new dictations. Your existing recordings "
        + "stay here unless you choose to move them to Trash."
    static let existingDetail = "You can keep them for review, or move them to Trash and restore "
        + "them later if you change your mind."
    static let keep = "Keep existing recordings"
}

/// Owns the nested run loop. Call from CFRunLoopPerformBlock, not main.sync: the
/// shared Trash sheet reports progress through the main queue while this is open.
final class RecordingsSetupController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var proceeded = false

    static func show(hasRecordings: Bool, fileCount: Int, folderPath: String) -> Bool {
        precondition(Thread.isMainThread)
        let controller = RecordingsSetupController()
        let view = RecordingsSetupView(hasRecordings: hasRecordings, fileCount: fileCount,
                                       folderPath: folderPath, onComplete: { controller.finish() })
        controller.window = NSWindow(contentViewController: NSHostingController(rootView: view))
        controller.window.title = "SpeakFree setup"
        controller.window.styleMask = [.titled, .closable]
        controller.window.isReleasedWhenClosed = false
        controller.window.delegate = controller
        NSApp.showDockIconIfNeeded()
        NSApp.installMinimalMenu()
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: controller.window)
        // Break window → hosting view → completion → controller after the modal.
        controller.window.contentView = nil
        NSApp.hideDockIconIfNoWindows()
        return controller.proceeded
    }

    private func finish() {
        proceeded = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

struct RecordingsSetupView: View {
    let hasRecordings: Bool
    let fileCount: Int
    let folderPath: String
    var persist: (Bool, String) throws -> Void = { try RecordingsSetup.persist(save: $0, existingDecision: $1) }
    var trashAction: @Sendable (@escaping @Sendable (RecordingRemoval.Progress) -> Void) -> RecordingRemoval.Result = {
        RecordingStore.trashAllRecordings(progress: $0)
    }
    var onComplete: () -> Void

    @State private var saveChoice: Bool?
    @State private var showTrash = false
    @State private var movedRecordings = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if saveChoice != nil && hasRecordings {
                Text(RecordingsSetupCopy.existingTitle).font(.title2.weight(.semibold))
                Text(RecordingsSetupCopy.existingBody)
                Text(RecordingsSetupCopy.existingDetail).foregroundStyle(.secondary)
                RecordingsFolderLink(folderPath: folderPath)
                HStack {
                    Button("Back") { saveChoice = nil; saveError = nil }
                        .help("Return to the choice about saving future dictations")
                    Spacer()
                    Button(NoticeCopy.deleteLinkText) { showTrash = true }
                        .help("Review the confirmation before moving existing recordings to Trash")
                    Button(RecordingsSetupCopy.keep) { finish(decision: movedRecordings ? "delete" : "keep") }
                        .help("Leave existing recordings here and finish setup")
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(RecordingsSetupCopy.title).font(.title2.weight(.semibold))
                Text(RecordingsSetupCopy.body)
                Text(RecordingsSetupCopy.optional).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button(RecordingsSetupCopy.save) { choose(true) }
                        .help("Keep audio and transcripts from future dictations on this Mac")
                        .accessibilityIdentifier("setup-save-recordings")
                    Button(RecordingsSetupCopy.decline) { choose(false) }
                        .help("Discard future dictation audio after transcription; existing recordings stay here")
                        .accessibilityIdentifier("setup-dont-save-recordings")
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.callout)
                    .accessibilityIdentifier("setup-save-error")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 540)
        .sheet(isPresented: $showTrash, onDismiss: {
            if movedRecordings { finish(decision: "delete") }
        }) {
            RecordingsTrashConfirmView(fileCount: fileCount, folderPath: folderPath,
                                      trashAction: trashAction, onDeleted: { movedRecordings = true })
        }
    }

    private func choose(_ save: Bool) {
        saveChoice = save
        saveError = nil
        if !hasRecordings { finish(decision: "none-found") }
    }

    private func finish(decision: String) {
        guard let saveChoice else { return }
        do {
            try persist(saveChoice, decision)
            onComplete()
        } catch {
            saveError = "Could not save your recording preference. Check access to the SpeakFree settings folder and try again. "
                + error.localizedDescription
        }
    }
}
