// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// App compatibility: how speakfree decides which insertion method a target app gets.
//
// Goal (2026-09-24): better app discovery for people whose computers were never tested,
// including terminals, agent TUIs and remote desktop apps the maintainers do not own.
//
// Before this file, routing was keyed on hand-written bundle-ID lists of apps already tested. This
// file keeps those lists (so nothing already handled changes) and adds capability detection that
// works for apps nobody has listed:
//
//   - Embedded web runtimes, found by the frameworks the bundle ships (Electron, CEF, NW.js,
//     Qt WebEngine), not by the app's name.
//   - Browsers, found by claiming the http/https URL schemes in Info.plist.
//   - Remote desktop and VNC viewers, found by claiming vnc/rdp-style URL schemes.
//   - Terminals, found by known IDs plus claiming ssh/telnet URL schemes.
//
// A per-app user override (Automatic / Type / Paste / Accessibility) sits on top, so a stranger
// can fix an unknown app from Settings without a code change.

import Foundation

/// The user's per-app insertion choice. Stored in config.json as a string; unknown strings
/// decode as `.automatic` so a newer config never breaks an older build.
public enum InsertionMethod: String, Codable, CaseIterable, Identifiable {
    case automatic
    case type
    case paste
    case accessibility

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = InsertionMethod(rawValue: raw.lowercased()) ?? .automatic
    }

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .type: return "Type"
        case .paste: return "Paste"
        case .accessibility: return "Accessibility"
        }
    }

    public var detail: String {
        switch self {
        case .automatic: return "speakfree picks the method for this kind of app."
        case .type: return "Sends the text as typed characters. Line breaks are pasted instead of typed in terminals and apps that may contain one."
        case .paste: return "Puts the text on the clipboard, presses ⌘V, then restores your clipboard."
        case .accessibility: return "Writes straight into the text field and checks that it landed. If that is not possible, types single lines and pastes the rest."
        }
    }
}

/// The per-app override map as stored in config.json. Decoding never throws: a hand-edited
/// value of the wrong shape (an array, a string) becomes an empty map instead of failing the
/// whole config decode, which would reset every other setting to defaults.
public struct InsertionOverrideMap: Codable, Equatable, ExpressibleByDictionaryLiteral {
    public var values: [String: InsertionMethod]
    /// Entries whose method this build does not know (written by a newer build). Kept as-is
    /// and written back, so opening Settings in an older build never deletes them.
    public var unknown: [String: String] = [:]

    public init(_ values: [String: InsertionMethod], unknown: [String: String] = [:]) {
        self.values = values
        self.unknown = unknown
    }

    public init(dictionaryLiteral elements: (String, InsertionMethod)...) {
        values = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    public subscript(key: String) -> InsertionMethod? { values[key] }

    public init(from decoder: Decoder) throws {
        values = [:]
        guard let raw = try? decoder.singleValueContainer().decode([String: LenientString].self) else { return }
        for (key, entry) in raw {
            guard let string = entry.value else { continue }
            if let method = InsertionMethod(rawValue: string.lowercased()) {
                values[key] = method
            } else {
                unknown[key] = string
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var merged: [String: String] = [:]
        let known = Set(values.keys.map { $0.lowercased() })
        for (key, value) in unknown where !known.contains(key.lowercased()) { merged[key] = value }
        for (key, method) in values { merged[key] = method.rawValue }
        var container = encoder.singleValueContainer()
        try container.encode(merged)
    }

    /// Decodes any JSON value; only strings are kept.
    private struct LenientString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }
}

/// What kind of app is in front, as far as insertion is concerned.
public enum AppClass: String, Equatable {
    /// A regular Cocoa/AppKit/SwiftUI app. Accessibility insertion first.
    case native
    /// A web browser. Web text fields accept an AX write and apply nothing, so paste.
    case browser
    /// An app that embeds a Chromium runtime (Electron, CEF, NW.js, or a renamed Chromium
    /// framework). Paste.
    case webRuntime
    /// A known app routed to paste for a reason other than its runtime (hand-maintained list).
    case listedPaste
    /// A terminal emulator. Paste: programs that enable bracketed paste (zsh, bash 5.1+, Claude
    /// Code, Codex) keep pasted line breaks as text, where a typed line break would be Return.
    /// (A trailing line break is dropped in every app, so a program without bracketed paste
    /// never receives one that would run the line.)
    case terminal
    /// A native editor with a built-in terminal pane (Zed, JetBrains IDEs, Nova). speakfree
    /// cannot tell which pane has focus, and a typed line break in the terminal pane is a
    /// Return, so paste. The editor's own cursor context stays trusted.
    case terminalHost
    /// A remote desktop, VNC viewer, or VM console. Keystrokes go to another computer.
    case remoteDesktop

    public var label: String {
        switch self {
        case .native: return "Native app"
        case .browser: return "Browser"
        case .webRuntime: return "Web-based app"
        case .listedPaste: return "Known paste app"
        case .terminal: return "Terminal"
        case .terminalHost: return "Editor with a terminal"
        case .remoteDesktop: return "Remote desktop"
        }
    }

    /// Classes whose live AX cursor context is not trustworthy (a web contenteditable, or a
    /// terminal whose AX value is the whole scrollback). Used to skip the prepend-space probe
    /// and the live cursor-context read, exactly as Electron apps already were.
    var cursorContextUntrusted: Bool {
        switch self {
        case .webRuntime, .listedPaste, .terminal: return true
        case .native, .browser, .terminalHost, .remoteDesktop: return false
        }
    }
}

/// The classification plus a short, human-readable reason (for logs and the compatibility report).
public struct AppClassification: Equatable {
    public let appClass: AppClass
    public let reason: String
    /// The bundle ships a terminal library (node-pty, xterm.js), so one of its panes may be a
    /// shell even though the app itself is not a terminal (VS Code forks, agent workbenches,
    /// Claude and ChatGPT desktop). Found by `speakfree compat scan`, 2026-09-24.
    public let hasTerminalPane: Bool

    public init(appClass: AppClass, reason: String, hasTerminalPane: Bool = false) {
        self.appClass = appClass
        self.reason = reason
        self.hasTerminalPane = hasTerminalPane
    }
}

/// The concrete path `TextInserter` takes for one insertion.
enum InsertionRoute: String, Equatable {
    /// Remote viewer: System Events keystrokes to the viewer process (multi-line uses paste).
    case remoteKeystroke
    /// Remote viewer: clipboard plus a System Events ⌘V, waiting for clipboard sync.
    case remotePaste
    /// Local clipboard paste with restore.
    case paste
    /// Local synthetic Unicode key events, falling back to paste.
    case keystrokes
    /// AX write with read-back verify, then keystrokes, then paste (the native chain).
    case accessibilityChain
}

enum AppCompatibility {

    // MARK: - Known lists (kept so every app already handled keeps its route)

    /// Remote desktop viewers and VM consoles that forward raw key codes, so a synthetic
    /// Unicode event (virtual key 0) arrives on the other side as the letter "a".
    static let remoteDesktopBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",          // macOS Screen Sharing (raw key 0 becomes "a")
        "com.splashtop.stp.macosx",          // Splashtop Personal
        "com.splashtop.Splashtop-Streamer",  // Splashtop Streamer
        "com.splashtop.PersonalBusiness",    // Splashtop Business
        "com.splashtop.streamer",
        "com.microsoft.rdc.macos",           // Microsoft Windows App / Remote Desktop
        "com.microsoft.rdc.osx",
        "com.teamviewer.TeamViewer",         // TeamViewer
        "com.parallels.desktop.console",     // Parallels
        "com.vmware.fusion",                 // VMware Fusion
        "com.realvnc.vncviewer",             // RealVNC
        "com.citrix.receiver.icaviewer",     // Citrix session viewer (not the launcher)
        "com.citrix.receiver.icaviewer.mac",
        "com.parsec-cloud.parsec",           // Parsec (older id)
        "com.moonlight-stream.Moonlight",    // Moonlight
        // Added 2026-09-24 (app-compat): viewers the maintainer does not own.
        "com.p5sys.jump.mac.viewer",         // Jump Desktop
        "com.p5sys.jump.mac.viewer.web",     // Jump Desktop (direct download)
        "com.edovia.screens.mac",            // Screens 4
        "com.edovia.screens5.mac",           // Screens 5
        "com.edovia.screens",                // Screens (other builds)
        "com.philandro.anydesk",             // AnyDesk
        "com.carriez.rustdesk",              // RustDesk
        "com.nomachine.nxplayer",            // NoMachine
        "com.nomachine.nxclient",
        "com.amazon.workspaces",             // Amazon WorkSpaces
        "com.teradici.pcoip-client",         // HP Anyware (Teradici PCoIP)
        "com.teradici.swiftclient",          // HP Anyware (older client)
        "tv.parsec.www",                     // Parsec (current id)
        "com.utmapp.UTM",                    // UTM virtual machines
        "org.virtualbox.app.VirtualBoxVM",   // VirtualBox VM window
        // Added 2026-09-24 (compat scan): forwards keys to the phone and ships no library or
        // URL scheme a rule could find. Not yet hand-tested.
        "com.apple.ScreenContinuity",        // iPhone Mirroring
    ]

    /// Substrings that mark a remote viewer even under a variant bundle ID.
    static let remoteKeywords = [
        "splashtop", "teamviewer", "parsec", "moonlight", "vnc", "remotedesktop",
        "anydesk", "rustdesk", "nomachine", "teradici", "pcoip",
    ]

    /// URL schemes that only a remote desktop or VNC viewer claims. An unknown viewer that
    /// registers one of these is caught without anyone listing it.
    /// Deliberately limited to names no ordinary local app would register (review 2026-09-24:
    /// common words like "receiver", "screens" or "jump" were dropped).
    static let remoteURLSchemes: Set<String> = [
        "vnc", "rdp", "ms-rd", "anydesk", "rustdesk", "teamviewer8", "teamviewerapi",
        "splashtop", "citrixreceiver", "pcoip",
        "hoptodesk",  // HopToDesk (a RustDesk fork)
    ]

    /// Libraries that only a remote desktop client ships: FreeRDP (and its WinPR runtime) and
    /// LibVNCClient. Matched case-insensitively as substrings of the names in
    /// Contents/Frameworks. Catches FreeRDP-based clients that register no rdp:// scheme, which
    /// the compat scan (2026-09-24) showed are common.
    static let remoteLibraryMarkers = ["freerdp", "libwinpr", "libvncclient"]

    /// Terminal emulators. Their text view is not an editable field (AX), and a typed line
    /// break is a Return that runs a command or submits a prompt.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty",
        "org.tabby",
        "co.zeit.hyper",
        "com.termius-dmg.mac", "com.termius.mac",
        "com.panic.Prompt3", "com.panic.prompt",
        "com.raphaelamorim.rio",
    ]

    static let terminalKeywords = ["iterm", "ghostty", "wezterm", "alacritty", "terminal"]

    /// URL schemes that terminals register. Remote-desktop managers that also claim ssh are
    /// caught earlier by the remote schemes, so this only fires for terminal-like apps.
    static let terminalURLSchemes: Set<String> = ["ssh", "telnet", "x-man-page"]

    /// Browser URL schemes. Only browsers (and browser pickers, which never hold a text field)
    /// register themselves for http/https.
    static let browserURLSchemes: Set<String> = ["http", "https"]

    /// Known browsers, kept for builds whose Info.plist is unreadable.
    static let browserBundleIDPrefixes = [
        "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
        "company.thebrowser.browser",  // Arc
        "company.thebrowser.dia",      // Dia
        "com.brave.browser", "com.microsoft.edgemac",
        "com.operasoftware.opera", "com.vivaldi.vivaldi",
        "com.kagi.kagimacos",          // Orion
        "app.zen-browser.zen",
    ]

    /// Frameworks that mean "this app's text fields are web contenteditables". Qt WebEngine is
    /// deliberately absent: Qt apps ship it for side panels while their text fields are native
    /// Qt widgets.
    static let webRuntimeFrameworks = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
        "nwjs Framework.framework",
    ]

    /// A resource every Chromium build ships inside its framework. Finding it catches renamed
    /// Chromium frameworks (ChatGPT's "Codex Framework", every Chromium browser's
    /// "<Name> Framework") that the name list above cannot know about.
    static let chromiumMarkerResource = "chrome_100_percent.pak"

    /// Native editors with a built-in terminal pane (see `AppClass.terminalHost`).
    static let terminalHostBundleIDs: Set<String> = [
        "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.panic.Nova",
        "com.google.android.studio",
    ]
    static let terminalHostPrefixes = ["com.jetbrains."]

    /// Explicit paste apps (Electron apps listed before the framework probe existed, plus
    /// non-Chromium special cases). Case-insensitive.
    static let listedPasteBundleIDs: Set<String> = [
        "org.whispersystems.signal-desktop",   // Signal
        "com.tinyspeck.slackmacgap",           // Slack
        "com.microsoft.VSCode",                // VS Code
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",       // Cursor
        "com.exafunction.windsurf",            // Windsurf
        "com.hnc.Discord",                     // Discord
        "com.hnc.Discord.ptb",
        "com.hnc.Discord.canary",
        "notion.id",                           // Notion
        "com.linear",                          // Linear
        "com.figma.Desktop",                   // Figma
        "com.spotify.client",                  // Spotify
        "com.github.GitHubClient",             // GitHub Desktop
        "com.1password.1password",             // 1Password
        "md.obsidian",                         // Obsidian
        "com.superhuman.superhuman",           // Superhuman
        "com.microsoft.teams2",                // Teams
        "us.zoom.xos",                         // Zoom (chat)
        "com.loom.desktop",                    // Loom
        "com.openai.codex",                    // Codex/ChatGPT desktop contenteditable
        "com.openai.chat",                     // ChatGPT Classic
        // Claude for Desktop (2026-07-28). Electron, and its composer accepts
        // kAXSelectedText as SETTABLE, so an AX write reported success and the text never
        // appeared.
        "com.anthropic.claudefordesktop",      // Claude
    ]

    /// Apps that copy the Mac clipboard to another machine the moment it changes (VMs with
    /// shared clipboard, software KVMs). While one runs, it may read speakfree's dictated text
    /// BEFORE the app the user is dictating into, so that first read is not proof the target has
    /// pasted: the fast clipboard restore is turned off and the backstop timer is used instead.
    /// Remote desktop viewers count too (`isClipboardSyncer`), except the ones known to fetch
    /// clipboard DATA only when the remote side pastes (`lazyClipboardRemoteViewer`).
    static let clipboardSyncerBundleIDs: Set<String> = [
        "com.parallels.desktop.console",     // Parallels Desktop
        "com.vmware.fusion",                 // VMware Fusion
        "com.utmapp.UTM",                    // UTM
        "org.virtualbox.app.VirtualBox",     // VirtualBox manager
        "org.virtualbox.app.VirtualBoxVM",   // VirtualBox VM window
        "com.symless.synergy",               // Synergy
        "com.symless.synergy3",
        "barrier",                           // Barrier (bundle id as shipped)
        "com.github.debauchee.barrier",
        "org.deskflow.deskflow",             // Deskflow
        "io.github.input-leap.input-leap",   // Input Leap
        "com.bartelsmedia.ShareMouse",       // ShareMouse
    ]

    static func isClipboardSyncer(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if matches(clipboardSyncerBundleIDs, bundleID) { return true }
        return isRemoteDesktop(bundleID: bundleID) && !lazyClipboardRemoteViewer(bundleID: bundleID)
    }

    /// Remote viewers that do not read the Mac clipboard's data eagerly:
    ///   - Microsoft Windows App / Remote Desktop: RDP announces the list of TYPES when the
    ///     clipboard changes and requests the data only when the remote side pastes (MS-RDPECLIP).
    ///     A types-only read does not call speakfree's provider (measured 2026-09-24).
    ///   - Splashtop Personal (the viewer, `com.splashtop.stp.macosx` only): measured 2026-09-24
    ///     with a session window open: 0 of 13 host-only dictation writes were read without a
    ///     paste. Splashtop Streamer (which serves this Mac's clipboard to someone connected IN)
    ///     and other Splashtop builds are unmeasured and stay on the backstop.
    /// Every other viewer (Screen Sharing, Jump, AnyDesk, Parsec, VNC, ...) is unmeasured, so
    /// while one runs the backstop decides.
    static func lazyClipboardRemoteViewer(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return lower == "com.splashtop.stp.macosx" || lower.hasPrefix("com.microsoft.rdc.")
    }

    /// Bundle ID of the first running clipboard syncer, or nil. Reads the process list only.
    static func runningClipboardSyncer(runningBundleIDs: [String?]) -> String? {
        runningBundleIDs.lazy.compactMap { $0 }.first { isClipboardSyncer(bundleID: $0) }
    }

    // MARK: - Pure classification

    static func matches(_ set: Set<String>, _ bundleID: String) -> Bool {
        set.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Bundle-ID-only remote check (no filesystem): the exact list plus keyword match.
    static func isRemoteDesktop(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if matches(remoteDesktopBundleIDs, bundleID) { return true }
        let lower = bundleID.lowercased()
        return remoteKeywords.contains { lower.contains($0) }
    }

    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if matches(terminalBundleIDs, bundleID) { return true }
        let lower = bundleID.lowercased()
        return terminalKeywords.contains { lower.contains($0) }
    }

    static func isListedPaste(bundleID: String) -> Bool {
        matches(listedPasteBundleIDs, bundleID) || bundleID.lowercased().contains("superhuman")
    }

    static func isKnownBrowser(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return browserBundleIDPrefixes.contains { lower.contains($0) }
    }

    /// Every URL scheme an Info.plist claims, lowercased. Tolerates malformed entries (a
    /// real app on the test Mac ships a bare string inside CFBundleURLTypes).
    static func urlSchemes(infoDictionary info: [String: Any]?) -> Set<String> {
        guard let types = info?["CFBundleURLTypes"] as? [Any] else { return [] }
        var schemes = Set<String>()
        for case let entry as [String: Any] in types {
            for case let scheme as String in (entry["CFBundleURLSchemes"] as? [Any]) ?? [] {
                schemes.insert(scheme.lowercased())
            }
        }
        return schemes
    }

    /// Does the app say it opens HTML documents? Browsers do; apps that merely claim http
    /// links (Cyberduck, VLC, mpv) do not.
    static func opensHTMLDocuments(infoDictionary info: [String: Any]?) -> Bool {
        guard let types = info?["CFBundleDocumentTypes"] as? [Any] else { return false }
        for case let entry as [String: Any] in types {
            let utis = (entry["LSItemContentTypes"] as? [Any])?.compactMap { $0 as? String } ?? []
            let exts = (entry["CFBundleTypeExtensions"] as? [Any])?.compactMap { $0 as? String } ?? []
            if utis.contains(where: { $0.lowercased() == "public.html" })
                || exts.contains(where: { ["html", "htm"].contains($0.lowercased()) }) {
                return true
            }
        }
        return false
    }

    static func isTerminalHost(bundleID: String) -> Bool {
        if matches(terminalHostBundleIDs, bundleID) { return true }
        let lower = bundleID.lowercased()
        return terminalHostPrefixes.contains { lower.hasPrefix($0) }
    }

    /// Pure classifier. `info` is the app's Info.plist (nil when unreadable), `frameworks` the
    /// names in Contents/Frameworks (nil when unreadable), and `chromiumFrameworks` the subset
    /// that carries the Chromium marker resource. Order matters: a remote viewer that embeds
    /// Electron is still a remote viewer, a terminal built on Electron (Hyper, Tabby) is still a
    /// terminal, and a Chromium browser is labelled a browser rather than a web runtime.
    static func classify(bundleID: String?,
                         info: [String: Any]?,
                         frameworks: Set<String>?,
                         chromiumFrameworks: Set<String>? = nil,
                         terminalLibrary: String? = nil) -> AppClassification {
        let base = classifyClass(bundleID: bundleID, info: info, frameworks: frameworks,
                                 chromiumFrameworks: chromiumFrameworks)
        // Terminals, editors with terminal panes and remote viewers already get the safe
        // line-break handling from their class; the flag matters for everything else.
        guard let terminalLibrary, [.webRuntime, .listedPaste, .native, .browser].contains(base.appClass) else {
            return base
        }
        return AppClassification(appClass: base.appClass,
                                 reason: base.reason + "; has a terminal pane (ships \(terminalLibrary))",
                                 hasTerminalPane: true)
    }

    private static func classifyClass(bundleID: String?,
                                      info: [String: Any]?,
                                      frameworks: Set<String>?,
                                      chromiumFrameworks: Set<String>?) -> AppClassification {
        guard let bundleID, !bundleID.isEmpty else {
            return AppClassification(appClass: .native, reason: "no bundle id")
        }
        let schemes = urlSchemes(infoDictionary: info)

        if matches(remoteDesktopBundleIDs, bundleID) {
            return AppClassification(appClass: .remoteDesktop, reason: "known remote viewer")
        }
        let lower = bundleID.lowercased()
        if let keyword = remoteKeywords.first(where: { lower.contains($0) }) {
            return AppClassification(appClass: .remoteDesktop, reason: "bundle id contains \"\(keyword)\"")
        }
        if let scheme = schemes.sorted().first(where: { remoteURLSchemes.contains($0) }) {
            return AppClassification(appClass: .remoteDesktop, reason: "handles \(scheme):// links")
        }
        if matches(terminalBundleIDs, bundleID) {
            return AppClassification(appClass: .terminal, reason: "known terminal")
        }
        if let keyword = terminalKeywords.first(where: { lower.contains($0) }) {
            return AppClassification(appClass: .terminal, reason: "bundle id contains \"\(keyword)\"")
        }
        // After the named terminals (a terminal that also bundles FreeRDP stays a terminal), but
        // before the ssh:// rule, so a connection manager that opens both ssh and RDP sessions
        // is treated as a remote viewer: its RDP windows forward key codes.
        if let library = frameworks?.sorted().first(where: { name in
            remoteLibraryMarkers.contains { name.lowercased().contains($0) }
        }) {
            return AppClassification(appClass: .remoteDesktop, reason: "ships a remote desktop library (\(library))")
        }
        if let scheme = schemes.sorted().first(where: { terminalURLSchemes.contains($0) }) {
            return AppClassification(appClass: .terminal, reason: "handles \(scheme):// links")
        }

        if isTerminalHost(bundleID: bundleID) {
            return AppClassification(appClass: .terminalHost, reason: "editor with a built-in terminal")
        }
        if isListedPaste(bundleID: bundleID) {
            return AppClassification(appClass: .listedPaste, reason: "known paste app")
        }

        if isKnownBrowser(bundleID: bundleID) {
            // Chrome and Brave "install as app" shims (com.google.Chrome.app.<id>) are one web
            // page in their own window: same route, clearer label in the scan and the report.
            let shim = lower.contains(".app.")
            return AppClassification(appClass: .browser,
                                     reason: shim ? "web app installed from a browser" : "known browser")
        }
        if !schemes.isDisjoint(with: browserURLSchemes) && opensHTMLDocuments(infoDictionary: info) {
            return AppClassification(appClass: .browser, reason: "opens web links and HTML files")
        }

        if let frameworks,
           let runtime = webRuntimeFrameworks.first(where: { frameworks.contains($0) }) {
            let name = runtime.replacingOccurrences(of: ".framework", with: "")
            return AppClassification(appClass: .webRuntime, reason: "ships \(name)")
        }
        if let chromium = chromiumFrameworks?.sorted().first {
            let name = chromium.replacingOccurrences(of: ".framework", with: "")
            return AppClassification(appClass: .webRuntime, reason: "ships Chromium (\(name))")
        }

        return AppClassification(appClass: .native, reason: "no special handling detected")
    }

    // MARK: - Filesystem probe (cached)

    private static var cache: [String: AppClassification] = [:]
    private static let cacheLock = NSLock()

    static func resetCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    /// Info.plist of the bundle at `url`, or nil if it cannot be read.
    static func infoDictionary(at url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    static func frameworkNames(at url: URL) -> Set<String>? {
        let dir = url.appendingPathComponent("Contents/Frameworks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        return Set(names)
    }

    /// The frameworks in `names` that carry Chromium's marker resource.
    static func chromiumFrameworkNames(at url: URL, among names: Set<String>) -> Set<String> {
        let dir = url.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        return names.filter { name in
            // Chromium and Electron name their framework "<Product> Framework.framework".
            // Requiring that shape keeps apps that bundle CEF for a side panel under another
            // name (DaVinci Resolve's Qt editor) on their native route.
            guard name.hasSuffix(" Framework.framework") else { return false }
            let framework = dir.appendingPathComponent(name)
            return fm.fileExists(atPath: framework.appendingPathComponent("Resources/\(chromiumMarkerResource)").path)
                || fm.fileExists(atPath: framework.appendingPathComponent("Versions/Current/Resources/\(chromiumMarkerResource)").path)
        }
    }

    /// Where Electron apps keep native Node modules. node-pty lives here whenever an app has a
    /// real shell pane (it cannot run from inside app.asar); xterm.js appears here when the app
    /// ships unbundled node_modules (VS Code and its forks).
    static let nodeModuleFolders = [
        "Contents/Resources/app/node_modules",
        "Contents/Resources/app/node_modules.asar.unpacked",
        "Contents/Resources/app.asar.unpacked/node_modules",
    ]

    /// Is this node_modules entry a terminal library? `node-pty` and its prebuilt forks, and
    /// xterm.js (`xterm`, `@xterm`).
    static func isTerminalModule(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("node-pty") || lower == "xterm" || lower == "@xterm"
    }

    /// The first terminal library the bundle ships, or nil. A handful of directory listings;
    /// scoped folders (`@scope/`) are looked into one level, which catches forks such as
    /// `@lydell/node-pty-darwin-arm64`.
    static func terminalLibrary(at url: URL) -> String? {
        let fm = FileManager.default
        for folder in nodeModuleFolders {
            let dir = url.appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() {
                if isTerminalModule(name) { return name }
                if name.hasPrefix("@"),
                   let inner = try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(name).path),
                   let hit = inner.sorted().first(where: isTerminalModule) {
                    return name + "/" + hit
                }
            }
        }
        return nil
    }

    /// Classify a live app. The bundle is only trusted when its own Info.plist names the same
    /// bundle ID (so a stale or mismatched URL can never reclassify an app). Cached per bundle
    /// ID, path and Info.plist modification date, so an app updated in place is re-probed; a
    /// probe that could not read the plist is not cached, so a read during an update retries.
    static func classify(bundleID: String?, bundleURL: URL?) -> AppClassification {
        guard let bundleID, !bundleID.isEmpty else {
            return classify(bundleID: nil, info: nil, frameworks: nil)
        }
        var stamp = ""
        if let bundleURL,
           let attrs = try? FileManager.default.attributesOfItem(
               atPath: bundleURL.appendingPathComponent("Contents/Info.plist").path),
           let mtime = attrs[.modificationDate] as? Date {
            stamp = String(mtime.timeIntervalSince1970)
        }
        let key = bundleID.lowercased() + "|" + (bundleURL?.path ?? "") + "|" + stamp
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        var info: [String: Any]?
        var frameworks: Set<String>?
        var chromium: Set<String>?
        var terminal: String?
        if let bundleURL, let dict = infoDictionary(at: bundleURL),
           let plistID = dict["CFBundleIdentifier"] as? String,
           plistID.caseInsensitiveCompare(bundleID) == .orderedSame {
            info = dict
            frameworks = frameworkNames(at: bundleURL)
            chromium = frameworks.map { chromiumFrameworkNames(at: bundleURL, among: $0) }
            terminal = terminalLibrary(at: bundleURL)
        }
        let result = classify(bundleID: bundleID, info: info, frameworks: frameworks,
                              chromiumFrameworks: chromium, terminalLibrary: terminal)

        let probeFailed = bundleURL != nil && info == nil
        if !probeFailed {
            cacheLock.lock()
            cache[key] = result
            cacheLock.unlock()
        }
        return result
    }

    // MARK: - Overrides and routing

    /// Case-insensitive lookup of a user override.
    static func override(for bundleID: String?, in overrides: [String: InsertionMethod]) -> InsertionMethod {
        guard let bundleID, !bundleID.isEmpty else { return .automatic }
        if let exact = overrides[bundleID] { return exact }
        let lower = bundleID.lowercased()
        return overrides.first { $0.key.lowercased() == lower }?.value ?? .automatic
    }

    /// Electron editors on the paste list that have an integrated terminal pane.
    static let integratedTerminalBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",        // Windsurf
        "com.google.antigravity",          // Antigravity (VS Code based)
        "dev.commandline.waveterm",        // Wave terminal (Electron)
    ]

    /// Is it unsafe to TYPE a line break into this app? True for terminals, for editors with a
    /// terminal pane, and for every unlisted web-runtime app (VS Code forks such as VSCodium,
    /// Positron or Kiro, and Electron terminals, all have terminal panes speakfree cannot see
    /// into): a typed Shift+Return reaches a terminal as a plain Return, which runs the command
    /// or submits the prompt. Remote viewers never get Unicode key events at all.
    static func typedLineBreaksUnsafe(appClass: AppClass, bundleID: String?,
                                      hasTerminalPane: Bool = false) -> Bool {
        if hasTerminalPane { return true }
        switch appClass {
        case .terminal, .terminalHost, .webRuntime, .remoteDesktop: return true
        case .native, .browser, .listedPaste: break
        }
        guard let bundleID else { return false }
        return matches(integratedTerminalBundleIDs, bundleID)
    }

    /// The text without its trailing line breaks, which `TextInserter.insert` drops for every
    /// app (2026-09-25). Spaces or tabs mixed into that trailing run go with it ("hi \n" -> "hi");
    /// trailing spaces with no line break after them, and every break in the middle, are kept.
    static func trimmingTrailingLineBreaks(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.endIndex
        var sawLineBreak = false
        while end > scalars.startIndex {
            let previous = scalars.index(before: end)
            switch scalars[previous].value {
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: sawLineBreak = true
            case 0x20, 0x09, 0xA0: break
            default:
                return sawLineBreak ? String(scalars[..<end]) : text
            }
            end = previous
        }
        return sawLineBreak ? "" : text
    }

    /// Pure routing table. Never produces `.keystrokes` for a line break into an app where
    /// typed line breaks are unsafe (see `typedLineBreaksUnsafe`); those paste instead.
    /// `lineBreaksUnsafe` defaults to the class-only answer.
    static func route(for appClass: AppClass,
                      override: InsertionMethod,
                      textHasLineBreak: Bool,
                      lineBreaksUnsafe: Bool? = nil) -> InsertionRoute {
        let unsafe = lineBreaksUnsafe ?? typedLineBreaksUnsafe(appClass: appClass, bundleID: nil)
        switch override {
        case .automatic:
            switch appClass {
            case .remoteDesktop: return .remoteKeystroke
            case .terminal, .terminalHost, .browser, .webRuntime, .listedPaste: return .paste
            case .native: return .accessibilityChain
            }
        case .paste:
            return appClass == .remoteDesktop ? .remotePaste : .paste
        case .type:
            if appClass == .remoteDesktop { return .remoteKeystroke }
            if unsafe && textHasLineBreak { return .paste }
            return .keystrokes
        case .accessibility:
            // Also for a detected remote viewer (a keyword false positive the user knows is
            // local): the chain's typing step refuses remote viewers and its paste uses the
            // remote-safe System Events path, so this can never type "aaa".
            return .accessibilityChain
        }
    }

    /// Clipboard-restore policy for a class: remote and slow consumers get the long backstop.
    static func pasteRestoreRoute(for appClass: AppClass) -> TextInserter.PasteRoute {
        switch appClass {
        case .remoteDesktop: return .remote
        case .terminal, .terminalHost, .browser, .webRuntime, .listedPaste: return .electron
        case .native: return .native
        }
    }

    /// Scalar-level check: "\r\n" is a single Character in Swift, so `contains("\n")` misses it,
    /// while the typing path walks scalars and would type it as Shift+Return.
    static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D }
    }
}
