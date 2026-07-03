import SwiftUI
import UniformTypeIdentifiers

struct TriggerEditorView: View {
    @Binding var triggerAction: TriggerAction
    @State private var triggerType: TriggerType

    enum TriggerType: String, CaseIterable {
        case keyboardShortcut = "Keyboard Shortcut"
        case openApp = "Open App"
        case windowAction = "Window Action"
    }

    init(triggerAction: Binding<TriggerAction>) {
        _triggerAction = triggerAction
        switch triggerAction.wrappedValue {
        case .keyboardShortcut: _triggerType = State(initialValue: .keyboardShortcut)
        case .openApp: _triggerType = State(initialValue: .openApp)
        case .windowAction: _triggerType = State(initialValue: .windowAction)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trigger")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            Picker("Type", selection: $triggerType) {
                ForEach(TriggerType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .onChange(of: triggerType) { _, newValue in
                switch newValue {
                case .keyboardShortcut:
                    triggerAction = .keyboardShortcut(KeyboardShortcutTrigger(key: ""))
                case .openApp:
                    triggerAction = .openApp(AppTrigger(appName: "", appPath: ""))
                case .windowAction:
                    triggerAction = .windowAction(.maximize)
                }
            }

            switch triggerAction {
            case .keyboardShortcut(let shortcut):
                ShortcutRecorderView(shortcut: shortcut) { updated in
                    triggerAction = .keyboardShortcut(updated)
                }
            case .openApp(let app):
                AppPickerView(app: app) { updated in
                    triggerAction = .openApp(updated)
                }
            case .windowAction(let action):
                WindowActionPicker(action: action) { updated in
                    triggerAction = .windowAction(updated)
                }
            }
        }
    }
}

// MARK: - Window Action Picker

struct WindowActionPicker: View {
    let action: WindowAction
    let onChange: (WindowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(WindowAction.allCases, id: \.self) { windowAction in
                    Button {
                        onChange(windowAction)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: windowAction.icon)
                                .font(.title2)
                            Text(windowAction.rawValue)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(action == windowAction ? Color.accentColor.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(action == windowAction ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderView: View {
    let shortcut: KeyboardShortcutTrigger
    let onChange: (KeyboardShortcutTrigger) -> Void
    @State private var isRecording = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Shortcut display + record button
            HStack {
                Text("Shortcut:")
                    .foregroundStyle(.secondary)

                if shortcut.key.isEmpty && !isRecording {
                    Text("Not set")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                } else if isRecording {
                    Text("Press a key…")
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.blue.opacity(0.4), lineWidth: 1)
                        )
                } else {
                    Text(shortcut.displayString)
                        .font(.body.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if isRecording {
                    Button("Cancel") {
                        isRecording = false
                    }
                    .controlSize(.small)
                } else {
                    Button("Record") {
                        isRecording = true
                        isFocused = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Modifier toggles
            HStack(spacing: 8) {
                ModifierButton(label: "⌘", isOn: shortcut.command) { val in
                    var s = shortcut; s.command = val; onChange(s)
                }
                ModifierButton(label: "⇧", isOn: shortcut.shift) { val in
                    var s = shortcut; s.shift = val; onChange(s)
                }
                ModifierButton(label: "⌥", isOn: shortcut.option) { val in
                    var s = shortcut; s.option = val; onChange(s)
                }
                ModifierButton(label: "⌃", isOn: shortcut.control) { val in
                    var s = shortcut; s.control = val; onChange(s)
                }
            }
        }
        .background(
            // Hidden key capture field
            KeyCaptureField(isRecording: $isRecording) { key, modifiers in
                var s = shortcut
                s.key = key
                s.command = modifiers.contains(.command)
                s.shift = modifiers.contains(.shift)
                s.option = modifiers.contains(.option)
                s.control = modifiers.contains(.control)
                onChange(s)
                isRecording = false
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .focused($isFocused)
        )
    }
}

// MARK: - Key Capture NSView

struct KeyCaptureField: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (String, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        if isRecording {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }
}

final class KeyCaptureNSView: NSView {
    var onCapture: ((String, NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = keyName(for: event)
        guard !key.isEmpty else { return }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        onCapture?(key, mods)
    }

    private func keyName(for event: NSEvent) -> String {
        // Map common key codes to display names
        switch Int(event.keyCode) {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 53: return "Escape"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? ""
        }
    }
}

// MARK: - Modifier Button

struct ModifierButton: View {
    let label: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
        } label: {
            Text(label)
                .font(.title3)
                .frame(width: 28, height: 28)
                .background(
                    isOn ? Color.blue.opacity(0.2) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .foregroundStyle(isOn ? .blue : .secondary)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - App Picker

struct AppPickerView: View {
    let app: AppTrigger
    let onChange: (AppTrigger) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !app.appPath.isEmpty {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                        .resizable()
                        .frame(width: 32, height: 32)
                    Text(app.appName)
                        .fontWeight(.medium)
                }
            }

            Button("Choose App…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowedContentTypes = [.application]
                if panel.runModal() == .OK, let url = panel.url {
                    let name = url.deletingPathExtension().lastPathComponent
                    onChange(AppTrigger(appName: name, appPath: url.path))
                }
            }
        }
    }
}
