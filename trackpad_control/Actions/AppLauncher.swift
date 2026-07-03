import AppKit

/// Launches applications via NSWorkspace.
enum AppLauncher {
    static func launch(_ app: AppTrigger) {
        guard !app.appPath.isEmpty else { return }

        let url = URL(fileURLWithPath: app.appPath)
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                print("[AppLauncher] Failed to open \(app.appName): \(error)")
            }
        }
    }
}
