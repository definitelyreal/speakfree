// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

#if DEBUG
import Foundation
import SpeakFreeKeyboardCore

/// Deterministic cross-process fixture used only by the Simulator UI suite. It exercises the
/// production App Group transport and keyboard revision planner without pretending that simulated
/// microphone input validates physical-device audio capture or Parakeet performance.
enum DictationUITestFixture {
    private static var didStart = false

    @MainActor
    static func startIfRequested() {
        guard !didStart,
              ProcessInfo.processInfo.arguments.contains("-SpeakFreeDictationUITestFixture"),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.speakfree.keyboard"
              ) else { return }
        didStart = true

        let store = DictationSnapshotStore(appGroupContainerURL: container)
        let sessionID = UUID()
        let createdAt = Date()
        // A Debug-only generation token tells the extension to discard its private claim receipt,
        // keeping repeated UI runs isolated without granting App Group write access to the keyboard.
        try? Data(UUID().uuidString.utf8).write(
            to: container.appendingPathComponent("speakfree-dictation-ui-test-reset"),
            options: .atomic
        )
        try? store.remove()
        try? store.write(snapshot(
            sessionID: sessionID,
            revision: 0,
            createdAt: createdAt,
            finalized: [],
            volatile: [DictationSegment(id: "tail", text: "hello wor")]
        ))

        Task.detached {
            // UI automation needs several seconds to reveal the lab field and select the custom
            // keyboard. Hold the first partial long enough to prove the initial claim separately
            // from the subsequent revision.
            // Keep the fixture's active lease fresh before the UI suite finishes selecting the
            // extension. A 15-second first update races the production 15-second freshness gate.
            try? await Task.sleep(for: .seconds(12))
            try? store.write(snapshot(
                sessionID: sessionID,
                revision: 1,
                createdAt: createdAt,
                finalized: [],
                volatile: [DictationSegment(id: "tail", text: "hello world")]
            ))
            try? await Task.sleep(for: .seconds(2))
            try? store.write(snapshot(
                sessionID: sessionID,
                revision: 2,
                createdAt: createdAt,
                finalized: [DictationSegment(id: "stable", text: "hello world")],
                volatile: [DictationSegment(id: "tail2", text: " from")]
            ))
            try? await Task.sleep(for: .seconds(2))
            try? store.write(snapshot(
                sessionID: sessionID,
                revision: 3,
                createdAt: createdAt,
                phase: .finalized,
                finalized: [
                    DictationSegment(id: "stable", text: "hello world"),
                    DictationSegment(id: "finish", text: " from SpeakFree")
                ],
                volatile: []
            ))
        }
    }

    private static func snapshot(
        sessionID: UUID,
        revision: UInt64,
        createdAt: Date,
        phase: DictationSessionPhase = .active,
        finalized: [DictationSegment],
        volatile: [DictationSegment]
    ) -> DictationSnapshot {
        DictationSnapshot(
            sessionID: sessionID,
            revision: revision,
            createdAt: createdAt,
            updatedAt: Date(),
            phase: phase,
            finalizedSegments: finalized,
            volatileSegments: volatile
        )
    }
}
#endif
