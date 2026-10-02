// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
import Darwin
import FluidAudio
import Foundation

// MARK: - First start (2026-09-24)
//
// After an app update (and sometimes at other launches) the first Parakeet load compiles the
// model for the Neural Engine: 16-73 s in the maintainer's logs, 18 s measured on an M3 Max. A dictation
// made meanwhile used to wait for all of it. Measured facts this design rests on (perf-harness
// coldstart* commands, commit 06aba3a):
//   - Inside one process CoreML serializes model loads, so a CPU-only load cannot finish while an
//     in-process Neural Engine compile runs (it finished at 20.2 s instead of 3.4 s).
//   - Across processes nothing blocks (CPU-only load 3.7 s while another process compiled).
//   - The compiled model is cached per client identity (the same binary under another name
//     recompiled: 19.3 s) and per model path, and that cache is shared between processes.
//   - CPU-only inference is not blocked by a compile and costs 0.14 s (5 s take) / 0.22 s (20 s).
// So the compile runs in a helper process that is this app's own executable, the app loads a
// CPU-only stand-in meanwhile, and once the helper finishes the app's own Neural Engine load hits
// the warm cache (about 0.2 s) and the stand-in is released.

/// Which Parakeet instance produced a take. Logged per take and kept in the take's diagnostics.
public enum ParakeetInferencePath: String, Codable, Sendable {
    case neuralEngine = "ane"
    case cpuStandIn = "cpu-standin"
}

/// What the engine's first model load is doing, for the menu.
public enum ModelPreparationPhase: Equatable, Sendable {
    case preparing(standInReady: Bool)
    case ready
    case failed
    /// The Neural Engine load failed but the CPU stand-in loaded and keeps serving.
    case cpuFallback

    /// Menu line for this phase; nil once the model is ready. No em dashes in UI copy.
    public var menuMessage: String? {
        switch self {
        case .preparing(standInReady: false): return "Preparing speech model…"
        case .preparing(standInReady: true): return "Preparing speech model… Dictation works meanwhile."
        case .ready: return nil
        case .failed: return "Speech model failed to load. Dictation will retry."
        case .cpuFallback: return "Speech model running on the CPU (slower). Neural Engine load failed."
        }
    }
}

/// One-shot signal: waiters resume once the engine can transcribe or preparation has ended.
actor PreparationSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// A running compile helper.
protocol CompileHelperHandle: AnyObject, Sendable {
    /// True when the helper exited successfully. Returns once it has exited or been stopped.
    func wait() async -> Bool
    /// Stop the helper (engine discarded or app quitting). `wait` then returns false.
    func cancel()
}

/// Starts compile helpers. Injectable so tests never spawn processes.
protocol CompileHelperStarting: Sendable {
    func start(modelID: String) -> CompileHelperHandle?
}

/// Runs `<this executable> precompile-parakeet <modelID>`.
struct ProcessCompileHelper: CompileHelperStarting {
    static let command = "precompile-parakeet"
    /// Longest cold compile in the logs was 73 s; beyond this the helper is presumed stuck.
    static let timeoutSeconds: TimeInterval = 300

    let executable: URL

    /// The helper only makes sense inside the app bundle: it must be the same executable as the
    /// app for the compiled-model cache entry to match. Tests, CLI runs and tools get nil and
    /// load in-process exactly as before.
    static func forRunningApp() -> ProcessCompileHelper? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return ProcessCompileHelper(executable: executable)
    }

    func start(modelID: String) -> CompileHelperHandle? {
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.command, modelID]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // The user may be waiting on this compile, so it runs at the same priority as dictation.
        process.qualityOfService = .userInitiated
        let handle = ProcessCompileHelperHandle(process: process)
        process.terminationHandler = { handle.finish(status: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            DiagnosticLogger.shared.log(
                "ParakeetEngine: compile helper could not start (\(error.localizedDescription))")
            return nil
        }
        handle.armTimeout(seconds: Self.timeoutSeconds)
        return handle
    }
}

final class ProcessCompileHelperHandle: CompileHelperHandle, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var status: Int32?
    private var stopped = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(process: Process) {
        self.process = process
    }

    func finish(status: Int32) {
        lock.lock()
        guard self.status == nil else { lock.unlock(); return }
        self.status = status
        let succeeded = status == 0 && !stopped
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: succeeded) }
    }

    func armTimeout(seconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let running = self.status == nil
            self.lock.unlock()
            if running {
                DiagnosticLogger.shared.log(
                    "ParakeetEngine: compile helper timed out after \(Int(seconds)) s; stopping it")
                self.cancel()
            }
        }
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                let succeeded = status == 0 && !stopped
                lock.unlock()
                continuation.resume(returning: succeeded)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func cancel() {
        lock.lock()
        stopped = true
        let running = status == nil
        lock.unlock()
        // terminationHandler still fires after the signal and resumes waiters with false.
        if running, process.isRunning { process.terminate() }
    }
}

/// Entry point for `speakfree precompile-parakeet <modelID>`, run by the app as its compile
/// helper. Loads the model for the Neural Engine through exactly the same call as the app, so the
/// compiled result lands in the app's own cache entry, then exits. Never downloads (the model
/// manager holds FluidAudio offline) and prints nothing.
public enum ParakeetCompileHelperCommand {
    /// Exit codes: 0 compiled, 1 load failed, 2 parent app gone, 3 model not downloaded,
    /// 4 own time limit, 64 bad arguments.
    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 1,
              EngineCatalog.parakeetModels.contains(where: { $0.id == arguments[0] }) else { return 64 }
        let modelID = arguments[0]
        guard ParakeetModelManager.shared.isModelDownloaded(modelID) else { return 3 }
        // The app stops this helper on quit and after 300 s. If the app crashed instead, the
        // helper must not linger (a leftover speakfree process makes update checks fail
        // closed), so it exits when its parent does and enforces the same limit itself.
        let parent = getppid()
        if parent == 1 { return 2 }  // already orphaned: the app that started it is gone
        let parentWatch = DispatchSource.makeProcessSource(
            identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        parentWatch.setEventHandler { _exit(2) }
        parentWatch.resume()
        if getppid() != parent { _exit(2) }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + ProcessCompileHelper.timeoutSeconds) { _exit(4) }
        let done = DispatchSemaphore(value: 0)
        let result = LockedStatus()
        Task.detached(priority: .userInitiated) {
            do {
                let models = try await ParakeetModelManager.shared.loadDownloadedModels(modelID)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                await manager.cleanup()
                result.set(0)
            } catch {
                result.set(1)
            }
            done.signal()
        }
        // Keep the parent watch alive until the load ends (a dropped source never fires).
        withExtendedLifetime(parentWatch) { done.wait() }
        return result.value
    }

    private final class LockedStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32 = 1
        func set(_ value: Int32) { lock.lock(); status = value; lock.unlock() }
        var value: Int32 { lock.lock(); defer { lock.unlock() }; return status }
    }
}

/// Resident memory of this process in MB, for the stand-in's log lines (its weights are about
/// 1.2 GB resident on the M3 Max, measured with perf-harness coldstart-concurrent).
func processResidentMB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
}

/// Name of the calling thread's QoS class, for the per-take latency line.
func currentQoSName() -> String {
    switch qos_class_self() {
    case QOS_CLASS_USER_INTERACTIVE: return "userInteractive"
    case QOS_CLASS_USER_INITIATED: return "userInitiated"
    case QOS_CLASS_DEFAULT: return "default"
    case QOS_CLASS_UTILITY: return "utility"
    case QOS_CLASS_BACKGROUND: return "background"
    default: return "unspecified"
    }
}
