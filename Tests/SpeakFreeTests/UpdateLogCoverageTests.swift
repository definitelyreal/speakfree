// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// The update guard fails closed on any unknown log line that mentions recording, dictation,
// transcription, finalize or streaming. That is deliberate, so every such line the app can
// write must be classified. On 2026-09-24 two unclassified lines blocked a real install.

import XCTest
@testable import SpeakFreeLib

final class UpdateLogCoverageTests: XCTestCase {
    func testArchiveAndBindingRuntimeDiagnosticsKeepUpdateSemantics() {
        for line in ["Terminate: closed in-flight recording", "Terminate: audio archive unavailable after failed repair",
                     "History paste: cancelled reason=external-input"] {
            XCTAssertEqual(UpdateLogEvent.classify("[00:00:00] " + line), .activity)
        }
        let requested = AudioInputDevice(id: 42, uid: "dictation-recording-input", name: "Test input",
            isBuiltIn: false, isBluetooth: true, nominalSampleRate: 24_000, inputChannels: 1)
        let states = [
            CaptureDeviceBinding.Snapshot(status: 0, byteCount: 4, deviceID: 42, uid: "dictation-recording-input", uidStatus: 0),
            CaptureDeviceBinding.Snapshot(status: 0, byteCount: 4, deviceID: 99, uid: "aggregate", uidStatus: 0),
            CaptureDeviceBinding.Snapshot(status: -1, byteCount: 0, deviceID: nil, uid: nil, uidStatus: nil),
            CaptureDeviceBinding.Snapshot(status: 0, byteCount: 4, deviceID: 42, uid: nil, uidStatus: -2),
        ]
        for observed in states {
            let line = CaptureDeviceBinding.diagnostic(requested: requested, observed: observed,
                stage: "recheck", generation: "test-generation")
            XCTAssertEqual(UpdateLogEvent.classify("[00:00:00] " + line), .unrelated, line)
        }
    }

    func testLinesThatBlockedTheSeptember24InstallAreClassified() {
        for line in [
            "[21:14:02] Capture route: Pre-listening: MacBook Pro Microphone · dictation: AirPods Pro",
            "[21:15:40] Reprocess: inserted 42 chars from recent dictation",
            "[21:16:00] WhisperEngine: streaming transcribe 40020 samples (2.5s audio)",
        ] {
            XCTAssertNotEqual(UpdateLogEvent.classify(line), .unsupported, line)
        }
    }

    /// The Stay on static switch (2026-09-25): real runtime lines, device names included.
    func testStaticSwitchLinesAreClassified() {
        let expected: [(String, UpdateLogEvent)] = [
            ("[18:45:09] Capture switch: Jamie’s AirPods Pro sounded like static (low-band 0.18, 5784 crossings/s, 2.0 s) while MacBook Pro Microphone heard a voice; the take continues on MacBook Pro Microphone", .activity),
            ("[18:45:09] Capture switch: Jamie’s AirPods Pro stopped sending audio; the take continues on MacBook Pro Microphone", .activity),
            ("[18:45:07] Capture switch: Jamie’s AirPods Pro had no verified audio at the start; using MacBook Pro Microphone", .activity),
            ("[18:45:09] Stay on notice: AirPods Pro sounded like static. Switched to MacBook Pro Microphone.", .unrelated),
            ("[18:42:26] Capture: Jamie’s AirPods Pro verified: sample clock steady at 24000 Hz; input stream matches", .unrelated),
            ("[18:42:26] Capture: Jamie’s AirPods Pro not verified: tap 48000 Hz; input stream 24000 Hz; device 48000 Hz", .unrelated),
        ]
        for (line, event) in expected {
            XCTAssertEqual(UpdateLogEvent.classify(line), event, line)
        }
    }

    /// Prefixes each merged branch classified on its own (dogfood and perf/first-start), pinned
    /// to the class each one chose so a later merge cannot silently drop or flip one.
    func testPrefixesFromBothBranchesKeepTheirClass() {
        let expected: [(String, UpdateLogEvent)] = [
            // dogfood
            ("[09:00:00] Report a Problem: opened the report window", .unrelated),
            ("[09:00:00] DictationTrace: wrote trace for the last dictation", .unrelated),
            ("[09:00:00] Clipboard restore: trigger=user-paste restored=true", .unrelated),
            ("[09:00:00] Capture route: Pre-listening: MacBook Pro Microphone · dictation: AirPods Pro", .unrelated),
            ("[09:00:00] RecordingsNotice: shown", .unrelated),
            ("[09:00:00] AudioRecorder: kept 0.40s captured while recording start was delayed", .activity),
            ("[09:00:00] Latency: total=0.350 wait=0.090 engine=parakeet path=ane qos=userInitiated", .activity),
            // perf/first-start (launch-fixes)
            ("[09:00:00] Dictation Mode: ON — pinning AirPods Pro", .activity),
            ("[09:00:00] Dictation Mode: OFF — restoring input MacBook Pro Microphone", .activity),
            ("[09:00:00] T2.3: reused last streaming partial (skipped final inference)", .activity),
            ("[09:00:00] Overlay: backdrop sample failed (Screen Recording permission?)", .activity),
            // both
            ("[09:00:00] Reprocess: inserted 42 chars from recent dictation", .activity),
            ("[09:00:00] WhisperEngine: streaming transcribe 40020 samples (2.5s audio)", .activity),
        ]
        for (line, event) in expected {
            XCTAssertEqual(UpdateLogEvent.classify(line), event, line)
        }
    }

    /// Every literal log message in the app (the text before any interpolation) must be
    /// classified, so adding a log line can never silently break agent-driven updates.
    func testEveryLogMessageInTheSourceIsClassified() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SpeakFreeLib")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        // Calls may break the line after `log(` or `String(`; both forms must be checked.
        let pattern = try NSRegularExpression(
            pattern: #"DiagnosticLogger\.shared\.log\(\s*(?:String\(\s*format:\s*)?"([^"\\]*)(?:"\s*\+\s*"([^"\\]*))?"#)
        // Format strings are checked with sample values, the way the line is really written.
        let integerSpecifier = try NSRegularExpression(pattern: #"%(?:l|ll)?[du]"#)
        let otherSpecifier = try NSRegularExpression(pattern: #"%(?:\.[0-9]+)?[fs@]"#)
        var checked = 0
        var unsupported: [String] = []
        var unreadable: [String] = []
        let call = try NSRegularExpression(pattern: #"DiagnosticLogger\.shared\.log\("#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            // Every call must be readable by the pattern (a literal to classify) or be listed
            // below with a representative runtime line; nothing is skipped silently.
            for site in call.matches(in: text, range: whole) {
                let readable = pattern.firstMatch(
                    in: text, options: .anchored, range: NSRange(location: site.range.location,
                                                                 length: whole.length - site.range.location))
                let literal = readable.flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) } ?? ""
                if literal.isEmpty, let start = Range(site.range, in: text) {
                    let snippet = text[start.lowerBound...].prefix(60)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    unreadable.append("\(file.lastPathComponent): \(snippet.prefix(45))")
                }
            }
            for match in pattern.matches(in: text, range: whole) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var message = String(text[range])
                if let continuation = Range(match.range(at: 2), in: text) {
                    message += text[continuation]
                }
                message = integerSpecifier.stringByReplacingMatches(
                    in: message, range: NSRange(message.startIndex..., in: message), withTemplate: "1")
                message = otherSpecifier.stringByReplacingMatches(
                    in: message, range: NSRange(message.startIndex..., in: message), withTemplate: "1.0")
                guard !message.isEmpty else { continue }
                checked += 1
                if UpdateLogEvent.classify("[00:00:00] " + message) == .unsupported {
                    unsupported.append("\(file.lastPathComponent): \(message)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 200)
        XCTAssertEqual(unsupported, [], "classify these in UpdateLogEvent")
        // The calls the literal scan cannot read, each with the runtime lines it can produce.
        // (AppDelegate: the launch readiness line, the two finalize failure messages and the
        // per-take Latency line; TextInserter: the two clipboard-restore records.)
        let allowlisted = [
            "AppDelegate.swift: DiagnosticLogger.shared.log(\"\\(readiness) — h",
            "AppDelegate.swift: DiagnosticLogger.shared.log(message) ",
            "AppDelegate.swift: DiagnosticLogger.shared.log(message) ",
            "AppDelegate.swift: DiagnosticLogger.shared.log(latency.logLine( ",
            "AppDelegate.swift: DiagnosticLogger.shared.log(recording.audioFi",
            "DeviceAudioSession.swift: DiagnosticLogger.shared.log(CaptureDeviceBind",
            "TextInserter.swift: DiagnosticLogger.shared.log(record.logLine) o",
            "TextInserter.swift: DiagnosticLogger.shared.log(record.userPasteL",
        ]
        XCTAssertEqual(unreadable.sorted(), allowlisted.sorted(),
                       "a new non-literal log call needs a runtime line checked here")
        for line in [
            "Ready — hotkey=fn model=parakeet-tdt-0.6b-v2",
            "Hotkey ready; speech model not loaded yet — hotkey=fn model=parakeet-tdt-0.6b-v2",
            "Parakeet model not downloaded — open Settings to download.",
            "Transcription failed: modelNotLoaded",
            "Latency: total=0.350 wait=0.090 stop=0.010 queue=0.000 infer=0.200 text=0.010 save=na "
                + "insert=0.040 ext=no tailRMS=0.0040 cold=no preload=no audio=1.00 chars=3 "
                + "engine=parakeet path=cpu-standin modelWait=0.000 qos=userInitiated",
            "TextInserter: clipboard restore route=local trigger=first-read read=12ms pasteToRestore=250ms restored=true",
            "Clipboard restore: trigger=user-paste route=local read=none pasteToRestore=900ms restored=false",
        ] {
            XCTAssertNotEqual(UpdateLogEvent.classify("[00:00:00] " + line), .unsupported, line)
        }
    }
}
