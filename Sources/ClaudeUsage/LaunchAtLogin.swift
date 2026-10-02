import ServiceManagement

/// The real login-item state from macOS, so a change made in System Settings shows here too.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but waiting for the user to allow it in System Settings › General › Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Only works from the .app bundle (Task 17), not from `swift run`.
    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
