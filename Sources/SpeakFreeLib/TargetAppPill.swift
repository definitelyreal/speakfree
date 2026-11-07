import AppKit
import QuartzCore

/// Geometry and pure state for the target-app pill: a dark rounded overlay that names
/// the app the dictation will be inserted into, with a row of dashes that rise into
/// bars with the voice. Shown immediately at the bottom of the screen — there is no
/// armed-dot entry and no centre-screen banner for this style.
enum TargetAppPill {

    /// `overlayStyle` value that selects the pill; an unset style resolves to it.
    static let style = 6

    static func usesPill(style: Int) -> Bool { style == TargetAppPill.style }

    /// Styles 1–5 remain the legacy banner variants.
    static func resolvedStyle(configured: Int?) -> Int {
        min(style, max(1, configured ?? style))
    }

    // MARK: - Geometry

    static let pillSize = NSSize(width: 280, height: 66)
    /// Transparent margin around the pill so the glow and shadow are not clipped.
    static let glowMargin: CGFloat = 30
    static let windowSize = NSSize(width: pillSize.width + glowMargin * 2,
                                   height: pillSize.height + glowMargin * 2)
    static let bottomMargin: CGFloat = 35
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 14
    static let iconSize: CGFloat = 22

    static let barCount = 30
    static let barWidth: CGFloat = 5
    static let dashHeight: CGFloat = 2
    static let maxBarHeight: CGFloat = 16
    /// Opacity of the bars while recording: present, but not shouting over the app name.
    static let barAlpha: CGFloat = 0.6
    static let shimmerFloor: CGFloat = 0.35

    static func windowFrame(screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        NSRect(x: screenFrame.midX - windowSize.width / 2,
               y: visibleFrame.minY + bottomMargin - glowMargin,
               width: windowSize.width, height: windowSize.height)
    }

    // MARK: - Bars

    /// Animation steps per second. The pill redraws on every display refresh and takes
    /// as many steps as the elapsed time calls for, so motion is equally fast at 60Hz
    /// and 120Hz and as smooth as the display allows.
    static let frameRate = 120
    /// Loudness samples (one per step) per bar: a sound crosses the pill in 1.25s.
    static let samplesPerBar = 5

    /// How many animation steps a display frame of `elapsed` seconds is worth. Leftover
    /// fractions carry to the next frame; a long stall is capped rather than replayed.
    static func steps(elapsed: TimeInterval, carry: Double) -> (steps: Int, carry: Double) {
        let total = max(0, elapsed) * Double(frameRate) + carry
        let whole = Int(total)
        return whole > 12 ? (12, 0) : (whole, total - Double(whole))
    }
    /// One bar of lead-in on the right and lead-out on the left of the visible bars.
    static let historyLength = (barCount + 1) * samplesPerBar + 1

    /// The waveform is a recording: every frame the newest loudness joins on the right
    /// and the oldest falls off the left.
    static func scrolled(_ history: [CGFloat], adding level: CGFloat) -> [CGFloat] {
        Array(history.dropFirst()) + [level]
    }

    /// Bar heights for a per-frame loudness history (0…1 each, oldest first). Each bar
    /// takes the loudest nearby sample, weighted by distance, so a sound is handed
    /// smoothly from bar to bar as it travels left. Silence is a flat row of dashes.
    static func barHeights(history: [CGFloat]) -> [CGFloat] {
        (0..<barCount).map { bar in
            let centre = (bar + 1) * samplesPerBar
            var value: CGFloat = 0
            for offset in -samplesPerBar...samplesPerBar where history.indices.contains(centre + offset) {
                let weight = 1 - CGFloat(abs(offset)) / CGFloat(samplesPerBar + 1)
                value = max(value, weight * min(1, max(0, history[centre + offset])))
            }
            return dashHeight + (maxBarHeight - dashHeight) * value
        }
    }

    /// One frame of easing toward a target height.
    static func smoothed(from current: CGFloat, toward target: CGFloat) -> CGFloat {
        current + (target - current) * 0.4
    }

    /// Per-bar opacity while transcribing: a highlight sweeping left to right.
    static func shimmerAlphas(tick: Int) -> [CGFloat] {
        let travel = Double(barCount + 8)
        let position = (Double(tick) * 0.15).truncatingRemainder(dividingBy: travel) - 4
        return (0..<barCount).map { index in
            let falloff = max(0, 1 - abs(Double(index) - position) / 4)
            return shimmerFloor + (1 - shimmerFloor) * CGFloat(falloff)
        }
    }

    // MARK: - Travelling glow

    /// One lap of the red glow around the pill, in animation steps (9s).
    static let glowPeriodTicks = 1080

    /// How far the glow reaches outside the pill. Kept tight: the light hugs the edge
    /// and falls inward, rather than spilling over what is behind the pill.
    static let outerGlowRadius: CGFloat = 9

    enum GlowColour: Equatable { case red, blue }

    /// Red while listening (and for errors), blue once the take is being processed.
    static func glowColour(state: RecordingOverlay.OverlayState) -> GlowColour {
        state == .transcribing ? .blue : .red
    }

    /// The glow laps the pill while recording and processing; an error glows evenly.
    static func glowTravels(state: RecordingOverlay.OverlayState) -> Bool {
        if case .error = state { return false }
        return true
    }

    // MARK: - Hover controls

    enum HoverAction: Equatable { case finish, cancel }

    /// While recording, the pill's top half finishes the take and its bottom half cancels it.
    static func hoverAction(at point: CGPoint, in pill: CGRect,
                            state: RecordingOverlay.OverlayState) -> HoverAction? {
        guard state == .recording, pill.contains(point) else { return nil }
        return point.y >= pill.midY ? .finish : .cancel
    }

    /// Where the glow's head is on its lap, 0..<1.
    static func glowFraction(tick: Int) -> CGFloat {
        CGFloat(((tick % glowPeriodTicks) + glowPeriodTicks) % glowPeriodTicks) / CGFloat(glowPeriodTicks)
    }

    /// The point `fraction` of the way round `rect`'s edge, clockwise on screen from the
    /// top-left corner. Any fraction is accepted and wraps onto the loop.
    static func perimeterPoint(of rect: CGRect, fraction: CGFloat) -> CGPoint {
        let perimeter = 2 * (rect.width + rect.height)
        let wrapped = fraction - fraction.rounded(.down)
        var distance = wrapped * perimeter
        if distance < rect.width { return CGPoint(x: rect.minX + distance, y: rect.maxY) }
        distance -= rect.width
        if distance < rect.height { return CGPoint(x: rect.maxX, y: rect.maxY - distance) }
        distance -= rect.height
        if distance < rect.width { return CGPoint(x: rect.maxX - distance, y: rect.minY) }
        distance -= rect.width
        return CGPoint(x: rect.minX, y: rect.minY + distance)
    }

    // MARK: - Following the frontmost app

    /// The pill names whichever app comes to the front during a dictation, since that is
    /// where the text will land. speakfree's own windows never count as a target.
    static func adoptsTarget(bundleID: String?, ownBundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID != ownBundleID
    }

    // MARK: - Title

    /// The pill's headline. Errors and status messages replace the app name; a live
    /// transcript arriving mid-recording does not.
    static func title(state: RecordingOverlay.OverlayState, appName: String?, message: String) -> String {
        let name = (appName?.isEmpty == false) ? appName! : "Dictation"
        switch state {
        case .error(let text): return text
        case .recording: return name
        case .transcribing: return message.isEmpty ? name : message
        }
    }

    /// The wordmark shares the top row with an app name only; an error or status
    /// message gets the whole row.
    static func showsWordmark(state: RecordingOverlay.OverlayState, message: String) -> Bool {
        switch state {
        case .error: return false
        case .recording: return true
        case .transcribing: return message.isEmpty
        }
    }
}

final class TargetAppPillView: NSView {
    var overlayState: RecordingOverlay.OverlayState = .recording
    var appName: String?
    var appIcon: NSImage?
    /// Status line shown in place of the app name once recording has ended.
    var message = ""
    /// A status message is being held before hide: no shimmer, bars at rest.
    var isLingering = false
    var audioLevel: CGFloat = 0
    /// Opacity of the pill's dark body. Lowered when a blur view sits behind it, so the
    /// body reads as tinted glass; near-opaque when drawn on its own.
    var bodyAlpha: CGFloat = 0.96
    /// Eased voice level driving the white bloom behind the bars.
    private var bloom: CGFloat = 0
    var speechGate = OverlayEmergence.AdaptiveSpeechGate()
    /// Raw microphone loudness (RMS) while a recorder is attached; nil when there is none.
    var levelSource: (() -> CGFloat?)?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var stepCarry = 0.0
    private var stepsUntilGateUpdate = 0
    private var gatedLevel: CGFloat = 0
    /// Called when a hover control is clicked.
    var onHoverAction: ((TargetAppPill.HoverAction) -> Void)?
    private var hovered: TargetAppPill.HoverAction?

    private var tick = 0
    /// Loudness per bar, oldest on the left.
    private var history = [CGFloat](repeating: 0, count: TargetAppPill.historyLength)

    var barHeights: [CGFloat] { TargetAppPill.barHeights(history: history) }

    override var isOpaque: Bool { false }

    private var pillRect: NSRect {
        bounds.insetBy(dx: TargetAppPill.glowMargin, dy: TargetAppPill.glowMargin)
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: pillRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self, userInfo: nil))
    }

    private func hover(_ event: NSEvent) {
        let action = TargetAppPill.hoverAction(
            at: convert(event.locationInWindow, from: nil), in: pillRect, state: overlayState)
        if action != hovered {
            hovered = action
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
    }

    func click(at point: CGPoint) {
        guard let action = TargetAppPill.hoverAction(at: point, in: pillRect, state: overlayState)
        else { return }
        onHoverAction?(action)
    }

    // MARK: Animation

    /// Redraw on every display refresh while the pill is on screen.
    func startAnimating() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTime = nil
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        let elapsed = lastFrameTime.map { link.timestamp - $0 } ?? 1.0 / Double(TargetAppPill.frameRate)
        lastFrameTime = link.timestamp
        advance(elapsed: elapsed)
        needsDisplay = true
    }

    func advance(elapsed: TimeInterval) {
        let result = TargetAppPill.steps(elapsed: elapsed, carry: stepCarry)
        stepCarry = result.carry
        for _ in 0..<result.steps { advance() }
    }

    /// Advance one animation step.
    func advance() {
        tick += 1
        if let levelSource {
            // The speech gate is calibrated for 30 updates a second; ease between them.
            if stepsUntilGateUpdate == 0 {
                if let rms = levelSource() { gatedLevel = speechGate.update(rms: rms) }
                stepsUntilGateUpdate = TargetAppPill.frameRate / 30
            }
            stepsUntilGateUpdate -= 1
            audioLevel = TargetAppPill.smoothed(from: audioLevel, toward: gatedLevel)
        }
        let level = overlayState == .recording ? min(1, max(0, audioLevel)) : 0
        history = TargetAppPill.scrolled(history, adding: level)
        bloom = TargetAppPill.smoothed(from: bloom, toward: level)
    }

    private var isError: Bool {
        if case .error = overlayState { return true }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pill = pillRect
        let body = CGPath(roundedRect: pill, cornerWidth: TargetAppPill.cornerRadius,
                          cornerHeight: TargetAppPill.cornerRadius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 16,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(body)
        ctx.setFillColor(NSColor(white: 0.125, alpha: bodyAlpha).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // The glow hugs the edge: a tight halo outside, a soft spill inside the glass,
        // and a bright run along the hairline border.
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addPath(body)
        ctx.clip(using: .evenOdd)
        drawGlow(around: pill, ctx: ctx, radius: TargetAppPill.outerGlowRadius, strength: 1.6)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        drawGlow(around: pill, ctx: ctx, radius: 20, strength: 0.55)
        ctx.restoreGState()

        // White light falling in from the rim, so the pill reads as set into the screen.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.setShadow(offset: .zero, blur: 7, color: NSColor(white: 1, alpha: 0.16).cgColor)
        ctx.addRect(pill.insetBy(dx: -20, dy: -20))
        ctx.addPath(body)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        ctx.addPath(body)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
        ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.setLineWidth(1.5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        drawGlow(around: pill, ctx: ctx, radius: 30, strength: 3.2)
        ctx.restoreGState()

        let rowCentreY = pill.maxY - 23
        let rowRight = pill.maxX - TargetAppPill.padding
        let showsWordmark = TargetAppPill.showsWordmark(state: shownState, message: message)
        let brandLeft = showsWordmark ? drawBrand(right: rowRight, centreY: rowCentreY) : rowRight + 10
        let iconRect = NSRect(x: pill.minX + TargetAppPill.padding,
                              y: rowCentreY - TargetAppPill.iconSize / 2,
                              width: TargetAppPill.iconSize, height: TargetAppPill.iconSize)
        drawIcon(in: iconRect)
        drawTitle(left: iconRect.maxX + 10, right: brandLeft - 10, centreY: rowCentreY,
                  isMessage: !showsWordmark)
        drawBars(in: pill, ctx: ctx)
        if overlayState == .recording, let hovered {
            drawHoverControls(in: pill, body: body, hovered: hovered, ctx: ctx)
        }
    }

    /// Finish on top, Cancel below, over a scrim that dims the pill's own content.
    private func drawHoverControls(in pill: NSRect, body: CGPath,
                                   hovered: TargetAppPill.HoverAction, ctx: CGContext) {
        let blue = NSColor(red: 0.27, green: 0.55, blue: 1.0, alpha: 1)
        let red = NSColor(red: 0.96, green: 0.36, blue: 0.33, alpha: 1)
        let top = NSRect(x: pill.minX, y: pill.midY, width: pill.width, height: pill.height / 2)
        let bottom = NSRect(x: pill.minX, y: pill.minY, width: pill.width, height: pill.height / 2)
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.07, alpha: 0.80).cgColor)
        ctx.fill(pill)
        ctx.setFillColor(blue.withAlphaComponent(hovered == .finish ? 0.30 : 0.16).cgColor)
        ctx.fill(top)
        ctx.setFillColor(red.withAlphaComponent(hovered == .cancel ? 0.20 : 0.04).cgColor)
        ctx.fill(bottom)
        ctx.setFillColor(blue.withAlphaComponent(0.35).cgColor)
        ctx.fill(NSRect(x: pill.minX, y: pill.midY - 0.5, width: pill.width, height: 1))
        ctx.restoreGState()
        drawControl("Finish recording", symbolName: "checkmark.circle.fill", colour: blue, in: top)
        drawControl("Cancel recording", symbolName: "xmark.circle.fill", colour: red, in: bottom)
    }

    private func drawControl(_ label: String, symbolName: String, colour: NSColor, in rect: NSRect) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: colour,
        ])
        let textSize = text.size()
        let mark = symbol(symbolName, pointSize: 14, color: colour, accent: .white)
        let markSize = mark?.size ?? .zero
        let gap: CGFloat = mark == nil ? 0 : 7
        var x = rect.midX - (markSize.width + gap + textSize.width) / 2
        if let mark {
            mark.draw(in: NSRect(x: x, y: rect.midY - markSize.height / 2,
                                 width: markSize.width, height: markSize.height))
            x += markSize.width + gap
        }
        text.draw(at: NSPoint(x: x, y: rect.midY - textSize.height / 2))
    }

    /// A lingering status message is titled like a finished recording.
    private var shownState: RecordingOverlay.OverlayState {
        isLingering ? .transcribing : overlayState
    }

    /// Light on the pill's edge: a lobe that laps the pill (red while recording, blue and
    /// quicker while processing), or an even red ring for an error.
    private func drawGlow(around pill: NSRect, ctx: CGContext, radius: CGFloat, strength: CGFloat) {
        guard !isLingering else { return }
        let blue = TargetAppPill.glowColour(state: overlayState) == .blue
        let rgb: (CGFloat, CGFloat, CGFloat) = blue ? (0.25, 0.55, 1.0) : (1.0, 0.27, 0.23)
        func blob(at point: CGPoint, alpha: CGFloat) {
            let colours = [NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: min(1, alpha)).cgColor,
                           NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colours, locations: [0, 1]) else { return }
            ctx.drawRadialGradient(gradient, startCenter: point, startRadius: 0,
                                   endCenter: point, endRadius: radius, options: [])
        }
        // Blobs are spaced closer than their radius so the light reads as a continuous line.
        let ring = 64
        guard TargetAppPill.glowTravels(state: overlayState) else {
            for step in 0..<ring {
                blob(at: TargetAppPill.perimeterPoint(of: pill, fraction: CGFloat(step) / CGFloat(ring)),
                     alpha: 0.05 * strength)
            }
            return
        }
        // The travelling lobe: brightest at its head, fading over 40% of a lap.
        let head = TargetAppPill.glowFraction(tick: tick * (blue ? 5 : 1))
        let lobeSteps = 48
        for step in 0..<lobeSteps {
            let trail = CGFloat(step) / CGFloat(lobeSteps)
            let falloff = (1 - trail) * (1 - trail)
            blob(at: TargetAppPill.perimeterPoint(of: pill, fraction: head - trail * 0.40),
                 alpha: 0.055 * falloff * strength)
        }
    }

    private func symbol(_ name: String, pointSize: CGFloat, color: NSColor,
                        accent: NSColor? = nil, weight: NSFont.Weight = .semibold) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: accent.map { [$0, color] } ?? [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func drawIcon(in rect: NSRect) {
        if isError {
            let red = NSColor(red: 1.0, green: 0.38, blue: 0.35, alpha: 1)
            draw(symbol("exclamationmark.triangle.fill", pointSize: 15, color: red,
                        accent: NSColor(white: 0.11, alpha: 1)), centredIn: rect)
        } else if let icon = appIcon {
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            draw(symbol("mic.fill", pointSize: 14, color: NSColor(white: 1, alpha: 0.9)), centredIn: rect)
        }
    }

    private func draw(_ image: NSImage?, centredIn rect: NSRect) {
        guard let image else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    /// Draws the wordmark right-aligned and returns its left edge.
    private func drawBrand(right: CGFloat, centreY: CGFloat) -> CGFloat {
        let grey = NSColor(white: 1, alpha: 0.42)
        let text = NSAttributedString(string: "speakfree", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: grey,
        ])
        let textSize = text.size()
        let textX = right - textSize.width
        text.draw(at: NSPoint(x: textX, y: centreY - textSize.height / 2))
        guard let mark = symbol("waveform", pointSize: 13, color: grey, weight: .regular) else { return textX }
        let markX = textX - 5 - mark.size.width
        mark.draw(in: NSRect(x: markX, y: centreY - mark.size.height / 2,
                             width: mark.size.width, height: mark.size.height))
        return markX
    }

    /// App names sit on one truncating line; messages are smaller and may wrap to two.
    private func drawTitle(left: CGFloat, right: CGFloat, centreY: CGFloat, isMessage: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = isMessage ? .byWordWrapping : .byTruncatingTail
        let font = NSFont.systemFont(ofSize: isMessage ? 13 : 14, weight: .medium)
        let text = NSAttributedString(
            string: TargetAppPill.title(state: shownState, appName: appName, message: message),
            attributes: [
                .font: font,
                .foregroundColor: NSColor(white: 1, alpha: 0.92),
                .paragraphStyle: style,
            ])
        let width = max(0, right - left)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let limit = NSSize(width: width, height: lineHeight * (isMessage ? 2 : 1))
        let height = min(limit.height, ceil(text.boundingRect(with: limit, options: options).height))
        text.draw(with: NSRect(x: left, y: centreY - height / 2, width: width, height: height),
                  options: options)
    }

    private func drawBars(in pill: NSRect, ctx: CGContext) {
        let count = TargetAppPill.barCount
        let span = pill.width - TargetAppPill.padding * 2
        let gap = (span - CGFloat(count) * TargetAppPill.barWidth) / CGFloat(count - 1)
        let centreY = pill.minY + 19
        let shimmering = overlayState == .transcribing && !isLingering
        let alphas = shimmering ? TargetAppPill.shimmerAlphas(tick: tick) : nil
        let restAlpha: CGFloat = overlayState == .recording ? TargetAppPill.barAlpha : 0.3
        let heights = barHeights
        // While speaking, the bars throw a soft white light into the glass around them.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: TargetAppPill.cornerRadius,
                           cornerHeight: TargetAppPill.cornerRadius, transform: nil))
        ctx.clip()
        if bloom > 0.01 {
            ctx.setShadow(offset: .zero, blur: 8 + 5 * bloom,
                          color: NSColor(white: 1, alpha: 0.32 * bloom).cgColor)
        }
        defer { ctx.restoreGState() }
        for index in 0..<count {
            let height = heights[index]
            let rect = CGRect(
                x: pill.minX + TargetAppPill.padding + CGFloat(index) * (TargetAppPill.barWidth + gap),
                y: centreY - height / 2, width: TargetAppPill.barWidth, height: height)
            let radius = min(rect.width, rect.height) / 2
            ctx.setFillColor(NSColor(white: 1, alpha: alphas.map { $0[index] * 0.85 } ?? restAlpha).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }
}
