// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import XCTest
@testable import SpeakFreeKeyboardCore

final class FUTOSwipeEncoderRuntimeTests: XCTestCase {
    /// Replays FUTO's published real-world "computer" trace through the same iOS runtime used by
    /// the extension. This catches missing resources, incompatible binaries, tensor-order errors,
    /// coordinate mistakes, and model execution failures in one simulator test.
    func testPublishedComputerTraceGreedyDecodesOnSimulator() throws {
        let x: [Double] = [
            0.4141, 0.4478, 0.5, 0.5741, 0.6599, 0.7256, 0.7744, 0.8098, 0.8485, 0.867,
            0.8737, 0.8653, 0.8418, 0.8182, 0.8098, 0.7963, 0.7946, 0.8081, 0.8418, 0.8704,
            0.9057, 0.9259, 0.9545, 0.9697, 0.968, 0.9529, 0.9141, 0.8468, 0.7811, 0.7273,
            0.6869, 0.6616, 0.6582, 0.6431, 0.6061, 0.5572, 0.5067, 0.4663, 0.4495, 0.4461,
            0.4411, 0.4192, 0.3872, 0.362, 0.3283, 0.2795, 0.2391, 0.2323, 0.2407, 0.2593,
            0.2879, 0.3249, 0.3468, 0.3569
        ]
        let y: [Double] = [
            0.8991, 0.858, 0.7876, 0.6702, 0.5352, 0.4237, 0.3357, 0.2653, 0.1655, 0.142,
            0.142, 0.2183, 0.3709, 0.588, 0.7347, 0.8462, 0.8697, 0.811, 0.6115, 0.4707,
            0.3122, 0.2066, 0.1303, 0.1068, 0.1068, 0.1068, 0.1185, 0.1596, 0.1772, 0.1772,
            0.1772, 0.189, 0.189, 0.189, 0.1831, 0.189, 0.189, 0.189, 0.189, 0.189,
            0.1831, 0.1831, 0.1831, 0.1831, 0.1831, 0.1948, 0.189, 0.1948, 0.189, 0.189,
            0.189, 0.1831, 0.1831, 0.1831
        ]
        let milliseconds: [Double] = [
            0, 100, 149, 197, 246, 297, 348, 399, 449, 498, 548, 598, 648, 698, 749, 799,
            849, 949, 999, 1047, 1100, 1152, 1197, 1248, 1314, 1364, 1414, 1465, 1515, 1565,
            1614, 1666, 1715, 1851, 1898, 1951, 1998, 2049, 2097, 2165, 2231, 2279, 2331,
            2382, 2431, 2481, 2532, 2584, 2649, 2700, 2751, 2798, 2848, 2899
        ]
        XCTAssertEqual(x.count, y.count)
        XCTAssertEqual(x.count, milliseconds.count)

        let points = zip(zip(x, y), milliseconds).map {
            TrajectoryPoint(x: $0.0.0, y: $0.0.1, timestamp: $0.1 / 1_000)
        }
        let input = try TrajectoryPreprocessor().prepare(
            points: points,
            keyboardSize: KeyboardSize(width: 1, height: 1)
        )
        let runtime = try FUTOSwipeEncoderRuntime(bundle: Bundle(for: Self.self))
        let emissions = try runtime.predict(input: input)
        XCTAssertEqual(emissions.count, 32)
        XCTAssertTrue(emissions.allSatisfy { $0.count == 65 && $0.allSatisfy(\.isFinite) })

        var decoded = ""
        var previous = -1
        for row in emissions {
            let current = row.indices.max(by: { row[$0] < row[$1] })!
            if current != previous, current != runtime.blankIndex, current < runtime.labels.count {
                decoded.append(runtime.labels[current])
            }
            previous = current
        }
        XCTAssertEqual(decoded, "computer")

        let vocabularyURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "wordfreq-en-25000-log",
                withExtension: "json"
            )
        )
        let rawRows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: vocabularyURL)) as? [[Any]]
        )
        let entries = rawRows.compactMap { row -> VocabularyEntry? in
            guard row.count == 2,
                  let word = row[0] as? String,
                  let frequency = row[1] as? Double else { return nil }
            return VocabularyEntry(word: word, frequency: frequency)
        }
        XCTAssertEqual(entries.count, 25_000)
        let vocabulary = VocabularyTrie(entries: entries)
        let fullDecoder = SwipeDecoder(
            runtime: runtime,
            vocabulary: vocabulary,
            beamWidth: 100,
            frequencyWeight: 0.15
        )
        let candidates = try fullDecoder.decode(
            points: points,
            keyboardSize: KeyboardSize(width: 1, height: 1),
            candidateLimit: 4
        )
        XCTAssertEqual(candidates.first?.word, "computer")
        XCTAssertTrue(candidates.prefix(3).contains { $0.word == "computer" })

        for size in [
            KeyboardSize(width: 320, height: 180),
            KeyboardSize(width: 390, height: 216),
            KeyboardSize(width: 844, height: 220),
            KeyboardSize(width: 768, height: 280),
        ] {
            let scaledPoints = points.map {
                TrajectoryPoint(
                    x: $0.x * size.width,
                    y: $0.y * size.height,
                    timestamp: $0.timestamp
                )
            }
            let start = CFAbsoluteTimeGetCurrent()
            let sizeCandidates = try fullDecoder.decode(
                points: scaledPoints,
                keyboardSize: size,
                candidateLimit: 4
            )
            XCTAssertEqual(sizeCandidates.first?.word, "computer")
            XCTAssertLessThan(
                CFAbsoluteTimeGetCurrent() - start,
                2,
                "a single swipe must remain interactive on the Simulator"
            )
        }

        var gesture = KeyboardGestureMachine()
        let surfaceWidth = 390.0
        let surfaceHeight = 216.0
        gesture.begin(
            role: .character,
            x: points[0].x * surfaceWidth,
            y: points[0].y * surfaceHeight,
            timestamp: points[0].timestamp
        )
        var sawPreview = false
        for point in points.dropFirst() {
            let actions = gesture.move(
                x: point.x * surfaceWidth,
                y: point.y * surfaceHeight,
                timestamp: point.timestamp
            )
            sawPreview = sawPreview || actions.contains(.previewSwipe)
        }
        XCTAssertTrue(sawPreview)
        XCTAssertEqual(gesture.end(), .commitSwipe)
    }
}
