// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// "Report a Problem with <App>": the logic behind the menu-bar window, kept free of AppKit so
// it is testable. Goal (2026-09-24): let someone say "this app isn't working", set a different
// method for that app on the spot, and mark a configuration that works; when the method that
// works is a less preferred one, ask them to try a better one once more.
//
// Privacy contract: nothing here ever holds dictated text. The report is built from the app's
// identity, its detected class, the methods tried and their verdicts, and the outcome labels
// the inserter records (which carry no text). Sending means opening a prefilled GitHub issue
// in the browser; the person submits it there, or does not.

import Foundation

// MARK: - Local record of "this works"

/// One "This works" confirmation, stored in config.json by bundle ID.
public struct InsertionConfirmation: Codable, Equatable {
    /// The method that actually ran (`paste`, `type`, `accessibility`), never `automatic`.
    public var method: String
    /// The per-app setting at the time (`automatic` when speakfree's own choice worked).
    public var setting: String
    public var appVersion: String?
    /// ISO 8601, UTC.
    public var confirmedAt: String

    public init(method: InsertionMethod, setting: InsertionMethod, appVersion: String?, date: Date) {
        self.method = method.rawValue
        self.setting = setting.rawValue
        self.appVersion = appVersion
        self.confirmedAt = ISO8601DateFormatter().string(from: date)
    }
}

/// The confirmations map as stored in config.json. Like `InsertionOverrideMap`, decoding never
/// throws: a malformed entry is dropped instead of failing the whole config decode.
public struct InsertionConfirmationMap: Codable, Equatable {
    public var values: [String: InsertionConfirmation]

    public init(_ values: [String: InsertionConfirmation] = [:]) { self.values = values }

    public subscript(key: String) -> InsertionConfirmation? {
        values[key] ?? values.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    public init(from decoder: Decoder) throws {
        values = [:]
        guard let raw = try? decoder.singleValueContainer().decode([String: Lenient].self) else { return }
        for (key, entry) in raw { if let value = entry.value { values[key] = value } }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    private struct Lenient: Decodable {
        let value: InsertionConfirmation?
        init(from decoder: Decoder) throws { value = try? InsertionConfirmation(from: decoder) }
    }
}

extension Config {
    /// Set (or, with `.automatic`, clear) the insertion method for one app. Same rules as the
    /// Settings row: replaces any entry for the same bundle ID regardless of letter case, and
    /// keeps entries a newer build wrote for other apps.
    public mutating func setInsertionOverride(_ method: InsertionMethod, for bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        var known = effectiveInsertionOverrides.filter { $0.key.lowercased() != lower }
        if method != .automatic { known[trimmed] = method }
        let unknown = (insertionOverrides?.unknown ?? [:]).filter { $0.key.lowercased() != lower }
        insertionOverrides = known.isEmpty && unknown.isEmpty ? nil : InsertionOverrideMap(known, unknown: unknown)
    }

    /// Remove this app's confirmation if it names `method`. Returns whether anything changed.
    @discardableResult
    public mutating func removeInsertionConfirmation(for bundleID: String, ifMethod method: InsertionMethod) -> Bool {
        let lower = bundleID.lowercased()
        guard var values = insertionConfirmations?.values,
              let key = values.keys.first(where: { $0.lowercased() == lower }),
              values[key]?.method == method.rawValue else { return false }
        values.removeValue(forKey: key)
        insertionConfirmations = values.isEmpty ? nil : InsertionConfirmationMap(values)
        return true
    }

    /// Record that `method` works for this app (one entry per app, newest wins).
    public mutating func recordInsertionConfirmation(_ confirmation: InsertionConfirmation, for bundleID: String) {
        var values = (insertionConfirmations?.values ?? [:]).filter { $0.key.lowercased() != bundleID.lowercased() }
        values[bundleID] = confirmation
        insertionConfirmations = InsertionConfirmationMap(values)
    }
}

// MARK: - The problem session

/// The app the window is about.
public struct ProblemTarget: Equatable {
    public let bundleID: String
    public let appName: String
    public let appVersion: String?
    public let classification: AppClassification

    public init(bundleID: String, appName: String, appVersion: String?, classification: AppClassification) {
        self.bundleID = bundleID
        self.appName = appName
        self.appVersion = appVersion
        self.classification = classification
    }
}

public struct ProblemTrial: Equatable {
    public let method: InsertionMethod   // concrete method, never .automatic
    public let worked: Bool
}

/// What the window suggests next.
public enum ProblemSuggestion: Equatable {
    /// A less preferred method works; ask them to try the preferred one once more.
    case tryPreferred(InsertionMethod)
    /// The current method failed; this is the next one worth trying.
    case tryNext(InsertionMethod)
    /// A trial of a better method failed; go back to the one that worked.
    case revert(to: InsertionMethod)
    /// Every method has failed. A report is the useful next step.
    case exhausted
}

public struct ProblemSession: Equatable {
    public let target: ProblemTarget
    /// The per-app setting when the window opened.
    public let initialSetting: InsertionMethod
    /// What the picker shows now (and what is saved as the app's setting).
    public private(set) var selected: InsertionMethod
    public private(set) var trials: [ProblemTrial] = []
    /// Newest outcome the inserter recorded for this app while the window was open.
    public var lastOutcome: InsertionOutcome?
    public var lastOutcomeDate: Date?
    /// Optional words from the person, shown in the report preview before anything is sent.
    public var note: String = ""

    public init(target: ProblemTarget, setting: InsertionMethod) {
        self.target = target
        self.initialSetting = setting
        self.selected = setting
    }

    public var appClass: AppClass { target.classification.appClass }

    /// The method speakfree uses for this app when the setting is Automatic (single line).
    public var automaticMethod: InsertionMethod {
        ProblemSession.method(for: AppCompatibility.route(for: appClass, override: .automatic, textHasLineBreak: false))
    }

    /// The concrete method a setting means for this app.
    public func concrete(_ setting: InsertionMethod) -> InsertionMethod {
        setting == .automatic ? automaticMethod : setting
    }

    static func method(for route: InsertionRoute) -> InsertionMethod {
        switch route {
        case .accessibilityChain: return .accessibility
        case .paste, .remotePaste: return .paste
        case .keystrokes, .remoteKeystroke: return .type
        }
    }

    /// Methods worth trying for this class, most preferred first: speakfree's own choice, then
    /// Accessibility (verified, leaves the clipboard alone), Paste, Type (slowest, most
    /// layout-sensitive). Accessibility is left out where it can never insert: terminals (their
    /// text view is not an editable field) and remote viewers (keys go to another computer).
    public var preferenceOrder: [InsertionMethod] {
        var order = [automaticMethod]
        for method in [InsertionMethod.accessibility, .paste, .type] where !order.contains(method) {
            if method == .accessibility && (appClass == .terminal || appClass == .remoteDesktop) { continue }
            order.append(method)
        }
        return order
    }

    /// True while the selection is a "try the preferred method once more" that the person has
    /// not picked themselves. Only such a trial is undone when the window closes.
    public private(set) var selectionIsSuggestedTrial = false

    public mutating func markSelectionDeliberate() { selectionIsSuggestedTrial = false }

    public mutating func select(_ setting: InsertionMethod, asSuggestedTrial: Bool = false) {
        selected = setting
        selectionIsSuggestedTrial = asSuggestedTrial
        lastOutcome = nil
        lastOutcomeDate = nil
    }

    /// Each method's latest verdict: a method that failed once and then worked counts as working.
    private var latestVerdicts: [InsertionMethod: Bool] {
        var verdicts: [InsertionMethod: Bool] = [:]
        for trial in trials { verdicts[trial.method] = trial.worked }
        return verdicts
    }
    /// Methods whose latest verdict is "works", most recently marked last.
    private var working: [InsertionMethod] {
        let verdicts = latestVerdicts
        var seen = Set<InsertionMethod>()
        return trials.reversed().map(\.method)
            .filter { verdicts[$0] == true && seen.insert($0).inserted }
            .reversed()
    }

    /// When the window closes: the setting to go back to, if any. Only a suggested "try it once
    /// more" that was not marked as working is undone, back to the method that was; a method
    /// the person picked themselves stays as they left it.
    public var settingToRestoreOnClose: InsertionMethod? {
        let current = concrete(selected)
        guard selectionIsSuggestedTrial, latestVerdicts[current] != true, let good = working.last else { return nil }
        let restore = setting(for: good)
        return restore == selected ? nil : restore
    }

    /// "This works". Returns a more preferred method to try once, if one is left untried.
    @discardableResult
    public mutating func markWorked() -> ProblemSuggestion? {
        let method = concrete(selected)
        trials.append(ProblemTrial(method: method, worked: true))
        let order = preferenceOrder
        guard let rank = order.firstIndex(of: method) else { return nil }
        let tried = Set(trials.map(\.method))
        guard let better = order.prefix(rank).first(where: { !tried.contains($0) }) else { return nil }
        return .tryPreferred(better)
    }

    /// "Didn't work". Goes back to a method that worked if there is one, else names the next.
    @discardableResult
    public mutating func markFailed() -> ProblemSuggestion {
        let method = concrete(selected)
        trials.append(ProblemTrial(method: method, worked: false))
        if let good = working.last { return .revert(to: good) }
        let tried = Set(trials.map(\.method))
        if let next = preferenceOrder.first(where: { !tried.contains($0) }) { return .tryNext(next) }
        return .exhausted
    }

    /// The setting to save for a concrete method: Automatic when that is speakfree's own
    /// choice, so the app keeps following future improvements to detection.
    public func setting(for method: InsertionMethod) -> InsertionMethod {
        method == automaticMethod ? .automatic : method
    }

    // MARK: Report

    public static let repositoryURL = "https://github.com/definitelyreal/speakfree"
    /// GitHub starts refusing new-issue links somewhere past 8,000 characters; stay well under.
    public static let maxIssueURLLength = 7_000

    public var issueTitle: String {
        let title = "App compatibility: \(target.appName) (\(target.bundleID))"
        return title.count > 160 ? String(title.prefix(159)) + "…" : title
    }

    /// Everything the report contains, exactly as it will appear in the issue.
    /// `clipboardDiagnostic`: the clipboard readers and canary section (no clipboard content),
    /// from `ClipboardTrustStore.diagnosticText`. nil leaves it out.
    public func issueBody(speakfreeVersion: String, macOSVersion: String,
                          clipboardDiagnostic: String? = nil) -> String {
        // The person's note goes last, so a link that must be trimmed loses the end of the
        // note rather than the app details a maintainer needs.
        var lines: [String] = []
        lines.append("**App**")
        lines.append("- Name: \(target.appName)" + (target.appVersion.map { " \($0)" } ?? ""))
        lines.append("- Bundle ID: \(target.bundleID)")
        lines.append("- Detected as: \(appClass.label) (\(target.classification.reason))")
        lines.append("- speakfree's own choice: \(automaticMethod.label)")
        lines.append("- Setting when the report was made: \(selected.label)"
            + (selected == .automatic ? "" : " (was \(initialSetting.label))"))
        lines.append("")
        lines.append("**What was tried**")
        if trials.isEmpty {
            lines.append("- Nothing marked yet")
        } else {
            for trial in trials {
                lines.append("- \(trial.method.label): \(trial.worked ? "works" : "did not work")")
            }
        }
        if let outcome = lastOutcome {
            lines.append("- Last result speakfree saw in this app: \(outcome.rawValue)")
        }
        lines.append("")
        lines.append("**System**")
        lines.append("- speakfree \(speakfreeVersion)")
        lines.append("- macOS \(macOSVersion)")
        lines.append("")
        if let clipboardDiagnostic, !clipboardDiagnostic.isEmpty {
            lines.append(clipboardDiagnostic)
            lines.append("")
        }
        lines.append("_Made with Report a Problem in speakfree. No dictated text is included._")
        let note = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("")
            lines.append("**What goes wrong**")
            lines.append("")
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    /// Percent-encoding for a query value: everything except unreserved characters, so `+`,
    /// `&`, `#` and `=` in an app name or a note can never change the link's meaning.
    static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static let trimmedNotice = "\n\n_(Trimmed to fit in a link. Copy the full report from speakfree and paste it here.)_"

    /// Does the full report exceed what fits in a link?
    public static func issueURLIsTrimmed(title: String, body: String, maxLength: Int = maxIssueURLLength) -> Bool {
        "\(repositoryURL)/issues/new?title=\(encodeQueryValue(title))&body=\(encodeQueryValue(body))".count > maxLength
    }

    /// A prefilled new-issue link, no longer than `maxLength`. When the body would not fit, it
    /// is cut at a line boundary and a notice says so; the title is always kept.
    public static func issueURL(title: String, body: String, maxLength: Int = maxIssueURLLength) -> URL? {
        func build(_ body: String) -> String {
            "\(repositoryURL)/issues/new?title=\(encodeQueryValue(title))&body=\(encodeQueryValue(body))"
        }
        var full = build(body)
        if full.count > maxLength {
            var lines = body.components(separatedBy: "\n")
            while !lines.isEmpty {
                lines.removeLast()
                full = build(lines.joined(separator: "\n") + trimmedNotice)
                if full.count <= maxLength { break }
            }
            if full.count > maxLength { full = build(String(trimmedNotice.drop(while: { $0 == "\n" }))) }
        }
        return URL(string: full)
    }
}
