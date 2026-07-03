import SwiftUI

struct TrackpadRecorderView: View {
    @Binding var samples: [GestureSample]
    @Binding var previewSample: GestureSample?
    @State private var appState = AppState.shared
    @State private var fingerPaths: [[PathPoint]] = []
    @State private var currentFingerCount: Int = 0
    @State private var isArmed = false
    @State private var gestureReady = false
    @State private var countdown: Int = 0
    @State private var countdownTimer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            trackpadCanvas
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            statusBar
            recordingControls
        }
        // Observe live paths from TCM via AppState
        .onChange(of: appState.recordingUpdateCounter) {
            guard isArmed && countdown == 0 && !gestureReady else { return }
            let paths = appState.recordingLivePaths
            if isMeaningfulRecording(paths) {
                fingerPaths = paths
                currentFingerCount = appState.recordingLiveFingerCount
            } else {
                fingerPaths = []
                currentFingerCount = 0
            }
        }
        // Observe completed gesture from TCM via AppState
        .onChange(of: appState.recordingCompletionCounter) {
            guard let paths = appState.recordedPaths else { return }
            guard isMeaningfulRecording(paths) else {
                appState.recordedPaths = nil
                appState.recordingLivePaths = []
                if isArmed {
                    fingerPaths = []
                    currentFingerCount = 0
                    appState.isRecordingArmed = true
                }
                return
            }
            fingerPaths = paths
            currentFingerCount = appState.recordedFingerCount
            gestureReady = true
            isArmed = false
            appState.recordedPaths = nil
            appState.recordingLivePaths = []
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBar: some View {
        let totalPoints = fingerPaths.reduce(0) { $0 + $1.count }
        if gestureReady {
            HStack {
                Label(
                    "\(totalPoints) points · \(currentFingerCount) finger\(currentFingerCount == 1 ? "" : "s") · \(fingerPaths.count) path\(fingerPaths.count == 1 ? "" : "s")",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
        } else if isArmed && totalPoints > 0 {
            HStack {
                Label(
                    "Recording… \(currentFingerCount) finger\(currentFingerCount == 1 ? "" : "s")",
                    systemImage: "record.circle"
                )
                .font(.caption)
                .foregroundStyle(.red)
                Spacer()
            }
        }
    }

    // MARK: - Trackpad Canvas

    private var trackpadCanvas: some View {
        // Visual-only frame — touch capture comes from global TouchCaptureManager
        Color.clear
        // Trackpad outline
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isArmed && !gestureReady ? Color.blue.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 1.5)
                )
                .allowsHitTesting(false)
        }
        // Grid
        .overlay {
            Canvas { context, size in
                let color = Color.primary.opacity(0.04)
                let cx = size.width / 2, cy = size.height / 2

                var hLine = Path()
                hLine.move(to: CGPoint(x: 0, y: cy))
                hLine.addLine(to: CGPoint(x: size.width, y: cy))
                context.stroke(hLine, with: .color(color), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

                var vLine = Path()
                vLine.move(to: CGPoint(x: cx, y: 0))
                vLine.addLine(to: CGPoint(x: cx, y: size.height))
                context.stroke(vLine, with: .color(color), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

                context.fill(
                    Circle().path(in: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4)),
                    with: .color(.primary.opacity(0.08))
                )
            }
            .allowsHitTesting(false)
        }
        // Per-finger path rendering
        .overlay {
            Canvas { context, size in
                let paths = previewSample?.fingerPaths ?? fingerPaths
                FingerPathRenderer.draw(paths: paths, in: context, size: size)
            }
            .allowsHitTesting(false)
        }
        // Armed hint
        .overlay {
            if isArmed && fingerPaths.isEmpty && previewSample == nil && !gestureReady {
                VStack(spacing: 4) {
                    if countdown > 0 {
                        Text("\(countdown)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: "hand.point.up")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Perform gesture on trackpad")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: countdown)
            }
        }
    }

    // MARK: - Controls

    private func isMeaningfulRecording(_ paths: [[PathPoint]]) -> Bool {
        let totalPoints = paths.reduce(0) { $0 + $1.count }
        let longestPath = paths.map(GestureNormalizer.pathLength).max() ?? 0
        return totalPoints >= 6 && longestPath > 0.03
    }

    private func armRecording() {
        fingerPaths = []
        currentFingerCount = 0
        gestureReady = false
        previewSample = nil
        isArmed = true
        countdown = 1
        appState.recordedPaths = nil
        appState.recordingLivePaths = []
        // Countdown before arming — prevents accidental capture right after clicking Record
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                guard isArmed else {
                    countdownTimer?.invalidate()
                    countdownTimer = nil
                    return
                }
                countdown -= 1
                if countdown <= 0 {
                    countdownTimer?.invalidate()
                    countdownTimer = nil
                    appState.isRecordingArmed = true
                }
            }
        }
    }

    private func disarmRecording() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = 0
        appState.isRecordingArmed = false
        appState.recordedPaths = nil
        appState.recordingLivePaths = []
    }

    private var recordingControls: some View {
        HStack {
            if previewSample != nil {
                Button("Done") { previewSample = nil }
            } else if gestureReady {
                Button("Discard") {
                    fingerPaths = []
                    currentFingerCount = 0
                    gestureReady = false
                }

                Button("Save Sample") {
                    let centroid = GestureSample.buildCentroidPath(from: fingerPaths)
                    let sample = GestureSample(
                        pathPoints: centroid,
                        fingerPaths: fingerPaths,
                        fingerCount: currentFingerCount,
                        duration: centroid.last?.timestamp ?? 0
                    )
                    samples.append(sample)
                    fingerPaths = []
                    currentFingerCount = 0
                    gestureReady = false
                }
                .buttonStyle(.borderedProminent)
            } else if isArmed {
                Button("Cancel") {
                    isArmed = false
                    fingerPaths = []
                    currentFingerCount = 0
                    gestureReady = false
                    disarmRecording()
                }
            } else {
                Button("Record Sample") {
                    armRecording()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
