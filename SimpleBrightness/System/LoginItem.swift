import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (public API, macOS 13+).
/// The registration lives in macOS (System Settings › General › Login Items),
/// not in our preferences, so it is always read back from the system.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the error to show the user, if any.
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            return error
        }
    }

    /// For `make uninstall`: unregister if registered; true on success.
    static func unregisterForUninstall() -> Bool {
        // Only a registered item can (and needs to) be removed; .notRegistered and
        // .notFound (e.g. a bundle outside /Applications) are already clean.
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: break
        default: return true
        }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            FileHandle.standardError.write(Data("Login item: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
