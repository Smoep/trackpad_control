import SwiftUI

struct RecognitionView: View {
    @State private var appState = AppState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                trackingStatus
                telemetricsSection
                activationSection
                sensitivitySection
            }
            .padding()
        }
    }

    // MARK: - Tracking Status

    private var trackingStatus: some View {
        SettingsSection(title: "STATUS") {
            HStack {
                Label(
                    appState.recognitionSettings.isTracking ? "Active" : "Paused",
                    systemImage: appState.recognitionSettings.isTracking
                        ? "bolt.circle.fill" : "pause.circle"
                )
                .foregroundStyle(
                    appState.recognitionSettings.isTracking ? .green : .secondary
                )
                .font(.body.weight(.medium))

                Spacer()

                Toggle("", isOn: $appState.recognitionSettings.isTracking)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            HStack {
                Label(
                    "Test Mode",
                    systemImage: "testtube.2"
                )
                .foregroundStyle(
                    appState.recognitionSettings.testMode ? .orange : .secondary
                )
                .font(.body.weight(.medium))

                Spacer()

                Toggle("", isOn: $appState.recognitionSettings.testMode)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .help("Gestures are recognized but actions are not executed")

            if appState.recognitionSettings.testMode {
                Text("Actions disabled — gestures will register without executing.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Telemetrics

    private var telemetricsSection: some View {
        SettingsSection(title: "LAST GESTURE") {
            if appState.lastGestureTimestamp == nil && !appState.isGestureActive {
                Text("No gesture captured yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                // Live position during gesture
                if appState.isGestureActive {
                    HStack {
                        Label("Tracking…", systemImage: "location.fill")
                            .foregroundStyle(.blue)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(String(format: "(%.2f, %.2f)", appState.liveX, appState.liveY))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // Match result (show after gesture completes)
                if appState.lastGestureTimestamp != nil {
                HStack {
                    if !appState.lastMatchName.isEmpty {
                        Label(appState.lastMatchName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.body.weight(.medium))
                    } else {
                        Label("No match", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.body.weight(.medium))
                    }
                    Spacer()
                    Text("\(appState.lastGestureFingerCount) finger\(appState.lastGestureFingerCount == 1 ? "" : "s") · \(appState.lastGesturePointCount) pts")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Spatial data
                HStack(spacing: 16) {
                    telemetricItem("Start", String(format: "(%.2f, %.2f)", appState.lastGestureStartX, appState.lastGestureStartY))
                    telemetricItem("End", String(format: "(%.2f, %.2f)", appState.lastGestureEndX, appState.lastGestureEndY))
                    telemetricItem("Length", String(format: "%.2f", appState.lastGesturePathLength))
                    Spacer()
                }

                // Score breakdown
                if !appState.lastAllScores.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.lastAllScores, id: \.name) { item in
                            HStack {
                                Text(item.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                // Score bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.primary.opacity(0.06))
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(item.score >= appState.recognitionSettings.discreteConfidence ? Color.green.opacity(0.5) : Color.orange.opacity(0.4))
                                            .frame(width: geo.size.width * item.score)
                                    }
                                }
                                .frame(width: 80, height: 8)
                                Text(String(format: "%.0f%%", item.score * 100))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    Text("Threshold: \(String(format: "%.0f%%", appState.recognitionSettings.discreteConfidence * 100)) / \(String(format: "%.0f%%", appState.recognitionSettings.locationConfidence * 100))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                } // end lastGestureTimestamp != nil
            }
        }
    }

    // MARK: - Activation

    private var activationSection: some View {
        SettingsSection(title: "ACTIVATION LAYERS") {
            Label("Set a modifier key per finger count — Always On captures without a key", systemImage: "hand.raised.fingers.spread")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            layerRow("1 Finger", $appState.recognitionSettings.layer1Key)
            layerRow("2 Fingers", $appState.recognitionSettings.layer2Key)
            layerRow("3 Fingers", $appState.recognitionSettings.layer3Key)
            layerRow("4 Fingers", $appState.recognitionSettings.layer4Key)
            layerRow("5 Fingers", $appState.recognitionSettings.layer5Key)

            let usesAnchor = (1...5).contains { appState.recognitionSettings.layerKey(for: $0) == .anchor }
            if usesAnchor {
                Divider()

                SettingsSlider(
                    label: "Anchor Delay",
                    value: $appState.recognitionSettings.anchorActivationDelay,
                    range: 0.10...0.80,
                    step: 0.01,
                    help: "How long the held finger must stay down before Anchor activates.",
                    displayValue: { String(format: "%.0f ms", $0 * 1000) }
                )

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anchor Zones")
                            .font(.body.weight(.medium))
                        Text("Tap a zone to toggle it. Disabled zones (✕) won't start an anchor hold — useful for excluding a resting-palm corner.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    TrackpadZoneMultiGrid(enabledZones: $appState.recognitionSettings.anchorAllowedZones)
                        .frame(width: 180, height: 132)
                }
            }

            let allAlwaysOn = (1...5).allSatisfy { appState.recognitionSettings.layerKey(for: $0) == .alwaysOn }
            if allAlwaysOn {
                Text("All layers are Always On — gestures activate without any modifier key.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func layerRow(_ label: String, _ key: Binding<RecognitionSettings.LayerActivation>) -> some View {
        HStack {
            Text(label)
                .font(.body.weight(.medium))
                .frame(width: 80, alignment: .leading)
            Picker("", selection: key) {
                ForEach(RecognitionSettings.LayerActivation.allCases, id: \.self) { k in
                    Text(k.rawValue).tag(k)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Sensitivity

    private var sensitivitySection: some View {
        VStack(spacing: 16) {
            discreteSensitivity
            locationSensitivity
            continuousSensitivity
        }
    }

    private var discreteSensitivity: some View {
        SettingsSection(title: "DISCRETE") {
            Label("Pattern matching for one-shot gestures", systemImage: "hand.draw")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsSlider(
                label: "Shape Confidence",
                value: $appState.recognitionSettings.discreteConfidence,
                range: 0.5...0.95,
                help: confidenceHelp(appState.recognitionSettings.discreteConfidence)
            )

            SettingsSlider(
                label: "Minimum Length",
                value: $appState.recognitionSettings.discreteMinLength,
                range: 0.1...1.0,
                help: minLengthHelp(appState.recognitionSettings.discreteMinLength)
            )
        }
    }

    private var locationSensitivity: some View {
        SettingsSection(title: "LOCATION") {
            Label("Position-aware gestures — shape + start position", systemImage: "mappin.and.ellipse")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsSlider(
                label: "Shape Confidence",
                value: $appState.recognitionSettings.locationConfidence,
                range: 0.4...0.95,
                help: confidenceHelp(appState.recognitionSettings.locationConfidence)
            )

            SettingsSlider(
                label: "Minimum Length",
                value: $appState.recognitionSettings.locationMinLength,
                range: 0.1...1.0,
                help: minLengthHelp(appState.recognitionSettings.locationMinLength)
            )

            SettingsSlider(
                label: "Position Tolerance",
                value: $appState.recognitionSettings.locationRadius,
                range: 0.05...0.5,
                help: locationRadiusHelp(appState.recognitionSettings.locationRadius)
            )

            SettingsSlider(
                label: "Multi-Tap Window",
                value: $appState.recognitionSettings.zoneTapWindow,
                range: 0.15...1.0,
                step: 0.05,
                help: zoneTapWindowHelp(appState.recognitionSettings.zoneTapWindow)
            )
        }
    }

    private var continuousSensitivity: some View {
        SettingsSection(title: "CONTINUOUS / PINCH / DIAL") {
            Label("Live movement — swipe, pinch, and dial controls", systemImage: "slider.horizontal.3")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsSlider(
                label: "Lift Rewind",
                value: $appState.recognitionSettings.continuousLiftRewind,
                range: 0.0...0.40,
                step: 0.02,
                help: liftRewindHelp(appState.recognitionSettings.continuousLiftRewind)
            )

            Text("Per-gesture sensitivity is configured in each gesture's settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Help Text

    private func confidenceHelp(_ value: Double) -> String {
        if value < 0.65 { return "Lenient — more matches, higher chance of false positives." }
        if value < 0.82 { return "Balanced — good mix of precision and flexibility." }
        return "Strict — only very precise gestures will match."
    }

    private func minLengthHelp(_ value: Double) -> String {
        if value < 0.3 { return "Short — small gestures are accepted. May catch accidental touches." }
        if value < 0.6 { return "Medium — filters out very short accidental touches." }
        return "Long — only longer, deliberate gestures are recognized."
    }

    private func locationRadiusHelp(_ value: Double) -> String {
        let pct = Int(value * 100)
        if value < 0.12 { return "Tight (\(pct)%) — must start very close to recorded position." }
        if value < 0.25 { return "Normal (\(pct)%) — moderate tolerance around recorded position." }
        return "Wide (\(pct)%) — can start far from recorded position."
    }

    private func zoneTapWindowHelp(_ value: Double) -> String {
        let ms = Int(value * 1000)
        if value < 0.25 { return "\(ms)ms — strict; reduces accidental follow-up taps but requires fast double/triple taps." }
        if value < 0.55 { return "\(ms)ms — balanced; comfortable for most multi-tap rhythms." }
        return "\(ms)ms — relaxed; easy multi-tap but more chance of unintended follow-ups within the window."
    }

    private func liftRewindHelp(_ value: Double) -> String {
        let ms = Int(value * 1000)
        if value < 0.01 { return "Off — no rewind on finger lift." }
        if value < 0.08 { return "\(ms)ms — subtle rewind, undoes tiny last-moment drift." }
        if value < 0.16 { return "\(ms)ms — moderate rewind, good for high-sensitivity gestures." }
        return "\(ms)ms — aggressive rewind, discards more movement before lift."
    }

    private func telemetricItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
