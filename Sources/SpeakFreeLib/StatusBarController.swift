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

    var reprocessHandler: ((URL) -> Void)?
    private var crashRecoveryURL: URL?
    private var crashRecoveryHandler: ((URL) -> Void)?

    func showCrashRecovery(url: URL, handler: @escaping (URL) -> Void) {
        crashRecoveryURL = url
        crashRecoveryHandler = handler
        buildMenu()
    }

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
    }

    // Called before the menu is displayed — rebuild items so state changes are reflected
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(menu)
    }

    @objc private func copyLastTranscription() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let text = delegate.lastTranscription else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    func buildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menuItemTargets = []
        menu.removeAllItems()
        buildMenuItems(into: menu)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildMenuItems(into menu: NSMenu) {

        let titleItem = NSMenuItem(title: SpeakFree.menuTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Microphone selector — FIRST section (Michael, 2026-07-14): the AirPods link
        // degrades unpredictably, and switching the capture device must be one click.
        // Radio list: System Default + every input device; checkmark = active pin.
        let micHeader = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micHeader.isEnabled = false
        menu.addItem(micHeader)

        // Cache-only reads: menu builds happen on the main thread on every state flip,
        // and live CoreAudio reads here are what wedged the app on 2026-07-15.
        let pinnedUID = (NSApplication.shared.delegate as? AppDelegate)?.currentInputDeviceUID()
        let defaultName = AudioDeviceCatalog.cachedDefaultInput?.name ?? "System Default"
        let defaultTarget = MenuItemTarget {
            (NSApplication.shared.delegate as? AppDelegate)?.selectInputDevice(uid: nil)
        }
        menuItemTargets.append(defaultTarget)
        let defaultItem = NSMenuItem(title: "System Default (\(defaultName))",
                                     action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        defaultItem.target = defaultTarget
        defaultItem.state = pinnedUID == nil ? .on : .off
        menu.addItem(defaultItem)

        for device in AudioDeviceCatalog.cachedInputDevices {
            let uid = device.uid
            let target = MenuItemTarget {
                (NSApplication.shared.delegate as? AppDelegate)?.selectInputDevice(uid: uid)
            }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: device.name,
                                  action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = pinnedUID == uid ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

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

        // Recent Dictations submenu — populated LAZILY (M1). buildMenu() runs on every state flip;
        // reading a transcript sidecar per recording here opened thousands of files per build on a
        // large corpus. The submenu's own delegate reads sidecars only when it's actually opened,
        // and only for the newest N (see populateRecentMenu).
        let recentParent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        // Placeholder so the parent shows its submenu-expand arrow before first population; replaced
        // in menuNeedsUpdate.
        recentMenu.addItem(NSMenuItem(title: "…", action: nil, keyEquivalent: ""))
        let delegate = RecentMenuDelegate { [weak self] submenu in
            self?.populateRecentMenu(submenu)
        }
        recentMenu.delegate = delegate
        recentMenuDelegate = delegate
        recentParent.submenu = recentMenu
        menu.addItem(recentParent)

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
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            let updateTarget = MenuItemTarget {
                delegate.updaterController.checkForUpdates(nil)
            }
            menuItemTargets.append(updateTarget)
            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            updateItem.target = updateTarget
            menu.addItem(updateItem)
        }

        let helpTarget = MenuItemTarget { HelpController.show() }
        menuItemTargets.append(helpTarget)
        let helpItem = NSMenuItem(title: "Help", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        helpItem.target = helpTarget
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// M1: build the "Recent Dictations" submenu on demand (when it opens), reading transcript
    /// sidecars only for the newest 15 recordings — never for the whole corpus, and never on a plain
    /// `buildMenu()`.
    private func populateRecentMenu(_ menu: NSMenu) {
        recentMenuTargets = []
        menu.removeAllItems()

        // Crash recovery at top if pending
        if let recoveryURL = crashRecoveryURL, let recoveryHandler = crashRecoveryHandler {
            let target = MenuItemTarget { [weak self] in
                self?.crashRecoveryURL = nil
                self?.crashRecoveryHandler = nil
                recoveryHandler(recoveryURL)
            }
            recentMenuTargets.append(target)
            let recoveryItem = NSMenuItem(title: "⚠️ Recover Unsaved Recording", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            recoveryItem.target = target
            menu.addItem(recoveryItem)
            menu.addItem(NSMenuItem.separator())
        }

        let recordings = RecordingStore.listRecordings(limit: 15)

        if recordings.isEmpty {
            if crashRecoveryURL == nil {
                let emptyItem = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            }
            return
        }

        for (index, recording) in recordings.enumerated() {
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
            if index == 0 && recordings.count > 1 {
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
    }

    @objc private func reloadConfiguration() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig()
    }

    private func updateIcon() {
        stopAnimation()

        switch state {
        case .idle:
            setIcon(StatusBarController.drawLogo(active: false))
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
        case .noModel:
            setIcon(StatusBarController.drawNoModelIcon())
        case .setupFailed:
            setIcon(StatusBarController.drawErrorIcon())
        }
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
