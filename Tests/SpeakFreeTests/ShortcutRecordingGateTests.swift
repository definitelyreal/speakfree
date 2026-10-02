// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import Carbon
import XCTest
@testable import SpeakFreeLib

/// No real hotkey registrations, keyboard posts, event taps, settings, or microphone access.
@MainActor
final class ShortcutRecordingGateTests: XCTestCase {
    func testClosingAWindowOrSwitchingAppsCancelsTheRecorderAndRestoresHotkeys() {
        for notification in [NSWindow.willCloseNotification, NSApplication.didResignActiveNotification] {
            let center = NotificationCenter()
            let gate = ShortcutRecordingGate(notificationCenter: center)
            var removals = 0, cancels = 0
            let holder = KeyMonitorHolder(recordingGate: gate, notificationCenter: center,
                installMonitor: { _ in NSObject() }, removeMonitor: { _ in removals += 1 })
            holder.install(onCapture: { _, _ in XCTFail("no key was supplied") }, onCancel: { cancels += 1 })
            XCTAssertTrue(gate.snapshot.isActive)
            center.post(name: notification, object: nil)
            XCTAssertFalse(gate.snapshot.isActive)
            XCTAssertEqual(cancels, 1)
            XCTAssertEqual(removals, 1)
            holder.remove()
            XCTAssertEqual(removals, 1, "SwiftUI disappearance after close is idempotent")
        }
    }

    func testFailedRecorderInstallationNeverLeavesGlobalShortcutsPaused() {
        let center = NotificationCenter()
        let gate = ShortcutRecordingGate(notificationCenter: center)
        var cancels = 0
        let holder = KeyMonitorHolder(recordingGate: gate, notificationCenter: center,
            installMonitor: { _ in nil }, removeMonitor: { _ in XCTFail("no monitor exists") })
        holder.install(onCapture: { _, _ in XCTFail("no key was supplied") }, onCancel: { cancels += 1 })
        XCTAssertFalse(gate.snapshot.isActive)
        XCTAssertEqual(cancels, 1)
    }

    func testNestedRecordersRestoreOnlyAfterBothEndAndIgnoreDuplicateClose() {
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter())
        let before = gate.snapshot
        let first = gate.begin(), second = gate.begin()
        XCTAssertTrue(gate.snapshot.isActive)
        gate.finish(first)
        gate.finish(first)
        XCTAssertTrue(gate.snapshot.isActive)
        gate.finish(second)
        XCTAssertFalse(gate.snapshot.isActive)
        XCTAssertFalse(gate.permitsDelivery(from: before), "queued pre-recorder key presses must not start dictation later")
        XCTAssertTrue(gate.permitsDelivery(from: gate.snapshot))
    }

    func testHeldCapturedKeyKeepsShortcutsPausedUntilRelease() throws {
        var held = true
        var polls: [() -> Void] = []
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter(), keyIsDown: { _ in held },
                                         scheduleReleaseCheck: { polls.append($0) })
        let lease = gate.begin()
        gate.finish(lease, afterKeyRelease: 9)
        XCTAssertTrue(gate.snapshot.isActive)
        XCTAssertEqual(polls.count, 1)
        let first = polls.removeFirst(); first()
        XCTAssertTrue(gate.snapshot.isActive, "a long hold must not become autorepeated History")
        held = false
        let last = try XCTUnwrap(polls.first); polls.removeAll(); last()
        XCTAssertFalse(gate.snapshot.isActive)
    }

    func testHistoryUnregistersDuringCaptureAndRestoresLatestSettingsOnCancel() throws {
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter())
        var registrations: [(UInt16, UInt32)] = [], unregistrations = 0
        let key = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let shortcut = HistoryShortcut(recordingGate: gate, register: { code, flags in
            registrations.append((code, flags)); return (noErr, key)
        }, unregister: { _ in unregistrations += 1 }, installEventHandler: false)
        shortcut.onAvailabilityChanged = { error in XCTAssertNil(error) }
        var settings = HistorySettings()
        let dictation = HotkeyConfig(keyCode: 63, modifiers: [])
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        XCTAssertEqual(registrations.count, 1)
        let lease = gate.begin()
        XCTAssertEqual(unregistrations, 1)
        settings.shortcutKeyCode = 8
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        XCTAssertEqual(registrations.count, 1, "saving while recording must not re-register early")
        gate.finish(lease)
        XCTAssertEqual(registrations.map { $0.0 }, [9, 8])
    }

    func testHistoryOffAndRestorationFailureDoNotSilentlyReregisterOldShortcut() throws {
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter())
        var registrations = 0, messages: [String?] = []
        let key = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let shortcut = HistoryShortcut(recordingGate: gate, register: { _, _ in
            registrations += 1
            return registrations == 1 ? (noErr, key) : (OSStatus(eventHotKeyExistsErr), nil)
        }, unregister: { _ in }, installEventHandler: false)
        shortcut.onAvailabilityChanged = { messages.append($0) }
        var settings = HistorySettings()
        let dictation = HotkeyConfig(keyCode: 63, modifiers: [])
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        let lease = gate.begin(); gate.finish(lease)
        XCTAssertNotNil(messages.last!, "registration failure after cancellation reaches preferences")
        let second = gate.begin()
        settings.retention = .off
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        gate.finish(second)
        XCTAssertEqual(registrations, 2, "History turned off while recording stays off")
    }

    func testDictationModifierEventsPassThroughWhileRecordingWithoutStartingATake() throws {
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter())
        let manager = HotkeyManager(keyCode: 63, shortcutRecordingGate: gate)
        var starts = 0, stops = 0
        manager.setKeyCallbacksForTesting(onKeyDown: { starts += 1 }, onKeyUp: { stops += 1 })
        let lease = gate.begin()
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.type = .flagsChanged; event.flags = .maskSecondaryFn
        XCTAssertNotNil(manager.handleCGEvent(type: .flagsChanged, event: event))
        event.flags = []
        XCTAssertNotNil(manager.handleCGEvent(type: .flagsChanged, event: event))
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
        gate.finish(lease)
    }

    func testGlobalKeyDownIsPausedButExistingReleaseIsNotLost() throws {
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter())
        let manager = HotkeyManager(keyCode: 9, modifiers: UInt64(NSEvent.ModifierFlags.command.rawValue),
                                    shortcutRecordingGate: gate)
        var starts = 0, stops = 0
        manager.setKeyCallbacksForTesting(onKeyDown: { starts += 1 }, onKeyUp: { stops += 1 })
        func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        }
        manager.handleNSEvent(try event(.keyDown))
        XCTAssertEqual(starts, 1)
        let lease = gate.begin()
        manager.handleNSEvent(try event(.keyDown))
        XCTAssertEqual(starts, 1)
        manager.handleNSEvent(try event(.keyUp, flags: []))
        XCTAssertEqual(stops, 1, "an existing hold dictation stops even if Command was released first")
        manager.handleNSEvent(try event(.keyDown))
        manager.handleNSEvent(try event(.keyUp))
        XCTAssertEqual(stops, 1, "a suppressed press must not synthesize a release")
        gate.finish(lease)
        manager.handleNSEvent(try event(.keyDown))
        manager.handleNSEvent(try event(.keyDown))
        XCTAssertEqual(starts, 2, "a held key's repeat does not start a second dictation")
        manager.handleNSEvent(try event(.keyUp, flags: []))
        XCTAssertEqual(stops, 2)
    }
}
