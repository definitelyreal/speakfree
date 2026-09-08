// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// Reproduce: xcrun swiftc -O Sources/SpeakFreeLib/WavWriter.swift \
//   scripts/benchmark-wav-encoding.swift -o /tmp/speakfree-wav-bench
// Then run /tmp/speakfree-wav-bench. Baseline is the encoder at b4eed23.
import Foundation
@inline(never) func previous(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for s in samples {
        let clamped = max(-1.0, min(1.0, s))
        var v = Int16((clamped * 32767.0).rounded())
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    return data
}
@main
struct WAVEncodingBenchmark {
    static func main() {
        let samples: [Float] = (0..<4096).map { sin(Float($0) * 0.1) }
        precondition(previous(samples) == WavWriter.pcmData(samples))
        func bench(_ body: ([Float]) -> Data) -> Double {
            var runs: [Double] = []
            var bytes = 0
            for _ in 0..<7 {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<1000 { bytes += body(samples).count }
                runs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            precondition(bytes == 7 * 1000 * samples.count * 2)
            return runs.sorted()[3]
        }
        let old = bench(previous), new = bench(WavWriter.pcmData)
        print(String(format: "4096 samples x 1000, 7 runs, median: previous %.3f ms; new %.3f ms; speedup %.2fx", old, new, old/new))
    }
}
