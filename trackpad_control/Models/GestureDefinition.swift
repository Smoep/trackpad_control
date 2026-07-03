import Foundation

// MARK: - Input Type

enum InputType: String, Codable, CaseIterable, Sendable {
    case discrete = "Discrete"
    case continuous = "Continuous"
    case pinch = "Pinch"
    case dial = "Dial"
    case zoneTap = "Zone Tap"

    var icon: String {
        switch self {
        case .discrete: "hand.draw"
        case .continuous: "slider.horizontal.3"
        case .pinch: "arrow.up.left.and.arrow.down.right"
        case .dial: "dial.low"
        case .zoneTap: "tablecells"
        }
    }

    var description: String {
        switch self {
        case .discrete: "One-shot pattern → single action"
        case .continuous: "Live movement → continuous control"
        case .pinch: "Pinch/spread → continuous control"
        case .dial: "Rotational twist → continuous control"
        case .zoneTap: "Tap in trackpad zones → action"
        }
    }

    /// Whether this type uses continuous-style detection (no recording needed)
    var isContinuousFamily: Bool {
        self == .continuous || self == .pinch || self == .dial
    }
}

// MARK: - Continuous Axis

enum ContinuousAxis: String, Codable, CaseIterable, Sendable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
}

// MARK: - Continuous Control

enum ContinuousControl: String, Codable, CaseIterable, Sendable {
    case volume = "Volume"
    case brightness = "Brightness"
    case scrollDesktops = "Scroll Desktops"
    case cycleWindows = "Cycle Windows"
    case windowHorizontalTiling = "Window Horizontal Tiling"
    case custom = "Custom Shortcut"

    var icon: String {
        switch self {
        case .volume: "speaker.wave.2"
        case .brightness: "sun.max"
        case .scrollDesktops: "rectangle.3.group"
        case .cycleWindows: "macwindow.on.rectangle"
        case .windowHorizontalTiling: "rectangle.split.3x1"
        case .custom: "keyboard"
        }
    }

    var isNavigationControl: Bool {
        self == .scrollDesktops || self == .cycleWindows
    }
}

// MARK: - Trackpad Zone

enum TrackpadZone: String, Codable, CaseIterable, Sendable {
    case topLeft = "Top Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case centerLeft = "Center Left"
    case center = "Center"
    case centerRight = "Center Right"
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"

    /// Normalized rect on trackpad (0-1 coordinate space)
    var rect: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let third = 1.0 / 3.0
        let col: (Double, Double) = switch self {
        case .topLeft, .centerLeft, .bottomLeft: (0, third)
        case .topCenter, .center, .bottomCenter: (third, third * 2)
        case .topRight, .centerRight, .bottomRight: (third * 2, 1)
        }
        let row: (Double, Double) = switch self {
        case .bottomLeft, .bottomCenter, .bottomRight: (0, third)
        case .centerLeft, .center, .centerRight: (third, third * 2)
        case .topLeft, .topCenter, .topRight: (third * 2, 1)
        }
        return (col.0, row.0, col.1, row.1)
    }

    /// Check if a normalized point falls in this zone
    func contains(x: Double, y: Double) -> Bool {
        let r = rect
        return x >= r.minX && x < r.maxX && y >= r.minY && y < r.maxY
    }
}

// MARK: - Gesture Definition

struct GestureDefinition: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isEnabled: Bool = true
    var fingerCount: Int
    var inputType: InputType = .discrete
    var triggerAction: TriggerAction
    var samples: [GestureSample] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // Continuous-specific
    var continuousAxis: ContinuousAxis = .horizontal
    var continuousControl: ContinuousControl = .volume
    var continuousSensitivity: Double = 5 // 1–10 scale: 1=coarse, 10=fine
    var triggerActionReverse: TriggerAction? // For custom: reverse direction shortcut

    // Location-specific (legacy — kept for migration)
    var trackpadZone: TrackpadZone = .center

    // Zone Tap specific
    var activeZones: Set<TrackpadZone> = []
    var tapCount: Int = 1  // 1 = single, 2 = double, 3 = triple

    /// Step threshold derived from sensitivity (1→0.15 big steps, 10→0.02 fine steps)
    var continuousStepThreshold: Double {
        0.15 - (continuousSensitivity - 1) * (0.13 / 9)
    }
}

// MARK: - Mock Data

extension GestureDefinition {
    static let mockData: [GestureDefinition] = [
        GestureDefinition(
            name: "Switch App Right",
            fingerCount: 3,
            triggerAction: .keyboardShortcut(KeyboardShortcutTrigger(key: "Tab", command: true)),
            samples: [
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        PathPoint(x: 0.2 + t * 0.6, y: 0.5 + sin(t * .pi) * 0.02, timestamp: t * 0.3)
                    },
                    fingerCount: 3,
                    duration: 0.3
                ),
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        PathPoint(x: 0.15 + t * 0.65, y: 0.48 + sin(t * .pi) * 0.03, timestamp: t * 0.35)
                    },
                    fingerCount: 3,
                    duration: 0.35
                ),
            ]
        ),
        GestureDefinition(
            name: "Show Desktop",
            fingerCount: 2,
            triggerAction: .keyboardShortcut(KeyboardShortcutTrigger(key: "D", command: true, shift: true)),
            samples: [
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        PathPoint(x: 0.5 + sin(t * .pi) * 0.03, y: 0.8 - t * 0.6, timestamp: t * 0.25)
                    },
                    fingerCount: 2,
                    duration: 0.25
                ),
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        PathPoint(x: 0.48 + sin(t * .pi) * 0.04, y: 0.75 - t * 0.55, timestamp: t * 0.28)
                    },
                    fingerCount: 2,
                    duration: 0.28
                ),
            ]
        ),
        GestureDefinition(
            name: "Open Safari",
            fingerCount: 1,
            triggerAction: .openApp(AppTrigger(appName: "Safari", appPath: "/Applications/Safari.app")),
            samples: [
                GestureSample(
                    pathPoints: [
                        PathPoint(x: 0.3, y: 0.8, timestamp: 0),
                        PathPoint(x: 0.3, y: 0.7, timestamp: 0.05),
                        PathPoint(x: 0.3, y: 0.6, timestamp: 0.1),
                        PathPoint(x: 0.3, y: 0.5, timestamp: 0.15),
                        PathPoint(x: 0.3, y: 0.4, timestamp: 0.2),
                        PathPoint(x: 0.3, y: 0.3, timestamp: 0.25),
                        PathPoint(x: 0.4, y: 0.3, timestamp: 0.3),
                        PathPoint(x: 0.5, y: 0.3, timestamp: 0.35),
                        PathPoint(x: 0.6, y: 0.3, timestamp: 0.4),
                        PathPoint(x: 0.7, y: 0.3, timestamp: 0.45),
                    ],
                    fingerCount: 1,
                    duration: 0.45
                ),
                GestureSample(
                    pathPoints: [
                        PathPoint(x: 0.28, y: 0.78, timestamp: 0),
                        PathPoint(x: 0.29, y: 0.65, timestamp: 0.08),
                        PathPoint(x: 0.3, y: 0.5, timestamp: 0.15),
                        PathPoint(x: 0.3, y: 0.35, timestamp: 0.22),
                        PathPoint(x: 0.3, y: 0.28, timestamp: 0.27),
                        PathPoint(x: 0.42, y: 0.28, timestamp: 0.32),
                        PathPoint(x: 0.55, y: 0.29, timestamp: 0.37),
                        PathPoint(x: 0.68, y: 0.28, timestamp: 0.42),
                    ],
                    fingerCount: 1,
                    duration: 0.42
                ),
            ]
        ),
        GestureDefinition(
            name: "Zoom In",
            isEnabled: false,
            fingerCount: 2,
            triggerAction: .keyboardShortcut(KeyboardShortcutTrigger(key: "=", command: true)),
            samples: [
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.04).map { t in
                        PathPoint(
                            x: 0.5 + cos(t * 2 * .pi) * 0.15,
                            y: 0.5 + sin(t * 2 * .pi) * 0.15,
                            timestamp: t * 0.6
                        )
                    },
                    fingerCount: 2,
                    duration: 0.6
                ),
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.04).map { t in
                        PathPoint(
                            x: 0.5 + cos(t * 2 * .pi) * 0.14,
                            y: 0.5 + sin(t * 2 * .pi) * 0.14,
                            timestamp: t * 0.55
                        )
                    },
                    fingerCount: 2,
                    duration: 0.55
                ),
            ]
        ),
        GestureDefinition(
            name: "Mission Control",
            fingerCount: 4,
            triggerAction: .keyboardShortcut(KeyboardShortcutTrigger(key: "↑", control: true)),
            samples: [
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        PathPoint(x: 0.2 + t * 0.6, y: 0.3 + t * 0.5, timestamp: t * 0.3)
                    },
                    fingerCount: 4,
                    duration: 0.3
                ),
                GestureSample(
                    pathPoints: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        PathPoint(x: 0.25 + t * 0.55, y: 0.25 + t * 0.55, timestamp: t * 0.28)
                    },
                    fingerCount: 4,
                    duration: 0.28
                ),
            ]
        ),
    ]
}
