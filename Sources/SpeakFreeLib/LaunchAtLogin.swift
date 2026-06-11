import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                    print("Launch at login: registered successfully (status: \(SMAppService.mainApp.status))")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("Launch at login: unregistered successfully")
                }
            } catch {
                print("Launch at login error: \(error)")
                print("  SMAppService status: \(SMAppService.mainApp.status)")
                print("  Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
                print("  Bundle path: \(Bundle.main.bundlePath)")
            }
        }
    }
}
