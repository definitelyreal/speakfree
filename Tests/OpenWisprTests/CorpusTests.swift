import XCTest
@testable import OpenWisprLib

/// Regression corpus for `TextPostProcessor`. Each case is a JSON object in
/// `Corpus/cases.json` with `{name, mode, input, expected, note?}`.
///
/// To add a case: copy a real failing dictation from `~/.config/speakfree/recordings/`
/// (`<id>.raw.txt` is the whisper output, `<id>.txt` is what speakfree typed) into
/// a new entry, set `expected` to what *should* have come out, and re-run.
///
/// Modes: "hybrid" (whisper auto-punct + spoken words), "spoken" (spoken words only),
/// "off" (no post-processing).
final class CorpusTests: XCTestCase {

    private struct Case: Decodable {
        let name: String
        let mode: String
        let input: String
        let expected: String
        let note: String?
    }

    func testCorpus() throws {
        let corpusURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
            .appendingPathComponent("cases.json")

        let data = try Data(contentsOf: corpusURL)
        let cases = try JSONDecoder().decode([Case].self, from: data)
        XCTAssertFalse(cases.isEmpty, "Corpus is empty")

        var failures: [String] = []
        for c in cases {
            let actual: String
            switch c.mode {
            case "off":
                actual = c.input
            case "spoken":
                actual = TextPostProcessor.process(c.input, hybrid: false)
            case "hybrid":
                actual = TextPostProcessor.process(c.input, hybrid: true)
            default:
                failures.append("\(c.name): unknown mode '\(c.mode)'")
                continue
            }

            if actual != c.expected {
                let noteLine = c.note.map { "  note:     \($0)\n" } ?? ""
                failures.append("""
                ✗ \(c.name) [mode: \(c.mode)]
                \(noteLine)  input:    \(c.input.debugDescription)
                  expected: \(c.expected.debugDescription)
                  actual:   \(actual.debugDescription)
                """)
            }
        }

        if !failures.isEmpty {
            XCTFail("Corpus failures (\(failures.count)/\(cases.count)):\n\n" + failures.joined(separator: "\n\n"))
        }
    }
}
