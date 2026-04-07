import AppKit
import ApplicationServices

class CorrectionMonitor {
    private var timer: Timer?
    private var element: AXUIElement?
    private var originalWords: [String] = []
    private var startTime: Date?
    private var offerCallback: ((String, String) -> Void)?
    private var lastCursorPos: Int?

    private static let monitorDuration: TimeInterval = 8
    private static let pollInterval: TimeInterval = 1.0

    /// Start monitoring a text field for corrections after a transcription was pasted.
    func start(element: AXUIElement, pastedText: String, onCorrectionFound: @escaping (String, String) -> Void) {
        stop()

        self.element = element
        // Snapshot the full field text so we can detect changes
        let snapshot = readText(from: element) ?? pastedText
        self.originalWords = tokenize(snapshot)
        self.startTime = Date()
        self.offerCallback = onCorrectionFound
        self.lastCursorPos = nil
        self.slowPollCount = 0

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        originalWords = []
        startTime = nil
        offerCallback = nil
        lastCursorPos = nil
    }

    private var slowPollCount = 0

    private func poll() {
        guard let start = startTime else { stop(); return }
        if Date().timeIntervalSince(start) > Self.monitorDuration { stop(); return }
        guard let element = self.element else { stop(); return }

        // Capture element locally — avoids race if stop() is called while AX work is in flight.
        let capturedElement = element

        // AX calls (especially kAXValueAttribute on large fields) can block the target app's
        // main thread via IPC, causing cursor/hover flicker and selection lag in that app.
        // Run them on a background thread so they don't stall the main run loop.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, self.element != nil else { return }

            let pollStart = CFAbsoluteTimeGetCurrent()
            guard let currentText = self.readText(from: capturedElement),
                  let cursorPos = self.readCursorPosition(from: capturedElement) else { return }
            let pollTime = CFAbsoluteTimeGetCurrent() - pollStart

            DispatchQueue.main.async {
                guard self.element != nil else { return }  // stopped while AX was in flight

                // If AX is consistently slow (>200ms), stop polling — we're making the app laggy
                if pollTime > 0.2 {
                    self.slowPollCount += 1
                    if self.slowPollCount >= 2 {
                        DiagnosticLogger.shared.log("CorrectionMonitor: AX too slow (\(Int(pollTime * 1000))ms) — stopping")
                        self.stop()
                        return
                    }
                }

                let currentWords = self.tokenize(currentText)

                // If word count changed (user inserted/deleted words), update snapshot and bail —
                // positional comparison would be wrong.
                guard currentWords.count == self.originalWords.count else {
                    self.originalWords = currentWords
                    self.lastCursorPos = cursorPos
                    return
                }

                // Only check for corrections when the cursor moves
                if let lastPos = self.lastCursorPos, cursorPos != lastPos {
                    if let (wrong, right) = self.findSingleCorrection(original: self.originalWords, current: currentWords) {
                        self.offerCallback?(wrong, right)
                        self.originalWords = currentWords
                    }
                }

                self.lastCursorPos = cursorPos
            }
        }
    }

    /// Minimum character length for a word to qualify as a correction candidate.
    private static let minWordLength = 4

    /// Find exactly one word that differs between original and current.
    /// Returns nil if zero or more than one word changed.
    ///
    /// Filters applied to avoid false positives:
    /// - Both words must be at least `minWordLength` characters (ignoring punctuation).
    /// - The Levenshtein distance must be less than 40 % of the longer word's length
    ///   (i.e. the two words must look like a plausible typo correction).
    private func findSingleCorrection(original: [String], current: [String]) -> (String, String)? {
        guard original.count == current.count else { return nil }
        var result: (String, String)?
        for i in 0..<original.count {
            let origStripped = stripPunctuation(original[i])
            let currStripped = stripPunctuation(current[i])
            let origNorm = origStripped.lowercased()
            let currNorm = currStripped.lowercased()

            guard origNorm != currNorm, !origNorm.isEmpty, !currNorm.isEmpty else { continue }

            // Both words must be long enough to be meaningful.
            guard origNorm.count >= Self.minWordLength,
                  currNorm.count >= Self.minWordLength else { continue }

            // The two words must be close in edit distance (plausible typo).
            guard LevenshteinDistance.isSimilar(origNorm, currNorm) else { continue }

            if result != nil { return nil }  // more than one change — ambiguous
            result = (origStripped, currStripped)
        }
        return result
    }

    private func readText(from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        return text
    }

    private func readCursorPosition(from element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        return range.location
    }

    private func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    private func stripPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
    }
}
