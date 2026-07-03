import SwiftUI

struct GestureSampleCardView: View {
    let sample: GestureSample
    let onDelete: () -> Void
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Mini thumbnail
            GestureThumbnailView(sample: sample)
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))

            // Info
            VStack(alignment: .leading, spacing: 1) {
                Text("\(sample.fingerCount) finger\(sample.fingerCount == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))

                if let start = sample.startPoint, let end = sample.endPoint {
                    Text(zoneName(start) + " → " + zoneName(end))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(String(format: "%.2fs", sample.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.3)
            .help("Delete sample")
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect() }
    }

    private func zoneName(_ point: PathPoint) -> String {
        let col = point.x < 0.33 ? "left" : point.x > 0.67 ? "right" : "center"
        let row = point.y < 0.33 ? "bottom" : point.y > 0.67 ? "top" : "center"
        if col == "center" && row == "center" { return "center" }
        if col == "center" { return row }
        if row == "center" { return col }
        return "\(row)-\(col)"
    }
}
