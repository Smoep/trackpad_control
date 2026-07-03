import SwiftUI

struct GestureRowView: View {
    let gesture: GestureDefinition
    @State private var appState = AppState.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail — direction arrow for continuous family, grid icon for zone tap, gesture trace for others
            if gesture.inputType.isContinuousFamily {
                ZStack {
                    Image(systemName: gesture.inputType == .continuous
                          ? (gesture.continuousAxis == .horizontal ? "arrow.left.arrow.right" : "arrow.up.arrow.down")
                          : gesture.inputType.icon)
                        .font(.title2)
                        .foregroundStyle(.blue.opacity(0.5))
                }
                .frame(width: 80, height: 56)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else if gesture.inputType == .zoneTap {
                Canvas { context, size in
                    let cols = 3, rows = 3
                    let gap: CGFloat = 2
                    let inset: CGFloat = 8
                    let cellW = (size.width - inset * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
                    let cellH = (size.height - inset * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)
                    let allZones: [[TrackpadZone]] = [
                        [.topLeft, .topCenter, .topRight],
                        [.centerLeft, .center, .centerRight],
                        [.bottomLeft, .bottomCenter, .bottomRight]
                    ]
                    for row in 0..<rows {
                        for col in 0..<cols {
                            let zone = allZones[row][col]
                            let x = inset + CGFloat(col) * (cellW + gap)
                            let y = inset + CGFloat(row) * (cellH + gap)
                            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                            let path = RoundedRectangle(cornerRadius: 3).path(in: rect)
                            if gesture.activeZones.contains(zone) {
                                context.fill(path, with: .color(.blue.opacity(0.4)))
                                context.stroke(path, with: .color(.blue.opacity(0.6)), lineWidth: 1)
                            } else {
                                context.fill(path, with: .color(.primary.opacity(0.05)))
                                context.stroke(path, with: .color(.primary.opacity(0.1)), lineWidth: 0.5)
                            }
                        }
                    }
                }
                .frame(width: 80, height: 56)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                GestureThumbnailView(sample: gesture.samples.first)
                    .frame(width: 80, height: 56)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.name.isEmpty ? "Untitled" : gesture.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if gesture.inputType.isContinuousFamily {
                        Text("\(gesture.fingerCount)F \(gesture.inputType == .continuous ? gesture.continuousAxis.rawValue.lowercased() : gesture.inputType.rawValue.lowercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(gesture.continuousControl.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if gesture.inputType == .zoneTap {
                        let zoneNames = gesture.activeZones.map(\.rawValue).sorted().joined(separator: ", ")
                        Text("\(gesture.fingerCount)F \(gesture.tapCount == 1 ? "" : "\(gesture.tapCount)x ")tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(gesture.triggerAction.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(gesture.triggerAction.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Finger count badge
            Text("\(gesture.fingerCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.1), in: Capsule())
                .foregroundStyle(.blue)

            // Toggle
            Toggle("", isOn: Binding(
                get: { gesture.isEnabled },
                set: { _ in appState.toggleGesture(gesture) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(gesture.isEnabled ? "Disable gesture" : "Enable gesture")

            // Delete
            Button {
                appState.deleteGesture(gesture)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Delete gesture")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            appState.editGesture(gesture)
        }
    }
}

// MARK: - Gesture Thumbnail

struct GestureThumbnailView: View {
    let sample: GestureSample?

    var body: some View {
        Canvas { context, size in
            guard let sample, !sample.pathPoints.isEmpty else {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let text = Text("?").font(.caption).foregroundStyle(.tertiary)
                context.draw(text, at: center)
                return
            }

            FingerPathRenderer.draw(
                paths: sample.fingerPaths,
                in: context,
                size: size,
                padding: 4,
                lineWidth: 1.5,
                opacity: 0.6,
                autoFit: true
            )
        }
    }
}
