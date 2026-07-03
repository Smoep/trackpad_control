import Foundation

struct GestureSample: Codable, Identifiable, Sendable {
    var id = UUID()
    /// Centroid path (averaged across fingers) — used for matching
    var pathPoints: [PathPoint]
    /// Per-finger paths — used for rendering
    var fingerPaths: [[PathPoint]]
    var fingerCount: Int
    var duration: TimeInterval
    var createdAt: Date = Date()

    var startPoint: PathPoint? { pathPoints.first }
    var endPoint: PathPoint? { pathPoints.last }

    init(pathPoints: [PathPoint], fingerPaths: [[PathPoint]] = [], fingerCount: Int, duration: TimeInterval) {
        self.pathPoints = pathPoints
        self.fingerPaths = fingerPaths.isEmpty ? [pathPoints] : fingerPaths
        self.fingerCount = fingerCount
        self.duration = duration
    }

    /// Build a centroid path by averaging all finger positions at each timestamp
    static func buildCentroidPath(from fingerPaths: [[PathPoint]]) -> [PathPoint] {
        var all: [PathPoint] = []
        for pts in fingerPaths { all.append(contentsOf: pts) }
        all.sort { $0.timestamp < $1.timestamp }

        var merged: [PathPoint] = []
        var i = 0
        while i < all.count {
            var sx = all[i].x, sy = all[i].y, st = all[i].timestamp, c = 1.0
            var j = i + 1
            while j < all.count && all[j].timestamp - all[i].timestamp < 0.005 {
                sx += all[j].x; sy += all[j].y; st += all[j].timestamp; c += 1; j += 1
            }
            merged.append(PathPoint(x: sx / c, y: sy / c, timestamp: st / c))
            i = j
        }
        return merged
    }
}
