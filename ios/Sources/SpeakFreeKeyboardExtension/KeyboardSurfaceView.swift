// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import UIKit
import SpeakFreeKeyboardCore

protocol KeyboardSurfaceViewDelegate: AnyObject {
    func keyboardSurface(_ surface: KeyboardSurfaceView, tapped key: KeyboardKey)
    func keyboardSurface(_ surface: KeyboardSurfaceView, previewingSwipe samples: [SwipeTouchSample], keyFrames: [PositionedKey])
    func keyboardSurface(_ surface: KeyboardSurfaceView, swiped samples: [SwipeTouchSample], keyFrames: [PositionedKey])
    func keyboardSurface(_ surface: KeyboardSurfaceView, moveCursorBy offset: Int)
    func keyboardSurfaceDeleteWord(_ surface: KeyboardSurfaceView)
    func keyboardSurface(_ surface: KeyboardSurfaceView, selectedAlternate value: String)
    func keyboardSurfaceDidCancelGesture(_ surface: KeyboardSurfaceView)
    func keyboardSurface(_ surface: KeyboardSurfaceView, handleGlobeWith event: UIEvent)
    func keyboardSurface(_ surface: KeyboardSurfaceView, feedback event: KeyboardFeedbackEvent)
}

struct SwipeTouchSample {
    let point: CGPoint
    let timestamp: TimeInterval
}

final class KeyboardSurfaceView: UIView {
    enum Context: Equatable {
        case standard
        case email
        case url
        case search
        case numbersAndPunctuation
        case numeric
        case decimal
        case phone
        case namePhone
        case social

        var isNumeric: Bool {
            switch self {
            case .numbersAndPunctuation, .numeric, .decimal, .phone: true
            default: false
            }
        }
    }

    weak var delegate: KeyboardSurfaceViewDelegate?
    var uppercase = true { didSet { if uppercase != oldValue { refreshAppearance() } } }
    var capsLock = false { didSet { if capsLock != oldValue { refreshAppearance() } } }
    var context: Context = .standard { didSet { if context != oldValue { refreshAppearance() } } }
    var showsGlobe = true { didSet { if showsGlobe != oldValue { refreshAppearance() } } }
    var dictationAvailable = false { didSet { if dictationAvailable != oldValue { refreshAppearance() } } }
    var swipeEnabled = true
    var numericMode: Bool { context.isNumeric }
    var returnLabel = "return" { didSet { if returnLabel != oldValue { refreshAppearance() } } }

    private(set) var positionedKeys: [PositionedKey] = []
    private var trackingSamples: [SwipeTouchSample] = []
    private var initialKey: KeyboardKey?
    private var initialPoint = CGPoint.zero
    private var longPressWork: DispatchWorkItem?
    private var alternateView: UIStackView?
    private var selectedAlternate: String?
    private var gestureMachine = KeyboardGestureMachine()
    private var activeTouchIdentity: ObjectIdentifier?
    private var gestureGeneration = 0
    private var gestureKeyFrames: [PositionedKey] = []
    private var deleteRepeatWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = false
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = true
        accessibilityIdentifier = "keyboardSurface"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionedKeys = makeLayout(in: bounds)
        rebuildAccessibilityElements()
    }

    override func draw(_ rect: CGRect) {
        let graphicsContext = UIGraphicsGetCurrentContext()
        graphicsContext?.setShadow(offset: CGSize(width: 0, height: 1), blur: 0.5, color: UIColor.black.withAlphaComponent(0.25).cgColor)
        for item in positionedKeys {
            let isSpecial = !item.key.isCharacter && item.key != .space && {
                if case .punctuation = item.key { return false }
                return true
            }()
            let fill = isSpecial ? UIColor.secondarySystemFill : UIColor.systemBackground
            let path = UIBezierPath(roundedRect: item.frame.insetBy(dx: 2.5, dy: 3), cornerRadius: 5)
            fill.setFill()
            path.fill()

            var label = item.key.label
            if case .character(let value) = item.key { label = uppercase ? value.uppercased() : value }
            if item.key == .shift, capsLock { label = "⇪" }
            if item.key == .mode, context.isNumeric { label = "ABC" }
            if item.key == .returnKey { label = returnLabel }
            let font = UIFont.systemFont(ofSize: item.key == .space ? 14 : 20, weight: .regular)
            let foreground: UIColor = item.key == .dictation && dictationAvailable
                ? .systemRed
                : .label
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: item.frame.midX - size.width / 2, y: item.frame.midY - size.height / 2), withAttributes: attributes)
        }

        if trackingSamples.count > 1, gestureMachine.state == .swiping {
            let path = UIBezierPath()
            path.move(to: trackingSamples[0].point)
            for sample in trackingSamples.dropFirst() { path.addLine(to: sample.point) }
            path.lineWidth = 5
            path.lineCapStyle = .round
            UIColor.systemBlue.withAlphaComponent(0.58).setStroke()
            path.stroke()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        gestureGeneration &+= 1
        activeTouchIdentity = ObjectIdentifier(touch)
        let point = touch.location(in: self)
        initialPoint = point
        initialKey = key(at: point)
        trackingSamples = [SwipeTouchSample(point: point, timestamp: touch.timestamp)]
        selectedAlternate = nil
        gestureKeyFrames = positionedKeys
        gestureMachine.begin(
            role: gestureRole(for: initialKey),
            x: point.x,
            y: point.y,
            timestamp: touch.timestamp
        )
        scheduleLongPress(for: initialKey, at: point)
        if initialKey == .delete { scheduleDeleteRepeat(generation: gestureGeneration) }
        if initialKey == .globe, let event {
            delegate?.keyboardSurface(self, handleGlobeWith: event)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              activeTouchIdentity == ObjectIdentifier(touch) else { return }
        let point = touch.location(in: self)
        if initialKey == .globe, let event {
            delegate?.keyboardSurface(self, handleGlobeWith: event)
        }
        trackingSamples.append(SwipeTouchSample(point: point, timestamp: touch.timestamp))
        let dx = point.x - initialPoint.x
        let dy = point.y - initialPoint.y
        let distance = hypot(dx, dy)
        if distance > 12 {
            cancelLongPress()
            cancelDeleteRepeat()
        }

        if gestureMachine.state == .selectingAlternate {
            updateAlternateSelection(at: point)
            setNeedsDisplay()
            return
        }

        for action in gestureMachine.move(
            x: point.x,
            y: point.y,
            timestamp: touch.timestamp
        ) {
            switch action {
            case .moveCursor(let delta):
                delegate?.keyboardSurface(self, moveCursorBy: delta)
            case .deleteWord:
                delegate?.keyboardSurfaceDeleteWord(self)
            case .previewSwipe:
                delegate?.keyboardSurface(self, previewingSwipe: trackingSamples, keyFrames: gestureKeyFrames)
            }
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              activeTouchIdentity == ObjectIdentifier(touch) else { return }
        cancelLongPress()
        cancelDeleteRepeat()
        defer { resetTracking() }
        if initialKey == .globe, let event {
            delegate?.keyboardSurface(self, handleGlobeWith: event)
            return
        }
        let outcome = gestureMachine.end(hasSelectedAlternate: selectedAlternate != nil)
        accessibilityValue = "last=\(String(describing: outcome));samples=\(trackingSamples.count)"
        if outcome == .selectedAlternate, let selectedAlternate {
            delegate?.keyboardSurface(self, selectedAlternate: selectedAlternate)
            return
        }
        guard let initialKey else { return }
        switch outcome {
        case .commitSwipe:
            delegate?.keyboardSurface(self, swiped: trackingSamples, keyFrames: gestureKeyFrames)
        case .tap:
            delegate?.keyboardSurface(self, tapped: initialKey)
        case .selectedAlternate, .none:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.contains(where: { activeTouchIdentity == ObjectIdentifier($0) }) else { return }
        if initialKey == .globe, let event {
            delegate?.keyboardSurface(self, handleGlobeWith: event)
        }
        cancelLongPress()
        cancelDeleteRepeat()
        gestureMachine.cancel()
        delegate?.keyboardSurfaceDidCancelGesture(self)
        resetTracking()
    }

    func cancelActiveInteraction() {
        cancelLongPress()
        cancelDeleteRepeat()
        if gestureMachine.state != .idle { delegate?.keyboardSurfaceDidCancelGesture(self) }
        gestureMachine.cancel()
        resetTracking()
    }

    private func resetTracking() {
        trackingSamples.removeAll()
        initialKey = nil
        gestureMachine.cancel()
        activeTouchIdentity = nil
        gestureKeyFrames.removeAll()
        alternateView?.removeFromSuperview()
        alternateView = nil
        selectedAlternate = nil
        setNeedsDisplay()
    }

    private func refreshAppearance() {
        positionedKeys = makeLayout(in: bounds)
        setNeedsDisplay()
        rebuildAccessibilityElements()
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private func cancelDeleteRepeat() {
        deleteRepeatWork?.cancel()
        deleteRepeatWork = nil
    }

    private func scheduleLongPress(for key: KeyboardKey?, at point: CGPoint) {
        let semanticValue: String
        switch key {
        case .character(let value), .punctuation(let value): semanticValue = value
        default: return
        }
        let displayValue = uppercase ? semanticValue.uppercased() : semanticValue
        let alternatives = TypingAlternates.alternatives(for: displayValue)
        guard !alternatives.isEmpty else { return }
        let generation = gestureGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.gestureGeneration,
                  self.gestureMachine.beginAlternateSelection() else { return }
            self.cancelDeleteRepeat()
            self.showAlternates(alternatives, above: point)
            self.delegate?.keyboardSurface(self, feedback: .alternateOpened)
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    private func scheduleDeleteRepeat(generation: Int, delay: TimeInterval = 0.42) {
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.gestureGeneration,
                  self.initialKey == .delete,
                  self.gestureMachine.beginDeleteRepeating() else { return }
            self.delegate?.keyboardSurface(self, tapped: .delete)
            self.scheduleDeleteRepeat(generation: generation, delay: 0.075)
        }
        deleteRepeatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showAlternates(_ alternatives: [String], above point: CGPoint) {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 1
        stack.backgroundColor = .secondarySystemBackground
        stack.layer.cornerRadius = 8
        stack.clipsToBounds = true
        for alternate in alternatives {
            let label = UILabel()
            label.text = alternate
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 22)
            label.widthAnchor.constraint(equalToConstant: 42).isActive = true
            stack.addArrangedSubview(label)
        }
        stack.frame = CGRect(x: max(4, min(bounds.width - CGFloat(alternatives.count) * 42 - 8, point.x - 21)),
                             y: max(2, point.y - 58), width: CGFloat(alternatives.count) * 42 + 8, height: 48)
        addSubview(stack)
        alternateView = stack
        updateAlternateSelection(at: point)
    }

    private func updateAlternateSelection(at point: CGPoint) {
        guard let stack = alternateView else { return }
        let local = convert(point, to: stack)
        let index = max(0, min(stack.arrangedSubviews.count - 1, Int(local.x / 42)))
        for (candidateIndex, view) in stack.arrangedSubviews.enumerated() {
            view.backgroundColor = candidateIndex == index ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        }
        let newSelection = (stack.arrangedSubviews[index] as? UILabel)?.text
        if selectedAlternate != nil, selectedAlternate != newSelection {
            delegate?.keyboardSurface(self, feedback: .alternateChanged)
        }
        selectedAlternate = newSelection
    }

    private func key(at point: CGPoint) -> KeyboardKey? {
        positionedKeys.first(where: { $0.frame.contains(point) })?.key
    }

    private func gestureRole(for key: KeyboardKey?) -> KeyboardGestureRole {
        switch key {
        case .character: swipeEnabled ? .character : .disabledCharacter
        case .space: .space
        case .delete: .delete
        default: .other
        }
    }

    private func makeLayout(in bounds: CGRect) -> [PositionedKey] {
        let rows: [[KeyboardKey]]
        switch context {
        case .numbersAndPunctuation:
            rows = [
                "1234567890".map { .character(String($0)) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""] .map { .punctuation($0) },
                [.mode] + [".", ",", "?", "!", "'"] .map { .punctuation($0) } + [.delete],
                visible([.globe, .space, .returnKey])
            ]
        case .numeric, .decimal, .phone:
            let thirdRow: [KeyboardKey]
            let lastRow: [KeyboardKey]
            if context == .phone {
                thirdRow = ["7", "8", "9"].map { .character($0) }
                lastRow = [.mode, .punctuation("+"), .character("0"), .punctuation("#"), .delete]
            } else {
                thirdRow = ["7", "8", "9"].map { .character($0) }
                lastRow = visible([.mode, .globe])
                    + (context == .decimal ? [.punctuation(".")] : [])
                    + [.character("0"), .delete, .returnKey]
            }
            rows = [
                ["1", "2", "3"].map { .character($0) },
                ["4", "5", "6"].map { .character($0) },
                thirdRow,
                lastRow
            ]
        case .standard, .email, .url, .search, .namePhone, .social:
            let bottomRow: [KeyboardKey]
            switch context {
            case .email:
                bottomRow = visible([.mode, .globe]) + [.punctuation("@"), .space, .punctuation("."), .returnKey]
            case .url:
                bottomRow = visible([.mode, .globe]) + [.punctuation("/"), .space, .punctuation("."), .punctuation(".com"), .returnKey]
            case .social:
                bottomRow = visible([.mode, .globe]) + [.punctuation("@"), .punctuation("#"), .space, .returnKey]
            case .namePhone:
                bottomRow = visible([.mode, .globe]) + [.punctuation("+"), .space, .returnKey]
            case .search, .standard:
                bottomRow = visible([.mode, .globe, .dictation, .space, .returnKey])
            case .numbersAndPunctuation, .numeric, .decimal, .phone:
                bottomRow = []
            }
            rows = [
                "qwertyuiop".map { .character(String($0)) },
                "asdfghjkl".map { .character(String($0)) },
                [.shift] + "zxcvbnm".map { .character(String($0)) } + [.delete],
                bottomRow
            ]
        }
        let rowHeight = bounds.height / CGFloat(rows.count)
        var output: [PositionedKey] = []
        for (rowIndex, row) in rows.enumerated() {
            let weights = row.map { key -> CGFloat in
                switch key {
                case .space: 4.4
                case .returnKey: 1.9
                case .shift, .delete: 1.45
                case .mode: 1.35
                case .globe: 1.0
                case .dictation: 1.0
                default: 1.0
                }
            }
            let total = weights.reduce(0, +)
            let naturalWidth = bounds.width / total
            let inset: CGFloat = (!context.isNumeric && rowIndex == 1) ? bounds.width * 0.045 : 0
            let available = bounds.width - inset * 2
            let weightedWidth = available / total
            var x = inset
            for (index, key) in row.enumerated() {
                let width = (inset > 0 ? weightedWidth : naturalWidth) * weights[index]
                output.append(PositionedKey(key: key, frame: CGRect(x: x, y: CGFloat(rowIndex) * rowHeight, width: width, height: rowHeight)))
                x += width
            }
        }
        return output
    }

    private func visible(_ keys: [KeyboardKey]) -> [KeyboardKey] {
        showsGlobe ? keys : keys.filter { $0 != .globe }
    }

    private func rebuildAccessibilityElements() {
        guard !positionedKeys.isEmpty else {
            accessibilityElements = []
            return
        }
        accessibilityElements = positionedKeys.map { item in
            let element = KeyboardKeyAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = accessibilityLabel(for: item.key)
            element.accessibilityIdentifier = "key_\(accessibilityIdentifier(for: item.key))"
            element.accessibilityTraits = [.keyboardKey]
            if item.key == .shift, uppercase { element.accessibilityTraits.insert(.selected) }
            // The painted key keeps a visual gutter, but its accessibility target owns the full
            // layout cell just like touch hit-testing. Letter columns are narrower than 44 pt on
            // iPhone; insetting them made VoiceOver and Switch Control targets unnecessarily tiny.
            element.accessibilityFrameInContainerSpace = item.frame
            element.onActivate = { [weak self] in
                guard let self else { return false }
                self.delegate?.keyboardSurface(self, tapped: item.key)
                return true
            }
            if item.key == .delete {
                element.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Delete word") { [weak self] _ in
                        guard let self else { return false }
                        self.delegate?.keyboardSurfaceDeleteWord(self)
                        return true
                    }
                ]
            } else if item.key == .space {
                element.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Move cursor left") { [weak self] _ in
                        guard let self else { return false }
                        self.delegate?.keyboardSurface(self, moveCursorBy: -1)
                        return true
                    },
                    UIAccessibilityCustomAction(name: "Move cursor right") { [weak self] _ in
                        guard let self else { return false }
                        self.delegate?.keyboardSurface(self, moveCursorBy: 1)
                        return true
                    }
                ]
            } else {
                let alternatives: [String]
                switch item.key {
                case .character(let value), .punctuation(let value):
                    alternatives = TypingAlternates.alternatives(
                        for: uppercase ? value.uppercased() : value
                    )
                default:
                    alternatives = []
                }
                if !alternatives.isEmpty {
                    element.accessibilityCustomActions = alternatives.map { alternate in
                        UIAccessibilityCustomAction(name: alternate) { [weak self] _ in
                            guard let self else { return false }
                            self.delegate?.keyboardSurface(self, selectedAlternate: alternate)
                            return true
                        }
                    }
                }
            }
            return element
        }
    }

    private func accessibilityLabel(for key: KeyboardKey) -> String {
        switch key {
        case .character(let value): uppercase ? value.uppercased() : value
        case .punctuation(let value): value
        case .shift: capsLock ? "Caps lock" : "Shift"
        case .delete: "Delete"
        case .globe: "Next keyboard"
        case .dictation: dictationAvailable ? "Insert SpeakFree dictation" : "SpeakFree dictation"
        case .mode: context.isNumeric ? "Letters" : "Numbers"
        case .space: "Space"
        case .returnKey: returnLabel.capitalized
        }
    }

    private func accessibilityIdentifier(for key: KeyboardKey) -> String {
        let value: String
        switch key {
        case .character(let label): value = label
        case .punctuation(let label):
            value = "punctuation_" + label.unicodeScalars.map {
                "u" + String($0.value, radix: 16, uppercase: true)
            }.joined(separator: "_")
        case .shift: value = "shift"
        case .delete: value = "delete"
        case .globe: value = "globe"
        case .dictation: value = "dictation"
        case .mode: value = "mode"
        case .space: value = "space"
        case .returnKey: value = "return"
        }
        return value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
    }

}

private final class KeyboardKeyAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? false
    }
}
