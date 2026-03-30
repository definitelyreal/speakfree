import AppKit
import AVFoundation
import ApplicationServices
import Foundation

struct Permissions {
    static func ensureMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("Microphone: granted")
        case .notDetermined:
            print("Microphone: requesting...")
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Microphone: \(granted ? "granted" : "denied")")
                semaphore.signal()
            }
            semaphore.wait()
        default:
            print("Microphone: denied — grant in System Settings → Privacy & Security → Microphone")
        }
    }

    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.definitelyreal.speakfree"]
        try? process.run()
        process.waitUntilExit()
    }

    static func didUpgrade() -> Bool {
        // Ad-hoc signed builds (including bundle-app.sh dev builds) change code
        // identity on every rebuild, which invalidates TCC accessibility grants.
        // We ALWAYS check the binary fingerprint to catch this. Version-based
        // checking alone only works for stable Developer ID signed releases.
        //
        // BUILD PROCESS NOTE:
        // - `scripts/build.sh` signs with Developer ID → stable signature across rebuilds
        // - `scripts/bundle-app.sh` ad-hoc signs (`codesign --sign -`) → NEW signature every time
        // - Ad-hoc builds MUST go through fingerprint check or accessibility breaks
        // - The fingerprint is stored in ~/.config/speakfree/.binary-fingerprint
        // - When fingerprint changes, we call tccutil reset to clear the stale TCC entry
        //   and then re-prompt for accessibility permission
        if didBetaBinaryChange() {
            return true
        }

        let versionFile = Config.configDir.appendingPathComponent(".last-version")
        let current = OpenWispr.version
        let previous = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Always write the current version
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        try? current.write(to: versionFile, atomically: true, encoding: .utf8)

        if previous == current {
            return false
        }

        // First launch (no previous version file) is not an upgrade
        guard previous != nil else { return false }

        return true
    }

    /// Check if the binary changed since last launch by comparing
    /// a simple file size + modification date fingerprint.
    /// Used for ALL builds (not just beta) because ad-hoc signing
    /// produces a new code identity on every rebuild.
    private static func didBetaBinaryChange() -> Bool {
        guard let execPath = Bundle.main.executablePath else { return false }

        let hashFile = Config.configDir.appendingPathComponent(".binary-fingerprint")
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)

        // Build a simple fingerprint from file size + modification date
        let attrs = try? FileManager.default.attributesOfItem(atPath: execPath)
        let size = attrs?[.size] as? Int ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let currentFingerprint = "\(size):\(Int(modified))"

        let previousFingerprint = try? String(contentsOf: hashFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Always write current fingerprint
        try? currentFingerprint.write(to: hashFile, atomically: true, encoding: .utf8)

        // First launch — not an upgrade
        guard let prev = previousFingerprint, !prev.isEmpty else { return false }

        if prev == currentFingerprint {
            return false
        }

        print("Beta binary changed — will reset accessibility")
        return true
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
