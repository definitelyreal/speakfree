// Trace output experiment: ai-suggestion:unverified · session:unknown · 2026-10-04
// ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
import ApplicationServices
import Foundation

/// The dictation-trace settings, snapshotted before this take's asynchronous inference starts.
struct TraceSettings {
    let setting: String?
    let apps: [String]?
    let hosts: [String]?
    let testingAvailable: Bool

    init(setting: String?, apps: [String]?, hosts: [String]?,
         testingAvailable: Bool = DictationTrace.testingAvailable) {
        self.setting = setting
        self.apps = apps
        self.hosts = hosts
        self.testingAvailable = testingAvailable
    }

    init(config: Config, testingAvailable: Bool = DictationTrace.testingAvailable) {
        self.init(setting: config.dictationTrace, apps: config.dictationTraceApps,
                  hosts: config.dictationTraceWebHosts, testingAvailable: testingAvailable)
    }

    var isOn: Bool {
        let mode = DictationTrace.OutputMode.resolve(setting)
        return mode != .off && (!mode.testingOnly || testingAvailable)
    }
}

/// A trace ready to append, plus the facts the final gate needs. Built off main after
/// transcription (the AX reads can be slow in browsers); `decide` runs on main at insertion.
struct PendingTrace {
    let settings: TraceSettings
    let payload: DictationTrace.Payload
    let targetBundleID: String?
    let focusedFieldIsSecure: Bool
    let webHost: String?

    /// Capability detection cannot establish safety when the frontmost bundle is unreadable
    /// or no longer matches its process identity. New output experiments fail closed.
    static func experimentalTerminalRisk(_ profile: TextInserter.FrontmostProfile) -> Bool {
        guard let bundleID = profile.bundleID, let bundleURL = profile.bundleURL,
              let info = AppCompatibility.infoDictionary(at: bundleURL),
              let plistID = info["CFBundleIdentifier"] as? String,
              plistID.caseInsensitiveCompare(bundleID) == .orderedSame else { return true }
        return profile.typedLineBreaksUnsafe
    }

    static func prepare(settings: TraceSettings, engine: String, heard: String,
                        unsure: [DictationTrace.WordScore], targetBundleID: String?,
                        element: AXUIElement?) -> PendingTrace? {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isOn, !trimmed.isEmpty else { return nil }
        // Cheap pre-check so no AX work is done for an app that can never get a trace.
        guard let target = targetBundleID, TraceGate.isListed(target, userApps: settings.apps) else {
            return PendingTrace(settings: settings, payload: .make(engine: engine, heard: trimmed, unsure: []),
                                targetBundleID: targetBundleID, focusedFieldIsSecure: false, webHost: nil)
        }
        let payload = DictationTrace.Payload.make(
            engine: engine, heard: trimmed,
            unsure: DictationTrace.unsureWords(unsure, presentIn: trimmed))
        let secure = element.map(TraceAX.isSecureField) ?? false
        let host = TraceGate.needsWebHost(target) ? element.flatMap(TraceAX.webHost) : nil
        return PendingTrace(settings: settings, payload: payload, targetBundleID: targetBundleID,
                            focusedFieldIsSecure: secure, webHost: host)
    }

    func decide(frontmostBundleID: String?, secureInputActive: Bool,
                mayHostTerminal: Bool = false) -> TraceGate.Decision {
        TraceGate.decide(.init(
            setting: settings.setting, userApps: settings.apps, userWebHosts: settings.hosts,
            targetBundleID: targetBundleID, frontmostBundleID: frontmostBundleID,
            secureInputActive: secureInputActive, focusedFieldIsSecure: focusedFieldIsSecure,
            webHost: webHost, testingAvailable: settings.testingAvailable,
            mayHostTerminal: mayHostTerminal))
    }

    /// Fail closed to the finished text, including dot-only mode when any gate rejects the trace.
    func insertionText(_ text: String, decision: TraceGate.Decision) -> String {
        guard case .append(let mode) = decision else { return text }
        return DictationTrace.output(payload, mode: mode, text: text)
    }
}

/// Accessibility reads for the trace gate. Read-only; never changes focus or content.
enum TraceAX {

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// A password field: AXSecureTextField subrole (native and web `<input type=password>`).
    static func isSecureField(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// Host of the web page containing `element`: walk up to the nearest AXWebArea and read
    /// its AXURL. nil when there is none or it cannot be read (the gate then refuses a trace).
    static func webHost(_ element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<60 {
            guard let el = current else { return nil }
            if string(el, kAXRoleAttribute) == "AXWebArea" {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &ref) == .success,
                      let value = ref else { return nil }
                if CFGetTypeID(value) == CFURLGetTypeID() {
                    // swiftlint:disable:next force_cast
                    return (value as! URL).host?.lowercased()
                }
                return (value as? String).flatMap { URL(string: $0)?.host?.lowercased() }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            // swiftlint:disable:next force_cast
            current = (p as! AXUIElement)
        }
        return nil
    }
}
