import AppKit
import Foundation

class VocabularyMigration {

    /// Check if migration is needed and run it. Call from AppDelegate.setupInner() on main thread.
    static func runIfNeeded() {
        let sentinel = Config.configDir.appendingPathComponent(".migration-v1")
        guard !FileManager.default.fileExists(atPath: sentinel.path) else { return }

        let dictionary = WordMemory.load()
        guard !dictionary.isEmpty else {
            writeSentinel(sentinel)
            return
        }

        let garbage = detectGarbage(in: dictionary)
        guard !garbage.isEmpty else {
            writeSentinel(sentinel)
            return
        }

        // Show dialog on main thread
        showCleanupDialog(garbage: garbage, sentinel: sentinel)
    }

    // MARK: - Detection

    /// Detect garbage entries in the dictionary.
    /// An entry is garbage if any of these are true:
    /// - Either word is <= 2 characters
    /// - The "right" word looks truncated (e.g. we'r, co-h, opposit.y)
    /// - Correction chains exist (A->B and B->C both in dictionary)
    /// - Words are not similar (edit distance > 40% of longer word)
    static func detectGarbage(in dictionary: [String: String]) -> [(wrong: String, right: String)] {
        // Build reverse lookup: right -> [wrong] for chain detection
        let rightValues = Set(dictionary.values.map { $0.lowercased() })

        var garbage: [(wrong: String, right: String)] = []
        var seen = Set<String>()

        for (wrong, right) in dictionary {
            let key = "\(wrong.lowercased())|\(right.lowercased())"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            if isGarbage(wrong: wrong, right: right, rightValues: rightValues, dictionary: dictionary) {
                garbage.append((wrong: wrong, right: right))
            }
        }

        // Sort for consistent display: alphabetical by wrong word
        return garbage.sorted { $0.wrong.lowercased() < $1.wrong.lowercased() }
    }

    private static func isGarbage(wrong: String, right: String, rightValues: Set<String>, dictionary: [String: String]) -> Bool {
        // Rule 1: Either word is <= 2 characters
        if wrong.count <= 2 || right.count <= 2 {
            return true
        }

        // Rule 2: Right word looks truncated
        if looksTruncated(right) {
            return true
        }

        // Rule 3: Correction chain — wrong->right and right->something_else
        if dictionary[right.lowercased()] != nil {
            return true
        }
        // Also check if wrong is the target of another correction (something->wrong->right)
        if rightValues.contains(wrong.lowercased()) {
            // wrong is used as a "right" value somewhere else, creating a chain
            return true
        }

        // Rule 4: Words are not similar enough
        if !LevenshteinDistance.isSimilar(wrong, right) {
            return true
        }

        return false
    }

    /// Check if a word looks truncated/malformed:
    /// - Ends with single quote followed by 1 char (we'r, you'l)
    /// - Contains a period mid-word (opposit.y)
    /// - Is a hyphenated fragment (co-h, co-hos)
    private static func looksTruncated(_ word: String) -> Bool {
        // Single quote followed by exactly 1 char at end: we'r, you'l
        let singleQuotePattern = #"'[a-zA-Z]$"#
        if word.range(of: singleQuotePattern, options: .regularExpression) != nil {
            // Check it's not a valid contraction (e.g. we're has 2+ chars after quote)
            // We're looking for words where there's only 1 char after the last quote
            if let quoteIndex = word.lastIndex(of: "'") {
                let afterQuote = word[word.index(after: quoteIndex)...]
                if afterQuote.count == 1 {
                    return true
                }
            }
        }

        // Period mid-word (not at start or end as sentence punctuation)
        if word.count > 2 {
            let inner = word.dropFirst().dropLast()
            if inner.contains(".") {
                return true
            }
        }

        // Hyphenated fragment: the part after the last hyphen is <= 2 chars
        if word.contains("-") {
            let parts = word.split(separator: "-")
            if let lastPart = parts.last, lastPart.count <= 2 {
                return true
            }
        }

        return false
    }

    // MARK: - Dialog

    private static func showCleanupDialog(garbage: [(wrong: String, right: String)], sentinel: URL) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Vocabulary Cleanup"
        panel.center()

        let content = panel.contentView!

        // Explanation label
        let label = NSTextField(wrappingLabelWithString:
            "speakfree found auto-learned entries that look incorrect. These were caused by a bug in how word corrections were detected (now fixed).\n\nThe following entries will be removed. Delete a line to keep that entry:")
        label.font = NSFont.systemFont(ofSize: 13)
        label.frame = NSRect(x: 20, y: 310, width: 440, height: 70)
        content.addSubview(label)

        // Editable text view in scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 70, width: 440, height: 230))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 230))
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = garbage.map { "\($0.wrong) \u{2192} \($0.right)" }.joined(separator: "\n")
        textView.textContainerInset = NSSize(width: 8, height: 8)

        scrollView.documentView = textView
        content.addSubview(scrollView)

        // Buttons
        // "Clean Up" is the primary action button (blue, right side)
        let cleanButton = NSButton(title: "Clean Up", target: nil, action: nil)
        cleanButton.bezelStyle = .rounded
        cleanButton.keyEquivalent = "\r"
        cleanButton.frame = NSRect(x: 370, y: 20, width: 90, height: 32)

        // "Skip" is secondary (left side)
        let skipButton = NSButton(title: "Skip", target: nil, action: nil)
        skipButton.bezelStyle = .rounded
        skipButton.frame = NSRect(x: 270, y: 20, width: 80, height: 32)

        // Use NSObject targets for button actions
        class ButtonHandler: NSObject {
            let action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action; super.init() }
            @objc func handle() { action() }
        }

        // Need to retain the handlers
        var handlers: [ButtonHandler] = []

        let skipHandler = ButtonHandler {
            writeSentinel(sentinel)
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        handlers.append(skipHandler)
        skipButton.target = skipHandler
        skipButton.action = #selector(ButtonHandler.handle)

        let cleanHandler = ButtonHandler {
            // Parse lines remaining in text view
            let remainingLines = Set(
                textView.string.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )

            // Remove entries that are still listed (user didn't delete them)
            for entry in garbage {
                let line = "\(entry.wrong) \u{2192} \(entry.right)"
                if remainingLines.contains(line) {
                    WordMemory.forget(entry.wrong)
                }
            }

            writeSentinel(sentinel)
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        handlers.append(cleanHandler)
        cleanButton.target = cleanHandler
        cleanButton.action = #selector(ButtonHandler.handle)

        content.addSubview(cleanButton)
        content.addSubview(skipButton)

        // Store handlers to prevent deallocation
        objc_setAssociatedObject(panel, "handlers", handlers, .OBJC_ASSOCIATION_RETAIN)

        NSApp.runModal(for: panel)
    }

    private static func writeSentinel(_ url: URL) {
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        try? Date().description.write(to: url, atomically: true, encoding: .utf8)
    }
}
