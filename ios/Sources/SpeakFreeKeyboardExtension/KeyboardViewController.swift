// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import UIKit
import SpeakFreeKeyboardCore

final class KeyboardViewController: UIInputViewController, KeyboardSurfaceViewDelegate {
    private struct DocumentSnapshot: Equatable {
        let identifier: UUID
        let before: String?
        let selected: String?
        let after: String?
    }

    private struct SwipeRequest: Equatable {
        let id: Int
        let controllerGeneration: UUID
        let document: DocumentSnapshot
    }

    private struct QueuedSwipe {
        let points: [TrajectoryPoint]
        let keyboardSize: KeyboardSize
    }

    private let candidateBar = CandidateBarView()
    private let surface = KeyboardSurfaceView()
    private var candidates: [String] = []
    private var committedCandidate: CommittedCandidate?
    private var typingEngine = TypingBehaviorEngine()
    private var uppercase = true
    private var capsLock = false
    private var numericMode = false
    private var traitContext: KeyboardSurfaceView.Context = .standard
    private var lastTraitSignature: String?
    private var previousShiftTap: Date?
    private let feedback = KeyboardFeedbackCoordinator()
    private let runtimeStore = KeyboardRuntimeStore.shared
    private let controllerGeneration = UUID()
    private var swipeRequestID = 0
    private var queuedSwipes: [QueuedSwipe] = []
    private var swipeDecodeInFlight = false
    private var swipeChainDocument: DocumentSnapshot?
    private var heightConstraint: NSLayoutConstraint?
    private var lastLocallyProducedDocument: DocumentSnapshot?
    private var committedCandidateDocumentIdentifier: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        surface.delegate = self
        candidateBar.onSelect = { [weak self] index in self?.acceptCandidate(at: index) }
        [candidateBar, surface].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            candidateBar.topAnchor.constraint(equalTo: view.topAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: 42),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 258)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint
        (view as? UIInputView)?.allowsSelfSizing = true
        feedback.prepare()
        updateTraits()
        runtimeStore.prepare()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredHeight()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.updatePreferredHeight(for: size)
        })
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        invalidateOutstandingSwipeRequests()
        surface.cancelActiveInteraction()
    }

    deinit {
        invalidateOutstandingSwipeRequests()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if documentSnapshot != lastLocallyProducedDocument {
            lastLocallyProducedDocument = nil
            invalidateOutstandingSwipeRequests()
            typingEngine.invalidateReplacement()
            clearCandidates()
        }
        updateTraits()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if documentSnapshot == lastLocallyProducedDocument {
            updateTraits()
            return
        }
        lastLocallyProducedDocument = nil
        invalidateOutstandingSwipeRequests()
        typingEngine.invalidateReplacement()
        clearCandidates()
        updateTraits()
    }

    private func updateTraits() {
        let traits = textDocumentProxy.keyboardType ?? .default
        let autocapitalization = textDocumentProxy.autocapitalizationType ?? .sentences
        let returnKeyType = textDocumentProxy.returnKeyType ?? .default
        let signature = "\(traits.rawValue):\(returnKeyType.rawValue):\(autocapitalization.rawValue)"
        let shouldResetPage = signature != lastTraitSignature
        lastTraitSignature = signature
        switch traits {
        case .emailAddress: traitContext = .email
        case .URL: traitContext = .url
        case .webSearch: traitContext = .search
        case .numbersAndPunctuation: traitContext = .numbersAndPunctuation
        case .numberPad, .asciiCapableNumberPad: traitContext = .numeric
        case .decimalPad: traitContext = .decimal
        case .phonePad: traitContext = .phone
        case .namePhonePad: traitContext = .namePhone
        case .twitter: traitContext = .social
        default: traitContext = returnKeyType == .search ? .search : .standard
        }
        if shouldResetPage {
            numericMode = traitContext.isNumeric
            surface.context = traitContext
        }
        surface.showsGlobe = needsInputModeSwitchKey
        surface.swipeEnabled = allowsSwipeTyping && !numericMode
        switch returnKeyType {
        case .search, .google: surface.returnLabel = "search"
        case .go: surface.returnLabel = "go"
        case .send: surface.returnLabel = "send"
        case .done: surface.returnLabel = "done"
        case .next: surface.returnLabel = "next"
        default: surface.returnLabel = "return"
        }
        uppercase = automaticUppercase(before: textDocumentProxy.documentContextBeforeInput ?? "")
        surface.capsLock = capsLock
        surface.uppercase = uppercase
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, tapped key: KeyboardKey) {
        feedback.emit(.keyTap)
        if key != .shift { previousShiftTap = nil }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        switch key {
        case .character(let value):
            let edit = typingEngine.tap(
                value,
                before: before,
                policy: typingPolicy,
                capitalization: capsLock ? .capsLocked : (uppercase ? .shifted : .lowercase)
            )
            apply(edit)
            updateTapSuggestions(before: edit.applying(to: before))
            updateTraits()
        case .punctuation(let value):
            apply(typingEngine.tap(value, before: before, policy: typingPolicy))
            clearCandidates()
            updateTraits()
        case .shift:
            let now = Date()
            if let prior = previousShiftTap, now.timeIntervalSince(prior) < 0.65 {
                uppercase = true
                capsLock = true
                previousShiftTap = nil
            } else {
                capsLock = false
                uppercase.toggle()
                previousShiftTap = now
            }
            surface.capsLock = capsLock
            surface.uppercase = uppercase
        case .delete:
            let edit: TypingEdit
            if let committedCandidate,
               committedCandidateDocumentIdentifier == textDocumentProxy.documentIdentifier,
               let removal = committedCandidate.removalEdit(before: before) {
                edit = removal
                self.committedCandidate = nil
                self.committedCandidateDocumentIdentifier = nil
            } else {
                edit = typingEngine.backspace(before: before)
            }
            apply(edit)
            let updated = edit.applying(to: before)
            updateTapSuggestions(before: updated)
            updateTraits()
        case .globe:
            invalidateEditingState()
            advanceToNextInputMode()
        case .mode:
            invalidateEditingState()
            if numericMode {
                numericMode = false
                surface.context = traitContext.isNumeric ? .standard : traitContext
            } else {
                numericMode = true
                surface.context = .numbersAndPunctuation
            }
            surface.swipeEnabled = allowsSwipeTyping && !numericMode
        case .space:
            let word = TypingBehaviorEngine.composition(before: before).word
            let correction = typingPolicy.allowsAutocorrection
                ? runtimeStore.bestCorrection(for: word)
                : nil
            apply(typingEngine.commitSpace(
                replacingWith: correction,
                before: before,
                policy: typingPolicy
            ))
            clearCandidates()
            updateTraits()
        case .returnKey:
            apply(TypingEdit(insertion: "\n"))
            invalidateEditingState()
            capsLock = false
            uppercase = true
            surface.capsLock = false
            surface.uppercase = true
        }
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, previewingSwipe samples: [SwipeTouchSample], keyFrames: [PositionedKey]) {
        guard allowsSwipeTyping else { return }
        let preview = traceWord(samples: samples, keyFrames: keyFrames)
        guard !preview.isEmpty else { return }
        candidateBar.setStatus(SwipeTextRenderer.render(
            preview,
            capitalization: swipeCapitalizationIntent
        ))
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, swiped samples: [SwipeTouchSample], keyFrames: [PositionedKey]) {
        guard allowsSwipeTyping else { return }
        decodeSwipe(samples: samples, in: surface)
    }

    private func decodeSwipe(
        samples: [SwipeTouchSample],
        in surface: KeyboardSurfaceView
    ) {
        let trajectory = samples.map {
            TrajectoryPoint(x: $0.point.x, y: $0.point.y, timestamp: $0.timestamp)
        }
        let size = KeyboardSize(width: surface.bounds.width, height: surface.bounds.height * 0.75)
        let snapshot = documentSnapshot
        if swipeChainDocument == nil {
            swipeChainDocument = snapshot
        } else if swipeChainDocument != snapshot {
            invalidateOutstandingSwipeRequests()
            swipeChainDocument = snapshot
        }
        queuedSwipes.append(QueuedSwipe(
            points: trajectory,
            keyboardSize: size
        ))
        processNextSwipe()
    }

    private func processNextSwipe() {
        guard !swipeDecodeInFlight,
              let queued = queuedSwipes.first,
              let expectedDocument = swipeChainDocument else { return }
        swipeDecodeInFlight = true
        // Resolve one-shot capitalization only when this queued gesture starts.
        // Earlier swipe commits may have consumed sentence capitalization.
        let capitalization = swipeCapitalizationIntent
        let request = SwipeRequest(
            id: swipeRequestID,
            controllerGeneration: controllerGeneration,
            document: expectedDocument
        )
        candidateBar.setStatus("Decoding…")
        runtimeStore.decode(
            points: queued.points,
            keyboardSize: queued.keyboardSize,
            candidateLimit: 4
        ) { [weak self] result in
            guard let self,
                  request.controllerGeneration == self.controllerGeneration,
                  request.id == self.swipeRequestID else { return }
            guard self.documentSnapshot == request.document else {
                self.invalidateOutstandingSwipeRequests()
                self.clearCandidates()
                return
            }
            self.swipeDecodeInFlight = false
            self.queuedSwipes.removeFirst()
            guard case .success(let decoded) = result else {
                self.candidates = []
                self.committedCandidate = nil
                self.committedCandidateDocumentIdentifier = nil
                self.candidateBar.setStatus("Swipe unavailable — try again")
                self.surface.accessibilityValue = "\(self.surface.accessibilityValue ?? "");source=unavailable"
                self.processNextSwipe()
                return
            }
            let words = decoded.map(\.word)
            guard !words.isEmpty else {
                self.candidateBar.setStatus("No swipe match")
                self.processNextSwipe()
                return
            }
            let renderedWords = words.map {
                SwipeTextRenderer.render($0, capitalization: capitalization)
            }
            let rendered = renderedWords[0]
            self.surface.accessibilityValue = "\(self.surface.accessibilityValue ?? "");source=model;word=\(rendered)"
            self.candidates = renderedWords
            self.candidateBar.setCandidates(renderedWords)
            self.apply(TypingEdit(insertion: rendered + " "))
            self.typingEngine.invalidateReplacement()
            self.committedCandidate = CommittedCandidate(text: rendered)
            self.committedCandidateDocumentIdentifier = self.textDocumentProxy.documentIdentifier
            self.swipeChainDocument = self.lastLocallyProducedDocument
            if !self.capsLock { self.uppercase = false }
            self.updateTraits()
            self.feedback.emit(.swipeCommit)
            if self.queuedSwipes.isEmpty {
                self.swipeChainDocument = nil
            } else {
                self.processNextSwipe()
            }
        }
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, moveCursorBy offset: Int) {
        invalidateEditingState()
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        feedback.emit(.cursorStep)
    }

    func keyboardSurfaceDeleteWord(_ surface: KeyboardSurfaceView) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let edit = typingEngine.deleteWord(before: before)
        apply(edit)
        invalidateEditingState()
        updateTapSuggestions(before: edit.applying(to: before))
        updateTraits()
        feedback.emit(.deleteWord)
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, selectedAlternate value: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let edit = typingEngine.tap(
            value,
            before: before,
            policy: typingPolicy,
            capitalization: capsLock ? .capsLocked : (uppercase ? .shifted : .lowercase)
        )
        apply(edit)
        feedback.emit(.keyTap)
        previousShiftTap = nil
        updateTapSuggestions(before: edit.applying(to: before))
        updateTraits()
    }

    func keyboardSurfaceDidCancelGesture(_ surface: KeyboardSurfaceView) {
        invalidateOutstandingSwipeRequests()
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, handleGlobeWith event: UIEvent) {
        handleInputModeList(from: surface, with: event)
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, feedback event: KeyboardFeedbackEvent) {
        feedback.emit(event)
    }

    private func apply(_ edit: TypingEdit) {
        guard edit != .none else { return }
        let before = documentSnapshot
        for _ in 0..<edit.deleteBackwardCount { textDocumentProxy.deleteBackward() }
        if !edit.insertion.isEmpty { textDocumentProxy.insertText(edit.insertion) }
        lastLocallyProducedDocument = DocumentSnapshot(
            identifier: before.identifier,
            before: before.before.map { edit.applying(to: $0) },
            selected: nil,
            after: before.after
        )
    }

    private func acceptCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        let candidate = candidates[index]
        if let committedCandidate {
            guard committedCandidateDocumentIdentifier == textDocumentProxy.documentIdentifier else {
                clearCandidates()
                return
            }
            guard textDocumentProxy.selectedText?.isEmpty != false else {
                clearCandidates()
                return
            }
            guard let edit = committedCandidate.replacementEdit(
                with: candidate,
                before: textDocumentProxy.documentContextBeforeInput
            ) else {
                clearCandidates()
                return
            }
            apply(edit)
            self.committedCandidate = CommittedCandidate(text: candidate)
            self.committedCandidateDocumentIdentifier = textDocumentProxy.documentIdentifier
            feedback.emit(.candidateCommit)
        } else {
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            apply(typingEngine.commitSpace(replacingWith: candidate, before: before))
            feedback.emit(.candidateCommit)
            clearCandidates()
        }
    }

    private func updateTapSuggestions(before context: String) {
        committedCandidate = nil
        committedCandidateDocumentIdentifier = nil
        let composition = TypingBehaviorEngine.composition(before: context).word
        guard !composition.isEmpty else {
            clearCandidates()
            return
        }
        var words = [composition]
        words.append(contentsOf: runtimeStore.suggestions(for: composition, limit: 3))
        candidates = words
        candidateBar.setCandidates(words)
    }

    private func clearCandidates() {
        candidates = []
        candidateBar.setCandidates([])
        committedCandidate = nil
        committedCandidateDocumentIdentifier = nil
    }

    /// Temporary geometric trace reader. The independent neural/CTC decoder replaces this path.
    private func traceWord(samples: [SwipeTouchSample], keyFrames: [PositionedKey]) -> String {
        var letters: [String] = []
        for sample in samples {
            let point = sample.point
            let nearest = keyFrames
                .filter(\.key.isCharacter)
                .min { hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y) }
            guard case .character(let value) = nearest?.key, value != letters.last else { continue }
            letters.append(value)
        }
        return letters.joined()
    }

    private func invalidateOutstandingSwipeRequests() {
        swipeRequestID &+= 1
        queuedSwipes.removeAll()
        swipeDecodeInFlight = false
        swipeChainDocument = nil
    }

    private func invalidateEditingState(clearCandidates shouldClearCandidates: Bool = true) {
        invalidateOutstandingSwipeRequests()
        typingEngine.invalidateReplacement()
        committedCandidate = nil
        committedCandidateDocumentIdentifier = nil
        if shouldClearCandidates { clearCandidates() }
    }

    private var typingPolicy: TypingContextPolicy {
        switch traitContext {
        case .email, .url, .social: .verbatim
        case .numeric, .decimal, .phone: .numeric
        default: .prose
        }
    }

    private var allowsSwipeTyping: Bool {
        traitContext == .standard || traitContext == .search
    }

    private var swipeCapitalizationIntent: TypingCapitalizationIntent {
        if capsLock || textDocumentProxy.autocapitalizationType == .allCharacters {
            return .capsLocked
        }
        return uppercase ? .shifted : .lowercase
    }

    private var documentSnapshot: DocumentSnapshot {
        DocumentSnapshot(
            identifier: textDocumentProxy.documentIdentifier,
            before: textDocumentProxy.documentContextBeforeInput,
            selected: textDocumentProxy.selectedText,
            after: textDocumentProxy.documentContextAfterInput
        )
    }

    private func automaticUppercase(before context: String) -> Bool {
        if capsLock { return true }
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: return false
        case .allCharacters: return true
        case .words: return context.isEmpty || context.last?.isWhitespace == true
        case .sentences:
            return TypingBehaviorEngine.capitalizationState(before: context) == .shifted
                || context.last.map { ".!?".contains($0) } == true
        @unknown default:
            return TypingBehaviorEngine.capitalizationState(before: context) == .shifted
                || context.last.map { ".!?".contains($0) } == true
        }
    }

    private func updatePreferredHeight(for size: CGSize? = nil) {
        let resolvedSize = size ?? view.bounds.size
        let isLandscape = resolvedSize.width > resolvedSize.height
        let isPad = traitCollection.userInterfaceIdiom == .pad
        let desired: CGFloat
        switch (isPad, isLandscape) {
        case (true, true): desired = 260
        case (true, false): desired = 320
        case (false, true): desired = 216
        case (false, false): desired = 258
        }
        if abs((heightConstraint?.constant ?? 0) - desired) > 0.5 {
            heightConstraint?.constant = desired
        }
    }
}
