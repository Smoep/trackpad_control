import SwiftUI

// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Settings Slider

struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    let help: String
    var displayValue: ((Double) -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(displayValue?(value) ?? String(format: "%.0f%%", value * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Slider(value: $value, in: range, step: step)
                .tint(.blue)

            Text(help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
