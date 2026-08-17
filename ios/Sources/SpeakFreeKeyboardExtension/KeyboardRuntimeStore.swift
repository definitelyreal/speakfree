// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation
import SpeakFreeKeyboardCore

enum KeyboardSwipeDecodeResult {
    case success([SwipeCandidate])
    case unavailable(String)
}

/// Process-wide owner for the expensive model, trie, and suggestion index. iOS can retain and
/// recreate many keyboard controllers while switching hosts; controller-local ownership multiplies
/// memory and makes late inference callbacks target stale document proxies.
final class KeyboardRuntimeStore {
    static let shared = KeyboardRuntimeStore()

    private enum State {
        case unloaded
        case loading(TypingSuggestionIndex?)
        case ready(decoder: SwipeDecoder, suggestions: TypingSuggestionIndex)
        case failed(String, TypingSuggestionIndex?)
    }

    private let stateLock = NSLock()
    private let loadQueue = DispatchQueue(label: "com.speakfree.keyboard.runtime.load", qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(label: "com.speakfree.keyboard.runtime.inference", qos: .userInitiated)
    private var state: State = .unloaded

    private init() {}

    func prepare(bundle: Bundle = .main, retryAfterFailure: Bool = false) {
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
                let entries = try EnglishVocabularyLoader.loadEntries(bundle: bundle)
                if suggestions == nil {
                    suggestions = TypingSuggestionIndex(entries: entries)
                }
                stateLock.lock()
                state = .loading(suggestions)
                stateLock.unlock()

                let runtime = try FUTOSwipeEncoderRuntime(bundle: bundle)
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
                let message = error.localizedDescription
                stateLock.lock()
                state = .failed(message, suggestions)
                stateLock.unlock()
            }
        }
    }

    func decode(
        points: [TrajectoryPoint],
        keyboardSize: KeyboardSize,
        candidateLimit: Int,
        completion: @escaping (KeyboardSwipeDecodeResult) -> Void
    ) {
        prepare(retryAfterFailure: true)
        // Serializing this handoff behind the load queue makes a first-use swipe wait for model
        // initialization instead of being decoded as a geometric fallback.
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
                DispatchQueue.main.async {
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
                    DispatchQueue.main.async { completion(.success(candidates)) }
                } catch {
                    DispatchQueue.main.async { completion(.unavailable(error.localizedDescription)) }
                }
            }
        }
    }

    func suggestions(for composition: String, limit: Int = 3) -> [String] {
        stateLock.lock()
        let index: TypingSuggestionIndex?
        switch state {
        case .loading(let suggestions): index = suggestions
        case .ready(_, let suggestions): index = suggestions
        case .failed(_, let suggestions): index = suggestions
        case .unloaded: index = nil
        }
        stateLock.unlock()
        guard let index else { return [] }
        var words = index.prefixSuggestions(for: composition, limit: limit).map(\.word)
        if words.isEmpty {
            words = index.correctionSuggestions(for: composition, limit: limit).map(\.word)
        }
        return words
    }

    func bestCorrection(for word: String) -> String? {
        stateLock.lock()
        let index: TypingSuggestionIndex?
        switch state {
        case .loading(let suggestions): index = suggestions
        case .ready(_, let suggestions): index = suggestions
        case .failed(_, let suggestions): index = suggestions
        case .unloaded: index = nil
        }
        stateLock.unlock()
        return index?.bestCorrection(for: word)?.word
    }
}
