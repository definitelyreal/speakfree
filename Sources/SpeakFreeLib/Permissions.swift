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

    /// Gate a recording attempt on microphone authorization. Returns true only when recording
    /// can actually capture audio. On anything else it surfaces a user-visible prompt instead of
    /// letting dictation silently record silence:
    ///   - notDetermined: triggers the system permission prompt (user grants, then presses again)
    ///   - denied/restricted: shows an actionable alert with a link to System Settings
    ///
    /// Returns synchronously and never blocks — safe to call from inside the hotkey event-tap
    /// callback (a blocking modal there would make macOS disable the tap).
    static func ensureMicrophoneForRecording() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Shows the standard macOS microphone prompt. The current key press is abandoned;
            // once granted, the next press records normally.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return false
        default:
            // Defer the modal to the next main-loop tick so the event-tap callback returns now.
            DispatchQueue.main.async { showMicrophoneDeniedAlert() }
            return false
        }
    }

    /// Visible, actionable indication that the mic is off — the thing the app failed to show
    /// before, leaving dictation to fail silently.
    static func showMicrophoneDeniedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "speakfree can’t access the microphone"
        alert.informativeText = "Microphone access is turned off, so dictation records nothing. Turn it on in System Settings → Privacy & Security → Microphone, then try dictating again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
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
        // Only reset TCC when the VERSION changes (e.g. 1.2.3 → 1.2.4).
        // Developer ID signed builds keep the same code identity across rebuilds,
        // so the fingerprint check is unnecessary and causes repeated TCC resets.
        // Ad-hoc (beta) builds still track fingerprint separately.
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        if isBeta && didBetaBinaryChange() {
            return true
        }

        let versionFile = Config.configDir.appendingPathComponent(".last-version")
        let current = SpeakFree.version
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
