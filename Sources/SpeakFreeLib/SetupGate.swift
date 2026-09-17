// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import Foundation

/// Coalesces settings changes while startup is using shared application state.
final class SetupGate {
    private let lock = NSLock()
    private var running = false
    private var pending = false

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { pending = true; return false }
        running = true
        return true
    }

    func deferReloadIfRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        pending = true
        return true
    }

    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        running = false
        defer { pending = false }
        return pending
    }
}
