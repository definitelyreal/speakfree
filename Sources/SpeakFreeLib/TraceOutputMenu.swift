// ai-suggestion:unverified · session:unknown · 2026-10-04
import AppKit

/// Small, revocable test control. The existing Settings picker retains the legacy encoding.
enum TraceOutputMenu {
    static let options: [DictationTrace.OutputMode] = [.off, .tags, .tagsOnly, .expanded]

    static func make(selected: DictationTrace.OutputMode, testingAvailable: Bool,
                     select: @escaping (DictationTrace.OutputMode) -> Void)
        -> (item: NSMenuItem, targets: [MenuItemTarget])? {
        guard testingAvailable else { return nil }
        let parent = NSMenuItem(title: "Dictation Trace (Testing)", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: parent.title)
        var targets: [MenuItemTarget] = []
        for mode in options {
            let target = MenuItemTarget { select(mode) }
            targets.append(target)
            let item = NSMenuItem(title: mode.title, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.state = mode == selected ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let scope = NSMenuItem(title: "Text + TAG also adds hidden text in editors/terminals", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        submenu.addItem(scope)
        let note = NSMenuItem(title: "TAG survival and AI readability vary by app", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        parent.submenu = submenu
        return (parent, targets)
    }
}
