// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
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
/// Framing (Michael, 2026-08-21): the archive is a GIFT, not a confession. The copy
/// leads with what a corpus of the user's own speech can do for them (accuracy
/// replay, correction mining, personal vocabulary) and keeps the transparency line,
/// with delete/opt-out still one obvious click.
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

// MARK: - Copy (Michael's words; 2026-08-21 corpus-as-gift draft awaiting his edit)

enum NoticeCopy {
    static let header = "You have a corpus of your own speech on this Mac. Here is what it can do."
    static let noteLabel = "A note from Michael:"
    static let note = """
    Speakfree has been saving your dictations locally: the audio plus what it typed. \
    I use my own archive constantly. I replay every change to speakfree against \
    thousands of my past dictations, find the words it keeps getting wrong for me, \
    and teach it my vocabulary. Yours is the raw material for the same thing: \
    speakfree learning how you actually talk, on your Mac and nowhere else. Saving \
    was meant to be a developer setting, not the default, so I'd rather tell you \
    it's here and let you choose than quietly delete it.
    """
    static let turnedOff = "Saving new dictations is off unless you turn it on. Keep building your corpus here or in Settings:"
    static let toggleLabel = "Save recordings and transcripts"
    static let deleteLeadIn = "Rather not? "
    static let deleteLinkText = "→ 🗑️"
    static let deleteLeadOut = ", or do it yourself from the folder:"
    static let openFolderLabel = "Open Recordings / Transcripts Folder…"
    static let continueKeepLabel = "Keep my recordings »"
    static let continueLabel = "Continue »"

    static let confirmTitle = "Move recordings and transcripts to Trash?"
    static func confirmBody(fileCount: Int, folder: String) -> String {
        "Move \(fileCount) recording \(fileCount == 1 ? "file" : "files") from \(folder) to Trash. You can restore them until you empty Trash."
    }
    // Michael's wording, 2026-08-12 — shown in the delete confirmation so the user knows
    // what the recordings are for before destroying them.
    static let confirmDataNote = """
    A note before you move them: my saved recordings have been an incredible data source, \
    allowing me to run changes on Speakfree against all my past dictations and study \
    voice patterns / usage history. They are on your computer and never sent anywhere, \
    but can of course pose a privacy risk.
    """
    static let confirmQuestion = "Are you sure you want to do this?"
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
            initialSaveToggle: Config.load().saveRecordings?.value ?? false,
            onToggle: { [weak self] save in
                RecordingsNotice.persistSaveToggle(save)
                self?.onConfigChanged?()
            },
            onContinue: { [weak self] didDelete in
                self?.resolve(didDelete ? "delete" : "keep")
            }
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

// MARK: - The notice view (banner design, Michael 2026-07-14)

struct RecordingsNoticeView: View {
    var initialSaveToggle = false
    /// In the shipping dialog these persist config / delete files; the preview
    /// command injects inert versions, so a preview can never touch user data.
    var onToggle: (Bool) -> Void
    /// Resolves the notice. `didDelete` reports whether the in-app delete ran.
    var onContinue: (Bool) -> Void
    var trashAction: @Sendable (@escaping @Sendable (RecordingRemoval.Progress) -> Void) -> RecordingRemoval.Result = { RecordingStore.trashAllRecordings(progress: $0) }

    @State private var saveToggle = false
    @State private var showDeleteConfirm = false
    /// Deleting (in-app) or opening the folder flips the continue button from
    /// "Keep my recordings »" to plain "Continue »" — the qualifier only
    /// makes sense while doing nothing is still the choice being made.
    @State private var didDelete = false
    @State private var tookAction = false

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
                Text(NoticeCopy.noteLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(NoticeCopy.note)
                    .fixedSize(horizontal: false, vertical: true)

                Text(NoticeCopy.turnedOff)
                    .padding(.top, 4)

                Toggle(NoticeCopy.toggleLabel, isOn: $saveToggle)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("save-recordings-toggle")
                    .onChange(of: saveToggle) { newValue in onToggle(newValue) }

                // "Rather not? We can [delete everything], or do it yourself from the folder:"
                HStack(spacing: 0) {
                    Text(NoticeCopy.deleteLeadIn)
                    Button(NoticeCopy.deleteLinkText) { showDeleteConfirm = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("delete-link")
                        .accessibilityLabel("Move recordings and transcripts to Trash")
                    Text(NoticeCopy.deleteLeadOut)
                }
                .padding(.top, 6)

                Divider().padding(.vertical, 8)

                HStack {
                    Spacer()
                    Button(NoticeCopy.openFolderLabel) {
                        tookAction = true
                        NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.recordingsDir])
                    }
                    .fixedSize()
                    .accessibilityIdentifier("open-folder")
                    Button(tookAction ? NoticeCopy.continueLabel : NoticeCopy.continueKeepLabel) {
                        onContinue(didDelete)
                    }
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Self.purple)
                    .accessibilityIdentifier("continue-btn")
                }
            }
            .padding(20)
        }
        .frame(width: 540)
        .onAppear { saveToggle = initialSaveToggle }
        .sheet(isPresented: $showDeleteConfirm) {
            RecordingsTrashConfirmView(
                fileCount: RecordingStore.recordingFileCount(),
                folderPath: RecordingStore.recordingsDir.path,
                trashAction: trashAction,
                onDeleted: {
                    // Deletion no longer closes the notice — the user returns to it
                    // with the button reading "Continue »".
                    didDelete = true
                    tookAction = true
                }
            )
        }
    }
}

// MARK: - Delete confirmation (shared with Settings)

/// Shared recoverable removal UI. All filesystem work stays off the main queue;
/// completion is shown only after Finder Trash accepts the recordings.
struct RecordingsTrashConfirmView: View {
    let fileCount: Int
    let folderPath: String
    var trashAction: @Sendable (@escaping @Sendable (RecordingRemoval.Progress) -> Void) -> RecordingRemoval.Result = {
        RecordingStore.trashAllRecordings(progress: $0)
    }
    var onDeleted: () -> Void

    @State private var isMoving = false
    @State private var progress: RecordingRemoval.Progress?
    @State private var startedUptime: TimeInterval?
    @State private var completionElapsed: TimeInterval?
    @State private var result: RecordingRemoval.Result?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result, result.succeeded {
                completion(result)
            } else {
                confirmation
                if let result { failure(result) }
                if isMoving { progressIndicator }
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isMoving)
                    Spacer()
                    Button("Open Folder…") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folderPath)])
                    }
                    .accessibilityIdentifier("confirm-open-folder")
                    Button(isMoving ? "Moving…" : "Move to Trash") { moveToTrash() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("confirm-trash")
                        .disabled(isMoving)
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(isMoving)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NoticeCopy.confirmTitle).font(.headline)
            Text(NoticeCopy.confirmBody(fileCount: fileCount, folder: folderPath))
                .fixedSize(horizontal: false, vertical: true)
            Text(NoticeCopy.confirmDataNote)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("confirm-data-note")
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(progress?.phase == .finishing ? "Finishing move to Trash…" :
                     progress?.phase == .moving ? "Moving recordings…" : "Preparing recordings…")
                if let progress, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    Text("\(progress.completed) of \(progress.total) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let seconds = max(0, ProcessInfo.processInfo.systemUptime - (startedUptime ?? ProcessInfo.processInfo.systemUptime))
                    Text("\(String(format: "%.1f", seconds)) seconds")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("trash-progress")
    }

    private func completion(_ result: RecordingRemoval.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.removedFiles > 0 ? "Moved to Trash" : "No recordings to move")
                .font(.headline).accessibilityIdentifier("trash-completion")
            Text("\(result.removedFiles) files moved in \(String(format: "%.1f", completionElapsed ?? result.elapsedSeconds)) seconds.")
            Text("You can restore them from Trash until you empty it.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Trash") { openTrash(result) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
    }

    private func failure(_ result: RecordingRemoval.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.enumerationFailed ? "The recordings folder could not be read." :
                 "\(result.removedFiles) files moved to Trash. \(result.failedFiles) files could not be moved.")
                .foregroundStyle(.red)
            if let recovery = result.recoveryDirectory {
                Text("Some files are safe in a recovery folder. Open it before trying again.")
                Button("Open Recovery Folder") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }
            } else {
                Text("The remaining files are in the recordings folder. Check access and try again.")
                    .foregroundStyle(.secondary)
            }
            if result.removedFiles > 0 { Button("Open Trash") { openTrash(result) } }
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

    private func moveToTrash() {
        guard !isMoving else { return }
        isMoving = true
        startedUptime = ProcessInfo.processInfo.systemUptime
        completionElapsed = nil
        result = nil
        progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = trashAction { update in
                DispatchQueue.main.async { progress = update }
            }
            DispatchQueue.main.async {
                result = outcome
                completionElapsed = ProcessInfo.processInfo.systemUptime - (startedUptime ?? ProcessInfo.processInfo.systemUptime)
                isMoving = false
                if outcome.succeeded { onDeleted() }
            }
        }
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

// MARK: - Design-review preview (`speakfree notice-preview`)

/// Opens the shipping dialog with INERT actions — clicks only print to stdout;
/// nothing reads or writes config, and delete deletes nothing.
public enum RecordingsNoticePreview {
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Preview-only failure injection exercises the real error sheet without
        // deleting user files. It has no effect on the running dictation app.
        let simulateFailure = ProcessInfo.processInfo.environment["SPEAKFREE_NOTICE_PREVIEW_FAILURE"] == "1"

        let view = RecordingsNoticeView(
            initialSaveToggle: false,
            onToggle: { print("preview: toggle → \($0) — inert") },
            onContinue: { print("preview: Continue (didDelete=\($0)) — inert") },
            trashAction: { progress in
                print("preview: TRASH clicked — inert, nothing moved")
                for step in 0...10 {
                    Thread.sleep(forTimeInterval: 0.4)
                    progress(RecordingRemoval.Progress(phase: .moving, completed: step, total: 10,
                                                       elapsedSeconds: Double(step) * 0.4))
                }
                return RecordingRemoval.Result(removedFiles: simulateFailure ? 0 : 10,
                    failedFiles: simulateFailure ? 1 : 0, enumerationFailed: false,
                    recoveryDirectory: nil, trashDirectory: nil, elapsedSeconds: 4.4)
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Recordings notice — preview (inert)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFront(nil)

        app.activate(ignoringOtherApps: true)
        print("notice-preview: dialog on screen (inert) — Ctrl-C or close to quit")
        app.run()
    }
}
