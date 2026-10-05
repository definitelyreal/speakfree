// ai-suggestion:unverified · 2026-09-24
import Foundation

// Pure decision rules around "Stay on <headset>": when to show the headset-connected
// notice, when a take counts as lost to a noisy room, what is playing on the headset,
// and whether to switch or only offer. No CoreAudio, no UI, no clocks of their own.

// MARK: - Headset-connected notice cadence

/// Per-headset history for the connect notice, keyed by the headset's UID.
public struct HeadsetNoticeRecord: Codable, Equatable, Sendable {
    public var shows = 0
    /// Showings since the person last used Stay on for this headset.
    public var ignoredStreak = 0
    public var lastShown: Date?
    public var lastUsed: Date?
    public var dismissedForever = false
    public init() {}
}

public enum HeadsetNoticeStyle: Equatable, Sendable {
    case none
    /// First two connections: larger, fuller contrast, about 8 seconds.
    case full
    /// Later: smaller and lighter, about 4 seconds.
    case compact
}

public enum HeadsetNoticePolicy {
    /// A connection counts only once the headset has stayed connected this long.
    public static let settleSeconds: TimeInterval = 20
    public static let recentUse: TimeInterval = 7 * 86400
    /// Back-off after three ignored showings in a row: 1 day, 3 days, then weekly.
    public static let backoff: [TimeInterval] = [86400, 3 * 86400, 7 * 86400]

    public static func style(for r: HeadsetNoticeRecord, now: Date, hasMic: Bool,
                             stayOnActiveForThisHeadset: Bool) -> HeadsetNoticeStyle {
        guard hasMic, !stayOnActiveForThisHeadset, !r.dismissedForever else { return .none }
        if r.shows < 2 { return .full }
        if let used = r.lastUsed, now.timeIntervalSince(used) < recentUse { return .compact }
        if r.ignoredStreak >= 3 {
            let wait = backoff[min(r.ignoredStreak - 3, backoff.count - 1)]
            guard let last = r.lastShown, now.timeIntervalSince(last) >= wait else { return .none }
        }
        return .compact
    }

    /// "Don't show again" appears from the third showing on.
    public static func offersDontShowAgain(_ r: HeadsetNoticeRecord) -> Bool { r.shows >= 2 }

    public static func shown(_ r: inout HeadsetNoticeRecord, now: Date) {
        r.shows += 1; r.ignoredStreak += 1; r.lastShown = now
    }

    /// Any use of Stay on for this headset, from the notice or the menu, at any time.
    public static func used(_ r: inout HeadsetNoticeRecord, now: Date) {
        r.ignoredStreak = 0; r.lastUsed = now
    }
}

// MARK: - Lost take in a noisy room

/// The outcome-based trigger from the design research: a take of 8 seconds or more,
/// recorded in a noisy room (quiet tenth louder than -48 dBFS), whose final text
/// (after the engine's own empty-result retries) is under 2 characters per second.
public enum LostTakeDetector {
    public static let minSeconds: Double = 8
    public static let noisyFloorDBFS: Double = -48
    public static let maxCharsPerSecond: Double = 2

    public static func isLost(durationSeconds: Double, noiseFloorDBFS: Double, transcriptChars: Int) -> Bool {
        // At least one character: a take that produced nothing at all is more likely an
        // accidental hold with nobody speaking than speech lost to noise.
        guard durationSeconds >= minSeconds, noiseFloorDBFS > noisyFloorDBFS, transcriptChars > 0 else { return false }
        return Double(transcriptChars) / durationSeconds < maxCharsPerSecond
    }

    /// 10th percentile of 100 ms loudness readings, in dBFS. nil for under one window.
    public static func noiseFloorDBFS(samples: [Float], sampleRate: Int = 16_000) -> Double? {
        let window = sampleRate / 10
        guard window > 0, samples.count >= window else { return nil }
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / window)
        var i = 0
        while i + window <= samples.count {
            var sum: Double = 0
            for j in i..<(i + window) { let v = Double(samples[j]); sum += v * v }
            let rms = (sum / Double(window)).squareRoot()
            levels.append(20 * log10(max(rms, 1e-9)))
            i += window
        }
        levels.sort()
        return levels[Int(Double(levels.count - 1) * 0.1)]
    }
}

// MARK: - What is playing on the headset

/// One app's use of the audio system, as CoreAudio's process objects report it.
public struct AudioProcessUse: Equatable, Sendable {
    public var bundleID: String
    public var inputOnHeadset: Bool
    public var outputOnHeadset: Bool
    /// Recording from any microphone (a browser call that uses the Mac mic).
    public var inputAnywhere: Bool
    public init(bundleID: String, inputOnHeadset: Bool = false, outputOnHeadset: Bool = false,
                inputAnywhere: Bool = false) {
        self.bundleID = bundleID; self.inputOnHeadset = inputOnHeadset
        self.outputOnHeadset = outputOnHeadset; self.inputAnywhere = inputAnywhere || inputOnHeadset
    }
}

public enum HeadsetPlayback: Equatable, Sendable {
    /// The audio process/route probe was incomplete; ask before changing the headset mode.
    case unknown
    case idle
    /// A call: the headset is already in call mode, switching costs nothing.
    case call
    /// Music, video or anything unknown: switching would drop it to call quality.
    case media
}

public enum HeadsetPlaybackClassifier {
    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.apple.avconferenced", "com.apple.FaceTime", "com.skype.skype",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.apple.WebKit.GPU", "com.apple.Safari",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Chrome, Slack and other Electron apps play through "<app id>.helper" processes.
    public static func appID(_ bundleID: String) -> String {
        var id = bundleID
        while let r = id.range(of: ".helper", options: [.caseInsensitive, .backwards]), r.upperBound == id.endIndex {
            id = String(id[..<r.lowerBound])
        }
        return id
    }

    public static func classify(_ uses: [AudioProcessUse], ownBundleID: String?) -> HeadsetPlayback {
        let others = uses.filter { appID($0.bundleID) != ownBundleID.map(appID) }
        if others.contains(where: { $0.inputOnHeadset }) { return .call }
        let playing = others.filter { $0.outputOnHeadset }
        guard !playing.isEmpty else { return .idle }
        var sawMedia = false
        for use in playing {
            let id = appID(use.bundleID)
            if callApps.contains(id) { continue }
            if browsers.contains(id) {
                let recording = others.contains { appID($0.bundleID) == id && $0.inputAnywhere }
                if recording { continue }
            }
            sawMedia = true
        }
        return sawMedia ? .media : .call
    }
}

// MARK: - After a lost take: switch, offer, or advise

public enum LostTakeResponse: Equatable, Sendable {
    /// Start Stay on for the default time and say so, with Undo.
    case switchNow
    /// Music is playing on the headset: ask instead of switching.
    case offer
    /// No headset with a mic: advice only, no button.
    case advise
    case nothing
}

public enum LostTakeResponder {
    public static let adviceCooldown: TimeInterval = 3600
    /// After an Undo, ask instead of switching for this long.
    public static let undoMemory: TimeInterval = 24 * 3600

    public static func respond(headsetWithMic: Bool, playback: HeadsetPlayback, stayOnActive: Bool,
                               lastAdvice: Date?, now: Date) -> LostTakeResponse {
        if stayOnActive { return .nothing }
        if headsetWithMic {
            return playback == .media || playback == .unknown ? .offer : .switchNow
        }
        if let last = lastAdvice, now.timeIntervalSince(last) < adviceCooldown { return .nothing }
        return .advise
    }
}
