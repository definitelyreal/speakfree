// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// `speakfree compat scan`: run the app-compatibility detection rules over every installed app
// and print what each one would get. Read-only: it reads Info.plist files and folder listings,
// launches nothing, and writes nothing. It exists so the rules can be checked against a real
// Mac instead of against the apps someone remembered to list.

import Foundation

public struct AppScanRow: Equatable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let appClass: AppClass
    public let reason: String
    /// Route for a single line of text with no per-app setting.
    public let route: String
    /// Route for text with a line break, when it differs.
    public let multiLineRoute: String?
}

public enum AppCompatScan {

    /// Where apps live on a stock Mac. Each folder is also searched one level down, which
    /// covers /Applications/Utilities and vendor folders such as /Applications/Microsoft Office.
    public static var defaultFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
    }

    /// Every `.app` bundle directly in `folder` or one folder below it (not inside other apps).
    static func appBundles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for entry in top {
            if entry.pathExtension == "app" {
                found.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let inner = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) {
                found.append(contentsOf: inner.filter { $0.pathExtension == "app" })
            }
        }
        return found
    }

    /// Plain-English name of a route, for the scan table and the problem window.
    static func describe(_ route: InsertionRoute) -> String {
        switch route {
        case .accessibilityChain: return "Accessibility"
        case .paste: return "Paste"
        case .keystrokes: return "Type"
        case .remoteKeystroke: return "Remote keystrokes"
        case .remotePaste: return "Remote paste"
        }
    }

    /// Classify one bundle on disk. Nil when it has no readable bundle ID.
    public static func row(for bundleURL: URL) -> AppScanRow? {
        guard let info = AppCompatibility.infoDictionary(at: bundleURL),
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let classification = AppCompatibility.classify(bundleID: bundleID, bundleURL: bundleURL)
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let unsafe = AppCompatibility.typedLineBreaksUnsafe(appClass: classification.appClass, bundleID: bundleID,
                                                            hasTerminalPane: classification.hasTerminalPane)
        let single = AppCompatibility.route(for: classification.appClass, override: .automatic,
                                            textHasLineBreak: false, lineBreaksUnsafe: unsafe)
        let multi = AppCompatibility.route(for: classification.appClass, override: .automatic,
                                           textHasLineBreak: true, lineBreaksUnsafe: unsafe)
        return AppScanRow(bundleID: bundleID, name: name, path: bundleURL.path,
                          appClass: classification.appClass, reason: classification.reason,
                          route: describe(single),
                          multiLineRoute: multi == single ? nil : describe(multi))
    }

    /// Scan the folders, one row per bundle ID (first path wins), sorted by class then name.
    public static func scan(folders: [URL] = defaultFolders) -> [AppScanRow] {
        var seen = Set<String>()
        var rows: [AppScanRow] = []
        for folder in folders {
            for bundle in appBundles(in: folder).sorted(by: { $0.path < $1.path }) {
                guard let row = row(for: bundle), seen.insert(row.bundleID.lowercased()).inserted else { continue }
                rows.append(row)
            }
        }
        return rows.sorted {
            $0.appClass.rawValue == $1.appClass.rawValue
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.appClass.rawValue < $1.appClass.rawValue
        }
    }

    /// Markdown table plus per-class counts.
    public static func renderMarkdown(_ rows: [AppScanRow]) -> String {
        var counts: [AppClass: Int] = [:]
        for row in rows { counts[row.appClass, default: 0] += 1 }
        var lines = ["\(rows.count) apps scanned.", ""]
        for (appClass, count) in counts.sorted(by: { $0.value > $1.value }) {
            lines.append("- \(appClass.label): \(count)")
        }
        lines.append("")
        lines.append("| App | Bundle ID | Detected | Why | Route |")
        lines.append("|---|---|---|---|---|")
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        for row in rows {
            let route = row.multiLineRoute.map { "\(row.route) (line breaks: \($0))" } ?? row.route
            lines.append("| \(cell(row.name)) | \(cell(row.bundleID)) | \(row.appClass.label) | \(cell(row.reason)) | \(route) |")
        }
        return lines.joined(separator: "\n")
    }

    /// Tab-separated, one app per line, for grep and sort.
    public static func renderTSV(_ rows: [AppScanRow]) -> String {
        rows.map { [$0.bundleID, $0.name, $0.appClass.rawValue, $0.route, $0.multiLineRoute ?? "", $0.reason]
            .joined(separator: "\t") }.joined(separator: "\n")
    }
}
