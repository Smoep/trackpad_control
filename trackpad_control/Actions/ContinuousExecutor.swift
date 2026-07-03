import AppKit
import Foundation

/// Executes a single "step" for continuous gesture controls.
/// Called from TCM when cumulative movement exceeds the step threshold.
enum ContinuousExecutor {

    /// Execute one step in the given direction.
    /// - Parameters:
    ///   - gesture: The continuous gesture definition
    ///   - positive: true = right/up, false = left/down
    static func executeStep(gesture: GestureDefinition, positive: Bool) {
        switch gesture.continuousControl {
        case .volume:
            postMediaKey(positive ? 0 : 1) // NX_KEYTYPE_SOUND_UP / DOWN
        case .brightness:
            postMediaKey(positive ? 2 : 3) // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
        case .scrollDesktops:
            // Switch desktop only (no window move) via pre-compiled AppleScript
            let script = positive ? scrollRightScript : scrollLeftScript
            script.executeAndReturnError(nil)
        case .cycleWindows:
            // Reversed so the scroll direction matches the other navigation gestures.
            WindowManager.cycleVisibleWindows(positive: !positive)
        case .windowHorizontalTiling:
            WindowManager.cycleHorizontalTiling(positive: positive)
        case .custom:
            let action = positive ? gesture.triggerAction : (gesture.triggerActionReverse ?? gesture.triggerAction)
            TriggerExecutor.execute(action)
        }
    }

    // Pre-compiled AppleScripts for desktop switching (Ctrl+Arrow)
    private static let scrollLeftScript: NSAppleScript = {
        let s = NSAppleScript(source: "tell application \"System Events\" to key code 123 using control down")!
        s.compileAndReturnError(nil)
        return s
    }()
    private static let scrollRightScript: NSAppleScript = {
        let s = NSAppleScript(source: "tell application \"System Events\" to key code 124 using control down")!
        s.compileAndReturnError(nil)
        return s
    }()

    // MARK: - Media Keys

    /// Post a media key (volume, brightness) via NSEvent systemDefined.
    /// NX HID convention: subtype 8, data1 encodes key type + state.
    /// Called from background thread — NSEvent + cgEvent.post is thread-safe.
    private static func postMediaKey(_ keyType: Int32) {
        let kt = Int(keyType)
        // Key down
        if let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: (kt << 16) | 0x0a00, data2: -1
        ) {
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
        // Key up
        if let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: (kt << 16) | 0x0b00, data2: -1
        ) {
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard Events

    /// Post a keyboard event with explicit modifier flags.
    private static func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
