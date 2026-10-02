// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core · 2026-10-01
import AppKit
import Foundation

/// Bytes, rather than an attributed-string/image conversion, are the replay authority.
/// Converting to NSImage or String while storing would discard alternate representations.
struct HistoryRepresentation: Codable, Equatable {
    let type: String
    let data: Data
}

struct HistoryPasteboardItem: Codable, Equatable {
    let representations: [HistoryRepresentation]
    /// For example, TIFF omitted when the writer also supplies lossless PNG. This is
    /// deliberately visible metadata, not a claim to retain every offered format.
    let omittedRepresentationTypes: [String]

    init(representations: [HistoryRepresentation], omittedRepresentationTypes: [String] = []) {
        self.representations = representations
        self.omittedRepresentationTypes = omittedRepresentationTypes
    }

    private enum CodingKeys: String, CodingKey { case representations, omittedRepresentationTypes }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        representations = try values.decode([HistoryRepresentation].self, forKey: .representations)
        omittedRepresentationTypes = try values.decodeIfPresent([String].self, forKey: .omittedRepresentationTypes) ?? []
    }

    var byteCount: Int { representations.reduce(0) { $0 + $1.data.count } }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        representations.first { $0.type == type.rawValue }?.data
    }

    var plainText: String? {
        if let data = data(forType: .string) { return String(data: data, encoding: .utf8) }
        if let data = representations.first(where: { $0.type == "public.utf16-plain-text" })?.data {
            return String(data: data, encoding: .utf16)
        }
        return nil
    }
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case dictation, clipboard }

    let id: UUID
    let createdAt: Date
    let source: Source
    /// Best-effort foreground-app attribution, never an authenticated pasteboard writer.
    let sourceAppBundleID: String?
    let linkedArchiveID: String?
    let items: [HistoryPasteboardItem]
    private let summary: Summary

    /// Search indexes only this much text per entry. It never changes replay bytes.
    static let searchByteLimit = 64 * 1024
    private struct Summary: Equatable {
        let byteCount: Int
        let containsImage: Bool
        let containsFiles: Bool
        let displayTitle: String
        let searchableText: String
        let searchWasTruncated: Bool
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), source: Source,
         sourceAppBundleID: String? = nil, linkedArchiveID: String? = nil,
         items: [HistoryPasteboardItem]) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.sourceAppBundleID = sourceAppBundleID
        self.linkedArchiveID = linkedArchiveID
        self.items = items
        self.summary = Self.makeSummary(items: items, sourceAppBundleID: sourceAppBundleID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, source, sourceAppBundleID, linkedArchiveID, items
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  createdAt: try values.decode(Date.self, forKey: .createdAt),
                  source: try values.decode(Source.self, forKey: .source),
                  sourceAppBundleID: try values.decodeIfPresent(String.self, forKey: .sourceAppBundleID),
                  linkedArchiveID: try values.decodeIfPresent(String.self, forKey: .linkedArchiveID),
                  items: try values.decode([HistoryPasteboardItem].self, forKey: .items))
    }

    var byteCount: Int { summary.byteCount }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(summary.byteCount), countStyle: .file) }
    /// Full text for explicit consumers/tests, not UI filtering. Display/search use the
    /// bounded cached summary below; replay always uses the original item representations.
    var plainText: String? {
        let strings = items.compactMap(\.plainText)
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    var containsImage: Bool { summary.containsImage }
    var containsFiles: Bool { summary.containsFiles }
    var displayTitle: String { summary.displayTitle }
    var searchWasTruncated: Bool { summary.searchWasTruncated }
    var representationNote: String? {
        items.contains(where: { !$0.omittedRepresentationTypes.isEmpty })
            ? "Original PNG saved; alternate TIFF omitted to avoid expanding the image. Format-specific metadata may differ."
            : nil
    }

    func matches(_ query: String) -> Bool {
        guard query.utf8.count <= Self.searchByteLimit else { return false }
        return query.isEmpty || summary.searchableText.localizedCaseInsensitiveContains(query)
    }

    private static func makeSummary(items: [HistoryPasteboardItem], sourceAppBundleID: String?) -> Summary {
        var budget = searchByteLimit
        var truncated = false
        var searchable = ""
        var textTitle: String?
        var filenames: [String] = []
        var bytes = 0
        var image = false
        var files = false
        var pdf = false
        var rich = false
        func appendSearch(_ value: String) {
            let data = Data(value.utf8)
            if data.count > budget { truncated = true }
            guard budget > 0 else { return }
            let prefix = data.prefix(budget)
            searchable += String(decoding: prefix, as: UTF8.self)
            budget -= prefix.count
            if budget > 0 { searchable += "\n"; budget -= 1 }
        }
        for item in items {
            bytes += item.byteCount
            for representation in item.representations {
                image = image || imageTypes.contains(representation.type)
                files = files || fileTypes.contains(representation.type)
                pdf = pdf || representation.type == "com.adobe.pdf"
                rich = rich || ["public.rtf", "com.apple.flat-rtfd", "public.html"].contains(representation.type)
            }
            if let text = item.data(forType: .string) {
                if text.count > budget { truncated = true }
                let value = String(decoding: text.prefix(budget), as: UTF8.self)
                if textTitle == nil, !value.isEmpty { textTitle = value }
                appendSearch(value)
            } else if let data = item.representations.first(where: { $0.type == "public.utf16-plain-text" })?.data {
                if data.count > budget { truncated = true }
                // A bounded UTF-16 decode; retain whole code units. The raw payload is unchanged.
                let bound = min(data.count, budget) / 2 * 2
                let value = String(data: data.prefix(bound), encoding: .utf16) ?? ""
                if textTitle == nil, !value.isEmpty { textTitle = value }
                appendSearch(value)
            }
            if let data = item.data(forType: .fileURL) {
                if data.count > budget { truncated = true }
                let value = String(decoding: data.prefix(budget), as: UTF8.self)
                if let url = URL(string: value), url.isFileURL {
                    filenames.append(url.lastPathComponent)
                    appendSearch(url.lastPathComponent)
                }
            } else if let data = item.representations.first(where: { $0.type == "NSFilenamesPboardType" })?.data {
                // Legacy filename lists are small property lists, never file-content reads.
                if data.count <= budget,
                   let names = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] {
                    for name in names {
                        let filename = (name as NSString).lastPathComponent
                        filenames.append(filename)
                        appendSearch(filename)
                    }
                } else { truncated = true }
            }
        }
        let title: String
        if !filenames.isEmpty {
            title = String(filenames.joined(separator: ", ").prefix(180))
        } else if let textTitle { title = String(textTitle.replacingOccurrences(of: "\n", with: " ↵ ").prefix(180)) }
        else if files { title = items.count == 1 ? "File" : "\(items.count) files" }
        else if image { title = items.count == 1 ? "Image" : "\(items.count) clipboard items" }
        else if pdf { title = "PDF" }
        else if rich { title = "Rich text" }
        else { title = "Clipboard item" }
        appendSearch(title)
        if let sourceAppBundleID { appendSearch(String(decoding: sourceAppBundleID.utf8.prefix(512), as: UTF8.self)) }
        return Summary(byteCount: bytes, containsImage: image, containsFiles: files, displayTitle: title,
                       searchableText: searchable, searchWasTruncated: truncated)
    }

    /// Creates fresh objects; NSPasteboardItem instances cannot be written to two boards.
    /// File URLs remain references. This neither loads files nor grants sandbox access.
    func makePasteboardItems(includeHistoryMarker: Bool = false) -> [NSPasteboardItem] {
        items.map { saved in
            let item = NSPasteboardItem()
            for representation in saved.representations {
                item.setData(representation.data, forType: .init(representation.type))
            }
            if includeHistoryMarker { item.setData(Data(), forType: ClipboardHistoryMonitor.historyMarker) }
            return item
        }
    }

    static let imageTypes: Set<String> = ["public.tiff", "public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "public.webp"]
    static let fileTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType"]
    /// Deliberately excludes executable promises and application-private archive formats.
    /// Capture retains supported representations except alternate TIFF when PNG is supplied.
    /// Unsupported-only items reject the capture.
    static let supportedTypes: Set<String> = imageTypes.union(fileTypes).union([
        "public.utf8-plain-text", "public.utf16-plain-text", "NSStringPboardType",
        "public.rtf", "com.apple.flat-rtfd", "public.html", "com.adobe.pdf", "public.url",
        "NSRTFPboardType", "NSRTFDPboardType", "NSHTMLPboardType", "NSTIFFPboardType",
        "NSPDFPboardType", "NSURLPboardType"
    ])
}
