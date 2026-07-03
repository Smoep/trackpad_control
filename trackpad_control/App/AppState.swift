import Foundation
import SwiftUI

@Observable
final class AppState {
    static let shared = AppState()

    var selectedTab: SettingsTab = .gestures
    var recognitionSettings = RecognitionSettings()
    var appearanceSettings = AppearanceSettings()
    let gestureStore = GestureStore.shared

    // Editor state
    var editingGesture: GestureDefinition?
    var isShowingEditor: Bool = false
    var isCreatingNew: Bool = false

    // Recognition telemetrics (updated on each gesture completion)
    var lastGestureFingerCount: Int = 0
    var lastGesturePointCount: Int = 0
    var lastMatchName: String = ""
    var lastMatchScore: Double = 0
    var lastMatchTurnCount: Int = 0
    var lastGestureTimestamp: Date?
    var lastAllScores: [(name: String, score: Double)] = []
    var lastGestureStartX: Double = 0
    var lastGestureStartY: Double = 0
    var lastGestureEndX: Double = 0
    var lastGestureEndY: Double = 0
    var lastGesturePathLength: Double = 0

    // Live telemetrics (updated each frame during gesture)
    var liveX: Double = 0
    var liveY: Double = 0
    var isGestureActive: Bool = false

    // Recording state (set by TrackpadRecorderView, read by TCM)
    var isRecordingArmed: Bool = false
    var recordingLivePaths: [[PathPoint]] = []
    var recordingLiveFingerCount: Int = 0
    var recordingUpdateCounter: Int = 0  // incremented on each live update
    var recordingCompletionCounter: Int = 0  // incremented when recording completes
    var recordedPaths: [[PathPoint]]?  // nil until gesture completes
    var recordedFingerCount: Int = 0

    private init() {}

    var gestures: [GestureDefinition] {
        get { gestureStore.gestures }
    }

    func createNewGesture(inputType: InputType = .discrete) {
        let defaultFingers: Int
        switch inputType {
        case .discrete: defaultFingers = 1
        case .continuous: defaultFingers = 3
        case .pinch, .dial: defaultFingers = 2
        case .zoneTap: defaultFingers = 1
        }
        editingGesture = GestureDefinition(
            name: "",
            fingerCount: defaultFingers,
            inputType: inputType,
            triggerAction: .keyboardShortcut(KeyboardShortcutTrigger(key: ""))
        )
        isCreatingNew = true
        isShowingEditor = true
    }

    func editGesture(_ gesture: GestureDefinition) {
        editingGesture = gesture
        isCreatingNew = false
        isShowingEditor = true
    }

    func saveGesture(_ gesture: GestureDefinition) {
        gestureStore.saveOrAdd(gesture)
        isShowingEditor = false
        editingGesture = nil
    }

    func deleteGesture(_ gesture: GestureDefinition) {
        gestureStore.delete(gesture)
    }

    func toggleGesture(_ gesture: GestureDefinition) {
        gestureStore.toggleEnabled(gesture)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case gestures = "Inputs"
    case recognition = "Recognition"
    case appearance = "Appearance"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gestures: "rectangle.3.group"
        case .recognition: "brain.head.profile"
        case .appearance: "paintbrush"
        case .advanced: "gearshape.2"
        }
    }
}
