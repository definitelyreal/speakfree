// Claude · 2026-09-24 · Edit Mode V1
import AppKit

/// The first-use cloud explanation, with an explicit
/// on-device path. Shown before any text can leave the Mac.
@MainActor
enum EditConsentSheet {
    enum Choice { case allow, onDeviceOnly, cancel }

    static let privacyURL = URL(string: "https://www.anthropic.com/legal/privacy")!

    static let explanation = """
    Edit Mode can clean up each dictation with Claude. Claude runs in Anthropic's cloud, through \
    the Claude command line tool on this Mac, using your own Claude account.

    Only the text of each paragraph is sent. Never the audio, never what is on your screen, never \
    the name of the app you are in.

    You can use Edit Mode on-device only, and turn cleanup on or off at any time in the window's \
    Options or in Settings.
    """

    static func run(in window: NSWindow?, offerOnDeviceOnly: Bool = false) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Clean up dictation with Claude?"
        alert.informativeText = explanation
        alert.addButton(withTitle: "Allow Claude cleanup")
        if offerOnDeviceOnly { alert.addButton(withTitle: "Use on-device only") }
        alert.addButton(withTitle: "Cancel")
        let link = NSTextField(labelWithString: "")
        link.allowsEditingTextAttributes = true
        link.isSelectable = true
        link.attributedStringValue = NSAttributedString(
            string: "Anthropic privacy policy",
            attributes: [.link: privacyURL, .font: NSFont.systemFont(ofSize: 11)])
        link.frame = NSRect(x: 0, y: 0, width: 300, height: 18)
        alert.accessoryView = link
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .allow
        case .alertSecondButtonReturn: return offerOnDeviceOnly ? .onDeviceOnly : .cancel
        default: return .cancel
        }
    }
}

/// The small options control in the window: cleanup on/off, model, on-demand
/// compare of the paragraph at the caret, and Settle/Quiet with a preview.
@MainActor
final class EditOptionsView: NSViewController {
    private let core: EditSessionCore
    private let onCleanup: (Bool) -> Void
    private let onModel: (CleanupService.Model) -> Void
    private let onAnimation: (EditAnimationStyle) -> Void
    private let onPreview: () -> Void
    private let onCompare: (CleanupService.Model, CleanupService.Model) -> Void
    private let onSample: (() -> Void)?

    private let cleanupBox = NSButton(checkboxWithTitle: "Clean up with Claude (cloud)", target: nil, action: nil)
    private let modelPopup = NSPopUpButton()
    private let compareA = NSPopUpButton()
    private let compareB = NSPopUpButton()
    private let animation = NSSegmentedControl(labels: ["Settle", "Quiet"], trackingMode: .selectOne,
                                               target: nil, action: nil)

    init(core: EditSessionCore, onCleanup: @escaping (Bool) -> Void,
         onModel: @escaping (CleanupService.Model) -> Void,
         onAnimation: @escaping (EditAnimationStyle) -> Void, onPreview: @escaping () -> Void,
         onCompare: @escaping (CleanupService.Model, CleanupService.Model) -> Void,
         onSample: (() -> Void)?) {
        self.core = core
        self.onCleanup = onCleanup
        self.onModel = onModel
        self.onAnimation = onAnimation
        self.onPreview = onPreview
        self.onCompare = onCompare
        self.onSample = onSample
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let models = CleanupService.Model.allCases
        cleanupBox.state = core.settings.cleanupEnabled && core.settings.consentGiven ? .on : .off
        cleanupBox.target = self
        cleanupBox.action = #selector(cleanupChanged)

        modelPopup.addItems(withTitles: models.map(\.displayName))
        modelPopup.selectItem(at: models.firstIndex(of: core.settings.model) ?? 0)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        compareA.addItems(withTitles: models.map(\.displayName))
        compareB.addItems(withTitles: models.map(\.displayName))
        compareA.selectItem(at: models.firstIndex(of: .sonnet) ?? 0)
        compareB.selectItem(at: models.firstIndex(of: .opus) ?? 1)
        let compareButton = NSButton(title: "Compare this paragraph", target: self, action: #selector(compareClicked))
        compareButton.toolTip = "Runs the paragraph at the cursor through both models once. Nothing changes until you pick A or B."

        animation.selectedSegment = core.settings.animation == .settle ? 0 : 1
        animation.target = self
        animation.action = #selector(animationChanged)
        let preview = NSButton(title: "Preview", target: self, action: #selector(previewClicked))

        let note = NSTextField(wrappingLabelWithString:
            "Only a paragraph's text is sent, never audio, screen contents, or the app name.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300

        func row(_ label: String, _ views: [NSView]) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            l.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let s = NSStackView(views: [l] + views)
            s.orientation = .horizontal
            s.spacing = 6
            return s
        }
        let vs = NSTextField(labelWithString: "vs")
        var rows: [NSView] = [
            cleanupBox,
            row("Model", [modelPopup]),
            row("Compare", [compareA, vs, compareB]),
            row("", [compareButton]),
            row("Animation", [animation, preview]),
            note,
        ]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let rm = NSTextField(wrappingLabelWithString: "Reduce Motion is on, so Quiet is shown either way.")
            rm.font = .systemFont(ofSize: 11)
            rm.textColor = .secondaryLabelColor
            rows.append(rm)
        }
        if let onSample = onSample {
            let b = NSButton(title: "Add sample paragraph (Developer)", target: self, action: #selector(sampleClicked))
            _ = onSample
            rows.append(b)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = stack
    }

    @objc private func cleanupChanged() {
        onCleanup(cleanupBox.state == .on)
        cleanupBox.state = core.settings.cleanupEnabled && core.settings.consentGiven ? .on : .off
    }
    @objc private func modelChanged() {
        let models = CleanupService.Model.allCases
        onModel(models[max(0, modelPopup.indexOfSelectedItem)])
    }
    @objc private func animationChanged() {
        onAnimation(animation.selectedSegment == 0 ? .settle : .quiet)
    }
    @objc private func previewClicked() { onPreview() }
    @objc private func compareClicked() {
        let models = CleanupService.Model.allCases
        let a = models[max(0, compareA.indexOfSelectedItem)]
        let b = models[max(0, compareB.indexOfSelectedItem)]
        guard a != b else { NSSound.beep(); return }
        onCompare(a, b)
    }
    @objc private func sampleClicked() { onSample?() }
}

/// Changes and versions for one paragraph: Original, Previous and Current
/// with Copy and Restore, and every cleanup change listed with its own Undo. Reachable by the
/// Changes button, ⌘I, and the right-click menu, so hover is never the only way in.
@MainActor
final class EditVersionsView: NSViewController {
    private let core: EditSessionCore
    private let segmentID: UUID
    private let onRetry: () -> Void

    init(core: EditSessionCore, segmentID: UUID, onRetry: @escaping () -> Void) {
        self.core = core
        self.segmentID = segmentID
        self.onRetry = onRetry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = stack
        rebuild()
    }

    private func rebuild() {
        guard let stack = view as? NSStackView else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let v = core.versions(for: segmentID) else {
            stack.addArrangedSubview(NSTextField(labelWithString: "This paragraph is gone."))
            return
        }
        if v.takes > 1 {
            let merged = NSTextField(labelWithString: "This paragraph joins \(v.takes) dictations.")
            merged.font = .systemFont(ofSize: 11)
            merged.textColor = .secondaryLabelColor
            stack.addArrangedSubview(merged)
        }
        addVersion(stack, "Current", v.current, kind: .current, restorable: false)
        if let prev = v.previous {
            addVersion(stack, "Previous", prev, kind: .previous, restorable: true)
        }
        if let orig = v.original, orig != v.current {
            addVersion(stack, "Original (on-device)", orig, kind: .original, restorable: true)
        }
        if !v.changes.isEmpty {
            let h = NSTextField(labelWithString: "Changes by Claude")
            h.font = .systemFont(ofSize: 11, weight: .semibold)
            stack.addArrangedSubview(h)
            for (i, change) in v.changes.enumerated() {
                let was = change.find.isEmpty ? "(nothing)" : "“\(change.find)”"
                let now = change.replace.isEmpty ? "(removed)" : "“\(change.replace)”"
                let label = NSTextField(wrappingLabelWithString: "\(was) → \(now) · \(change.reason)")
                label.font = .systemFont(ofSize: 12)
                label.preferredMaxLayoutWidth = 280
                let undo = NSButton(title: "Undo", target: self, action: #selector(undoChange(_:)))
                undo.tag = i
                undo.controlSize = .small
                undo.setAccessibilityLabel("Undo change \(i + 1)")
                let row = NSStackView(views: [label, undo])
                row.orientation = .horizontal
                row.alignment = .firstBaseline
                stack.addArrangedSubview(row)
            }
        }
        if let failure = core.failureMessage(for: segmentID) {
            let f = NSTextField(wrappingLabelWithString: "Cleanup failed: \(failure)")
            f.textColor = .systemOrange
            f.preferredMaxLayoutWidth = 320
            stack.addArrangedSubview(f)
        }
        if core.settings.sendsToCloud, core.segment(segmentID)?.state != .cleaning {
            stack.addArrangedSubview(NSButton(title: "Clean up again", target: self, action: #selector(retry)))
        }
    }

    private func addVersion(_ stack: NSStackView, _ title: String, _ text: String,
                            kind: EditVersionKind, restorable: Bool) {
        let h = NSTextField(labelWithString: title)
        h.font = .systemFont(ofSize: 11, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: text)
        body.isSelectable = true
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = 320
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyVersion(_:)))
        copy.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        copy.controlSize = .small
        copy.setAccessibilityLabel("Copy \(title)")
        var buttons: [NSView] = [copy]
        if restorable {
            let restore = NSButton(title: "Restore", target: self, action: #selector(restoreVersion(_:)))
            restore.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            restore.controlSize = .small
            restore.setAccessibilityLabel("Restore \(title)")
            buttons.append(restore)
        }
        let row = NSStackView(views: [h] + buttons)
        row.orientation = .horizontal
        row.spacing = 6
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(body)
    }

    @objc private func copyVersion(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = EditVersionKind(rawValue: raw) else { return }
        core.copyVersion(kind, segmentID: segmentID)
    }

    @objc private func restoreVersion(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = EditVersionKind(rawValue: raw) else { return }
        core.restore(kind, segmentID: segmentID)
        rebuild()
    }

    @objc private func undoChange(_ sender: NSButton) {
        guard let v = core.versions(for: segmentID), sender.tag < v.changes.count else { return }
        if !core.revertChange(v.changes[sender.tag], segmentID: segmentID) { NSSound.beep() }
        rebuild()
    }

    @objc private func retry() {
        onRetry()
        rebuild()
    }
}
