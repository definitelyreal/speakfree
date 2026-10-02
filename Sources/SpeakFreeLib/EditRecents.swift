// Claude · 2026-09-24 · Edit Mode V1
import Foundation

/// Recent Dictations for Edit Mode: the whole committed text is one entry, and each of the
/// dictations that made it up is listed under it on a line starting with "⤷".
///
/// A committed session is written as `recording-<timestamp>-<id>.edit.json` in the recordings
/// folder, ONLY when recordings are saved (the same consent as every other transcript). It
/// holds the committed text and each paragraph (its final text, its on-device original, the
/// recording stems behind it, its revision history). Each paragraph is one ⤷ component; a
/// paragraph that merged two dictations is one component listing both recordings. Clicking a
/// component inserts that paragraph's COMMITTED text (what was actually sent), not the raw take.
/// Components live inside the parent file, so they stay reachable for as long as the parent does.
public struct EditRecentSession: Equatable {
    public let url: URL
    public let date: Date
    public let artifact: EditSessionArtifact

    public var text: String { artifact.text }
    public var components: [EditSessionArtifact.Paragraph] { artifact.paragraphs }
    public var componentStems: Set<String> { Set(artifact.paragraphs.flatMap(\.componentStems)) }
}

public enum EditRecents {
    public static let suffix = ".edit.json"

    /// Write the session file (0600). Returns its URL, or nil if it could not be written.
    @discardableResult
    public static func write(_ artifact: EditSessionArtifact) -> URL? {
        RecordingStore.ensureDirectory()
        let stamp = RecordingStore.formatTimestamp(artifact.committedAt)
        let name = "\(RecordingStore.filePrefix)\(stamp)-\(artifact.sessionID.uuidString.prefix(8))\(suffix)"
        let url = RecordingStore.recordingsDir.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(artifact) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            DiagnosticLogger.shared.log("EditRecents: could not write session file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Newest `limit` sessions, by filename (names only, no per-file reads beyond those N).
    public static func list(limit: Int) -> [EditRecentSession] {
        guard limit > 0, let names = RecordingStore.directoryEntryNames(
            atPath: RecordingStore.recordingsDir.path) else { return [] }
        let newest = names.filter { $0.hasPrefix(RecordingStore.filePrefix) && $0.hasSuffix(suffix) }
            .sorted(by: >).prefix(limit)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return newest.compactMap { name in
            let url = RecordingStore.recordingsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let artifact = try? decoder.decode(EditSessionArtifact.self, from: data) else { return nil }
            return EditRecentSession(url: url, date: artifact.committedAt, artifact: artifact)
        }
    }

    /// One row of the Recent Dictations menu, before titles.
    public enum Item: Equatable {
        case recording(URL)
        case session(EditRecentSession)
    }

    /// Merge plain recordings and Edit sessions, newest first, `limit` top-level rows. A
    /// recording that is a component of a listed session is not repeated at top level (it is
    /// reachable as that session's ⤷ row).
    public static func merge(recordings: [Recording], sessions: [EditRecentSession],
                             limit: Int = 15) -> [Item] {
        let componentStems = sessions.reduce(into: Set<String>()) { $0.formUnion($1.componentStems) }
        var rows: [(Date, Item)] = sessions.map { ($0.date, .session($0)) }
        for r in recordings {
            let stem = r.url.deletingPathExtension().lastPathComponent
            if componentStems.contains(stem) { continue }
            rows.append((r.date, .recording(r.url)))
        }
        return rows.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    /// "Edit · 3 paragraphs · The garden center opens at eight…"
    public static func parentTitle(_ s: EditRecentSession) -> String {
        let n = s.components.count
        return "Edit · \(n) paragraph\(n == 1 ? "" : "s") · \(preview(s.text))"
    }

    /// "⤷ The recital is on Friday at six."
    public static func componentTitle(_ p: EditSessionArtifact.Paragraph) -> String {
        "⤷ " + preview(p.text)
    }

    static func preview(_ text: String, max: Int = 50) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// Keep Edit sessions in step with a recordings cap: drop sessions beyond `maxCount`, and
    /// sessions whose every recording has been pruned away. Called by RecordingStore.prune.
    static func prune(maxCount: Int) {
        guard maxCount > 0, let names = RecordingStore.directoryEntryNames(
            atPath: RecordingStore.recordingsDir.path) else { return }
        let nameSet = Set(names)
        let sessions = names.filter { $0.hasPrefix(RecordingStore.filePrefix) && $0.hasSuffix(suffix) }
            .sorted(by: >)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (i, name) in sessions.enumerated() {
            let url = RecordingStore.recordingsDir.appendingPathComponent(name)
            var remove = i >= maxCount
            if !remove, let data = try? Data(contentsOf: url),
               let artifact = try? decoder.decode(EditSessionArtifact.self, from: data) {
                let stems = artifact.paragraphs.flatMap(\.componentStems)
                if !stems.isEmpty && !stems.contains(where: { nameSet.contains("\($0).wav") }) {
                    remove = true
                }
            }
            if remove { try? FileManager.default.removeItem(at: url) }
        }
    }
}
