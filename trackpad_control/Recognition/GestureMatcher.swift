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

    /// Diagnostics of a corner tie-break decision (see `cornerTieBreak`).
    struct TieBreak {
        let liveCorners: Int
        let promoted: String
        let demoted: String
    }

    struct Evaluation {
        /// Every candidate of the finger count, scored, tie-break applied, best first.
        let all: [MatchResult]
        /// `all` filtered by the per-type confidence threshold.
        let confident: [MatchResult]
        let tieBreak: TieBreak?

        static let empty = Evaluation(all: [], confident: [], tieBreak: nil)
    }

    /// Match a performed gesture against all enabled gestures.
    /// Returns candidates sorted by score (best first), filtered by confidence threshold.
    static func match(
        performedPath: [PathPoint],
        fingerCount: Int,
        gestures: [GestureDefinition],
        settings: RecognitionSettings
    ) -> [MatchResult] {
        evaluate(performedPath: performedPath, fingerCount: fingerCount, gestures: gestures, settings: settings).confident
    }

    /// Like match() but returns ALL gesture scores without confidence threshold filtering.
    /// Used for telemetrics display.
    static func matchAll(
        performedPath: [PathPoint],
        fingerCount: Int,
        gestures: [GestureDefinition],
        settings: RecognitionSettings
    ) -> [MatchResult] {
        evaluate(performedPath: performedPath, fingerCount: fingerCount, gestures: gestures, settings: settings).all
    }

    /// Score every enabled shape gesture of this finger count. The corner tie-break runs on
    /// the full ranking, before threshold filtering, so a demoted top-1 can drop below the
    /// threshold instead of firing — this is the order validated offline
    /// (scripts/matcher_experiment.py `rank`, scripts/pipeline_eval.py).
    static func evaluate(
        performedPath: [PathPoint],
        fingerCount: Int,
        gestures: [GestureDefinition],
        settings: RecognitionSettings
    ) -> Evaluation {

        // Quick filter: minimum path length (use lowest threshold across types)
        let length = GestureNormalizer.pathLength(performedPath)
        let minLength = min(settings.discreteMinLength, settings.locationMinLength) * 0.1
        guard length >= minLength else { return .empty }

        // Resample only — no position normalization. Angular matching is inherently
        // position/scale independent. Smooth first to cancel per-finger jitter.
        let resampled = GestureNormalizer.resample(GestureNormalizer.smooth(performedPath))
        let performedAngles = GestureNormalizer.directionAngles(resampled)
        guard !performedAngles.isEmpty else { return .empty }

        var results: [MatchResult] = []

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
                let samplePath = primaryPath(of: sample)
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
                // Net-direction (mirror) penalty: two shapes can have similar
                // per-segment angles yet point in mirror-opposite net directions
                // (e.g. up-left TLQ vs up-right TRQ). Penalize by how far the
                // overall start→end direction disagrees, so mirrored gestures
                // separate cleanly instead of both scoring "up-ish".
                let netFactor = netDirectionFactor(resampled, resampledSample)
                let openClosedFactor = openClosedPathFactor(resampled, resampledSample)
                let finalScore = score * max(0, turnPenalty) * netFactor * openClosedFactor

                if finalScore > bestScore {
                    bestScore = finalScore
                    bestIdx = idx
                }
            }

            results.append(MatchResult(gesture: gesture, score: bestScore, bestSampleIndex: bestIdx))
        }

        results.sort { $0.score > $1.score }
        let tieBreak = cornerTieBreak(&results, performedPath: performedPath)
        let confident = results.filter {
            $0.score >= ($0.gesture.inputType == .zoneTap ? settings.locationConfidence : settings.discreteConfidence)
        }
        return Evaluation(all: results, confident: confident, tieBreak: tieBreak)
    }

    /// Longest individual finger path of a stored sample, not the centroid.
    /// Falls back to pathPoints if fingerPaths is empty.
    private static func primaryPath(of sample: GestureSample) -> [PathPoint] {
        if sample.fingerPaths.count > 1 {
            return sample.fingerPaths.max(by: { $0.count < $1.count }) ?? sample.pathPoints
        }
        return sample.pathPoints
    }

    // MARK: - Corner tie-break

    // 2026-09-04: L-shapes with a short second leg (12–18 % of the path) score almost the same
    // as the straight stroke they start with, because the matcher weights by leg length —
    // e.g. Window - BLQ vs Close tab, Kopy vs Mission C. Five owner-labelled live strokes: four
    // were suppressed as ambiguous or fired the straight rival (one confident wrong Close tab).
    // When the top two are within `tieBreakMargin` and their recordings disagree on how many
    // sharp corners they have, let the live corner count decide and demote the loser.
    // Offline: 4/4 labelled strokes fixed, 0 of the other live strokes change, leave-one-out
    // ambiguous 3 → 0 (docs/gesture-recognition.md §8.3, scripts/matcher_experiment.py).
    private static let tieBreakMargin = 0.12
    private static let tieBreakLoserFactor = 0.80
    private static let cornerSharpDegrees = 40.0
    private static let cornerWindowShare = 0.15   // heading measured over this share of the path each side
    private static let cornerMinTailShare = 0.10  // corners closer than this to the end are hooks, not legs

    private static func cornerTieBreak(_ results: inout [MatchResult], performedPath: [PathPoint]) -> TieBreak? {
        guard results.count >= 2, results[0].score - results[1].score < tieBreakMargin else { return nil }
        let a = results[0], b = results[1]
        let ta = typicalCorners(of: a.gesture), tb = typicalCorners(of: b.gesture)
        guard ta != tb else { return nil }
        let live = sharpCorners(performedPath)
        let da = abs(live - ta), db = abs(live - tb)
        guard da != db else { return nil }
        let loser = da < db ? 1 : 0
        let winner = 1 - loser
        results[loser] = MatchResult(gesture: results[loser].gesture,
                                     score: results[loser].score * tieBreakLoserFactor,
                                     bestSampleIndex: results[loser].bestSampleIndex)
        let info = TieBreak(liveCorners: live, promoted: results[winner].gesture.name, demoted: results[loser].gesture.name)
        results.sort { $0.score > $1.score }
        return info
    }

    /// Median sharp-corner count over a gesture's recordings.
    private static func typicalCorners(of gesture: GestureDefinition) -> Int {
        let counts = gesture.samples.map { primaryPath(of: $0) }
            .filter { $0.count >= 2 }
            .map { sharpCorners($0) }
            .sorted()
        return counts.isEmpty ? 0 : counts[counts.count / 2]
    }

    /// Count real L-corners: a turn > 40° in the smoothed heading (same detector as
    /// `countTurns`) whose heading change measured over 15 % of the path on each side is
    /// still ≥ 40°, and that leaves ≥ 10 % of the path after it. Gentle curvature and end
    /// hooks (the 1–4° curl on Close-tab takes) do not count.
    static func sharpCorners(_ path: [PathPoint]) -> Int {
        let rs = GestureNormalizer.resample(GestureNormalizer.smooth(path))
        let n = rs.count
        guard n >= 4 else { return 0 }
        let w = max(2, Int(Double(n) * cornerWindowShare))
        let total = GestureNormalizer.pathLength(rs)
        guard total > 1e-9 else { return 0 }
        var count = 0
        for c in cornerIndices(GestureNormalizer.directionAngles(rs)) {
            let a = Array(rs[max(0, c - w)...c])
            let b = Array(rs[c..<min(n, c + w + 1)])
            guard a.count >= 2, b.count >= 2 else { continue }
            let ha = atan2(a[a.count - 1].y - a[0].y, a[a.count - 1].x - a[0].x)
            let hb = atan2(b[b.count - 1].y - b[0].y, b[b.count - 1].x - b[0].x)
            var d = abs(hb - ha)
            d = min(d, 2 * .pi - d)
            let tailShare = GestureNormalizer.pathLength(Array(rs[c...])) / total
            if d * 180 / .pi >= cornerSharpDegrees && tailShare >= cornerMinTailShare {
                count += 1
            }
        }
        return count
    }

    /// Indices where the smoothed heading turns more than 40°. Same smoothing,
    /// threshold and sampling step as `countTurns`, but returns the positions.
    private static func cornerIndices(_ angles: [Double]) -> [Int] {
        guard angles.count >= 4 else { return [] }
        let smoothed = smoothedAngles(angles)
        let threshold = cornerSharpDegrees * .pi / 180.0
        let step = max(1, smoothed.count / 16)
        var lastDir = smoothed[0]
        var out: [Int] = []
        for i in stride(from: step, to: smoothed.count, by: step) {
            var diff = abs(smoothed[i] - lastDir)
            if diff > .pi { diff = 2 * .pi - diff }
            if diff > threshold {
                out.append(i)
                lastDir = smoothed[i]
            }
        }
        return out
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
    ///
    /// Per-segment angle differences below `angularDeadband` are treated as a
    /// perfect match. Real strokes always carry small hand jitter, so forgiving
    /// tiny per-segment disagreements lifts the confidence of a correct-but-
    /// imperfect stroke toward 1.0 without lifting genuinely different gestures
    /// (their per-segment diffs stay well above the deadband). Validated via
    /// recognizer_eval.py: raises avg correct confidence and confident-count with
    /// no new confusions; 20° over-forgives and introduces one, so 15° is the cap.
    private static let angularDeadband = 15.0 * .pi / 180.0
    private static func angularSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }

        var totalDelta: Double = 0
        for i in 0..<count {
            var diff = abs(a[i] - b[i])
            if diff > .pi { diff = 2 * .pi - diff }
            diff = max(0, diff - angularDeadband)
            totalDelta += diff
        }
        let avgDelta = totalDelta / Double(count)
        // avgDelta in [0, π]: 0 → 1.0 (perfect), π → 0.0 (opposite)
        return max(0, 1.0 - avgDelta / .pi)
    }

    /// Multiplicative penalty (0–1) based on how far two gestures' overall
    /// start→end directions disagree. 1.0 when they point the same way, lower as
    /// they diverge, driven to 0 for opposite directions. This separates
    /// mirror-image shapes (e.g. up-left vs up-right diagonals) that the
    /// per-segment angular similarity alone scores almost equally because both
    /// are "mostly upward". Weight tuned against the sample DB (recognizer_eval.py):
    /// paired with the 15° angular deadband, weight 2.0 gives leave-one-out top-1
    /// 97.1% → 98.1% and widens tight pairs (e.g. Window - BLQ vs Window - LD
    /// margin 0.376 → 0.421) with no new confusions. Weight 3.0 over-separates and
    /// breaks Window - C vs Close tab, so 2.0 is the ceiling.
    private static let netDirectionWeight = 2.0
    // 2026-09-04 "netgate": for there-and-back strokes (Windows - C, and 4 of 5 Open Safari
    // takes) the start→end vector is a few hundredths long and its direction is noise, so
    // this factor zeroed genuine matches (Windows - C leave-one-out 2/6). When both paths
    // are that closed, skip the factor; open-vs-closed separation is still done by
    // `openClosedPathFactor`. Offline: fixes those, 0 live strokes change (docs §8.2).
    private static let netGateOpenness = 0.15
    private static func netDirectionFactor(_ a: [PathPoint], _ b: [PathPoint]) -> Double {
        if pathOpenness(a) < netGateOpenness && pathOpenness(b) < netGateOpenness { return 1.0 }
        guard let a0 = a.first, let a1 = a.last, let b0 = b.first, let b1 = b.last else { return 1.0 }
        let adx = a1.x - a0.x, ady = a1.y - a0.y
        let bdx = b1.x - b0.x, bdy = b1.y - b0.y
        let am = (adx * adx + ady * ady).squareRoot()
        let bm = (bdx * bdx + bdy * bdy).squareRoot()
        guard am > 1e-9, bm > 1e-9 else { return 1.0 }
        let cosine = max(-1.0, min(1.0, (adx * bdx + ady * bdy) / (am * bm)))
        let angle = acos(cosine) // 0…π
        return max(0.0, 1.0 - (angle / .pi) * netDirectionWeight)
    }

    /// Penalize comparisons between open strokes and closed-loop strokes. A
    /// circular/loop gesture can share many local segment directions with a
    /// curved quadrant stroke, but its endpoint returns near the start. The
    /// openness ratio (net displacement / path length) captures that distinction
    /// without making the matcher position- or scale-dependent.
    private static func openClosedPathFactor(_ a: [PathPoint], _ b: [PathPoint]) -> Double {
        let ao = pathOpenness(a)
        let bo = pathOpenness(b)
        let openThreshold = 0.35
        let closedThreshold = 0.12
        if (ao >= openThreshold && bo <= closedThreshold) || (bo >= openThreshold && ao <= closedThreshold) {
            return 0.35
        }
        return 1.0
    }

    private static func pathOpenness(_ path: [PathPoint]) -> Double {
        guard let first = path.first, let last = path.last else { return 0 }
        let length = GestureNormalizer.pathLength(path)
        guard length > 1e-9 else { return 0 }
        return hypot(last.x - first.x, last.y - first.y) / length
    }

    // MARK: - Structural Complexity

    /// Count significant direction changes (turns) in an angle sequence.
    /// A turn is detected when the smoothed direction shifts by more than 40°.
    private static func countTurns(_ angles: [Double]) -> Int {
        guard angles.count >= 4 else { return 0 }
        let smoothed = smoothedAngles(angles)

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

    /// Sliding-window circular mean of a heading sequence (window = count/12, min 3).
    private static func smoothedAngles(_ angles: [Double]) -> [Double] {
        let windowSize = max(3, angles.count / 12)
        var smoothed: [Double] = []
        smoothed.reserveCapacity(angles.count)
        for i in 0..<angles.count {
            let start = max(0, i - windowSize / 2)
            let end = min(angles.count, i + windowSize / 2 + 1)
            var sx = 0.0, sy = 0.0
            for j in start..<end {
                sx += cos(angles[j])
                sy += sin(angles[j])
            }
            smoothed.append(atan2(sy / Double(end - start), sx / Double(end - start)))
        }
        return smoothed
    }
}
