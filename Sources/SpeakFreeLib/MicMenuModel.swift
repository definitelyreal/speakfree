// ai-suggestion:unverified · 2026-09-24
import Foundation

/// The microphone block at the top of the menu-bar dropdown, as data. StatusBarController
/// draws it; tests check it. Layout follows the design review's recommended direction:
/// a first row that always says what is recording (with a bold notice line above it when
/// there is something to say), a "CHANGE TO" header, the wired mics, and for each headset
/// "Stay on <name> for 2 hours" (one click) plus "Other durations" (submenu, checkmark on
/// the default or the duration in use). Built from cached state only, never CoreAudio.
public struct MicMenuModel: Equatable {
    public enum NoticeKind: Equatable { case stayOn, info }

    public struct FirstRow: Equatable {
        /// Bold, icon-led line above the device, only when there is something to say.
        public var notice: String?
        public var noticeKind: NoticeKind = .info
        /// What is recording now.
        public var device: String
        /// A quiet third line (music on the Stay-on headset).
        public var detail: String?
    }

    public enum Row: Equatable {
        case microphone(uid: String, name: String, checked: Bool, selectsAutomatic: Bool)
        /// One click starts (or restarts) Stay on for the default duration.
        case stayOn(uid: String, name: String, title: String, enabled: Bool)
        /// Submenu of every duration; `checked` is the default or the one in use.
        case otherDurations(uid: String, name: String, checked: StayOnDuration)
        case endStayOn
        case noMicOffered(title: String)
    }

    public var firstRow: FirstRow
    public var rows: [Row]

    /// `automatic` is what dictation uses with Stay on off (the pin, else this Mac's mic);
    /// `automaticDefaultUID` is what it would use with no pin at all.
    public static func build(inputs: [AudioInputDevice], headsets: [ConnectedHeadset], automatic: AudioInputDevice?,
                             automaticDefaultUID: String?, pinnedUID: String?, stayOn: StayOnMode, status: StayOnStatus,
                             recentEnd: StayOnEnded?, musicOnStayOnHeadset: Bool) -> MicMenuModel {
        let wired = inputs.filter { !$0.isBluetooth && !$0.isVirtual }
        let session = stayOn.session
        let routed = stayOn.routedHeadsetUID
        let fallbackName = automatic?.name ?? "No microphone"

        // First row.
        var first: FirstRow
        switch status {
        case .active(let name, let detail):
            let short = HeadsetLabel.short(name)
            first = FirstRow(notice: "Stay on \(short), \(detail)", noticeKind: .stayOn, device: name,
                             detail: musicOnStayOnHeadset ? "Music on \(short) sounds like a phone call while Stay on is on." : nil)
        case .waitingForReconnect(let name):
            first = FirstRow(notice: "Stay on \(HeadsetLabel.short(name)), waiting for it to reconnect.",
                             noticeKind: .stayOn, device: "Using \(fallbackName)")
        case .retrying(let name, _):
            first = FirstRow(notice: "Stay on paused, retrying \(HeadsetLabel.short(name)).",
                             noticeKind: .stayOn, device: "Using \(fallbackName)")
        case .off:
            if wired.isEmpty, pinnedUID == nil, let h = headsets.first(where: \.hasMic) {
                // Honest about what records: with no other mic, each dictation opens the headset.
                first = FirstRow(notice: nil, device: "Using \(HeadsetLabel.short(h.name)) (no other mic)")
            } else {
                first = FirstRow(notice: nil, device: fallbackName)
            }
            if let e = recentEnd {
                switch e.reason {
                case .sleptLong: first.notice = "Stay on ended while this Mac was asleep."
                case .restarted: first.notice = "Stay on ended when this Mac restarted."
                default: first.notice = "Stay on \(HeadsetLabel.short(e.deviceName)) ended."
                }
            }
        }

        // CHANGE TO rows.
        var rows: [Row] = []
        for mic in wired {
            let checked = routed == nil && automatic?.uid == mic.uid
            rows.append(.microphone(uid: mic.uid, name: mic.name, checked: checked,
                                    selectsAutomatic: mic.uid == automaticDefaultUID))
        }
        // A headset pinned in Settings stays visible and checked (explicit pins are preserved).
        if routed == nil, let a = automatic, a.isBluetooth, a.uid == pinnedUID {
            rows.append(.microphone(uid: a.uid, name: a.name, checked: true, selectsAutomatic: a.uid == automaticDefaultUID))
        }
        let sessionBase = session.map { HeadsetInventory.baseUID($0.deviceUID) }
        for h in headsets {
            let short = HeadsetLabel.short(h.name)
            guard h.hasMic else {
                if sessionBase != HeadsetInventory.baseUID(h.uid) {
                    rows.append(.noMicOffered(title: "\(short) connected. macOS is not offering its mic."))
                }
                continue
            }
            let isThis = session?.deviceUID == h.uid
            var title = "Stay on \(short) \(StayOnDuration.standard.phrase)"
            var enabled = true
            // While it is on for this headset, the row states that instead of offering a
            // click that would quietly reset a longer duration to 2 hours.
            if isThis { title = "Stay on \(short) is on"; enabled = false }
            if isThis, case .retrying = status { title = "\(short) (retrying...)" }
            rows.append(.stayOn(uid: h.uid, name: h.name, title: title, enabled: enabled))
            rows.append(.otherDurations(uid: h.uid, name: h.name,
                                        checked: isThis ? (session?.duration ?? .standard) : .standard))
        }
        if session != nil { rows.append(.endStayOn) }
        return MicMenuModel(firstRow: first, rows: rows)
    }

    /// One sentence for VoiceOver.
    public var accessibilityLabel: String {
        [firstRow.notice, firstRow.device, firstRow.detail].compactMap { $0 }.joined(separator: " ")
    }
}
