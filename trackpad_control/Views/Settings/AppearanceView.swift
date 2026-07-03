import SwiftUI

struct AppearanceView: View {
    @State private var appState = AppState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                overlaySection
                traceSection
            }
            .padding()
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        SettingsSection(title: "OVERLAY") {
            SettingsSlider(
                label: "Background Opacity",
                value: $appState.appearanceSettings.overlayBackgroundOpacity,
                range: 0.0...1.0,
                step: 0.05,
                help: "How opaque the overlay background panel appears.",
                displayValue: { String(format: "%d%%", Int($0 * 100)) }
            )
            SettingsSlider(
                label: "Overlay Size",
                value: $appState.appearanceSettings.overlaySize,
                range: 0.5...2.0,
                step: 0.1,
                help: "Scale of the gesture overlay. Trackpad aspect ratio is always maintained.",
                displayValue: { String(format: "%d%%", Int($0 * 100)) }
            )
        }
    }

    // MARK: - Trace

    private var traceSection: some View {
        SettingsSection(title: "GESTURE TRACE") {
            SettingsSlider(
                label: "Trace Thickness",
                value: $appState.appearanceSettings.traceThickness,
                range: 1.0...6.0,
                step: 0.5,
                help: "Width of the drawn gesture path.",
                displayValue: { String(format: "%.1fpt", $0) }
            )

            SettingsSlider(
                label: "Trace Opacity",
                value: $appState.appearanceSettings.traceOpacity,
                range: 0.1...1.0,
                help: "Visibility of the gesture path while drawing."
            )

            Toggle("Show live path during normal use", isOn: $appState.appearanceSettings.showLivePath)
                .toggleStyle(.switch)
                .help("Draw gesture paths on screen as you perform them outside of Settings.")
        }
    }




}
