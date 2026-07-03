import SwiftUI

@main
struct trackpad_controlApp: App {
    @State private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra("Trackpad Control", systemImage: appState.recognitionSettings.isTracking ? "hand.point.up.braille.fill" : "hand.point.up.braille") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        StartupMaintenance.run()
        mtdLog("[STARTUP] marker=\(GestureOverlayWindow.diagnosticBuildMarker)")
        WindowManager.startTrackingSpaceChanges()
        if ProcessInfo.processInfo.environment["TC_OVERLAY_SELF_TEST"] == "1"
            || UserDefaults.standard.bool(forKey: "debug_overlay_self_test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                GestureOverlayWindow.shared.showDiagnosticSelfTest(duration: 20.0)
            }
        }
        if AppState.shared.recognitionSettings.isTracking {
            DispatchQueue.main.async {
                TouchCaptureManager.shared.start()
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsRootView())
            let settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow.title = "Trackpad Control"
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow.setContentSize(NSSize(width: 820, height: 600))
            settingsWindow.center()
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.delegate = self
            settingsWindow.setFrameAutosaveName("settings")
            window = settingsWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        window?.delegate = nil
        window = nil
    }
}

enum StartupMaintenance {
    static func run() {
        pruneLegacyDefaults()
        pruneDiagnosticsLogIfNeeded()
    }

    private static func pruneLegacyDefaults() {
        let defaults = UserDefaults.standard
        let obsoleteKeys = [
            "gestureTemplates",
            "activationMargin",
            "recognitionThreshold",
            "trailColorHex",
            "trailThickness",
            "triggerFingerCount",
            "isEnabled",
            "NSWindow Frame com_apple_SwiftUI_Settings_window",
            "NSSplitView Subview Frames com_apple_SwiftUI_Settings_window, SidebarNavigationSplitView",
            "NSWindow Frame Gesture_Sign.ContentView-1-AppWindow-1",
            "NSWindow Frame trackpad_control.ContentView-1-AppWindow-1"
        ]
        for key in obsoleteKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    private static func pruneDiagnosticsLogIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "adv_diagnostics") else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let logURL = appSupport?.appendingPathComponent("TrackpadControl", isDirectory: true).appendingPathComponent("tc-debug.log") else { return }

        let maxBytes = 1_048_576
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes,
              let data = try? Data(contentsOf: logURL) else { return }

        let suffix = data.suffix(maxBytes)
        try? Data(suffix).write(to: logURL, options: .atomic)
    }
}
