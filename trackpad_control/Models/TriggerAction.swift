import Foundation

enum TriggerAction: Codable, Sendable {
    case keyboardShortcut(KeyboardShortcutTrigger)
    case openApp(AppTrigger)
    case windowAction(WindowAction)

    var displayName: String {
        switch self {
        case .keyboardShortcut(let shortcut):
            shortcut.displayString.isEmpty ? "No shortcut" : shortcut.displayString
        case .openApp(let app):
            app.appName.isEmpty ? "No app selected" : "Open \(app.appName)"
        case .windowAction(let action):
            action.rawValue
        }
    }
}

struct KeyboardShortcutTrigger: Codable, Sendable {
    var key: String
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    var displayString: String {
        guard !key.isEmpty else { return "" }
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

struct AppTrigger: Codable, Sendable {
    var appName: String
    var appPath: String
}

enum WindowAction: String, Codable, CaseIterable, Sendable {
    case leftHalf = "Left Half"
    case rightHalf = "Right Half"
    case topHalf = "Top Half"
    case bottomHalf = "Bottom Half"
    case topLeftQuarter = "Top Left Quarter"
    case topRightQuarter = "Top Right Quarter"
    case bottomLeftQuarter = "Bottom Left Quarter"
    case bottomRightQuarter = "Bottom Right Quarter"
    case center = "Center"
    case maximize = "Maximize"
    case moveToLeftDesktop = "Move to Left Desktop"
    case moveToRightDesktop = "Move to Right Desktop"

    var icon: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeftQuarter: "rectangle.inset.topleft.filled"
        case .topRightQuarter: "rectangle.inset.topright.filled"
        case .bottomLeftQuarter: "rectangle.inset.bottomleft.filled"
        case .bottomRightQuarter: "rectangle.inset.bottomright.filled"
        case .center: "arrow.left.and.right"
        case .maximize: "rectangle.fill"
        case .moveToLeftDesktop: "chevron.left.2"
        case .moveToRightDesktop: "chevron.right.2"
        }
    }
}
