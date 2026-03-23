import AppKit
import ApplicationServices

class CorrectionMonitor {
    private var timer: Timer?
    private var element: AXUIElement?
    private var originalWords: [String] = []
    private var snapshotText: String = ""
    private var startTime: Date?
    private var offerCallback: ((String, String) -> Void)?
    private var lastCursorWordIndex: Int?

    private static let monitorDuration: TimeInterval = 10
    private static let pollInterval: TimeInterval = 0.5

    /// Start monitoring a text field for corrections after a transcription was pasted.
    func start(element: AXUIElement, pastedText: String, onCorrectionFound: @escaping (String, String) -> Void) {
        stop()

        self.element = element
        // Snapshot the full field text so word indices align with future reads
        self.snapshotText = readText(from: element) ?? pastedText
        self.originalWords = tokenize(snapshotText)
        self.startTime = Date()
        self.offerCallback = onCorrectionFound
        self.lastCursorWordIndex = nil

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        originalWords = []
        snapshotText = ""
        startTime = nil
        offerCallback = nil
        lastCursorWordIndex = nil
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

        let cursorWordIndex = wordIndexAtPosition(cursorPos, in: currentText)

        // Check if cursor moved away from a previously edited word
        if let lastIdx = lastCursorWordIndex, cursorWordIndex != lastIdx {
            if lastIdx < originalWords.count && lastIdx < currentWords.count {
                let original = originalWords[lastIdx]
                let current = currentWords[lastIdx]
                let origNorm = stripPunctuation(original).lowercased()
                let currNorm = stripPunctuation(current).lowercased()
                if origNorm != currNorm && !origNorm.isEmpty && !currNorm.isEmpty {
                    offerCallback?(stripPunctuation(original), stripPunctuation(current))
                    originalWords[lastIdx] = current
                }
            }
        }

        lastCursorWordIndex = cursorWordIndex
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
              let rangeValue = rangeRef else { return nil }
        var range = CFRange()
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        return range.location
    }

    private func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// Strip leading/trailing punctuation from a word for comparison
    private func stripPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
    }

    private func wordIndexAtPosition(_ pos: Int, in text: String) -> Int? {
        var charCount = 0
        let words = text.components(separatedBy: .whitespaces)
        for (i, word) in words.enumerated() where !word.isEmpty {
            let wordStart = charCount
            let wordEnd = charCount + word.count
            if pos >= wordStart && pos <= wordEnd {
                return i
            }
            charCount = wordEnd + 1
        }
        return nil
    }
}
