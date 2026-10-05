// Trace output experiment: ai-suggestion:unverified · session:unknown · 2026-10-04
// ai-suggestion:unverified · session:01a09da8-0424-7b71-a705-10868c5f46e4 · 2026-09-13
// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import AppKit
import Foundation
import SpeakFreeLib

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let version = SpeakFree.version

func printUsage() {
    print("""
    speakfree v\(version) — Push-to-talk voice dictation for macOS

    USAGE:
        speakfree start              Start the dictation daemon
        speakfree prepare-update [--timeout 60...3600] [--require-visible-warning]
                                     Wait for quiet and warn before an external update
        speakfree quit-clipy         Ask Clipy to quit normally before deployment
        speakfree process <wav>      Transcribe a wav file; prints JSON {raw, processed, styled}
        speakfree set-hotkey <key>   Set the push-to-talk hotkey
        speakfree get-hotkey         Show current hotkey
        speakfree set-model <size>   Set the Whisper model
        speakfree download-model [size]  Download a Whisper model
        speakfree set-engine <name>  Set the transcription engine (whisper | parakeet)
        speakfree download-parakeet [id]  Download a Parakeet model (default parakeet-tdt-0.6b-v2)
        speakfree status             Show configuration and status

    FOR AI ASSISTANTS AND SCRIPTS (one JSON object on stdout, documented exit codes;
    see docs/AGENT-CLI.md):
        speakfree transcribe <file>  Transcribe an audio file offline (never downloads)
        speakfree history [--limit N] [--app BUNDLE_ID]
                                     Recent dictations, only if saving is turned on
        speakfree vocab list | add <word> | remove <word>
                                     Read or edit the custom vocabulary (vocabulary.txt)
        speakfree trace decode [--clipboard]
                                     Decode dictation traces in text on stdin (or the clipboard)
        speakfree match [--days N] [--clipboard]
                                     Find the saved dictations that text came from, with what
                                     the engine heard (only if saving is turned on)
        speakfree set-trace <off|tags|tags-only|expanded|selectors>
                                     Append an invisible dictation trace in AI apps (off by default)
        speakfree audio-check        Check microphone handover for 12 seconds (saves no audio)
        speakfree compat scan [--tsv]  List installed apps and how dictation reaches each (read-only)
        speakfree --help             Show this help message

    HOTKEY EXAMPLES:
        speakfree set-hotkey globe             Globe/fn key (default)
        speakfree set-hotkey rightoption        Right Option key
        speakfree set-hotkey f5                 F5 key
        speakfree set-hotkey ctrl+space         Ctrl + Space

    AVAILABLE MODELS:
        tiny.en, tiny, base.en, base, small.en, small, medium.en, medium, large-v3-turbo, large
    """)
}

// sig_atomic_t flag: set-only from signal handler, polled on main RunLoop.
// NSApp.terminate(nil) MUST be called on the main thread.
private var sigintReceived: sig_atomic_t = 0

func cmdStart() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    // Signal handler only sets the flag — no heap allocation, locks, or Obj-C calls.
    signal(SIGINT) { _ in sigintReceived = 1 }

    // Main RunLoop timer polls the flag every 0.25s and terminates via NSApp.terminate.
    let sigintTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        if sigintReceived != 0 {
            print("\nStopping speakfree...")
            NSApp.terminate(nil)
        }
    }
    RunLoop.main.add(sigintTimer, forMode: .common)

    app.run()
}

func cmdSetHotkey(_ keyString: String) {
    guard let parsed = KeyCodes.parse(keyString) else {
        print("Error: Unknown key '\(keyString)'")
        print("Run 'speakfree --help' for examples")
        exit(1)
    }

    var config = Config.load()
    config.hotkey = HotkeyConfig(keyCode: parsed.keyCode, modifiers: parsed.modifiers)

    do {
        try config.save()
        let desc = KeyCodes.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
        print("Hotkey set to: \(desc)")
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdSetModel(_ size: String) {
    let validSizes = ["tiny.en", "tiny", "base.en", "base", "small.en", "small", "medium.en", "medium", "large-v3-turbo", "large"]
    guard validSizes.contains(size) else {
        print("Error: Unknown model '\(size)'")
        print("Available: \(validSizes.joined(separator: ", "))")
        exit(1)
    }

    var config = Config.load()
    config.modelSize = size

    do {
        try config.save()
        print("Model set to: \(size)")
        if !Transcriber.modelExists(modelSize: size) {
            print("Model will be downloaded on next start.")
        }
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdGetHotkey() {
    let config = Config.load()
    let desc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
    print("Current hotkey: \(desc)")
}

func cmdDownloadModel(_ size: String) {
    do {
        try ModelDownloader.download(modelSize: size)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdSetEngine(_ name: String) {
    let valid = ["whisper", "parakeet"]
    guard valid.contains(name) else {
        print("Error: Unknown engine '\(name)'. Available: \(valid.joined(separator: ", "))")
        exit(1)
    }
    var config = Config.load()
    config.engine = name
    do {
        try config.save()
        print("Engine set to: \(name)")
        if name == "parakeet" {
            let id = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
            if !ParakeetModelManager.shared.isModelDownloaded(id) {
                print("Parakeet model '\(id)' not downloaded. Run: speakfree download-parakeet \(id)")
            }
        }
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdDownloadParakeet(_ modelID: String) {
    DiagnosticLogger.shared.setEnabled(true)  // surface ParakeetDirectDownloader diagnostics on the CLI
    print("Downloading Parakeet model '\(modelID)' (~600 MB, one time)…")
    let sem = DispatchSemaphore(value: 0)
    var failure: Error?
    Task {
        do {
            // Phase 1: byte-accurate pre-fetch of the large bundles (smooth real progress).
            try await ParakeetModelManager.shared.prefetchLargeFiles(modelID) { written, total in
                guard total > 0 else { return }
                let pct = Int(Double(written) / Double(total) * 100)
                fputs("\r  downloading \(pct)%  (\(written / 1_000_000) of \(total / 1_000_000) MB)   ", stderr)
            }
            fputs("\n  finishing + compiling…\n", stderr)
            // Phase 2: FluidAudio fetches the small remainder and compiles (skips pre-fetched files).
            try await ParakeetModelManager.shared.ensureDownloaded(modelID) { _ in }
        } catch {
            failure = error
        }
        sem.signal()
    }
    sem.wait()
    fputs("\n", stderr)
    if let failure {
        print("Error: \(failure.localizedDescription)")
        exit(1)
    }
    print("Parakeet model '\(modelID)' ready.")
}

func cmdProcess(_ wavPath: String) {
    let wavURL = URL(fileURLWithPath: wavPath)
    do {
        let result = try ProcessCommand.run(wavURL: wavURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8) ?? "{}")
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func cmdStatus() {
    let config = Config.load()
    let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)

    let engine = config.engine ?? "whisper"
    print("speakfree v\(version)")
    print("Config:      \(Config.configFile.path)")
    print("Hotkey:      \(hotkeyDesc)")
    print("Engine:      \(engine)")
    if engine == "parakeet" {
        let id = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
        print("Model:       \(id)")
        print("Model ready: \(ParakeetModelManager.shared.isModelDownloaded(id) ? "yes" : "no")")
    } else {
        print("Model:       \(config.modelSize)")
        print("Model ready: \(Transcriber.modelExists(modelSize: config.modelSize) ? "yes" : "no")")
        print("whisper-cpp: \(Transcriber.findWhisperBinary() != nil ? "yes" : "no")")
    }
    let toggleMode = config.toggleMode?.value ?? false
    print("Toggle:      \(toggleMode ? "on (press to start/stop)" : "off (hold to talk)")")
    print("Trace:       \(DictationTrace.OutputMode.resolve(config.dictationTrace).rawValue)")
}

/// Run an agent command so that stdout carries exactly one JSON object: anything the
/// engines print while working goes to stderr, then the JSON is written to the real stdout.
func runAgentCommand(_ produce: () -> AgentCLI.Output) -> Never {
    fflush(stdout)
    let savedStdout = dup(STDOUT_FILENO)
    if savedStdout >= 0 { dup2(STDERR_FILENO, STDOUT_FILENO) }
    let output = produce()
    fflush(stdout)
    // Write the JSON straight to the saved real stdout and leave fd 1 pointing at stderr,
    // so a late print from a background thread can never land after the JSON.
    let data = Data((output.json + "\n").utf8)
    if savedStdout >= 0 {
        FileHandle(fileDescriptor: savedStdout, closeOnDealloc: false).write(data)
    } else {
        FileHandle.standardOutput.write(data)
    }
    exit(output.exitCode)
}

/// Text for `trace decode` / `match`: stdin when something is piped in, otherwise (or with
/// --clipboard) the clipboard. nil when there is none, or when it exceeds the input cap
/// (then `agentInputTooLarge` is set).
var agentInputTooLarge = false
func readAgentInput(forceClipboard: Bool) -> String? {
    if forceClipboard || isatty(STDIN_FILENO) != 0 {
        let text = NSPasteboard.general.string(forType: .string)
        if let text, text.utf8.count > AgentCLI.maxInputBytes {
            agentInputTooLarge = true
            return nil
        }
        return text
    }
    var data = Data()
    let handle = FileHandle.standardInput
    while true {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        data.append(chunk)
        if data.count > AgentCLI.maxInputBytes {
            agentInputTooLarge = true
            return nil
        }
    }
    return String(data: data, encoding: .utf8)
}

func cmdSetTrace(_ value: String) {
    let valid = DictationTrace.OutputMode.allCases.map(\.rawValue)
    guard valid.contains(value) else {
        print("Usage: speakfree set-trace <off|tags|tags-only|expanded|selectors>")
        exit(1)
    }
    if ["tags-only", "expanded"].contains(value), !DictationTrace.testingAvailable {
        print("This trace output is available only in alpha or development builds.")
        exit(1)
    }
    var config = Config.load()
    config.dictationTrace = value == "off" ? nil : value
    do {
        try config.save()
        print(value == "off" ? "Dictation trace: off"
              : "Dictation trace: on (\(value)) in \(config.dictationTraceApps == nil ? "the default app list" : "\(config.dictationTraceApps!.count) listed apps")")
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : nil

switch command {
case "quit-clipy":
    exit(DeploymentClipyQuit.run(arguments: Array(args.dropFirst(2))))
case "quit-legacy-installed":
    exit(LegacyDeploymentQuit.run(arguments: Array(args.dropFirst(2))))
case "prepare-update":
    exit(UpdatePreparation.run(arguments: Array(args.dropFirst(2))))
case "start":
    cmdStart()
case "audio-check":
    print(AudioCaptureDiagnostics.run())
case "process":
    guard args.count > 2 else {
        print("Usage: speakfree process <wav>")
        exit(1)
    }
    cmdProcess(args[2])
case "transcribe":
    runAgentCommand { AgentCLI.transcribe(arguments: Array(args.dropFirst(2))) }
case "history":
    runAgentCommand { AgentCLI.history(arguments: Array(args.dropFirst(2))) }
case "vocab", "vocabulary":
    runAgentCommand { AgentCLI.vocab(arguments: Array(args.dropFirst(2))) }
case "trace":
    let rest = Array(args.dropFirst(2))
    guard rest.first == "decode", rest.dropFirst().allSatisfy({ $0 == "--clipboard" }) else {
        runAgentCommand { AgentCLI.traceUsage() }
    }
    let input = readAgentInput(forceClipboard: rest.contains("--clipboard"))
    if agentInputTooLarge { runAgentCommand { AgentCLI.inputTooLarge(schema: AgentCLI.traceSchema) } }
    runAgentCommand { AgentCLI.traceDecode(input: input) }
case "match":
    let rest = Array(args.dropFirst(2))
    if rest.contains("--hook") {
        // Hook mode: stdin is the hook's JSON. Print only a JSON object, or nothing at all,
        // and always exit 0 so a prompt is never blocked.
        let output = AgentCLI.matchHook(
            stdin: isatty(STDIN_FILENO) != 0 ? nil : readAgentInput(forceClipboard: false))
        if !output.json.isEmpty { FileHandle.standardOutput.write(Data((output.json + "\n").utf8)) }
        exit(0)
    }
    let input = readAgentInput(forceClipboard: rest.contains("--clipboard"))
    if agentInputTooLarge { runAgentCommand { AgentCLI.inputTooLarge(schema: AgentCLI.matchSchema) } }
    runAgentCommand { AgentCLI.match(arguments: rest, input: input) }
case "set-trace":
    guard args.count > 2 else {
        print("Usage: speakfree set-trace <off|tags|tags-only|expanded|selectors>")
        exit(1)
    }
    cmdSetTrace(args[2])
case "set-hotkey":
    guard args.count > 2 else {
        print("Usage: speakfree set-hotkey <key>")
        exit(1)
    }
    cmdSetHotkey(args[2])
case "set-model":
    guard args.count > 2 else {
        print("Usage: speakfree set-model <size>")
        exit(1)
    }
    cmdSetModel(args[2])
case "get-hotkey":
    cmdGetHotkey()
case "download-model":
    let size = args.count > 2 ? args[2] : "base.en"
    cmdDownloadModel(size)
case "set-engine":
    guard args.count > 2 else {
        print("Usage: speakfree set-engine <whisper|parakeet>")
        exit(1)
    }
    cmdSetEngine(args[2])
case "download-parakeet":
    // Default to the app's default model (English v2) so the bare command matches what a fresh
    // install expects. Important for the manual-install fallback instructions on the website.
    let id = args.count > 2 ? args[2] : Config.defaultParakeetModel
    cmdDownloadParakeet(id)
case "status":
    cmdStatus()
case "compat":
    guard args.count > 2, args[2] == "scan" else {
        print("Usage: speakfree compat scan [--tsv]")
        exit(1)
    }
    let rows = AppCompatScan.scan()
    print(args.dropFirst(3).contains("--tsv") ? AppCompatScan.renderTSV(rows) : AppCompatScan.renderMarkdown(rows))
case "precompile-parakeet":
    // Internal: the app runs its own executable with this command at launch to compile the
    // Parakeet model for the Neural Engine outside its own process (ParakeetFirstStart.swift).
    exit(ParakeetCompileHelperCommand.run(arguments: Array(args.dropFirst(2))))
case "notice-preview":
    // Dev-only: tile every recordings-notice design variant on screen, buttons inert.
    RecordingsNoticePreview.run()
case "overlay-preview":
    // Dev-only: loop the recording overlay's entry animation against simulated
    // speech, so the sequence can be judged without dictating. Mic untouched.
    RecordingOverlayPreview.run(style: args.count > 2 ? (Int(args[2]) ?? 5) : 5)
case "--help", "-h", "help":
    printUsage()
case nil:
    // Launched as app bundle (no arguments) — start the daemon
    if Bundle.main.object(forInfoDictionaryKey: "SFInertRecordingsReview") as? Bool == true {
        RecordingsNoticePreview.run()
    } else {
        cmdStart()
    }
default:
    print("Unknown command: \(command!)")
    printUsage()
    exit(1)
}
