import Foundation

/// Matches performed gestures against saved gesture definitions.
/// Pure angular matching inspired by GestureSign: resample to equal points,
/// compare direction angle sequences index-by-index.
/// Position and scale independent — only direction matters.
enum GestureMatcher {

    struct MatchResult {
        let gesture: GestureDefinition
        let score: Double         // 0.0–1.0
        let bestSampleIndex: Int
    }

    /// Match a performed gesture against all enabled gestures.
    /// Returns candidates sorted by score (best first), filtered by confidence threshold.
    static func match(
        performedPath: [PathPoint],
        fingerCount: Int,
        gestures: [GestureDefinition],
        settings: RecognitionSettings
    ) -> [MatchResult] {

        // Quick filter: minimum path length (use lowest threshold across types)
        let length = GestureNormalizer.pathLength(performedPath)
        let minLength = min(settings.discreteMinLength, settings.locationMinLength) * 0.1
        guard length >= minLength else { return [] }

        // Resample only — no position normalization. Angular matching is inherently
        // position/scale independent. Smooth first to cancel per-finger jitter.
        let resampled = GestureNormalizer.resample(GestureNormalizer.smooth(performedPath))
        let performedAngles = GestureNormalizer.directionAngles(resampled)
        guard !performedAngles.isEmpty else { return [] }

        var results: [MatchResult] = []

        // Start position for zone filtering
        let startX = performedPath.first?.x ?? 0
        let startY = performedPath.first?.y ?? 0

        for gesture in gestures where gesture.isEnabled && !gesture.samples.isEmpty {
            // Skip continuous inputs — they don't use pattern matching
            guard gesture.inputType != .continuous else { continue }

            // Finger count must match exactly
            guard gesture.fingerCount == fingerCount else { continue }

            // Per-type minimum length filter
            let typeMinLength = gesture.inputType == .zoneTap ? settings.locationMinLength : settings.discreteMinLength
            guard length >= typeMinLength * 0.1 else { continue }

            // Zone tap inputs are handled separately in TCM (tap detection)
            // They don't use shape matching — skip them here
            if gesture.inputType == .zoneTap { continue }

            var bestScore: Double = 0
            var bestIdx = 0

            for (idx, sample) in gesture.samples.enumerated() {
                // Use longest individual finger path from the stored sample,
                // not the centroid. Falls back to pathPoints if fingerPaths is empty.
                let samplePath: [PathPoint]
                if sample.fingerPaths.count > 1 {
                    samplePath = sample.fingerPaths.max(by: { $0.count < $1.count }) ?? sample.pathPoints
                } else {
                    samplePath = sample.pathPoints
                }
                let resampledSample = GestureNormalizer.resample(GestureNormalizer.smooth(samplePath))
                let sampleAngles = GestureNormalizer.directionAngles(resampledSample)
                guard !sampleAngles.isEmpty else { continue }

                let score = angularSimilarity(performedAngles, sampleAngles)

                // Penalize if the gestures have different structural complexity
                // (different number of significant direction changes / turns)
                let perfTurns = countTurns(performedAngles)
                let sampTurns = countTurns(sampleAngles)
                let turnDiff = abs(perfTurns - sampTurns)
                // Each extra turn reduces score by 15%
                let turnPenalty = 1.0 - Double(turnDiff) * 0.15
                let finalScore = score * max(0, turnPenalty)

                if finalScore > bestScore {
                    bestScore = finalScore
                    bestIdx = idx
                }
            }

            if bestScore >= (gesture.inputType == .zoneTap ? settings.locationConfidence : settings.discreteConfidence) {
                results.append(MatchResult(gesture: gesture, score: bestScore, bestSampleIndex: bestIdx))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// Like match() but returns ALL gesture scores without confidence threshold filtering.
    /// Used for telemetrics display.
    static func matchAll(
        performedPath: [PathPoint],
        fingerCount: Int,
        gestures: [GestureDefinition],
        settings: RecognitionSettings
    ) -> [MatchResult] {
        let length = GestureNormalizer.pathLength(performedPath)
        let minLength = min(settings.discreteMinLength, settings.locationMinLength) * 0.1
        guard length >= minLength else { return [] }

        let resampled = GestureNormalizer.resample(GestureNormalizer.smooth(performedPath))
        let performedAngles = GestureNormalizer.directionAngles(resampled)
        guard !performedAngles.isEmpty else { return [] }

        var results: [MatchResult] = []

        let startX = performedPath.first?.x ?? 0
        let startY = performedPath.first?.y ?? 0

        for gesture in gestures where gesture.isEnabled && !gesture.samples.isEmpty {
            guard gesture.inputType != .continuous else { continue }
            guard gesture.fingerCount == fingerCount else { continue }
            if gesture.inputType == .zoneTap { continue }

            var bestScore: Double = 0
            var bestIdx = 0

            for (idx, sample) in gesture.samples.enumerated() {
                let samplePath: [PathPoint]
                if sample.fingerPaths.count > 1 {
                    samplePath = sample.fingerPaths.max(by: { $0.count < $1.count }) ?? sample.pathPoints
                } else {
                    samplePath = sample.pathPoints
                }
                let resampledSample = GestureNormalizer.resample(GestureNormalizer.smooth(samplePath))
                let sampleAngles = GestureNormalizer.directionAngles(resampledSample)
                guard !sampleAngles.isEmpty else { continue }

                let score = angularSimilarity(performedAngles, sampleAngles)
                let perfTurns = countTurns(performedAngles)
                let sampTurns = countTurns(sampleAngles)
                let turnDiff = abs(perfTurns - sampTurns)
                let turnPenalty = 1.0 - Double(turnDiff) * 0.15
                let finalScore = score * max(0, turnPenalty)

                if finalScore > bestScore {
                    bestScore = finalScore
                    bestIdx = idx
                }
            }

            results.append(MatchResult(gesture: gesture, score: bestScore, bestSampleIndex: bestIdx))
        }

        return results.sorted { $0.score > $1.score }
    }

    // MARK: - Angular Similarity

    /// Check if a performed gesture starts close enough to a location gesture's recorded position.
    /// Uses adaptive per-axis tolerance: strict on axes where samples cluster, loose where they spread.
    /// `radius` is the base tolerance from settings. Axes with wider sample spread get larger tolerance.
    private static func isStartPositionClose(x: Double, y: Double, gesture: GestureDefinition, radius: Double) -> Bool {
        let starts = gesture.samples.compactMap { sample -> (Double, Double)? in
            let path: [PathPoint]
            if sample.fingerPaths.count > 1 {
                path = sample.fingerPaths.max(by: { $0.count < $1.count }) ?? sample.pathPoints
            } else {
                path = sample.pathPoints
            }
            guard let first = path.first else { return nil }
            return (first.x, first.y)
        }
        guard !starts.isEmpty else { return false }
        let avgX = starts.map(\.0).reduce(0, +) / Double(starts.count)
        let avgY = starts.map(\.1).reduce(0, +) / Double(starts.count)
        // Per-axis tolerance: base radius + half the spread of recorded samples.
        // If samples are all at x=0.85 (tight), toleranceX ≈ radius.
        // If samples spread y=0.2...0.8 (wide), toleranceY ≈ radius + 0.3 → very loose.
        let xValues = starts.map(\.0)
        let yValues = starts.map(\.1)
        let halfSpreadX = (xValues.max()! - xValues.min()!) / 2
        let halfSpreadY = (yValues.max()! - yValues.min()!) / 2
        let toleranceX = halfSpreadX + radius
        let toleranceY = halfSpreadY + radius
        return abs(x - avgX) < toleranceX && abs(y - avgY) < toleranceY
    }

    /// Compute the average start position across all recorded samples of a gesture.
    /// Returns nil if no samples have path data.
    static func averageStartPosition(of gesture: GestureDefinition) -> (x: Double, y: Double)? {
        let starts = gesture.samples.compactMap { sample -> (Double, Double)? in
            let path: [PathPoint]
            if sample.fingerPaths.count > 1 {
                path = sample.fingerPaths.max(by: { $0.count < $1.count }) ?? sample.pathPoints
            } else {
                path = sample.pathPoints
            }
            guard let first = path.first else { return nil }
            return (first.x, first.y)
        }
        guard !starts.isEmpty else { return nil }
        return (starts.map(\.0).reduce(0, +) / Double(starts.count),
                starts.map(\.1).reduce(0, +) / Double(starts.count))
    }

    /// Compare angle sequences index-by-index. Both arrays come from paths
    /// resampled to the same point count, so indices correspond.
    /// Returns 0–1 where 1 = identical direction at every segment.
    private static func angularSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }

        var totalDelta: Double = 0
        for i in 0..<count {
            var diff = abs(a[i] - b[i])
            if diff > .pi { diff = 2 * .pi - diff }
            totalDelta += diff
        }
        let avgDelta = totalDelta / Double(count)
        // avgDelta in [0, π]: 0 → 1.0 (perfect), π → 0.0 (opposite)
        return max(0, 1.0 - avgDelta / .pi)
    }

    // MARK: - Structural Complexity

    /// Count significant direction changes (turns) in an angle sequence.
    /// A turn is detected when the smoothed direction shifts by more than 40°.
    private static func countTurns(_ angles: [Double]) -> Int {
        guard angles.count >= 4 else { return 0 }

        // Smooth angles with a sliding window to filter noise
        let windowSize = max(3, angles.count / 12)
        var smoothed: [Double] = []
        for i in 0..<angles.count {
            let start = max(0, i - windowSize / 2)
            let end = min(angles.count, i + windowSize / 2 + 1)
            // Average using circular mean (via sin/cos)
            var sx = 0.0, sy = 0.0
            for j in start..<end {
                sx += cos(angles[j])
                sy += sin(angles[j])
            }
            smoothed.append(atan2(sy / Double(end - start), sx / Double(end - start)))
        }

        // Count direction changes exceeding 40° threshold
        let threshold = 40.0 * .pi / 180.0
        var turns = 0
        // Sample at intervals to avoid counting the same turn multiple times
        let step = max(1, smoothed.count / 16)
        var lastDir = smoothed[0]
        for i in stride(from: step, to: smoothed.count, by: step) {
            var diff = abs(smoothed[i] - lastDir)
            if diff > .pi { diff = 2 * .pi - diff }
            if diff > threshold {
                turns += 1
                lastDir = smoothed[i]
            }
        }
        return turns
    }
}
