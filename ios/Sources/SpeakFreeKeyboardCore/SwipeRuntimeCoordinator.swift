// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

/// The result of a swipe decode whose model is loaded lazily.
public enum SwipeRuntimeDecodeResult {
    case success([SwipeCandidate])
    case unavailable(String)
}

public enum SwipeRuntimeCoordinatorError: LocalizedError {
    case emptyVocabulary

    public var errorDescription: String? {
        "The swipe vocabulary is empty or invalid."
    }
}

/// Serializes lazy vocabulary/model initialization and decode handoff.
///
/// The keyboard extension is frequently recreated while the containing process remains alive.
/// Keeping this policy independent of UIKit lets its process-wide owner be tested with controlled
/// loaders: the first swipe waits for initialization, a failed model retry retains typing
/// suggestions, and a failed vocabulary retry starts from a clean state.
public final class SwipeRuntimeCoordinator {
    private enum State {
        case unloaded
        case loading(TypingSuggestionIndex?)
        case ready(decoder: SwipeDecoder, suggestions: TypingSuggestionIndex)
        case failed(String, TypingSuggestionIndex?)
    }

    private let stateLock = NSLock()
    private let vocabularyLoader: () throws -> [VocabularyEntry]
    private let runtimeLoader: () throws -> any SwipeModelRuntime
    private let loadQueue: DispatchQueue
    private let inferenceQueue: DispatchQueue
    private let completionQueue: DispatchQueue
    private var state: State = .unloaded

    public init(
        vocabularyLoader: @escaping () throws -> [VocabularyEntry],
        runtimeLoader: @escaping () throws -> any SwipeModelRuntime,
        loadQueue: DispatchQueue = DispatchQueue(
            label: "com.speakfree.keyboard.runtime.load", qos: .userInitiated
        ),
        inferenceQueue: DispatchQueue = DispatchQueue(
            label: "com.speakfree.keyboard.runtime.inference", qos: .userInitiated
        ),
        completionQueue: DispatchQueue = .main
    ) {
        self.vocabularyLoader = vocabularyLoader
        self.runtimeLoader = runtimeLoader
        self.loadQueue = loadQueue
        self.inferenceQueue = inferenceQueue
        self.completionQueue = completionQueue
    }

    public func prepare(retryAfterFailure: Bool = false) {
        stateLock.lock()
        let retainedSuggestions: TypingSuggestionIndex?
        switch state {
        case .unloaded:
            retainedSuggestions = nil
        case .failed(_, let suggestions) where retryAfterFailure:
            retainedSuggestions = suggestions
        default:
            stateLock.unlock()
            return
        }
        state = .loading(retainedSuggestions)
        stateLock.unlock()

        loadQueue.async { [self] in
            var suggestions = retainedSuggestions
            do {
                let entries = try vocabularyLoader()
                guard !entries.isEmpty else {
                    throw SwipeRuntimeCoordinatorError.emptyVocabulary
                }
                if suggestions == nil {
                    suggestions = TypingSuggestionIndex(entries: entries)
                }
                let runtime = try runtimeLoader()
                let readyState = State.ready(
                    decoder: SwipeDecoder(
                        runtime: runtime,
                        vocabulary: VocabularyTrie(entries: entries),
                        beamWidth: 100,
                        frequencyWeight: 0.15
                    ),
                    suggestions: suggestions!
                )
                stateLock.lock()
                state = readyState
                stateLock.unlock()
            } catch {
                stateLock.lock()
                state = .failed(error.localizedDescription, suggestions)
                stateLock.unlock()
            }
        }
    }

    public func decode(
        points: [TrajectoryPoint],
        keyboardSize: KeyboardSize,
        candidateLimit: Int,
        completion: @escaping (SwipeRuntimeDecodeResult) -> Void
    ) {
        prepare(retryAfterFailure: true)
        // This enqueue occurs after `prepare`, on the same serial queue. Thus first use cannot
        // bypass model initialization and fall through to a geometric/fallback decoder.
        loadQueue.async { [self] in
            stateLock.lock()
            let decoder: SwipeDecoder?
            let unavailableReason: String?
            if case .ready(let readyDecoder, _) = state {
                decoder = readyDecoder
                unavailableReason = nil
            } else if case .failed(let message, _) = state {
                decoder = nil
                unavailableReason = message
            } else {
                decoder = nil
                unavailableReason = "Swipe model is not ready."
            }
            stateLock.unlock()
            guard let decoder else {
                completionQueue.async {
                    completion(.unavailable(unavailableReason ?? "Swipe model is unavailable."))
                }
                return
            }
            inferenceQueue.async {
                do {
                    let candidates = try decoder.decode(
                        points: points,
                        keyboardSize: keyboardSize,
                        candidateLimit: candidateLimit
                    )
                    self.completionQueue.async { completion(.success(candidates)) }
                } catch {
                    self.completionQueue.async { completion(.unavailable(error.localizedDescription)) }
                }
            }
        }
    }

    public func suggestions(for composition: String, limit: Int = 3) -> [String] {
        let index = suggestionIndex()
        guard let index else { return [] }
        var words = index.prefixSuggestions(for: composition, limit: limit).map(\.word)
        if words.isEmpty {
            words = index.correctionSuggestions(for: composition, limit: limit).map(\.word)
        }
        return words
    }

    public func bestCorrection(for word: String) -> String? {
        suggestionIndex()?.bestCorrection(for: word)?.word
    }

    private func suggestionIndex() -> TypingSuggestionIndex? {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .loading(let suggestions), .failed(_, let suggestions): return suggestions
        case .ready(_, let suggestions): return suggestions
        case .unloaded: return nil
        }
    }
}
