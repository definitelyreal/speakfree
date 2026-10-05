// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit

enum ApplicationTermination {
    /// A terminateLater reply pumps a nested AppKit loop. Entering that loop from
    /// a main-dispatch callback prevents the queue from draining shutdown work.
    /// Enter from the run loop instead, after the dispatch callback has returned.
    static func request(_ application: NSApplication? = nil) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            (application ?? NSApplication.shared).terminate(nil)
        }
        CFRunLoopWakeUp(runLoop)
    }
}
