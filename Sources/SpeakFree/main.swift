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
        tiny.en, tiny, base.en, base, small.en, small, medium.en, medium, large
    """)
}

func cmdStart() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    signal(SIGINT) { _ in
        print("\nStopping speakfree...")
        exit(0)
    }

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
    let validSizes = ["tiny.en", "tiny", "base.en", "base", "small.en", "small", "medium.en", "medium", "large"]
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
