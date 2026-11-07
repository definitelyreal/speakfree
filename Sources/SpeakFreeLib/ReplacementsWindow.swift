import AppKit
import SwiftUI

/// Scrolling loudness history for the Replacements window, drawn the way the dictation
/// pill draws it: new sound enters on the right and travels left.
final class CaptureMeter: ObservableObject {
    @Published private(set) var heights: [CGFloat]

    private var history = [CGFloat](repeating: 0, count: TargetAppPill.historyLength)
    private var gate = OverlayEmergence.AdaptiveSpeechGate()
    private var level: CGFloat = 0
    private var timer: Timer?

    init() {
        heights = TargetAppPill.barHeights(history: history)
    }

    func start(source: @escaping () -> CGFloat?) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advance(rms: source())
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reset()
    }

    func reset() {
        history = [CGFloat](repeating: 0, count: TargetAppPill.historyLength)
        gate = OverlayEmergence.AdaptiveSpeechGate()
        level = 0
        heights = TargetAppPill.barHeights(history: history)
    }

    /// One thirtieth of a second: the pill moves four steps in that time.
    func advance(rms: CGFloat?) {
        let target = rms.map { gate.update(rms: $0) } ?? 0
        for _ in 0..<(TargetAppPill.frameRate / 30) {
            level = TargetAppPill.smoothed(from: level, toward: target)
            history = TargetAppPill.scrolled(history, adding: min(1, max(0, level)))
        }
        heights = TargetAppPill.barHeights(history: history)
    }
}

/// The Replacements window: teach speakfree what to write when it hears a word wrong.
struct ReplacementsView: View {
    @ObservedObject var model: ReplacementsModel
    let onDone: () -> Void
    @StateObject private var meter = CaptureMeter()

    private let labelWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Replacements").font(.title2.weight(.semibold))
                Text("Teach speakfree a name, a term, or any word it keeps getting wrong.")
                    .foregroundColor(.secondary)
            }

            CaptureStrip(state: model.captureState, canRecord: model.canRecord,
                         heights: meter.heights, onToggle: model.toggleRecording)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Heard as").frame(width: labelWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.triggers.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(model.triggers, id: \.self) { trigger in
                                    HeardChip(text: trigger) { model.removeTrigger(trigger) }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            TextField(model.triggers.isEmpty
                                        ? "Record above, or type what it hears"
                                        : "Type another",
                                      text: $model.typedTrigger)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.addTypedTrigger() }
                            Button("Add") { model.addTypedTrigger() }
                                .disabled(Replacements.normalize(model.typedTrigger).isEmpty)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Write").frame(width: labelWidth, alignment: .leading)
                    TextField("What it should write", text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Spacer()
                    if model.editing != nil || !model.replacement.isEmpty || !model.triggers.isEmpty {
                        Button(model.editing == nil ? "Clear" : "Cancel") { model.startNew() }
                    }
                    Button(model.editing == nil ? "Add Replacement" : "Save Changes") { model.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }

            Divider()

            if model.rules.isEmpty {
                Text("Nothing saved yet. Your replacements will be listed here.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rules) { rule in
                            SavedRuleRow(rule: rule, isEditing: model.editing == rule,
                                         onEdit: { model.edit(rule) },
                                         onDelete: { model.delete(rule) })
                            Divider().opacity(0.5)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { onDone() }
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onChange(of: model.isListening) { listening in
            if listening {
                meter.start { [weak model] in model?.level }
            } else {
                meter.stop()
            }
        }
        .onDisappear { meter.stop() }
    }

    private var canSubmit: Bool {
        let hasText = !model.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && (!model.triggers.isEmpty || !Replacements.normalize(model.typedTrigger).isEmpty)
    }
}

/// The recording area. It borrows the dictation pill's look, a dark strip with white
/// bars and a red edge while the microphone is live, so recording here is unmistakable.
private struct CaptureStrip: View {
    let state: ReplacementsModel.CaptureState
    let canRecord: Bool
    let heights: [CGFloat]
    let onToggle: () -> Void

    private var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    private var heard: Int {
        if case .listening(let heard) = state { return heard }
        return 0
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onToggle) {
                ZStack {
                    Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    if isListening {
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .systemRed))
                            .frame(width: 16, height: 16)
                    } else {
                        Circle().fill(Color(nsColor: .systemRed)).padding(6)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .opacity(canRecord ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .disabled(!canRecord)
            .help(isListening ? "Stop" : "Record")
            .accessibilityLabel(isListening ? "Stop recording" : "Record")

            VStack(alignment: .leading, spacing: 8) {
                // The bars spread to fill the strip, so the waveform reads as its centrepiece.
                HStack(alignment: .center, spacing: 0) {
                    ForEach(heights.indices, id: \.self) { index in
                        Capsule()
                            .fill(Color.white.opacity(isListening ? 0.9 : 0.3))
                            .frame(width: 4, height: heights[index] * 1.75)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: TargetAppPill.maxBarHeight * 1.75)
                .accessibilityHidden(true)

                Text(status)
                    .font(.callout)
                    .foregroundColor(isWarning ? Color(nsColor: .systemOrange) : .white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                ForEach(0..<ReplacementCapture.wantedRepeats, id: \.self) { index in
                    Circle()
                        .fill(index < heard ? Color.white : Color.white.opacity(0.18))
                        .frame(width: 9, height: 9)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(heard) of \(ReplacementCapture.wantedRepeats) heard")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.09)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isListening ? Color(nsColor: .systemRed) : Color.white.opacity(0.08),
                              lineWidth: isListening ? 2 : 1))
        .shadow(color: isListening ? Color(nsColor: .systemRed).opacity(0.45) : .clear, radius: 9)
        .animation(.easeOut(duration: 0.18), value: isListening)
    }

    private var status: String {
        switch state {
        case .idle:
            return "Say it five times, pausing between each."
        case .listening(let heard):
            return heard == 0
                ? "Recording. Say it five times."
                : "Recording. Heard \(heard) of \(ReplacementCapture.wantedRepeats)."
        case .working:
            return "Working out what it heard\u{2026}"
        case .message(let message):
            return message
        }
    }

    private var isWarning: Bool {
        if case .message = state { return true }
        return false
    }
}

private struct HeardChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.09)))
    }
}

private struct SavedRuleRow: View {
    let rule: ReplacementRule
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(rule.replacement)
                .fontWeight(.medium)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Text(rule.triggers.joined(separator: ", "))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
                .accessibilityLabel("Edit \(rule.replacement)")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
                .accessibilityLabel("Delete \(rule.replacement)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(isEditing ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// Lays chips out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat)
        -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

final class ReplacementsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: ReplacementsWindowController?
    private var model: ReplacementsModel?

    static func show() {
        if let existing = shared?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ReplacementsWindowController(window: nil)
        let capture = (NSApp.delegate as? AppDelegate).map { ReplacementCapture(app: $0) }
        let model = ReplacementsModel(overrides: Config.loadOverrides(), capture: capture) {
            try Config.saveOverrides($0)
        }
        let view = ReplacementsView(model: model) { [weak controller] in controller?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Replacements"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.window = window
        controller.model = model
        shared = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        Self.shared = nil
    }
}
