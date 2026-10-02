// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_elegance_audit · 2026-10-01
// Edit Mode V1 test doubles
import Foundation
@testable import SpeakFreeLib

/// A scripted cleanup: every call waits until the test resolves it, so the test controls ordering.
/// Cancellation resolves a call at once with `.cancelled`, like the real service.
final class ScriptedCleaner: EditCleanupRunning {
    struct Call {
        let raw: String
        let pipelineText: String
        let model: CleanupService.Model
        let cancellation: CleanupCancellation
    }
    private(set) var calls: [Call] = []
    private var continuations: [Int: CheckedContinuation<Result<[SpanEdit], CleanupService.CleanupError>, Never>] = [:]
    private let lock = NSLock()

    func cleanup(raw: String, pipelineText: String, model: CleanupService.Model,
                 cancellation: CleanupCancellation) async -> Result<[SpanEdit], CleanupService.CleanupError> {
        if cancellation.isCancelled { return .failure(.cancelled) }
        return await withCheckedContinuation { cont in
            lock.lock()
            let index = calls.count
            calls.append(Call(raw: raw, pipelineText: pipelineText, model: model, cancellation: cancellation))
            continuations[index] = cont
            lock.unlock()
            cancellation.onCancel { [weak self] in self?.finish(index, .failure(.cancelled)) }
        }
    }

    /// Resolve call `index` (0-based, in call order).
    func finish(_ index: Int, _ result: Result<[SpanEdit], CleanupService.CleanupError>) {
        lock.lock()
        let cont = continuations.removeValue(forKey: index)
        lock.unlock()
        cont?.resume(returning: result)
    }

    /// The index of the call made for this paragraph text (concurrent calls start in any order).
    func index(for pipelineText: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return calls.firstIndex(where: { $0.pipelineText == pipelineText })
    }

    /// The newest call made with this model.
    func lastIndex(model: CleanupService.Model) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return calls.lastIndex(where: { $0.model == model })
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var openCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }
}

final class FakeClipboard: EditClipboard {
    private(set) var copies: [String] = []
    var copySucceeds = true
    func copy(_ text: String) -> Bool {
        guard copySucceeds else { return false }
        copies.append(text)
        return true
    }
}

/// Let queued main-actor tasks run.
@MainActor
func drainMainActor(_ rounds: Int = 30) async {
    for _ in 0..<rounds { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<rounds { await Task.yield() }
}

extension EditModeSettings {
    static let cloudOn = EditModeSettings(cleanupEnabled: true, consentGiven: true, model: .sonnet,
                                          animation: .settle)
    static let cloudOff = EditModeSettings(cleanupEnabled: false, consentGiven: true, model: .sonnet,
                                           animation: .settle)
    static let noConsent = EditModeSettings(cleanupEnabled: true, consentGiven: false, model: .sonnet,
                                            animation: .settle)
}
