// Claude · 2026-09-24 · Edit Mode V1
import Foundation

/// Maps what the edit window's text now holds back onto the session's paragraphs (the model
/// is authoritative; the text view is a projection, and hand edits flow back through here).
///
/// The window stores one "\n" between paragraphs and uses U+2028 (line separator) for a
/// Shift+Return line break inside a paragraph, so splitting on "\n" always yields paragraphs. Every
/// character carries the id of the paragraph it came from. Return never inserts "\n" (it commits),
/// and pasted newlines become U+2028, so the paragraph count only drops (Backspace across a
/// boundary merges) or stays the same.
public enum EditDocumentReconciler {

    /// One paragraph as it now reads in the window.
    public struct Paragraph: Equatable {
        /// The paragraph text with in-paragraph breaks already turned back into "\n".
        public let text: String
        /// Segment ids found on its characters, in order of first appearance.
        public let ownerIDs: [UUID]

        public init(text: String, ownerIDs: [UUID]) {
            self.text = text
            self.ownerIDs = ownerIDs
        }
    }

    public enum Op: Equatable {
        case edit(UUID, String)
        case merge(owner: UUID, absorbed: [UUID], text: String)
        case remove(UUID)
        case addTyped(UUID, String)
    }

    /// - Parameters:
    ///   - paragraphs: what the window holds.
    ///   - displayed: the session's on-screen paragraphs (id, current text), in order.
    ///   - makeID: id for a paragraph typed where no dictation was (injectable for tests).
    public static func reconcile(paragraphs: [Paragraph], displayed: [(id: UUID, text: String)],
                                 makeID: () -> UUID = UUID.init) -> [Op] {
        // A window with nothing in it and no paragraphs: nothing to do.
        if displayed.isEmpty {
            return paragraphs.filter { !$0.text.isEmpty }.map { .addTyped(makeID(), $0.text) }
        }
        let known = Set(displayed.map(\.id))
        var ops: [Op] = []

        // Same count and every paragraph either carries its own id or none: map by position. This is
        // the ordinary case (typing inside paragraphs), and the only safe mapping for an emptied
        // paragraph, which has no characters to carry an id.
        if paragraphs.count == displayed.count,
           zip(paragraphs, displayed).allSatisfy({ p, d in
               p.ownerIDs.filter(known.contains).allSatisfy { $0 == d.id }
           }) {
            for (p, d) in zip(paragraphs, displayed) where p.text != d.text {
                ops.append(.edit(d.id, p.text))
            }
            return ops
        }

        // Structure changed: map by the ids on the characters.
        var owners = Set<UUID>()
        var seen = Set<UUID>()
        for p in paragraphs {
            let ids = p.ownerIDs.filter(known.contains)
            ids.forEach { seen.insert($0) }
            guard let owner = ids.first(where: { !owners.contains($0) }) else {
                if !p.text.isEmpty { ops.append(.addTyped(makeID(), p.text)) }
                continue
            }
            owners.insert(owner)
            let absorbed = ids.filter { $0 != owner && !owners.contains($0) }
            absorbed.forEach { owners.insert($0) }
            if !absorbed.isEmpty {
                ops.append(.merge(owner: owner, absorbed: absorbed, text: p.text))
            } else if displayed.first(where: { $0.id == owner })?.text != p.text {
                ops.append(.edit(owner, p.text))
            }
        }
        for d in displayed where !seen.contains(d.id) {
            ops.append(.remove(d.id))
        }
        return ops
    }

    /// U+2028, the in-paragraph line break the window uses for Shift+Return.
    public static let lineBreak: Character = "\u{2028}"

    /// Model text ("\n" = line break inside a paragraph) to window text.
    public static func displayText(_ modelText: String) -> String {
        modelText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: String(lineBreak))
    }

    /// Window text back to model text.
    public static func modelText(_ displayText: String) -> String {
        displayText.replacingOccurrences(of: String(lineBreak), with: "\n")
    }

    /// What a copy of a window selection puts on the clipboard: a paragraph boundary becomes a
    /// blank line, a line break stays one line break.
    public static func exportText(_ windowSelection: String) -> String {
        windowSelection.replacingOccurrences(of: "\n", with: "\n\n")
            .replacingOccurrences(of: String(lineBreak), with: "\n")
    }
}
