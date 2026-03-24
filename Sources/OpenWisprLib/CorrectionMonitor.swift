import AppKit
import ApplicationServices

class CorrectionMonitor {
    private var timer: Timer?
    private var element: AXUIElement?
    private var originalWords: [String] = []
    private var startTime: Date?
    private var offerCallback: ((String, String) -> Void)?
    private var lastCursorPos: Int?

    private static let monitorDuration: TimeInterval = 10
    private static let pollInterval: TimeInterval = 0.5

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

    private func poll() {
        guard let start = startTime else { stop(); return }

        if Date().timeIntervalSince(start) > Self.monitorDuration {
            stop()
            return
        }

        guard let element = element else { stop(); return }

        guard let currentText = readText(from: element),
              let cursorPos = readCursorPosition(from: element) else { return }

        let currentWords = tokenize(currentText)

        // If word count changed (user inserted/deleted words), update snapshot and bail —
        // positional comparison would be wrong.
        guard currentWords.count == originalWords.count else {
            originalWords = currentWords
            lastCursorPos = cursorPos
            return
        }

        // Only check for corrections when the cursor moves
        if let lastPos = lastCursorPos, cursorPos != lastPos {
            // Scan all words for the single changed one
            if let (wrong, right) = findSingleCorrection(original: originalWords, current: currentWords) {
                offerCallback?(wrong, right)
                originalWords = currentWords
            }
        }

        lastCursorPos = cursorPos
    }

    /// Find exactly one word that differs between original and current.
    /// Returns nil if zero or more than one word changed.
    private func findSingleCorrection(original: [String], current: [String]) -> (String, String)? {
        guard original.count == current.count else { return nil }
        var result: (String, String)?
        for i in 0..<original.count {
            let origNorm = stripPunctuation(original[i]).lowercased()
            let currNorm = stripPunctuation(current[i]).lowercased()
            if origNorm != currNorm && !origNorm.isEmpty && !currNorm.isEmpty {
                if result != nil { return nil }  // more than one change — ambiguous
                result = (stripPunctuation(original[i]), stripPunctuation(current[i]))
            }
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
