import SwiftUI
import UniformTypeIdentifiers

struct AdvancedView: View {
    @State private var appState = AppState.shared
    @State private var launchAtLogin = UserDefaults.standard.bool(forKey: "adv_launchAtLogin")
    @State private var pauseWhileTyping = UserDefaults.standard.object(forKey: "adv_pauseWhileTyping") != nil ? UserDefaults.standard.bool(forKey: "adv_pauseWhileTyping") : true
    @State private var typingPauseWindow = UserDefaults.standard.object(forKey: "adv_typingPauseWindow") != nil ? UserDefaults.standard.double(forKey: "adv_typingPauseWindow") : 0.7
    @State private var excludedApps: [String] = (UserDefaults.standard.array(forKey: "adv_excludedApps") as? [String]) ?? []
    @State private var diagnosticsEnabled = UserDefaults.standard.bool(forKey: "adv_diagnostics")

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                generalSection
                exclusionsSection
                dataSection
            }
            .padding()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection(title: "GENERAL") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .help("Automatically start Trackpad Control when you log in.")
                .onChange(of: launchAtLogin) { _, val in
                    UserDefaults.standard.set(val, forKey: "adv_launchAtLogin")
                }

            Toggle("Pause while typing", isOn: $pauseWhileTyping)
                .toggleStyle(.switch)
                .help("Temporarily ignore gestures while typing to prevent accidental triggers.")
                .onChange(of: pauseWhileTyping) { _, val in
                    UserDefaults.standard.set(val, forKey: "adv_pauseWhileTyping")
                }

            SettingsSlider(
                label: "Typing pause window",
                value: $typingPauseWindow,
                range: 0.1...1.5,
                step: 0.05,
                help: "Gestures are ignored for this long after typing unless an explicit layer key is held.",
                displayValue: { String(format: "%.2fs", $0) }
            )
            .disabled(!pauseWhileTyping)
            .opacity(pauseWhileTyping ? 1 : 0.45)
            .onChange(of: typingPauseWindow) { _, val in
                UserDefaults.standard.set(val, forKey: "adv_typingPauseWindow")
            }

            Toggle("Enable diagnostics log", isOn: $diagnosticsEnabled)
                .toggleStyle(.switch)
                .help("Log gesture captures, match scores, and trigger executions for debugging.")
                .onChange(of: diagnosticsEnabled) { _, val in
                    UserDefaults.standard.set(val, forKey: "adv_diagnostics")
                }

            if diagnosticsEnabled {
                HStack {
                    Text("~/Library/Application Support/TrackpadControl/tc-debug.log")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear Log") {
                        let path = NSHomeDirectory() + "/Library/Application Support/TrackpadControl/tc-debug.log"
                        try? "".write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    .font(.caption2)
                    .help("Erase the diagnostics log file so the next test starts clean.")
                }
            }
        }
    }

    // MARK: - Exclusions

    private var exclusionsSection: some View {
        SettingsSection(title: "APP EXCLUSIONS") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gestures will be ignored in these applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if excludedApps.isEmpty {
                    Text("No excluded apps")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(excludedApps, id: \.self) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications/\(app).app"))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app)
                            Spacer()
                            Button {
                                excludedApps.removeAll { $0 == app }
                                UserDefaults.standard.set(excludedApps, forKey: "adv_excludedApps")
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button("Add App…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url {
                        let name = url.deletingPathExtension().lastPathComponent
                        if !excludedApps.contains(name) {
                            excludedApps.append(name)
                            UserDefaults.standard.set(excludedApps, forKey: "adv_excludedApps")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection(title: "DATA") {
            HStack(spacing: 8) {
                Button("Export…") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "gestures.json"
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = GestureStore.shared.exportData() {
                        try? data.write(to: url)
                    }
                }
                .help("Export all gestures to a JSON file.")

                Button("Import…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? Data(contentsOf: url) {
                        try? GestureStore.shared.importData(data)
                    }
                }
                .help("Import gestures from a JSON file.")

                Spacer()

                Button("Reset Settings") {
                    let settings = AppState.shared.recognitionSettings
                    settings.discreteConfidence = 0.80
                    settings.discreteMinLength = 0.5
                    settings.locationConfidence = 0.75
                    settings.locationMinLength = 0.3
                    settings.locationRadius = 0.20
                    settings.continuousLiftRewind = 0.08
                    settings.layer1Key = .fn
                    settings.layer2Key = .fn
                    settings.layer3Key = .alwaysOn
                    settings.layer4Key = .alwaysOn
                    settings.layer5Key = .alwaysOn
                }
                .foregroundStyle(.red)
                .help("Reset all recognition settings to defaults.")
            }
        }
    }
}
