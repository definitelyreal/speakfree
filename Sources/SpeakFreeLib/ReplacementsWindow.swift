import AppKit
import SwiftUI

/// The Replacements window: teach speakfree what to write when it hears a word wrong.
struct ReplacementsView: View {
    @ObservedObject var model: ReplacementsModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Replacements").font(.title3.weight(.semibold))
                Text("When speakfree hears one of these, it writes your text instead. Use it for names, terminology, or any word it keeps getting wrong.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Write").frame(width: 96, alignment: .leading)
                        TextField("What it should write", text: $model.replacement)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(alignment: .top) {
                        Text("When it hears").frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            heardList
                            HStack(spacing: 8) {
                                Button(model.isListening ? "Stop" : "Record") { model.toggleRecording() }
                                    .disabled(!model.canRecord)
                                Text(captureHint)
                                    .font(.footnote)
                                    .foregroundColor(captureHintIsWarning ? .orange : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 8) {
                                TextField("Or type what it hears", text: $model.typedTrigger)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { model.addTypedTrigger() }
                                Button("Add") { model.addTypedTrigger() }
                                    .disabled(Replacements.normalize(model.typedTrigger).isEmpty)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        if model.editing != nil || !model.replacement.isEmpty || !model.triggers.isEmpty {
                            Button(model.editing == nil ? "Clear" : "Cancel") { model.startNew() }
                        }
                        Button(model.editing == nil ? "Add Replacement" : "Save Changes") { model.save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canSave && Replacements.normalize(model.typedTrigger).isEmpty)
                    }
                }
                .padding(6)
            }

            if model.rules.isEmpty {
                Text("No replacements yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rules) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.replacement).fontWeight(.medium)
                            Text(rule.triggers.joined(separator: "  ·  "))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Edit") { model.edit(rule) }
                        Button("Delete") { model.delete(rule) }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                Spacer()
                Button("Done") { onDone() }
            }
        }
        .padding(18)
        .frame(width: 540, height: 560)
    }

    @ViewBuilder private var heardList: some View {
        if model.triggers.isEmpty {
            Text("Nothing yet").foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.triggers, id: \.self) { trigger in
                    HStack(spacing: 6) {
                        Text(trigger)
                        Button {
                            model.removeTrigger(trigger)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                }
            }
        }
    }

    private var captureHint: String {
        switch model.captureState {
        case .idle:
            return "Say it \(ReplacementCapture.wantedRepeats) times, pausing between each."
        case .listening(let heard):
            return "Listening: \(heard) of \(ReplacementCapture.wantedRepeats). Pause between each."
        case .working:
            return "Working out what was heard\u{2026}"
        case .message(let message):
            return message
        }
    }

    private var captureHintIsWarning: Bool {
        if case .message = model.captureState { return true }
        return false
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
