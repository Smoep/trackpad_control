import Foundation
import os.log

private let teLog = Logger(subsystem: "com.trackpadcontrol.debug", category: "TriggerExecutor")

/// Dispatches trigger actions when a gesture is recognized.
enum TriggerExecutor {
    static func execute(_ action: TriggerAction) {
        teLog.debug("execute: \(action.displayName)")
        switch action {
        case .keyboardShortcut(let shortcut):
            ShortcutExecutor.execute(shortcut)
        case .openApp(let app):
            AppLauncher.launch(app)
        case .windowAction(let action):
            teLog.debug("routing to WindowManager: \(action.rawValue)")
            WindowManager.execute(action)
        }
    }
}
