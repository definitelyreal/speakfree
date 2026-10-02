// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import Foundation

struct LegacyQuitEnvironment {
    struct Application {
        let pid: pid_t
        let bundleIdentifier: String?
        let executableURL: URL?
        let terminate: () -> Bool
    }
    let installedCommit: () -> String?
    let application: (pid_t) -> Application?

    static var live: Self {
        Self(installedCommit: {
            let url = URL(fileURLWithPath: "/Applications/speakfree.app/Contents/Info.plist")
            guard let data = try? Data(contentsOf: url),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any] else { return nil }
            return info["SFBuildCommit"] as? String
        }, application: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
            return Application(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                               executableURL: app.executableURL, terminate: { app.terminate() })
        })
    }
}

enum LegacyQuitResult: Equatable { case requested, wrongBuild, wrongProcess, refused }

/// Compatibility bridge for the exact build whose SIGTERM handler can starve its
/// asynchronous history drain. A normal AppKit quit enters outside that handler.
public enum LegacyDeploymentQuit {
    static func pid(arguments: [String]) -> pid_t? {
        guard arguments.count == 2, arguments[0] == "--pid",
              let value = Int32(arguments[1]), value > 0 else { return nil }
        return value
    }

    static func request(pid: pid_t, environment: LegacyQuitEnvironment) -> LegacyQuitResult {
        guard environment.installedCommit() == "9f4f749" else { return .wrongBuild }
        guard pid > 0, let app = environment.application(pid), app.pid == pid,
              app.bundleIdentifier == "com.definitelyreal.speakfree",
              app.executableURL?.standardizedFileURL ==
                URL(fileURLWithPath: "/Applications/speakfree.app/Contents/MacOS/speakfree") else {
            return .wrongProcess
        }
        return app.terminate() ? .requested : .refused
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let pid = pid(arguments: arguments) else {
            fputs("Usage: speakfree quit-legacy-installed --pid PID\n", stderr)
            return 64
        }
        guard (ProcessInfo.processInfo.environment["SPEAKFREE_CONFIG_DIR"] ?? "").isEmpty else {
            fputs("Legacy quit refused: unset SPEAKFREE_CONFIG_DIR before deployment.\n", stderr)
            return 1
        }
        switch request(pid: pid, environment: .live) {
        case .requested:
            print("SPEAKFREE_LEGACY_QUIT_REQUESTED")
            return 0
        case .wrongBuild:
            fputs("Legacy quit refused: installed SFBuildCommit is not 9f4f749. Recheck the installed build before retrying.\n", stderr)
            return 2
        case .wrongProcess:
            fputs("Legacy quit refused: PID, bundle ID, or installed executable identity did not match. Recheck the running app before retrying.\n", stderr)
            return 3
        case .refused:
            fputs("The installed app refused the normal quit request. Resolve its pending work and retry; no signal or force quit was attempted.\n", stderr)
            return 4
        }
    }
}
