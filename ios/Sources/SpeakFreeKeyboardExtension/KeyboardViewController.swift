// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import UIKit
import SpeakFreeKeyboardCore
import OSLog

final class KeyboardViewController: UIInputViewController, KeyboardSurfaceViewDelegate {
    private let logger = Logger(
        subsystem: "com.speakfree.keyboard.extension",
        category: "KeyboardLifecycle"
    )
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
        let startedAt: Date
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
    // One gesture may decode while at most two later gestures wait. This prevents rapid input
    // from growing retained trajectory memory without bound inside the extension process.
    private var queuedSwipes = BoundedFIFO<QueuedSwipe>(capacity: 3)
    private var swipeDecodeInFlight = false
    private var swipeChainDocument: DocumentSnapshot?
    private var heightConstraint: NSLayoutConstraint?
    private var lastLocallyProducedDocument: DocumentSnapshot?
    private var committedCandidateDocumentIdentifier: UUID?
    private let dictationIOQueue = DispatchQueue(
        label: "com.speakfree.keyboard.dictation", qos: .userInitiated
    )
    private var dictationSnapshotStore: DictationSnapshotStore?
    private var dictationClaimStore: DictationClaimStore?
    private var dictationSnapshot: DictationSnapshot?
    private var dictationRevisionState: DictationRevisionState?
    private var dictationPollTimer: DispatchSourceTimer?
    private var dictationReadInFlight = false
#if DEBUG
    private var dictationUITestResetToken: String?
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        logger.notice("Keyboard controller loaded")
        // Keep Apple's system Dictation available as a reliable fallback. SpeakFree's red relay
        // key claims an already-running local session; it cannot itself access the microphone.
        // Suppressing the system-owned button left users with no dictation at all while the local
        // models were downloading, unavailable, or recovering from a failure.
        hasDictationKey = false
        view.backgroundColor = KeyboardPalette.background
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
        configureDictationRelay()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        logger.notice("Keyboard became visible")
        startDictationPolling()
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
        logger.notice("Keyboard will disappear")
        invalidateOutstandingSwipeRequests()
        surface.cancelActiveInteraction()
        stopDictationPolling()
    }

    deinit {
        logger.notice("Keyboard controller deinitialized")
        invalidateOutstandingSwipeRequests()
        dictationPollTimer?.cancel()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        logger.error("Keyboard extension received a memory warning")
        invalidateOutstandingSwipeRequests()
        surface.cancelActiveInteraction()
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
        case .dictation:
            claimOrAdvanceDictation()
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
        guard queuedSwipes.append(QueuedSwipe(
            points: trajectory,
            keyboardSize: size
        )) else {
            candidateBar.setStatus("Finish current swipes…")
            return
        }
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
            document: expectedDocument,
            startedAt: Date()
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
            _ = self.queuedSwipes.removeFirst()
            guard case .success(let decoded) = result else {
                if self.developerLoggingEnabled {
                    let elapsed = Int(Date().timeIntervalSince(request.startedAt) * 1_000)
                    self.logger.debug("Swipe decode failed after \(elapsed, privacy: .public) ms")
                }
                if case .unavailable(let reason) = result {
                    self.logger.error("Swipe model unavailable: \(reason, privacy: .public)")
                }
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
            if self.developerLoggingEnabled {
                let elapsed = Int(Date().timeIntervalSince(request.startedAt) * 1_000)
                self.logger.debug(
                    "Swipe decoded in \(elapsed, privacy: .public) ms; result=\(rendered, privacy: .private(mask: .hash)) candidates=\(renderedWords.count, privacy: .public)"
                )
            }
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
        let action = typingEngine.deleteWord(
            before: before,
            selectedText: textDocumentProxy.selectedText
        )
        let updated: String
        switch action {
        case .deleteSelection:
            textDocumentProxy.deleteBackward()
            lastLocallyProducedDocument = documentSnapshot
            updated = textDocumentProxy.documentContextBeforeInput ?? before
        case .edit(let edit):
            apply(edit)
            updated = edit.applying(to: before)
        }
        invalidateEditingState()
        updateTapSuggestions(before: updated)
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

    private func configureDictationRelay() {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.speakfree.keyboard"
        ) {
            dictationSnapshotStore = DictationSnapshotStore(appGroupContainerURL: container)
        } else {
            logger.error("Dictation relay unavailable: App Group container could not be resolved")
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            dictationClaimStore = DictationClaimStore(
                receiptURL: support.appendingPathComponent(
                    "speakfree-dictation-claim-v1.json",
                    isDirectory: false
                )
            )
        } else {
            logger.error("Dictation relay unavailable: extension support directory could not be resolved")
        }
    }

    private func startDictationPolling() {
        guard dictationPollTimer == nil else { return }
        pollDictationSnapshot()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(125), repeating: .milliseconds(125))
        timer.setEventHandler { [weak self] in
            self?.pollDictationSnapshot()
        }
        dictationPollTimer = timer
        timer.resume()
    }

    private func stopDictationPolling() {
        dictationPollTimer?.cancel()
        dictationPollTimer = nil
    }

    private func pollDictationSnapshot() {
        guard !dictationReadInFlight, let store = dictationSnapshotStore else { return }
        dictationReadInFlight = true
        dictationIOQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            let resetURL = store.snapshotURL.deletingLastPathComponent()
                .appendingPathComponent("speakfree-dictation-ui-test-reset")
            if let token = try? String(contentsOf: resetURL, encoding: .utf8),
               token != self.dictationUITestResetToken {
                try? self.dictationClaimStore?.remove()
                self.dictationUITestResetToken = token
            }
#endif
            let currentSnapshot = try? store.read()
            let receipt = try? self.dictationClaimStore?.read()
            let terminalSnapshot: DictationSnapshot?
            if let receipt,
               currentSnapshot?.sessionID != receipt.revisionState.sessionID,
               let terminal = try? store.readTerminal(
                    sessionID: receipt.revisionState.sessionID
               ),
               terminal.revision > receipt.revisionState.appliedRevision {
                terminalSnapshot = terminal
            } else {
                terminalSnapshot = nil
            }
            let snapshot = terminalSnapshot ?? currentSnapshot
            DispatchQueue.main.async {
                self.dictationReadInFlight = false
                self.receiveDictationSnapshot(snapshot)
            }
        }
    }

    private func receiveDictationSnapshot(_ snapshot: DictationSnapshot?) {
        guard let snapshot, isFreshForKeyboardHandoff(snapshot) else {
            dictationSnapshot = nil
            dictationRevisionState = nil
            surface.dictationAvailable = false
            return
        }

        let sessionChanged = dictationSnapshot?.sessionID != snapshot.sessionID
        dictationSnapshot = snapshot
        surface.dictationAvailable = true

        if sessionChanged {
            switch restoreClaim(for: snapshot, allowRecoveryEdit: false) {
            case .none:
                dictationRevisionState = nil
            case .restored(let state):
                dictationRevisionState = state
            case .ambiguous:
                dictationRevisionState = nil
                candidateBar.setStatus("Dictation claim needs recovery in its original field")
            }
        }

        guard let state = dictationRevisionState else {
            if candidates.isEmpty {
                let preview = snapshot.renderedText.isEmpty
                    ? "Dictation listening — tap 🎙 to insert"
                    : "🎙 " + String(snapshot.renderedText.suffix(48))
                candidateBar.setStatus(preview)
            }
            return
        }
        guard snapshot.revision > state.appliedRevision else { return }
        if snapshot.phase == .active {
            applyDictation(snapshot, from: state)
            return
        }
        applyDictation(snapshot, from: state)
    }

    private func claimOrAdvanceDictation() {
        // Some hosts transiently balance the input controller's appearance callbacks while the
        // keyboard remains onscreen. An explicit claim must keep its relay alive through the
        // terminal revision even if an earlier viewWillDisappear stopped the idle poller.
        startDictationPolling()
        guard traitContext == .standard || traitContext == .search else {
            candidateBar.setStatus("Dictation inserts into standard text fields")
            return
        }
        guard dictationSnapshotStore != nil, dictationClaimStore != nil else {
            candidateBar.setStatus("Dictation relay unavailable in this build")
            logger.error("Dictation claim rejected because relay storage is unavailable")
            return
        }
        guard let snapshot = dictationSnapshot, isFreshForKeyboardHandoff(snapshot) else {
            candidateBar.setStatus("Start Dictation in the SpeakFree app first")
            return
        }

        if snapshot.phase == .active {
            claimDictationPreview(snapshot)
            return
        }

        switch restoreClaim(for: snapshot, allowRecoveryEdit: true) {
        case .restored(let restored):
            dictationRevisionState = restored
            guard snapshot.revision > restored.appliedRevision else {
                candidateBar.setStatus("This dictation is already inserted here")
                return
            }
            applyDictation(snapshot, from: restored)
        case .ambiguous:
            dictationRevisionState = nil
            candidateBar.setStatus("This dictation was claimed elsewhere or its edit is ambiguous")
        case .none:
            applyDictation(snapshot, from: nil)
        }
    }

    /// The EOU recognizer revises its complete hypothesis. Showing that hypothesis in the
    /// candidate bar gives immediate feedback without repeatedly deleting an ever-growing host
    /// suffix. The independent batch result is inserted once when the session terminalizes.
    private func claimDictationPreview(_ snapshot: DictationSnapshot) {
        let documentID = textDocumentProxy.documentIdentifier.uuidString
        switch restoreClaim(for: snapshot, allowRecoveryEdit: true) {
        case .ambiguous:
            candidateBar.setStatus("This dictation was claimed elsewhere or needs recovery")
        case .restored(let state):
            guard state.documentIdentifier == documentID else {
                candidateBar.setStatus("This dictation is already claimed in another field")
                return
            }
            if snapshot.revision > state.appliedRevision {
                applyDictation(snapshot, from: state)
            } else {
                candidateBar.setStatus(previewStatus(for: snapshot))
            }
        case .none:
            guard textDocumentProxy.selectedText?.isEmpty != false else {
                candidateBar.setStatus("Place the cursor in an empty selection and try again")
                return
            }
            // Insert the current local hypothesis immediately. The revision planner owns only
            // this suffix and safely replaces it as Parakeet improves its result. Previously the
            // red key merely changed a label and left the host field empty until Stop, which was
            // indistinguishable from a broken dictation key on a physical device.
            applyDictation(snapshot, from: nil)
        }
    }

    private func previewStatus(for snapshot: DictationSnapshot) -> String {
        snapshot.renderedText.isEmpty
            ? "Dictation listening…"
            : "🎙 " + String(snapshot.renderedText.suffix(48))
    }

    private func applyDictation(
        _ snapshot: DictationSnapshot,
        from state: DictationRevisionState?
    ) {
        if developerLoggingEnabled {
            logger.debug(
                "Applying dictation session=\(snapshot.sessionID.uuidString, privacy: .private(mask: .hash)) revision=\(snapshot.revision, privacy: .public) phase=\(snapshot.phase.rawValue, privacy: .public) text=\(snapshot.renderedText, privacy: .private(mask: .hash))"
            )
        }
        do {
            // First validate a terminal revision against the exact raw history already inserted.
            // Formatting the snapshot before this proof changes finalized segment text and makes
            // a valid live claim look like a finalized-history regression.
            if snapshot.phase != .active, let state {
                let rawDecision = try DictationRevisionPlanner.plan(
                    snapshot: snapshot,
                    in: currentDictationDocumentContext,
                    from: state
                )
                switch rawDecision {
                case .reject:
                    dictationRevisionState = nil
                    candidateBar.setStatus("Cursor changed — tap 🎙 to claim the latest text")
                    return
                case .apply(_, let nextState), .advanceWithoutEdit(let nextState):
                    let previouslyInserted = state.finalizedSegments.map(\.text).joined()
                        + state.volatileText
                    let formattingContext = contextBeforeOwnedDictation(
                        currentContext: textDocumentProxy.documentContextBeforeInput ?? "",
                        previouslyInserted: previouslyInserted,
                        state: state
                    )
                    let formatted = formattedTerminalSnapshot(
                        snapshot,
                        contextBeforeInput: formattingContext
                    ).renderedText
                    try applyDictationTransaction(
                        TypingEdit(
                            deleteBackwardCount: previouslyInserted.count,
                            insertion: formatted
                        ),
                        nextState: nextState,
                        isTerminal: true
                    )
                    return
                }
            }

            let snapshot = formattedTerminalSnapshot(
                snapshot,
                contextBeforeInput: textDocumentProxy.documentContextBeforeInput ?? ""
            )
            let decision = try DictationRevisionPlanner.plan(
                snapshot: snapshot,
                in: currentDictationDocumentContext,
                from: state
            )
            switch decision {
            case .apply(let edit, let nextState):
                try applyDictationTransaction(
                    edit,
                    nextState: nextState,
                    isTerminal: snapshot.phase != .active
                )
            case .advanceWithoutEdit(let nextState):
                acceptDictationState(nextState, isTerminal: snapshot.phase != .active)
            case .reject:
                dictationRevisionState = nil
                candidateBar.setStatus("Cursor changed — tap 🎙 to claim the latest text")
            }
        } catch {
            dictationRevisionState = nil
            candidateBar.setStatus("Dictation update unavailable")
        }
    }

    private var developerLoggingEnabled: Bool {
        UserDefaults(suiteName: "group.com.speakfree.keyboard")?.bool(
            forKey: "developerDictationLoggingEnabled"
        ) == true
    }

    private func formattedTerminalSnapshot(
        _ snapshot: DictationSnapshot,
        contextBeforeInput: String
    ) -> DictationSnapshot {
        guard snapshot.phase != .active else { return snapshot }
        let policy: DictationCapitalizationPolicy
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: policy = .none
        case .words: policy = .words
        case .allCharacters: policy = .allCharacters
        case .sentences: policy = .sentences
        @unknown default: policy = .sentences
        }
        let formatted = DictationTextFormatter.format(
            snapshot.renderedText,
            contextBeforeInput: contextBeforeInput,
            capitalization: policy
        )
        guard formatted != snapshot.renderedText else { return snapshot }
        return DictationSnapshot(
            schemaVersion: snapshot.schemaVersion,
            sessionID: snapshot.sessionID,
            revision: snapshot.revision,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            phase: snapshot.phase,
            finalizedSegments: formatted.isEmpty
                ? []
                : [DictationSegment(id: "formatted-final", text: formatted)],
            volatileSegments: []
        )
    }

    /// Returns the host-owned prefix rather than the current context, which still contains the
    /// lowercase live hypothesis. Feeding that owned suffix to sentence detection made an empty
    /// field look mid-sentence and preserved a lowercase terminal result.
    private func contextBeforeOwnedDictation(
        currentContext: String,
        previouslyInserted: String,
        state: DictationRevisionState
    ) -> String {
        if currentContext.hasSuffix(previouslyInserted) {
            return String(currentContext.dropLast(previouslyInserted.count))
        }
        let finalized = state.finalizedSegments.map(\.text).joined()
        if state.anchorSuffix.hasSuffix(finalized) {
            return String(state.anchorSuffix.dropLast(finalized.count))
        }
        // The planner already proved the cursor-local edit safe, but UIKit may truncate long
        // before-context. Preserve the available anchor instead of inventing a sentence boundary.
        return state.anchorSuffix
    }

    private var currentDictationDocumentContext: DictationDocumentContext {
        DictationDocumentContext(
            documentIdentifier: textDocumentProxy.documentIdentifier.uuidString,
            // UIKit reports nil before-context for some empty SwiftUI fields. A dictation edit is
            // always user-claimed, so bind that initial state to an empty prefix; subsequent
            // revisions still prove document identity, cursor position, after-context, and suffix.
            contextBeforeInput: textDocumentProxy.documentContextBeforeInput ?? "",
            selectedText: textDocumentProxy.selectedText,
            contextAfterInput: textDocumentProxy.documentContextAfterInput
        )
    }

    private func acceptDictationState(_ state: DictationRevisionState, isTerminal: Bool) {
        dictationRevisionState = state
        candidates = []
        candidateBar.setStatus(state.volatileText.isEmpty ? "Dictation caught up" : state.volatileText)
        guard let claimStore = dictationClaimStore else { return }
        let receipt = DictationClaimReceipt(
            revisionState: state,
            redactingTerminalText: isTerminal
        )
        try? claimStore.write(receipt)
    }

    /// A two-phase private receipt closes the extension-death gap around `insertText`. On a later
    /// process launch we can prove whether the exact edit landed, is definitely absent, or is
    /// ambiguous. Ambiguous state always fails closed.
    private func applyDictationTransaction(
        _ edit: TypingEdit,
        nextState: DictationRevisionState,
        isTerminal: Bool
    ) throws {
        guard let claimStore = dictationClaimStore else {
            throw DictationTransactionError.claimStoreUnavailable
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput
        try claimStore.write(DictationClaimReceipt(
            pending: nextState,
            edit: edit,
            contextBeforeInput: before,
            contextAfterInput: after
        ))
        apply(edit)
        dictationRevisionState = nextState
        candidates = []
        candidateBar.setStatus(
            nextState.volatileText.isEmpty ? "Dictation caught up" : nextState.volatileText
        )
        // If this atomic write fails, the pending receipt remains and is reconciled next launch.
        try? claimStore.write(DictationClaimReceipt(
            revisionState: nextState,
            redactingTerminalText: isTerminal
        ))
    }

    private func restoreClaim(
        for snapshot: DictationSnapshot,
        allowRecoveryEdit: Bool
    ) -> DictationClaimRestoreResult {
        guard let claimStore = dictationClaimStore else { return .ambiguous }
        let receipt: DictationClaimReceipt?
        do {
            receipt = try claimStore.read()
        } catch {
            return .ambiguous
        }
        guard let receipt else { return .none }
        guard receipt.revisionState.sessionID == snapshot.sessionID else { return .none }
        guard receipt.revisionState.documentIdentifier
                == textDocumentProxy.documentIdentifier.uuidString else { return .ambiguous }
        guard receipt.phase == .pending else { return .restored(receipt.revisionState) }
        guard let edit = receipt.plannedEdit,
              let originalBefore = receipt.contextBeforeInput,
              receipt.contextAfterInput == textDocumentProxy.documentContextAfterInput,
              textDocumentProxy.selectedText?.isEmpty != false,
              let currentBefore = textDocumentProxy.documentContextBeforeInput else {
            return .ambiguous
        }

        let expectedAfter = edit.applying(to: originalBefore)
        let expectedSuffix = String(expectedAfter.suffix(DictationRevisionPlanner.maximumAnchorLength))
        let editAlreadyLanded = expectedAfter.isEmpty
            ? currentBefore.isEmpty
            : currentBefore.hasSuffix(expectedSuffix)
        if editAlreadyLanded {
            try? claimStore.write(DictationClaimReceipt(
                revisionState: receipt.revisionState,
                redactingTerminalText: snapshot.phase != .active
            ))
            return .restored(receipt.revisionState)
        }
        guard currentBefore == originalBefore, allowRecoveryEdit else { return .ambiguous }
        apply(edit)
        try? claimStore.write(DictationClaimReceipt(
            revisionState: receipt.revisionState,
            redactingTerminalText: snapshot.phase != .active
        ))
        return .restored(receipt.revisionState)
    }

    private func isFreshForKeyboardHandoff(_ snapshot: DictationSnapshot) -> Bool {
        snapshot.isFresh(maximumAge: snapshot.phase == .active ? 15 : 120)
    }

    private var typingPolicy: TypingContextPolicy {
        switch traitContext {
        case .email, .url, .social: .verbatim
        case .numbersAndPunctuation, .numeric, .decimal, .phone: .numeric
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
        // A keyboard view is wider than it is tall in both orientations, so comparing its own
        // bounds always misclassified an iPhone portrait keyboard as landscape. Ask the scene (or
        // full window) instead; only use the vertical size class as a last-resort startup signal.
        let isLandscape = view.window?.windowScene?.interfaceOrientation.isLandscape
            ?? view.window.map { $0.bounds.width > $0.bounds.height }
            ?? (traitCollection.verticalSizeClass == .compact)
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

private enum DictationClaimRestoreResult {
    case none
    case restored(DictationRevisionState)
    case ambiguous
}

private enum DictationTransactionError: Error {
    case claimStoreUnavailable
}
