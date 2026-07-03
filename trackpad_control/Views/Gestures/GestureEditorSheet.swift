import SwiftUI

struct GestureEditorSheet: View {
    @State var gesture: GestureDefinition
    let isNew: Bool
    @State private var appState = AppState.shared
    @State private var previewSample: GestureSample?

    private var needsRecorder: Bool {
        gesture.inputType == .discrete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Two-column content
            HStack(alignment: .top, spacing: 0) {
                // Left column: recorder for discrete, visual for continuous family and zone tap
                if needsRecorder {
                    recorderColumn
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if gesture.inputType == .zoneTap {
                    zoneTapVisual
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    continuousFamilyVisual
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                Divider()

                // Right: Metadata + trigger
                ScrollView {
                    rightColumn
                        .padding()
                }
                .frame(width: 260)
            }
        }
        .frame(width: 700, height: 580)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: gesture.inputType.icon)
                    .foregroundStyle(.secondary)
                Text(isNew ? "Create \(gesture.inputType.rawValue) Input" : "Edit \(gesture.inputType.rawValue) Input")
                    .font(.headline)
            }

            Spacer()

            Button("Cancel") {
                appState.isShowingEditor = false
            }
            .keyboardShortcut(.cancelAction)

            Button(isNew ? "Create" : "Save") {
                gesture.updatedAt = Date()
                if gesture.inputType == .discrete {
                    if !gesture.samples.isEmpty {
                        gesture.fingerCount = gesture.samples.first?.fingerCount ?? gesture.fingerCount
                    }
                }
                appState.saveGesture(gesture)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(gesture.name.isEmpty || (isNew && gesture.inputType == .discrete && gesture.samples.count < 2) || (gesture.inputType == .zoneTap && gesture.activeZones.isEmpty))
        }
        .padding()
    }

    // MARK: - Recorder Column (Discrete + Location)

    private var recorderColumn: some View {
        VStack(spacing: 12) {
            TrackpadRecorderView(samples: $gesture.samples, previewSample: $previewSample)

            // Sample list
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Samples")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(gesture.samples.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    if isNew {
                        Text("(min 2)")
                            .font(.caption2)
                            .foregroundStyle(gesture.samples.count >= 2 ? .green : .orange)
                    }
                }

                if gesture.samples.isEmpty {
                    Text("No samples yet. Record at least two samples of the gesture.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(gesture.samples) { sample in
                                GestureSampleCardView(
                                    sample: sample,
                                    onDelete: {
                                        gesture.samples.removeAll { $0.id == sample.id }
                                    },
                                    onSelect: {
                                        previewSample = sample
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Continuous Family Visual (replaces recorder)

    private var continuousFamilyVisual: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: continuousFamilyIcon)
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.blue.opacity(0.5))

            VStack(spacing: 4) {
                Text(continuousFamilyTitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)

                if gesture.continuousControl != .custom {
                    Text(gesture.continuousControl.rawValue)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 2) {
                        Text("\(continuousFamilyPositiveLabel) \(gesture.triggerAction.displayName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("\(continuousFamilyNegativeLabel) \((gesture.triggerActionReverse ?? gesture.triggerAction).displayName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Text("No recording needed — detected by finger count and movement pattern.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Zone Tap Visual (3×3 interactive grid)

    private var zoneTapVisual: some View {
        VStack(spacing: 16) {
            Text("Tap Zones")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 3×3 grid — trackpad representation
            let zoneRows: [[TrackpadZone]] = [
                [.topLeft, .topCenter, .topRight],
                [.centerLeft, .center, .centerRight],
                [.bottomLeft, .bottomCenter, .bottomRight],
            ]
            VStack(spacing: 3) {
                ForEach(zoneRows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(row, id: \.self) { zone in
                            let isActive = gesture.activeZones.contains(zone)
                            Button {
                                if isActive {
                                    gesture.activeZones.remove(zone)
                                    // Don't allow empty — keep at least one
                                    // Empty is allowed — save button will require at least one
                                } else {
                                    gesture.activeZones.insert(zone)
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isActive ? Color.blue.opacity(0.4) : Color.primary.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(isActive ? Color.blue.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                    .overlay {
                                        Text(zoneShortName(zone))
                                            .font(.caption2)
                                            .foregroundStyle(isActive ? .primary : .tertiary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1.3, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1.5)
                    )
            }

            Text("Click zones to toggle. Tap activates when fingers land in any selected zone.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            // Finger count and tap visualization
            HStack(spacing: 8) {
                Label("\(gesture.fingerCount) finger\(gesture.fingerCount == 1 ? "" : "s")", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Label(gesture.tapCount == 1 ? "Single tap" : gesture.tapCount == 2 ? "Double tap" : "Triple tap", systemImage: "touch.radiowaves.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Label("\(gesture.activeZones.count) zone\(gesture.activeZones.count == 1 ? "" : "s")", systemImage: "tablecells")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func zoneShortName(_ zone: TrackpadZone) -> String {
        switch zone {
        case .topLeft: "TL"
        case .topCenter: "TC"
        case .topRight: "TR"
        case .centerLeft: "CL"
        case .center: "C"
        case .centerRight: "CR"
        case .bottomLeft: "BL"
        case .bottomCenter: "BC"
        case .bottomRight: "BR"
        }
    }

    private var continuousFamilyIcon: String {
        switch gesture.inputType {
        case .continuous:
            gesture.continuousAxis == .horizontal ? "arrow.left.arrow.right" : "arrow.up.arrow.down"
        case .pinch:
            "arrow.up.left.and.arrow.down.right"
        case .dial:
            "dial.low"
        default:
            "questionmark"
        }
    }

    private var continuousFamilyTitle: String {
        switch gesture.inputType {
        case .continuous:
            "\(gesture.fingerCount)-finger \(gesture.continuousAxis.rawValue.lowercased()) swipe"
        case .pinch:
            "\(gesture.fingerCount)-finger pinch / spread"
        case .dial:
            "\(gesture.fingerCount)-finger dial rotation"
        default:
            ""
        }
    }

    private var continuousFamilyPositiveLabel: String {
        switch gesture.inputType {
        case .continuous:
            gesture.continuousAxis == .horizontal ? "→" : "↑"
        case .pinch:
            "⤢" // spread out
        case .dial:
            "↻" // clockwise
        default: "+"
        }
    }

    private var continuousFamilyNegativeLabel: String {
        switch gesture.inputType {
        case .continuous:
            gesture.continuousAxis == .horizontal ? "←" : "↓"
        case .pinch:
            "⤡" // pinch in
        case .dial:
            "↺" // counterclockwise
        default: "-"
        }
    }

    // MARK: - Right Column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                TextField("Input name", text: $gesture.name)
                    .textFieldStyle(.roundedBorder)
            }

            // Type-specific configuration
            switch gesture.inputType {
            case .discrete:
                TriggerEditorView(triggerAction: $gesture.triggerAction)

            case .continuous:
                continuousSettings

            case .pinch, .dial:
                pinchDialSettings

            case .zoneTap:
                zoneTapSettings
                Divider()
                TriggerEditorView(triggerAction: $gesture.triggerAction)
            }

            Divider()

            // Enabled
            Toggle("Enabled", isOn: $gesture.isEnabled)
                .toggleStyle(.switch)

            // Summary
            summarySection
        }
    }

    // MARK: - Continuous Settings

    private var continuousSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Finger count
            VStack(alignment: .leading, spacing: 4) {
                Text("Fingers")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.fingerCount) {
                    ForEach(1...5, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Direction
            VStack(alignment: .leading, spacing: 4) {
                Text("Direction")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.continuousAxis) {
                    Text("← →  Horizontal").tag(ContinuousAxis.horizontal)
                    Text("↑ ↓  Vertical").tag(ContinuousAxis.vertical)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Control
            VStack(alignment: .leading, spacing: 4) {
                Text("Control")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.continuousControl) {
                    ForEach(ContinuousControl.allCases, id: \.self) { control in
                        Label(control.rawValue, systemImage: control.icon).tag(control)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Sensitivity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(sensitivityLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $gesture.continuousSensitivity, in: 1...10, step: 1)
                    .tint(.blue)

                Text(sensitivityHelpText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(continuousHelpText)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Custom shortcut triggers — one per direction
            if gesture.continuousControl == .custom {
                Divider()
                customShortcutSettings
            }
        }
    }

    private var sensitivityLabel: String {
        let v = Int(gesture.continuousSensitivity)
        switch v {
        case 1...3: return "\(v) — Coarse"
        case 4...6: return "\(v) — Medium"
        case 7...9: return "\(v) — Fine"
        case 10: return "10 — Very Fine"
        default: return "\(v)"
        }
    }

    private var sensitivityHelpText: String {
        let v = Int(gesture.continuousSensitivity)
        if v <= 3 {
            return "Large movements needed per step. Good for desktop switching."
        } else if v <= 6 {
            return "Balanced responsiveness. Good for volume and brightness."
        } else {
            return "Small movements trigger steps. Precise fine-tuning."
        }
    }

    private var customShortcutSettings: some View {
        return VStack(alignment: .leading, spacing: 12) {
            Text(gesture.continuousAxis == .horizontal ? "→ Right / ↑ Up" : "↑ Up")
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            TriggerEditorView(triggerAction: $gesture.triggerAction)

            Text(gesture.continuousAxis == .horizontal ? "← Left / ↓ Down" : "↓ Down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            TriggerEditorView(triggerAction: reverseActionBinding)
        }
    }

    private var reverseActionBinding: Binding<TriggerAction> {
        Binding(
            get: { gesture.triggerActionReverse ?? .keyboardShortcut(KeyboardShortcutTrigger(key: "")) },
            set: { gesture.triggerActionReverse = $0 }
        )
    }

    private var continuousHelpText: String {
        switch gesture.continuousControl {
        case .volume:
            "Controls system volume while swiping."
        case .brightness:
            "Controls screen brightness while swiping."
        case .scrollDesktops:
            "Switches between desktops while swiping."
        case .cycleWindows:
            "Cycles through visible windows across apps on the current desktop while swiping."
        case .windowHorizontalTiling:
            "Horizontal swipe cycles active window layouts: half, quarter, and three-quarters on the swipe side."
        case .custom:
            "Sends configured shortcuts while swiping."
        }
    }

    // MARK: - Pinch / Dial Settings

    private var pinchDialSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Finger count (pinch needs ≥2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fingers")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.fingerCount) {
                    ForEach(2...5, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Control
            VStack(alignment: .leading, spacing: 4) {
                Text("Control")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.continuousControl) {
                    ForEach(ContinuousControl.allCases, id: \.self) { control in
                        Label(control.rawValue, systemImage: control.icon).tag(control)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Sensitivity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(sensitivityLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $gesture.continuousSensitivity, in: 1...10, step: 1)
                    .tint(.blue)

                Text(sensitivityHelpText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if gesture.inputType == .pinch {
                Text("Spread fingers apart or pinch inward to control.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Rotate fingers like turning a knob to control.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Custom shortcut triggers
            if gesture.continuousControl == .custom {
                Divider()
                pinchDialCustomShortcuts
            }
        }
    }

    private var pinchDialCustomShortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            if gesture.inputType == .pinch {
                Text("⤢ Spread Out")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
            } else {
                Text("↻ Clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
            }
            TriggerEditorView(triggerAction: $gesture.triggerAction)

            if gesture.inputType == .pinch {
                Text("⤡ Pinch In")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
            } else {
                Text("↺ Counter-clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
            }
            TriggerEditorView(triggerAction: reverseActionBinding)
        }
    }

    // MARK: - Zone Tap Settings

    private var zoneTapSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Finger count
            VStack(alignment: .leading, spacing: 4) {
                Text("Fingers")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.fingerCount) {
                    ForEach(1...5, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Tap count
            VStack(alignment: .leading, spacing: 4) {
                Text("Tap Count")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Picker("", selection: $gesture.tapCount) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                    Text("Triple").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(tapCountHelp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var tapCountHelp: String {
        switch gesture.tapCount {
        case 1: "Triggers on a single tap in the selected zones."
        case 2: "Triggers on a double tap (two quick taps) in the selected zones."
        case 3: "Triggers on a triple tap in the selected zones."
        default: ""
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Label(gesture.inputType.rawValue, systemImage: gesture.inputType.icon)
                if gesture.inputType.isContinuousFamily {
                    Label("\(gesture.fingerCount)F \(continuousFamilySummary)", systemImage: "hand.raised.fingers.spread")
                    Label(gesture.continuousControl.rawValue, systemImage: gesture.continuousControl.icon)
                } else if gesture.inputType == .zoneTap {
                    Label("\(gesture.fingerCount)F \(gesture.tapCount == 1 ? "single" : gesture.tapCount == 2 ? "double" : "triple") tap", systemImage: "hand.tap")
                    Label("\(gesture.activeZones.count) zone\(gesture.activeZones.count == 1 ? "" : "s")", systemImage: "tablecells")
                } else {
                    Label(gesture.triggerAction.displayName, systemImage: "bolt")
                    Label(
                        "\(gesture.samples.count) sample\(gesture.samples.count == 1 ? "" : "s")",
                        systemImage: "square.stack.3d.up"
                    )
                }
                Label(
                    gesture.isEnabled ? "Enabled" : "Disabled",
                    systemImage: gesture.isEnabled ? "checkmark.circle" : "xmark.circle"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var continuousFamilySummary: String {
        switch gesture.inputType {
        case .continuous: gesture.continuousAxis.rawValue.lowercased()
        case .pinch: "pinch"
        case .dial: "dial"
        default: ""
        }
    }
}
