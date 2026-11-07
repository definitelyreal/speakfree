import AppKit
import Foundation

/// State behind the Replacements window: the saved rules, and the one being written.
final class ReplacementsModel: ObservableObject {
    enum CaptureState: Equatable {
        case idle
        case listening(heard: Int)
        case working
        case message(String)
    }

    @Published private(set) var rules: [ReplacementRule]
    @Published var replacement = ""
    @Published private(set) var triggers: [String] = []
    @Published var typedTrigger = ""
    @Published private(set) var captureState: CaptureState = .idle
    /// The saved rule being edited, or nil while writing a new one.
    @Published private(set) var editing: ReplacementRule?

    private let persist: ([String: String]) throws -> Void
    private let capture: ReplacementCapturing?

    init(overrides: [String: String],
         capture: ReplacementCapturing?,
         persist: @escaping ([String: String]) throws -> Void) {
        self.rules = ReplacementRules.grouped(overrides)
        self.capture = capture
        self.persist = persist
    }

    /// Pick up rules changed elsewhere (the file edited by hand, another window).
    func reload(overrides: [String: String]) {
        rules = ReplacementRules.grouped(overrides)
        if let editing, !rules.contains(editing) { self.editing = nil }
    }

    /// The model behind the Settings pane: the real rules file and the app's microphone.
    static func forSettings() -> ReplacementsModel {
        let capture = (NSApp?.delegate as? AppDelegate).map { ReplacementCapture(app: $0) }
        return ReplacementsModel(overrides: [:], capture: capture) { try Config.saveOverrides($0) }
    }

    var canSave: Bool {
        !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !triggers.isEmpty
    }

    var canRecord: Bool { capture != nil && captureState != .working }

    /// Microphone loudness for the waveform; nil when not listening.
    var level: CGFloat? { capture?.level }

    var isListening: Bool {
        if case .listening = captureState { return true }
        return false
    }

    // MARK: - Triggers

    func addTypedTrigger() {
        addTriggers([typedTrigger])
        typedTrigger = ""
    }

    func addTriggers(_ new: [String]) {
        triggers = ReplacementRules.cleaned(triggers + new)
    }

    func removeTrigger(_ trigger: String) {
        triggers.removeAll { $0 == trigger }
    }

    // MARK: - Rules

    func startNew() {
        capture?.cancel()
        editing = nil
        replacement = ""
        triggers = []
        typedTrigger = ""
        captureState = .idle
    }

    func edit(_ rule: ReplacementRule) {
        startNew()
        editing = rule
        replacement = rule.replacement
        triggers = rule.triggers
    }

    func save() {
        if !typedTrigger.isEmpty { addTypedTrigger() }
        guard canSave else { return }
        let updated = ReplacementRules.saving(
            ReplacementRule(replacement: replacement, triggers: triggers),
            replacing: editing, into: rules)
        guard store(updated) else { return }
        startNew()
    }

    func delete(_ rule: ReplacementRule) {
        guard store(ReplacementRules.deleting(rule, from: rules)) else { return }
        if editing == rule { startNew() }
    }

    private func store(_ updated: [ReplacementRule]) -> Bool {
        do {
            try persist(ReplacementRules.flattened(updated))
            rules = updated
            return true
        } catch {
            captureState = .message("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Voice

    func toggleRecording() {
        guard let capture else { return }
        if isListening {
            captureState = .working
            capture.stop()
            return
        }
        captureState = .listening(heard: 0)
        capture.start(
            onProgress: { [weak self] heard in
                guard let self, self.isListening else { return }
                self.captureState = .listening(heard: heard)
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let heard):
                    self.addTriggers(heard)
                    self.captureState = .idle
                case .failure(let failure):
                    self.captureState = .message(failure.message)
                }
            })
    }

    func close() {
        capture?.cancel()
        captureState = .idle
    }
}
