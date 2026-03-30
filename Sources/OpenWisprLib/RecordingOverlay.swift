import AppKit

class RecordingOverlay {
    private var window: NSWindow?
    private var animationTimer: Timer?
    private var contentView: OverlayContentView?
    private weak var recorder: AudioRecorder?

    func show(state: OverlayState, recorder: AudioRecorder? = nil) {
        // Hard kill any existing window (no animation)
        animationTimer?.invalidate()
        animationTimer = nil
        window?.orderOut(nil)
        window = nil
        contentView = nil
        self.recorder = recorder

        guard let screen = NSScreen.main else { return }

        let pillSize = OverlayContentView.pillSize(for: state)
        let bottomMargin: CGFloat = 48
        let x = screen.frame.midX - pillSize.width / 2
        let y = screen.visibleFrame.origin.y + bottomMargin
        let frame = NSRect(x: x, y: y, width: pillSize.width, height: pillSize.height)

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = OverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        view.overlayState = state
        win.contentView = view

        // Start fully transparent for fade-in
        win.alphaValue = 0
        view.borderWidth = 0

        win.orderFrontRegardless()
        window = win
        contentView = view

        startAnimation()

        // Fade in over 200ms
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            win.animator().alphaValue = 1.0
        }
        // Border grows to 1px after 100ms delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                view.animator().borderWidth = 1.0
            }
        }
    }

    func update(state: OverlayState) {
        guard let view = contentView, let win = window, let screen = NSScreen.main else {
            show(state: state)
            return
        }
        view.overlayState = state

        let pillSize = OverlayContentView.pillSize(for: state, streamingText: view.streamingText)
        let bottomMargin: CGFloat = 48
        let x = screen.frame.midX - pillSize.width / 2
        let y = screen.visibleFrame.origin.y + bottomMargin
        win.setFrame(NSRect(x: x, y: y, width: pillSize.width, height: pillSize.height), display: false)
        view.frame = NSRect(origin: .zero, size: pillSize)
        view.needsDisplay = true
    }

    /// Update the overlay with streaming transcription text.
    /// Called from the main thread during recording as partial results arrive.
    func updateStreamingText(_ text: String) {
        guard let view = contentView, let win = window, let screen = NSScreen.main else { return }

        // Only grow the text, never shrink — prevents flickering from re-processing
        if text.count < view.streamingText.count { return }

        let oldText = view.streamingText
        view.streamingText = text

        // Resize the pill if text content changed
        let newSize = OverlayContentView.pillSize(for: view.overlayState, streamingText: text)
        let oldSize = OverlayContentView.pillSize(for: view.overlayState, streamingText: oldText)
        if newSize != oldSize {
            let x = screen.frame.midX - newSize.width / 2
            let y: CGFloat
            if text.isEmpty {
                // Compact pill at the bottom
                y = screen.visibleFrame.origin.y + 48
            } else {
                // Expanded pill centered on screen
                y = screen.frame.midY - newSize.height / 2
            }

            // Animate the size change smoothly
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(NSRect(x: x, y: y, width: newSize.width, height: newSize.height), display: true)
            }
            view.frame = NSRect(origin: .zero, size: newSize)
        }

        view.needsDisplay = true
    }

    /// Clear streaming text (called when recording stops).
    func clearStreamingText() {
        contentView?.streamingText = ""
        contentView?.needsDisplay = true
    }

    func hide() {
        guard let win = window, let view = contentView else { return }

        // Immediately detach references so show() won't see a stale window
        let animTimer = animationTimer
        animationTimer = nil
        window = nil
        contentView = nil
        recorder = nil

        // Hide bars, spinner, and border
        view.hideContents = true
        view.borderWidth = 0

        let originalFrame = win.frame

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
            let shrinkW: CGFloat = 15
            let shrinkH: CGFloat = 4
            let drop: CGFloat = 3
            let newFrame = NSRect(
                x: originalFrame.origin.x + shrinkW,
                y: originalFrame.origin.y - drop,
                width: originalFrame.width - shrinkW * 2,
                height: originalFrame.height - shrinkH * 2
            )
            win.animator().setFrame(newFrame, display: true)
        }, completionHandler: {
            animTimer?.invalidate()
            win.orderOut(nil)
        })
    }

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let view = self.contentView else { return }
            view.tick += 1
            if let recorder = self.recorder {
                let raw = CGFloat(recorder.currentLevel)
                // Noise gate: suppress ambient noise, rescale speech range
                let gated = max(raw - 0.08, 0) / 0.92
                view.audioLevel = min(pow(gated, 0.5) * 1.4, 1.0)
            }
            view.needsDisplay = true
        }
    }

    enum OverlayState {
        case recording
        case transcribing
    }
}

private class OverlayContentView: NSView {
    var overlayState: RecordingOverlay.OverlayState = .recording
    var audioLevel: CGFloat = 0
    var tick: Int = 0
    @objc dynamic var borderWidth: CGFloat = 0
    var hideContents = false
    var streamingText: String = ""

    // Layout constants — visualization is 2x the original size
    private static let barCount = 16
    private static let dotSize: CGFloat = 2.0
    private static let barGap: CGFloat = 3
    private static let hPadding: CGFloat = 24
    private static let vPadding: CGFloat = 18
    private static let maxBarHeight: CGFloat = 20
    private static let spinnerSize: CGFloat = 22
    private static let spinnerLeftPad: CGFloat = 12   // gap between bars and spinner
    private static let spinnerRightPad: CGFloat = 16  // right edge padding
    private static let spinnerSpace: CGFloat = spinnerLeftPad + spinnerSize + spinnerRightPad - hPadding

    // Fixed corner radius — does NOT scale with pill height
    private static let cornerRadius: CGFloat = 20

    private var smoothLevel: CGFloat = 0
    private var displayLevels: [CGFloat] = Array(repeating: 0, count: barCount)
    // Per-bar jitter targets that change periodically, not every frame
    private var jitterTargets: [CGFloat] = Array(repeating: 0, count: barCount)
    private var jitterCurrent: [CGFloat] = Array(repeating: 0, count: barCount)
    // Traveling boost that cascades left to right
    private var travelBoost: [CGFloat] = Array(repeating: 0, count: barCount)
    private var travelTimer: Int = 0
    private var travelCooldown: Int = 0

    // Streaming text layout constants
    private static let streamingTextMaxWidth: CGFloat = 400
    private static let streamingTextTopPad: CGFloat = 2
    private static let streamingTextBottomPad: CGFloat = 12
    private static let streamingTextFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let maxVisibleLines = 6
    private static let lineHeightEstimate: CGFloat = 18 // ~13pt font with leading

    // Compressed bars layout when text is showing
    private static let compressedDotSize: CGFloat = 1.5
    private static let compressedBarGap: CGFloat = 2.0
    private static let compressedMaxBarHeight: CGFloat = 10
    private static let compressedBarsAreaHeight: CGFloat = 24

    static func pillSize(for state: RecordingOverlay.OverlayState, streamingText: String = "") -> NSSize {
        let barsWidth = CGFloat(barCount) * dotSize + CGFloat(barCount - 1) * barGap
        let baseWidth = hPadding * 2 + barsWidth
        let baseHeight = vPadding * 2 + dotSize

        if streamingText.isEmpty || state == .transcribing {
            return NSSize(width: baseWidth, height: baseHeight)
        }

        // Wider pill to accommodate text
        let textWidth = max(baseWidth, streamingTextMaxWidth + hPadding * 2)

        // Calculate text height, capped at ~6 lines
        let textHeight = streamingTextHeight(for: streamingText, maxWidth: streamingTextMaxWidth)
        let maxTextHeight = lineHeightEstimate * CGFloat(maxVisibleLines)
        let clampedTextHeight = min(textHeight, maxTextHeight)

        let totalHeight = compressedBarsAreaHeight + streamingTextTopPad + clampedTextHeight + streamingTextBottomPad
        return NSSize(width: textWidth, height: totalHeight)
    }

    private static func streamingTextHeight(for text: String, maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: streamingTextFont,
            .paragraphStyle: paraStyle,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let boundingRect = attrStr.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(boundingRect.height)
    }

    /// Returns just the last N lines of text that fit in the visible area.
    private static func visibleTailText(from text: String, maxWidth: CGFloat) -> String {
        let maxHeight = lineHeightEstimate * CGFloat(maxVisibleLines)
        let fullHeight = streamingTextHeight(for: text, maxWidth: maxWidth)
        if fullHeight <= maxHeight { return text }

        // Text exceeds visible area — find lines from the end that fit
        // Split by newlines (we insert \n for sentence breaks)
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        for line in lines.reversed() {
            let candidate = ([line] + result).joined(separator: "\n")
            let h = streamingTextHeight(for: candidate, maxWidth: maxWidth)
            if h > maxHeight && !result.isEmpty { break }
            result.insert(line, at: 0)
        }
        return result.joined(separator: "\n")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = bounds
        let pillPath = CGPath(roundedRect: rect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)

        // Purple gradient background for recording and transcribing states
        if overlayState == .recording || overlayState == .transcribing {
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.clip()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradientColors = [
                NSColor(red: 0.25, green: 0.05, blue: 0.35, alpha: 0.6).cgColor,
                NSColor(red: 0.40, green: 0.10, blue: 0.55, alpha: 0.6).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(gradient,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: [])
            }
            ctx.restoreGState()
        } else {
            ctx.addPath(pillPath)
            ctx.setFillColor(NSColor(white: 0.08, alpha: 0.92).cgColor)
            ctx.fillPath()
        }

        if hideContents { return }

        // Border
        if borderWidth > 0 {
            let inset = borderWidth / 2
            let borderRect = rect.insetBy(dx: inset, dy: inset)
            let borderPath = CGPath(roundedRect: borderRect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
            ctx.addPath(borderPath)
            ctx.setStrokeColor(NSColor(red: 0.5, green: 0.15, blue: 0.7, alpha: 0.8).cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }

        let isTranscribing = overlayState == .transcribing
        let hasText = !streamingText.isEmpty && !isTranscribing

        if isTranscribing {
            // No bars during transcribing — only centered spinner
            drawSpinner(ctx: ctx, rect: rect)
        } else if hasText {
            // Bars compressed to top of the expanded pill
            let barsRect = NSRect(
                x: rect.minX,
                y: rect.maxY - Self.compressedBarsAreaHeight,
                width: rect.width,
                height: Self.compressedBarsAreaHeight
            )
            drawBars(ctx: ctx, rect: barsRect, color: NSColor.white.withAlphaComponent(0.75), compressed: true)

            // Streaming text below bars
            drawStreamingText(ctx: ctx, rect: rect)
        } else {
            // Normal centered bars, no text
            drawBars(ctx: ctx, rect: rect, color: NSColor.white.withAlphaComponent(0.75), compressed: false)
        }
    }

    private func drawBars(ctx: CGContext, rect: NSRect, color: NSColor, compressed: Bool) {
        if overlayState == .transcribing { return }

        let effectiveDotSize = compressed ? Self.compressedDotSize : Self.dotSize
        let effectiveGap = compressed ? Self.compressedBarGap : Self.barGap
        let effectiveMaxHeight = compressed ? Self.compressedMaxBarHeight : Self.maxBarHeight

        // When compressed, left-align bars; otherwise center them
        let startX: CGFloat
        let centerY: CGFloat
        if compressed {
            startX = Self.hPadding
            centerY = rect.midY
        } else {
            startX = Self.hPadding
            centerY = rect.midY
        }

        // Fast attack, moderate release
        let smoothing: CGFloat = audioLevel > smoothLevel ? 0.8 : 0.4
        smoothLevel += (audioLevel - smoothLevel) * smoothing

        let baseLevel = smoothLevel

        // Periodically fire a traveling boost that cascades left to right
        travelTimer += 1
        if travelCooldown > 0 { travelCooldown -= 1 }
        if baseLevel > 0.1 && travelCooldown == 0 && travelTimer % 8 == 0 {
            travelBoost[0] = CGFloat.random(in: 0.1...0.25)
            travelCooldown = Int.random(in: 3...8)
        }
        // Cascade travel boost left to right
        for i in stride(from: Self.barCount - 1, through: 1, by: -1) {
            travelBoost[i] += (travelBoost[i - 1] - travelBoost[i]) * 0.4
        }
        travelBoost[0] *= 0.85 // decay the source

        ctx.setFillColor(color.cgColor)

        for i in 0..<Self.barCount {
            // Edge suppression: 20% outermost, 12% second, 5% third
            let edgeClamp: CGFloat
            if i == 0 || i == Self.barCount - 1 {
                edgeClamp = 0.8
            } else if i == 1 || i == Self.barCount - 2 {
                edgeClamp = 0.88
            } else if i == 2 || i == Self.barCount - 3 {
                edgeClamp = 0.95
            } else {
                edgeClamp = 1.0
            }

            // Smooth jitter: wider range so only some bars peak tall
            if tick % 6 == i % 6 {
                jitterTargets[i] = CGFloat.random(in: -0.4...0.4)
            }
            jitterCurrent[i] += (jitterTargets[i] - jitterCurrent[i]) * 0.25
            let jitter = jitterCurrent[i] * (0.3 + 0.7 * baseLevel)

            let target = (baseLevel + jitter + travelBoost[i]) * edgeClamp

            // Fast attack, smoother release
            let displaySmoothing: CGFloat = target > displayLevels[i] ? 0.8 : 0.5
            displayLevels[i] += (target - displayLevels[i]) * displaySmoothing

            let dl = max(displayLevels[i], 0)
            let minH: CGFloat = compressed ? 0.5 : 1.0
            let h = minH + (effectiveMaxHeight - minH) * dl

            let x = startX + CGFloat(i) * (effectiveDotSize + effectiveGap)
            let y = centerY - h / 2
            let barRect = CGRect(x: x, y: y, width: effectiveDotSize, height: h)
            // Border radius scales with level: square when silent, fully rounded when loud
            let r = dl * (effectiveDotSize / 2)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawSpinner(ctx: CGContext, rect: NSRect) {
        let cx = rect.midX  // centered when transcribing
        let cy = rect.midY
        let spokeCount = 8
        let innerR: CGFloat = 6.0  // distance from center to inner tip
        let outerR: CGFloat = 10.0  // distance from center to outer tip
        let spokeWidth: CGFloat = 2.5

        // Current leading spoke index (rotates at ~10 steps/sec)
        let leadingSpoke = (tick / 3) % spokeCount

        ctx.setLineWidth(spokeWidth)
        ctx.setLineCap(.round)

        for i in 0..<spokeCount {
            // Angle: 0=top, going clockwise. Negate because CG Y-axis is up.
            let angle = -CGFloat(i) * (.pi / 4) + .pi / 2

            let x1 = cx + cos(angle) * innerR
            let y1 = cy + sin(angle) * innerR
            let x2 = cx + cos(angle) * outerR
            let y2 = cy + sin(angle) * outerR

            // Brightness: leading spoke is brightest, fading behind it
            let stepsBehind = (leadingSpoke - i + spokeCount) % spokeCount
            let alpha = CGFloat(spokeCount - stepsBehind) / CGFloat(spokeCount)

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12 + 0.78 * alpha).cgColor)
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
        }
    }

    private func drawStreamingText(ctx: CGContext, rect: NSRect) {
        guard !streamingText.isEmpty else { return }

        let textMaxWidth = Self.streamingTextMaxWidth
        let textX = rect.midX - textMaxWidth / 2

        // The text area starts below the compressed bars area
        let textAreaTop = rect.maxY - Self.compressedBarsAreaHeight - Self.streamingTextTopPad
        let textAreaBottom = rect.minY + Self.streamingTextBottomPad
        let textAreaHeight = textAreaTop - textAreaBottom

        // Get the visible tail of the text (last ~6 lines)
        let visibleText = Self.visibleTailText(from: streamingText, maxWidth: textMaxWidth)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.streamingTextFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraphStyle,
        ]

        let attrStr = NSAttributedString(string: visibleText, attributes: attributes)
        let textHeight = Self.streamingTextHeight(for: visibleText, maxWidth: textMaxWidth)

        // Anchor text to the top of the text area (new text pushes old text up)
        let textRect = NSRect(x: textX, y: textAreaTop - textHeight, width: textMaxWidth, height: textHeight)

        // Clip to the text area so nothing bleeds outside the pill
        ctx.saveGState()
        ctx.clip(to: NSRect(x: rect.minX, y: textAreaBottom, width: rect.width, height: textAreaHeight))

        NSGraphicsContext.current?.saveGraphicsState()
        attrStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.current?.restoreGraphicsState()

        ctx.restoreGState()
    }
}
