// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import ApplicationServices
import Carbon
import SwiftUI

/// The optional history feature owns observation and UI. The inserter remains a
/// standalone dictation service and accepts generic pasteboard items only.
final class HistoryCoordinator {
    let store: HistoryStore
    let model = HistoryPickerModel(preferences: .standard)
    var showSavedDictations: (() -> Void)?
    var showPreferences: (() -> Void)?
    private var presentationAnchor: NSPoint?
    private let monitor: ClipboardHistoryMonitor
    private let shortcut = HistoryShortcut()
    private let inserter: () -> TextInserter?
    private let isBusy: () -> Bool
    private var panel: HistoryPanel?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var target: Destination?
    private var operation: UInt64 = 0
    private var contentEpoch: UInt64 = 0
    private var captureReady = false
    static let shortcutStatusChanged = Notification.Name("SpeakFreeHistoryShortcutStatusChanged")
    private(set) var shortcutError: String?
    private var isReplaying: Bool { model.pasteBehavior == .pasting }
    private var isClosing = false
    private var isPreparingForTermination = false
    private var pauseReasons = Set<String>()

    private struct Destination {
        let app: NSRunningApplication
        let window: AXUIElement?
        let field: AXUIElement?
        let title: String?
    }

    init(config: Config, inserter: @escaping () -> TextInserter?, isBusy: @escaping () -> Bool) {
        self.inserter = inserter
        self.isBusy = isBusy
        let settings = config.history ?? .init()
        store = HistoryStore(fileURL: Config.configDir.appendingPathComponent("history/items.plist"), policy: settings.policy)
        monitor = ClipboardHistoryMonitor(pasteboard: .general, store: store)
        monitor.isClipboardBorrowed = { inserter()?.ownsCurrentClipboard ?? false }
        store.onChange = { [weak self] in self?.refresh() }
        monitor.onStatusChange = { [weak self] _ in self?.refresh() }
        shortcut.onPress = { [weak self] in self?.show() }
        shortcut.onAvailabilityChanged = { [weak self] error in
            guard let self else { return }
            self.shortcutError = error
            NotificationCenter.default.post(name: Self.shortcutStatusChanged, object: self)
            self.refresh()
        }
        model.choose = { [weak self] entry, copy in self?.choose(entry, copyOnly: copy) }
        model.remove = { [weak self] id in
            guard let self else { return }
            self.contentEpoch &+= 1
            self.store.remove(id: id)
        }
        model.close = { [weak self] in self?.close() }
        model.resize = { [weak self] in self?.positionPanel() }
        model.focusSearchEditor = { [weak self] in self?.panel?.focusSearchEditor() }
        model.openPreferences = { [weak self] in
            guard let self, !self.isBusy(), self.inserter()?.hasDeferredInsertion != true else { return }
            self.close()
            self.showPreferences?()
        }
        model.openSavedDictations = { [weak self] in
            guard let self, !self.isBusy(), self.inserter()?.hasDeferredInsertion != true else { return }
            self.close()
            self.showSavedDictations?()
        }
        observers.append(NotificationCenter.default.addObserver(forName: PasteboardWriteReceipt.notification, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["name"] as? String == NSPasteboard.Name.general.rawValue,
                  let count = note.userInfo?["changeCount"] as? Int else { return }
            self?.monitor.ignore(changeCount: count)
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.applicationDidActivate()
        })
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                self?.setPaused(notification == NSWorkspace.willSleepNotification ? "sleep" : "session", true)
            })
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in self?.setPaused(notification == NSWorkspace.didWakeNotification ? "sleep" : "session", false) })
        }
        configure(config)
        monitor.start()
    }

    private func setPaused(_ reason: String, _ paused: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if !wasPaused && !pauseReasons.isEmpty { close(); monitor.suspend() }
        if wasPaused && pauseReasons.isEmpty { monitor.resume() }
    }

    func configure(_ config: Config) {
        let settings = config.history ?? .init()
        store.configure(settings.policy)
        monitor.setEnabled(settings.policy.captureClipboard)
        model.clipboardEnabled = settings.policy.captureClipboard
        shortcutError = shortcut.configure(settings, dictation: config.hotkey)
        NotificationCenter.default.post(name: Self.shortcutStatusChanged, object: self)
        refresh()
    }

    func recordDictation(_ text: String, app: String?, archiveID: String?) {
        guard !isPreparingForTermination, !IsSecureEventInputEnabled(),
              !ClipboardHistoryMonitor.defaultExcludedApplications.contains(app?.lowercased() ?? "") else { return }
        store.addDictation(TextInserter.withoutTrace(text), sourceAppBundleID: app, linkedArchiveID: archiveID)
    }

    func importRecentDictations() {
        guard store.policy.captureDictations else {
            model.status = "Turn on history before importing saved dictations."
            return
        }
        let generation = operation
        let importEpoch = contentEpoch
        model.status = "Loading recent saved dictations…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recordings = RecordingStore.listRecordings(limit: 50)
            let sessions = EditRecents.list(limit: 15)
            let rows = EditRecents.merge(recordings: recordings, sessions: sessions, limit: 50)
            let byURL = Dictionary(uniqueKeysWithValues: recordings.map { ($0.url, $0) })
            let imported: [HistoryEntry] = rows.compactMap { row in
                let text: String
                let date: Date
                let archiveID: String
                let app: String?
                switch row {
                case .recording(let url):
                    guard let recording = byURL[url], let savedText = recording.text, !savedText.isEmpty else { return nil }
                    text = savedText; date = recording.date
                    archiveID = url.deletingPathExtension().lastPathComponent; app = nil
                case .session(let session):
                    text = session.text; date = session.date
                    archiveID = session.artifact.sessionID.uuidString; app = session.artifact.targetApp
                }
                return HistoryEntry(createdAt: date, source: .dictation, sourceAppBundleID: app,
                    linkedArchiveID: archiveID, items: [.init(representations: [
                        .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(TextInserter.withoutTrace(text).utf8))])])
            }
            DispatchQueue.main.async {
                guard let self, !self.isPreparingForTermination, self.contentEpoch == importEpoch else { return }
                let added = self.store.importDictations(imported)
                if self.operation == generation { self.model.status = "Added \(added) recent saved dictations within the history limits." }
            }
        }
    }

    func clear() {
        contentEpoch &+= 1
        // Invalidate deferred provider reads before erasing. Resuming baselines the
        // current clipboard so the just-cleared item cannot immediately reappear.
        monitor.suspend()
        store.clear()
        monitor.resume()
    }

    /// Finish queued history writes before normal app termination. Observation stops
    /// before the drain, so no late provider callback can append behind its barrier.
    func prepareForTermination(completion: @escaping (Result<Void, Error>) -> Void) {
        isPreparingForTermination = true
        setPaused("termination", true)
        var finished = false
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard !finished else { return }
            finished = true
            if case .failure = result {
                self?.isPreparingForTermination = false
                self?.setPaused("termination", false)
            }
            completion(result)
        }
        store.flushPendingPersistence(completion: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            finish(.failure(NSError(domain: "SpeakFreeHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Saving history took too long. speakfree stayed open to keep your session available."])))
        }
    }

    private func refresh() {
        model.entries = store.entries
        model.status = store.lastError ?? shortcutError ?? monitor.status
        if !store.policy.captureDictations { model.status = "History is off. Turn it on in Settings → Clipboard." }
        model.reconcileSelection()
    }

    func show() {
        guard !isBusy(), inserter()?.hasDeferredInsertion != true else { NSSound.beep(); return }
        if panel?.isVisible == true { close(); return }
        operation &+= 1
        let generation = operation
        target = nil
        captureReady = false
        store.pruneExpired()
        refresh()
        model.resetForPresentation()
        let app = NSWorkspace.shared.frontmostApplication
        if let app, app.processIdentifier != getpid() {
            // Don't fetch document text. Preserve window/field identity only, off-main.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.1)
                let window = Self.element(element, kAXFocusedWindowAttribute)
                let field = Self.element(element, kAXFocusedUIElementAttribute)
                let title = window.flatMap { Self.string($0, kAXTitleAttribute) }
                DispatchQueue.main.async {
                    guard let self, self.operation == generation else { return }
                    self.target = Destination(app: app, window: window, field: field, title: title)
                    self.captureReady = true
                }
            }
        } else { captureReady = true }
        presentationAnchor = NSEvent.mouseLocation
        if panel == nil { makePanel() }
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        model.handle(.focusSearch)
        installKeys()
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        model.pasteBehavior = .ready
        operation &+= 1
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    private func makePanel() {
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: model.preferredSize),
                                 styleMask: [.nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.onResignKey = { [weak self] in
            guard let self, !self.isReplaying else { return }
            self.close()
        }
        panel.onClose = { [weak self] in self?.close() }
        panel.title = "speakfree History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The panel dismisses with Escape or focus loss; remove titlebar controls so
        // the search field retains its full content inset.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = HistoryHostingView(rootView: HistoryPickerView(model: model))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let anchor = presentationAnchor,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) })
                ?? panel.screen ?? NSScreen.main else { return }
        model.fit(to: screen.visibleFrame)
        panel.setFrame(HistoryPickerLayout.frame(near: anchor, size: model.preferredSize,
                                                visibleFrame: screen.visibleFrame), display: panel.isVisible)
    }

    private func installKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard let action = self.model.keyAction(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
            self.model.handle(action)
            return nil
        }
    }

    private func choose(_ entry: HistoryEntry, copyOnly: Bool) {
        guard panel?.isVisible == true, !isReplaying, !isBusy(), let inserter = inserter() else { return }
        guard copyOnly || captureReady else { model.status = "Finding the previous window…"; return }
        // This is an explicit clipboard selection, not a temporary dictation borrow.
        guard inserter.replaceClipboardForUser(with: entry.makePasteboardItems(includeHistoryMarker: true)) else {
            model.status = inserter.isWaitingForClipboardConsumption
                ? "The previous dictation is still finishing. Try again after it appears; your selection is kept."
                : "Could not copy this item. It remains in History."
            return
        }
        let writtenCount = inserter.pasteboard.changeCount
        guard !copyOnly else { close(); return }
        guard let destination = target, !destination.app.isTerminated,
              destination.window != nil, destination.field != nil else {
            model.pasteBehavior = .copyOnly
            model.status = "Copied. Press ⌘V in the app where you want it."
            return
        }
        if EditDestination.terminalBundleIDs.contains(destination.app.bundleIdentifier ?? "")
            || TextInserter.isRemoteDesktop(bundleID: destination.app.bundleIdentifier) {
            model.pasteBehavior = .copyOnly
            model.status = "Copied. Paste in the terminal or remote app when you are ready."
            return
        }
        model.pasteBehavior = .pasting
        panel?.orderOut(nil)
        let generation = operation
        destination.app.activate(options: [])
        waitForTarget(destination, until: Date().addingTimeInterval(1.0), generation: generation) { [weak self] active in
            guard let self, self.operation == generation else { return }
            guard active else { self.retainCopy("The previous app did not come forward. Your item is still in History."); return }
            self.validate(destination) { [weak self] valid in
                guard let self, self.operation == generation else { return }
                guard valid, !self.isBusy(), NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.app.processIdentifier,
                      inserter.pasteCurrentClipboard(expectedChangeCount: writtenCount) else {
                    self.retainCopy("The clipboard or destination changed. Choose Copy, then paste where you want it.")
                    return
                }
                self.close()
            }
        }
    }

    private func retainCopy(_ message: String) {
        // A failed destination check is final for this presentation. Repeated
        // clicks must copy, not hide/reopen while retrying the same stale field.
        model.pasteBehavior = .copyOnly
        target = nil
        model.status = message
        panel?.makeKeyAndOrderFront(nil)
    }

    private func waitForTarget(_ destination: Destination, until deadline: Date, generation: UInt64,
                               done: @escaping (Bool) -> Void) {
        guard operation == generation else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.app.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { done(true) }
        } else if Date() >= deadline { done(false) }
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.waitForTarget(destination, until: deadline, generation: generation, done: done)
            }
        }
    }

    private func validate(_ destination: Destination, done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(destination.app.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let window = Self.element(app, kAXFocusedWindowAttribute)
            let field = Self.element(app, kAXFocusedUIElementAttribute)
            let title = window.flatMap { Self.string($0, kAXTitleAttribute) }
            let sameWindow = destination.window.flatMap { before in window.map { CFEqual(before, $0) } } ?? false
            let sameField = destination.field.map { before in field.map { CFEqual(before, $0) } ?? false } ?? false
            let sameTitle = destination.title == nil || title == destination.title
            let valid = sameWindow && sameField && sameTitle && !IsSecureEventInputEnabled()
            DispatchQueue.main.async { done(valid) }
        }
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.1)
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    deinit {
        monitor.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
