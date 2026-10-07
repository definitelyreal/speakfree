// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import Foundation

struct ClipyQuitEnvironment {
    struct Application {
        let pid: pid_t
        let isTerminated: () -> Bool
        let terminate: () -> Bool
    }
    let applications: () -> [Application]
    let uptime: () -> TimeInterval
    let wait: () -> Void

    static var live: Self {
        Self(applications: {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.clipy-app.Clipy")
                .filter { !$0.isTerminated }
                .map { app in
                    Application(pid: app.processIdentifier,
                                isTerminated: { app.isTerminated },
                                terminate: { app.terminate() })
                }
        }, uptime: { ProcessInfo.processInfo.systemUptime }, wait: {
            // NSRunningApplication updates termination state as the run loop runs.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        })
    }
}

enum ClipyQuitResult: Equatable {
    case stopped, refused, timedOut, relaunched
}

/// A deployment-only normal quit. Never sends signals or escalates to forceTerminate.
public enum DeploymentClipyQuit {
    static func timeout(arguments: [String]) -> TimeInterval? {
        if arguments.isEmpty { return 30 }
        guard arguments.count == 2, arguments[0] == "--timeout",
              let seconds = Int(arguments[1]), (1...60).contains(seconds) else { return nil }
        return TimeInterval(seconds)
    }

    static func quit(environment: ClipyQuitEnvironment, timeout: TimeInterval) -> ClipyQuitResult {
        let deadline = environment.uptime() + timeout
        let original = environment.applications()
        if original.isEmpty { return .stopped }
        let originalPIDs = Set(original.map(\.pid))
        for app in original {
            if environment.uptime() >= deadline { return .timedOut }
            if !app.isTerminated(), !app.terminate(), !app.isTerminated() { return .refused }
        }
        while true {
            let current = environment.applications()
            if current.isEmpty && original.allSatisfy({ $0.isTerminated() }) { return .stopped }
            if current.contains(where: { !originalPIDs.contains($0.pid) }) { return .relaunched }
            if environment.uptime() >= deadline { return .timedOut }
            environment.wait()
        }
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let timeout = timeout(arguments: arguments) else {
            fputs("Usage: speakfree quit-clipy [--timeout 1...60]\n", stderr)
            return 64
        }
        guard (ProcessInfo.processInfo.environment["SPEAKFREE_CONFIG_DIR"] ?? "").isEmpty else {
            fputs("Clipy was not asked to quit: unset SPEAKFREE_CONFIG_DIR before deployment.\n", stderr)
            return 1
        }
        switch quit(environment: .live, timeout: timeout) {
        case .stopped:
            print("SPEAKFREE_CLIPY_STOPPED")
            return 0
        case .refused:
            fputs("Clipy refused the normal quit request. Quit Clipy manually, then retry deployment; speakfree has not been stopped.\n", stderr)
            return 2
        case .timedOut:
            fputs("Clipy did not finish quitting within the deadline. Resolve any Clipy dialog and retry deployment; no force quit was attempted.\n", stderr)
            return 3
        case .relaunched:
            fputs("Clipy restarted while quitting. Stop its relaunch and retry deployment; no force quit was attempted.\n", stderr)
            return 4
        }
    }
}
