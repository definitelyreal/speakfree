// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-03
import AppKit
import Carbon
import XCTest
@testable import SpeakFreeLib

/// Synthetic key events and injected Carbon calls only; no live shortcuts, input or preferences.
@MainActor
final class HistoryActionShortcutTests: XCTestCase {
    private let dictation = HotkeyConfig(keyCode: 63, modifiers: [])
    private func key(_ action: HistorySettings.Action) -> EventHotKeyRef { OpaquePointer(bitPattern: Int(action.carbonID))! }
    private func allAssigned() -> HistorySettings {
        var settings = HistorySettings()
        settings.allShortcut = .init(keyCode: 9, modifiers: ["ctrl", "shift"])
        return settings
    }

    func testDefaultsAreSeparateAndAllIsUnassignedWithoutEnablingClipboard() throws {
        let settings = try JSONDecoder().decode(HistorySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(HistorySettings.Action.allCases, [.dictation, .clipboard, .all])
        XCTAssertEqual(settings.shortcut(for: .dictation).label, "⌥⇧V")
        XCTAssertEqual(settings.shortcut(for: .clipboard).label, "⇧⌘V")
        XCTAssertEqual(settings.shortcut(for: .all).label, "Not set")
        XCTAssertFalse(settings.includeClipboard)
        XCTAssertEqual(settings.retention, .session)
    }

    func testLegacyCustomShortcutMovesToClipboardAndDoesNotLoseToNewDefault() throws {
        for modifiers in [["ctrl", "option"], ["alt", "shift"]] {
            let data = try JSONSerialization.data(withJSONObject: ["shortcutKeyCode": 9, "shortcutModifiers": modifiers])
            let settings = try JSONDecoder().decode(HistorySettings.self, from: data)
            XCTAssertEqual(settings.shortcut(for: .clipboard).modifiers, modifiers)
            XCTAssertEqual(settings.dictationShortcut.isAssigned, modifiers != ["alt", "shift"])
            XCTAssertFalse(settings.allShortcut.isAssigned)
            XCTAssertFalse(settings.includeClipboard)
        }
    }

    func testLegacyExplicitlyDisabledShortcutDoesNotEnableNewDictationsBinding() throws {
        let legacy = try JSONDecoder().decode(HistorySettings.self, from: Data(#"{"shortcutModifiers":[]}"#.utf8))
        XCTAssertFalse(legacy.shortcut(for: .clipboard).isAssigned)
        XCTAssertFalse(legacy.dictationShortcut.isAssigned, "an existing disabled shortcut must stay disabled after migration")
        let fresh = try JSONDecoder().decode(HistorySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.dictationShortcut.label, "⌥⇧V")
        let modern = try JSONDecoder().decode(HistorySettings.self, from: Data(
            #"{"shortcutModifiers":[],"dictationShortcut":{"keyCode":8,"modifiers":["ctrl"]}}"#.utf8))
        XCTAssertEqual(modern.dictationShortcut.label, "⌃C", "explicit newer settings remain authoritative")
        XCTAssertFalse(modern.shortcut(for: .clipboard).isAssigned)
    }

    func testMalformedLegacyShortcutMigrationPreservesDecodedDisabledState() throws {
        let variants = [#""shortcutModifiers":null"#, #""shortcutModifiers":"bad""#,
                        #""shortcutModifiers":["shift"]"#, #""shortcutModifiers":["future"]"#,
                        #""shortcutKeyCode":-1"#, #""shortcutKeyCode":999"#]
        for legacy in variants {
            let config = try Config.decode(from: Data("{\"hotkey\":{\"keyCode\":63,\"modifiers\":[]},\"modelSize\":\"custom\",\"language\":\"de\",\"history\":{\(legacy)}}".utf8))
            let settings = try XCTUnwrap(config.history)
            XCTAssertFalse(settings.shortcut(for: .clipboard).isAssigned)
            XCTAssertFalse(settings.dictationShortcut.isAssigned, legacy)
            XCTAssertEqual(config.modelSize, "custom"); XCTAssertEqual(config.language, "de")
            let newer = "{\(legacy),\"dictationShortcut\":{\"keyCode\":8,\"modifiers\":[\"ctrl\"]}}"
            let explicit = try JSONDecoder().decode(HistorySettings.self, from: Data(newer.utf8))
            XCTAssertEqual(explicit.dictationShortcut.label, "⌃C")
        }
        let fresh = try JSONDecoder().decode(HistorySettings.self, from: Data("{}".utf8))
        XCTAssertTrue(fresh.dictationShortcut.isAssigned)
        XCTAssertTrue(fresh.shortcut(for: .clipboard).isAssigned)
    }

    func testClearedAndCustomActionShortcutsRoundTripWithoutResettingConfig() throws {
        var config = Config.defaultConfig
        config.modelPath = "/synthetic/custom-model"; config.language = "de"
        var settings = allAssigned()
        settings.setShortcut(.unassigned, for: .dictation)
        settings.setShortcut(.init(keyCode: 8, modifiers: ["control", "alt"]), for: .clipboard)
        config.history = settings
        let decoded = try Config.decode(from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.history, settings)
        XCTAssertEqual(decoded.modelPath, config.modelPath)
        XCTAssertEqual(decoded.language, "de")
    }

    func testMalformedActionFieldsDisableOnlyThatAction() throws {
        for malformed in ["null", "7", #""future""#, #"{"keyCode":-1,"modifiers":["cmd"]}"#,
                          #"{"keyCode":9,"modifiers":["future"]}"#, #"{"keyCode":9}"#] {
            let json = """
            {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"custom","language":"fr",
             "history":{"dictationShortcut":\(malformed),"shortcutKeyCode":8,"shortcutModifiers":["ctrl"],
             "allShortcut":{"keyCode":7,"modifiers":["option"]},"futureField":{"anything":true}}}
            """
            let config = try Config.decode(from: Data(json.utf8))
            let settings = try XCTUnwrap(config.history)
            XCTAssertFalse(settings.dictationShortcut.isAssigned)
            XCTAssertEqual(settings.shortcut(for: .clipboard).label, "⌃C")
            XCTAssertEqual(settings.allShortcut.label, "⌥X")
            XCTAssertEqual(config.modelSize, "custom"); XCTAssertEqual(config.language, "fr")
        }
    }

    func testCaptureValidationRejectsDuplicateAndDictationBindingsWithGlyphLabels() {
        let settings = HistorySettings()
        let duplicate = HistorySettings.Shortcut(keyCode: 9, modifiers: ["command", "shift"])
        XCTAssertTrue(settings.validationError(for: duplicate, action: .all, dictation: dictation)?.contains("Clipboard") == true)
        XCTAssertNotNil(settings.validationError(for: .init(keyCode: 9, modifiers: ["shift"]), action: .all, dictation: dictation))
        let hotkey = HotkeyConfig(keyCode: 8, modifiers: ["control"])
        XCTAssertNotNil(settings.validationError(for: .init(keyCode: 8, modifiers: ["ctrl"]), action: .all, dictation: hotkey))
        XCTAssertNil(settings.validationError(for: .unassigned, action: .all, dictation: hotkey))
        XCTAssertEqual(HistorySettings.Shortcut(keyCode: 125, modifiers: ["command", "alt", "control", "shift"]).label, "⌃⌥⇧⌘↓")
    }

    func testEachCarbonIDDispatchesItsActionAndClipboardWorksWhenCaptureIsDisabled() {
        var calls: [(HistorySettings.Action, UInt16, UInt32)] = [], pressed: [HistorySettings.Action] = []
        let shortcut = HistoryShortcut(register: { action, code, flags in
            calls.append((action, code, flags)); return (noErr, self.key(action))
        }, unregister: { _ in }, installEventHandler: false)
        shortcut.onPress = { pressed.append($0) }
        let settings = allAssigned()
        XCTAssertFalse(settings.includeClipboard)
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.first(where: { $0.0 == .dictation })?.2, UInt32(optionKey | shiftKey))
        XCTAssertEqual(calls.first(where: { $0.0 == .clipboard })?.2, UInt32(cmdKey | shiftKey))
        for id: UInt32 in [1, 2, 3, 999] { shortcut.receive(actionID: id) }
        XCTAssertEqual(pressed, [.dictation, .clipboard, .all])
    }

    func testDuplicateConfigPreservesLegacyClipboardAndUnrelatedAllRegistration() {
        var settings = allAssigned(), calls: [HistorySettings.Action] = []
        settings.shortcutModifiers = ["option", "shift"]
        let shortcut = HistoryShortcut(register: { action, _, _ in
            calls.append(action); return (noErr, self.key(action))
        }, unregister: { _ in }, installEventHandler: false)
        let error = shortcut.configure(settings, dictation: dictation)
        XCTAssertEqual(Set(calls), [.clipboard, .all])
        XCTAssertTrue(error?.contains("Dictations") == true)
        XCTAssertTrue(error?.contains("Clipboard") == true)
        XCTAssertNil(shortcut.availabilityErrors[.clipboard])
        XCTAssertNil(shortcut.availabilityErrors[.all])
    }

    func testFailedRegistrationDoesNotReleaseOrReplaceOtherValidActions() {
        var rejectAll = false, registered: [HistorySettings.Action] = [], removed: [EventHotKeyRef] = []
        let shortcut = HistoryShortcut(register: { action, _, _ in
            registered.append(action)
            return action == .all && rejectAll ? (OSStatus(eventHotKeyExistsErr), nil) : (noErr, self.key(action))
        }, unregister: { removed.append($0) }, installEventHandler: false)
        var settings = HistorySettings()
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        XCTAssertEqual(registered.count, 2)
        settings.allShortcut = .init(keyCode: 8, modifiers: ["ctrl"]); rejectAll = true
        XCTAssertTrue(shortcut.configure(settings, dictation: dictation)?.contains("All: ⌃C is unavailable") == true)
        XCTAssertEqual(registered, [.clipboard, .dictation, .all])
        XCTAssertTrue(removed.isEmpty)
        var pressed: [HistorySettings.Action] = []; shortcut.onPress = { pressed.append($0) }
        [1, 2, 3].forEach { shortcut.receive(actionID: $0) }
        XCTAssertEqual(pressed, [.dictation, .clipboard])
        rejectAll = false
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(registered, [.clipboard, .dictation, .all, .all])
    }

    func testDictationCollisionOnlyDisablesTheConflictingAction() {
        var registered: [HistorySettings.Action] = []
        let shortcut = HistoryShortcut(register: { action, _, _ in
            registered.append(action); return (noErr, self.key(action))
        }, unregister: { _ in }, installEventHandler: false)
        let error = shortcut.configure(allAssigned(), dictation: .init(keyCode: 9, modifiers: ["option", "shift"]))
        XCTAssertEqual(Set(registered), [.clipboard, .all])
        XCTAssertTrue(error?.contains("Dictations") == true)
        XCTAssertTrue(error?.contains("dictation key") == true)
    }

    func testAllActionsStaySuppressedThroughCaptureAndKeyReleaseWait() throws {
        var held = true, checks: [() -> Void] = [], pressed: [HistorySettings.Action] = []
        let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter(), keyIsDown: { _ in held },
                                         scheduleReleaseCheck: { checks.append($0) })
        let shortcut = HistoryShortcut(recordingGate: gate, register: { action, _, _ in (noErr, self.key(action)) },
                                       unregister: { _ in }, installEventHandler: false)
        shortcut.onPress = { pressed.append($0) }
        XCTAssertNil(shortcut.configure(allAssigned(), dictation: dictation))
        let lease = gate.begin()
        [1, 2, 3].forEach { shortcut.receive(actionID: $0) }
        gate.finish(lease, afterKeyRelease: 9)
        [1, 2, 3].forEach { shortcut.receive(actionID: $0) }
        XCTAssertTrue(pressed.isEmpty)
        held = false; try XCTUnwrap(checks.first)()
        [1, 2, 3].forEach { shortcut.receive(actionID: $0) }
        XCTAssertEqual(pressed, [.dictation, .clipboard, .all])
    }

    func testModifierSupersetThatStartsRuntimeDictationIsRejectedByBothHistoryPaths() throws {
        let primary = HotkeyConfig(keyCode: 9, modifiers: ["command"])
        let candidate = HistorySettings.Action.clipboard.defaultShortcut
        let manager = HotkeyManager(keyCode: primary.keyCode, modifiers: primary.modifierFlags)
        var starts = 0
        manager.setKeyCallbacksForTesting(onKeyDown: { starts += 1 }, onKeyUp: {})
        manager.handleNSEvent(try event(9, flags: [.command, .shift]))
        XCTAssertEqual(starts, 1, "the existing runtime accepts extra Shift on Command-V")
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 9))
        manager.handleNSEvent(release)
        let settings = HistorySettings()
        XCTAssertNotNil(settings.validationError(for: candidate, action: .clipboard, dictation: primary))
        var registrations: [HistorySettings.Action] = []
        let shortcut = HistoryShortcut(register: { action, _, _ in
            registrations.append(action); return (noErr, self.key(action))
        }, unregister: { _ in }, installEventHandler: false)
        XCTAssertNotNil(shortcut.configure(settings, dictation: primary))
        XCTAssertEqual(registrations, [.dictation], "only the conflicting Clipboard chord is disabled")
        XCTAssertNotNil(shortcut.availabilityErrors[.clipboard])
    }

    func testSidedModifierPrimaryConflictsWithChordsUsingThatModifier() {
        let cases: [(UInt16, String, [String])] = [
            (54, "cmd", ["cmd"]), (55, "cmd", ["cmd"]),
            (56, "shift", ["cmd", "shift"]), (60, "shift", ["cmd", "shift"]),
            (58, "option", ["option"]), (61, "option", ["option"]),
            (59, "ctrl", ["ctrl"]), (62, "ctrl", ["ctrl"]),
        ]
        for (code, _, modifiers) in cases {
            let primary = HotkeyConfig(keyCode: code, modifiers: [])
            let candidate = HistorySettings.Shortcut(keyCode: 9, modifiers: modifiers)
            var settings = HistorySettings()
            settings.dictationShortcut = .unassigned; settings.shortcutModifiers = []
            settings.allShortcut = candidate
            let flags = CGEventFlags(rawValue: HotkeyManager.modifierFlagBit(for: code)
                | HotkeyConfig(keyCode: 9, modifiers: modifiers).modifierFlags)
            XCTAssertTrue(HotkeyManager.hotkeyIsDown(flags, keyCode: code), "real sided-modifier decision recognizes this press")
            XCTAssertNotNil(settings.validationError(for: candidate, action: .all, dictation: primary), "primary key \(code)")
            var registered = false
            let shortcut = HistoryShortcut(register: { action, _, _ in registered = true; return (noErr, self.key(action)) },
                                           unregister: { _ in }, installEventHandler: false)
            XCTAssertNotNil(shortcut.configure(settings, dictation: primary))
            XCTAssertFalse(registered, "Carbon must not admit a chord that can start dictation first")
        }
    }

    func testRuntimeCollisionControlsKeepIndependentChordsAndHonorRequiredModifiers() {
        var settings = HistorySettings()
        settings.dictationShortcut = .unassigned; settings.shortcutModifiers = []
        let commandV = HistorySettings.Shortcut(keyCode: 9, modifiers: ["cmd"])
        for primary in [HotkeyConfig(keyCode: 9, modifiers: ["cmd", "shift"]),
                        HotkeyConfig(keyCode: 8, modifiers: ["cmd"]),
                        HotkeyConfig(keyCode: 63, modifiers: []),
                        HotkeyConfig(keyCode: 58, modifiers: [])] {
            XCTAssertNil(settings.validationError(for: commandV, action: .all, dictation: primary))
        }
        XCTAssertNotNil(settings.validationError(for: commandV, action: .all, dictation: .init(keyCode: 9, modifiers: [])))
        let optionShiftV = HistorySettings.Action.dictation.defaultShortcut
        XCTAssertNil(settings.validationError(for: optionShiftV, action: .all, dictation: .init(keyCode: 58, modifiers: ["control"])))
        let optionControlV = HistorySettings.Shortcut(keyCode: 9, modifiers: ["option", "ctrl"])
        XCTAssertNotNil(settings.validationError(for: optionControlV, action: .all, dictation: .init(keyCode: 58, modifiers: ["control"])))
    }

    func testKnownFnLayerKeysAreRejectedWithoutReleasingIndependentVActions() {
        var registrations: [HistorySettings.Action] = [], removals = 0
        let shortcut = HistoryShortcut(register: { action, _, _ in
            registrations.append(action); return (noErr, self.key(action))
        }, unregister: { _ in removals += 1 }, installEventHandler: false)
        var settings = HistorySettings()
        XCTAssertNil(shortcut.configure(settings, dictation: dictation))
        let fnLayerCodes: [UInt16] = [115, 116, 117, 119, 121,
                                     122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]
        for code in fnLayerCodes {
            let candidate = HistorySettings.Shortcut(keyCode: code, modifiers: ["cmd"])
            XCTAssertNotNil(settings.validationError(for: candidate, action: .all, dictation: dictation), "Fn-layer key \(code)")
            settings.allShortcut = candidate
            XCTAssertNotNil(shortcut.configure(settings, dictation: dictation))
            XCTAssertEqual(registrations, [.clipboard, .dictation])
            XCTAssertEqual(removals, 0, "unaffected V bindings stay registered")
        }
        var pressed: [HistorySettings.Action] = []; shortcut.onPress = { pressed.append($0) }
        [1, 2, 3].forEach { shortcut.receive(actionID: $0) }
        XCTAssertEqual(pressed, [.dictation, .clipboard])
    }

    func testFnLayerCollisionStillRequiresPrimaryModifiers() {
        let primary = HotkeyConfig(keyCode: 63, modifiers: ["control"])
        var settings = HistorySettings(), registered: [HistorySettings.Action] = []
        let shortcut = HistoryShortcut(register: { action, _, _ in
            registered.append(action); return (noErr, self.key(action))
        }, unregister: { _ in }, installEventHandler: false)
        let commandDelete = HistorySettings.Shortcut(keyCode: 117, modifiers: ["cmd"])
        XCTAssertNil(settings.validationError(for: commandDelete, action: .all, dictation: primary))
        settings.allShortcut = commandDelete
        XCTAssertNil(shortcut.configure(settings, dictation: primary))
        XCTAssertEqual(Set(registered), [.dictation, .clipboard, .all])
        let controlDelete = HistorySettings.Shortcut(keyCode: 117, modifiers: ["ctrl"])
        XCTAssertNotNil(settings.validationError(for: controlDelete, action: .all, dictation: primary))
        settings.allShortcut = controlDelete
        XCTAssertNotNil(shortcut.configure(settings, dictation: primary))
        XCTAssertNotNil(shortcut.availabilityErrors[.all])
    }

    private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testInlineTabLeavesFieldWhileModifiedTabCanBeRecorded() throws {
        for flags: NSEvent.ModifierFlags in [[], .shift, .command] {
            var handler: HistoryKeyMonitorHolder.EventHandler?, cancelled = 0, captured: [UInt16] = []
            let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter(), keyIsDown: { _ in false })
            let holder = HistoryKeyMonitorHolder(recordingGate: gate, notificationCenter: NotificationCenter(),
                installMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in })
            holder.install(onCapture: { code, _ in captured.append(code) }, onCancel: { cancelled += 1 }, allowsFocusTraversal: true)
            let input = try event(48, flags: flags)
            let result = handler?(input)
            if flags == .command {
                XCTAssertNil(result); XCTAssertEqual(captured, [48]); XCTAssertEqual(cancelled, 0)
            } else {
                XCTAssertTrue(result === input); XCTAssertTrue(captured.isEmpty); XCTAssertEqual(cancelled, 1)
                XCTAssertFalse(gate.snapshot.isActive)
            }
            holder.remove()
        }
    }

    func testInlineForwardDeleteIgnoresFnButPreservesOtherModifiers() throws {
        for flags: NSEvent.ModifierFlags in [.function, [.function, .command], [.function, .option],
                                             [.function, .control], [.function, .shift]] {
            var handler: HistoryKeyMonitorHolder.EventHandler?, clears = 0, captures: [UInt16] = []
            let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter(), keyIsDown: { _ in false })
            let holder = HistoryKeyMonitorHolder(recordingGate: gate, notificationCenter: NotificationCenter(),
                installMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in })
            holder.install(onCapture: { key, _ in captures.append(key) }, onCancel: {}, allowsFocusTraversal: true,
                onClear: { clears += 1; holder.remove() })
            XCTAssertNil(handler?(try event(117, flags: flags)))
            XCTAssertEqual(clears, flags == .function ? 1 : 0)
            XCTAssertEqual(captures, flags == .function ? [] : [117])
            holder.remove()
            XCTAssertFalse(gate.snapshot.isActive)
        }
    }

    func testInlineDeleteClearsAndEscapeCancelsWithoutChangingOverlayTabBehavior() throws {
        for code: UInt16 in [51, 117, 53, 48] {
            var handler: HistoryKeyMonitorHolder.EventHandler?, clears = 0, cancels = 0, captures: [UInt16] = []
            let gate = ShortcutRecordingGate(notificationCenter: NotificationCenter(), keyIsDown: { _ in false })
            let holder = HistoryKeyMonitorHolder(recordingGate: gate, notificationCenter: NotificationCenter(),
                installMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in })
            holder.install(onCapture: { key, _ in captures.append(key) }, onCancel: { cancels += 1; holder.remove() },
                onClear: { clears += 1; holder.remove() })
            XCTAssertNil(handler?(try event(code)))
            XCTAssertEqual(clears, [51, 117].contains(code) ? 1 : 0)
            XCTAssertEqual(cancels, code == 53 ? 1 : 0)
            XCTAssertEqual(captures, code == 48 ? [48] : [])
            holder.remove()
            XCTAssertFalse(gate.snapshot.isActive)
        }
    }
}
