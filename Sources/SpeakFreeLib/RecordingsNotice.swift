// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import AppKit
import SwiftUI

/// The recordings apology notice (Michael, 2026-07-14).
///
/// Through v1.7.1 every dictation's audio and transcript were saved to disk by
/// default — a dev-machine debugging setting that accidentally shipped to everyone.
/// Saving is now opt-in, and rather than silently deleting what accumulated, this
/// notice tells the user and lets THEM decide: keep the existing files or delete
/// them. It returns every launch and every few hours until they choose; once a
/// choice is persisted it never shows again.
public enum RecordingsNotice {

    public enum LaunchAction: Equatable {
        /// No recordings exist — nothing to apologize for. Persist "none-found" so a
        /// user who later opts in and accumulates recordings never sees the notice.
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

    /// Persist the user's choice. `deleteExisting` removes every recording and
    /// sidecar; `saveFutureRecordings` mirrors the dialog's toggle into Settings.
    static func resolve(deleteExisting: Bool, saveFutureRecordings: Bool) {
        if deleteExisting {
            RecordingStore.deleteAllRecordings()
        }
        var config = Config.load()
        config.recordingsNoticeDecision = deleteExisting ? "delete" : "keep"
        config.saveRecordings = FlexBool(saveFutureRecordings)
        try? config.save()
        DiagnosticLogger.shared.log(
            "RecordingsNotice: resolved (\(deleteExisting ? "delete" : "keep"), saveFuture=\(saveFutureRecordings))")
    }
}

final class RecordingsNoticeController: NSWindowController, NSWindowDelegate {

    /// Called when the user makes a keep/delete decision (notice is done forever).
    private var onResolved: (() -> Void)?
    /// Called when the window closes WITHOUT a decision (caller schedules a re-show).
    private var onDismissed: (() -> Void)?
    private var resolved = false

    static func present(onResolved: @escaping () -> Void,
                        onDismissed: @escaping () -> Void) -> RecordingsNoticeController {
        let controller = RecordingsNoticeController(window: nil)
        controller.onResolved = onResolved
        controller.onDismissed = onDismissed
        controller.loadNoticeWindow()
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    private func loadNoticeWindow() {
        let view = RecordingsNoticeView(
            onDecision: { [weak self] deleteExisting, saveFuture in
                RecordingsNotice.resolve(deleteExisting: deleteExisting,
                                         saveFutureRecordings: saveFuture)
                self?.resolved = true
                // Close BEFORE notifying: onResolved drops the owner's strong reference,
                // and a deallocated controller can't close its window (weak self → no-op,
                // leaving the window stranded on screen — caught by the AX harness).
                self?.close()
                self?.onResolved?()
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

private struct RecordingsNoticeView: View {
    /// (deleteExisting, saveFutureRecordings)
    let onDecision: (Bool, Bool) -> Void

    @State private var saveAudio = false
    @State private var showLetter = false

    // Michael's letter, verbatim.
    private static let letter = """
    Hey there, it's Michael, developer of Speakfree.

    As part of developing Speakfree, I had my local dev version recording all my \
    dictations, so I could troubleshoot. It makes it really easy to point Claude to \
    an issue and have it diagnose it, and improve transcription. What I didn't \
    realize was this turned on saving recordings for everyone. Your Speakfree has \
    been saving your recordings into a folder.

    They haven't left your computer, but this is a privacy-first app and recording \
    without your permission never should have happened.

    It's been turned off, and rather than silently delete your recordings and \
    pretend it didn't happen, I wanted to let you know.

    I'm committed to creating a privacy-first application that respects your data. \
    This is also a vibe-coded project, so sometimes these kinds of things can happen.

    Help me with the project and feel free to contribute on GitHub!

    Thanks for using Speakfree, and please tell your friends :)
    """

    private static let purple = Color(nsColor: WelcomeController.purple)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand header: the speakfree waveform + heading, centered.
            VStack(spacing: 10) {
                WaveformMark()
                    .frame(width: 46, height: 30)
                Text("We apologize!")
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 10) {
                Text("I accidentally turned on saving your recordings locally.")

                Text("You can now choose to save your recordings in preferences. "
                     + "It's been turned off, but you can turn it back on here:")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Save my recording audio", isOn: $saveAudio)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("save-recordings-toggle")
                    .padding(.top, 2)

                Button(showLetter ? "Read less «" : "Read more »") {
                    withAnimation { showLetter.toggle() }
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("read-more")
                .padding(.top, 2)
            }

            if showLetter {
                Divider().padding(.vertical, 12)
                Text(Self.letter)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Link("https://definitelyreal.github.io/speakfree/",
                     destination: URL(string: "https://definitelyreal.github.io/speakfree/")!)
                    .font(.callout)
                    .padding(.top, 6)
            }

            Divider().padding(.vertical, 14)

            HStack {
                Spacer()

                Button("Keep my recordings, or I'll delete them myself »") {
                    onDecision(false, saveAudio)
                }
                .fixedSize()
                .accessibilityIdentifier("keep-recordings")

                Button("Delete my recordings »") {
                    onDecision(true, saveAudio)
                }
                .fixedSize()
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Self.purple)
                .accessibilityIdentifier("delete-recordings")
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

/// The five-bar speakfree waveform mark (same geometry as WelcomeController's LogoView).
private struct WaveformMark: View {
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
