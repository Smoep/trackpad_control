import SwiftUI

struct MenuBarContentView: View {
    @State private var appState = AppState.shared

    var body: some View {
        Toggle("Tracking", isOn: $appState.recognitionSettings.isTracking)
            .keyboardShortcut("t")

        Divider()

        Button("Settings…") {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Trackpad Control") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
