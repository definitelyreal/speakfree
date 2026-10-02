// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// The "Report a Problem with <App>…" window from the menu bar. Logic lives in
// AppProblemReport.swift (pure) and AppProblemModel below (side effects injected), so the
// "this works" flow is testable without a window, a keystroke or the real config.

import AppKit
import Combine
import SwiftUI

// MARK: - Model

final class AppProblemModel: ObservableObject {
    @Published private(set) var session: ProblemSession
    @Published private(set) var suggestion: ProblemSuggestion?
    @Published private(set) var savedMessage: String?
    @Published var note: String = "" {
        didSet { session.note = note }
    }

    /// Whether "Try Last Dictation Again" can run now (there is a dictation and none is in flight).
    @Published private(set) var canRetry = false
    /// One line about the last retry when it did not insert.
    @Published private(set) var retryMessage: String?

    let speakfreeVersion: String
    let macOSVersion: String
    /// Clipboard readers and canary results for the report (no clipboard content). Built when
    /// the window opens.
    let clipboardDiagnostic: String?
    private let applySetting: (InsertionMethod) -> Void
    private let recordConfirmation: (InsertionConfirmation) -> Void
    private let forgetConfirmation: (InsertionMethod) -> Void
    private let retryAvailable: () -> Bool
    private let now: () -> Date

    init(session: ProblemSession,
         speakfreeVersion: String,
         macOSVersion: String,
         applySetting: @escaping (InsertionMethod) -> Void,
         recordConfirmation: @escaping (InsertionConfirmation) -> Void,
         forgetConfirmation: @escaping (InsertionMethod) -> Void = { _ in },
         retryAvailable: @escaping () -> Bool = { false },
         now: @escaping () -> Date = Date.init,
         clipboardDiagnostic: String? = nil) {
        self.session = session
        self.clipboardDiagnostic = clipboardDiagnostic
        self.speakfreeVersion = speakfreeVersion
        self.macOSVersion = macOSVersion
        self.applySetting = applySetting
        self.recordConfirmation = recordConfirmation
        self.forgetConfirmation = forgetConfirmation
        self.retryAvailable = retryAvailable
        self.now = now
        self.canRetry = retryAvailable()
    }

    func refreshCanRetry() {
        let value = retryAvailable()
        if value != canRetry { canRetry = value }
    }

    func retryStarted() {
        retryMessage = nil
        refreshCanRetry()
    }

    func retryFinished(_ result: AppDelegate.RetryResult) {
        switch result {
        case .inserted: retryMessage = nil
        case .skippedBusy: retryMessage = "Retry skipped: a dictation was in progress."
        case .appNotInFront: retryMessage = "Retry skipped: \(appName) did not come to the front."
        case .notDelivered: retryMessage = "Delivery was not confirmed. Check the dictation recovery prompt or clipboard."
        }
        refreshCanRetry()
    }

    /// The window is closing (or speakfree is quitting): undo a suggested "try it once more"
    /// that was never marked as working. Safe to call more than once.
    func finish() {
        guard let restore = session.settingToRestoreOnClose else { return }
        session.select(restore)
        applySetting(restore)
        reconfirm(session.concrete(restore))
    }

    /// Going back to a method marked as working this session: save its record again, since a
    /// later trial of another method may have replaced it (one record per app).
    private func reconfirm(_ method: InsertionMethod) {
        recordConfirmation(InsertionConfirmation(method: method, setting: session.setting(for: method),
                                                 appVersion: session.target.appVersion, date: now()))
    }

    var appName: String { session.target.appName }

    /// Pick a setting for the app. Saved right away, so the next dictation uses it.
    func choose(_ setting: InsertionMethod, asSuggestedTrial: Bool = false) {
        if setting == session.selected && suggestion == nil {
            // Picking what is already selected makes it the person's own choice (so closing
            // the window will not undo it); nothing to save.
            if !asSuggestedTrial { session.markSelectionDeliberate() }
            return
        }
        session.select(setting, asSuggestedTrial: asSuggestedTrial)
        suggestion = nil
        savedMessage = nil
        applySetting(setting)
    }

    /// "This works": record it locally, then maybe ask for one more try of a better method.
    func thisWorks() {
        let method = session.concrete(session.selected)
        let setting = session.selected
        suggestion = session.markWorked()
        recordConfirmation(InsertionConfirmation(method: method, setting: setting,
                                                 appVersion: session.target.appVersion, date: now()))
        savedMessage = "Saved on this Mac: \(method.label) works in \(appName)."
    }

    func didNotWork() {
        savedMessage = nil
        // A "works" record for this same method is no longer true.
        forgetConfirmation(session.concrete(session.selected))
        suggestion = session.markFailed()
    }

    /// Follow the current suggestion (try the preferred method, try the next, or go back).
    func acceptSuggestion() {
        switch suggestion {
        case .tryPreferred(let method):
            choose(session.setting(for: method), asSuggestedTrial: true)
        case .revert(to: let method):
            choose(session.setting(for: method))
            reconfirm(method)
        case .tryNext(let method):
            choose(session.setting(for: method))
        case .exhausted, .none:
            break
        }
    }

    func dismissSuggestion() { suggestion = nil }

    /// An insertion happened somewhere; keep it only if it went to this app.
    func observe(_ event: CompatibilityEvent) {
        refreshCanRetry()  // any insertion means there is now a dictation to retry
        guard event.bundleID.caseInsensitiveCompare(session.target.bundleID) == .orderedSame else { return }
        session.lastOutcome = event.outcome
        session.lastOutcomeDate = event.date
    }

    var reportBody: String {
        session.issueBody(speakfreeVersion: speakfreeVersion, macOSVersion: macOSVersion,
                          clipboardDiagnostic: clipboardDiagnostic)
    }

    var issueURL: URL? {
        ProblemSession.issueURL(title: session.issueTitle, body: reportBody)
    }

    /// Would the link cut the report? The preview always shows the whole report.
    var linkIsTrimmed: Bool {
        ProblemSession.issueURLIsTrimmed(title: session.issueTitle, body: reportBody)
    }

    var suggestionText: String? {
        switch suggestion {
        case .tryPreferred(let method):
            return "\(method.label) usually works better in this kind of app. Try it once more? If it fails, press Didn't Work to go back. Closing without marking it also goes back."
        case .tryNext(let method):
            return "Try \(method.label) next."
        case .revert(to: let method):
            return "Go back to \(method.label), which worked."
        case .exhausted:
            return "Nothing worked. A report helps: open one below."
        case .none:
            return nil
        }
    }

    var suggestionButton: String? {
        switch suggestion {
        case .tryPreferred(let method), .tryNext(let method): return "Try \(method.label)"
        case .revert(to: let method): return "Use \(method.label)"
        case .exhausted, .none: return nil
        }
    }
}

// MARK: - View

struct AppProblemView: View {
    @ObservedObject var model: AppProblemModel
    let onRetry: () -> Void
    let onOpenIssue: () -> Void
    let onCopy: () -> Void

    @State private var copied = false

    private var session: ProblemSession { model.session }

    private func label(for setting: InsertionMethod) -> String {
        setting == .automatic ? "Automatic (\(session.automaticMethod.label))" : setting.label
    }

    private var lastResult: String {
        guard let outcome = session.lastOutcome else {
            return "No dictation into \(model.appName) since this window opened or the method changed."
        }
        return "Last result in \(model.appName): \(outcome.rawValue)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.appName + (session.target.appVersion.map { " \($0)" } ?? ""))
                    .font(.headline)
                Text("Detected: \(session.appClass.label) (\(session.target.classification.reason))")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Method", selection: Binding(get: { session.selected },
                                                    set: { model.choose($0) })) {
                    ForEach(InsertionMethod.allCases) { setting in
                        Text(label(for: setting)).tag(setting)
                    }
                }
                .frame(maxWidth: 320)
                .help(session.selected.detail)
                Text("Saved right away, for \(model.appName) only. Switch to \(model.appName) and dictate again, or try your last dictation.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(lastResult).font(.footnote)
            }

            HStack(spacing: 8) {
                Button("Try Last Dictation Again", action: onRetry)
                    .disabled(!model.canRetry)
                    .help("Switches to \(model.appName) and inserts your most recent dictation (whichever app it first went to) with the chosen method.")
                Spacer()
                Button("Didn't Work") { model.didNotWork() }
                // No Return shortcut: a verdict must never come from pressing Return in the
                // note field.
                Button("This Works") { model.thisWorks() }
            }

            if let retry = model.retryMessage {
                Text(retry).font(.footnote).foregroundStyle(.secondary)
            }
            if let saved = model.savedMessage {
                Text(saved).font(.footnote).foregroundStyle(.secondary)
            }
            if let text = model.suggestionText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let button = model.suggestionButton {
                        Button(button) { model.acceptSuggestion() }
                        Button("Not Now") { model.dismissSuggestion() }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Send a report (optional)").font(.headline)
                TextField("What goes wrong? (optional, included as typed)", text: $model.note)
                Text("This is everything the report contains:")
                    .font(.footnote).foregroundStyle(.secondary)
                ScrollView {
                    Text(model.reportBody)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack(spacing: 8) {
                    Button("Open GitHub Issue…", action: onOpenIssue)
                    Button(copied ? "Copied" : "Copy Report") { onCopy(); copied = true }
                    Spacer()
                }
                if model.linkIsTrimmed {
                    Text("Too long for a link: the issue opens with the end of your note cut and says so. Use Copy Report to paste the whole thing.")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Opens a prefilled issue in your browser. Nothing is sent until you submit it there. A GitHub account is needed to submit.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

// MARK: - Window

final class AppProblemWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AppProblemWindowController?
    private static var lastExternalApp: NSRunningApplication?
    private static var activationObserver: NSObjectProtocol?

    private var model: AppProblemModel?
    private var target: NSRunningApplication?

    /// Remember the last app other than speakfree that was in front, so the menu can name it
    /// even while a speakfree window (Settings, this one) is frontmost.
    static func startTrackingFrontmostApps() {
        guard activationObserver == nil else { return }
        let own = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != own {
            lastExternalApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != nil, app.bundleIdentifier != own else { return }
            lastExternalApp = app
        }
    }

    /// The app a report would be about: the frontmost app, or the last one before speakfree.
    static func currentTargetApp() -> NSRunningApplication? {
        let own = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != nil, front.bundleIdentifier != own {
            return front
        }
        guard let last = lastExternalApp, !last.isTerminated else { return nil }
        return last
    }

    static func show(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        // Close any open window first: its close may restore a setting, and the new window
        // must read the setting after that write.
        shared?.close()
        let classification = AppCompatibility.classify(bundleID: bundleID, bundleURL: app.bundleURL)
        let info = app.bundleURL.flatMap { AppCompatibility.infoDictionary(at: $0) }
        let target = ProblemTarget(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            appVersion: info?["CFBundleShortVersionString"] as? String,
            classification: classification)
        let setting = AppCompatibility.override(for: bundleID, in: Config.load().effectiveInsertionOverrides)
        let model = AppProblemModel(
            session: ProblemSession(target: target, setting: setting),
            speakfreeVersion: SpeakFree.version,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            applySetting: { [weak delegate] method in delegate?.setInsertionMethod(method, forBundleID: bundleID) },
            recordConfirmation: { [weak delegate] confirmation in
                delegate?.recordInsertionConfirmation(confirmation, forBundleID: bundleID)
            },
            forgetConfirmation: { [weak delegate] method in
                delegate?.forgetInsertionConfirmation(method: method, forBundleID: bundleID)
            },
            retryAvailable: { [weak delegate] in delegate?.canRetryLastDictation ?? false },
            clipboardDiagnostic: ClipboardTrustStore.shared.diagnosticText())

        let controller = AppProblemWindowController(model: model, target: app)
        shared = controller
        CompatibilityReport.shared.listener = { [weak model] event in
            DispatchQueue.main.async { model?.observe(event) }
        }
        NSApp.showDockIconIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private convenience init(model: AppProblemModel, target: NSRunningApplication) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Report a Problem with \(model.appName)"
        // Stays visible above the app being tested while the person dictates into it.
        window.level = .floating
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.model = model
        self.target = target
        window.delegate = self
        let view = AppProblemView(
            model: model,
            onRetry: { [weak self] in self?.retry() },
            onOpenIssue: { [weak self] in self?.openIssue() },
            onCopy: { [weak self] in self?.copyReport() })
        // A hosting controller resizes the window as the suggestion box comes and goes.
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        // Size to the content before centering, so the window opens centered.
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        window.center()

        // Keep the retry button honest while a dictation starts or ends elsewhere.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.model?.refreshCanRetry()
        }
        // Quitting does not close windows through windowWillClose; undo a pending trial then too.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.model?.finish() }
    }

    private var pollTimer: Timer?
    private var terminateObserver: NSObjectProtocol?

    private func retry() {
        guard let target, let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        model?.retryStarted()
        delegate.retryLastDictation(in: target) { [weak self] result in
            self?.model?.retryFinished(result)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model?.refreshCanRetry()
    }

    private func openIssue() {
        guard let url = model?.issueURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyReport() {
        guard let body = model?.reportBody else { return }
        UserPasteRestoreGate.shared.writeOutsideBorrow {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model?.finish()
        pollTimer?.invalidate()
        pollTimer = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        CompatibilityReport.shared.listener = nil
        if Self.shared === self { Self.shared = nil }
        NSApp.hideDockIconIfNoWindows()
    }
}
