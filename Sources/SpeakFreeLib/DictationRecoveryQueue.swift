// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-02
import Foundation

/// Failed delivery survives independently of optional History/recording retention.
/// Main-thread, memory-only, one dialog at a time. New capture is backpressured at
/// eight pending results or 1 MiB; already-in-flight results are never discarded.
final class DictationRecoveryQueue {
    var isAvailable: () -> Bool = { false }
    var present: (String, @escaping () -> Bool, @escaping (Bool) -> Void) -> Void = { _, _, finished in finished(false) }
    var schedule: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    private var pending: [String] = []
    private var bytes = 0
    private var scheduled = false
    private var presenting = false
    var hasPending: Bool { !pending.isEmpty }
    var blocksNewCapture: Bool { pending.count >= 8 || bytes >= 1_048_576 }

    func retain(_ text: String) {
        guard !text.isEmpty else { return }
        pending.append(text)
        bytes += text.utf8.count
        schedulePump()
    }

    private func schedulePump() {
        guard hasPending, !scheduled, !presenting else { return }
        scheduled = true
        schedule { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.pump()
        }
    }

    private func pump() {
        guard let text = pending.first, !presenting else { return }
        guard isAvailable() else { schedulePump(); return }
        presenting = true
        present(text, { [weak self] in self?.isAvailable() == true }, { [weak self] handled in
            guard let self else { return }
            if handled {
                self.bytes -= self.pending.removeFirst().utf8.count
            }
            self.presenting = false
            self.schedulePump()
        })
    }
}
