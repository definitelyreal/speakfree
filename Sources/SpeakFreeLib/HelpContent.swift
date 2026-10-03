// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
//
// Help content as DATA, separate from the window that renders it
// ([HelpController.swift]). The previous Help was one hardcoded attributed string built
// inside the window initializer, and every fact in it had gone stale: it documented
// Whisper-only models while the default engine is Parakeet, named punctuation modes
// ("Hybrid", "Off", "Spoken words") that no longer exist in the picker, and pointed at a
// "Settings → Max Recordings" control that was replaced by the opt-in recordings toggle.
// See the internal help audit.
//
// Two rules keep it honest:
//   1. Anything the app already knows (version, build channel, dev mode, the hotkey the
//      user actually has, which engine is selected) is read from `HelpFacts`, not typed
//      into prose, so it cannot drift.
//   2. Control names, the model list, and the engine defaults are pinned by
//      HelpWindowTests against the real Settings UI and EngineCatalog.

import Foundation

/// One renderable line of help.
public enum HelpBlock: Equatable {
    /// Body prose. Blank-line separated when rendered.
    case paragraph(String)
    /// A bolded term and its explanation, for option lists.
    case row(String, String)
    /// A bulleted step.
    case bullet(String)
    /// A clickable link that performs an in-app action.
    case action(String, HelpAction)
    /// Vertical breathing room.
    case spacer
}

/// Actions the Help window can perform when a link is clicked. Rendered as
/// `speakfree-help://<rawValue>` link attributes and routed by HelpController.
public enum HelpAction: String, CaseIterable {
    case openSettings
    case openLogsFolder
    case openRecordingsFolder
    case openVocabularyFile
    case openMicrophonePrivacy
    case openAccessibilityPrivacy
    case openRepo

    static let scheme = "speakfree-help"

    public var url: URL {
        // Force-unwrap is safe: rawValue is a fixed lowercase identifier.
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }

    public static func from(url: URL) -> HelpAction? {
        guard url.scheme == scheme else { return nil }
        // "speakfree-help://openSettings" parses the identifier as the HOST. Matched
        // case-insensitively because host-case preservation is not something to depend on: it is
        // preserved on macOS 15 (verified) but URL/RFC semantics treat hosts as case-insensitive,
        // so a future OS lowercasing them must not silently kill every link in this window.
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        return allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }
}

/// One topic in the Help sidebar.
public struct HelpTopic: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let blocks: [HelpBlock]
}

/// Live facts about THIS install, so help text never claims something the running app
/// contradicts. Mirrors the menu-title rule in the project CLAUDE.md: never let the user
/// guess what they are running.
public struct HelpFacts: Equatable {
    public var version: String
    public var buildDescription: String
    public var devMode: Bool
    public var hotkeyName: String
    public var isToggleMode: Bool
    public var isEditMode: Bool
    public var engineID: String
    public var whisperModel: String
    public var parakeetModel: String
    public var saveRecordings: Bool
    public var punctuationMode: PunctuationMode
    public var recordingsPath: String
    public var vocabularyPath: String
    public var logsPath: String

    public var engineIsParakeet: Bool { engineID != "whisper" }

    /// Name of the engine as the Settings picker labels it.
    public var engineDisplayName: String {
        EngineCatalog.engines.first { $0.id == engineID }?.displayName ?? engineID
    }

    /// The model actually in use for the selected engine, as Settings labels it.
    public var activeModelName: String {
        if engineIsParakeet {
            return EngineCatalog.parakeetModels.first { $0.id == parakeetModel }?.displayName
                ?? parakeetModel
        }
        return whisperModel
    }

    public var punctuationDisplayName: String {
        switch punctuationMode {
        case .hybrid: return "Automatic & Spoken"
        case .off: return "Automatic Only"
        case .spoken:
            // On Parakeet, Spoken Only is not offered and behaves identically to Automatic &
            // Spoken (Parakeet ignores auto-punct suppression). Report the effective behavior so
            // Help never announces a mode the app is not actually running.
            return engineIsParakeet ? "Automatic & Spoken" : "Spoken Only"
        }
    }

    public init(version: String,
                buildDescription: String,
                devMode: Bool,
                hotkeyName: String,
                isToggleMode: Bool,
                engineID: String,
                whisperModel: String,
                parakeetModel: String,
                saveRecordings: Bool,
                punctuationMode: PunctuationMode = .off,
                recordingsPath: String,
                vocabularyPath: String,
                logsPath: String,
                isEditMode: Bool = false) {
        self.version = version
        self.buildDescription = buildDescription
        self.devMode = devMode
        self.hotkeyName = hotkeyName
        self.isToggleMode = isToggleMode
        self.isEditMode = isEditMode
        self.engineID = engineID
        self.whisperModel = whisperModel
        self.parakeetModel = parakeetModel
        self.saveRecordings = saveRecordings
        self.punctuationMode = punctuationMode
        self.recordingsPath = recordingsPath
        self.vocabularyPath = vocabularyPath
        self.logsPath = logsPath
    }

    /// Snapshot the running app. Reads config from disk, so it reflects changes made in
    /// Settings since launch.
    public static func live(config: Config? = nil) -> HelpFacts {
        let c = config ?? Config.load()
        return HelpFacts(
            version: SpeakFree.version,
            buildDescription: SpeakFree.menuTitle,
            devMode: DevMode.isActive,
            hotkeyName: KeyCodes.displayName(keyCode: c.hotkey.keyCode),
            isToggleMode: c.effectiveKeyMode == .toggle,
            // Resolve EXACTLY as the runtime does, not as `defaultConfig` does. EngineFactory
            // and AppDelegate use `?? "whisper"` / `?? "parakeet-tdt-0.6b-v3"`, and Config.swift
            // documents that split as deliberate: the NEW-install defaults must not retroactively
            // reinterpret a whisper-era config that has no `engine` key. Using
            // `Config.defaultEngine` here made Help announce "You are using Parakeet" on a legacy
            // config while EngineFactory built Whisper (2026-07-26 round-2 review) — the same
            // class of lie this file exists to end.
            engineID: c.engine ?? "whisper",
            whisperModel: c.modelSize,
            parakeetModel: c.parakeetModel ?? "parakeet-tdt-0.6b-v3",
            saveRecordings: DevMode.effectiveSaveRecordings(c),
            punctuationMode: c.effectivePunctuationMode,
            recordingsPath: RecordingStore.recordingsDir.path,
            vocabularyPath: Config.vocabularyFile.path,
            logsPath: Config.configDir.appendingPathComponent("logs").path,
            isEditMode: c.effectiveKeyMode == .edit
        )
    }
}

public enum HelpContent {

    /// Every topic, in sidebar order. Ordered so the first four answer the questions people
    /// actually arrive with, and troubleshooting sits at the end where it is looked up.
    public static func topics(_ facts: HelpFacts) -> [HelpTopic] {
        [
            gettingStarted(facts),
            hotkey(facts),
            editMode(facts),
            history(facts),
            enginesAndModels(facts),
            languages(facts),
            punctuation(facts),
            vocabulary(facts),
            recordingsAndPrivacy(facts),
            recovering(facts),
            audioFiles(facts),
            microphone(facts),
            experimental(facts),
            performance(facts),
            troubleshooting(facts),
            about(facts),
        ]
    }

    // MARK: - Topics

    private static func gettingStarted(_ f: HelpFacts) -> HelpTopic {
        var blocks: [HelpBlock] = []
        if f.isEditMode {
            blocks.append(.paragraph(
                "Tap \(f.hotkeyName) to open the Edit window and start recording. Tap again to "
                + "stop the take. Further takes add paragraphs; review the text, then press "
                + "Return to insert it into the original destination when it can be confirmed."))
        } else if f.isToggleMode {
            blocks.append(.paragraph(
                "Press \(f.hotkeyName) once to start recording, speak, then press it again to "
                + "stop. speakfree transcribes your voice on your own Mac and types the text "
                + "wherever your cursor is."))
        } else {
            blocks.append(.paragraph(
                "Hold \(f.hotkeyName), speak, then let go. speakfree transcribes your voice on "
                + "your own Mac and types the text wherever your cursor is."))
        }
        blocks.append(contentsOf: [
            .paragraph("A few things worth knowing early:"),
            .bullet("If speakfree cannot safely insert your text, it offers a clipboard copy "
                    + "or keeps selectable text for recovery. Check the recovery message "
                    + "before pasting; macOS can refuse a clipboard write."),
            .bullet("A recording banner appears while you speak. It shows the microphone level, "
                    + "so you can tell speakfree is hearing you."),
            .bullet("The first dictation after launch can be a moment slower while the model "
                    + "loads. After that it is fast."),
            .bullet("When speakfree can see where your cursor is, it adds a leading space if it "
                    + "is continuing a line, and lowercases the first word if it is continuing a "
                    + "sentence. Some apps do not report the cursor, and there it skips just "
                    + "those two adjustments. Everything else, including your vocabulary "
                    + "corrections and spoken punctuation, is applied either way."),
            .spacer,
            .paragraph("You are running \(f.buildDescription), using \(f.activeModelName)."),
            .action("Open Settings", .openSettings),
        ])
        return HelpTopic(id: "getting-started", title: "Getting Started", blocks: blocks)
    }

    private static func hotkey(_ f: HelpFacts) -> HelpTopic {
        var blocks: [HelpBlock] = [
            .paragraph("Your hotkey is currently \(f.hotkeyName), in "
                       + "\(f.isEditMode ? "Edit" : f.isToggleMode ? "Toggle" : "Hold") mode. Change both under "
                       + "Settings → Dictation → General → Hotkey."),
            .paragraph("The three modes:"),
            .row("Hold", "Hold the key down for as long as you are speaking, release to "
                 + "transcribe. Best for short dictation, and there is no way to leave a "
                 + "recording running by accident."),
            .row("Toggle", "Tap once to start, tap again to stop. Better for long dictation, "
                 + "and for anyone who finds holding a key uncomfortable."),
            .row("Edit", "Tap to open the editing window and record. Tap again to stop a take; "
                 + "add more takes as paragraphs and press Return when ready to insert."),
            .spacer,
            .paragraph("Any of these keys can be the hotkey:"),
            .row("Globe / fn", "The key in the bottom-left corner. The default."),
            .row("Left or Right Command", "\u{2318}"),
            .row("Left or Right Option", "\u{2325}"),
            .row("Left Control", "\u{2303}"),
            .spacer,
            .paragraph("\"Other…\" lets you pick a different key by pressing it."),
            .paragraph("Keyboard shortcuts still work. With any of the modifier keys above, "
                       + "pressing another key within 300 milliseconds of the hotkey tells "
                       + "speakfree it was a shortcut, so it throws the recording away and stays "
                       + "out of your way. A non-modifier key chosen through \"Other…\" does not "
                       + "get that treatment, so pick one you do not otherwise type."),
        ]
        if f.hotkeyName.contains("Globe") || f.hotkeyName.contains("fn") {
            blocks.append(contentsOf: [
                .spacer,
                .paragraph("While the Globe / fn key is your hotkey, speakfree takes it over "
                           + "completely, so the macOS emoji drawer that key normally opens will "
                           + "not appear. If you want the emoji drawer back, switch your hotkey "
                           + "to Right Option in Settings."),
            ])
        }
        blocks.append(.action("Open Settings", .openSettings))
        return HelpTopic(id: "hotkey", title: "Your Hotkey", blocks: blocks)
    }

    private static func editMode(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "edit-mode", title: "Edit Mode", blocks: [
            .paragraph("Choose Edit under Settings → Dictation → General → Hotkey. Your "
                       + "dictation key opens the Edit window and starts a take; another tap "
                       + "stops it. Additional takes become separate paragraphs."),
            .paragraph("You can type corrections in the window. Return inserts the reviewed "
                       + "text; Shift+Return adds a line break within a paragraph. Esc cancels "
                       + "a current take, or asks for another Esc before discarding session text."),
            .paragraph("The destination is shown at the top. If the original destination cannot "
                       + "be confirmed, the text stays available for recovery instead of being "
                       + "silently sent to another control."),
            .paragraph("Options controls optional Claude cleanup. It requires your consent and "
                       + "a signed-in Claude Code CLI; paragraph text is sent to Claude. You can "
                       + "use the editing window with cleanup off."),
            .paragraph("Use Changes (⌘I) to inspect Current, Previous and Original versions, "
                       + "restore a version or undo individual changes. Review cleanup results "
                       + "before inserting them."),
            .action("Open Settings", .openSettings),
        ])
    }

    private static func history(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "history", title: "History & Clipboard", blocks: [
            .paragraph("History brings recent dictations and optional clipboard items into one "
                       + "small searchable menu. ⌥⇧V opens Dictations and ⇧⌘V opens Clipboard. "
                       + "Set shortcuts for Dictations, Clipboard and All directly in the key "
                       + "fields under Settings → Clipboard; All starts without a shortcut."),
            .paragraph("Type to search, use arrow keys to select, and press Return or click a "
                       + "row once to paste. ⌘↓ and ⌘↑ move by a page. Dictations, Clipboard "
                       + "and All filter the same history. ⌘1, ⌘2 and ⌘3 select them in that order."),
            .paragraph("Clipboard capture is optional. When it is off, the dim Clipboard "
                       + "filter explains how to enable it and offers a Preferences button."),
            .paragraph("Choose Off, Until speakfree quits, or 7 days on this Mac for history "
                       + "retention. Text, rich formatting, images and file references are "
                       + "supported within the size limits shown in Clipboard settings. File "
                       + "references depend on the original files staying available."),
            .paragraph("Selecting a history item makes it the current clipboard. Temporary "
                       + "dictation pastes use a separate save-and-restore path. Clearing "
                       + "history does not delete saved recordings or transcript archives."),
            .action("Open Settings", .openSettings),
        ])
    }

    private static func enginesAndModels(_ f: HelpFacts) -> HelpTopic {
        var blocks: [HelpBlock] = [
            .paragraph("speakfree can transcribe with either of two local engines, chosen under "
                       + "Settings → Dictation → Transcription. You are using \(f.engineDisplayName) with "
                       + "\(f.activeModelName)."),
            .row(EngineCatalog.engines.first { $0.id == "parakeet" }?.displayName ?? "Parakeet",
                 "NVIDIA's model, on the Apple Neural Engine. The default for new installs: "
                 + "fast, accurate, and it manages its own memory. It transcribes after you "
                 + "finish speaking, so it has no live preview."),
            .row(EngineCatalog.engines.first { $0.id == "whisper" }?.displayName ?? "Whisper",
                 "OpenAI's model, on CPU/GPU. More sizes to choose from, and more languages."),
            .spacer,
            .paragraph("Parakeet models:"),
        ]
        for model in EngineCatalog.parakeetModels {
            let languages = model.supportedLanguages.count == 1
                ? "English only"
                : "\(model.supportedLanguages.count)+ languages"
            blocks.append(.row(model.displayName, "\(model.sizeDescription) · \(languages)"))
        }
        // Listed from the same table the Settings picker reads, so the two cannot drift apart
        // again. The recommendation depends on how much memory this Mac has, so it is computed,
        // not written into the prose.
        let recommendedBase = EngineCatalog.recommendedWhisperBase()
        blocks.append(contentsOf: [
            .spacer,
            .paragraph("Whisper models. Larger is more accurate but slower to load, and holds "
                       + "more in memory. The recommendation depends on how much memory your Mac "
                       + "has, so it is marked in the Settings picker rather than fixed here:"),
        ])
        for model in EngineCatalog.whisperModels {
            let recommended = model.base == recommendedBase ? " · Recommended on this Mac" : ""
            let names = model.englishID == model.multilingualID
                ? model.englishID
                : "\(model.englishID) / \(model.multilingualID)"
            blocks.append(.row(names,
                               "\(model.memoryDescription) in memory · "
                               + "\(model.loadTimeDescription) to load" + recommended))
        }
        blocks.append(contentsOf: [
            .spacer,
            .paragraph("The \".en\" builds are English-only and a little sharper on English; the "
                       + "plain names are multilingual. speakfree picks between them from your "
                       + "language setting, so the picker shows one or the other, not both."),
            .paragraph("Picking a model you do not have yet does NOT start a download on its "
                       + "own: a Download button appears next to it and waits for you, so "
                       + "selecting something large by accident never costs you bandwidth, and "
                       + "your current model keeps working until the new one is ready. Once "
                       + "downloaded it stays on your Mac, and nothing is uploaded in either "
                       + "direction."),
            .action("Open Settings", .openSettings),
        ])
        return HelpTopic(id: "engines", title: "Engines & Models", blocks: blocks)
    }

    private static func languages(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "languages", title: "Languages", blocks: [
            .paragraph("Set your language under Settings → Dictation → Transcription → Language. The row is "
                       + "hidden while an English-only Parakeet model is selected, which is the "
                       + "default: there is nothing to choose. Switch to Parakeet v3 or to "
                       + "Whisper and it appears."),
            .row("A specific language", "Most accurate. speakfree will not try to guess, and "
                 + "will not drift into another language mid-sentence."),
            .row("Auto-detect", "Convenient if you switch languages often. Slightly less "
                 + "accurate, and short utterances are the hardest to detect."),
            .spacer,
            .paragraph("Each language remembers its own model, so you can run a small English "
                       + "model for speed and a larger multilingual one for everything else "
                       + "without re-picking every time."),
            .paragraph("Parakeet v2 is English-only. To dictate in another language, either "
                       + "switch to Parakeet v3 or use Whisper with a multilingual model, which "
                       + "means one without the \".en\" suffix."),
            .action("Open Settings", .openSettings),
        ])
    }

    private static func punctuation(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "punctuation", title: "Punctuation", blocks: [
            .paragraph("Choose under Settings → Dictation → Transcription → Punctuation. You are using "
                       + "\(f.punctuationDisplayName)."),
            .row("Automatic & Spoken", "The engine punctuates from your speech patterns, AND you "
                 + "can say \"comma\", \"period\", \"question mark\", \"new line\" and the rest "
                 + "to place punctuation yourself. The default, and the recommendation."),
            .row("Automatic Only", "The engine punctuates on its own and speakfree leaves the "
                 + "result alone: saying \"comma\" types the word comma, and none of the tidying "
                 + "the other modes do (collapsing runs of commas, repairing spacing) is applied "
                 + "either. The most literal option."),
            .row("Spoken Only", "For when you want to place every mark yourself. The engine's own "
                 + "automatic punctuation is turned off, so only the marks you speak appear. Your "
                 + "spoken words are converted with the same safeguards as Automatic & Spoken, so "
                 + "phrases like \"a period of time\" and \"colon cancer\" are left alone. Turning "
                 + "off the engine's punctuation only works on Whisper, so this mode is offered on "
                 + "Whisper only. On Parakeet it is not shown, because Parakeet cannot suppress its "
                 + "own punctuation and the mode would be identical to Automatic & Spoken there."),
            .spacer,
            .paragraph("Spoken punctuation understands the common names, including \"period\", "
                       + "\"comma\", \"question mark\", \"exclamation point\", \"colon\", "
                       + "\"semicolon\", \"dash\", \"open quote\" and \"close quote\", plus "
                       + "\"new line\" and \"new paragraph\". A line break at the very end of "
                       + "a dictation is left out in every app (in a terminal it could run the "
                       + "line); line breaks in the middle are kept."),
            .action("Open Settings", .openSettings),
        ])
    }

    private static func vocabulary(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "vocabulary", title: "Vocabulary", blocks: [
            .paragraph("Names, jargon, and acronyms are what speech models get wrong most often. "
                       + "The vocabulary file is a plain list of the spellings you want: one entry "
                       + "per line, lines starting with # ignored."),
            .paragraph("When a transcription comes back close to one of your entries, speakfree "
                       + "corrects it to your spelling. It is deliberately cautious, because a "
                       + "list that rewrites ordinary words does more damage than the "
                       + "misrecognitions it fixes:"),
            .bullet("Single words only, for correcting. A multi-word phrase is still passed to "
                    + "Whisper as a hint, but it is never used to rewrite a transcription, and "
                    + "Parakeet ignores hints entirely."),
            .bullet("A misheard word is only corrected if it is at least four characters and "
                    + "within one or two edits of an entry, where the edits also have to be a "
                    + "small fraction of the word's length, so short names are stricter than long "
                    + "ones. If more than one entry is that close, speakfree does not guess: it "
                    + "leaves the word alone rather than picking a winner."),
            .bullet("Never rewrites a legitimate English word. Adding \"Will\" or \"Grace\" does "
                    + "nothing at all, even when you say exactly that word, because rewriting real "
                    + "words corrupts ordinary sentences (\"I will send it\" turning into \"I Will "
                    + "send it\" is why the guard exists). If you genuinely need a real word "
                    + "respelled, the separate overrides file is the deliberate way to force it."),
            .spacer,
            .paragraph("Edit it under Settings → Vocabulary & Context, or open it directly:"),
            .action("Open Vocabulary File", .openVocabularyFile),
            .paragraph(f.vocabularyPath),
        ])
    }

    private static func recordingsAndPrivacy(_ f: HelpFacts) -> HelpTopic {
        var blocks: [HelpBlock] = [
            .paragraph("Speech recognition runs locally on your Mac and does not require a "
                       + "speakfree account. Models and app updates use the internet. Optional "
                       + "Edit Mode cleanup is different: after you consent, paragraph text "
                       + "is sent through your signed-in Claude Code CLI to Claude. Leave "
                       + "cleanup off to keep that text processing on your Mac."),
            .paragraph("Audio is written to a file, transcribed on your device, and then deleted "
                       + "unless you asked to keep it. It is written to the recordings folder "
                       + "rather than a temporary one on purpose, so a crash mid-dictation can "
                       + "still be recovered. One exception: if a recording captured no audio at "
                       + "all, the file is kept even with saving off, because that is the "
                       + "evidence needed to work out why the microphone was silent."),
            .spacer,
            .paragraph("Keeping recordings is optional and OFF by default. Turn on \"Save "
                       + "recordings and transcripts\" under Settings → Dictation → General and speakfree "
                       + "keeps each dictation's audio and its text next to it, on your Mac only. "
                       + "A \"Past Recordings\" row then appears, setting how many to keep; it is "
                       + "hidden while saving is off, because there is nothing to cap."),
        ]
        if f.devMode {
            blocks.append(.paragraph(
                "On this Mac, developer mode is active (the ~/.speakfree-dev marker file "
                + "exists), so recordings are saved regardless of that checkbox."))
        }
        blocks.append(contentsOf: [
            .paragraph(f.saveRecordings
                       ? "Recordings are currently being saved to:"
                       : "Recordings are currently NOT being saved. If any exist from earlier, "
                         + "they are at:"),
            .paragraph(f.recordingsPath),
            .action("Open Recordings Folder", .openRecordingsFolder),
            .spacer,
            .paragraph("Once recordings exist, Settings → Dictation → General shows how many you have with a "
                       + "\"\(NoticeCopy.deleteLinkText)\" link below the count. That moves the audio "
                       + "and the transcripts together."),
            .action("Open Settings", .openSettings),
        ])
        return HelpTopic(id: "privacy", title: "Recordings & Privacy", blocks: blocks)
    }

    private static func recovering(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "recovery", title: "Recovering a Lost Dictation", blocks: [
            .paragraph("If speakfree quits unexpectedly while you are recording, the audio is "
                       + "kept so the words are not lost."),
            .paragraph("There is nothing to click. speakfree finds what was left behind on a "
                       + "later launch and transcribes it in the background, waiting for idle "
                       + "moments so a live dictation is never queued behind a recovery. The "
                       + "recovered text then appears in Recent Dictations like any other."),
            .paragraph("Two details worth knowing if you go looking for it: a recording has to be "
                       + "a couple of minutes old before it is treated as abandoned, so relaunching "
                       + "immediately after a crash will not recover it on that launch, and only "
                       + "the few most recent are swept, from the last two weeks."),
            .paragraph("Recent Dictations holds your recent transcriptions. Clicking one types it "
                       + "into the frontmost window, or copies it to the clipboard if it cannot "
                       + "type there. The list is normally only populated while \"Save recordings "
                       + "and transcripts\" is on, since that is what writes the text to disk. Two "
                       + "things still appear with saving off: anything recovered after a crash, "
                       + "and a recording that captured no audio, which is kept as evidence and "
                       + "shows as having no transcript."),
        ])
    }

    private static func audioFiles(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "audio-files", title: "Transcribing Audio Files", blocks: [
            .paragraph("\"Transcribe Audio File…\" in the menu transcribes a recording you "
                       + "already have. Useful for voice memos, interviews, and meeting audio."),
            .paragraph("It opens its own window: pick one file, pick the engine, model and "
                       + "output format, pick where the transcript goes, and watch progress "
                       + "there. Nothing is copied to your clipboard, so a long transcription "
                       + "cannot clobber what you had on it."),
            .paragraph("Its engine and model are its OWN settings, separate from the ones your "
                       + "dictation uses, and they start out as Whisper large-v3-turbo. If you "
                       + "dictate with Parakeet and have never downloaded a Whisper model, the "
                       + "window will say no model is downloaded until you either pick Parakeet "
                       + "there or let it fetch a Whisper model."),
            .paragraph("The transcript is written to your Documents folder by default, named "
                       + "after the audio file. Long files take a while. This is all local too, "
                       + "and files are never uploaded."),
        ])
    }

    private static func microphone(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "microphone", title: "Microphone", blocks: [
            .paragraph("Choose your input device in Settings under Microphone. The built-in "
                       + "mic is the default and transcribes most reliably: Bluetooth mics "
                       + "(AirPods) degrade quality unpredictably, and virtual devices (Zoom, "
                       + "Splashtop) can record silence. Picking a specific device pins "
                       + "speakfree to it, so plugging in headphones or joining a call does "
                       + "not change what it records from."),
            .paragraph("If a pinned device is unplugged, speakfree falls back to this Mac's own "
                       + "microphone rather than failing to record."),
            .paragraph("AirPods and other Bluetooth headsets are never used automatically. To dictate "
                       + "through one, choose \"Stay on <headset>\" in the menu (2 hours by default; "
                       + "\"Other durations\" has the rest). While Stay on is on, music on the headset "
                       + "sounds like a phone call, because Bluetooth only carries a microphone in its "
                       + "call mode, and AirPods may switch over from your iPhone. It lasts through "
                       + "disconnects and ends on its own."),
            .paragraph("If a long dictation comes back nearly empty in a noisy room and a headset is "
                       + "connected, speakfree switches to it for 2 hours and says so, with Undo. If "
                       + "music is playing on the headset, it asks first."),
            .spacer,
            .paragraph("If nothing is being heard at all, check that speakfree has microphone "
                       + "permission:"),
            .action("Open Microphone Privacy Settings", .openMicrophonePrivacy),
        ])
    }

    private static func experimental(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "experimental", title: "Experimental Features", blocks: [
            .paragraph("These live under Settings → Dictation → Advanced, each labelled \"(Experimental)\". "
                       + "They work, but they are rougher than the rest of the app."),
            .row("Live Preview", "Shows text in the recording banner as you speak, instead of "
                 + "only at the end. The preview revises itself as more audio arrives, so it "
                 + "flickers. The final transcription is unaffected. On by default, and it does "
                 + "nothing on Parakeet, which only transcribes once you stop speaking."),
            .row("Screen Context", "Off by default. Reads on-screen text with local OCR and feeds "
                 + "it in as vocabulary hints, which helps with names visible in the window you "
                 + "are typing into. It can backfire: the engine sometimes transcribes what is on "
                 + "screen instead of what you said."),
            .row("Local Transcription API", "Off by default. Serves an OpenAI-compatible "
                 + "transcription endpoint on localhost, so your own scripts and any compatible "
                 + "client can use speakfree's engine. It refuses any connection that is not from "
                 + "this Mac, and fails closed if it cannot tell."),
            .action("Open Settings", .openSettings),
        ])
    }

    private static func performance(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "performance", title: "Speed & Memory", blocks: [
            .paragraph("Under Settings → Dictation → Performance."),
            .row("Model Loading: Automatic", "Keeps the model in memory but hands it back "
                 + "whenever your Mac needs the RAM. The default, and the right answer for "
                 + "nearly everyone."),
            .row("Model Loading: Always", "Never unloads. The fastest first word, at the cost of "
                 + "holding memory permanently."),
            .row("Model Loading: Off", "Loads on every dictation and unloads after. Lowest memory "
                 + "use, slowest start. Parakeet manages its own memory, so this setting does "
                 + "nothing when Parakeet is selected."),
            .row("Pre-Buffer Audio", "Records a moment of audio before the hotkey is pressed, so "
                 + "words spoken slightly early are still captured. On by default."),
            .spacer,
            .paragraph("A bigger model is slower in a way you can feel on long dictation. If "
                       + "transcription feels sluggish, drop one model size before changing "
                       + "anything else."),
            .action("Open Settings", .openSettings),
        ])
    }

    private static func troubleshooting(_ f: HelpFacts) -> HelpTopic {
        HelpTopic(id: "troubleshooting", title: "When Something Goes Wrong", blocks: [
            .paragraph("speakfree needs two macOS permissions to work at all. Almost every problem "
                       + "is one of them having been revoked. (Screen Context, if you turn it on, "
                       + "additionally asks for Screen Recording; nothing else needs it.)"),
            .row("Microphone", "To hear you. Without it, recordings are silent."),
            .row("Accessibility", "To watch for your hotkey and to type the text. Without it "
                 + "speakfree does not start at all: it waits, re-asking every minute, and the "
                 + "menu-bar icon says it is waiting for permission. Granting it starts "
                 + "everything automatically, with no relaunch."),
            .action("Open Microphone Privacy Settings", .openMicrophonePrivacy),
            .action("Open Accessibility Privacy Settings", .openAccessibilityPrivacy),
            .spacer,
            .paragraph("The hotkey stopped responding."),
            .bullet("macOS sometimes disables an app's key monitoring after the system has been "
                    + "busy. speakfree notices and re-establishes it, but quitting from the menu "
                    + "and reopening is the quick fix."),
            .bullet("If speakfree was replaced with a new build, macOS may have quietly dropped "
                    + "its Accessibility permission. Toggle speakfree off and back on in the "
                    + "Accessibility list."),
            .bullet("Check that no second copy of speakfree is running. Two instances fight over "
                    + "the same hotkey, and only one of them records."),
            .spacer,
            .paragraph("Text goes to the clipboard instead of into the app."),
            .bullet("That is the deliberate fallback for when no text field is focused. Click "
                    + "into the field first, or just paste."),
            .bullet("While any app has secure keyboard entry turned on, which password fields do "
                    + "system-wide rather than just in their own window, nothing can type for "
                    + "you. speakfree puts the text on the clipboard instead, and clears it "
                    + "shortly afterwards so a password field does not leave your dictation "
                    + "sitting there."),
            .spacer,
            .paragraph("Words are missing from the start or end."),
            .bullet("Turn on Pre-Buffer Audio under Settings → Dictation → Performance for the start."),
            .bullet("For the end, leave a beat of silence before releasing the hotkey. speakfree "
                    + "keeps capturing for a fraction of a second after you let go, and pads the "
                    + "audio for the engine, but releasing while still mid-word can still clip "
                    + "the last one."),
            .spacer,
            .paragraph("Still wrong? Turn on Diagnostic Logging under Settings → Dictation → Advanced, "
                       + "reproduce the problem, and the log will describe what happened. Logs "
                       + "stay on your Mac."),
            .action("Open Logs Folder", .openLogsFolder),
            .action("Report an Issue on GitHub", .openRepo),
        ])
    }

    private static func about(_ f: HelpFacts) -> HelpTopic {
        var blocks: [HelpBlock] = [
            .paragraph(f.buildDescription),
            .paragraph("A build whose title says \"Testing\" was built locally and is not the "
                       + "released version. Only the released build shows a plain version "
                       + "number."),
        ]
        if f.devMode {
            blocks.append(.paragraph(
                "Developer mode is active on this Mac: recordings always save and the recordings "
                + "notice is suppressed. Diagnostic logging is a separate switch under Settings "
                + "\u{2192} Advanced and is not affected. Delete ~/.speakfree-dev to return to "
                + "stock behavior."))
        }
        blocks.append(contentsOf: [
            .spacer,
            .paragraph("speakfree is open source. Bugs, ideas, and pull requests are all welcome."),
            .action("speakfree on GitHub", .openRepo),
            .spacer,
            .paragraph("Settings, your vocabulary, and Whisper models live in "
                       + "\(Config.configDir.path)."),
            .paragraph("Parakeet models are cached separately, under "
                       + "~/Library/Application Support/FluidAudio/Models."),
            .paragraph("Logs live in \(f.logsPath)."),
        ])
        return HelpTopic(id: "about", title: "About speakfree", blocks: blocks)
    }
}
