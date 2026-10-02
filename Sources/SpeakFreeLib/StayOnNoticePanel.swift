// ai-suggestion:unverified · 2026-09-24
import AppKit

/// The words for each Stay-on notice. Pure, so the copy is tested and never says
/// "MacBook" unless macOS named the device that way.
public enum StayOnNoticeCopy {
    public struct Text: Equatable {
        public var message: String
        /// Title of the split button's main part (starts the default duration), if any.
        public var stayOnButton: String?
        public var undo: Bool = false
        /// Warnings are advice: neutral icon, never a warning triangle, never red.
        public var symbol: String
    }

    public static func text(for notice: StayOnNotice) -> Text {
        switch notice {
        case .connected(_, let name, let using, _, _):
            let short = HeadsetLabel.short(name)
            return Text(message: "\(short) connected. Still using \(using).",
                        stayOnButton: "Stay on \(short) \(StayOnDuration.standard.phrase)", symbol: "headphones")
        case .switched(_, let name, _):
            let short = HeadsetLabel.short(name)
            return Text(message: "Hard to hear you here, so speakfree switched to \(short) \(StayOnDuration.standard.phrase). Your last dictation may be incomplete.",
                        stayOnButton: nil, undo: true, symbol: "waveform")
        case .offer(_, let name):
            let short = HeadsetLabel.short(name)
            return Text(message: "Hard to hear you here. Switch to \(short)? Music on \(short) will sound like a phone call.",
                        stayOnButton: "Stay on \(short) \(StayOnDuration.standard.phrase)", symbol: "waveform")
        case .advise:
            return Text(message: "Hard to hear you here. Your last dictation may be incomplete. A headset or a closer mic will help.",
                        stayOnButton: nil, symbol: "waveform")
        case .endedAfterAutomaticSwitch(_, let name):
            let short = HeadsetLabel.short(name)
            return Text(message: "Stay on \(short) ended.",
                        stayOnButton: "Stay on \(short) \(StayOnDuration.standard.phrase)", symbol: "timer")
        case .fellBack(_, let name, let using, let reason):
            let short = HeadsetLabel.short(name)
            switch reason {
            case .staticNoise:
                return Text(message: "\(short) sounded like static. Switched to \(using).", symbol: "waveform")
            case .stopped:
                return Text(message: "\(short) stopped sending audio. Switched to \(using).", symbol: "waveform")
            case .notReady:
                return Text(message: "\(short) wasn't ready. Using \(using).", symbol: "waveform")
            }
        }
    }

    /// Seconds on screen before fading (paused while the pointer is over it).
    public static func seconds(for notice: StayOnNotice) -> TimeInterval {
        if case .connected(_, _, _, let style, _) = notice { return style == .compact ? 4 : 8 }
        return 12
    }

    public static func isCompact(_ notice: StayOnNotice) -> Bool {
        if case .connected(_, _, _, let style, _) = notice { return style == .compact }
        return false
    }
}

private final class NoticePanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A small floating notice under the menu-bar icon. A non-activating panel that can
/// never become key, so clicking it never takes keyboard focus from the app being
/// dictated into. Clicks in its first 0.3 s are ignored (a click meant for the window
/// behind it), and its fade pauses while the pointer is over it.
final class StayOnNoticePanel {
    weak var statusItem: NSStatusItem?
    var startStayOn: ((String, String, StayOnDuration) -> Void)?
    var undo: ((String, Date) -> Void)?
    var dismissForever: ((String) -> Void)?

    private var panel: NoticePanelWindow?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuOpen = false

    init() {
        // A duration menu opened from the notice moves the pointer off the panel; do not
        // let the panel fade out from under its own open menu.
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel != nil else { return }
            self.menuOpen = true
            self.hideWork?.cancel()
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.menuOpen else { return }
            self.menuOpen = false
            if self.panel != nil { self.scheduleHide(after: 3) }
        })
    }
    private var hideWork: DispatchWorkItem?
    private var shownAt = Date.distantPast
    private var targets: [MenuItemTarget] = []
    private let width: CGFloat = 340

    func show(_ notice: StayOnNotice) {
        close(animated: false)
        let copy = StayOnNoticeCopy.text(for: notice)
        let compact = StayOnNoticeCopy.isCompact(notice)
        targets = []

        let fontSize: CGFloat = compact ? 11 : 13
        let icon = NSImageView(image: NSImage(systemSymbolName: copy.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: fontSize + 2, weight: .regular)
        icon.contentTintColor = copy.symbol == "timer" ? .systemOrange : .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: copy.message)
        label.font = compact ? .systemFont(ofSize: fontSize) : .boldSystemFont(ofSize: fontSize)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = width - 90
        let closeButton = button("\u{00D7}") { [weak self] in self?.close(animated: true) }
        closeButton.isBordered = false
        closeButton.setAccessibilityLabel("Close")
        let top = NSStackView(views: [icon, label, closeButton])
        top.alignment = .top
        top.spacing = 8

        var buttons: [NSView] = []
        let uidAndName: (String, String)? = {
            switch notice {
            case .connected(let u, let n, _, _, _), .switched(let u, let n, _), .offer(let u, let n),
                 .endedAfterAutomaticSwitch(let u, let n): return (u, n)
            case .advise, .fellBack: return nil
            }
        }()
        if case .switched(let uid, _, let startedAt) = notice {
            buttons.append(button("Undo") { [weak self] in self?.undo?(uid, startedAt); self?.close(animated: true) })
        }
        if let (uid, name) = uidAndName {
            let menu = durationMenu(uid: uid, name: name, checked: .standard)
            if let title = copy.stayOnButton {
                let split = NSComboButton(title: title, menu: menu, target: nil, action: nil)
                let t = MenuItemTarget { [weak self] in
                    guard let self, self.acceptsClicks else { return }
                    self.startStayOn?(uid, name, .standard); self.close(animated: true)
                }
                targets.append(t)
                split.target = t; split.action = #selector(MenuItemTarget.invoke)
                split.controlSize = compact ? .small : .regular
                buttons.append(split)
            } else if copy.undo {
                let pull = NSPopUpButton(frame: .zero, pullsDown: true)
                pull.menu = menu
                pull.menu?.insertItem(withTitle: "Change duration", action: nil, keyEquivalent: "", at: 0)
                buttons.append(pull)
            }
        }
        if case .connected(let uid, _, _, _, true) = notice {
            let never = button("Don't show again") { [weak self] in self?.dismissForever?(uid); self?.close(animated: true) }
            never.isBordered = false
            never.contentTintColor = .secondaryLabelColor
            never.font = .systemFont(ofSize: 11)
            buttons.append(never)
        }

        let stack = NSStackView(views: [top] + (buttons.isEmpty ? [] : [NSStackView(views: buttons)]))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 10)

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let hover = HoverView()
        hover.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { self.hideWork?.cancel() } else if !self.menuOpen { self.scheduleHide(after: 3) }
        }
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        hover.addSubview(effect)
        effect.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: hover.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: hover.trailingAnchor),
            effect.topAnchor.constraint(equalTo: hover.topAnchor),
            effect.bottomAnchor.constraint(equalTo: hover.bottomAnchor),
        ])

        let panel = NoticePanelWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = hover
        panel.setAccessibilityLabel(copy.message)
        hover.layoutSubtreeIfNeeded()
        let size = hover.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(size.height, 44)))
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.alphaValue = compact ? 0.9 : 1
        panel.orderFrontRegardless()
        self.panel = panel
        shownAt = Date()
        scheduleHide(after: StayOnNoticeCopy.seconds(for: notice))
    }

    private var acceptsClicks: Bool { Date().timeIntervalSince(shownAt) >= 0.3 }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let t = MenuItemTarget { [weak self] in
            guard let self, self.acceptsClicks else { return }
            action()
        }
        targets.append(t)
        return NSButton(title: title, target: t, action: #selector(MenuItemTarget.invoke))
    }

    private func durationMenu(uid: String, name: String, checked: StayOnDuration) -> NSMenu {
        let menu = NSMenu()
        for (i, group) in StayOnDuration.menuGroups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for d in group {
                let t = MenuItemTarget { [weak self] in self?.startStayOn?(uid, name, d); self?.close(animated: true) }
                targets.append(t)
                let item = NSMenuItem(title: d.menuTitle, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                item.target = t
                item.state = d == checked ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Under the menu-bar icon; top right of the screen when the icon is hidden (notch,
    /// menu-bar managers).
    private func origin(for size: NSSize) -> NSPoint {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let frame = statusItem?.button?.window?.frame, frame.width > 0, visible.insetBy(dx: -1, dy: -40).intersects(frame) {
            let x = min(max(frame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            return NSPoint(x: x, y: frame.minY - size.height - 6)
        }
        return NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func close(animated: Bool) {
        hideWork?.cancel(); hideWork = nil
        guard let panel else { return }
        self.panel = nil
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
    }
}
