// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation
import SpeakFreeKeyboardCore

/// Process-wide owner for the expensive model and vocabulary services. iOS can retain and
/// recreate many keyboard controllers while switching hosts; controller-local ownership
/// multiplies memory and makes late inference callbacks target stale document proxies.
final class KeyboardRuntimeStore {
    static let shared = KeyboardRuntimeStore()

    private let coordinator: SwipeRuntimeCoordinator

    private init() {
        coordinator = SwipeRuntimeCoordinator(
            vocabularyLoader: { try EnglishVocabularyLoader.loadEntries(bundle: .main) },
            runtimeLoader: { try FUTOSwipeEncoderRuntime(bundle: .main) }
        )
    }

    func prepare(retryAfterFailure: Bool = false) {
        coordinator.prepare(retryAfterFailure: retryAfterFailure)
    }

    func decode(
        points: [TrajectoryPoint],
        keyboardSize: KeyboardSize,
        candidateLimit: Int,
        completion: @escaping (SwipeRuntimeDecodeResult) -> Void
    ) {
        coordinator.decode(
            points: points,
            keyboardSize: keyboardSize,
            candidateLimit: candidateLimit,
            completion: completion
        )
    }

    func suggestions(for composition: String, limit: Int = 3) -> [String] {
        coordinator.suggestions(for: composition, limit: limit)
    }

    func bestCorrection(for word: String) -> String? {
        coordinator.bestCorrection(for: word)
    }
}
