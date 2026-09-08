// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import Foundation

/// Control state and sample delivery are serial; hardware workers never run here.
/// sync() is safe for recording boundaries because this queue does no driver I/O.
final class MicrophoneCaptureCoordinator {
    let queue = DispatchQueue(label: "com.speakfree.capturerouting", qos: .userInitiated)
    private let factory: () -> DeviceCapturing
    private let refresh: () -> Void
    private let now: () -> Double
    private let onSamples: ([Float], String) -> Void
    private let onStatus: (String) -> Void
    private var devices: [AudioInputDevice] = []
    private var systemDefault: AudioInputDevice?
    private var pin: String?
    private var prelisten = true
    private var recording = false
    private var enabled = false
    private var suspended = false
    private var lastRecordingEnd = -Double.infinity
    private var base: AudioInputDevice?
    private var preferred: AudioInputDevice?
    private var timeline = CaptureTimeline()
    private var timer: DispatchSourceTimer?
    private var status = ""
    private var sessions: [String: Entry] = [:]
    private var retries: [String: Int] = [:]
    private var retryAfter: [String: Double] = [:]
    private var lastSource = "Microphone connecting"
    static let idleSeconds: Double = 30

    private struct Entry {
        let generation: UUID
        let device: AudioInputDevice
        let session: DeviceCapturing
        let started: Double
        var lastPacket: Double?
    }

    init(factory: @escaping () -> DeviceCapturing = { DeviceAudioSession() },
         samples: @escaping ([Float], String) -> Void, status: @escaping (String) -> Void,
         refresh: @escaping () -> Void = { AudioDeviceCatalog.refreshNow() },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.factory = factory
        self.refresh = refresh
        self.now = now
        self.onSamples = samples
        self.onStatus = status
    }

    static func routes(devices: [AudioInputDevice], systemDefault: AudioInputDevice?, pin: String?)
        -> (base: AudioInputDevice?, preferred: AudioInputDevice?) {
        let base = devices.first { $0.isBuiltIn }
            ?? devices.first { $0.uid == pin && !$0.isBluetooth }
            ?? systemDefault.flatMap { d in devices.first { $0.uid == d.uid && !$0.isBluetooth && !$0.isVirtual } }
            ?? devices.first { !$0.isBluetooth && !$0.isVirtual }
            ?? systemDefault.flatMap { d in devices.first { $0.uid == d.uid } }
            ?? devices.first
        let preferred: AudioInputDevice?
        if let pin { preferred = devices.first { $0.uid == pin } ?? base }
        else { preferred = devices.first { $0.isBluetooth } ?? base }
        return (base, preferred)
    }

    func configure(devices: [AudioInputDevice], systemDefault: AudioInputDevice?, pin: String?, prelisten: Bool) {
        queue.async {
            let oldRoutes = Self.routes(devices: self.devices, systemDefault: self.systemDefault, pin: self.pin)
            let newRoutes = Self.routes(devices: devices, systemDefault: systemDefault, pin: pin)
            let changed = oldRoutes.base != newRoutes.base || oldRoutes.preferred != newRoutes.preferred || self.pin != pin
            self.devices = devices; self.systemDefault = systemDefault
            self.pin = pin; self.prelisten = prelisten
            if changed { self.retries = [:]; self.retryAfter = [:] }
            self.reconcile()
        }
    }

    func start() {
        queue.async {
            guard !self.enabled else { return }
            self.enabled = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkHealth() }
            self.timer = timer; timer.resume()
            self.reconcile()
        }
    }

    func stop() {
        queue.async {
            self.enabled = false
            self.timer?.cancel(); self.timer = nil
            for entry in self.sessions.values { entry.session.stop() }
            self.sessions = [:]; self.timeline.reset()
        }
    }

    /// Called inside the short, driver-free recording boundary on queue.
    func setRecording(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        recording = value
        if !value { lastRecordingEnd = now() }
        if value { retries = [:]; retryAfter = [:] }
        reconcile()
    }

    func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        emit(timeline.flush(), source: base?.name ?? lastSource)
    }

    func recover() {
        queue.async {
            self.retries = [:]; self.retryAfter = [:]
            self.checkHealth()
        }
    }

    func suspend() {
        queue.async {
            self.suspended = true
            for uid in Array(self.sessions.keys) { self.remove(uid) }
            self.timeline.reset()
        }
    }

    func resume() {
        queue.async {
            self.suspended = false
            for uid in Array(self.sessions.keys) { self.remove(uid) }
            self.timeline.reset(); self.retries = [:]; self.retryAfter = [:]
            self.reconcile()
        }
    }

    private func reconcile() {
        guard enabled, !suspended else { return }
        let now = self.now()
        let routes = Self.routes(devices: devices, systemDefault: systemDefault, pin: pin)
        let oldBase = base?.uid, oldPreferred = preferred?.uid
        base = routes.base; preferred = routes.preferred
        if oldPreferred != preferred?.uid { emit(timeline.useBase(), source: base?.name ?? lastSource) }
        if oldBase != base?.uid { timeline.reset() }
        var desired: [AudioInputDevice] = []
        if prelisten || recording, let base { desired.append(base) }
        if let preferred, preferred.uid != base?.uid,
           recording || (prelisten && (!preferred.isBluetooth || now - lastRecordingEnd < Self.idleSeconds)) {
            desired.append(preferred)
        }
        for (uid, entry) in sessions {
            if !desired.contains(where: { $0.uid == uid && $0.id == entry.device.id && $0.nominalSampleRate == entry.device.nominalSampleRate }) {
                remove(uid)
            }
        }
        for device in desired where sessions[device.uid] == nil {
            guard (retries[device.uid] ?? 0) < 4, now >= (retryAfter[device.uid] ?? 0) else { continue }
            let generation = UUID(), session = factory()
            sessions[device.uid] = Entry(generation: generation, device: device, session: session, started: now)
            session.start(device: device, packet: { [weak self] packet in
                self?.queue.async { [weak self] in self?.receive(packet, uid: device.uid, generation: generation) }
            }, failure: { [weak self] reason in
                self?.queue.async { [weak self] in self?.failed(device.uid, generation: generation, reason: reason) }
            })
        }
        updateStatus()
    }

    private func remove(_ uid: String) {
        guard let entry = sessions.removeValue(forKey: uid) else { return }
        entry.session.stop()
        if uid == preferred?.uid { emit(timeline.useBase(), source: base?.name ?? lastSource) }
    }

    private func receive(_ packet: CapturePacket, uid: String, generation: UUID) {
        guard var entry = sessions[uid], entry.generation == generation, enabled else { return }
        entry.lastPacket = now()
        sessions[uid] = entry
        // Reset retries only after sustained successful capture, not one stray buffer.
        if entry.lastPacket! - entry.started > 5 { retries[uid] = 0 }
        let samples = uid == base?.uid ? timeline.receiveBase(packet) : timeline.receiveSecondary(packet)
        emit(samples, source: entry.device.name)
        updateStatus()
    }

    private func emit(_ samples: [Float], source: String) {
        guard !samples.isEmpty else { return }
        lastSource = source
        onSamples(samples, source)
    }

    private func failed(_ uid: String, generation: UUID, reason: String) {
        guard sessions[uid]?.generation == generation else { return }
        DiagnosticLogger.shared.log("Capture: \(sessions[uid]!.device.name) failed: \(reason); preserving fallback")
        remove(uid)
        refresh()
        let count = (retries[uid] ?? 0) + 1
        retries[uid] = count
        retryAfter[uid] = now() + min(4, Double(count) * 0.5)
        updateStatus()
    }

    private func checkHealth() {
        guard enabled, !suspended else { return }
        let now = self.now()
        for (uid, entry) in sessions {
            let age = now - (entry.lastPacket ?? entry.started)
            let allowance = entry.lastPacket == nil ? 5.0 : 1.5
            if age > allowance { failed(uid, generation: entry.generation, reason: "No valid audio for \(String(format: "%.1f", age)) seconds") }
        }
        reconcile()
    }

    private func updateStatus() {
        let message: String
        if !prelisten && !recording { message = "Pre-listening off" }
        else if sessions[base?.uid ?? ""]?.lastPacket == nil && sessions[preferred?.uid ?? ""]?.lastPacket == nil {
            message = recording ? "Microphone connecting — audio not ready yet" : "Starting pre-listening…"
        }
        else if let pin, !devices.contains(where: { $0.uid == pin }) {
            message = "Selected microphone disconnected — using \(base?.name ?? "available microphone")"
        }
        else if let preferred, preferred.uid != base?.uid {
            if sessions[preferred.uid]?.lastPacket != nil {
                message = "Using \(preferred.name) · pre-listening protected by \(base?.name ?? "fallback microphone")"
            } else if recording {
                message = "Using \(base?.name ?? "fallback microphone") while \(preferred.name) connects…"
            } else {
                message = "Pre-listening: \(base?.name ?? "microphone") · dictation: \(preferred.name)"
            }
        } else { message = "Pre-listening: \(base?.name ?? "waiting for microphone")" }
        guard message != status else { return }
        status = message
        DiagnosticLogger.shared.log("Capture route: \(message)")
        onStatus(message)
    }
}
