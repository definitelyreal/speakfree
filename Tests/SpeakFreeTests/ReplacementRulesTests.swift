import XCTest
@testable import SpeakFreeLib

final class ReplacementRulesTests: XCTestCase {
    func testTriggersForTheSameReplacementBecomeOneRule() {
        let rules = ReplacementRules.grouped(
            ["wag one": "wagwan", "wagon": "wagwan", "kama": "Karma"])
        XCTAssertEqual(rules, [
            ReplacementRule(replacement: "Karma", triggers: ["kama"]),
            ReplacementRule(replacement: "wagwan", triggers: ["wag one", "wagon"]),
        ])
    }

    func testRulesRoundTripThroughTheFlatFile() {
        let overrides = ["wag one": "wagwan", "wagon": "wagwan", "kama": "Karma"]
        XCTAssertEqual(ReplacementRules.flattened(ReplacementRules.grouped(overrides)), overrides)
    }

    func testSavingANewRuleAddsIt() {
        let rules = ReplacementRules.saving(
            ReplacementRule(replacement: "wagwan", triggers: ["Wag One.", "wag one", " ", "wagon"]),
            into: [ReplacementRule(replacement: "Karma", triggers: ["kama"])])
        XCTAssertEqual(rules.map(\.replacement), ["Karma", "wagwan"])
        XCTAssertEqual(rules[1].triggers, ["wag one", "wagon"])
    }

    func testEditingARuleReplacesItsOldTriggersAndText() {
        let original = ReplacementRule(replacement: "wagwan", triggers: ["wag one", "wagon"])
        let rules = ReplacementRules.saving(
            ReplacementRule(replacement: "wagwaan", triggers: ["wag one"]),
            replacing: original, into: [original])
        XCTAssertEqual(rules, [ReplacementRule(replacement: "wagwaan", triggers: ["wag one"])])
    }

    func testATriggerBelongsToOneRuleOnly() {
        let rules = ReplacementRules.saving(
            ReplacementRule(replacement: "wagwan", triggers: ["wagon"]),
            into: [ReplacementRule(replacement: "Wagon", triggers: ["wagon", "waggon"])])
        XCTAssertEqual(rules, [
            ReplacementRule(replacement: "Wagon", triggers: ["waggon"]),
            ReplacementRule(replacement: "wagwan", triggers: ["wagon"]),
        ])
    }

    func testARuleNeedsTextAndATrigger() {
        let existing = [ReplacementRule(replacement: "Karma", triggers: ["kama"])]
        XCTAssertEqual(ReplacementRules.saving(
            ReplacementRule(replacement: "  ", triggers: ["x"]), into: existing), existing)
        XCTAssertEqual(ReplacementRules.saving(
            ReplacementRule(replacement: "y", triggers: ["?!"]), into: existing), existing)
    }

    func testDeletingARuleRemovesAllItsTriggers() {
        let rule = ReplacementRule(replacement: "wagwan", triggers: ["wag one", "wagon"])
        XCTAssertEqual(ReplacementRules.flattened(ReplacementRules.deleting(rule, from: [rule])), [:])
    }

    func testTheOverridesFileIsWrittenAndReadBack() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-replacements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Config.configDirOverride = dir
        defer { Config.configDirOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try Config.saveOverrides(["wag one": "wagwan"])
        XCTAssertEqual(Config.loadOverrides(), ["wag one": "wagwan"])
        XCTAssertEqual(Config.loadReplacements().apply(to: "say wag one"), "say wagwan")

        try Config.saveOverrides(["kama": "Karma"])
        XCTAssertEqual(Config.loadReplacements().apply(to: "say wag one kama"), "say wag one Karma")

        try Config.saveOverrides([:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.overridesFile.path))
        XCTAssertTrue(Config.loadReplacements().isEmpty)
    }
}

final class UtteranceSplitterTests: XCTestCase {
    private let rate = UtteranceSplitter.sampleRate

    private func tone(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { level * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func quiet(_ seconds: Double, level: Float = 0.001) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { ($0 % 2 == 0 ? level : -level) }
    }

    func testFiveRepeatsAreFoundSeparately() {
        var samples = quiet(0.5)
        for _ in 0..<5 { samples += tone(0.5) + quiet(0.8) }
        let utterances = UtteranceSplitter.utterances(in: samples)
        XCTAssertEqual(utterances.count, 5)
        for utterance in utterances {
            XCTAssertEqual(Double(utterance.count) / Double(rate), 0.5, accuracy: 0.06)
        }
    }

    func testAShortGapInsideAPhraseDoesNotSplitIt() {
        let samples = quiet(0.3) + tone(0.3) + quiet(0.15) + tone(0.3) + quiet(1.0)
        XCTAssertEqual(UtteranceSplitter.utterances(in: samples).count, 1)
    }

    func testClicksAndSilenceAreNotUtterances() {
        XCTAssertEqual(UtteranceSplitter.utterances(in: quiet(2.0)).count, 0)
        XCTAssertEqual(UtteranceSplitter.utterances(in: quiet(0.5) + tone(0.04) + quiet(0.5)).count, 0)
        XCTAssertEqual(UtteranceSplitter.utterances(in: []).count, 0)
    }

    func testQuietSpeechIsStillFound() {
        let samples = quiet(0.5) + tone(0.5, level: 0.03) + quiet(0.8)
        XCTAssertEqual(UtteranceSplitter.utterances(in: samples).count, 1)
    }

    func testAnUtteranceOnlyCountsAsFinishedAfterAPause() {
        let stillSpeaking = quiet(0.3) + tone(0.5) + quiet(0.8) + tone(0.5) + quiet(0.2)
        XCTAssertEqual(UtteranceSplitter.finishedCount(in: stillSpeaking), 1)
        XCTAssertEqual(UtteranceSplitter.finishedCount(in: stillSpeaking + quiet(0.6)), 2)
    }

    func testAClipCarriesQuietOnBothSides() {
        let samples = quiet(1.0) + tone(0.5) + quiet(1.0)
        let utterance = UtteranceSplitter.utterances(in: samples)[0]
        let clip = UtteranceSplitter.clip(utterance, from: samples)
        XCTAssertEqual(Double(clip.count) / Double(rate), 0.5 + 0.3 + 0.6, accuracy: 0.08)
        XCTAssertEqual(clip.prefix(100).map(abs).max(), 0)
    }
}
