// Claude · 2026-07-26 · Session: ec24b5ef-be6a-4c4b-be38-a3b84ca63074
//
// Help window. Content comes from [HelpContent.swift]; this file is chrome and layout only.
//
// Rewritten 2026-07-26 because the previous version's CONTENT had gone stale to the point of
// being misleading: 8 documented false claims, including punctuation modes and a "Max
// Recordings" control that no longer exist, and no mention of Parakeet, the default engine.
// See build/26-07-26-help-audit/AUDIT.ai.md. The rewrite also adds what a 14-topic document
// needs and had none of: topic navigation, ⌘F, links that act, and facts read from the running
// app instead of typed into prose.
//
// CORRECTION (adversarial review, same day): the audit ALSO claimed the old window clipped its
// last third and could not reflow. That was wrong, and the retraction is recorded here because
// it is an easy mistake to repeat. The old code did compute its document height from an
// unconstrained `sizeToFit()`, but `NSTextView` defaults to `isVerticallyResizable = true` with
// `maxSize.height = 10_000_000`, so AppKit re-grew the document to fit on the first layout pass.
// Measured on the old code (build/26-07-26-help-audit/verify/verify-old-help.swift): document
// 992pt vs needed 992pt, deficit 0.0, tail text reachable, and it reflowed 900pt -> 380pt fine.
// The original probe had measured the pre-layout frame (672pt) against the post-layout
// requirement. Lesson: never measure an AppKit view before it has been laid out in a window.
//
// The layout here is still the canonical recipe (width-tracking container, scroll view owns
// scrolling) — it is just not a bug fix.

import AppKit

class HelpController: NSWindowController {
    private static var shared: HelpController?

    private var topics: [HelpTopic] = []
    private var topicList: NSTableView!
    private var contentTextView: NSTextView!

    static func show() {
        if shared == nil {
            shared = HelpController()
            // Hide the dock icon again when the Help window closes (matches Settings).
            if let window = shared?.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in NSApp.hideDockIconIfNoWindows() }
            }
        } else {
            // Facts (current hotkey, engine, whether recordings are saving) may have changed
            // in Settings since the window was built. Re-render rather than show stale text.
            shared?.reloadContent()
        }
        // Accessory (menu-bar) apps can't bring a window to the front without first switching to a
        // regular activation policy — the Settings window does this; Help was missing it, so clicking
        // Help appeared to do nothing.
        NSApp.showDockIconIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    /// Sidebar width. Wide enough for "When Something Goes Wrong" without truncation
    /// (measured: it truncates at 190).
    private static let sidebarWidth: CGFloat = 218
    private static let defaultSize = NSSize(width: 760, height: 620)

    // Build the window in the designated initializer (like SettingsWindowController) instead of a
    // lazy loadWindow() override. The lazy path left the window unbuilt, so clicking Help did
    // nothing even though the menu action fired.
    convenience init() {
        // Use a plain NSWindow, not NSPanel: NSPanel defaults hidesOnDeactivate=true, so in an
        // accessory (menu-bar) app it hides itself the moment activation wobbles — which is why
        // clicking Help did nothing. SettingsWindowController uses NSWindow and works.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: HelpController.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "speakfree Help"
        window.minSize = NSSize(width: 560, height: 380)
        // A reused shared controller must NOT release its window on close, or the next show()
        // would reference a freed window and silently fail.
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        buildContentView(in: window)
        // Remember where the user put it, and how big they made it. Must come after the
        // content view exists so the restored frame is applied to a laid-out window.
        window.setFrameAutosaveName("SpeakFreeHelpWindow")
    }

    // MARK: - View construction

    private func buildContentView(in window: NSWindow) {
        topics = HelpContent.topics(HelpFacts.live())

        let bounds = window.contentView!.bounds
        let split = NSSplitView(frame: bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.delegate = self

        // NSSplitView divides by FRAME, and an arranged subview added with a zero frame stays
        // at zero: setPosition() alone left the sidebar 0pt wide (measured 0.0 x 660.0) and the
        // window rendered as content-only. Seed both panes with real frames first.
        let sidebar = makeSidebar()
        let content = makeContentPane()
        let dividerWidth = split.dividerThickness
        sidebar.frame = NSRect(x: 0, y: 0,
                               width: HelpController.sidebarWidth, height: bounds.height)
        content.frame = NSRect(x: HelpController.sidebarWidth + dividerWidth, y: 0,
                               width: bounds.width - HelpController.sidebarWidth - dividerWidth,
                               height: bounds.height)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(content)

        window.contentView!.addSubview(split)
        split.adjustSubviews()
        split.setPosition(HelpController.sidebarWidth, ofDividerAt: 0)

        topicList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        render(topicIndex: 0)
    }

    private func makeSidebar() -> NSView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        topicList = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        // Keep the sidebar from being dragged away entirely or stretched into the content.
        scroll.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makeContentPane() -> NSView {
        // A width-tracking text container inside a scroll view: the text view never carries an
        // authoritative height of its own, so there is no build-time measurement to get stuck
        // with, and the text reflows when the window is resized.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: NSSize(width: 480, height: 10)))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        // ⌘F. Two lines the previous version never had, on a window full of prose.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        contentTextView = textView

        scroll.documentView = textView
        return scroll
    }

    // MARK: - Rendering

    /// Re-snapshot live facts and redraw. Called when Help is reopened.
    private func reloadContent() {
        let selected = topicList.selectedRow
        topics = HelpContent.topics(HelpFacts.live())
        topicList.reloadData()
        let index = (0..<topics.count).contains(selected) ? selected : 0
        topicList.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        render(topicIndex: index)
    }

    private func render(topicIndex: Int) {
        guard topics.indices.contains(topicIndex) else { return }
        contentTextView.textStorage?.setAttributedString(
            HelpController.attributedBody(for: topics[topicIndex]))
        contentTextView.scroll(NSPoint(x: 0, y: 0))
    }

    /// Renders one topic. Internal so tests can measure the real string.
    static func attributedBody(for topic: HelpTopic) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 10
        result.append(NSAttributedString(string: "\(topic.title)\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 19),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titleParagraph,
        ]))

        let body = NSMutableParagraphStyle()
        body.paragraphSpacing = 10
        body.lineSpacing = 1.5

        let hanging = NSMutableParagraphStyle()
        hanging.paragraphSpacing = 6
        hanging.lineSpacing = 1.5
        hanging.headIndent = 16
        hanging.firstLineHeadIndent = 4

        for block in topic.blocks {
            switch block {
            case .paragraph(let text):
                result.append(NSAttributedString(string: "\(text)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: body,
                ]))

            case .row(let label, let detail):
                result.append(NSAttributedString(string: label, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: hanging,
                ]))
                result.append(NSAttributedString(string: " \u{2014} \(detail)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: hanging,
                ]))

            case .bullet(let text):
                result.append(NSAttributedString(string: "\u{2022}  \(text)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: hanging,
                ]))

            case .action(let label, let action):
                result.append(NSAttributedString(string: "\(label)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.linkColor,
                    .link: action.url,
                    .paragraphStyle: hanging,
                ]))

            case .spacer:
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 6),
                ]))
            }
        }

        return result
    }

    // MARK: - Link actions

    /// Performs a help link's action. Internal so tests can assert every declared action is
    /// routed — an unrouted link is a dead end the user cannot tell from a broken app.
    @discardableResult
    static func perform(_ action: HelpAction) -> Bool {
        switch action {
        case .openSettings:
            guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return false }
            delegate.showSettings()

        case .openLogsFolder:
            let logs = Config.configDir.appendingPathComponent("logs")
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            NSWorkspace.shared.open(logs)

        case .openRecordingsFolder:
            let dir = RecordingStore.recordingsDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([dir])

        case .openVocabularyFile:
            let url = Config.vocabularyFile
            try? FileManager.default.createDirectory(at: Config.configDir,
                                                     withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                // Single words, not "word or phrase": only single-word entries are used to
                // correct a transcription (GlossaryCorrector skips anything containing a space).
                // The old template invited phrases and then silently ignored them.
                let template = "# Vocabulary for speakfree\n"
                    + "# One word per line — names, jargon, acronyms.\n"
                    + "# Multi-word phrases are only passed to Whisper as a hint, never used\n"
                    + "# to correct a transcription.\n"
                    + "# Lines starting with # are ignored.\n"
                try? template.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(url)

        case .openMicrophonePrivacy:
            Permissions.openMicrophoneSettings()

        case .openAccessibilityPrivacy:
            Permissions.openAccessibilitySettings()

        case .openRepo:
            if let url = URL(string: "https://github.com/definitelyreal/speakfree") {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }
}

// MARK: - Split behavior

extension HelpController: NSSplitViewDelegate {

    /// Resizing the window grows the CONTENT pane, not the topic list.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== splitView.arrangedSubviews.first
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 150)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, 280)
    }
}

// MARK: - Sidebar data

extension HelpController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { topics.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard topics.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HelpTopicCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let created = NSTableCellView()
                created.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                created.addSubview(label)
                created.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: created.centerYAnchor),
                ])
                return created
            }()
        cell.textField?.stringValue = topics[row].title
        cell.textField?.font = NSFont.systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        render(topicIndex: topicList.selectedRow)
    }
}

// MARK: - Link routing

extension HelpController: NSTextViewDelegate {

    func textView(_ textView: NSTextView,
                  clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        let url: URL?
        switch link {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        // Returning FALSE hands the URL back to NSTextView, which asks NSWorkspace to open it —
        // and nothing is registered for speakfree-help://, so the user gets a system "no
        // application can open this" alert. Always claim the click.
        guard let url else { return true }
        if let action = HelpAction.from(url: url) {
            HelpController.perform(action)
            return true
        }
        // Anything else (a plain https link) opens in the browser.
        NSWorkspace.shared.open(url)
        return true
    }
}
