import Foundation

/// One recording, from the moment it stops until its text is inserted or dropped.
/// Cancelling marks the take, not the app, so a new recording started while a cancelled
/// one is still transcribing cannot bring the cancelled text back.
final class DictationTake: @unchecked Sendable {
    private let lock = NSLock()
    private var discarded: Bool

    init(discarded: Bool = false) {
        self.discarded = discarded
    }

    var isDiscarded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return discarded
    }

    func discard() {
        lock.lock()
        discarded = true
        lock.unlock()
    }
}

/// The most recently cancelled dictation, held in memory so a shortcut can bring it back.
/// It is replaced by the next cancelled dictation and is gone when the app quits.
enum DiscardedDictation {
    static func remembering(_ text: String, over current: String?) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? current : text
    }

    /// A cancelled take is transcribed only so it can be recovered; its audio and
    /// transcript never reach the recordings folder, whatever the saving preference.
    static func keepsRecording(savingEnabled: Bool, discarded: Bool) -> Bool {
        savingEnabled && !discarded
    }
}
