import AppKit
import SwiftUI

// MARK: - Touch Capture NSView

/// Captures indirect trackpad touches and emits per-finger paths.
/// Each finger draws its own path — 2 fingers = 2 separate paths.
final class TouchCaptureNSView: NSView {
    /// Called during touch movement with (fingerPaths, fingerCount)
    var onPathUpdate: (([[PathPoint]], Int) -> Void)?
    /// Called when all fingers lift with (fingerPaths, fingerCount)
    var onGestureComplete: (([[PathPoint]], Int) -> Void)?

    private(set) var isArmed = false
    private var activeTouches: [NSObject: [PathPoint]] = [:]
    // Keep ended finger paths until gesture completes
    private var completedFingerPaths: [[PathPoint]] = []
    private var gestureStartTime: TimeInterval = 0
    private var maxFingerCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func startCapture() {
        isArmed = true
        activeTouches.removeAll()
        completedFingerPaths.removeAll()
        maxFingerCount = 0
        gestureStartTime = 0
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    func stopCapture() {
        isArmed = false
        activeTouches.removeAll()
        completedFingerPaths.removeAll()
        maxFingerCount = 0
    }

    // MARK: - Touch Handling

    override func touchesBegan(with event: NSEvent) {
        guard isArmed else { return }

        let began = event.touches(matching: .began, in: nil)
        guard !began.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if activeTouches.isEmpty && completedFingerPaths.isEmpty {
            gestureStartTime = now
            maxFingerCount = 0
        }

        for touch in began {
            let key = touch.identity as! NSObject
            let pt = PathPoint(
                x: touch.normalizedPosition.x,
                y: touch.normalizedPosition.y,
                timestamp: now - gestureStartTime
            )
            activeTouches[key] = [pt]
        }

        updateFingerCount()
        emitPaths()
    }

    override func touchesMoved(with event: NSEvent) {
        guard isArmed else { return }

        let moved = event.touches(matching: .moved, in: nil)
        guard !moved.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        for touch in moved {
            let key = touch.identity as! NSObject
            let pt = PathPoint(
                x: touch.normalizedPosition.x,
                y: touch.normalizedPosition.y,
                timestamp: now - gestureStartTime
            )
            if activeTouches[key] != nil {
                activeTouches[key]!.append(pt)
            }
        }

        emitPaths()
    }

    override func touchesEnded(with event: NSEvent) {
        guard isArmed else { return }

        let ended = event.touches(matching: .ended, in: nil)
        guard !ended.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        for touch in ended {
            let key = touch.identity as! NSObject
            let pt = PathPoint(
                x: touch.normalizedPosition.x,
                y: touch.normalizedPosition.y,
                timestamp: now - gestureStartTime
            )
            activeTouches[key]?.append(pt)
            // Move to completed paths
            if let path = activeTouches.removeValue(forKey: key), path.count > 1 {
                completedFingerPaths.append(path)
            }
        }

        // All fingers lifted — gesture is complete
        if activeTouches.isEmpty && !completedFingerPaths.isEmpty {
            isArmed = false
            onGestureComplete?(completedFingerPaths, maxFingerCount)
            completedFingerPaths.removeAll()
        } else {
            emitPaths()
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        activeTouches.removeAll()
        completedFingerPaths.removeAll()
        maxFingerCount = 0
    }

    // MARK: - Helpers

    private func updateFingerCount() {
        let count = activeTouches.count
        if count > maxFingerCount { maxFingerCount = count }
    }

    private func emitPaths() {
        onPathUpdate?(allFingerPaths(), maxFingerCount)
    }

    /// Returns all current finger paths (active + completed)
    private func allFingerPaths() -> [[PathPoint]] {
        var paths = completedFingerPaths
        for (_, pts) in activeTouches where pts.count > 1 {
            paths.append(pts)
        }
        return paths
    }
}

// MARK: - SwiftUI Wrapper

struct TouchCaptureRepresentable: NSViewRepresentable {
    var isArmed: Bool
    var onPathUpdate: ([[PathPoint]], Int) -> Void
    var onGestureComplete: ([[PathPoint]], Int) -> Void

    func makeNSView(context: Context) -> TouchCaptureNSView {
        let view = TouchCaptureNSView(frame: .zero)
        view.onPathUpdate = onPathUpdate
        view.onGestureComplete = onGestureComplete
        return view
    }

    func updateNSView(_ nsView: TouchCaptureNSView, context: Context) {
        nsView.onPathUpdate = onPathUpdate
        nsView.onGestureComplete = onGestureComplete

        if isArmed && !nsView.isArmed {
            nsView.startCapture()
        } else if !isArmed && nsView.isArmed {
            nsView.stopCapture()
        }
    }
}

// MARK: - Path Drawing Helper

/// Draws an array of finger paths on a Canvas context.
/// Each finger gets its own color from a palette.
enum FingerPathRenderer {
    static let colors: [Color] = [.blue, .purple, .orange, .cyan, .pink, .mint, .indigo, .teal]

    static func draw(
        paths: [[PathPoint]],
        in context: GraphicsContext,
        size: CGSize,
        padding: CGFloat = 16,
        lineWidth: CGFloat = 2.5,
        opacity: Double = 0.7,
        autoFit: Bool = false
    ) {
        let drawArea = CGSize(
            width: size.width - padding * 2,
            height: size.height - padding * 2
        )

        // Compute bounding box for auto-fit mode
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        if autoFit {
            for points in paths {
                for p in points {
                    if p.x < minX { minX = p.x }
                    if p.x > maxX { maxX = p.x }
                    if p.y < minY { minY = p.y }
                    if p.y > maxY { maxY = p.y }
                }
            }
            // Add 10% margin around bounding box
            let rangeX = max(maxX - minX, 0.01)
            let rangeY = max(maxY - minY, 0.01)
            let margin = max(rangeX, rangeY) * 0.1
            minX -= margin; maxX += margin
            minY -= margin; maxY += margin
        }

        for (fingerIndex, points) in paths.enumerated() {
            guard points.count > 1 else { continue }

            let color = colors[fingerIndex % colors.count]

            func mapPoint(_ point: PathPoint) -> CGPoint {
                let nx: Double
                let ny: Double
                if autoFit {
                    nx = (point.x - minX) / (maxX - minX)
                    ny = (point.y - minY) / (maxY - minY)
                } else {
                    nx = point.x
                    ny = point.y
                }
                return CGPoint(
                    x: padding + nx * drawArea.width,
                    y: padding + (1 - ny) * drawArea.height
                )
            }

            var path = Path()
            for (i, point) in points.enumerated() {
                let pt = mapPoint(point)
                if i == 0 { path.move(to: pt) }
                else { path.addLine(to: pt) }
            }

            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)

            // Start dot (green)
            if let first = points.first {
                let pt = mapPoint(first)
                context.fill(
                    Circle().path(in: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)),
                    with: .color(.green)
                )
            }

            // End arrowhead — points in direction of travel
            if let last = points.last, points.count >= 2 {
                let ptEnd = mapPoint(last)
                // Walk back to find a reference point at least 5px away for stable direction
                var refPoint: CGPoint? = nil
                for i in stride(from: points.count - 2, through: 0, by: -1) {
                    let pt = mapPoint(points[i])
                    let dx = ptEnd.x - pt.x
                    let dy = ptEnd.y - pt.y
                    if sqrt(dx * dx + dy * dy) >= 5 {
                        refPoint = pt
                        break
                    }
                }
                if let ref = refPoint {
                    let angle = atan2(ptEnd.y - ref.y, ptEnd.x - ref.x)
                    let arrowLen: CGFloat = max(lineWidth * 3.5, 7)
                    let wingAngle: CGFloat = .pi / 5  // 36°
                    var arrowPath = Path()
                    arrowPath.move(to: CGPoint(
                        x: ptEnd.x + arrowLen * cos(angle + .pi - wingAngle),
                        y: ptEnd.y + arrowLen * sin(angle + .pi - wingAngle)))
                    arrowPath.addLine(to: ptEnd)
                    arrowPath.addLine(to: CGPoint(
                        x: ptEnd.x + arrowLen * cos(angle + .pi + wingAngle),
                        y: ptEnd.y + arrowLen * sin(angle + .pi + wingAngle)))
                    context.stroke(arrowPath, with: .color(color.opacity(min(opacity + 0.2, 1.0))), lineWidth: lineWidth)
                }
            }
        }
    }
}
