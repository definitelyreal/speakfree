// ai-suggestion:unverified · 2026-09-24
import XCTest
@testable import SpeakFreeLib

final class MicMenuModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isBuiltIn: true, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let usb = AudioInputDevice(id: 5, uid: "usb", name: "Shure MV7+", isBuiltIn: false, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let display = AudioInputDevice(id: 7, uid: "display", name: "Studio Display Microphone", isBuiltIn: false, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
    private let zoom = AudioInputDevice(id: 8, uid: "zoom", name: "ZoomAudioDevice", isBuiltIn: false, isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 2, isVirtual: true)
    private let airPods = AudioInputDevice(id: 2, uid: "airpods", name: "Sam's AirPods Pro", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 24_000, inputChannels: 1)
    private let jabra = AudioInputDevice(id: 6, uid: "jabra", name: "Jabra Evolve2 65 Flex Link380", isBuiltIn: false, isBluetooth: true, nominalSampleRate: 16_000, inputChannels: 1)

    private func headset(_ d: AudioInputDevice) -> ConnectedHeadset { ConnectedHeadset(uid: d.uid, name: d.name, input: d) }

    private func model(inputs: [AudioInputDevice], headsets: [ConnectedHeadset], pin: String? = nil, mode: StayOnMode = StayOnMode(),
                       now: Date? = nil, music: Bool = false) -> MicMenuModel {
        let routes = MicrophoneCaptureCoordinator.routes(devices: inputs, systemDefault: nil, pin: pin)
        let def = MicrophoneCaptureCoordinator.routes(devices: inputs, systemDefault: nil, pin: nil).preferred
        let at = now ?? t0
        return MicMenuModel.build(inputs: inputs, headsets: headsets, automatic: routes.preferred, automaticDefaultUID: def?.uid,
                                  pinnedUID: pin, stayOn: mode, status: mode.status(now: at), recentEnd: mode.recentUnexpectedEnd(now: at),
                                  musicOnStayOnHeadset: music)
    }

    private func active(_ d: AudioInputDevice, _ duration: StayOnDuration = .twoHours) -> StayOnMode {
        var m = StayOnMode()
        m.start(deviceUID: d.uid, deviceName: d.name, duration: duration, now: t0, bootID: nil)
        return m
    }

    func testMacMicOnlyIsOneLineAndOneCheckedRow() {
        let m = model(inputs: [builtIn], headsets: [])
        XCTAssertNil(m.firstRow.notice)
        XCTAssertEqual(m.firstRow.device, "MacBook Pro Microphone")
        XCTAssertEqual(m.rows, [.microphone(uid: "built-in", name: "MacBook Pro Microphone", checked: true, selectsAutomatic: true)])
    }

    func testHeadsetConnectedOffersTwoRowsWithTheDefaultChecked() {
        let m = model(inputs: [builtIn, usb, zoom, airPods], headsets: [headset(airPods)])
        XCTAssertEqual(m.firstRow.device, "MacBook Pro Microphone", "the headset is not used just because it connected")
        XCTAssertEqual(m.rows, [
            .microphone(uid: "built-in", name: "MacBook Pro Microphone", checked: true, selectsAutomatic: true),
            .microphone(uid: "usb", name: "Shure MV7+", checked: false, selectsAutomatic: false),
            .stayOn(uid: "airpods", name: "Sam's AirPods Pro", title: "Stay on AirPods Pro for 2 hours", enabled: true),
            .otherDurations(uid: "airpods", name: "Sam's AirPods Pro", checked: .twoHours),
        ], "virtual devices stay out of the menu; the owner's name is dropped from the label")
    }

    func testStayOnActive() {
        let m = model(inputs: [builtIn, airPods], headsets: [headset(airPods)], mode: active(airPods, .sixHours),
                      now: t0.addingTimeInterval(6 * 3600 - 42 * 60))
        XCTAssertEqual(m.firstRow.notice, "Stay on AirPods Pro, 42 min left")
        XCTAssertEqual(m.firstRow.noticeKind, .stayOn)
        XCTAssertEqual(m.firstRow.device, "Sam's AirPods Pro")
        XCTAssertNil(m.firstRow.detail)
        XCTAssertTrue(m.rows.contains(.microphone(uid: "built-in", name: "MacBook Pro Microphone", checked: false, selectsAutomatic: true)))
        XCTAssertTrue(m.rows.contains(.otherDurations(uid: "airpods", name: "Sam's AirPods Pro", checked: .sixHours)), "checkmark on the duration in use")
        XCTAssertTrue(m.rows.contains(.stayOn(uid: "airpods", name: "Sam's AirPods Pro", title: "Stay on AirPods Pro is on", enabled: false)),
                      "no click that would reset 6 hours to 2")
        XCTAssertEqual(m.rows.last, .endStayOn)
    }

    func testMusicLine() {
        let m = model(inputs: [builtIn, airPods], headsets: [headset(airPods)], mode: active(airPods), music: true)
        XCTAssertEqual(m.firstRow.detail, "Music on AirPods Pro sounds like a phone call while Stay on is on.")
    }

    func testRetryingAndWaiting() {
        var failing = active(airPods)
        failing.headsetFailed(now: t0)
        let r = model(inputs: [builtIn, airPods], headsets: [headset(airPods)], mode: failing)
        XCTAssertEqual(r.firstRow.notice, "Stay on paused, retrying AirPods Pro.")
        XCTAssertEqual(r.firstRow.device, "Using MacBook Pro Microphone")
        XCTAssertTrue(r.rows.contains(.stayOn(uid: "airpods", name: "Sam's AirPods Pro", title: "AirPods Pro (retrying...)", enabled: false)))

        var gone = active(airPods)
        gone.devicesChanged(presentUIDs: [builtIn.uid], now: t0)
        let w = model(inputs: [builtIn], headsets: [], mode: gone)
        XCTAssertEqual(w.firstRow.notice, "Stay on AirPods Pro, waiting for it to reconnect.")
        XCTAssertEqual(w.firstRow.device, "Using MacBook Pro Microphone")
        XCTAssertEqual(w.rows.last, .endStayOn, "Stay on can still be ended while the headset is away")
    }

    func testTwoHeadsetsEachGetTheirOwnRows() {
        let m = model(inputs: [builtIn, airPods, jabra], headsets: [headset(airPods), headset(jabra)])
        let titles: [String] = m.rows.compactMap { if case .stayOn(_, _, let t, _) = $0 { return t } else { return nil } }
        XCTAssertEqual(titles, ["Stay on AirPods Pro for 2 hours", "Stay on Jabra Evolve2...Link380 for 2 hours"])
    }

    func testHeadsetWithoutAMic() {
        let noMic = ConnectedHeadset(uid: "out", name: "AirPods Pro", input: nil)
        let m = model(inputs: [builtIn], headsets: [noMic])
        XCTAssertEqual(m.rows.last, .noMicOffered(title: "AirPods Pro connected. macOS is not offering its mic."))
        XCTAssertFalse(m.rows.contains { if case .stayOn = $0 { return true } else { return false } })
    }

    func testDesktopNeverSaysMacBook() {
        let m = model(inputs: [display, airPods], headsets: [headset(airPods)])
        XCTAssertEqual(m.firstRow.device, "Studio Display Microphone")
        let all = [m.firstRow.notice, m.firstRow.device].compactMap { $0 }.joined() + "\(m.rows)"
        XCTAssertFalse(all.contains("MacBook"))
    }

    func testHeadsetOnlyMac() {
        let m = model(inputs: [airPods], headsets: [headset(airPods)])
        XCTAssertEqual(m.firstRow.device, "Using AirPods Pro (no other mic)")
        XCTAssertTrue(m.rows.contains(.stayOn(uid: "airpods", name: "Sam's AirPods Pro", title: "Stay on AirPods Pro for 2 hours", enabled: true)))
    }

    func testExplicitHeadsetPinStaysVisibleAndChecked() {
        let m = model(inputs: [builtIn, airPods], headsets: [headset(airPods)], pin: airPods.uid)
        XCTAssertEqual(m.firstRow.device, "Sam's AirPods Pro")
        XCTAssertTrue(m.rows.contains(.microphone(uid: "airpods", name: "Sam's AirPods Pro", checked: true, selectsAutomatic: false)))
        XCTAssertTrue(m.rows.contains(.microphone(uid: "built-in", name: "MacBook Pro Microphone", checked: false, selectsAutomatic: true)))
    }

    func testEndedWhileAsleep() {
        var m0 = active(airPods, .untilSleep)
        m0.sleepBegan(now: t0)
        m0.sleepEnded(now: t0.addingTimeInterval(3600))
        let m = model(inputs: [builtIn, airPods], headsets: [headset(airPods)], mode: m0, now: t0.addingTimeInterval(3660))
        XCTAssertEqual(m.firstRow.notice, "Stay on ended while this Mac was asleep.")
        XCTAssertTrue(m.rows.contains(.otherDurations(uid: "airpods", name: "Sam's AirPods Pro", checked: .twoHours)), "offered again")
    }

    // MARK: Notice copy

    func testNoticeCopy() {
        let c = StayOnNoticeCopy.text(for: .connected(uid: "a", name: "Sam's AirPods Pro", usingName: "MacBook Pro Microphone", style: .full, offerDontShowAgain: false))
        XCTAssertEqual(c.message, "AirPods Pro connected. Still using MacBook Pro Microphone.")
        XCTAssertEqual(c.stayOnButton, "Stay on AirPods Pro for 2 hours")
        let s = StayOnNoticeCopy.text(for: .switched(uid: "a", name: "AirPods Pro", startedAt: t0))
        XCTAssertEqual(s.message, "Hard to hear you here, so speakfree switched to AirPods Pro for 2 hours. Your last dictation may be incomplete.")
        XCTAssertTrue(s.undo)
        XCTAssertEqual(StayOnNoticeCopy.text(for: .offer(uid: "a", name: "AirPods Pro")).message,
                       "Hard to hear you here. Switch to AirPods Pro? Music on AirPods Pro will sound like a phone call.")
        XCTAssertNil(StayOnNoticeCopy.text(for: .advise).stayOnButton)
        for n in [StayOnNotice.advise, .offer(uid: "a", name: "x"), .switched(uid: "a", name: "x", startedAt: t0), .endedAfterAutomaticSwitch(uid: "a", name: "x"),
                  .connected(uid: "a", name: "x", usingName: "y", style: .compact, offerDontShowAgain: true)] {
            let t = StayOnNoticeCopy.text(for: n)
            XCTAssertFalse(t.symbol.contains("triangle"), "no warning sign")
            XCTAssertFalse(t.message.contains("\u{2014}"), "no em dashes")
        }
        XCTAssertEqual(StayOnNoticeCopy.seconds(for: .connected(uid: "a", name: "x", usingName: "y", style: .full, offerDontShowAgain: false)), 8)
        XCTAssertEqual(StayOnNoticeCopy.seconds(for: .connected(uid: "a", name: "x", usingName: "y", style: .compact, offerDontShowAgain: false)), 4)
    }
}
