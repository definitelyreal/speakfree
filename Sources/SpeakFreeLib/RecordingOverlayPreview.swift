// ai-suggestion:unverified · session:9bb7d552-ac60-4aeb-b987-841018c752be · 2026-08-12
//
// `speakfree overlay-preview` — watch the recording overlay's entry animation
// without dictating, the same way `notice-preview` shows the recordings dialog.
//
// Nothing here touches the mic, config, or the real overlay window: it builds a
// bare OverlayContentView and feeds it a simulated speech envelope (the same
// simulator the design lab used), so the sequence is judgeable in isolation and
// on repeat. Click the window to toggle the backdrop between dark and light;
// the sequence replays automatically.

import AppKit

/// Simulated speech envelope — a direct port of the design lab's `tickAudio`
/// (build/26-08-12-record-icon-animation/lab.html). Silence, then syllables at
/// ~220ms with per-syllable amplitude variation and the occasional dropped breath.
struct PreviewSpeechSimulator {
    var level: CGFloat = 0
    private var walk: CGFloat = 0
    private var clock: Double = 0          // ms
    private var speechAt: Double = -1      // ms

    /// Lab dials: silenceMs 850, syllableMs 220, loudness 0.82, noiseFloor 0.05.
    static let silenceMs: Double = 850
    static let syllableMs: Double = 220
    static let loudness: CGFloat = 0.82
    static let noiseFloor: CGFloat = 0.05

    private static func hash(_ n: CGFloat) -> CGFloat {
        let s = sin(n * 127.1) * 43758.5453
        return s - floor(s)
    }

    mutating func reset() {
        level = 0
        walk = 0
        clock = 0
        speechAt = -1
    }

    /// `dt` in milliseconds.
    mutating func advance(_ dt: Double) {
        clock += dt
        walk = max(-1, min(1, (walk + (CGFloat.random(in: 0...1) - 0.5) * CGFloat(dt) * 0.004) * 0.94))
        let tone = Self.noiseFloor * (0.65 + 0.35 * (0.5 + walk * 0.5))
        if clock < Self.silenceMs {
            level = tone
            return
        }
        if speechAt < 0 { speechAt = clock }
        let st = clock - speechAt
        let k = CGFloat(floor(st / Self.syllableMs))
        let ph = CGFloat((st.truncatingRemainder(dividingBy: Self.syllableMs)) / Self.syllableMs)
        let amp = 0.55 + 0.45 * Self.hash(k + 3.1)
        let breath: CGFloat = Self.hash(k * 0.37) < 0.12 ? 0.12 : 1
        let env = pow(sin(.pi * min(1, ph * 1.12)), 0.75)
        level = min(1, tone + Self.loudness * amp * breath * env * (0.85 + 0.3 * (0.5 + walk * 0.5)))
    }
}

/// Backdrop the overlay is composited over; click to flip dark/light.
private final class PreviewBackdropView: NSView {
    var isLight = false
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        (isLight ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.08, alpha: 1)).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        isLight.toggle()
        needsDisplay = true
        onClick?()
    }
}

/// `speakfree overlay-preview [style]` — loops the recording overlay entry.
public enum RecordingOverlayPreview {

    /// Seconds the finished steady state is held before the sequence replays.
    private static let holdSeconds: Double = 3.5

    public static func run(style: Int = 5) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let overlaySize = OverlayContentView.usesEmergenceEntry(style: style)
            ? OverlayContentView.emergenceSize
            : OverlayContentView.prominentSize
        let pad: CGFloat = 60
        let canvas = NSRect(x: 0, y: 0,
                            width: overlaySize.width + pad * 2,
                            height: overlaySize.height + pad * 2 + 24)

        let backdrop = PreviewBackdropView(frame: canvas)

        let caption = NSTextField(labelWithString:
            "style \(style) — click to flip backdrop · replays every \(Int(holdSeconds))s")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = NSColor(white: 0.5, alpha: 1)
        caption.frame = NSRect(x: pad, y: 10, width: canvas.width - pad * 2, height: 16)
        backdrop.addSubview(caption)

        let view = OverlayContentView(frame: NSRect(x: pad, y: pad + 24,
                                                    width: overlaySize.width,
                                                    height: overlaySize.height))
        view.overlayState = .recording
        view.prominent = true
        view.style = style
        view.borderWidth = 1
        backdrop.addSubview(view)

        let window = NSWindow(contentRect: canvas,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Recording overlay — entry preview (inert)"
        window.contentView = backdrop
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFront(nil)

        var sim = PreviewSpeechSimulator()
        var frame: UInt64 = 0
        var doneAt: Date?
        var startedAt = Date()

        func replay() {
            sim.reset()
            view.heardSpeech = false
            view.speechStartedAt = nil
            view.explodeProgress = 0
            view.seedLevelsForRender([CGFloat](repeating: 0, count: 16))
            view.recordingStartedAt = Date()
            startedAt = Date()
            doneAt = nil
        }
        replay()

        // 60Hz redraw, 30Hz state — the same split the live overlay uses.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            frame &+= 1
            if frame % 2 == 0 {
                sim.advance(1000.0 / 30.0)
                view.tick += 1
                view.audioLevel = sim.level
                if !view.heardSpeech && view.audioLevel > 0.25 {
                    view.heardSpeech = true
                    view.speechStartedAt = Date()
                }
                view.advanceLevels()
            }
            if view.heardSpeech && view.explodeProgress < 1 {
                let started = view.speechStartedAt ?? Date()
                view.explodeProgress = min(1, CGFloat(-started.timeIntervalSinceNow
                                                      / OverlayEmergence.emergeDuration))
                if view.explodeProgress >= 1 { doneAt = Date() }
            }
            if let done = doneAt, -done.timeIntervalSinceNow > holdSeconds { replay() }
            // Guard against a simulator that somehow never crosses the speech gate.
            if !view.heardSpeech && -startedAt.timeIntervalSinceNow > 6 { replay() }
            view.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)

        app.activate(ignoringOtherApps: true)
        print("overlay-preview: style \(style) on screen (inert) — Ctrl-C or close to quit")
        app.run()
    }
}
