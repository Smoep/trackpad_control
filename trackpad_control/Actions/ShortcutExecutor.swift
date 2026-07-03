import Carbon
import Foundation

/// Executes keyboard shortcuts via CGEvent with explicit modifier flags.
enum ShortcutExecutor {
    static func execute(_ shortcut: KeyboardShortcutTrigger) {
        guard !shortcut.key.isEmpty else { return }
        guard let keyCode = keyCodeForCharacter(shortcut.key.lowercased()) else {
            print("[ShortcutExecutor] Unknown key: \(shortcut.key)")
            return
        }

        var flags = CGEventFlags()
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.shift { flags.insert(.maskShift) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }

        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Key Code Lookup

    private static func keyCodeForCharacter(_ char: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46, "o": 31,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
            "8": 28, "9": 25, "0": 29,
            "-": 27, "=": 24, "[": 33, "]": 30, "'": 39, ";": 41, "\\": 42,
            ",": 43, "/": 44, ".": 47, "`": 50,
            "tab": 48, "space": 49, " ": 49, "return": 36, "escape": 53,
            "delete": 51, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        return map[char]
    }
}
