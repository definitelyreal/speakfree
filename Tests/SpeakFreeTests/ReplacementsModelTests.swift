import XCTest
@testable import SpeakFreeLib

private final class FakeCapture: ReplacementCapturing {
    var onProgress: ((Int) -> Void)?
    var completion: ((Result<[String], ReplacementCaptureFailure>) -> Void)?
    var stopped = false
    var cancelled = false
    var level: CGFloat?

    func start(onProgress: @escaping (Int) -> Void,
               completion: @escaping (Result<[String], ReplacementCaptureFailure>) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
    }
    func stop() { stopped = true }
    func cancel() { cancelled = true }
}

final class ReplacementsModelTests: XCTestCase {
    private var saved: [String: String] = [:]

    private func model(_ overrides: [String: String] = [:], capture: FakeCapture? = FakeCapture())
        -> ReplacementsModel {
        saved = overrides
        return ReplacementsModel(overrides: overrides, capture: capture) { [unowned self] in self.saved = $0 }
    }

    func testARuleNeedsTextAndAtLeastOneTriggerBeforeItCanBeSaved() {
        let model = model()
        XCTAssertFalse(model.canSave)
        model.replacement = "wagwan"
        XCTAssertFalse(model.canSave)
        model.typedTrigger = "Wag one"
        model.addTypedTrigger()
        XCTAssertEqual(model.triggers, ["wag one"])
        XCTAssertEqual(model.typedTrigger, "")
        XCTAssertTrue(model.canSave)
    }

    func testSavingWritesTheRuleAndClearsTheForm() {
        let model = model()
        model.replacement = "wagwan"
        model.addTriggers(["wag one", "wagon"])
        model.save()
        XCTAssertEqual(saved, ["wag one": "wagwan", "wagon": "wagwan"])
        XCTAssertEqual(model.rules.map(\.replacement), ["wagwan"])
        XCTAssertEqual(model.replacement, "")
        XCTAssertEqual(model.triggers, [])
    }

    func testSavingIncludesATriggerStillInTheTextField() {
        let model = model()
        model.replacement = "Karma"
        model.typedTrigger = "kama"
        model.save()
        XCTAssertEqual(saved, ["kama": "Karma"])
    }

    func testEditingLoadsARuleAndSavingReplacesIt() {
        let model = model(["wag one": "wagwan", "wagon": "wagwan"])
        model.edit(model.rules[0])
        XCTAssertEqual(model.replacement, "wagwan")
        XCTAssertEqual(model.triggers, ["wag one", "wagon"])
        model.removeTrigger("wagon")
        model.replacement = "wagwaan"
        model.save()
        XCTAssertEqual(saved, ["wag one": "wagwaan"])
        XCTAssertNil(model.editing)
    }

    func testDeletingRemovesTheRule() {
        let model = model(["wag one": "wagwan", "kama": "Karma"])
        model.delete(model.rules.first { $0.replacement == "wagwan" }!)
        XCTAssertEqual(saved, ["kama": "Karma"])
    }

    func testRecordingAddsEveryDistinctHearingAsATrigger() {
        let capture = FakeCapture()
        let model = model(capture: capture)
        model.toggleRecording()
        XCTAssertEqual(model.captureState, .listening(heard: 0))
        capture.onProgress?(3)
        XCTAssertEqual(model.captureState, .listening(heard: 3))
        capture.completion?(.success(["wag one", "wagon", "wag one"]))
        XCTAssertEqual(model.triggers, ["wag one", "wagon"])
        XCTAssertEqual(model.captureState, .idle)
    }

    func testPressingTheButtonAgainStopsEarly() {
        let capture = FakeCapture()
        let model = model(capture: capture)
        model.toggleRecording()
        model.toggleRecording()
        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(model.captureState, .working)
        XCTAssertFalse(model.canRecord)
    }

    func testAFailedRecordingSaysWhy() {
        let capture = FakeCapture()
        let model = model(capture: capture)
        model.toggleRecording()
        capture.completion?(.failure(.nothingHeard))
        XCTAssertEqual(model.captureState, .message(ReplacementCaptureFailure.nothingHeard.message))
        XCTAssertEqual(model.triggers, [])
    }

    func testTheWaveformReadsTheMicrophoneLevel() {
        let capture = FakeCapture()
        let model = model(capture: capture)
        XCTAssertNil(model.level)
        capture.level = 0.25
        XCTAssertEqual(model.level, 0.25)
    }

    func testTheWaveformScrollsNewSoundInFromTheRight() {
        let meter = CaptureMeter()
        XCTAssertEqual(Set(meter.heights), [TargetAppPill.dashHeight])
        // Room noise first, so the gate knows what quiet is; then a word.
        for _ in 0..<20 { meter.advance(rms: 0.002) }
        XCTAssertEqual(Set(meter.heights), [TargetAppPill.dashHeight])
        for _ in 0..<6 { meter.advance(rms: 0.3) }
        XCTAssertGreaterThan(meter.heights.last!, TargetAppPill.dashHeight)
        XCTAssertEqual(meter.heights.first!, TargetAppPill.dashHeight)
        meter.reset()
        XCTAssertEqual(Set(meter.heights), [TargetAppPill.dashHeight])
    }

    func testClosingTheWindowStopsListening() {
        let capture = FakeCapture()
        let model = model(capture: capture)
        model.toggleRecording()
        model.close()
        XCTAssertTrue(capture.cancelled)
        XCTAssertEqual(model.captureState, .idle)
    }

    func testWithoutAMicrophonePathTriggersCanStillBeTyped() {
        let model = model(capture: nil)
        XCTAssertFalse(model.canRecord)
        model.replacement = "Karma"
        model.addTriggers(["kama"])
        model.save()
        XCTAssertEqual(saved, ["kama": "Karma"])
    }
}

final class SettingsChromeTests: XCTestCase {
    func testShortcutsAreDrawnAsModifierSymbolsThenTheKey() {
        XCTAssertEqual(ShortcutSymbols.parts(keyCode: 49, modifiers: ["cmd", "option", "shift"]),
                       ["\u{2325}", "\u{21E7}", "\u{2318}", "Space"])
        XCTAssertEqual(ShortcutSymbols.parts(keyCode: 9, modifiers: ["ctrl"]), ["\u{2303}", "V"])
        XCTAssertEqual(ShortcutSymbols.parts(keyCode: 49, modifiers: []), ["Space"])
        // A modifier used alone as the dictation key names its side.
        XCTAssertEqual(ShortcutSymbols.parts(keyCode: 63, modifiers: []), ["fn"])
        XCTAssertEqual(ShortcutSymbols.parts(keyCode: 61, modifiers: []), ["Right \u{2325}"])
    }

    func testEveryPaneHasATitleAnIconAndASummary() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title),
                       ["General", "Shortcuts", "Microphone", "Transcription", "Words", "Recordings", "Advanced"])
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.symbol.isEmpty)
            XCTAssertTrue(tab.summary.hasSuffix("."))
        }
    }

    func testSettingsCanBeOpenedStraightToAPane() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.tab, .general)
        navigation.tab = .words
        XCTAssertEqual(navigation.tab, .words)
    }

    func testTheReplacementsListReloadsFromDisk() {
        let model = ReplacementsModel(overrides: [:], capture: nil) { _ in }
        model.reload(overrides: ["kama": "Karma"])
        XCTAssertEqual(model.rules.map(\.replacement), ["Karma"])
        // A rule being written is not thrown away by a reload.
        model.replacement = "wagwan"
        model.reload(overrides: [:])
        XCTAssertEqual(model.rules, [])
        XCTAssertEqual(model.replacement, "wagwan")
    }
}
