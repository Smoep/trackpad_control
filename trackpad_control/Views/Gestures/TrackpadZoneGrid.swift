import SwiftUI

struct TrackpadZoneGrid: View {
    @Binding var selectedZone: TrackpadZone

    private let zones: [[TrackpadZone]] = [
        [.topLeft, .topCenter, .topRight],
        [.centerLeft, .center, .centerRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(zones, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(row, id: \.self) { zone in
                        zoneCell(zone)
                    }
                }
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func zoneCell(_ zone: TrackpadZone) -> some View {
        let isSelected = zone == selectedZone
        return RoundedRectangle(cornerRadius: 4)
            .fill(isSelected ? Color.blue.opacity(0.3) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { selectedZone = zone }
    }
}

// MARK: - Multi-select variant (used for anchor zone restriction)

/// A 9×9 grid where each cell toggles on/off independently.
/// Cell index = row * 9 + col (row 0 = top, col 0 = left).
/// All 81 cells enabled = no restriction (anchor can start anywhere).
struct TrackpadZoneMultiGrid: View {
    @Binding var enabledZones: Set<Int>

    private let rows = 9
    private let cols = 9

    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(0..<cols, id: \.self) { col in
                        zoneCell(row: row, col: col)
                    }
                }
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func zoneCell(row: Int, col: Int) -> some View {
        let index = row * cols + col
        let isEnabled = enabledZones.contains(index)
        return RoundedRectangle(cornerRadius: 2)
            .fill(isEnabled ? Color.blue.opacity(0.28) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isEnabled ? Color.blue.opacity(0.50) : Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if isEnabled {
                    if enabledZones.count > 1 { enabledZones.remove(index) }
                } else {
                    enabledZones.insert(index)
                }
            }
    }
}
