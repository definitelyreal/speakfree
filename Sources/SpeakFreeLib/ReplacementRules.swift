import Foundation

/// One replacement as the user sees it: what to write, and every heard form that
/// should become it. On disk each trigger is its own entry in overrides.json.
public struct ReplacementRule: Equatable, Identifiable {
    public var replacement: String
    public var triggers: [String]

    public var id: String { replacement }

    public init(replacement: String, triggers: [String]) {
        self.replacement = replacement
        self.triggers = triggers
    }
}

public enum ReplacementRules {
    /// Group the flat trigger → replacement map into one rule per replacement.
    public static func grouped(_ overrides: [String: String]) -> [ReplacementRule] {
        var byReplacement: [String: [String]] = [:]
        for (trigger, replacement) in overrides {
            let key = Replacements.normalize(trigger)
            guard !key.isEmpty, !replacement.isEmpty else { continue }
            byReplacement[replacement, default: []].append(key)
        }
        return byReplacement
            .map { ReplacementRule(replacement: $0.key, triggers: $0.value.sorted()) }
            .sorted { $0.replacement.localizedCaseInsensitiveCompare($1.replacement) == .orderedAscending }
    }

    public static func flattened(_ rules: [ReplacementRule]) -> [String: String] {
        var overrides: [String: String] = [:]
        for rule in rules {
            for trigger in rule.triggers { overrides[trigger] = rule.replacement }
        }
        return overrides
    }

    /// Save `rule` into `rules`, replacing `original` when editing. A trigger belongs to
    /// one rule only, so any it shares with another rule moves here; a rule left with no
    /// triggers disappears.
    public static func saving(_ rule: ReplacementRule, replacing original: ReplacementRule? = nil,
                              into rules: [ReplacementRule]) -> [ReplacementRule] {
        let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = cleaned(rule.triggers)
        guard !replacement.isEmpty, !triggers.isEmpty else { return rules }
        var overrides = flattened(rules.filter { $0 != original })
        // Editing a rule's text must not leave its old triggers pointing at the old text.
        for (trigger, target) in overrides where target == replacement { overrides[trigger] = nil }
        for trigger in triggers { overrides[trigger] = replacement }
        return grouped(overrides)
    }

    public static func deleting(_ rule: ReplacementRule, from rules: [ReplacementRule]) -> [ReplacementRule] {
        rules.filter { $0 != rule }
    }

    /// Normalise, drop blanks and duplicates, keep first-seen order.
    public static func cleaned(_ triggers: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for trigger in triggers {
            let key = Replacements.normalize(trigger)
            guard !key.isEmpty, key.split(separator: " ").count <= Replacements.maxTriggerWords,
                  seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }
}
