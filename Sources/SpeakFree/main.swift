import AppKit
import Foundation
import OpenWisprLib

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let version = OpenWispr.version

func printUsage() {
    print("""
    speakfree v\(version) — Push-to-talk voice dictation for macOS

    USAGE:
        speakfree start              Start the dictation daemon
        speakfree process <wav>      Transcribe a wav file; prints JSON {raw, processed, styled}
        speakfree set-hotkey <key>   Set the push-to-talk hotkey
        speakfree get-hotkey         Show current hotkey
        speakfree set-model <size>   Set the Whisper model
        speakfree download-model [size]  Download a Whisper model
        speakfree status             Show configuration and status
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

    print("speakfree v\(version)")
    print("Config:      \(Config.configFile.path)")
    print("Hotkey:      \(hotkeyDesc)")
    print("Model:       \(config.modelSize)")
    print("Model ready: \(Transcriber.modelExists(modelSize: config.modelSize) ? "yes" : "no")")
    print("whisper-cpp: \(Transcriber.findWhisperBinary() != nil ? "yes" : "no")")
    let toggleMode = config.toggleMode?.value ?? false
    print("Toggle:      \(toggleMode ? "on (press to start/stop)" : "off (hold to talk)")")
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : nil

switch command {
case "start":
    cmdStart()
case "process":
    guard args.count > 2 else {
        print("Usage: speakfree process <wav>")
        exit(1)
    }
    cmdProcess(args[2])
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
case "status":
    cmdStatus()
case "--help", "-h", "help":
    printUsage()
case nil:
    // Launched as app bundle (no arguments) — start the daemon
    cmdStart()
default:
    print("Unknown command: \(command!)")
    printUsage()
    exit(1)
}
