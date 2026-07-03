import Foundation

@Observable
final class RecognitionSettings {
    private static let d = UserDefaults.standard
    private var isInitialized = false

    var isTracking: Bool = true {
        didSet {
            Self.d.set(isTracking, forKey: "rs_isTracking")
            guard isInitialized else { return }
            if isTracking {
                TouchCaptureManager.shared.start()
            } else {
                TouchCaptureManager.shared.stop()
            }
        }
    }
    // Per-finger-count activation layers (1–5 fingers)
    var layer1Key: LayerActivation = .fn {
        didSet { Self.d.set(layer1Key.rawValue, forKey: "rs_layer1Key") }
    }
    var layer2Key: LayerActivation = .fn {
        didSet { Self.d.set(layer2Key.rawValue, forKey: "rs_layer2Key") }
    }
    var layer3Key: LayerActivation = .alwaysOn {
        didSet { Self.d.set(layer3Key.rawValue, forKey: "rs_layer3Key") }
    }
    var layer4Key: LayerActivation = .alwaysOn {
        didSet { Self.d.set(layer4Key.rawValue, forKey: "rs_layer4Key") }
    }
    var layer5Key: LayerActivation = .alwaysOn {
        didSet { Self.d.set(layer5Key.rawValue, forKey: "rs_layer5Key") }
    }

    func layerKey(for fingerCount: Int) -> LayerActivation {
        switch fingerCount {
        case 1: return layer1Key
        case 2: return layer2Key
        case 3: return layer3Key
        case 4: return layer4Key
        case 5: return layer5Key
        default: return .alwaysOn
        }
    }
    // -- Discrete --
    var discreteConfidence: Double = 0.80 {
        didSet { Self.d.set(discreteConfidence, forKey: "rs_discreteConfidence") }
    }
    var discreteMinLength: Double = 0.5 {
        didSet { Self.d.set(discreteMinLength, forKey: "rs_discreteMinLength") }
    }
    /// Minimum score gap required between the top two *different* confident
    /// discrete candidates. If the gap is smaller, the gesture is treated as
    /// ambiguous ("doesn't fit neatly") and suppressed instead of firing a
    /// coin-flip. Clean gestures separate by >=0.10 in practice; genuine
    /// ambiguity clusters within ~0.02, so 0.06 sits safely between.
    var discreteAmbiguityMargin: Double = 0.06 {
        didSet { Self.d.set(discreteAmbiguityMargin, forKey: "rs_discreteAmbiguityMargin") }
    }
    // -- Location --
    var locationConfidence: Double = 0.75 {
        didSet { Self.d.set(locationConfidence, forKey: "rs_locationConfidence") }
    }
    var locationMinLength: Double = 0.3 {
        didSet { Self.d.set(locationMinLength, forKey: "rs_locationMinLength") }
    }
    var locationRadius: Double = 0.20 {
        didSet { Self.d.set(locationRadius, forKey: "rs_locationRadius") }
    }
    /// Maximum time (seconds) between consecutive zone taps in a multi-tap
    /// sequence. Lower values reduce accidental "follow-up" taps but may make
    /// double/triple taps harder to perform.
    var zoneTapWindow: Double = 0.4 {
        didSet { Self.d.set(zoneTapWindow, forKey: "rs_zoneTapWindow") }
    }
    var anchorActivationDelay: Double = 0.40 {
        didSet { Self.d.set(anchorActivationDelay, forKey: "rs_anchorActivationDelay") }
    }
    /// Cells of a 9×9 trackpad grid that are allowed to start an anchor hold.
    /// Cell index = row * 9 + col, where row 0 = top, col 0 = left.
    /// Defaults to all 81 cells (no restriction). Remove cells to block accidental
    /// activation from a resting palm. An empty set is treated as "all allowed".
    var anchorAllowedZones: Set<Int> = Set(0..<81) {
        didSet {
            let raw = anchorAllowedZones.sorted().map(String.init).joined(separator: ",")
            Self.d.set(raw, forKey: "rs_anchorAllowedZones9")
        }
    }
    // -- Continuous --
    var continuousLiftRewind: Double = 0.08 {
        didSet { Self.d.set(continuousLiftRewind, forKey: "rs_continuousLiftRewind") }
    }
    var testMode: Bool = false {
        didSet { Self.d.set(testMode, forKey: "rs_testMode") }
    }

    init() {
        let d = Self.d
        if d.object(forKey: "rs_isTracking") != nil {
            isTracking = d.bool(forKey: "rs_isTracking")
        }
        for i in 1...5 {
            if let raw = d.string(forKey: "rs_layer\(i)Key"),
               let val = LayerActivation(rawValue: raw) {
                switch i {
                case 1: layer1Key = val
                case 2: layer2Key = val
                case 3: layer3Key = val
                case 4: layer4Key = val
                case 5: layer5Key = val
                default: break
                }
            }
        }
        if d.object(forKey: "rs_discreteConfidence") != nil {
            discreteConfidence = d.double(forKey: "rs_discreteConfidence")
        }
        if d.object(forKey: "rs_discreteMinLength") != nil {
            discreteMinLength = d.double(forKey: "rs_discreteMinLength")
        }
        if d.object(forKey: "rs_discreteAmbiguityMargin") != nil {
            discreteAmbiguityMargin = d.double(forKey: "rs_discreteAmbiguityMargin")
        }
        if d.object(forKey: "rs_locationConfidence") != nil {
            locationConfidence = d.double(forKey: "rs_locationConfidence")
        }
        if d.object(forKey: "rs_locationMinLength") != nil {
            locationMinLength = d.double(forKey: "rs_locationMinLength")
        }
        if d.object(forKey: "rs_locationRadius") != nil {
            locationRadius = d.double(forKey: "rs_locationRadius")
        }
        if d.object(forKey: "rs_zoneTapWindow") != nil {
            zoneTapWindow = d.double(forKey: "rs_zoneTapWindow")
        }
        if d.object(forKey: "rs_anchorActivationDelay") != nil {
            anchorActivationDelay = d.double(forKey: "rs_anchorActivationDelay")
        }
        if let raw = d.string(forKey: "rs_anchorAllowedZones9") {
            let indices = raw.split(separator: ",").compactMap { Int($0) }.filter { (0..<81).contains($0) }
            if !indices.isEmpty { anchorAllowedZones = Set(indices) }
        }
        if d.object(forKey: "rs_continuousLiftRewind") != nil {
            continuousLiftRewind = d.double(forKey: "rs_continuousLiftRewind")
        }
        if d.object(forKey: "rs_testMode") != nil {
            testMode = d.bool(forKey: "rs_testMode")
        }
        isInitialized = true
    }

    enum LayerActivation: String, CaseIterable, Sendable {
        case alwaysOn = "Always On"
        case anchor = "Anchor"
        case fn = "Fn"
        case globe = "Globe"
        case shift = "Shift"
        case control = "Control"
        case option = "Option"
        case command = "Command"
    }
}
