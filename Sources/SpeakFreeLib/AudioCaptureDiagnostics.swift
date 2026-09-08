// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
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
        var statuses: [String] = []
        let router = MicrophoneCaptureCoordinator(samples: { samples, source in counts[source, default: 0] += samples.count }, status: { statuses.append($0) })
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
                      "availableInputs": devices.map(\.name)]
        }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
