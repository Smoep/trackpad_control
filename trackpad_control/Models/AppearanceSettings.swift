import Foundation

@Observable
final class AppearanceSettings {
    private static let d = UserDefaults.standard

    var traceThickness: Double = 2.0 {
        didSet { Self.d.set(traceThickness, forKey: "as_traceThickness") }
    }
    var traceOpacity: Double = 0.4 {
        didSet { Self.d.set(traceOpacity, forKey: "as_traceOpacity") }
    }
    var traceFadeDuration: Double = 0.3 {
        didSet { Self.d.set(traceFadeDuration, forKey: "as_traceFadeDuration") }
    }
    var acknowledgmentIntensity: Double = 0.3 {
        didSet { Self.d.set(acknowledgmentIntensity, forKey: "as_acknowledgmentIntensity") }
    }
    var showLivePath: Bool = false {
        didSet { Self.d.set(showLivePath, forKey: "as_showLivePath") }
    }
    var showAcknowledgment: Bool = true {
        didSet { Self.d.set(showAcknowledgment, forKey: "as_showAcknowledgment") }
    }
    var overlayBackgroundOpacity: Double = 0.55 {
        didSet { Self.d.set(overlayBackgroundOpacity, forKey: "as_overlayBgOpacity") }
    }
    var overlaySize: Double = 1.0 {
        didSet { Self.d.set(overlaySize, forKey: "as_overlaySize") }
    }

    init() {
        let d = Self.d
        if d.object(forKey: "as_traceThickness") != nil {
            traceThickness = d.double(forKey: "as_traceThickness")
        }
        if d.object(forKey: "as_traceOpacity") != nil {
            traceOpacity = d.double(forKey: "as_traceOpacity")
        }
        if d.object(forKey: "as_traceFadeDuration") != nil {
            traceFadeDuration = d.double(forKey: "as_traceFadeDuration")
        }
        if d.object(forKey: "as_acknowledgmentIntensity") != nil {
            acknowledgmentIntensity = d.double(forKey: "as_acknowledgmentIntensity")
        }
        if d.object(forKey: "as_showLivePath") != nil {
            showLivePath = d.bool(forKey: "as_showLivePath")
        }
        if d.object(forKey: "as_showAcknowledgment") != nil {
            showAcknowledgment = d.bool(forKey: "as_showAcknowledgment")
        }
        if d.object(forKey: "as_overlayBgOpacity") != nil {
            overlayBackgroundOpacity = d.double(forKey: "as_overlayBgOpacity")
        }
        if d.object(forKey: "as_overlaySize") != nil {
            overlaySize = d.double(forKey: "as_overlaySize")
        }
    }
}
