// ai-suggestion:unverified · 2026-09-24
import Foundation

/// How long "Stay on <headset>" lasts. The list, its order and the default are the
/// decided design (2026-09-22): four clock times, "until I turn it off", and two
/// natural end events.
public enum StayOnDuration: String, Codable, CaseIterable, Sendable {
    case oneHour = "1h"
    case twoHours = "2h"
    case sixHours = "6h"
    case twentyFourHours = "24h"
    case untilTurnedOff = "untilOff"
    case untilSleep = "untilSleep20"
    case untilRestart = "untilRestart"

    public static let standard: StayOnDuration = .twoHours
    /// Submenu groups, drawn with a separator between each group.
    public static let menuGroups: [[StayOnDuration]] = [
        [.oneHour, .twoHours, .sixHours, .twentyFourHours],
        [.untilTurnedOff],
        [.untilSleep, .untilRestart],
    ]

    public var menuTitle: String {
        switch self {
        case .oneHour: return "For 1 hour"
        case .twoHours: return "For 2 hours"
        case .sixHours: return "For 6 hours"
        case .twentyFourHours: return "For 24 hours"
        case .untilTurnedOff: return "Until I turn it off"
        case .untilSleep: return "Until computer sleeps for 20min"
        case .untilRestart: return "Until restart"
        }
    }

    /// Lower-case phrase used after "Stay on AirPods Pro ...".
    public var phrase: String {
        switch self {
        case .oneHour: return "for 1 hour"
        case .twoHours: return "for 2 hours"
        case .sixHours: return "for 6 hours"
        case .twentyFourHours: return "for 24 hours"
        case .untilTurnedOff: return "until you turn it off"
        case .untilSleep: return "until this Mac sleeps for 20 minutes"
        case .untilRestart: return "until restart"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .twoHours: return 2 * 3600
        case .sixHours: return 6 * 3600
        case .twentyFourHours: return 24 * 3600
        case .untilTurnedOff, .untilSleep, .untilRestart: return nil
        }
    }

    /// Durations that end when the computer restarts or the person logs out.
    public var endsOnRestart: Bool { self == .untilSleep || self == .untilRestart }
}

public enum StayOnEndReason: String, Codable, Sendable {
    case expired        // the chosen time ran out
    case turnedOff      // "End Stay on"
    case choseOtherMic  // picked another microphone
    case undone         // Undo on an automatic switch
    case sleptLong      // "Until computer sleeps for 20min" and it did
    case restarted      // the Mac restarted or shut down (a new boot session)
}

/// One Stay-on period for one physical headset (keyed by its CoreAudio UID).
public struct StayOnSession: Codable, Equatable, Sendable {
    public var deviceUID: String
    public var deviceName: String
    public var duration: StayOnDuration
    public var startedAt: Date
    public var expiresAt: Date?
    /// Identity of the boot this started in; a different boot means the Mac restarted.
    public var bootID: String?
    /// True when speakfree switched on its own after a lost take (Undo is offered).
    public var automatic: Bool
    /// Set while the headset is not connected. Disconnects never end the mode.
    public var absentSince: Date?
    /// Consecutive failed attempts to get audio from the headset mic.
    public var failures: Int
    /// While paused after a failure: when the next attempt may start. nil = routed.
    public var nextAttemptAt: Date?
    public var sleepStartedAt: Date?
}

public struct StayOnEnded: Codable, Equatable, Sendable {
    public var deviceUID: String
    public var deviceName: String
    public var reason: StayOnEndReason
    public var at: Date
}

/// What the menu and notices should say right now.
public enum StayOnStatus: Equatable, Sendable {
    case off
    case active(name: String, detail: String)
    case waitingForReconnect(name: String)
    case retrying(name: String, next: Date)
}

/// The "Stay on <headset>" state machine. Pure: every input (time, device presence,
/// sleep, boot identity, recording state, headset health) is passed in, so each rule
/// is unit-tested without CoreAudio, timers or a real Mac. `StayOnController` owns one,
/// feeds it events, persists it, and routes the capture coordinator from it.
public struct StayOnMode: Codable, Equatable, Sendable {
    public private(set) var session: StayOnSession?
    /// The most recent end, for "Stay on ended while this Mac was asleep".
    public private(set) var lastEnded: StayOnEnded?

    /// A sleep this long ends "Until computer sleeps for 20min"; a shorter one keeps it.
    public static let longSleep: TimeInterval = 20 * 60
    /// Retry schedule while the headset mic fails: 3 tries, wait 5 min, 3 tries, wait
    /// 20 min, then 3 tries an hour. Tries within a block are 30 s apart at minimum.
    public static let retryGap: TimeInterval = 30
    public static let blockWaits: [TimeInterval] = [5 * 60, 20 * 60, 60 * 60]
    /// How long an unexplained end stays visible in the first menu row.
    public static let endedNoticeWindow: TimeInterval = 30 * 60

    public init() {}

    public var isActive: Bool { session != nil }

    public func isActive(for uid: String) -> Bool { session?.deviceUID == uid }

    // MARK: - Starting and ending

    public mutating func start(deviceUID: String, deviceName: String, duration: StayOnDuration,
                               now: Date, bootID: String?, automatic: Bool = false) {
        session = StayOnSession(
            deviceUID: deviceUID, deviceName: deviceName, duration: duration, startedAt: now,
            expiresAt: duration.seconds.map { now.addingTimeInterval($0) }, bootID: bootID,
            automatic: automatic, absentSince: nil, failures: 0, nextAttemptAt: nil,
            sleepStartedAt: nil)
        lastEnded = nil
    }

    @discardableResult
    public mutating func end(_ reason: StayOnEndReason, now: Date) -> StayOnEnded? {
        guard let s = session else { return nil }
        let ended = StayOnEnded(deviceUID: s.deviceUID, deviceName: s.deviceName, reason: reason, at: now)
        session = nil
        lastEnded = ended
        return ended
    }

    // MARK: - Time

    /// Ends a clock duration whose time is up. A deadline that lands during a take
    /// waits for the take to finish. Also starts a due retry, but only between takes,
    /// so a headset cold start never eats the first words of a take.
    @discardableResult
    public mutating func tick(now: Date, recording: Bool) -> StayOnEnded? {
        guard var s = session else { return nil }
        if let expiresAt = s.expiresAt, now >= expiresAt, !recording {
            return end(.expired, now: now)
        }
        if let next = s.nextAttemptAt, now >= next, !recording, s.absentSince == nil {
            s.nextAttemptAt = nil
            session = s
        }
        return nil
    }

    // MARK: - Headset presence

    /// Disconnects never end the mode (they happen too often); it waits for the headset.
    /// A reconnect clears the failure history so the headset gets a fresh try.
    public mutating func devicesChanged(presentUIDs: Set<String>, now: Date) {
        guard var s = session else { return }
        if presentUIDs.contains(s.deviceUID) {
            if s.absentSince != nil {
                s.absentSince = nil
                s.failures = 0
                s.nextAttemptAt = nil
            }
        } else if s.absentSince == nil {
            s.absentSince = now
        }
        session = s
    }

    /// The device name can change (macOS renames "AirPods Pro" to "Sam's AirPods Pro").
    public mutating func deviceRenamed(to name: String) {
        guard var s = session, s.deviceName != name, !name.isEmpty else { return }
        s.deviceName = name
        session = s
    }

    // MARK: - Headset health (reported by the capture coordinator)

    public mutating func headsetFailed(now: Date) {
        guard var s = session, s.absentSince == nil, s.nextAttemptAt == nil else { return }
        s.failures += 1
        s.nextAttemptAt = now.addingTimeInterval(Self.retryDelay(afterFailures: s.failures))
        session = s
    }

    public mutating func headsetHealthy() {
        guard var s = session, s.failures != 0 || s.nextAttemptAt != nil else { return }
        s.failures = 0
        s.nextAttemptAt = nil
        session = s
    }

    public static func retryDelay(afterFailures n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        guard n % 3 == 0 else { return retryGap }
        let block = n / 3 - 1
        return blockWaits[min(block, blockWaits.count - 1)]
    }

    // MARK: - Sleep, restart, launch

    public mutating func sleepBegan(now: Date) {
        guard var s = session, s.sleepStartedAt == nil else { return }
        s.sleepStartedAt = now
        session = s
    }

    @discardableResult
    public mutating func sleepEnded(now: Date) -> StayOnEnded? {
        guard var s = session, let began = s.sleepStartedAt else { return nil }
        s.sleepStartedAt = nil
        session = s
        if s.duration == .untilSleep, now.timeIntervalSince(began) >= Self.longSleep {
            return end(.sleptLong, now: now)
        }
        return nil
    }

    /// Restart or shut down (the app detects it as a new boot session at launch).
    @discardableResult
    public mutating func poweringOff(now: Date) -> StayOnEnded? {
        guard let s = session, s.duration.endsOnRestart else { return nil }
        return end(.restarted, now: now)
    }

    /// On app launch: a session from an earlier boot ends if its duration ends on
    /// restart. Relaunching speakfree alone (an update, a crash) keeps every duration.
    @discardableResult
    public mutating func launched(bootID: String?, now: Date) -> StayOnEnded? {
        guard var s = session else { return nil }
        if s.duration.endsOnRestart, let bootID, s.bootID != bootID {
            return end(.restarted, now: now)
        }
        // A sleep that began before a quit is not evidence of anything after relaunch.
        s.sleepStartedAt = nil
        session = s
        return tick(now: now, recording: false)
    }

    // MARK: - Routing and status

    /// The headset UID the capture coordinator should route dictation to, or nil.
    public var routedHeadsetUID: String? {
        guard let s = session, s.absentSince == nil, s.nextAttemptAt == nil else { return nil }
        return s.deviceUID
    }

    public func status(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> StayOnStatus {
        guard let s = session else { return .off }
        if s.absentSince != nil { return .waitingForReconnect(name: s.deviceName) }
        if let next = s.nextAttemptAt { return .retrying(name: s.deviceName, next: next) }
        return .active(name: s.deviceName, detail: Self.detail(s, now: now, calendar: calendar, locale: locale))
    }

    /// A recent end the person did not cause, worth one line in the menu.
    public func recentUnexpectedEnd(now: Date) -> StayOnEnded? {
        guard session == nil, let e = lastEnded,
              [.expired, .sleptLong, .restarted].contains(e.reason),
              now.timeIntervalSince(e.at) < Self.endedNoticeWindow else { return nil }
        return e
    }

    public mutating func clearLastEnded() { lastEnded = nil }

    static func detail(_ s: StayOnSession, now: Date, calendar: Calendar, locale: Locale) -> String {
        switch s.duration {
        case .untilTurnedOff:
            return "on since " + clock(s.startedAt, now: now, calendar: calendar, locale: locale)
        case .untilSleep:
            return "until this Mac sleeps for 20 min"
        case .untilRestart:
            return "until restart"
        case .oneHour, .twoHours, .sixHours, .twentyFourHours:
            guard let expiresAt = s.expiresAt else { return "" }
            let left = expiresAt.timeIntervalSince(now)
            if left <= 60 { return "ending now" }
            if left < 3600 { return "\(Int((left / 60).rounded(.up))) min left" }
            return "until " + clock(expiresAt, now: now, calendar: calendar, locale: locale)
        }
    }

    /// "1:05am", or "Monday 1:05am" when not today.
    static func clock(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.dateFormat = "h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        let time = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let day = DateFormatter()
        day.calendar = calendar; day.locale = locale; day.timeZone = calendar.timeZone
        day.dateFormat = "EEEE"
        return day.string(from: date) + " " + time
    }
}

/// How the menu labels a headset: drop a leading "<Name>'s " and cut names longer than
/// about 24 characters in the middle, so both ends stay readable. VoiceOver and the
/// tooltip keep the full name.
public enum HeadsetLabel {
    public static let maxLength = 24

    public static func short(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        for apostrophe in ["'s ", "\u{2019}s "] {
            if let r = n.range(of: apostrophe), n.distance(from: n.startIndex, to: r.lowerBound) <= 20 {
                let rest = String(n[r.upperBound...])
                if !rest.isEmpty { n = rest }
                break
            }
        }
        guard n.count > maxLength else { return n }
        let keep = maxLength - 3
        let tailCount = min(8, keep / 2)
        let head = n.prefix(keep - tailCount)
        let tail = n.suffix(tailCount)
        return head.trimmingCharacters(in: .whitespaces) + "..." + tail.trimmingCharacters(in: .whitespaces)
    }
}
