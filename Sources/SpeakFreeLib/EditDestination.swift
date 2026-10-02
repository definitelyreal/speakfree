// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import Foundation

/// Where an edit session's text goes on Return, and whether it may be typed there.
///
/// The design review names insertion into the wrong conversation or document as the single biggest
/// risk: capturing an app, window and field does not prove the field still holds the original
/// conversation, and a header saying "→ Slack" would not reveal the mistake. The containment is
/// to extend the existing fallback: whenever the original destination cannot be established, the
/// text is COPIED and the draft is KEPT in the window instead of being typed anywhere.
///
/// This file is the pure decision. The AppKit side (EditSessionController) gathers the facts
/// (who is frontmost after activation, whether the focused window and field are the captured
/// ones, Secure Input) and asks `verdict`.
public struct EditTargetIdentity: Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let appName: String
    /// A title for the captured window when Accessibility exposed one (shown in the header).
    public let windowTitle: String?
    /// True when an AX focused window and focused field were captured at session open.
    public let hasWindow: Bool
    public let hasField: Bool

    public init(pid: Int32, bundleID: String?, appName: String, windowTitle: String?,
                hasWindow: Bool, hasField: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.hasWindow = hasWindow
        self.hasField = hasField
    }
}

/// What was observed immediately before insertion, after the captured app was re-activated.
public struct EditTargetObservation: Equatable {
    public let targetStillRunning: Bool
    public let frontmostPID: Int32?
    /// nil = could not be read; true/false = compared with CFEqual against the captured element.
    public let sameWindow: Bool?
    /// nil = no title now or at capture; true/false = the focused window's title compared with
    /// the captured title. In Slack, Claude and browsers the title names the conversation, channel
    /// or tab, so a changed title means "same app, different place".
    public let sameTitle: Bool?
    public let sameField: Bool?
    public let secureInputActive: Bool
    public let activationTimedOut: Bool

    public init(targetStillRunning: Bool, frontmostPID: Int32?, sameWindow: Bool?,
                sameTitle: Bool? = nil, sameField: Bool?,
                secureInputActive: Bool, activationTimedOut: Bool) {
        self.targetStillRunning = targetStillRunning
        self.frontmostPID = frontmostPID
        self.sameWindow = sameWindow
        self.sameTitle = sameTitle
        self.sameField = sameField
        self.secureInputActive = secureInputActive
        self.activationTimedOut = activationTimedOut
    }
}

public enum EditRetainReason: String, Equatable, Codable {
    case noTarget            // nothing usable was frontmost when the session opened
    case terminal            // Terminal-class apps are copy-only in V1 (a Return there runs a command)
    case remoteDesktop       // the real field is on another computer and cannot be checked
    case targetQuit          // the original app is no longer running
    case activationTimedOut  // the original app did not come to the front in time
    case differentApp        // something else is frontmost
    case differentWindow     // same app, different window (another document or conversation)
    case differentField      // same window, focus is in a different field
    case unknownField        // the original field could not be confirmed
    case conversationUnknown // the app's window title does not say which conversation is open
    case secureInput         // a password field has Secure Input on
    case insertionUncertain  // the insert path could not confirm the text landed

    /// Footer sentence, completed by "Your text is copied and still here."
    public var explanation: String {
        switch self {
        case .noTarget: return "No text field was active when this session started."
        case .terminal: return "Edit Mode does not type into Terminal windows."
        case .remoteDesktop: return "The remote computer's field cannot be checked from here."
        case .targetQuit: return "The app you started in has quit."
        case .activationTimedOut: return "The app you started in did not come back to the front."
        case .differentApp: return "A different app is in front."
        case .differentWindow: return "The original window is no longer the one in front."
        case .differentField: return "The cursor is in a different field than where you started."
        case .unknownField: return "The original text field could not be confirmed."
        case .conversationUnknown:
            return "This app does not show which conversation is open, so Edit Mode cannot confirm it is the same one."
        case .secureInput: return "A password field is blocking typing."
        case .insertionUncertain: return "It could not be confirmed that the text landed."
        }
    }
}

public enum EditDestinationVerdict: Equatable {
    case insert
    case retain(EditRetainReason)
}

public enum EditDestination {

    /// Terminal-class apps: typing a multi-paragraph draft there could run commands. Copy-only in
    /// V1. VS Code is an editor and is NOT on this list; its integrated terminal cannot be told
    /// apart through Accessibility, which the field check below covers only partially.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.mitchellh.ghostty",
        "co.zeit.hyper", "org.tabby", "com.github.wez.wezterm",
    ]

    /// Checks that need only the identity captured at session open (run before touching focus).
    public static func precheck(_ target: EditTargetIdentity?, isRemoteDesktop: Bool) -> EditDestinationVerdict {
        guard let target = target else { return .retain(.noTarget) }
        if let b = target.bundleID, terminalBundleIDs.contains(b) { return .retain(.terminal) }
        if isRemoteDesktop { return .retain(.remoteDesktop) }
        // Without at least the window, "the same place" cannot be established at all.
        if !target.hasWindow { return .retain(.unknownField) }
        // Without a captured field, the window title is the only thing that tells one
        // conversation, channel or document from another, and only some apps put that in the
        // title. Elsewhere (a fixed title such as "Claude" or "Zoom Workplace", or no title) the
        // draft is copied instead of typed.
        if !target.hasField
            && !(titleNamesThePlace(target) && appTitlesNameThePlace(target.bundleID)) {
            return .retain(.conversationUnknown)
        }
        return .insert
    }

    /// Apps without a readable text field whose window title changes with the channel,
    /// conversation or document in front. Any app not listed is copy-only when its field cannot
    /// be captured. Kept short on purpose: a wrong entry here is the one way a draft could be
    /// typed into the wrong conversation.
    public static let titleNamesPlaceBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",          // Slack: channel or DM name in the title
        "com.hnc.Discord",                    // Discord: channel name
        "com.microsoft.VSCode",               // VS Code: file name
        "com.todesktop.230313mzl4w4u92",      // Cursor: file name
        "md.obsidian",                        // Obsidian: note name
        "notion.id",                          // Notion: page name
    ]

    public static func appTitlesNameThePlace(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return titleNamesPlaceBundleIDs.contains(b)
    }

    /// True when the captured title says more than the app's name.
    public static func titleNamesThePlace(_ target: EditTargetIdentity) -> Bool {
        guard let title = target.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return false }
        return title.caseInsensitiveCompare(target.appName) != .orderedSame
    }

    /// The full verdict, after re-activating the captured app. Every uncertainty retains.
    ///
    /// The window must be the captured window (CFEqual) and, when a title was captured, still
    /// carry the same title. The field must be the captured field when one was captured.
    /// Capturing an AX element identity does not read or write its text. If no field is
    /// available, only the explicit title-capable app list may use window/title matching.
    public static func verdict(target: EditTargetIdentity?, isRemoteDesktop: Bool,
                               observed: EditTargetObservation) -> EditDestinationVerdict {
        let pre = precheck(target, isRemoteDesktop: isRemoteDesktop)
        guard pre == .insert, let target = target else { return pre }
        if !observed.targetStillRunning { return .retain(.targetQuit) }
        if observed.activationTimedOut { return .retain(.activationTimedOut) }
        guard observed.frontmostPID == target.pid else { return .retain(.differentApp) }
        switch observed.sameWindow {
        case .some(false): return .retain(.differentWindow)
        case .none: return .retain(.unknownField)
        case .some(true): break
        }
        if target.windowTitle != nil {
            switch observed.sameTitle {
            case .some(false): return .retain(.differentWindow)
            case .none: return .retain(.unknownField)
            case .some(true): break
            }
        }
        if target.hasField {
            switch observed.sameField {
            case .some(false): return .retain(.differentField)
            case .none: return .retain(.unknownField)
            case .some(true): break
            }
        }
        if observed.secureInputActive { return .retain(.secureInput) }
        return .insert
    }
}
