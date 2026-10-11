import Foundation

/// Something that can listen to a word said several times and report each hearing.
protocol ReplacementCapturing: AnyObject {
    /// `onProgress` reports how many repeats have been heard so far; `completion` delivers
    /// the distinct hearings as normalised triggers. Both arrive on the main queue.
    func start(onProgress: @escaping (Int) -> Void,
               completion: @escaping (Result<[String], ReplacementCaptureFailure>) -> Void)
    /// Stop listening now and report what was heard so far.
    func stop()
    /// Stop listening and report nothing.
    func cancel()
}

enum ReplacementCaptureFailure: Error, Equatable {
    case busy, noMicrophone, couldNotRecord, nothingHeard

    var message: String {
        switch self {
        case .busy: return "Finish the current dictation first."
        case .noMicrophone: return "speakfree needs microphone access."
        case .couldNotRecord: return "Could not start recording."
        case .nothingHeard: return "Nothing was heard. Try again a little louder."
        }
    }
}

/// Teaching a replacement by voice: record through the app's own microphone path, split
/// the take wherever the speaker paused, and transcribe each repeat alone, so every way
/// the engine hears the word becomes a trigger. Nothing is inserted and nothing is kept.
final class ReplacementCapture: ReplacementCapturing {
    static let wantedRepeats = 5
    private static let maximumSeconds = 40.0

    private weak var app: AppDelegate?
    private var timer: Timer?
    private var preRoll = 0
    private var startedAt = Date()
    private var onProgress: ((Int) -> Void)?
    private var completion: ((Result<[String], ReplacementCaptureFailure>) -> Void)?

    init(app: AppDelegate) {
        self.app = app
    }

    func start(onProgress: @escaping (Int) -> Void,
               completion: @escaping (Result<[String], ReplacementCaptureFailure>) -> Void) {
        guard let app, timer == nil, app.canCaptureReplacement else {
            completion(.failure(.busy))
            return
        }
        guard Permissions.ensureMicrophoneForRecording() else {
            completion(.failure(.noMicrophone))
            return
        }
        do {
            try app.recorder.startRecording(to: Self.temporaryURL())
        } catch {
            completion(.failure(.couldNotRecord))
            return
        }
        app.replacementCaptureActive = true
        // Pre-listening hands over audio from before Record was pressed; leave it out.
        preRoll = app.recorder.currentSampleCount()
        startedAt = Date()
        self.onProgress = onProgress
        self.completion = completion
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        guard timer != nil else { return }
        finish(reporting: true)
    }

    func cancel() {
        guard timer != nil else { return }
        finish(reporting: false)
    }

    private func tick() {
        guard let app else { return }
        let heard = UtteranceSplitter.finishedCount(in: app.recorder.samples(after: preRoll))
        onProgress?(min(heard, Self.wantedRepeats))
        if heard >= Self.wantedRepeats || Date().timeIntervalSince(startedAt) > Self.maximumSeconds {
            finish(reporting: true)
        }
    }

    private func finish(reporting: Bool) {
        timer?.invalidate()
        timer = nil
        let completion = self.completion
        self.completion = nil
        onProgress = nil
        guard let app else { return }
        let recording = app.recorder.stopRecording()
        app.replacementCaptureActive = false
        if let recording { try? FileManager.default.removeItem(at: recording.url) }
        guard reporting, let completion else { return }
        guard let recording, let transcriber = app.transcriber else {
            completion(.failure(.couldNotRecord))
            return
        }
        let samples = Array(recording.samples.dropFirst(preRoll))
        let clips = UtteranceSplitter.utterances(in: samples)
            .prefix(Self.wantedRepeats)
            .map { UtteranceSplitter.clip($0, from: samples) }
        guard !clips.isEmpty else {
            completion(.failure(.nothingHeard))
            return
        }
        Task {
            var heard: [String] = []
            for clip in clips {
                // The engine's fallbacks read the audio from disk, so each repeat gets a
                // short-lived file of its own.
                let url = Self.temporaryURL()
                defer { try? FileManager.default.removeItem(at: url) }
                guard let writer = try? WavWriter(url: url) else { continue }
                try? writer.append(clip)
                writer.close()
                if let text = try? await transcriber.transcribe(audioURL: url, samples: clip) {
                    heard.append(text)
                }
            }
            let triggers = ReplacementRules.cleaned(heard)
            DispatchQueue.main.async {
                completion(triggers.isEmpty ? .failure(.nothingHeard) : .success(triggers))
            }
        }
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-replacement-\(UUID().uuidString).wav")
    }
}
