import AppKit

extension NSApplication {
    /// Show the Dock icon (and app menu bar) — call before presenting any window.
    func showDockIconIfNeeded() {
        guard activationPolicy() != .regular else { return }
        setActivationPolicy(.regular)
        activate(ignoringOtherApps: true)
    }

    /// Hide the Dock icon after a short delay, but only if no titled windows remain visible.
    /// The delay prevents a flicker when one window closes and another opens immediately.
    func hideDockIconIfNoWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let hasVisibleWindows = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled)
            }
            if !hasVisibleWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Install a minimal main menu so Cmd+W and Cmd+Q work in any window or modal.
    func installMinimalMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Close Window",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit SpeakFree",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        mainMenu.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))  // enables Cmd+C/V/X
        NSApp.mainMenu = mainMenu
    }
}
