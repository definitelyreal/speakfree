// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import AppKit

class MenuItemTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

/// M1: dedicated delegate for the "Recent Dictations" submenu so its lazy population is never
/// confused with the top-level menu's `menuNeedsUpdate:` (which rebuilds every item). The submenu's
/// transcript sidecars are read only here — when the user actually opens the submenu — instead of on
/// every programmatic `buildMenu()`.
private final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    let populate: (NSMenu) -> Void
    init(populate: @escaping (NSMenu) -> Void) { self.populate = populate }
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }
}

class StatusBarController: NSObject, NSMenuDelegate {
    private(set) var statusItem: NSStatusItem
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var animationFrames: [NSImage] = []
    private var downloadProgress: String?
    private var copiedFeedback = false
    private var menuItemTargets: [MenuItemTarget] = []
    // M1: the recent-submenu's targets are retained separately from the main menu's so a top-level
    // rebuild (which clears `menuItemTargets`) can't invalidate the actions of an open submenu.
    private var recentMenuTargets: [MenuItemTarget] = []
    private var recentMenuDelegate: RecentMenuDelegate?
    private var recentRecordingsSnapshot: [Recording] = []
    private var hasLoadedRecentRecordings = false
    private var recentRefreshInFlight = false
    private var recentRefreshPending = false

    var historyHandler: (() -> Void)?
    var reprocessHandler: ((URL) -> Void)?
    /// Inserts an Edit session's committed text, or one ⤷ component's, into the frontmost app.
    var insertTextHandler: ((String) -> Void)?
    private var recentEditSessionsSnapshot: [EditRecentSession] = []
    private var crashRecoveryURL: URL?
    private var crashRecoveryHandler: ((URL) -> Void)?

    func showCrashRecovery(url: URL, handler: @escaping (URL) -> Void) {
        crashRecoveryURL = url
        crashRecoveryHandler = handler
        buildMenu()
    }

    /// Called by AppDelegate when a recovery SUCCEEDS (transcript saved). Until then
    /// the menu entry persists so failures and busy-state rejections can be retried.
    func clearCrashRecovery() {
        crashRecoveryURL = nil
        crashRecoveryHandler = nil
        buildMenu()
    }

    var captureMessage: String? { didSet { buildMenu() } }

    /// While "Stay on <headset>" is on, the menu-bar icon carries a small monochrome
    /// headset badge (never orange: macOS already shows an orange mic dot there).
    var stayOnActive = false { didSet { if stayOnActive != oldValue { updateIcon() } } }

    var modelIsLoading = false {
        didSet {
            modelLoadMessage = modelIsLoading ? ModelPreparationPhase.preparing(standInReady: false).menuMessage : nil
        }
    }
    var modelLoadMessage: String? { didSet { buildMenu() } }

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case downloading
        /// Model just finished downloading and the app is set up, but the user hasn't dictated yet.
        /// Drawn as a green logo — an at-a-glance "you're all set, try it now" cue. Cleared to `.idle`
        /// the moment the first dictation starts (see AppDelegate.handleKeyDown → `.recording`).
        case ready
        case waitingForPermission
        case copiedToClipboard
        /// Recording transcribed to NOTHING (near-silent capture: mic muted or a stale
        /// input route). Shown briefly so a lost dictation is never a silent no-op —
        /// the user spoke, held the key, and deserves to know nothing was heard.
        case noSpeech
        case captureFailed
        /// Secure-Input fallback: dictated text was copied with concealment markers and will
        /// auto-clear after the configured delay. Shows a distinct notification so the user
        /// knows the clipboard will self-clean (audit M2).
        case secureInputCopied
        case noModel
        /// Setup threw a fatal error. The process stays alive so the user can read the
        /// error text in the menu and quit cleanly.
        case setupFailed(message: String)
    }

    var state: State = .idle {
        didSet { updateIcon() }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusBarController.drawLogo(active: false)
            button.image?.isTemplate = true
        }

        buildMenu()
        requestRecentRecordingsRefresh()
    }

    // Called before the menu is displayed — rebuild items so state changes are reflected
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(menu)
    }

    @objc private func copyLastTranscription() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let text = delegate.lastTranscription else { return }
        let pasteboard = NSPasteboard.general
        UserPasteRestoreGate.shared.writeOutsideBorrow {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        copiedFeedback = true
        buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copiedFeedback = false
            self?.buildMenu()
        }
    }

    func updateDownloadProgress(_ text: String?) {
        downloadProgress = text
        buildMenu()
    }

    private static func relativeTime(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    private func rebuildMenuItems(_ menu: NSMenu) {
        menuItemTargets = []
        menu.removeAllItems()
        buildMenuItems(into: menu)
    }

    /// True while the status menu is on screen. `buildMenu()` must never mutate an
    /// OPEN menu (2026-07-25: recovery's state flips rebuilt it under the cursor,
    /// closing it mid-hover) — rebuilds are deferred to `menuDidClose`, and
    /// `menuNeedsUpdate` already refreshes contents at the next open.
    private var menuIsOpen = false
    private var pendingMenuRebuild = false

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menuIsOpen = false
        if pendingMenuRebuild {
            pendingMenuRebuild = false
            buildMenu()
        }
    }

    func buildMenu() {
        if menuIsOpen {
            pendingMenuRebuild = true
            return
        }
        let menu = statusItem.menu ?? NSMenu()
        menuItemTargets = []
        menu.removeAllItems()
        buildMenuItems(into: menu)
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Keep the newest saved take visible without rescanning the 50k-artifact corpus after every
    /// state change. The old buildMenu-triggered scan occasionally took 10–35 seconds under load;
    /// that competed with the event tap and produced the user-visible "fn did nothing, then the
    /// Globe panel opened" outage. Disk reconciliation still runs at launch and submenu-open.
    /// A refresh can read the newest take before its transcript sidecar is written (sidecars
    /// follow insertion since 2026-09-22); keep the text the snapshot already has for that URL
    /// rather than showing "(no transcript)".
    static func keepingKnownText(refreshed: [Recording], previous: [Recording]) -> [Recording] {
        let known = Dictionary(previous.compactMap { r in r.text.map { (r.url, $0) } },
                               uniquingKeysWith: { first, _ in first })
        return refreshed.map { r in
            guard r.text?.isEmpty ?? true, let text = known[r.url] else { return r }
            return Recording(url: r.url, date: r.date, text: text)
        }
    }

    func noteFinishedRecording(url: URL, text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.noteFinishedRecording(url: url, text: text)
            }
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let stamp = String(name.dropFirst(RecordingStore.filePrefix.count).prefix(17))
        let date = RecordingStore.parseTimestamp(stamp) ?? Date()
        recentRecordingsSnapshot.removeAll { $0.url == url }
        recentRecordingsSnapshot.insert(Recording(url: url, date: date, text: text), at: 0)
        if recentRecordingsSnapshot.count > 15 {
            recentRecordingsSnapshot.removeLast(recentRecordingsSnapshot.count - 15)
        }
        hasLoadedRecentRecordings = true
    }

    private func buildMenuItems(into menu: NSMenu) {

        let titleItem = NSMenuItem(title: SpeakFree.menuTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Microphone block (2026-09-24, "Stay on <headset>"): what is recording, then
        // CHANGE TO with the wired mics and each headset's Stay-on rows. Cache reads only.
        if let delegate = NSApplication.shared.delegate as? AppDelegate, let model = delegate.micMenuModel() {
            addMicBlock(model, into: menu)
            menu.addItem(NSMenuItem.separator())
        }

        // Settings — opens the SwiftUI Settings window (first after title)
        let settingsTarget = MenuItemTarget {
            guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
            delegate.showSettings()
        }
        menuItemTargets.append(settingsTarget)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(MenuItemTarget.invoke), keyEquivalent: ",")
        settingsItem.target = settingsTarget
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        if let progress = downloadProgress {
            let dlItem = NSMenuItem(title: progress, action: nil, keyEquivalent: "")
            dlItem.isEnabled = false
            menu.addItem(dlItem)
            menu.addItem(NSMenuItem.separator())
        }

        if let message = captureMessage {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        if let message = modelLoadMessage {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        // Status line — only show when not idle/ready (remove "Ready" noise; the green icon already
        // signals the ready state).
        if state != .idle && state != .ready {
            let stateText: String
            switch state {
            case .idle, .ready: stateText = ""  // unreachable — excluded above
            case .recording: stateText = "Recording..."
            case .transcribing: stateText = "Transcribing..."
            case .downloading: stateText = "Downloading model..."
            case .waitingForPermission: stateText = "⚠️ Grant Accessibility Permission →"
            case .copiedToClipboard: stateText = "Copied to clipboard"
            case .noSpeech: stateText = "⚠️ No speech detected — check your mic"
            case .captureFailed: stateText = "⚠️ Capture failed - please try again"
            case .secureInputCopied: stateText = "Copied — auto-clears in 15s (Secure Input)"
            case .noModel: stateText = "⚠️ No model — open Settings to download"
            case .setupFailed(let message): stateText = "⛔ Setup failed: \(message)"
            }
            if case .setupFailed = state {
                // Show the error message as a disabled item so the user can read it.
                // The process stays alive; the Quit item at the bottom of the menu lets the
                // user exit cleanly.
                let errorItem = NSMenuItem(title: stateText, action: nil, keyEquivalent: "")
                errorItem.isEnabled = false
                menu.addItem(errorItem)
                menu.addItem(NSMenuItem.separator())
            } else if case .waitingForPermission = state {
                let target = MenuItemTarget {
                    // Clear the stale TCC entry then re-prompt. M4: never block the main thread on
                    // `waitUntilExit()` — run tccutil async and fire the AX prompt from the
                    // termination handler (back on main). If launch fails, prompt anyway.
                    let promptForAccessibility = {
                        DispatchQueue.main.async {
                            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
                            AXIsProcessTrustedWithOptions(options)
                        }
                    }
                    let task = Process()
                    task.launchPath = "/usr/bin/tccutil"
                    task.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.definitelyreal.speakfree"]
                    task.terminationHandler = { _ in promptForAccessibility() }
                    do {
                        try task.run()
                    } catch {
                        promptForAccessibility()
                    }
                }
                menuItemTargets.append(target)
                let stateItem = NSMenuItem(title: stateText, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                stateItem.target = target
                menu.addItem(stateItem)
            } else if case .noModel = state {
                let target = MenuItemTarget {
                    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
                    delegate.showSettings()
                }
                menuItemTargets.append(target)
                let stateItem = NSMenuItem(title: stateText, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                stateItem.target = target
                menu.addItem(stateItem)
            } else {
                let stateItem = NSMenuItem(title: stateText, action: nil, keyEquivalent: "")
                stateItem.isEnabled = false
                menu.addItem(stateItem)
            }

            menu.addItem(NSMenuItem.separator())
        }

        if let historyHandler {
            let target = MenuItemTarget(handler: historyHandler)
            menuItemTargets.append(target)
            let history = NSMenuItem(title: "History…", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            history.target = target
            menu.addItem(history)
        }
        else {
            let recentParent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
            recentParent.submenu = makeSavedDictationsMenu()
            menu.addItem(recentParent)
        }

        // Developer machines only: exercise the Edit Mode window without a microphone.
        if DevMode.isActive {
            let sampleTarget = MenuItemTarget {
                (NSApplication.shared.delegate as? AppDelegate)?.openEditModeWithSample()
            }
            menuItemTargets.append(sampleTarget)
            let sampleItem = NSMenuItem(title: "Edit Mode: Add Sample Paragraph",
                                        action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            sampleItem.target = sampleTarget
            menu.addItem(sampleItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Transcribe audio file — below Recent Dictations
        let transcribeTarget = MenuItemTarget { FileTranscriptionController.show() }
        menuItemTargets.append(transcribeTarget)
        let transcribeItem = NSMenuItem(title: "Transcribe Audio File…",
                                        action: #selector(MenuItemTarget.invoke),
                                        keyEquivalent: "t")
        transcribeItem.target = transcribeTarget
        transcribeItem.keyEquivalentModifierMask = .command
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())

        // Check for Updates — wired to Sparkle's updater
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
           let delegate = NSApplication.shared.delegate as? AppDelegate {
            let updateTarget = MenuItemTarget {
                delegate.updaterController.checkForUpdates(nil)
            }
            menuItemTargets.append(updateTarget)
            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            updateItem.target = updateTarget
            menu.addItem(updateItem)
        } else if Bundle.main.object(forInfoDictionaryKey: "SFBuildChannel") as? String == "alpha" {
            let manualUpdateItem = NSMenuItem(title: "Alpha updates are manual", action: nil, keyEquivalent: "")
            manualUpdateItem.isEnabled = false
            menu.addItem(manualUpdateItem)
        }

        // Report a Problem with <App>… (2026-09-24): about the app that was in front when the
        // menu opened (or the last one before a speakfree window). Hidden when there is none.
        if let app = AppProblemWindowController.currentTargetApp() {
            let problemTarget = MenuItemTarget { AppProblemWindowController.show(for: app) }
            menuItemTargets.append(problemTarget)
            let name = app.localizedName ?? app.bundleIdentifier ?? "This App"
            let problemItem = NSMenuItem(title: "Report a Problem with \(name)…",
                                         action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            problemItem.target = problemTarget
            problemItem.toolTip = "Try a different insertion method for this app, mark what works, and optionally open a prefilled bug report. No dictated text is included."
            menu.addItem(problemItem)
        }

        let helpTarget = MenuItemTarget { HelpController.show() }
        menuItemTargets.append(helpTarget)
        let helpItem = NSMenuItem(title: "Help", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        helpItem.target = helpTarget
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// History's archive link preserves recovery and saved Edit-session actions without
    /// adding a second competing history item to the menu bar. No sidecars are read here.
    func showSavedDictationsMenu() {
        let menu = makeSavedDictationsMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func makeSavedDictationsMenu() -> NSMenu {
        let menu = NSMenu(title: "Saved Dictations")
        menu.addItem(NSMenuItem(title: "…", action: nil, keyEquivalent: ""))
        let delegate = RecentMenuDelegate { [weak self] submenu in self?.populateRecentMenu(submenu) }
        menu.delegate = delegate
        recentMenuDelegate = delegate
        return menu
    }

    /// M1: build the "Recent Dictations" submenu on demand (when it opens), reading transcript
    /// sidecars only for the newest 15 recordings — never for the whole corpus, and never on a plain
    /// `buildMenu()`.
    private func populateRecentMenu(_ menu: NSMenu) {
        let renderStarted = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - renderStarted) * 1_000
            DiagnosticLogger.shared.log(String(
                format: "Recent Dictations: rendered cached menu in %.1f ms", elapsedMs))
        }
        recentMenuTargets = []
        menu.removeAllItems()

        // Crash recovery at top if pending. The entry SURVIVES the click (codex review
        // #7): it clears only when recovery succeeds (AppDelegate calls
        // clearCrashRecovery) — a busy-state rejection or a transcription failure
        // must leave a retry path, not a one-shot pointer.
        if let recoveryURL = crashRecoveryURL, let recoveryHandler = crashRecoveryHandler {
            let target = MenuItemTarget {
                recoveryHandler(recoveryURL)
            }
            recentMenuTargets.append(target)
            let recoveryItem = NSMenuItem(title: "⚠️ Recover Unsaved Recording", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            recoveryItem.target = target
            menu.addItem(recoveryItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Never touch the 23k-file corpus from a submenu hover. `buildMenu()` and the
        // previous hover refresh this snapshot on a utility queue; hover only renders it.
        let recordings = recentRecordingsSnapshot

        if !hasLoadedRecentRecordings {
            let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
            requestRecentRecordingsRefresh()
            return
        }
        // Refresh for the next open without delaying this one.
        requestRecentRecordingsRefresh()

        let items = EditRecents.merge(recordings: recordings, sessions: recentEditSessionsSnapshot)
        if items.isEmpty {
            if crashRecoveryURL == nil {
                let emptyItem = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            }
            return
        }

        for (index, item) in items.enumerated() {
            // Edit Mode session: the full text first, then each paragraph on a "⤷" line.
            if case .session(let session) = item {
                let age = StatusBarController.relativeTime(from: session.date)
                let parentTarget = MenuItemTarget { [weak self] in
                    self?.insertTextHandler?(session.text)
                }
                recentMenuTargets.append(parentTarget)
                let parent = NSMenuItem(title: "\(age) — \(EditRecents.parentTitle(session))",
                                        action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                parent.target = parentTarget
                menu.addItem(parent)
                for component in session.components {
                    let childTarget = MenuItemTarget { [weak self] in
                        self?.insertTextHandler?(component.text)
                    }
                    recentMenuTargets.append(childTarget)
                    let child = NSMenuItem(title: EditRecents.componentTitle(component),
                                           action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                    child.target = childTarget
                    child.indentationLevel = 1
                    menu.addItem(child)
                }
                if index == 0 && items.count > 1 { menu.addItem(NSMenuItem.separator()) }
                continue
            }
            guard case .recording(let url) = item,
                  let recording = recordings.first(where: { $0.url == url }) else { continue }
            let age = StatusBarController.relativeTime(from: recording.date)
            let preview: String
            if let t = recording.text, !t.isEmpty {
                let short = t.prefix(50).replacingOccurrences(of: "\n", with: " ")
                preview = t.count > 50 ? "\(short)…" : String(short)
            } else {
                preview = "(no transcript)"
            }
            let label = "\(age) — \(preview)"
            let target = MenuItemTarget { [weak self] in
                self?.reprocessHandler?(recording.url)
            }
            recentMenuTargets.append(target)
            let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
            // Separator after the first (most recent) recording
            if index == 0 && items.count > 1 {
                menu.addItem(NSMenuItem.separator())
            }
        }

        // Cheap affordance: reach the full corpus in Finder rather than materializing thousands of
        // items in the menu (the submenu is capped at 15).
        menu.addItem(NSMenuItem.separator())
        let folderTarget = MenuItemTarget {
            NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.recordingsDir])
        }
        recentMenuTargets.append(folderTarget)
        let folderItem = NSMenuItem(title: "Open Recordings Folder…", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        folderItem.target = folderTarget
        menu.addItem(folderItem)

        let clearTarget = MenuItemTarget { RecordingsTrashWindowController.present() }
        recentMenuTargets.append(clearTarget)
        let clearItem = NSMenuItem(title: "Clear…", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        clearItem.target = clearTarget
        menu.addItem(clearItem)
    }

    /// Main-thread state, background filesystem work. If another state change requests
    /// a refresh while one is running, perform exactly one follow-up so the newest
    /// completed dictation cannot be stranded behind a stale in-flight snapshot.
    private func requestRecentRecordingsRefresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestRecentRecordingsRefresh()
            }
            return
        }
        guard !recentRefreshInFlight else {
            recentRefreshPending = true
            return
        }
        recentRefreshInFlight = true
        // `.userInitiated`, not `.utility` (2026-08-05). The work itself is 33 ms measured on the
        // real 47,187-entry corpus — names-only readdir, filename sort, then ≤15 sidecar reads —
        // yet this refresh logged 10-35 s on 112 occasions in a single day, worst 34.8 s. A 700x
        // gap is scheduler starvation, not work: `.utility` is aggressively deprioritized under
        // load and on battery. This backs a menu the user is about to open, so it belongs in the
        // user-initiated band.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let refreshStarted = CFAbsoluteTimeGetCurrent()
            let recordings = RecordingStore.listRecordings(limit: 15)
            let editSessions = EditRecents.list(limit: 15)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - refreshStarted) * 1_000
            DiagnosticLogger.shared.log(String(
                format: "Recent Dictations: refreshed %d-item cache in %.1f ms",
                recordings.count, elapsedMs))
            DispatchQueue.main.async {
                guard let self else { return }
                self.recentRecordingsSnapshot = Self.keepingKnownText(
                    refreshed: recordings, previous: self.recentRecordingsSnapshot)
                self.recentEditSessionsSnapshot = editSessions
                self.hasLoadedRecentRecordings = true
                self.recentRefreshInFlight = false
                if self.recentRefreshPending {
                    self.recentRefreshPending = false
                    self.requestRecentRecordingsRefresh()
                }
            }
        }
    }

    @objc private func reloadConfiguration() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig()
    }

    private func updateIcon() {
        stopAnimation()

        switch state {
        case .idle:
            setIcon(stayOnActive ? StatusBarController.drawLogoWithHeadsetBadge() : StatusBarController.drawLogo(active: false))
        case .ready:
            setIcon(StatusBarController.drawGreenLogo())
        case .recording:
            startRecordingAnimation()
        case .transcribing:
            startTranscribingAnimation()
        case .downloading:
            startDownloadingAnimation()
        case .waitingForPermission:
            setIcon(StatusBarController.drawLockIcon())
        case .copiedToClipboard, .secureInputCopied:
            setIcon(StatusBarController.drawCheckmarkIcon())
        case .noSpeech, .captureFailed:
            setIcon(StatusBarController.drawErrorIcon())
        case .noModel:
            setIcon(StatusBarController.drawNoModelIcon())
        case .setupFailed:
            setIcon(StatusBarController.drawErrorIcon())
        }
    }

    // MARK: - Microphone block

    private func addMicBlock(_ model: MicMenuModel, into menu: NSMenu) {
        let first = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        first.isEnabled = false
        let text = NSMutableAttributedString()
        let regular = NSFont.menuFont(ofSize: 0)
        let bold = NSFont.boldSystemFont(ofSize: regular.pointSize)
        if let notice = model.firstRow.notice {
            text.append(NSAttributedString(string: notice + "\n", attributes: [.font: bold, .foregroundColor: NSColor.labelColor]))
            first.image = model.firstRow.noticeKind == .stayOn ? Self.stayOnGlyph()
                : NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        }
        text.append(NSAttributedString(string: model.firstRow.device, attributes: [.font: regular, .foregroundColor: NSColor.labelColor]))
        if let detail = model.firstRow.detail {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.menuFont(ofSize: regular.pointSize - 2), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        first.attributedTitle = text
        first.toolTip = model.accessibilityLabel
        menu.addItem(first)

        guard !model.rows.isEmpty else { return }
        menu.addItem(NSMenuItem.sectionHeader(title: "CHANGE TO"))
        for row in model.rows {
            switch row {
            case .microphone(let uid, let name, let checked, let selectsAutomatic):
                let item = actionItem(name) {
                    (NSApplication.shared.delegate as? AppDelegate)?.selectInputDevice(uid: selectsAutomatic ? nil : uid)
                }
                item.state = checked ? .on : .off
                menu.addItem(item)
            case .stayOn(let uid, let name, let title, let enabled):
                let item = actionItem(title) {
                    (NSApplication.shared.delegate as? AppDelegate)?.startStayOn(uid: uid, name: name, duration: .standard)
                }
                item.image = Self.stayOnGlyph()
                item.isEnabled = enabled
                item.toolTip = "Uses the \(name) mic for dictation for 2 hours. Music on it sounds like a phone call while Stay on is on, and it may switch over from your phone."
                menu.addItem(item)
            case .otherDurations(let uid, let name, let checked):
                let item = NSMenuItem(title: "Other durations", action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                let sub = NSMenu()
                for (i, group) in StayOnDuration.menuGroups.enumerated() {
                    if i > 0 { sub.addItem(NSMenuItem.separator()) }
                    for d in group {
                        let di = actionItem(d.menuTitle) {
                            (NSApplication.shared.delegate as? AppDelegate)?.startStayOn(uid: uid, name: name, duration: d)
                        }
                        di.state = d == checked ? .on : .off
                        sub.addItem(di)
                    }
                }
                item.submenu = sub
                menu.addItem(item)
            case .endStayOn:
                menu.addItem(actionItem("End Stay on") {
                    (NSApplication.shared.delegate as? AppDelegate)?.stayOn?.end(.turnedOff)
                })
            case .noMicOffered(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
    }

    private func actionItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuItemTarget(handler: handler)
        menuItemTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        item.target = target
        return item
    }

    /// Orange system timer symbol: orange marks Stay on, and only on this glyph. The shape
    /// (a timer: the mode ends on its own) carries the meaning without the color.
    static func stayOnGlyph() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Stay on")?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    /// The idle logo with a small monochrome headset badge, shown while Stay on is on.
    static func drawLogoWithHeadsetBadge() -> NSImage {
        let logo = drawLogo(active: false)
        let badge = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            logo.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            badge?.draw(in: NSRect(x: 15, y: 0, width: 9, height: 9))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "speakfree, Stay on"
        return image
    }

    // MARK: - Recording animation: wave

    private static let waveFrameCount = 30

    private static let recordingColor = NSColor(red: 0.6, green: 0.2, blue: 0.8, alpha: 1.0)

    private static func prerenderWaveFrames() -> [NSImage] {
        let count = waveFrameCount
        let baseHeights: [CGFloat] = [4, 8, 12, 8, 4]
        let minScale: CGFloat = 0.3
        let phaseOffsets: [Double] = [0.0, 0.15, 0.3, 0.45, 0.6]

        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                // Purple foreground bars, no background
                recordingColor.setFill()

                let barWidth: CGFloat = 2.0
                let gap: CGFloat = 2.5
                let radius: CGFloat = 1.5
                let centerX = rect.midX
                let centerY = rect.midY

                let totalWidth = CGFloat(baseHeights.count) * barWidth + CGFloat(baseHeights.count - 1) * gap
                let startX = centerX - totalWidth / 2

                for (i, baseHeight) in baseHeights.enumerated() {
                    let phase = t - phaseOffsets[i]
                    let scale = minScale + (1.0 - minScale) * CGFloat((sin(phase * 2.0 * .pi) + 1.0) / 2.0)
                    let height = baseHeight * scale
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let y = centerY - height / 2
                    let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                    NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
                }
                return true
            }
            image.isTemplate = false
            return image
        }
    }

    private func startRecordingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderWaveFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.waveFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
    }

    // MARK: - Transcribing animation: smooth wave dots

    private static let transcribeFrameCount = 30

    private static func prerenderTranscribeFrames() -> [NSImage] {
        let count = transcribeFrameCount
        let maxBounce: CGFloat = 3.0
        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

                let dotSize: CGFloat = 3
                let gap: CGFloat = 3.0
                let centerY = rect.midY - dotSize / 2
                let totalWidth = 3 * dotSize + 2 * gap
                let startX = rect.midX - totalWidth / 2

                for i in 0..<3 {
                    let phase = t - Double(i) * 0.15
                    let bounce = maxBounce * CGFloat(max(0, sin(phase * 2.0 * .pi)))
                    let x = startX + CGFloat(i) * (dotSize + gap)
                    let y = centerY + bounce
                    let dotRect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
                    NSBezierPath(ovalIn: dotRect).fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func startTranscribingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderTranscribeFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.transcribeFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
    }

    // MARK: - Downloading animation: rolling wave (each bar dips to a dot, sweeping left→right)

    private static let downloadFrameCount = 40

    private static func prerenderDownloadWaveFrames() -> [NSImage] {
        let count = downloadFrameCount
        let baseHeights: [CGFloat] = [4, 8, 12, 8, 4]
        let barWidth: CGFloat = 2.0
        let gap: CGFloat = 2.5
        let radius: CGFloat = 1.0
        let dotHeight: CGFloat = barWidth  // a fully-shrunk bar reads as a round dot

        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)
            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

                let centerX = rect.midX
                let centerY = rect.midY
                let totalWidth = CGFloat(baseHeights.count) * barWidth + CGFloat(baseHeights.count - 1) * gap
                let startX = centerX - totalWidth / 2

                for (i, base) in baseHeights.enumerated() {
                    // Each bar lags the one to its left, so the trough (dot) sweeps left→right.
                    let phase = 2.0 * .pi * (t - Double(i) / Double(baseHeights.count))
                    let s = CGFloat((sin(phase) + 1.0) / 2.0)  // 0 = dot, 1 = full height
                    let height = dotHeight + (base - dotHeight) * s
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let y = centerY - height / 2
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                                 xRadius: radius, yRadius: radius).fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func startDownloadingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderDownloadWaveFrames()
        setIcon(animationFrames[0])

        // Use a common-mode timer so the wave keeps animating even while the onboarding modal
        // panel is up (a default-mode timer is starved during NSApp.runModal).
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.downloadFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrames = []
    }

    private func setIcon(_ image: NSImage) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.image = image
                // Don't override isTemplate — recording frames set it to false for purple color
            }
        }
    }

    // MARK: - Custom drawn icons

    static func drawLogo(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.5
            let radius: CGFloat = 1.5
            let centerX = rect.midX
            let centerY = rect.midY

            let heights: [CGFloat] = [4, 8, 12, 8, 4]
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let startX = centerX - totalWidth / 2

            for (i, height) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + gap)
                let y = centerY - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Green-filled logo for the `.ready` state (post-download, pre-first-dictation). Not a template
    /// image — the green must render as an actual color, not be recolored to the menu-bar tint.
    static func drawGreenLogo() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.setFill()

            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.5
            let radius: CGFloat = 1.5
            let centerX = rect.midX
            let centerY = rect.midY

            let heights: [CGFloat] = [4, 8, 12, 8, 4]
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let startX = centerX - totalWidth / 2

            for (i, height) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + gap)
                let y = centerY - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = false  // keep the green; don't let the menu bar tint it
        return image
    }

    static func drawLockIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX

            let bodyRect = NSRect(x: centerX - 4, y: 2, width: 8, height: 7)
            NSBezierPath(roundedRect: bodyRect, xRadius: 1.5, yRadius: 1.5).fill()

            let shacklePath = NSBezierPath()
            shacklePath.move(to: NSPoint(x: centerX - 2.5, y: 9))
            shacklePath.curve(to: NSPoint(x: centerX + 2.5, y: 9),
                              controlPoint1: NSPoint(x: centerX - 2.5, y: 15),
                              controlPoint2: NSPoint(x: centerX + 2.5, y: 15))
            shacklePath.lineWidth = 1.8
            shacklePath.lineCapStyle = .round
            shacklePath.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawNoModelIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()

            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.5
            let radius: CGFloat = 1.0
            let centerX = rect.midX
            let centerY = rect.midY

            let heights: [CGFloat] = [4, 8, 12, 8, 4]
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let startX = centerX - totalWidth / 2

            for (i, height) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + gap)
                let y = centerY - height / 2
                let inset: CGFloat = 0.4
                let barRect = NSRect(x: x + inset, y: y + inset, width: barWidth - inset * 2, height: height - inset * 2)
                let path = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
                path.lineWidth = 0.8
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Exclamation mark in a circle — drawn for the `.setupFailed` state.
    static func drawErrorIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX
            let centerY = rect.midY
            let radius: CGFloat = 7.0

            // Circle outline
            let circlePath = NSBezierPath(ovalIn: NSRect(x: centerX - radius, y: centerY - radius,
                                                         width: radius * 2, height: radius * 2))
            circlePath.lineWidth = 1.5
            circlePath.stroke()

            // Exclamation bar
            let barPath = NSBezierPath()
            barPath.move(to: NSPoint(x: centerX, y: centerY + 3.5))
            barPath.line(to: NSPoint(x: centerX, y: centerY - 0.5))
            barPath.lineWidth = 2.0
            barPath.lineCapStyle = .round
            barPath.stroke()

            // Exclamation dot
            let dotRect = NSRect(x: centerX - 1.0, y: centerY - 3.5, width: 2.0, height: 2.0)
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawCheckmarkIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()

            let centerX = rect.midX
            let centerY = rect.midY

            let path = NSBezierPath()
            path.move(to: NSPoint(x: centerX - 5, y: centerY + 1))
            path.line(to: NSPoint(x: centerX - 2, y: centerY - 3))
            path.line(to: NSPoint(x: centerX + 5, y: centerY + 4))
            path.lineWidth = 2.0
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
