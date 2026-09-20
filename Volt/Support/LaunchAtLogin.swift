import Foundation
import ServiceManagement

/// Wraps `SMAppService` so the settings toggle reads and writes the real login item.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Volt: could not change login item — \(error.localizedDescription)")
            }
        }
    }

    /// True when macOS wants the user to approve the login item in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
