// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import AppKit
import SwiftUI

/// The recordings notice (Michael, 2026-07-14; copy revised same day).
///
/// Through v1.7.1 every dictation's audio and transcript were saved to disk by
/// default — a dev-machine debugging setting that accidentally shipped to everyone.
/// Saving is now opt-in, and rather than silently deleting what accumulated, this
/// notice tells the user and leaves the decision to them: keep the files (default),
/// open the folder and delete manually, or use the in-app delete confirmation.
/// It returns every launch and every few hours until acknowledged; once resolved
/// it never shows again.
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

// MARK: - Copy (Michael's words)

enum NoticeCopy {
    static let header = "We were saving local recordings on your device. It's off now."
    static let noteLabel = "A note from Michael:"
    static let note = """
    Speakfree has a dev mode feature that saves local recordings, which I use to \
    improve it. It wasn't supposed to be on for everyone, but it was. I'm committed \
    to privacy and transparency, so I wanted to let you know rather than silently \
    delete them.
    """
    static let turnedOff = "It's turned off now. Change the behavior here or in settings:"
    static let toggleLabel = "Save recordings and transcripts"
    static let deleteLeadIn = "We can "
    static let deleteLinkText = "delete them for you"
    static let deleteLeadOut = ", but I suggest you do it yourself for safety:"
    static let openFolderLabel = "Open Recordings / Transcripts Folder…"
    static let continueKeepLabel = "Continue without deleting »"
    static let continueLabel = "Continue »"

    static let confirmTitle = "Delete your recordings and transcripts"
    static func confirmBody(fileCount: Int, folder: String) -> String {
        "This will permanently delete \(fileCount) files in \(folder)."
    }
    // Michael's wording, 2026-08-12 — shown in the delete confirmation so the user knows
    // what the recordings are for before destroying them.
    static let confirmDataNote = """
    A note before you delete: my saved recordings have been an incredible data source, \
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
    var deleteAction: () -> Void = { RecordingStore.deleteAllRecordings() }

    @State private var saveToggle = false
    @State private var showDeleteConfirm = false
    /// Deleting (in-app) or opening the folder flips the continue button from
    /// "Continue without deleting »" to plain "Continue »" — the qualifier only
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

                // "We can [delete them for you], but I suggest you do it yourself for safety:"
                HStack(spacing: 0) {
                    Text(NoticeCopy.deleteLeadIn)
                    Button(NoticeCopy.deleteLinkText) { showDeleteConfirm = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("delete-link")
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
            DeleteRecordingsConfirmView(
                fileCount: RecordingStore.recordingFileCount(),
                folderPath: RecordingStore.recordingsDir.path,
                deleteAction: deleteAction,
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

/// "Open Folder…" keeps the sheet up (per spec); "Delete" performs the deletion and
/// dismisses. Cancel/Esc added beyond the spec — a permanent-delete confirmation
/// needs a way out that isn't one of the two actions.
struct DeleteRecordingsConfirmView: View {
    let fileCount: Int
    let folderPath: String
    var deleteAction: () -> Void = { RecordingStore.deleteAllRecordings() }
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NoticeCopy.confirmTitle)
                .font(.headline)
            Text(NoticeCopy.confirmBody(fileCount: fileCount, folder: folderPath))
                .fixedSize(horizontal: false, vertical: true)
            Text(NoticeCopy.confirmDataNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("confirm-data-note")
            Text(NoticeCopy.confirmQuestion)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Folder…") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: folderPath)])
                }
                .accessibilityIdentifier("confirm-open-folder")
                Button("Delete") {
                    deleteAction()
                    dismiss()
                    onDeleted()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("confirm-delete")
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 460)
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

        let view = RecordingsNoticeView(
            initialSaveToggle: false,
            onToggle: { print("preview: toggle → \($0) — inert") },
            onContinue: { print("preview: Continue (didDelete=\($0)) — inert") },
            deleteAction: { print("preview: DELETE clicked — inert, nothing deleted") }
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
