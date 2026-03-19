import AppKit

class MenuItemTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var animationFrames: [NSImage] = []
    private var downloadProgress: String?
    private var copiedFeedback = false
    private var menuItemTargets: [MenuItemTarget] = []

    var reprocessHandler: ((URL) -> Void)?
    private var crashRecoveryURL: URL?
    private var crashRecoveryHandler: ((URL) -> Void)?

    // Captured before the menu opens — so reprocess can type without any delay
    var elementBeforeMenuOpen: AXUIElement?

    func showCrashRecovery(url: URL, handler: @escaping (URL) -> Void) {
        crashRecoveryURL = url
        crashRecoveryHandler = handler
        buildMenu()
    }

    enum State {
        case idle
        case recording
        case transcribing
        case downloading
        case waitingForPermission
        case copiedToClipboard
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

    // Called by AppKit before the menu appears — capture focus before menu steals it
    func menuWillOpen(_ menu: NSMenu) {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef) == .success,
           let element = elementRef {
            elementBeforeMenuOpen = (element as! AXUIElement)
        } else {
            elementBeforeMenuOpen = nil
        }
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

    func buildMenu() {
        menuItemTargets = []

        let config = Config.load()
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "speakfree v\(OpenWispr.version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        if let progress = downloadProgress {
            let dlItem = NSMenuItem(title: progress, action: nil, keyEquivalent: "")
            dlItem.isEnabled = false
            menu.addItem(dlItem)
            menu.addItem(NSMenuItem.separator())
        }

        let stateText: String
        switch state {
        case .idle: stateText = "Ready"
        case .recording: stateText = "Recording..."
        case .transcribing: stateText = "Transcribing..."
        case .downloading: stateText = "Downloading model..."
        case .waitingForPermission: stateText = "⚠️ Grant Accessibility Permission →"
        case .copiedToClipboard: stateText = "Copied to clipboard"
        }
        if case .waitingForPermission = state {
            let target = MenuItemTarget {
                // Clear the stale TCC entry then re-prompt
                let task = Process()
                task.launchPath = "/usr/bin/tccutil"
                task.arguments = ["reset", "Accessibility", "com.definitelyreal.speakfree"]
                try? task.run()
                task.waitUntilExit()
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
                AXIsProcessTrustedWithOptions(options)
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

        // Recent Dictations submenu — crash recovery, last dictation, then older recordings
        let recentParent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()

        // Crash recovery at top if pending
        if let recoveryURL = crashRecoveryURL, let recoveryHandler = crashRecoveryHandler {
            let target = MenuItemTarget { [weak self] in
                self?.crashRecoveryURL = nil
                self?.crashRecoveryHandler = nil
                recoveryHandler(recoveryURL)
            }
            menuItemTargets.append(target)
            let recoveryItem = NSMenuItem(title: "⚠️ Recover Unsaved Recording", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            recoveryItem.target = target
            recentMenu.addItem(recoveryItem)
            recentMenu.addItem(NSMenuItem.separator())
        }

        let recordings = RecordingStore.listRecordings()

        if recordings.isEmpty && crashRecoveryURL == nil {
            let emptyItem = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
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
                menuItemTargets.append(target)
                let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                item.target = target
                recentMenu.addItem(item)
                // Separator after the first (most recent) recording
                if index == 0 && recordings.count > 1 {
                    recentMenu.addItem(NSMenuItem.separator())
                }
            }
        }

        recentParent.submenu = recentMenu
        menu.addItem(recentParent)

        menu.addItem(NSMenuItem.separator())

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        // Hotkey picker
        let hotkeyParent = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        let hotkeyOptions: [(String, UInt16)] = [
            ("🌐  Globe / fn",       63),
            ("⌘  Left Command",     55),
            ("⌘  Right Command",    54),
            ("⌥  Left Option",      58),
            ("⌥  Right Option",     61),
            ("⌃  Left Control",     59),
        ]
        for (label, keyCode) in hotkeyOptions {
            let target = MenuItemTarget { [weak self] in self?.setHotkey(keyCode: keyCode) }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = config.hotkey.keyCode == keyCode ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyParent.submenu = hotkeyMenu
        settingsMenu.addItem(hotkeyParent)
        settingsMenu.addItem(NSMenuItem.separator())

        // Model
        let modelParent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for size in ["tiny.en", "base.en", "small.en", "medium.en", "large"] {
            let target = MenuItemTarget { [weak self] in self?.setModel(size) }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: size, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = config.modelSize == size ? .on : .off
            modelMenu.addItem(item)
        }
        modelParent.submenu = modelMenu
        settingsMenu.addItem(modelParent)

        // Punctuation
        let punctParent = NSMenuItem(title: "Punctuation", action: nil, keyEquivalent: "")
        let punctMenu = NSMenu()
        let punctOptions: [(String, PunctuationMode)] = [
            ("Off", .off),
            ("Spoken words", .spoken),
            ("Hybrid (auto + spoken)", .hybrid),
        ]
        let currentPunct = config.spokenPunctuation ?? .off
        for (label, mode) in punctOptions {
            let target = MenuItemTarget { [weak self] in self?.setPunctuation(mode) }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = currentPunct == mode ? .on : .off
            punctMenu.addItem(item)
        }
        punctParent.submenu = punctMenu
        settingsMenu.addItem(punctParent)

        // Key Mode
        let keyModeParent = NSMenuItem(title: "Key Mode", action: nil, keyEquivalent: "")
        let keyModeMenu = NSMenu()
        let isToggle = config.toggleMode?.value == true
        for (label, isToggleMode) in [("Hold fn", false), ("Toggle fn", true)] {
            let target = MenuItemTarget { [weak self] in self?.setToggleMode(isToggleMode) }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = isToggle == isToggleMode ? .on : .off
            keyModeMenu.addItem(item)
        }
        keyModeParent.submenu = keyModeMenu
        settingsMenu.addItem(keyModeParent)

        // Max recordings
        let recParent = NSMenuItem(title: "Max Recordings", action: nil, keyEquivalent: "")
        let recMenu = NSMenu()
        let recOptions = [0, 10, 20, 30, 50, 100]
        let currentMax = config.maxRecordings ?? 0
        for count in recOptions {
            let label = count == 0 ? "Off" : "\(count)"
            let target = MenuItemTarget { [weak self] in self?.setMaxRecordings(count) }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = currentMax == count ? .on : .off
            recMenu.addItem(item)
        }
        recParent.submenu = recMenu
        settingsMenu.addItem(recParent)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func reloadConfiguration() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig()
    }

    private func applyConfig(_ block: (inout Config) -> Void) {
        var config = Config.load()
        block(&config)
        try? config.save()
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig()
    }

    private func setHotkey(keyCode: UInt16) {
        applyConfig { $0.hotkey = HotkeyConfig(keyCode: keyCode, modifiers: []) }
    }

    private func setModel(_ size: String) {
        applyConfig { $0.modelSize = size }
    }

    private func setPunctuation(_ mode: PunctuationMode) {
        applyConfig { $0.spokenPunctuation = mode }
    }

    private func setToggleMode(_ enabled: Bool) {
        applyConfig { $0.toggleMode = FlexBool(enabled) }
    }

    private func setMaxRecordings(_ count: Int) {
        applyConfig { $0.maxRecordings = count }
    }

    private func updateIcon() {
        stopAnimation()

        switch state {
        case .idle:
            setIcon(StatusBarController.drawLogo(active: false))
        case .recording:
            startRecordingAnimation()
        case .transcribing:
            startTranscribingAnimation()
        case .downloading:
            startDownloadingAnimation()
        case .waitingForPermission:
            setIcon(StatusBarController.drawLockIcon())
        case .copiedToClipboard:
            setIcon(StatusBarController.drawCheckmarkIcon())
        }
    }

    // MARK: - Recording animation: wave

    private static let waveFrameCount = 30

    private static func prerenderWaveFrames() -> [NSImage] {
        let count = waveFrameCount
        let baseHeights: [CGFloat] = [4, 8, 12, 8, 4]
        let minScale: CGFloat = 0.3
        let phaseOffsets: [Double] = [0.0, 0.15, 0.3, 0.45, 0.6]

        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

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
            image.isTemplate = true
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

    // MARK: - Downloading animation: arrow moves down

    private func startDownloadingAnimation() {
        animationFrame = 0
        setIcon(StatusBarController.drawDownloadingFrame(0))

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % 3
            self.setIcon(StatusBarController.drawDownloadingFrame(self.animationFrame))
        }
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
                button.image?.isTemplate = true
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

    static func drawDownloadingFrame(_ frame: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX

            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: centerX - 5, y: 3))
            basePath.line(to: NSPoint(x: centerX + 5, y: 3))
            basePath.lineWidth = 1.5
            basePath.lineCapStyle = .round
            basePath.stroke()

            let arrowY: CGFloat = 14 - CGFloat(frame) * 2
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: centerX, y: arrowY))
            arrowPath.line(to: NSPoint(x: centerX, y: 6))
            arrowPath.lineWidth = 1.5
            arrowPath.lineCapStyle = .round
            arrowPath.stroke()

            let headPath = NSBezierPath()
            headPath.move(to: NSPoint(x: centerX - 3, y: 9))
            headPath.line(to: NSPoint(x: centerX, y: 5))
            headPath.line(to: NSPoint(x: centerX + 3, y: 9))
            headPath.lineWidth = 1.5
            headPath.lineCapStyle = .round
            headPath.lineJoinStyle = .round
            headPath.stroke()

            return true
        }
        image.isTemplate = true
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
