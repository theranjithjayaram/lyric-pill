import ServiceManagement

/// Launch-at-login through the app's own SMAppService registration (macOS 13+).
/// Only a bundled app can register: run unbundled (`swift run`) the calls
/// throw, and the Settings window shows that error text instead of crashing.
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// For `.requiresApproval`: macOS wants the user to allow it in Login Items.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
