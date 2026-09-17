// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
import AppKit
import AVFoundation

public enum AudioCaptureDiagnostics {
    /// Bounded physical route check. Captures only in memory, saves no audio or
    /// transcripts, installs no hotkey, and never changes the user's configuration.
    public static func run() -> String {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return "{\"error\":\"Microphone permission is not granted to this build\"}"
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        AudioDeviceCatalog.startCache()
        let scanDeadline = Date().addingTimeInterval(3)
        while AudioDeviceCatalog.cachedInputDevices.isEmpty && Date() < scanDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let devices = AudioDeviceCatalog.cachedInputDevices
        var counts: [String: Int] = [:]
        var nonzero: [String: Int] = [:]
        var energy: [String: Double] = [:]
        var statuses: [String] = []
        let router = MicrophoneCaptureCoordinator(samples: { samples, source in
            counts[source, default: 0] += samples.count
            nonzero[source, default: 0] += samples.filter { $0 != 0 }.count
            energy[source, default: 0] += samples.reduce(0) { $0 + Double($1) * Double($1) }
        }, status: { statuses.append($0) })
        router.configure(devices: devices, systemDefault: AudioDeviceCatalog.cachedDefaultInput, pin: nil, prelisten: true)
        router.start()
        let start = Date()
        var began = false, ended = false
        while Date().timeIntervalSince(start) < 12 {
            let elapsed = Date().timeIntervalSince(start)
            if !began && elapsed >= 2 {
                began = true
                router.queue.async { router.setRecording(true) }
            }
            if !ended && elapsed >= 9 {
                ended = true
                router.queue.async { router.flush(); router.setRecording(false) }
                let base = MicrophoneCaptureCoordinator.routes(devices: devices, systemDefault: AudioDeviceCatalog.cachedDefaultInput, pin: nil).base
                router.configure(devices: devices, systemDefault: AudioDeviceCatalog.cachedDefaultInput, pin: base?.uid, prelisten: true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        router.stop()
        var result: [String: Any] = [:]
        router.queue.sync {
            result = ["elapsedSeconds": Date().timeIntervalSince(start),
                      "emittedSeconds": Double(counts.values.reduce(0, +)) / 16_000,
                      "samplesBySource": counts, "routeMessages": statuses,
                      "nonzeroSamplesBySource": nonzero,
                      "availableInputs": devices.map(\.name)]
            result["rmsBySource"] = Dictionary(uniqueKeysWithValues: counts.map { ($0.key, sqrt((energy[$0.key] ?? 0) / Double(max(1, $0.value)))) })
        }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        return String(bytes: data, encoding: .utf8)!
    }
}
