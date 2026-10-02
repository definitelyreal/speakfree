// Claude · 2026-09-24 · Edit Mode V1
// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit

extension NSAttributedString.Key {
    /// The id of the paragraph (EditSegment) a character belongs to (identity by attribute,
    /// never by stored range).
    static let editSegmentID = NSAttributedString.Key("com.speakfree.edit.segment")
    /// Marks a character range as a cleanup change (value: the SpanEdit's reason).
    static let editChangeMark = NSAttributedString.Key("com.speakfree.edit.change")
}

/// The edit window's text view. Owns only key routing and clipboard shape; every decision goes
/// through the controller and the core.
final class EditTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onShowVersions: (() -> Void)?
    /// Paragraph state dots in the left margin: (glyph-range start, color).
    var marginDots: () -> [(characterIndex: Int, color: NSColor, tooltip: String?)] = { [] }
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !hasMarkedText() {
            if event.modifierFlags.contains(.shift) {
                // Shift+Return: a line break inside this paragraph (U+2028), never a new paragraph.
                insertText(String(EditDocumentReconciler.lineBreak), replacementRange: selectedRange())
                return
            }
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                onReturn?()
                return
            }
        }
        if event.keyCode == 53 && !hasMarkedText() {   // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Belt and braces for Return/Esc arriving as commands (IME-safe: only without marked text).
        if !hasMarkedText() {
            if selector == #selector(insertNewline(_:)) { onReturn?(); return }
            if selector == #selector(cancelOperation(_:)) { onEscape?(); return }
            if selector == #selector(insertNewlineIgnoringFieldEditor(_:))
                || selector == #selector(insertLineBreak(_:)) {
                insertText(String(EditDocumentReconciler.lineBreak), replacementRange: selectedRange())
                return
            }
        }
        super.doCommand(by: selector)
    }

    enum EditingShortcut: Equatable { case copy, cut, paste, selectAll, undo, redo, versions }

    static func editingShortcut(key: String, modifiers: NSEvent.ModifierFlags) -> EditingShortcut? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift, .function])
        if key.lowercased() == "z", modifiers == [.command, .shift] { return .redo }
        guard modifiers == .command else { return nil }
        switch key.lowercased() {
        case "c": return .copy
        case "x": return .cut
        case "v": return .paste
        case "a": return .selectAll
        case "z": return .undo
        case "i": return .versions
        default: return nil
        }
    }

    /// Standard editing shortcuts work even though the app's minimal menu has no Edit submenu.
    /// Match exact chords: Command-Shift-V belongs to History, not this view's plain paste.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers,
              let shortcut = Self.editingShortcut(key: key, modifiers: event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }
        switch shortcut {
        case .copy: copy(nil)
        case .cut: cut(nil)
        case .paste: paste(nil)
        case .selectAll: selectAll(nil)
        case .undo: undoManager?.undo()
        case .redo: undoManager?.redo()
        case .versions: onShowVersions?()
        }
        return true
    }

    /// A copy puts a blank line at each paragraph boundary (the window stores one "\n").
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let selected = (string as NSString).substring(with: range)
        let pb = NSPasteboard.general
        UserPasteRestoreGate.shared.writeOutsideBorrow {
            pb.clearContents()
            pb.setString(EditDocumentReconciler.exportText(selected), forType: .string)
        }
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, isEditable else { return }
        copy(sender)
        insertText("", replacementRange: range)
    }

    /// Pasted newlines become in-paragraph line breaks: a paste never creates paragraphs.
    override func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        insertText(EditDocumentReconciler.displayText(s), replacementRange: selectedRange())
    }

    /// Dropped text follows the paste rule too (plain text only, newlines become line breaks).
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let s = pboard.string(forType: .string) else { return false }
        insertText(EditDocumentReconciler.displayText(s), replacementRange: selectedRange())
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        return contextMenuProvider?(index) ?? super.menu(for: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let length = (string as NSString).length
        for dot in marginDots() {
            guard length > 0 else { break }
            let ci = min(max(0, dot.characterIndex), length - 1)
            let glyph = lm.glyphIndexForCharacter(at: ci)
            var lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            lineRect.origin.y += textContainerOrigin.y
            _ = tc
            let d: CGFloat = 6
            let r = NSRect(x: 7, y: lineRect.minY + (min(lineRect.height, 20) - d) / 2, width: d, height: d)
            dot.color.setFill()
            NSBezierPath(ovalIn: r).fill()
        }
    }
}

/// Edit sessions hide with orderOut when committing or retaining their controller. That path
/// does not emit willClose, so it must participate in the Dock lifecycle explicitly.
private final class EditSessionWindow: NSWindow {
    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        super.orderOut(sender)
        if wasVisible { NSApp.hideDockIconIfNoWindows() }
    }
}

/// The Edit Mode window: header (recording state, destination, Changes, options), the text,
/// an on-demand comparison panel, and a footer that always says whether text leaves the Mac.
@MainActor
final class EditWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {

    let core: EditSessionCore
    private let placementAutosaveName: String?
    let window: NSWindow
    let textView: EditTextView
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let changesButton = NSButton(title: "Changes", target: nil, action: nil)
    private let optionsButton = NSButton(title: "Options", target: nil, action: nil)
    private let footerStatus = NSTextField(labelWithString: "")
    private let footerHint = NSTextField(wrappingLabelWithString: "")
    let comparePanel = NSStackView()

    /// Actions routed to the controller.
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onOptions: ((NSView) -> Void)?
    var onChanges: ((UUID, NSView) -> Void)?
    var onRetry: ((UUID) -> Void)?
    var onCompareChoose: ((String) -> Void)?
    var onCompareClose: (() -> Void)?

    private var applyingProgrammatic = false
    private var pendingRender: [EditCoreEvent] = []
    private var animations: [UUID: Date] = [:]
    private var animationTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    static let settleDuration: TimeInterval = 0.35

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var effectiveAnimation: EditAnimationStyle {
        reduceMotion ? .quiet : core.settings.animation
    }

    private let baseFont = NSFont.systemFont(ofSize: 14)
    private var baseParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.25
        p.paragraphSpacing = 10
        return p
    }
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraphStyle]
    }

    init(core: EditSessionCore, targetName: String?, placementAutosaveName: String? = "SpeakFreeEditWindow") {
        self.core = core
        self.placementAutosaveName = placementAutosaveName
        window = EditSessionWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        textView = EditTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
        super.init()
        window.title = "speakfree Edit"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 180)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        buildLayout(targetName: targetName)
        placeWindow()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitWindowToVisibleScreen() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        animationTimer?.invalidate()
    }

    // MARK: Layout

    private func buildLayout(targetName: String?) {
        guard let content = window.contentView else { return }

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetLabel.font = .systemFont(ofSize: 12)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        targetLabel.stringValue = targetName.map { "→ \($0)" } ?? "→ (no text field)"
        targetLabel.toolTip = "Return puts the text here. If this place cannot be confirmed, the text is copied and kept in this window instead."
        for b in [changesButton, optionsButton] {
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        changesButton.toolTip = "See the original, previous and current versions of this paragraph and undo single changes (⌘I)"
        changesButton.target = self
        changesButton.action = #selector(changesClicked)
        optionsButton.toolTip = "Cleanup, model, compare, animation"
        optionsButton.target = self
        optionsButton.action = #selector(optionsClicked)
        changesButton.setAccessibilityLabel("Changes and versions")
        optionsButton.setAccessibilityLabel("Edit Mode options")

        let header = NSStackView(views: [statusLabel, NSView(), targetLabel, changesButton, optionsButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        header.views[1].setContentHuggingPriority(.init(1), for: .horizontal)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = baseFont
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 10)
        textView.typingAttributes = baseAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onReturn = { [weak self] in self?.onReturn?() }
        textView.onEscape = { [weak self] in self?.onEscape?() }
        textView.onShowVersions = { [weak self] in self?.changesClicked() }
        textView.marginDots = { [weak self] in self?.marginDots() ?? [] }
        textView.contextMenuProvider = { [weak self] index in self?.contextMenu(at: index) }
        textView.setAccessibilityLabel("Edit Mode text")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        comparePanel.orientation = .vertical
        comparePanel.alignment = .leading
        comparePanel.spacing = 6
        comparePanel.isHidden = true

        footerStatus.font = .systemFont(ofSize: 11)
        footerStatus.textColor = .secondaryLabelColor
        footerStatus.lineBreakMode = .byTruncatingTail
        footerHint.font = .systemFont(ofSize: 11)
        footerHint.textColor = .secondaryLabelColor
        footerHint.maximumNumberOfLines = 3

        let stack = NSStackView(views: [header, scrollView, comparePanel, footerStatus, footerHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            comparePanel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footerStatus.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footerHint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
    }

    /// Restore the user's placement, then keep the entire window on an available display.
    private func placeWindow() {
        let restored = placementAutosaveName.map { window.setFrameUsingName($0) } ?? false
        if let placementAutosaveName { window.setFrameAutosaveName(placementAutosaveName) }
        if !restored, let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            let size = window.frame.size
            let top = vf.maxY - vf.height * 0.22
            window.setFrame(NSRect(x: vf.midX - size.width / 2, y: top - size.height,
                                   width: size.width, height: size.height), display: false)
        }
        fitWindowToVisibleScreen()
    }

    private func fitWindowToVisibleScreen() {
        guard let visibleFrame = WindowScreenPlacement.screen(for: window.frame,
                                                               visibleFrames: NSScreen.screens.map(\.visibleFrame)) else { return }
        window.minSize = NSSize(width: min(420, visibleFrame.width), height: min(180, visibleFrame.height))
        window.setFrame(WindowScreenPlacement.fit(window.frame, to: visibleFrame), display: false)
    }

    func show() {
        fitWindowToVisibleScreen()
        NSApp.showDockIconIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        refreshStatus()
    }

    // MARK: Events from the core

    func handle(_ event: EditCoreEvent) {
        // Never mutate the text while an input method is composing; retry shortly.
        if textView.hasMarkedText(), event != .status, event != .comparison {
            pendingRender.append(event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.flushPending() }
            return
        }
        switch event {
        case .appended(let id): appendParagraph(id)
        case .replaced(let id, let animate): replaceParagraph(id, animate: animate)
        case .restructured: fullRender()
        case .status: refreshStatus(); refreshStyling()
        case .comparison: renderComparison()
        case .readyToCommit: break
        }
    }

    private func flushPending() {
        guard !textView.hasMarkedText() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.flushPending() }
            return
        }
        // Typing done during the wait is reconciled FIRST, against the paragraphs the window
        // actually shows; then the waiting paragraphs are drawn.
        let events = pendingRender
        pendingRender = []
        var handEdited = Set<UUID>()
        if needsReconcile {
            needsReconcile = false
            handEdited = reconcile(excluding: events)
        }
        for event in events {
            // He typed in this paragraph while its cleanup result waited: his text already won in
            // the session, so the waiting cleanup is not drawn over it.
            if case .replaced(let id, _) = event, handEdited.contains(id) { continue }
            handle(event)
        }
    }

    /// Hand any typing the window has not reported yet to the session (Return calls this).
    func syncTypingNow() {
        guard !textView.hasMarkedText() else { return }
        if !pendingRender.isEmpty {
            flushPending()
        } else if needsReconcile {
            needsReconcile = false
            reconcile()
        }
    }

    // MARK: Rendering

    private var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }

    /// Paragraph ranges in the window, in order (split on "\n").
    private func paragraphRanges() -> [NSRange] {
        let s = textView.string as NSString
        var ranges: [NSRange] = []
        var start = 0
        let length = s.length
        if length == 0 { return displayedCountIsZero ? [] : [NSRange(location: 0, length: 0)] }
        while start <= length {
            let r = s.range(of: "\n", options: [], range: NSRange(location: start, length: length - start))
            if r.location == NSNotFound {
                ranges.append(NSRange(location: start, length: length - start))
                break
            }
            ranges.append(NSRange(location: start, length: r.location - start))
            start = r.location + 1
        }
        return ranges
    }

    private var displayedCountIsZero: Bool { core.displayedSegments.isEmpty }

    private func attributed(for seg: EditSegment) -> NSAttributedString {
        let text = EditDocumentReconciler.displayText(seg.currentText)
        var attrs = baseAttributes
        attrs[.editSegmentID] = seg.id.uuidString
        let out = NSMutableAttributedString(string: text, attributes: attrs)
        applyChangeMarks(to: out, segment: seg)
        return out
    }

    /// Lasting change marks (the F in B + F): a thin underline on every cleanup change, with
    /// "was: … · reason" on hover. Deletions mark the character after them with a dotted line.
    private func applyChangeMarks(to out: NSMutableAttributedString, segment seg: EditSegment) {
        guard let rev = seg.currentModelRevision, !rev.appliedEdits.isEmpty,
              let parentID = rev.parent,
              let parent = seg.revisions.first(where: { $0.id == parentID }) else { return }
        let marks = EditChangeMarks.ranges(parentText: parent.text, edits: rev.appliedEdits)
        let color = NSColor.controlAccentColor.withAlphaComponent(0.55)
        let length = out.length
        for mark in marks {
            var range = mark.range
            let deletion = range.length == 0
            if deletion {
                guard length > 0 else { continue }
                range = NSRange(location: min(range.location, length - 1), length: 1)
            }
            guard NSMaxRange(range) <= length else { continue }
            let tip = deletion
                ? "removed: \(mark.edit.find) · \(mark.edit.reason)"
                : "was: \(mark.edit.find.isEmpty ? "(nothing)" : mark.edit.find) · \(mark.edit.reason)"
            out.addAttributes([
                .underlineStyle: deletion
                    ? NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    : NSUnderlineStyle.single.rawValue,
                .underlineColor: color,
                .toolTip: tip,
                .editChangeMark: mark.edit.reason,
            ], range: range)
        }
    }

    private func withProgrammaticChange(_ body: () -> Void) {
        applyingProgrammatic = true
        let selection = captureSelection()
        storage.beginEditing()
        body()
        storage.endEditing()
        restoreSelection(selection)
        // Programmatic changes are not user undo steps, and older undo steps would now point at
        // shifted ranges, so the text undo stack is cleared. Changes & versions is the undo for
        // model changes (Cmd+Z walks hand edits made since).
        textView.undoManager?.removeAllActions()
        applyingProgrammatic = false
        refreshStyling()
        textView.needsDisplay = true
    }

    func fullRender() {
        withProgrammaticChange {
            let out = NSMutableAttributedString()
            for (i, seg) in core.displayedSegments.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                out.append(attributed(for: seg))
            }
            storage.setAttributedString(out)
        }
    }

    private func appendParagraph(_ id: UUID) {
        guard let seg = core.segment(id) else { return }
        let displayed = core.displayedSegments
        // The window must already show every earlier paragraph; if it does not, rebuild.
        guard paragraphRanges().count == displayed.count - 1, displayed.last?.id == id else {
            fullRender()
            if effectiveAnimation == .settle { scrollToEnd() }
            return
        }
        withProgrammaticChange {
            if storage.length > 0 {
                storage.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
            storage.append(attributed(for: seg))
        }
        scrollToEnd()
    }

    private func scrollToEnd() {
        textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    private func replaceParagraph(_ id: UUID, animate: Bool) {
        let displayed = core.displayedSegments
        let ranges = paragraphRanges()
        guard ranges.count == displayed.count,
              let index = displayed.firstIndex(where: { $0.id == id }) else {
            fullRender()
            return
        }
        let seg = displayed[index]
        withProgrammaticChange {
            storage.replaceCharacters(in: ranges[index], with: attributed(for: seg))
        }
        if animate && effectiveAnimation == .settle {
            startSettle(id)
        }
    }

    // MARK: Selection kept by (paragraph, offset) across programmatic changes

    private struct SavedSelection { let index: Int; let offset: Int; let length: Int; let tailFromEnd: Int? }

    private func captureSelection() -> SavedSelection? {
        let sel = textView.selectedRange()
        let ranges = paragraphRanges()
        guard let i = ranges.firstIndex(where: { sel.location >= $0.location && sel.location <= NSMaxRange($0) })
        else { return nil }
        let atEnd = sel.location == NSMaxRange(ranges[i])
        return SavedSelection(index: i, offset: sel.location - ranges[i].location, length: sel.length,
                              tailFromEnd: atEnd ? 0 : nil)
    }

    private func restoreSelection(_ saved: SavedSelection?) {
        guard let saved = saved else { return }
        let ranges = paragraphRanges()
        guard saved.index < ranges.count else {
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            return
        }
        let r = ranges[saved.index]
        let loc = saved.tailFromEnd != nil ? NSMaxRange(r) : r.location + min(saved.offset, r.length)
        let len = min(saved.length, storage.length - loc)
        textView.setSelectedRange(NSRange(location: loc, length: max(0, len)))
    }

    // MARK: Styling (temporary attributes: never stored, never undoable)

    func refreshStyling(now: Date = Date()) {
        guard let lm = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        let displayed = core.displayedSegments
        let ranges = paragraphRanges()
        guard ranges.count == displayed.count else { return }
        let settle = effectiveAnimation == .settle
        for (seg, range) in zip(displayed, ranges) where range.length > 0 {
            var tint: CGFloat = 0
            var alpha: CGFloat = 1
            if settle && (seg.state == .provisional || seg.state == .cleaning) {
                tint = 0.12; alpha = 0.85
            }
            if let started = animations[seg.id] {
                let p = min(1, now.timeIntervalSince(started) / Self.settleDuration)
                tint = 0.12 * (1 - p); alpha = 0.85 + 0.15 * p
            }
            if seg.state == .failed { tint = 0 }
            if tint > 0 {
                lm.addTemporaryAttribute(.backgroundColor,
                                         value: NSColor.controlAccentColor.withAlphaComponent(tint),
                                         forCharacterRange: range)
            }
            if alpha < 1 {
                lm.addTemporaryAttribute(.foregroundColor,
                                         value: NSColor.labelColor.withAlphaComponent(alpha),
                                         forCharacterRange: range)
            }
        }
    }

    private func startSettle(_ id: UUID) {
        animations[id] = Date()
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let now = Date()
                self.refreshStyling(now: now)
                self.animations = self.animations.filter { now.timeIntervalSince($0.value) < Self.settleDuration }
                if self.animations.isEmpty {
                    self.animationTimer?.invalidate()
                    self.animationTimer = nil
                    self.refreshStyling()
                }
            }
        }
    }

    /// Replay the settle on the last paragraph (the options control's preview).
    func previewAnimation() {
        guard let last = core.displayedSegments.last else { return }
        if effectiveAnimation == .settle {
            startSettle(last.id)
        } else {
            refreshStyling()
        }
    }

    private func marginDots() -> [(characterIndex: Int, color: NSColor, tooltip: String?)] {
        let displayed = core.displayedSegments
        let ranges = paragraphRanges()
        guard ranges.count == displayed.count else { return [] }
        var dots: [(Int, NSColor, String?)] = []
        for (seg, range) in zip(displayed, ranges) {
            switch seg.state {
            case .cleaning: dots.append((range.location, NSColor.systemBlue.withAlphaComponent(0.6), "Cleaning"))
            case .failed:
                dots.append((range.location, NSColor.systemOrange, core.failureMessage(for: seg.id)))
            default: break
            }
        }
        return dots.map { (characterIndex: $0.0, color: $0.1, tooltip: $0.2) }
    }

    // MARK: Status

    func refreshStatus() {
        if core.recordingSegmentID != nil {
            statusLabel.stringValue = "● Recording…"
            statusLabel.textColor = .systemRed
        } else if !core.transcribingSegmentIDs.isEmpty {
            statusLabel.stringValue = "Transcribing…"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "Tap your dictation key"
            statusLabel.textColor = .secondaryLabelColor
        }
        var status = core.cleanupStatusLine
        if let progress = core.progressLine, core.recordingSegmentID == nil || core.cleaningCount > 0 {
            status += " · " + progress.replacingOccurrences(of: "Recording · ", with: "")
        }
        if core.rejectedForMeaning > 0 {
            status += " · \(core.rejectedForMeaning) fix\(core.rejectedForMeaning == 1 ? "" : "es") skipped (would change meaning)"
        }
        footerStatus.stringValue = status
        footerStatus.toolTip = status
        if core.isEscArmed() {
            footerHint.stringValue = "Press Esc again to discard this text."
            footerHint.textColor = .systemOrange
        } else if core.pendingCommit {
            footerHint.stringValue = "Finishing the last take, then inserting…"
            footerHint.textColor = .secondaryLabelColor
        } else if let notice = core.notice {
            footerHint.stringValue = notice
            footerHint.textColor = .labelColor
        } else {
            footerHint.stringValue = "Return inserts · Shift+Return new line · Esc cancels · ⌘I changes"
            footerHint.textColor = .secondaryLabelColor
        }
        changesButton.isEnabled = !core.displayedSegments.isEmpty
        textView.needsDisplay = true
    }

    func setTargetName(_ name: String?) {
        targetLabel.stringValue = name.map { "→ \($0)" } ?? "→ (no text field)"
    }

    // MARK: Typing → core

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        // New typing takes the paragraph's identity but never a change mark's underline/tooltip.
        var attrs = baseAttributes
        if let id = segmentID(forCharacterAt: affectedCharRange.location) {
            attrs[.editSegmentID] = id.uuidString
        }
        textView.typingAttributes = attrs
        return true
    }

    /// Which paragraph a character position belongs to.
    func segmentID(forCharacterAt location: Int) -> UUID? {
        let displayed = core.displayedSegments
        let ranges = paragraphRanges()
        if ranges.count == displayed.count,
           let i = ranges.firstIndex(where: { location >= $0.location && location <= NSMaxRange($0) }) {
            return displayed[i].id
        }
        let length = storage.length
        guard length > 0 else { return nil }
        let at = min(max(0, location - 1), length - 1)
        return (storage.attribute(.editSegmentID, at: at, effectiveRange: nil) as? String).flatMap(UUID.init)
    }

    func textDidChange(_ notification: Notification) {
        guard !applyingProgrammatic else { return }
        // While an input method composes, or while a paragraph the core already has is waiting to
        // be drawn, the window and the core disagree on purpose. Reconciling now would read the
        // not-yet-drawn paragraph as deleted. Catch up once both are settled.
        if textView.hasMarkedText() || !pendingRender.isEmpty {
            needsReconcile = true
            if pendingRender.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reconcileIfNeeded() }
            }
            return
        }
        reconcile()
    }

    private var needsReconcile = false

    private func reconcileIfNeeded() {
        guard needsReconcile else { return }
        if textView.hasMarkedText() || !pendingRender.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reconcileIfNeeded() }
            return
        }
        needsReconcile = false
        reconcile()
    }

    /// - Parameter pending: core events not drawn yet. Their appended paragraphs are not in the
    ///   window, so they are left out. A paragraph with an undrawn replacement shows the text from
    ///   BEFORE that replacement: if the window still matches it, nothing was typed there; if not,
    ///   he typed there, his text wins, and the paragraph is returned so the replacement is skipped.
    @discardableResult
    private func reconcile(excluding pending: [EditCoreEvent] = []) -> Set<UUID> {
        var appended = Set<UUID>()
        var replaced = Set<UUID>()
        for e in pending {
            if case .appended(let id) = e { appended.insert(id) }
            if case .replaced(let id, _) = e { replaced.insert(id) }
        }
        let ns = textView.string as NSString
        var paragraphs: [EditDocumentReconciler.Paragraph] = []
        for range in paragraphRanges() {
            var ids: [UUID] = []
            if range.length > 0 {
                storage.enumerateAttribute(.editSegmentID, in: range) { value, _, _ in
                    if let s = value as? String, let id = UUID(uuidString: s), !ids.contains(id) {
                        ids.append(id)
                    }
                }
            }
            paragraphs.append(.init(text: EditDocumentReconciler.modelText(ns.substring(with: range)),
                                    ownerIDs: ids))
        }
        // What the window is expected to show for each paragraph it has drawn.
        let displayed = core.displayedSegments.filter { !appended.contains($0.id) }
            .map { seg -> (id: UUID, text: String) in
                if replaced.contains(seg.id) {
                    return (seg.id, seg.revisions.dropLast().last?.text ?? seg.currentText)
                }
                return (seg.id, seg.currentText)
            }
        let ops = EditDocumentReconciler.reconcile(paragraphs: paragraphs, displayed: displayed)
        var handEdited = Set<UUID>()
        for op in ops {
            if case .edit(let id, _) = op, replaced.contains(id) { handEdited.insert(id) }
        }
        guard !ops.isEmpty else { return handEdited }
        let structural = ops.contains {
            if case .edit = $0 { return false }
            return true
        }
        core.applyUserEdits(ops)
        if !structural { refreshStyling() }
        return handEdited
    }

    // MARK: Header actions

    /// The paragraph the caret is in (or the last one).
    func currentSegmentID() -> UUID? {
        segmentID(forCharacterAt: textView.selectedRange().location) ?? core.displayedSegments.last?.id
    }

    @objc private func changesClicked() {
        guard let id = currentSegmentID() else { return }
        onChanges?(id, changesButton)
    }

    @objc private func optionsClicked() {
        onOptions?(optionsButton)
    }

    private func contextMenu(at index: Int) -> NSMenu? {
        guard let id = segmentID(forCharacterAt: index), let seg = core.segment(id) else { return nil }
        let menu = NSMenu()
        let changes = NSMenuItem(title: "Changes and versions…", action: #selector(menuChanges(_:)), keyEquivalent: "")
        changes.target = self
        changes.representedObject = id
        menu.addItem(changes)
        if seg.originalText != nil, seg.originalText != seg.currentText {
            let item = NSMenuItem(title: "Restore original", action: #selector(menuRestoreOriginal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        if seg.previousRevision != nil {
            let item = NSMenuItem(title: "Restore previous version", action: #selector(menuRestorePrevious(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        if core.settings.sendsToCloud, seg.state != .cleaning {
            let title = seg.state == .failed
                ? "Clean up again (\(core.failureMessage(for: id) ?? "failed"))"
                : "Clean up again"
            let item = NSMenuItem(title: title, action: #selector(menuRetry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, sel) in [("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))),
                             ("Paste", #selector(NSText.paste(_:)))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = textView
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuChanges(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onChanges?(id, changesButton)
    }
    @objc private func menuRestoreOriginal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        core.restore(.original, segmentID: id)
    }
    @objc private func menuRestorePrevious(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        core.restore(.previous, segmentID: id)
    }
    @objc private func menuRetry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRetry?(id)
    }

    // MARK: Comparison panel (read-only cards outside the editor, a stale-comparison rule)

    func renderComparison() {
        comparePanel.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let c = core.comparison else {
            comparePanel.isHidden = true
            return
        }
        comparePanel.isHidden = false
        let title = NSTextField(labelWithString: c.invalidated
            ? "The paragraph changed, so this comparison can no longer be used. Compare again from Options."
            : (c.chosenLabel == nil ? "Compare: same paragraph, two models (names hidden until you pick)"
                                    : "Compared"))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        comparePanel.addArrangedSubview(title)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 10
        for cand in c.candidates {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 4
            let head = NSTextField(labelWithString: c.chosenLabel == nil
                ? cand.label : "\(cand.label) · \(cand.model.displayName)")
            head.font = .systemFont(ofSize: 11, weight: .bold)
            col.addArrangedSubview(head)
            let body: String
            var usable = false
            switch cand.status {
            case .running: body = "Working…"
            case .failed(let msg): body = "Failed: \(msg)"
            case .ready(let text, let edits):
                body = text + (edits.isEmpty ? "\n(no changes)" : "\n(\(edits.count) change\(edits.count == 1 ? "" : "s"))")
                usable = !c.invalidated && c.chosenLabel == nil
            }
            let text = NSTextField(wrappingLabelWithString: body)
            text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            text.preferredMaxLayoutWidth = 240
            col.addArrangedSubview(text)
            let use = NSButton(title: "Use \(cand.label)", target: self, action: #selector(useCandidate(_:)))
            use.identifier = NSUserInterfaceItemIdentifier(cand.label)
            use.controlSize = .small
            use.isEnabled = usable
            col.addArrangedSubview(use)
            row.addArrangedSubview(col)
        }
        comparePanel.addArrangedSubview(row)
        let close = NSButton(title: "Close comparison", target: self, action: #selector(closeCompare))
        close.controlSize = .small
        comparePanel.addArrangedSubview(close)
    }

    @objc private func useCandidate(_ sender: NSButton) {
        guard let label = sender.identifier?.rawValue else { return }
        onCompareChoose?(label)
    }

    @objc private func closeCompare() { onCompareClose?() }

    // MARK: NSWindowDelegate

    var onCloseRequest: (() -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest?() ?? true
    }
}

/// Where each applied cleanup change sits in the new text (for underlines and tooltips).
public enum EditChangeMarks {
    public struct Mark: Equatable {
        public let range: NSRange     // UTF-16 range in the NEW text (length 0 for a deletion)
        public let edit: SpanEdit
    }

    /// `edits` were applied to `parentText` by SpanEditApplier (unique anchors, no overlaps).
    public static func ranges(parentText: String, edits: [SpanEdit]) -> [Mark] {
        let ns = parentText as NSString
        var located: [(NSRange, SpanEdit)] = []
        for e in edits where !e.find.isEmpty {
            let r = ns.range(of: e.find)
            if r.location != NSNotFound { located.append((r, e)) }
        }
        located.sort { $0.0.location < $1.0.location }
        var delta = 0
        var marks: [Mark] = []
        for (r, e) in located {
            let newLength = (e.replace as NSString).length
            marks.append(Mark(range: NSRange(location: r.location + delta, length: newLength), edit: e))
            delta += newLength - r.length
        }
        return marks
    }
}
