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

        let pillSize = OverlayContentView.pillSize(for: state)
        let bottomMargin: CGFloat = 48
        let x = screen.frame.midX - pillSize.width / 2
        let y = screen.visibleFrame.origin.y + bottomMargin
        win.setFrame(NSRect(x: x, y: y, width: pillSize.width, height: pillSize.height), display: false)
        view.frame = NSRect(origin: .zero, size: pillSize)
        view.needsDisplay = true
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

    // Layout constants
    private static let barCount = 10
    private static let dotSize: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let hPadding: CGFloat = 19
    private static let vPadding: CGFloat = 14
    private static let maxBarHeight: CGFloat = 14
    private static let spinnerSize: CGFloat = 17
    private static let spinnerLeftPad: CGFloat = 9   // gap between bars and spinner
    private static let spinnerRightPad: CGFloat = 13 // right edge padding
    private static let spinnerSpace: CGFloat = spinnerLeftPad + spinnerSize + spinnerRightPad - hPadding

    private var smoothLevel: CGFloat = 0
    private var displayLevels: [CGFloat] = Array(repeating: 0, count: barCount)
    // Per-bar jitter targets that change periodically, not every frame
    private var jitterTargets: [CGFloat] = Array(repeating: 0, count: barCount)
    private var jitterCurrent: [CGFloat] = Array(repeating: 0, count: barCount)
    // Traveling boost that cascades left to right
    private var travelBoost: [CGFloat] = Array(repeating: 0, count: barCount)
    private var travelTimer: Int = 0
    private var travelCooldown: Int = 0

    static func pillSize(for state: RecordingOverlay.OverlayState) -> NSSize {
        let barsWidth = CGFloat(barCount) * dotSize + CGFloat(barCount - 1) * barGap
        let baseWidth = hPadding * 2 + barsWidth
        let height = vPadding * 2 + dotSize
        switch state {
        case .recording:
            return NSSize(width: baseWidth, height: height)
        case .transcribing:
            return NSSize(width: baseWidth + spinnerSpace, height: height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = bounds
        let cornerRadius = rect.height / 2

        let pillPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(pillPath)
        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.92).cgColor)
        ctx.fillPath()

        if hideContents { return }

        // Border
        if borderWidth > 0 {
            let inset = borderWidth / 2
            let borderRect = rect.insetBy(dx: inset, dy: inset)
            let borderRadius = borderRect.height / 2
            let borderPath = CGPath(roundedRect: borderRect, cornerWidth: borderRadius, cornerHeight: borderRadius, transform: nil)
            ctx.addPath(borderPath)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }

        let isTranscribing = overlayState == .transcribing
        let color = isTranscribing ? NSColor.white.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.9)
        drawBars(ctx: ctx, rect: rect, color: color)

        if isTranscribing {
            drawSpinner(ctx: ctx, rect: rect)
        }
    }

    private func drawBars(ctx: CGContext, rect: NSRect, color: NSColor) {
        let centerY = rect.midY
        let startX = Self.hPadding

        // Fast attack, moderate release
        let smoothing: CGFloat = audioLevel > smoothLevel ? 0.8 : 0.4
        smoothLevel += (audioLevel - smoothLevel) * smoothing

        let baseLevel: CGFloat
        if case .transcribing = overlayState {
            baseLevel = 0
        } else {
            baseLevel = smoothLevel
        }

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
            // Recording: bars can shrink to 1px when very quiet. Transcribing: fixed at 2px.
            let minH: CGFloat = (overlayState == .transcribing) ? Self.dotSize : 1.0
            let h = minH + (Self.maxBarHeight - minH) * dl

            let x = startX + CGFloat(i) * (Self.dotSize + Self.barGap)
            let y = centerY - h / 2
            let barRect = CGRect(x: x, y: y, width: Self.dotSize, height: h)
            // Border radius scales with level: square when silent, fully rounded when loud
            let r = dl * (Self.dotSize / 2)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawSpinner(ctx: CGContext, rect: NSRect) {
        let cx = rect.maxX - Self.spinnerRightPad - Self.spinnerSize / 2
        let cy = rect.midY
        let spokeCount = 8
        let innerR: CGFloat = 4.5  // distance from center to inner tip
        let outerR: CGFloat = 7.5  // distance from center to outer tip
        let spokeWidth: CGFloat = 2.0

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
}
