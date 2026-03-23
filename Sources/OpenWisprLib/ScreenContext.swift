import AppKit
import Vision

class ScreenContext {

    /// Whether the user has granted screen capture permission.
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompt for screen capture permission. Returns true if already granted.
    static func requestPermission() -> Bool {
        if hasPermission { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    /// Capture the frontmost window and run OCR. Returns recognized text or nil.
    /// Runs synchronously — call from a background thread.
    static func captureAndRecognize() -> String? {
        guard hasPermission else { return nil }

        guard let image = captureActiveWindow() else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else { return nil }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

        // Trim to 500 chars for whisper prompt limit
        if text.isEmpty { return nil }
        return String(text.prefix(500))
    }

    private static func captureActiveWindow() -> CGImage? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid == frontPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            return CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming])
        }

        return CGDisplayCreateImage(CGMainDisplayID())
    }
}
