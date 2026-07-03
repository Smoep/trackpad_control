import Foundation

/// Normalizes gesture paths for comparison.
/// Resamples to fixed point count, normalizes to unit bounding box, computes direction vectors.
enum GestureNormalizer {
    static let defaultPointCount = 64
    static let smoothingWindow = 9

    /// Moving-average smoothing over the raw path to cancel per-finger jitter.
    /// Centered window; endpoints use the available neighbors. Position/timestamp
    /// preserved. No-op for paths shorter than 3 points or window <= 1.
    static func smooth(_ points: [PathPoint], window: Int = smoothingWindow) -> [PathPoint] {
        guard window > 1, points.count >= 3 else { return points }
        let half = window / 2
        return points.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(points.count - 1, i + half)
            let seg = points[lo...hi]
            let n = Double(seg.count)
            let sx = seg.reduce(0) { $0 + $1.x } / n
            let sy = seg.reduce(0) { $0 + $1.y } / n
            return PathPoint(x: sx, y: sy, timestamp: points[i].timestamp)
        }
    }

    /// Resample a path to exactly N evenly-spaced points along its length.
    static func resample(_ points: [PathPoint], to count: Int = defaultPointCount) -> [PathPoint] {
        guard points.count >= 2 else { return points }

        let totalLength = pathLength(points)
        guard totalLength > 0 else { return points }

        let interval = totalLength / Double(count - 1)
        // Work on a mutable copy so we can insert interpolated points
        var src = points
        var resampled: [PathPoint] = [src[0]]
        var accumulated: Double = 0
        var j = 1

        while j < src.count && resampled.count < count {
            let prev = src[j - 1]
            let curr = src[j]
            let segLen = distance(prev, curr)

            if accumulated + segLen >= interval {
                let ratio = (interval - accumulated) / segLen
                let nx = prev.x + ratio * (curr.x - prev.x)
                let ny = prev.y + ratio * (curr.y - prev.y)
                let nt = prev.timestamp + ratio * (curr.timestamp - prev.timestamp)
                let pt = PathPoint(x: nx, y: ny, timestamp: nt)
                resampled.append(pt)
                // Insert interpolated point into source so next iteration
                // measures from HERE, not from the original segment start
                src.insert(pt, at: j)
                accumulated = 0
                j += 1
            } else {
                accumulated += segLen
                j += 1
            }
        }

        // Fill remaining if numerical issues
        while resampled.count < count, let last = resampled.last {
            resampled.append(last)
        }

        return Array(resampled.prefix(count))
    }

    /// Normalize coordinates to unit bounding box [0,1] × [0,1] preserving aspect ratio.
    static func normalize(_ points: [PathPoint]) -> [PathPoint] {
        guard !points.isEmpty else { return points }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!

        let w = maxX - minX
        let h = maxY - minY
        let scale = max(w, h)

        guard scale > 0.001 else {
            // Point or near-point gesture — center it
            return points.map { PathPoint(x: 0.5, y: 0.5, timestamp: $0.timestamp) }
        }

        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2

        return points.map { pt in
            PathPoint(
                x: (pt.x - cx) / scale + 0.5,
                y: (pt.y - cy) / scale + 0.5,
                timestamp: pt.timestamp
            )
        }
    }

    /// Compute direction angles between consecutive points (in radians, 0 to 2π).
    static func directionAngles(_ points: [PathPoint]) -> [Double] {
        guard points.count >= 2 else { return [] }
        var angles: [Double] = []
        for i in 1..<points.count {
            let dx = points[i].x - points[i-1].x
            let dy = points[i].y - points[i-1].y
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            angles.append(angle)
        }
        return angles
    }

    /// Full normalization pipeline: resample → normalize → return.
    static func process(_ points: [PathPoint], resampleCount: Int = defaultPointCount) -> [PathPoint] {
        let resampled = resample(points, to: resampleCount)
        return normalize(resampled)
    }

    // MARK: - Helpers

    static func pathLength(_ points: [PathPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var len: Double = 0
        for i in 1..<points.count {
            len += distance(points[i-1], points[i])
        }
        return len
    }

    static func distance(_ a: PathPoint, _ b: PathPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
