import AppKit
import SwiftUI

/// Transparent overlay window for live gesture traces and recognition acknowledgment.
/// Uses subtle glass-like rendering: thin feathered strokes, low opacity, soft glow.
final class GestureOverlayWindow {
    static let shared = GestureOverlayWindow()
    static let diagnosticBuildMarker = "OVERLAY_DESKTOP_DEBUG_20260627_1818"

    private var window: NSWindow?
    private let overlayView = GlassOverlayView()
    private var isShowing = false
    private var isHiding = false
    private var hideAnimationTimer: DispatchWorkItem?
    private var lastDecisionLogTime: TimeInterval = 0
    private var lastShowTime: TimeInterval = 0
    private let minimumTraceVisibleDuration: TimeInterval = 0.25

    private func logDecision(_ message: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDecisionLogTime > 0.25 else { return }
        lastDecisionLogTime = now
        mtdLog("[OVERLAY] \(message)")
    }

    // MARK: - Live Trace

    func showAnchorCandidate(progress: Double) {
        ensureWindow()
        hideAnimationTimer?.cancel()
        hideAnimationTimer = nil

        let wasHidden = !isShowing
        isShowing = true
        isHiding = false
        lastShowTime = ProcessInfo.processInfo.systemUptime
        overlayView.mode = .anchorCandidate
        overlayView.anchorCandidateProgress = min(max(progress, 0), 1)
        overlayView.needsDisplay = true
        window?.orderFrontRegardless()

        if wasHidden {
            overlayView.prepareForEmerge()
            logDecision("SHOW anchorCandidate progress=\(String(format: "%.2f", progress)) desktopIdx=\(WindowManager.currentSpaceIdx) marker=\(Self.diagnosticBuildMarker)", force: true)
        } else {
            logDecision("REFRESH anchorCandidate progress=\(String(format: "%.2f", progress)) desktopIdx=\(WindowManager.currentSpaceIdx)")
        }
    }

    func showTrace(paths: [[PathPoint]], fingerCount: Int) {
        ensureWindow()
        hideAnimationTimer?.cancel()
        hideAnimationTimer = nil

        let wasHidden = !isShowing
        isShowing = true
        isHiding = false
        lastShowTime = ProcessInfo.processInfo.systemUptime
        overlayView.mode = .liveTrace
        overlayView.paths = paths
        overlayView.fingerCount = fingerCount

        if wasHidden {
            logDecision("SHOW showTrace desktopIdx=\(WindowManager.currentSpaceIdx) fingers=\(fingerCount) marker=\(Self.diagnosticBuildMarker)", force: true)
            overlayView.needsDisplay = true
            window?.orderFrontRegardless()
            overlayView.playAppear()
        } else {
            // Seamless handoff from the emerging anchor-candidate pad — it is already
            // on screen at full size, so the trace just starts drawing inside it.
            logDecision("REFRESH showTrace desktopIdx=\(WindowManager.currentSpaceIdx) fingers=\(fingerCount)")
            overlayView.needsDisplay = true
            window?.orderFrontRegardless()
        }
    }

    func hideTrace() {
        guard isShowing else {
            logDecision("HIDE requested while not showing desktopIdx=\(WindowManager.currentSpaceIdx)")
            overlayView.paths = []
            overlayView.fingerCount = 0
            overlayView.needsDisplay = true
            window?.orderOut(nil)
            return
        }

        // A fade-out is already running — don't restart it. Overlapping cancel
        // calls (the anchor teardown fires hideTrace several times in one frame)
        // would otherwise remove the in-flight animation and blink the overlay
        // off instead of fading.
        if isHiding { return }

        if overlayView.mode == .liveTrace {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastShowTime
            if elapsed < minimumTraceVisibleDuration {
                let remaining = minimumTraceVisibleDuration - elapsed
                hideAnimationTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.hideTrace()
                }
                hideAnimationTimer = work
                logDecision("DELAY hideTrace remaining=\(String(format: "%.3f", remaining)) desktopIdx=\(WindowManager.currentSpaceIdx)", force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
                return
            }
        }

        logDecision("HIDE showState=true desktopIdx=\(WindowManager.currentSpaceIdx)", force: true)
        isHiding = true
        // Scale-down exit animation (Core Animation, GPU-composited)
        overlayView.playDisappear { [weak self] in
            guard let self else { return }
            self.isShowing = false
            self.isHiding = false
            self.overlayView.paths = []
            self.overlayView.fingerCount = 0
            self.overlayView.mode = .idle
            self.overlayView.needsDisplay = true
            self.window?.orderOut(nil)
        }
    }

    // MARK: - Recognition Acknowledgment

    func showAcknowledgment(name: String, at point: NSPoint, intensity: Double = 0.3) {
        ensureWindow()
        logDecision("SHOW acknowledgment desktopIdx=\(WindowManager.currentSpaceIdx) name=\(name) marker=\(Self.diagnosticBuildMarker)", force: true)
        overlayView.mode = .acknowledgment
        overlayView.acknowledgmentName = name
        overlayView.acknowledgmentCenter = point
        overlayView.acknowledgmentIntensity = intensity
        overlayView.acknowledgmentPhase = 1.0
        overlayView.needsDisplay = true
        window?.orderFrontRegardless()

        // Draw once at full intensity, then bloom-and-dissolve the whole layer (GPU-composited)
        overlayView.playAcknowledgmentFade { [weak self] in
            guard let self else { return }
            if self.overlayView.mode == .acknowledgment {
                self.overlayView.mode = .idle
                self.overlayView.needsDisplay = true
                self.window?.orderOut(nil)
            }
        }
    }

    func showDiagnosticSelfTest(duration: TimeInterval = 3.0) {
        ensureWindow()
        hideAnimationTimer?.cancel()
        hideAnimationTimer = nil
        isShowing = true
        overlayView.mode = .diagnostic
        overlayView.needsDisplay = true
        logDecision("SHOW diagnostic self-test marker=\(Self.diagnosticBuildMarker) desktopIdx=\(WindowManager.currentSpaceIdx)", force: true)
        window?.orderFrontRegardless()
        overlayView.playAppear()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.logDecision("HIDE diagnostic self-test marker=\(Self.diagnosticBuildMarker) desktopIdx=\(WindowManager.currentSpaceIdx)", force: true)
            self.isShowing = false
            self.overlayView.mode = .idle
            self.overlayView.needsDisplay = true
            self.window?.orderOut(nil)
        }
        hideAnimationTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Legacy API

    func show(paths: [[PathPoint]], fingerCount: Int) {
        showTrace(paths: paths, fingerCount: fingerCount)
    }

    func hide() {
        hideTrace()
    }

    // MARK: - Window

    private func ensureWindow() {
        if window == nil { createWindow() }
    }

    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        mtdLog("[OVERLAY] CREATE window marker=\(Self.diagnosticBuildMarker) screen=\(screen.frame)")

        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.title = Self.diagnosticBuildMarker
        w.hasShadow = false
        w.contentView = overlayView
        overlayView.enableLayerBacking()

        self.window = w
    }
}

// MARK: - Glass Overlay View

private final class GlassOverlayView: NSView {
    enum Mode { case idle, anchorCandidate, liveTrace, acknowledgment, diagnostic }

    var mode: Mode = .idle
    var paths: [[PathPoint]] = []
    var fingerCount: Int = 0

    var acknowledgmentName: String = ""
    var acknowledgmentCenter: NSPoint = .zero
    var acknowledgmentIntensity: Double = 0.3
    var acknowledgmentPhase: Double = 0.0  // 1.0 → 0.0 during fade
    var anchorCandidateProgress: Double = 0.0

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .idle else { return }
        NSGraphicsContext.saveGraphicsState()

        switch mode {
        case .anchorCandidate:
            drawAnchorCandidate()
        case .liveTrace:
            drawGlassTrace()
        case .acknowledgment:
            drawAcknowledgment()
        case .diagnostic:
            drawDiagnosticSelfTest()
        case .idle:
            break
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Layer-backed Core Animation

    /// Enable GPU-composited, vsync-synced animations. Content is rasterized once
    /// into the backing layer; appear/disappear/acknowledgment transitions are then
    /// driven by Core Animation on the layer's opacity only. No geometry/transform is
    /// touched, so the overlay never shifts position.
    func enableLayerBacking() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = false
    }

    /// Entrance: smooth opacity fade-in.
    func playAppear() {
        guard let layer = layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.26
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    /// Make the layer fully visible without any layer-level fade. The anchor-candidate
    /// emergence is driven entirely by content (scale + alpha in draw), so the handoff
    /// into the live trace is seamless — the pad is already on screen at full size.
    func prepareForEmerge() {
        guard let layer = layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
    }

    /// Exit: smooth dissolve.
    func playDisappear(completion: @escaping () -> Void) {
        guard let layer = layer else { completion(); return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)

        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 0.0
        fade.duration = 0.30
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade")

        CATransaction.commit()
    }

    /// Acknowledgment: brief hold, then dissolve the whole layer out.
    func playAcknowledgmentFade(completion: @escaping () -> Void) {
        guard let layer = layer else { completion(); return }
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)

        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.5
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.6, 1.0)
        layer.add(fade, forKey: "fade")

        CATransaction.commit()
    }

    // MARK: - Glass Trace Rendering

    private func drawAnchorCandidate() {
        let raw = CGFloat(min(max(anchorCandidateProgress, 0), 1))
        let p = raw * raw * (3 - 2 * raw)  // smoothstep emergence
        guard p > 0.001 else { return }

        let appearance = AppState.shared.appearanceSettings

        // Same trackpad geometry as the live trace, so when the hold locks the pad is
        // already on screen at full size and the trace simply starts inside it.
        let trackpadAspect: CGFloat = 1.35
        let trackpadHeight: CGFloat = 260 * CGFloat(appearance.overlaySize)
        let trackpadWidth = trackpadHeight * trackpadAspect
        let padRect = NSRect(
            x: (bounds.width - trackpadWidth) / 2,
            y: (bounds.height - trackpadHeight) / 2,
            width: trackpadWidth,
            height: trackpadHeight
        )
        let cornerRadius: CGFloat = 18

        NSGraphicsContext.saveGraphicsState()

        // Emerge: grow from a small footprint up to full size about the screen center
        // (content-space transform — centered, so the overlay never drifts). Alpha
        // follows the smoothstep emergence directly for an even, smooth fade-in;
        // at p = 1 it reaches full opacity for a seamless handoff to the live trace.
        let fade = p
        let scale = 0.45 + 0.55 * p
        let cx = bounds.midX, cy = bounds.midY
        let t = NSAffineTransform()
        t.translateX(by: cx, yBy: cy)
        t.scaleX(by: scale, yBy: scale)
        t.translateX(by: -cx, yBy: -cy)
        t.concat()

        // Soft blue halo, brightest mid-emergence, dissolving as it settles
        let haloGrow = p * (1 - p)
        if haloGrow > 0.001 {
            let halo = padRect.insetBy(dx: -16, dy: -16)
            NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 0.12 * haloGrow * p).setFill()
            NSBezierPath(roundedRect: halo, xRadius: cornerRadius + 10, yRadius: cornerRadius + 10).fill()
        }

        // Glass background (matches drawGlassTrace at p = 1 for a seamless handoff)
        let padPath = NSBezierPath(roundedRect: padRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.08, alpha: CGFloat(appearance.overlayBackgroundOpacity) * fade).setFill()
        padPath.fill()

        // Inner gradient for depth
        NSGraphicsContext.saveGraphicsState()
        let gradientRect = padRect.insetBy(dx: 1, dy: 1)
        NSBezierPath(roundedRect: gradientRect, xRadius: cornerRadius - 1, yRadius: cornerRadius - 1).addClip()
        let gradient = NSGradient(
            colors: [
                NSColor(white: 1.0, alpha: 0.06 * fade),
                NSColor(white: 1.0, alpha: 0.02 * fade),
                NSColor(white: 0.0, alpha: 0.03 * fade),
            ],
            atLocations: [0.0, 0.5, 1.0],
            colorSpace: .genericRGB
        )
        gradient?.draw(in: gradientRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // Thin bright border
        NSColor(white: 1.0, alpha: 0.12 * fade).setStroke()
        let borderPath = NSBezierPath(roundedRect: padRect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        borderPath.lineWidth = 1.0
        borderPath.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDiagnosticSelfTest() {
        let bannerRect = NSRect(
            x: bounds.midX - 360,
            y: bounds.midY - 90,
            width: 720,
            height: 180
        )
        NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.2, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bannerRect, xRadius: 18, yRadius: 18).fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(roundedRect: bannerRect.insetBy(dx: 3, dy: 3), xRadius: 15, yRadius: 15)
        border.lineWidth = 6
        border.stroke()

        let text = "TRACKPAD CONTROL OVERLAY SELF-TEST"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 34),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        string.draw(at: NSPoint(x: bannerRect.midX - size.width / 2, y: bannerRect.midY - size.height / 2))
    }

    private func drawGlassTrace() {
        guard !paths.isEmpty else { return }

        let screenBounds = self.bounds
        let appearance = AppState.shared.appearanceSettings

        // Trackpad representation — centered, proportional to real trackpad (~1.35:1 aspect)
        let trackpadAspect: CGFloat = 1.35  // width / height
        let trackpadHeight: CGFloat = 260 * CGFloat(appearance.overlaySize)
        let trackpadWidth = trackpadHeight * trackpadAspect
        let padRect = NSRect(
            x: (screenBounds.width - trackpadWidth) / 2,
            y: (screenBounds.height - trackpadHeight) / 2,
            width: trackpadWidth,
            height: trackpadHeight
        )
        let cornerRadius: CGFloat = 18

        // --- Glass background ---
        let padPath = NSBezierPath(roundedRect: padRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Dark translucent fill
        NSColor(white: 0.08, alpha: CGFloat(appearance.overlayBackgroundOpacity)).setFill()
        padPath.fill()

        // Inner subtle gradient overlay for depth
        let gradientRect = padRect.insetBy(dx: 1, dy: 1)
        let gradientPath = NSBezierPath(roundedRect: gradientRect, xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
        gradientPath.addClip()
        let gradient = NSGradient(
            colors: [
                NSColor(white: 1.0, alpha: 0.06),
                NSColor(white: 1.0, alpha: 0.02),
                NSColor(white: 0.0, alpha: 0.03),
            ],
            atLocations: [0.0, 0.5, 1.0],
            colorSpace: .genericRGB
        )
        gradient?.draw(in: gradientRect, angle: 90)

        // Reset clipping
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()

        // Border — thin bright edge
        NSColor(white: 1.0, alpha: 0.12).setStroke()
        let borderPath = NSBezierPath(roundedRect: padRect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        borderPath.lineWidth = 1.0
        borderPath.stroke()

        // Clip drawing to trackpad bounds (with small inset)
        let clipRect = padRect.insetBy(dx: 8, dy: 8)
        let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: cornerRadius - 6, yRadius: cornerRadius - 6)
        clipPath.addClip()

        // Drawable area within the trackpad
        let inset: CGFloat = 12
        let drawOrigin = NSPoint(x: padRect.minX + inset, y: padRect.minY + inset)
        let drawSize = NSSize(width: padRect.width - inset * 2, height: padRect.height - inset * 2)

        // Finger path colors — soft, desaturated
        let glassColors: [NSColor] = [
            NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1.0),  // blue
            NSColor(calibratedRed: 0.75, green: 0.55, blue: 1.0, alpha: 1.0),  // purple
            NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.85, alpha: 1.0),  // mint
            NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.55, alpha: 1.0),  // peach
        ]

        let thickness = CGFloat(appearance.traceThickness)
        let opacity = CGFloat(appearance.traceOpacity)

        for (fingerIndex, points) in paths.enumerated() {
            guard points.count > 1 else { continue }

            let baseColor = glassColors[fingerIndex % glassColors.count]

            // Build path within trackpad area (touch coords are 0–1)
            func buildPath() -> NSBezierPath {
                let p = NSBezierPath()
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                for (i, point) in points.enumerated() {
                    let x = drawOrigin.x + point.x * drawSize.width
                    let y = drawOrigin.y + point.y * drawSize.height
                    if i == 0 { p.move(to: NSPoint(x: x, y: y)) }
                    else { p.line(to: NSPoint(x: x, y: y)) }
                }
                return p
            }

            // Outer glow
            let glowPath = buildPath()
            glowPath.lineWidth = thickness + 5
            baseColor.withAlphaComponent(opacity * 0.08).setStroke()
            glowPath.stroke()

            // Mid layer
            let midPath = buildPath()
            midPath.lineWidth = thickness + 2
            baseColor.withAlphaComponent(opacity * 0.2).setStroke()
            midPath.stroke()

            // Core line
            let corePath = buildPath()
            corePath.lineWidth = thickness
            baseColor.withAlphaComponent(opacity * 0.7).setStroke()
            corePath.stroke()

            // Current finger position — bright dot at the last point
            if let last = points.last {
                let x = drawOrigin.x + last.x * drawSize.width
                let y = drawOrigin.y + last.y * drawSize.height
                let dotSize: CGFloat = thickness + 4
                baseColor.withAlphaComponent(opacity * 0.5).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - dotSize, y: y - dotSize, width: dotSize * 2, height: dotSize * 2)).fill()
                NSColor.white.withAlphaComponent(opacity * 0.8).setFill()
                let innerDot: CGFloat = thickness
                NSBezierPath(ovalIn: NSRect(x: x - innerDot / 2, y: y - innerDot / 2, width: innerDot, height: innerDot)).fill()
            }
        }

        // Finger count label at bottom of trackpad
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()

        if fingerCount > 0 {
            let labelText = "\(fingerCount) finger\(fingerCount > 1 ? "s" : "")"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35)
            ]
            let str = NSAttributedString(string: labelText, attributes: attrs)
            let strSize = str.size()
            str.draw(at: NSPoint(
                x: padRect.midX - strSize.width / 2,
                y: padRect.minY - strSize.height - 6
            ))
        }
    }

    // MARK: - Acknowledgment Rendering

    private func drawAcknowledgment() {
        let phase = acknowledgmentPhase
        guard phase > 0 else { return }

        let screenBounds = self.bounds
        let appearance = AppState.shared.appearanceSettings
        let intensity = acknowledgmentIntensity
        let opacity = CGFloat(appearance.traceOpacity)
        let thickness = CGFloat(appearance.traceThickness)

        // Scale trackpad size based on thickness slider and overlay size setting
        let trackpadAspect: CGFloat = 1.35
        let trackpadHeight: CGFloat = (200 + thickness * 20) * CGFloat(appearance.overlaySize)
        let trackpadWidth = trackpadHeight * trackpadAspect
        let padRect = NSRect(
            x: (screenBounds.width - trackpadWidth) / 2,
            y: (screenBounds.height - trackpadHeight) / 2,
            width: trackpadWidth,
            height: trackpadHeight
        )
        let cornerRadius: CGFloat = 18

        // Glass trackpad background — opacity slider controls overall visibility
        let padPath = NSBezierPath(roundedRect: padRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.08, alpha: CGFloat(appearance.overlayBackgroundOpacity) * CGFloat(phase) * opacity).setFill()
        padPath.fill()

        // Border
        NSColor(white: 1.0, alpha: 0.12 * CGFloat(phase) * opacity).setStroke()
        let borderPath = NSBezierPath(roundedRect: padRect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        borderPath.lineWidth = 1.0
        borderPath.stroke()

        // Brief flash inside the trackpad
        let flashAlpha = CGFloat(phase * phase * intensity * 0.06) * opacity
        NSColor.white.withAlphaComponent(flashAlpha).setFill()
        padPath.fill()

        // Gesture name label — centered on trackpad
        if !acknowledgmentName.isEmpty {
            let labelAlpha = phase * min(intensity * 2.0, 1.0) * Double(opacity)
            // Font size scales with thickness (12–18pt)
            let fontSize: CGFloat = 12 + thickness
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(CGFloat(min(labelAlpha, 0.85)))
            ]
            let str = NSAttributedString(string: acknowledgmentName, attributes: attrs)
            let strSize = str.size()
            let labelPt = NSPoint(
                x: padRect.midX - strSize.width / 2,
                y: padRect.midY - strSize.height / 2
            )

            // Label backdrop pill
            let backdropRect = NSRect(
                x: labelPt.x - 10, y: labelPt.y - 5,
                width: strSize.width + 20, height: strSize.height + 10
            )
            NSColor(white: 0.0, alpha: CGFloat(phase * 0.25) * opacity).setFill()
            NSBezierPath(roundedRect: backdropRect, xRadius: 8, yRadius: 8).fill()

            // Bright border on pill
            NSColor(white: 1.0, alpha: CGFloat(phase * 0.1) * opacity).setStroke()
            let pillBorder = NSBezierPath(roundedRect: backdropRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            pillBorder.lineWidth = 0.5
            pillBorder.stroke()

            str.draw(at: labelPt)
        }
    }
}
