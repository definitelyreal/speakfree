// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-14
import AppKit
import SwiftUI

/// The recordings notice (Michael, 2026-07-14; copy revised same day; reframed
/// 2026-08-21).
///
/// Through v1.7.1 every dictation's audio and transcript were saved to disk by
/// default — a dev-machine debugging setting that accidentally shipped to everyone.
/// Saving is now opt-in, and rather than silently deleting what accumulated, this
/// notice tells the user and leaves the decision to them: keep the files (default),
/// open the folder and delete manually, or use the in-app delete confirmation.
/// It returns every launch and every few hours until acknowledged; once resolved
/// it never shows again.
///
/// Copy and layout revised by Michael, September 14: explain the earlier default,
/// keep the saving choice separate from existing files, and use recoverable Trash.
public enum RecordingsNotice {

    public enum LaunchAction: Equatable {
        /// No recordings exist — nothing to disclose. Persist "none-found" so a user
        /// who later opts in and accumulates recordings never sees the notice.
        case markNotApplicable
        /// Undecided and recordings exist — show the notice.
        case show
        /// Already resolved.
        case nothing
    }

    /// Pure launch policy — unit-tested directly.
    public static func launchAction(decision: String?, hasRecordings: Bool) -> LaunchAction {
        guard decision == nil else { return .nothing }
        return hasRecordings ? .show : .markNotApplicable
    }

    /// Re-show interval while the user has not decided (4 hours). The app commonly
    /// runs for days between launches, so launch-time-only would never re-ask.
    public static let reshowInterval: TimeInterval = 4 * 60 * 60

    /// Persist the notice resolution ("keep" | "delete"). Deletion itself happens in
    /// the confirmation sheet BEFORE this is called — persisting is decision-only.
    static func persistDecision(_ decision: String) {
        var config = Config.load()
        config.recordingsNoticeDecision = decision
        try? config.save()
        DiagnosticLogger.shared.log("RecordingsNotice: resolved (\(decision))")
    }

    /// Persist the dialog's toggle immediately (same semantics as the Settings toggle) —
    /// a user who flips it and closes the window without acknowledging keeps their choice.
    static func persistSaveToggle(_ save: Bool) {
        var config = Config.load()
        config.saveRecordings = FlexBool(save)
        try? config.save()
    }
}

// MARK: - Copy (Michael's saved wording review, September 14)

enum NoticeCopy {
    static let header = """
    Oops! Earlier versions of Speakfree saved your recordings locally.
    Now you have a decision: keep your corpus, or delete it.
    """
    static let noteLabel = "A note from Michael:"
    static let note = """
    As part of developing Speakfree, I have it keep all my recordings local.

    It’s a POWERFUL tool in developing the product. Having real data lets me test a change to the \
    code against 18,000 recordings — over three DAYS of speech!

    I left the recording setting on for everyone, which means that everything you’ve dictated is in \
    the folder shown below. That was my mistake, and I apologize. Privacy and consent are core \
    values of this app. The app NEVER uploads anything of yours or phones home, aside from checks \
    for updates.

    You can delete them, but before you do, consider that this is a POWERFUL \
    source of personal data: about your own voice, your speech patterns, anything you choose to \
    analyze. They are local to your device, and there are even private LLMs that can analyze them \
    without ever uploading them to a company’s dataset. And having your recordings allows you to \
    participate more in developing the app. You can test changes in the code against your corpus \
    (without uploading them) and help improve the app for everyone.
    """
    static let turnedOff = "Your choice"
    static let toggleLabel = "Save recordings and transcripts"
    static let deleteLeadIn = "Rather not? "
    static let deleteLinkText = "🗑️ Move Recordings to Trash"
    static let deleteLeadOut = "or do it yourself from the folder:"
    static let continueKeepLabel = "💾 Keep My Recordings »"
    static let continueTrashLabel = "🗑️ Move Recordings to Trash »"
    static let continueLabel = "Continue »"

    static func confirmTitle(recordingCount: Int, artifactCount: Int) -> String {
        "Move \(recordingCount.formatted()) recordings and transcripts "
            + "(\(artifactCount.formatted()) files) to Trash?"
    }
    static let restoreNotice = "You can restore them until you empty the Trash."
    static let activeNotice = "Recordings in use will stay in the recordings folder."
}

// MARK: - Window controller

final class RecordingsNoticeController: NSWindowController, NSWindowDelegate {

    /// Called when the user resolves the notice (acknowledge or delete) — never again.
    private var onResolved: (() -> Void)?
    /// Called when the window closes WITHOUT a resolution (caller schedules a re-show).
    private var onDismissed: (() -> Void)?
    /// Called when the dialog's toggle changes config (caller reloads its config cache).
    private var onConfigChanged: (() -> Void)?
    private var resolved = false

    static func present(onResolved: @escaping () -> Void,
                        onConfigChanged: @escaping () -> Void,
                        onDismissed: @escaping () -> Void) -> RecordingsNoticeController {
        let controller = RecordingsNoticeController(window: nil)
        controller.onResolved = onResolved
        controller.onDismissed = onDismissed
        controller.onConfigChanged = onConfigChanged
        controller.loadNoticeWindow()
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    private func resolve(_ decision: String) {
        RecordingsNotice.persistDecision(decision)
        resolved = true
        // Close BEFORE notifying: onResolved drops the owner's strong reference, and a
        // deallocated controller can't close its window (weak self → stranded window).
        close()
        onResolved?()
    }

    private func loadNoticeWindow() {
        let view = RecordingsNoticeView(
            refreshCounts: { (RecordingStore.recordingCount(), RecordingStore.recordingFileCount()) },
            onSaveSelection: { [weak self] choice in
                var config = Config.load()
                RecordingRetention.apply(choice, to: &config)
                try config.save()
                self?.onConfigChanged?()
            },
            onCommit: { [weak self] choice, didDelete in
                var config = Config.load()
                RecordingRetention.apply(choice, to: &config)
                config.recordingsNoticeDecision = didDelete ? "delete" : "keep"
                try config.save()
                self?.onConfigChanged?()
            },
            onContinue: { [weak self] didDelete in
                self?.resolved = true
                self?.close()
                self?.onResolved?()
            },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "speakfree"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        if !resolved { onDismissed?() }
    }
}

/// Standalone host used by the menu-bar "Recent Dictations → Clear…" command.
final class RecordingsTrashWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: RecordingsTrashWindowController?

    static func present() {
        if let existing = shared?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = RecordingsTrashWindowController(window: nil)
        let view = RecordingsTrashConfirmView(
            fileCount: RecordingStore.recordingCount(),
            folderPath: RecordingStore.recordingsDir.path,
            onDeleted: {}, onRestored: {}, onDismiss: { [weak controller] in controller?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "speakfree"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.window = window
        shared = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

// MARK: - The notice view (banner design, Michael 2026-07-14)

struct RecordingsNoticeView: View {
    var initialRetention = 0
    var folderPath = RecordingStore.recordingsDir.path
    var recordingCount: Int = RecordingStore.recordingCount()
    var artifactCount: Int = RecordingStore.recordingFileCount()
    var refreshCounts: (() -> (Int, Int))? = nil
    var choiceIsBold = true
    var folderAlignment: Alignment = .center
    var noteText = NoticeCopy.note
    var openFolder: ((String) -> Void)? = nil
    /// Called only after the user confirms Move. A failed Trash operation must not
    /// silently leave future saving on after the explicit Keep None choice.
    var onSaveSelection: (Int) throws -> Void = { _ in }
    /// The default is a proposal. Opening, inspecting, or canceling changes nothing.
    var onCommit: (Int, Bool) throws -> Void
    /// Resolves the notice. `didDelete` reports whether the in-app delete ran.
    var onContinue: (Bool) -> Void
    var onClose: () -> Void = {}
    var trashAction: @Sendable (@escaping @Sendable (RecordingRemoval.Progress) -> Void) -> RecordingRemoval.Result = { RecordingStore.trashAllRecordings(progress: $0) }

    @State private var retention = 0
    @State private var showDeleteConfirm = false
    /// Deleting (in-app) or opening the folder flips the continue button from
    /// "Keep my recordings »" to plain "Continue »" — the qualifier only
    /// makes sense while doing nothing is still the choice being made.
    @State private var didDelete = false
    @State private var didRestore = false
    @State private var confirmationCounts: (Int, Int)?
    @State private var preferenceError: String?

    fileprivate static let purple = Color(nsColor: WelcomeController.purple)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WaveformMark().frame(width: 36, height: 24)
                Text(NoticeCopy.header)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Self.purple.opacity(0.1))

            VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NoticeCopy.noteLabel)
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(noteText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                RecordingsFolderButton(folderPath: folderPath, open: openFolder)
                    .frame(maxWidth: .infinity, alignment: folderAlignment)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 10) {
                    Text(NoticeCopy.turnedOff)
                        .fontWeight(choiceIsBold ? .bold : .regular)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(RecordingRetention.label)
                        RecordingRetentionPicker(selection: $retention)
                    }
                    Text(RecordingRetention.explanation(retention, notice: !didRestore))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(width: 510, alignment: .leading)
                .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)

                if let preferenceError {
                    Text(preferenceError).foregroundStyle(.red)
                }
                Divider()

                HStack {
                    Spacer()
                    RecordingsChoiceButton(title: didDelete || didRestore ? NoticeCopy.continueLabel :
                           retention == -1 ? NoticeCopy.continueTrashLabel : NoticeCopy.continueKeepLabel) {
                        if retention == -1 && !didDelete && !didRestore {
                            confirmationCounts = refreshCounts?() ?? (recordingCount, artifactCount)
                            showDeleteConfirm = true
                        }
                        else { commitAndContinue() }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("continue-btn")
                    .help(retention == -1 && !didDelete && !didRestore ? "Review the Trash confirmation" : "Apply your recording choice")
                }
            }
            .padding(20)
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { retention = initialRetention }
        .onExitCommand { if !showDeleteConfirm { onClose() } }
        .sheet(isPresented: $showDeleteConfirm) {
            RecordingsTrashConfirmView(
                fileCount: confirmationCounts?.0 ?? recordingCount,
                artifactCount: confirmationCounts?.1 ?? artifactCount,
                folderPath: folderPath,
                beforeTrash: { try onSaveSelection(retention) },
                trashAction: trashAction,
                onDeleted: {
                    // Deletion no longer closes the notice — the user returns to it
                    // with the button reading "Continue »".
                    didDelete = true
                    do { try onCommit(retention, true) }
                    catch { preferenceError = "Files were moved, but the recording preference could not be saved: \(error.localizedDescription)" }
                },
                onRestored: {
                    didDelete = false
                    didRestore = true
                    // Restore returns files, never silently opts back into future saving.
                    do { try onCommit(retention, false) }
                    catch { preferenceError = "Files were restored, but the notice could not be saved: \(error.localizedDescription)" }
                }
            )
        }
    }

    private func commitAndContinue() {
        do {
            try onCommit(retention, didDelete)
            onContinue(didDelete)
        } catch {
            preferenceError = "Could not save your recording preference: \(error.localizedDescription)"
        }
    }
}

// MARK: - Delete confirmation (shared with Settings)

/// Shared recoverable removal UI. All filesystem work stays off the main queue;
/// completion is shown only after Finder Trash accepts the recordings.
struct RecordingsTrashConfirmView: View {
    /// Snapshot-only state. Production callers leave this nil and use real transitions.
    enum ReviewState {
        case moving(RecordingRemoval.Progress?)
        case completed(RecordingRemoval.Result, RecordingRemoval.RestoreResult?, RecordingRemoval.Progress?, Bool)
        case failed(RecordingRemoval.Result)
    }
    let fileCount: Int
    var artifactCount: Int = RecordingStore.recordingFileCount()
    let folderPath: String
    var folderAlignment: Alignment = .leading
    var reviewState: ReviewState? = nil
    var beforeTrash: () throws -> Void = {}
    var trashAction: @Sendable (@escaping @Sendable (RecordingRemoval.Progress) -> Void) -> RecordingRemoval.Result = {
        RecordingStore.trashAllRecordings(progress: $0)
    }
    var onDeleted: () -> Void
    var onRestored: () -> Void = {}
    var onDismiss: (() -> Void)? = nil

    @State private var isMoving = false
    @State private var progress: RecordingRemoval.Progress?
    @State private var result: RecordingRemoval.Result?
    @State private var restoreResult: RecordingRemoval.RestoreResult?
    @State private var restoreProgress: RecordingRemoval.Progress?
    @State private var isRestoring = false
    @State private var startError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result, result.succeeded {
                completion(result)
            } else {
                confirmation
                if let startError { Text(startError).foregroundStyle(.red) }
                if let result { failure(result) }
                if isMoving { progressIndicator }
                HStack {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isMoving)
                        .help("Return without moving any recordings")
                    Spacer()
                    Button(isMoving ? "Moving…" : "🗑️ Move to Trash") { moveToTrash() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("confirm-trash")
                        .help("Move eligible recordings and transcripts to Trash; active recordings stay here")
                        .disabled(isMoving)
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(isMoving || isRestoring)
        .onExitCommand { if !isMoving && !isRestoring { close() } }
        .onAppear {
            switch reviewState {
            case .moving(let update): isMoving = true; progress = update
            case .completed(let outcome, let restored, let update, let busy):
                result = outcome; restoreResult = restored; restoreProgress = update; isRestoring = busy
            case .failed(let outcome): result = outcome
            case nil: break
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NoticeCopy.confirmTitle(recordingCount: fileCount, artifactCount: artifactCount))
                .font(.headline)
            RecordingsFolderLink(folderPath: folderPath, alignment: folderAlignment)
                .accessibilityIdentifier("confirm-folder-link")
            Text(NoticeCopy.restoreNotice)
                .fixedSize(horizontal: false, vertical: true)
            Text(NoticeCopy.activeNotice)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressIndicator: some View {
        RecordingsTrashProgress(progress: progress)
    }

    private func completion(_ result: RecordingRemoval.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(restoreResult != nil ? (restoreResult?.succeeded == true ? "Recordings restored" : "Some recordings still need restoring") :
                 result.removedFiles > 0 ? "Moved to Trash" :
                 result.retainedRecordings > 0 ? "Recordings in use were kept" : "No recordings to move")
                .font(.headline).accessibilityIdentifier("trash-completion")
            if let restoreResult {
                Text("\(restoreResult.restoredRecordings.formatted()) recordings and transcripts "
                     + "(\(restoreResult.restoredFiles.formatted()) files) returned to the recordings folder.")
                if !restoreResult.succeeded {
                    Text("Some files could not be restored. Newer or active recordings, permissions, or an interrupted restore may be blocking them. They remain safe in the recovery folder.")
                        .foregroundStyle(.red)
                }
            } else {
                Text("\(result.removedRecordings.formatted()) recordings and transcripts "
                     + "(\(result.removedFiles.formatted()) files) were moved to Trash.")
            }
            if result.retainedRecordings > 0 {
                Text("\(result.retainedRecordings.formatted()) \(result.retainedRecordings == 1 ? "recording in use or started during this move was" : "recordings in use or started during this move were") kept in the recordings folder.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("trash-retained-recordings")
            }
            HStack {
                if result.removedFiles > 0 && restoreResult == nil {
                    if result.trashDirectory != nil {
                        Button(isRestoring ? "Restoring…" : "Restore") { restore(result) }
                            .disabled(isRestoring)
                            .help("Return these recordings and transcripts to their original folder without overwriting newer files")
                            .accessibilityIdentifier("restore-recordings")
                    }
                    Button("Open Trash") { openTrash(result) }
                        .help("Show the moved recordings in Finder Trash")
                } else if let recovery = restoreResult?.recoveryDirectory {
                    Button("Open Recovery Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recovery])
                    }
                    .help("Show the files that still need to be restored")
                    Button(isRestoring ? "Restoring…" : "Try Restore Again") {
                        retryRestore(from: recovery)
                    }
                    .disabled(isRestoring)
                    .help("Retry the safe restore without overwriting newer files")
                }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isRestoring)
                    .help("Close this result and return to the previous screen")
            }
            if isRestoring {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restoring recordings and transcripts…")
                    let total = Double(max(1, restoreProgress?.total ?? 1))
                    ProgressView(value: max(total * 0.02, Double(restoreProgress?.completed ?? 0)),
                                 total: total)
                        .progressViewStyle(.linear)
                }
                .accessibilityIdentifier("restore-progress")
            }
        }
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func failure(_ result: RecordingRemoval.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.enumerationFailed ? "The recordings folder could not be read." :
                 "\(result.removedFiles) files moved to Trash. \(result.failedFiles) files could not be moved.")
                .foregroundStyle(.red)
            if result.retainedRecordings > 0 {
                Text("\(result.retainedRecordings) recordings in use or started during this move were kept.")
                    .foregroundStyle(.secondary)
            }
            if let recovery = result.recoveryDirectory {
                Text("Some files are safe in a recovery folder. Open it before trying again.")
                Button("Open Recovery Folder") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }
                    .help("Show recordings preserved after the incomplete move")
            } else {
                Text("The remaining files are in the recordings folder. Check access and try again.")
                    .foregroundStyle(.secondary)
            }
            if result.removedFiles > 0 {
                Button("Open Trash") { openTrash(result) }
                    .help("Show the moved recordings in Finder Trash")
            }
        }
        .font(.callout)
        .accessibilityIdentifier("trash-error")
    }

    private func openTrash(_ result: RecordingRemoval.Result) {
        if let directory = result.trashDirectory {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        }
    }

    private func restore(_ result: RecordingRemoval.Result) {
        guard !isRestoring, let trashed = result.trashDirectory else { return }
        isRestoring = true
        restoreProgress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = RecordingRemoval.restoreTrashedBatch(
                trashed, to: URL(fileURLWithPath: folderPath, isDirectory: true),
                progress: { update in DispatchQueue.main.async { restoreProgress = update } })
            RecordingStore.invalidateCachedCount()
            DispatchQueue.main.async {
                NSWorkspace.shared.noteFileSystemChanged(folderPath)
                restoreResult = outcome
                isRestoring = false
                if outcome.restoredFiles > 0 { onRestored() }
            }
        }
    }

    private func retryRestore(from recovery: URL) {
        guard !isRestoring else { return }
        isRestoring = true
        restoreProgress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = RecordingRemoval.restoreBatch(
                recovery, to: URL(fileURLWithPath: folderPath, isDirectory: true),
                progress: { update in DispatchQueue.main.async { restoreProgress = update } })
            RecordingStore.invalidateCachedCount()
            DispatchQueue.main.async {
                NSWorkspace.shared.noteFileSystemChanged(folderPath)
                restoreResult = outcome
                isRestoring = false
                if outcome.restoredFiles > 0 { onRestored() }
            }
        }
    }

    private func moveToTrash() {
        guard !isMoving else { return }
        do {
            try beforeTrash()
            startError = nil
        } catch {
            startError = "Your recording preference could not be saved, so no files were moved. \(error.localizedDescription)"
            return
        }
        isMoving = true
        result = nil
        progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = trashAction { update in
                DispatchQueue.main.async { progress = update }
            }
            DispatchQueue.main.async {
                result = outcome
                isMoving = false
                if outcome.succeeded { onDeleted() }
            }
        }
    }
}

/// A visible file URL remains useful for long paths and keyboard/VoiceOver users.
struct RecordingsFolderLink: View {
    let folderPath: String
    var alignment: Alignment = .leading
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            onOpen()
            NSWorkspace.shared.open(URL(fileURLWithPath: folderPath, isDirectory: true))
        } label: {
            Text(folderPath)
                .foregroundStyle(.blue)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
        .help("Open recordings and transcripts in Finder: \(folderPath)")
        .accessibilityLabel("Open recordings and transcripts folder")
        .accessibilityValue(folderPath)
    }
}

/// Keep the same layout while preparation discovers the file count. Hiding the
/// reserved bar/count avoids resizing the sheet at its first moving-phase update.
struct RecordingsTrashProgress: View {
    let progress: RecordingRemoval.Progress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(progress == nil || progress?.phase == .preparing ? "Preparing…" :
                 progress?.phase == .finishing ? "Finishing…" : "Moving recordings and transcripts…")
                .lineLimit(1)
            let total = Double(max(1, progress?.total ?? 1))
            ProgressView(value: max(total * 0.02, Double(progress?.completed ?? 0)),
                         total: total)
                .progressViewStyle(.linear)
        }
        .accessibilityIdentifier("trash-progress")
    }
}

/// The five-bar speakfree waveform mark (same geometry as WelcomeController's LogoView).
struct WaveformMark: View {
    var body: some View {
        GeometryReader { geo in
            let heights: [CGFloat] = [0.28, 0.52, 0.78, 0.52, 0.28]
            let barW = geo.size.width * 0.12
            let gap = geo.size.width * 0.09
            let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
            let startX = geo.size.width / 2 - total / 2
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color(nsColor: WelcomeController.purple))
                    .frame(width: barW, height: geo.size.height * heights[i])
                    .position(x: startX + CGFloat(i) * (barW + gap) + barW / 2,
                              y: geo.size.height / 2)
            }
        }
    }
}
