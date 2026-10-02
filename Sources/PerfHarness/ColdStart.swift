// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// First-start and inference-priority measurements for Parakeet (perf/first-start).
//
//   coldstart  Load Parakeet v2 from a fresh APFS clone of the model folder on the Neural
//              Engine and on CPU only, then time inference on the given WAVs with each.
//              The clone lives under --work-dir; the user's real model cache is only read.
//   qos-ab     Time Parakeet inference on the given WAVs at several task priorities, with and
//              without a `yes`-per-core CPU load. Every load process is killed before exit.
//
// Prints timings, audio lengths and character counts only, never transcript text.

import CoreML
import Darwin
import FluidAudio
import Foundation
import SpeakFreeLib

enum ColdStartBench {
    static let modelFolder = "parakeet-tdt-0.6b-v2"

    static func realModelDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(modelFolder)")
    }

    /// APFS clone (`cp -c`) of the real model folder into a fresh, uniquely named directory.
    static func cloneModel(into workDir: URL, tag: String) throws -> URL {
        let parent = workDir.appendingPathComponent("\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dest = parent.appendingPathComponent(modelFolder)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-Rc", realModelDir().path, dest.path]
        try cp.run()
        cp.waitUntilExit()
        guard cp.terminationStatus == 0 else {
            throw NSError(domain: "coldstart", code: Int(cp.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "cp -Rc failed"])
        }
        return dest
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func loadModels(from dir: URL, units: MLComputeUnits) async throws -> (AsrManager, Double) {
        let config = MLModelConfiguration()
        config.computeUnits = units
        let start = CFAbsoluteTimeGetCurrent()
        let models = try await AsrModels.load(from: dir, configuration: config, version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return (manager, CFAbsoluteTimeGetCurrent() - start)
    }

    /// Same trailing-silence pad as ParakeetEngine (3 s, never past the 15 s single chunk).
    static func padded(_ samples: [Float]) -> [Float] {
        let pad = min(48_000, max(0, 240_000 - samples.count))
        return samples + [Float](repeating: 0, count: pad)
    }

    static func infer(_ manager: AsrManager, _ samples: [Float]) async throws -> (Double, Int) {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await manager.transcribe(padded(samples), decoderState: &state, language: nil)
        return (CFAbsoluteTimeGetCurrent() - start, result.text.count)
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func runColdStart(wavs: [URL], workDir: URL, reps: Int) async throws {
        DownloadUtils.enforceOffline = true
        let takes = try wavs.map { ($0, try ProcessCommand.loadSamples(from: $0)) }
        print("coldstart: model \(modelFolder), clones under \(workDir.path)")
        print(String(format: "baseline footprint %.0f MB", footprintMB()))

        // Warm reference: the user's real cache path (read only).
        let (warmMgr, warmLoad) = try await loadModels(from: realModelDir(), units: .cpuAndNeuralEngine)
        print(String(format: "ANE load, real path (warm reference): %.2f s", warmLoad))
        await warmMgr.cleanup()

        for (label, units) in [("ANE", MLComputeUnits.cpuAndNeuralEngine), ("CPU-only", .cpuOnly)] {
            let clone = try cloneModel(into: workDir, tag: label == "ANE" ? "ane" : "cpu")
            let before = footprintMB()
            let (mgr, first) = try await loadModels(from: clone, units: units)
            let after = footprintMB()
            print(String(format: "%@ load, fresh clone (first): %.2f s, footprint +%.0f MB",
                         label, first, after - before))
            for (url, samples) in takes {
                var times: [Double] = []
                var chars = 0
                for _ in 0..<reps {
                    let (t, c) = try await infer(mgr, samples)
                    times.append(t); chars = c
                }
                print(String(format: "  %@ infer %.1f s audio: median %.3f s (runs %@), %d chars",
                             label, Double(samples.count) / 16_000, median(times),
                             times.map { String(format: "%.3f", $0) }.joined(separator: " "), chars))
            }
            await mgr.cleanup()
            let (mgr2, second) = try await loadModels(from: clone, units: units)
            print(String(format: "%@ load, same clone (second): %.2f s", label, second))
            await mgr2.cleanup()
        }
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    /// The realistic first start: the Neural Engine compile begins (as at app launch), and a
    /// CPU-only load of a second fresh clone starts `cpuDelay` seconds later, while the compile
    /// is still running. Reports when each becomes usable and CPU inference mid-compile.
    static func runConcurrent(wavs: [URL], workDir: URL, cpuDelay: Double) async throws {
        DownloadUtils.enforceOffline = true
        let takes = try wavs.map { try ProcessCommand.loadSamples(from: $0) }
        let aneClone = try cloneModel(into: workDir, tag: "conc-ane")
        let cpuClone = try cloneModel(into: workDir, tag: "conc-cpu")
        print(String(format: "concurrent: start rss %.0f MB footprint %.0f MB", residentMB(), footprintMB()))
        let t0 = CFAbsoluteTimeGetCurrent()
        let ane = Task.detached(priority: .userInitiated) {
            let (m, _) = try await loadModels(from: aneClone, units: .cpuAndNeuralEngine)
            return (m, CFAbsoluteTimeGetCurrent() - t0)
        }
        try await Task.sleep(nanoseconds: UInt64(cpuDelay * 1_000_000_000))
        let (cpuMgr, cpuLoad) = try await loadModels(from: cpuClone, units: .cpuOnly)
        let cpuReady = CFAbsoluteTimeGetCurrent() - t0
        print(String(format: "CPU-only ready at %.2f s after compile start (its own load %.2f s); rss %.0f MB footprint %.0f MB",
                     cpuReady, cpuLoad, residentMB(), footprintMB()))
        for samples in takes {
            let (t, c) = try await infer(cpuMgr, samples)
            print(String(format: "  CPU-only infer during compile, %.1f s audio: %.3f s (%d chars) at t=%.2f s",
                         Double(samples.count) / 16_000, t, c, CFAbsoluteTimeGetCurrent() - t0))
        }
        let (aneMgr, aneReady) = try await ane.value
        print(String(format: "ANE ready at %.2f s after compile start; rss %.0f MB footprint %.0f MB (both loaded)",
                     aneReady, residentMB(), footprintMB()))
        await cpuMgr.cleanup()
        print(String(format: "after dropping CPU instance: rss %.0f MB footprint %.0f MB", residentMB(), footprintMB()))
        for samples in takes {
            let (t, _) = try await infer(aneMgr, samples)
            print(String(format: "  ANE infer after compile, %.1f s audio: %.3f s", Double(samples.count) / 16_000, t))
        }
        await aneMgr.cleanup()
    }

    /// One fresh-clone load, for cross-process experiments (two harness processes at once).
    static func runLoadOnce(workDir: URL, units: MLComputeUnits, label: String,
                            modelDir: URL? = nil) async throws {
        DownloadUtils.enforceOffline = true
        let clone = try modelDir ?? cloneModel(into: workDir, tag: "once-\(label)")
        print("load-once dir: \(clone.path)")
        let t0 = CFAbsoluteTimeGetCurrent()
        let (mgr, load) = try await loadModels(from: clone, units: units)
        print(String(format: "load-once %@: %.2f s (started %.3f, wall end %.3f)",
                     label, load, t0, CFAbsoluteTimeGetCurrent()))
        await mgr.cleanup()
    }

    /// CPU-only instance fully loaded first; then the Neural Engine compile starts in the same
    /// process, and CPU-only inference runs `inferDelay` seconds into that compile.
    static func runInferDuringCompile(wavs: [URL], workDir: URL, inferDelay: Double) async throws {
        DownloadUtils.enforceOffline = true
        let takes = try wavs.map { try ProcessCommand.loadSamples(from: $0) }
        let aneClone = try cloneModel(into: workDir, tag: "idc-ane")
        let cpuClone = try cloneModel(into: workDir, tag: "idc-cpu")
        let (cpuMgr, cpuLoad) = try await loadModels(from: cpuClone, units: .cpuOnly)
        print(String(format: "infer-during-compile: CPU-only loaded alone in %.2f s", cpuLoad))
        let t0 = CFAbsoluteTimeGetCurrent()
        let ane = Task.detached(priority: .userInitiated) {
            let (m, _) = try await loadModels(from: aneClone, units: .cpuAndNeuralEngine)
            return (m, CFAbsoluteTimeGetCurrent() - t0)
        }
        try await Task.sleep(nanoseconds: UInt64(inferDelay * 1_000_000_000))
        for samples in takes {
            let (t, c) = try await infer(cpuMgr, samples)
            print(String(format: "  CPU-only infer at t=%.2f s into compile, %.1f s audio: %.3f s (%d chars)",
                         CFAbsoluteTimeGetCurrent() - t0 - t, Double(samples.count) / 16_000, t, c))
        }
        let (aneMgr, aneReady) = try await ane.value
        print(String(format: "infer-during-compile: ANE ready at %.2f s", aneReady))
        await cpuMgr.cleanup()
        await aneMgr.cleanup()
    }

    /// CPU-only load starts first; the Neural Engine load starts `aneDelay` seconds later.
    static func runCPUFirst(wavs: [URL], workDir: URL, aneDelay: Double) async throws {
        DownloadUtils.enforceOffline = true
        let takes = try wavs.map { try ProcessCommand.loadSamples(from: $0) }
        let aneClone = try cloneModel(into: workDir, tag: "cf-ane")
        let cpuClone = try cloneModel(into: workDir, tag: "cf-cpu")
        let t0 = CFAbsoluteTimeGetCurrent()
        let cpu = Task.detached(priority: .userInitiated) {
            let (m, _) = try await loadModels(from: cpuClone, units: .cpuOnly)
            return (m, CFAbsoluteTimeGetCurrent() - t0)
        }
        try await Task.sleep(nanoseconds: UInt64(aneDelay * 1_000_000_000))
        let ane = Task.detached(priority: .userInitiated) {
            let (m, _) = try await loadModels(from: aneClone, units: .cpuAndNeuralEngine)
            return (m, CFAbsoluteTimeGetCurrent() - t0)
        }
        let (cpuMgr, cpuReady) = try await cpu.value
        print(String(format: "cpu-first: CPU-only ready at %.2f s", cpuReady))
        for samples in takes {
            let (t, c) = try await infer(cpuMgr, samples)
            print(String(format: "  CPU-only infer while ANE compiles, %.1f s audio: %.3f s (%d chars) at t=%.2f s",
                         Double(samples.count) / 16_000, t, c, CFAbsoluteTimeGetCurrent() - t0))
        }
        let (aneMgr, aneReady) = try await ane.value
        print(String(format: "cpu-first: ANE ready at %.2f s (ANE started at %.2f s)", aneReady, aneDelay))
        await cpuMgr.cleanup()
        await aneMgr.cleanup()
    }

    // MARK: - qos-ab

    /// Loops Parakeet inference on the Neural Engine until killed (an ANE load generator).
    static func runANEHog(wav: URL) async throws -> Never {
        DownloadUtils.enforceOffline = true
        let samples = try ProcessCommand.loadSamples(from: wav)
        let (mgr, _) = try await loadModels(from: realModelDir(), units: .cpuAndNeuralEngine)
        while true { _ = try await infer(mgr, samples) }
    }

    final class LoadGenerator {
        private var processes: [Process] = []

        /// `count` copies of this harness in `ane-hog` mode at `qos` (ANE contention).
        func startANE(count: Int, wav: URL, qos: QualityOfService) throws {
            for _ in 0..<count {
                let p = Process()
                p.qualityOfService = qos
                p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                p.arguments = ["ane-hog", wav.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                processes.append(p)
            }
        }

        func start(count: Int, qos: QualityOfService = .default) throws {
            for _ in 0..<count {
                let p = Process()
                p.qualityOfService = qos
                p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                processes.append(p)
            }
        }

        func stop() {
            for p in processes where p.isRunning { p.terminate() }
            for p in processes { p.waitUntilExit() }
            processes.removeAll()
        }

        deinit { stop() }
    }

    static func loadQoS(_ name: String) -> QualityOfService {
        switch name {
        case "utility": return .utility
        case "userInitiated": return .userInitiated
        case "userInteractive": return .userInteractive
        default: return .default
        }
    }

    static func runQosAB(wavs: [URL], reps: Int, loadCount: Int, loadQoSName: String = "default",
                         aneLoad: Int = 0) async throws {
        DownloadUtils.enforceOffline = true
        let takes = try wavs.map { try ProcessCommand.loadSamples(from: $0) }
        let (mgr, loadTime) = try await loadModels(from: realModelDir(), units: .cpuAndNeuralEngine)
        print(String(format: "qos-ab: ANE model loaded in %.2f s; %d takes, %d reps; load = %d x yes + %d x ANE inference loop, at %@",
                     loadTime, takes.count, reps, loadCount, aneLoad, loadQoSName))
        let probe = await Task.detached(priority: TaskPriority(rawValue: 33)) {
            (Task.currentPriority.rawValue, qos_class_self().rawValue)
        }.value
        print("raw33 task: currentPriority \(probe.0), thread qos class \(probe.1) (33 = userInteractive, 25 = userInitiated)")
        // Warm the graph once so the first timed run is not a first-call outlier.
        _ = try await infer(mgr, takes[0])

        let priorities: [(String, TaskPriority)] = [
            ("utility", .utility), ("medium", .medium), ("userInitiated", .userInitiated),
            ("raw33", TaskPriority(rawValue: 33)),
        ]
        let loader = LoadGenerator()
        var interrupted = false
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler { interrupted = true; loader.stop(); exit(130) }
        sigSource.resume()
        defer { loader.stop() }

        for loaded in [false, true] {
            if loaded && aneLoad > 0 {
                try loader.startANE(count: aneLoad, wav: wavs[wavs.count - 1], qos: loadQoS(loadQoSName))
                try await Task.sleep(nanoseconds: 4_000_000_000)  // let the hogs load their models
            }
            if loaded && loadCount > 0 { try loader.start(count: loadCount, qos: loadQoS(loadQoSName)); try await Task.sleep(nanoseconds: 1_000_000_000) }
            for (name, priority) in priorities {
                var ratios: [Double] = []
                var times: [Double] = []
                for _ in 0..<reps {
                    for samples in takes {
                        let t = try await Task.detached(priority: priority) {
                            try await infer(mgr, samples).0
                        }.value
                        times.append(t)
                        ratios.append(t / (Double(samples.count) / 16_000))
                    }
                }
                print(String(format: "%@ %-13@ infer median %.3f s  max %.3f s  | infer/audio-s median %.3f max %.3f",
                             loaded ? "LOADED" : "idle  ", name as NSString, median(times), times.max() ?? .nan,
                             median(ratios), ratios.max() ?? .nan))
            }
            if loaded { loader.stop() }
        }
        _ = interrupted
        await mgr.cleanup()
    }
}
