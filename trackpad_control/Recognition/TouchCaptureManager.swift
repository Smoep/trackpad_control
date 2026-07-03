import AppKit
import Foundation
import os.log

private let tcmLog = Logger(subsystem: "com.trackpadcontrol.debug", category: "TCM")

// MARK: - File-Based Debug Log

private let ztLogPath: String = {
    let dir = NSHomeDirectory() + "/Library/Application Support/TrackpadControl"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/tc-debug.log"
}()

/// Append a timestamped line to tc-debug.log.
/// Only writes when "Enable diagnostics log" is turned on in Advanced settings.
private func ztLog(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "adv_diagnostics") else { return }
    let ts = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    let line = "[\(ts)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: ztLogPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: ztLogPath, contents: data)
    }
}

// MARK: - MultitouchSupport C Types

private typealias MTDeviceRef = OpaquePointer

private struct MTPhase {
    static let makeTouch: Int32 = 3
    static let touching: Int32 = 4
    static let breakTouch: Int32 = 5
}

// Callback: device, touchData (raw), touchCount, timestamp, frame
private typealias MTCallback = @convention(c) (
    OpaquePointer, UnsafeMutableRawPointer, Int32, Double, Int32
) -> Void

// dlsym function types
private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>
private typealias RegisterFn = @convention(c) (OpaquePointer, MTCallback) -> Void
private typealias UnregisterFn = @convention(c) (OpaquePointer, MTCallback) -> Void
private typealias StartFn = @convention(c) (OpaquePointer, Int32) -> Void
private typealias StopFn = @convention(c) (OpaquePointer) -> Void

private var fnCreateList: CreateListFn?
private var fnRegister: RegisterFn?
private var fnUnregister: UnregisterFn?
private var fnStart: StartFn?
private var fnStop: StopFn?
private var libHandle: UnsafeMutableRawPointer?

// MTTouch struct layout offsets (bytes from start of each touch record)
// Verified via hexdump: record 2 starts at byte 96 in the buffer
private let kTouchRecordSize = 96
private let kOff_state: Int = 20
private let kOff_fingerID: Int = 24
private let kOff_normX: Int = 32
private let kOff_normY: Int = 36
// Contact size/density — used to distinguish a physical (hard) click from a light
// tap/gesture. Standard MTTouch layout: size (zTotal) at 48, density (zDensity) at 92.
// Offsets not yet hardware-verified here — logged for calibration before gating.
private let kOff_size: Int = 48
private let kOff_density: Int = 92

private struct RawTouch {
    var pathIndex: Int32  // offset 16 — stable per touch lifecycle
    var state: Int32
    var fingerID: Int32   // offset 24 — finger classification, may be reassigned
    var normX: Float
    var normY: Float
    var size: Float       // offset 48 — contact area (zTotal)
    var density: Float    // offset 92 — contact pressure/density (zDensity)
}

private let kOff_pathIndex: Int = 16

private func extractTouches(_ buf: UnsafeMutableRawPointer, count: Int) -> [RawTouch] {
    (0..<count).map { i in
        let base = buf + i * kTouchRecordSize
        return RawTouch(
            pathIndex: base.load(fromByteOffset: kOff_pathIndex, as: Int32.self),
            state: base.load(fromByteOffset: kOff_state, as: Int32.self),
            fingerID: base.load(fromByteOffset: kOff_fingerID, as: Int32.self),
            normX: base.load(fromByteOffset: kOff_normX, as: Float.self),
            normY: base.load(fromByteOffset: kOff_normY, as: Float.self),
            size: base.load(fromByteOffset: kOff_size, as: Float.self),
            density: base.load(fromByteOffset: kOff_density, as: Float.self)
        )
    }
}

// MARK: - Global C callback

private let mtCallback: MTCallback = { _, touchBuf, count, _, _ in
    let touches = extractTouches(touchBuf, count: Int(count))
    let mgr = TouchCaptureManager.shared
    mgr.mtCallbackCount += 1
    mgr.processRawTouches(touches)
}

// MARK: - Manager

/// NOT @Observable — this class is accessed from multiple threads (event tap on main,
/// touch processing on processingQueue). @Observable's ObservationRegistrar uses locks
/// that cause contention: event tap callback blocks → macOS disables the tap → freeze.
final class TouchCaptureManager {
    static let shared = TouchCaptureManager()

    private(set) var isActive = false
    private var devices: [OpaquePointer] = []

    private var activeTouches: [Int32: [PathPoint]] = [:]
    private var completedPaths: [[PathPoint]] = []
    private var gestureStartTime: TimeInterval = 0
    private var maxFingerCount = 0
    private var completionTimer: DispatchWorkItem?
    // Calibration: peak contact size/density per active path, used to distinguish a
    // physical (hard) click from a light tap/gesture. Logged when the finger lifts.
    private var contactPeakSize: [Int32: Float] = [:]
    private var contactPeakDensity: [Int32: Float] = [:]
    // Current (instantaneous) contact size per active path, and the max across all
    // active fingers on the latest frame. Read when a leftMouseDown arrives to tell a
    // physical click (finger still pressed, size high) from a tap-to-click (finger
    // already lifted, size ~0). Validated: tap size≈0.0, physical click size≈0.85-1.20.
    private var contactCurrentSize: [Int32: Float] = [:]
    private var lastFingerSize: Float = 0
    /// Whether the current gesture was started while the modifier key was held.
    /// Prevents non-modifier touches from piggybacking on a modifier gesture.
    private var modifierActivated = false

    /// Thread-safe flags read by the event tap callback.
    /// Since all processing now runs on the main thread, these are always
    /// consistent with the event tap callback (also main thread).
    private(set) var isCapturingGesture = false
    private(set) var isContinuousSession = false
    private(set) var isAlwaysOnMultitouch = false

    // Cached layer keys for event tap callback — plain properties, NO @Observable access.
    // Updated by _processRawTouches on each touch frame.
    // The event tap callback reads ONLY these + isModifierHeld() (CGEventSource).
    private(set) var cachedLayerKeys: [RecognitionSettings.LayerActivation] = [.fn, .fn, .alwaysOn, .alwaysOn, .alwaysOn]

    // Snapshot of modifier flags at gesture start — used to verify per-layer permission
    private var startModifierFlags: CGEventFlags = []

    // Recording support for gesture editor — uses AppState for thread-safe communication
    var isRecordingArmed: Bool { AppState.shared.isRecordingArmed }

    // Diagnostic counters — visible via print, no @Observable overhead
    var mtCallbackCount: Int = 0
    var processedCount: Int = 0
    var lastDiagTime: TimeInterval = 0

    // Safety timeout: tracks when the event tap last started blocking.
    // If blocking for >5s, stop swallowing to prevent permanent system freeze.
    private var blockingStartTime: TimeInterval = 0
    private var isCurrentlyBlocking = false
    private let maxBlockingDuration: TimeInterval = 5.0

    // Polled modifier state — CGEventSource.flagsState is unreliable inside
    // event tap callbacks for Fn detection. This flag is updated by a 16ms
    // timer and read by the event tap callback for reliable blocking.
    private(set) var polledModifierActive = false
    private var modifierPollTimer: DispatchSourceTimer?

    // Fn state tracked via listenOnly CGEventTap for flagsChanged — most reliable
    // source on macOS Tahoe where .defaultTap may not receive Globe/Fn events.
    private(set) var globalFnActive = false
    private var flagsMonitor: Any?
    private var fnListenTap: CFMachPort?
    private var fnListenSource: CFRunLoopSource?

    // Physical trackpad click detection (Force Touch actuation).
    // A "tap" (including tap-to-click) does NOT press the sensor hard, so its
    // contact size/density stays low; a physical/haptic click presses and rests,
    // spiking size/density. We use the MultitouchSupport contact data (not mouse
    // events, which can't tell tap-to-click from a real click) to distinguish taps
    // (which we act on) from physical clicks (which belong to a separate app).
    private var physicalClickActive = false
    // Set when a physical click occurs while fingers are down — taints the whole
    // touch session so we suppress the overlay and discard recognition on lift.
    private var physicalClickTaintedGesture = false

    // Continuous gesture state
    private var activeContinuousGesture: GestureDefinition?
    private var continuousLastPosition: Double = 0
    private var continuousAccumulator: Double = 0
    private var lastContinuousStepTime: TimeInterval = 0
    private var lastNavigationRateLimitLogTime: TimeInterval = 0
    // Throttle state for per-frame diagnostic logs (avoid log-file bloat):
    // these high-frequency lock-attempt logs are collapsed to state-transitions
    // plus a slow heartbeat (see logThrottleInterval).
    private var lastShapeGuardLogTime: TimeInterval = 0
    private var lastShapeGuardAccepted: Bool?
    private var lastNavLockLogTime: TimeInterval = 0
    private var lastNavLockAccepted: Bool?
    private let logThrottleInterval: TimeInterval = 0.15
    private var continuousDirection: Int = 0  // +1 or -1 once established, 0 = undecided
    // Step history for lift-rewind: records each step's timestamp and direction
    // so we can undo steps that fired in the last N ms before finger lift.
    private var continuousStepHistory: [(time: TimeInterval, positive: Bool)] = []
    // Cached candidates for current finger count (avoids per-frame filter)
    private var cachedContinuousCandidates: [GestureDefinition] = []
    private var cachedPinchCandidates: [GestureDefinition] = []
    private var cachedDialCandidates: [GestureDefinition] = []
    private var cachedCandidateFingerCount: Int = 0
    // Remember last continuous gesture for quick repeat swipes (clears after 2s idle)
    private var recentContinuousGesture: GestureDefinition?
    private var recentContinuousTime: TimeInterval = 0
    // Pinch state — tracks average inter-finger distance
    private var pinchLastDistance: Double = 0

    // Zone tap state — tracks multi-tap sequences
    private var tapSequenceCount: Int = 0       // completed taps so far in sequence
    private var tapSequenceFingers: Int = 0     // finger count of current tap sequence
    private var tapSequenceZone: TrackpadZone?  // zone of first tap in sequence
    private var tapSequenceTime: TimeInterval = 0 // when last tap completed
    private var tapSequenceTimer: DispatchWorkItem? // timer to fire after tap wait

    // Anchor activation layer state. This is not a gesture/input type: it only
    // satisfies RecognitionSettings.LayerActivation.anchor and is excluded from
    // recognition finger counts/paths while active.
    private var anchorPathIndex: Int32?
    private var anchorStartPoint: PathPoint?
    private var anchorActivationTimer: DispatchWorkItem?
    private var anchorCandidateIndicatorTimer: DispatchWorkItem?
    private var anchorCandidateStartedAt: TimeInterval = 0
    private var anchorCandidateDelay: TimeInterval = 0
    private var anchorActivationActive = false
    private let anchorMovementThreshold: Double = 0.06
    // Cooldown: timestamp of the last completed gesture interaction (discard or
    // finalize). Used to suppress anchor candidates during rapid strokes — a
    // "transition" finger that rests briefly between strokes won't trip the anchor.
    private var lastInteractionEndTime: TimeInterval = 0

    /// Update the thread-safe flags after any state change.
    private func updateCaptureFlags() {
        isCapturingGesture = !activeTouches.isEmpty || completionTimer != nil
        let hasContinuousFamily = activeContinuousGesture != nil
        isContinuousSession = hasContinuousFamily ||
            (recentContinuousGesture != nil && (ProcessInfo.processInfo.systemUptime - recentContinuousTime) < 2.0)
        // Block system events immediately for 3+ finger Always On layers
        // (prevents macOS from interpreting as scroll/swipe)
        let settings = AppState.shared.recognitionSettings
        let blockingFingerCount = max(maxFingerCount, activeTouches.count)
        isAlwaysOnMultitouch = blockingFingerCount >= 3
            && !activeTouches.isEmpty
            && (3...min(5, blockingFingerCount)).contains { settings.layerKey(for: $0) == .alwaysOn }
    }

    private var hasAnchorActivationLayer: Bool {
        (1...5).contains { AppState.shared.recognitionSettings.layerKey(for: $0) == .anchor }
    }

    private func recognizedActiveTouches() -> [Int32: [PathPoint]] {
        guard anchorActivationActive, let anchorPathIndex else { return activeTouches }
        return activeTouches.filter { $0.key != anchorPathIndex }
    }

    private func recognizedActiveFingerCount() -> Int {
        recognizedActiveTouches().count
    }

    private func activationSignal(for key: RecognitionSettings.LayerActivation, flags: CGEventFlags? = nil) -> Bool {
        switch key {
        case .alwaysOn:
            return true
        case .anchor:
            return anchorActivationActive
        default:
            let currentFlags = flags ?? CGEventSource.flagsState(.hidSystemState)
            return Self.flagsContain(currentFlags, key: key)
                || Self.nsContains(key: key)
                || polledModifierActive
                || (key == .fn && globalFnActive)
        }
    }

    // CGEventTap for blocking system trackpad gestures while modifier is held
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    private init() {
        loadFramework()
    }

    // MARK: - Start / Stop

    func start() {
        guard !isActive, fnCreateList != nil else { return }
        ztLog("TCM-START: launching capture")
        let rs = AppState.shared.recognitionSettings
        let layers = (1...5).map { rs.layerKey(for: $0).rawValue }.joined(separator: ",")
        ztLog("TCM-CONFIG: anchorDelay=\(String(format: "%.2f", rs.anchorActivationDelay)) moveThreshold=\(String(format: "%.3f", anchorMovementThreshold)) layers=[\(layers)] anchorZones=\(rs.anchorAllowedZones.count)/81 discreteConf=\(String(format: "%.2f", rs.discreteConfidence))")

        let cfList = fnCreateList!().takeUnretainedValue()
        let count = CFArrayGetCount(cfList)
        devices = (0..<count).compactMap { i in
            guard let ptr = CFArrayGetValueAtIndex(cfList, i) else { return nil }
            return OpaquePointer(ptr)
        }

        for dev in devices {
            fnRegister!(dev, mtCallback)
            fnStart!(dev, 0)
        }
        isActive = true
        installEventTap()
        startModifierPolling()
    }

    func stop() {
        guard isActive else { return }
        stopModifierPolling()
        removeEventTap()
        for dev in devices {
            fnUnregister!(dev, mtCallback)
            fnStop!(dev)
        }
        devices.removeAll()
        resetGesture()
        isActive = false
    }

    // MARK: - Framework Loading

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            print("[TCM] dlopen failed: \(String(cString: dlerror()))")
            return
        }
        libHandle = handle

        func sym<T>(_ name: String) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        fnCreateList = sym("MTDeviceCreateList")
        fnRegister = sym("MTRegisterContactFrameCallback")
        fnUnregister = sym("MTUnregisterContactFrameCallback")
        fnStart = sym("MTDeviceStart")
        fnStop = sym("MTDeviceStop")
    }

    // MARK: - Touch Processing

    fileprivate func processRawTouches(_ touches: [RawTouch]) {
        // Dispatch to main thread so all state mutations (TCM properties, AppState,
        // GestureOverlayWindow) run on the same thread as the event tap callback
        // and SwiftUI. Eliminates @Observable lock contention that caused macOS
        // to disable the event tap.
        DispatchQueue.main.async { self._processRawTouches(touches) }
    }

    private func _processRawTouches(_ touches: [RawTouch]) {
        processedCount += 1
        let settings = AppState.shared.recognitionSettings
        guard settings.isTracking else {
            logDiag("SKIP: isTracking=false")
            return
        }

        // Refresh cached layer keys for the event tap callback (no @Observable in callback)
        cachedLayerKeys = (1...5).map { settings.layerKey(for: $0) }

        let editorOpen = AppState.shared.isShowingEditor

        // Per-layer modifier gating — check at gesture START.
        // Each finger count has its own modifier key (or Always On).
        // At first touch, we permit capture if ANY layer is satisfied
        // (Always On, or its modifier is currently held).
        // At gesture completion, we verify the actual finger count's layer.
        do {
            let gestureInProgress = !activeTouches.isEmpty
            if !gestureInProgress {
                let flags = CGEventSource.flagsState(.hidSystemState)
                let anyPermitted = (1...5).contains { count in
                    let key = settings.layerKey(for: count)
                    return key == .anchor
                        || key == .alwaysOn
                        || Self.flagsContain(flags, key: key)
                        || Self.nsContains(key: key)
                }
                // Allow through if a tap sequence is active — the first tap already
                // passed the layer check, so subsequent taps in the sequence should
                // not be rejected if the modifier is briefly released between taps.
                guard anyPermitted || tapSequenceCount > 0 else {
                    if completionTimer != nil { finalizeGesture() }
                    return
                }
                modifierActivated = true
                startModifierFlags = flags
                logDiag("LAYER MODIFIER ACTIVATED")
            } else if !modifierActivated {
                return
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        var anyBegan = false
        var anyEnded = false
        // Track peak finger count during the loop — fingers may begin and end
        // in the same frame, so activeTouches.count after the loop may undercount.
        var peakFingerCount = recognizedActiveFingerCount()

        for touch in touches {
            let pid = touch.pathIndex

            switch touch.state {
            case 3: // makeTouch — finger down
                // If a new gesture starts while previous is pending completion, finalize first
                if completionTimer != nil {
                    finalizeGesture()
                    // finalizeGesture→resetGesture clears modifierActivated.
                    // Re-arm if any layer's modifier is still held.
                    let flags = CGEventSource.flagsState(.hidSystemState)
                    let anyPermitted = (1...5).contains { count in
                        let key = settings.layerKey(for: count)
                        return key == .anchor
                            || key == .alwaysOn
                            || Self.flagsContain(flags, key: key)
                            || Self.nsContains(key: key)
                    }
                    guard anyPermitted else { continue }
                    modifierActivated = true
                    startModifierFlags = flags
                }
                if activeTouches.isEmpty && completedPaths.isEmpty {
                    gestureStartTime = now
                    maxFingerCount = 0
                    peakFingerCount = 0
                    cachedContinuousCandidates = []
                    cachedCandidateFingerCount = 0
                }
                let pt = PathPoint(x: Double(touch.normX), y: Double(touch.normY), timestamp: now - gestureStartTime)
                activeTouches[pid] = [pt]
                contactPeakSize[pid] = touch.size
                contactPeakDensity[pid] = touch.density
                contactCurrentSize[pid] = touch.size
                handleAnchorActivationTouchBegan(pathIndex: pid, point: pt)
                anyBegan = true
                // Update peak immediately — before any end events can remove fingers
                peakFingerCount = max(peakFingerCount, recognizedActiveFingerCount())

            case 4: // touching — finger moving
                guard activeTouches[pid] != nil else { continue }
                let pt = PathPoint(x: Double(touch.normX), y: Double(touch.normY), timestamp: now - gestureStartTime)
                activeTouches[pid]!.append(pt)
                contactPeakSize[pid] = max(contactPeakSize[pid] ?? 0, touch.size)
                contactPeakDensity[pid] = max(contactPeakDensity[pid] ?? 0, touch.density)
                contactCurrentSize[pid] = touch.size

            case 5, 6, 7: // breakTouch, hover-out, gone — finger ended
                if var path = activeTouches.removeValue(forKey: pid) {
                    if touch.state == 5 {
                        let pt = PathPoint(x: Double(touch.normX), y: Double(touch.normY), timestamp: now - gestureStartTime)
                        path.append(pt)
                    }
                    let pkS = max(contactPeakSize.removeValue(forKey: pid) ?? 0, touch.size)
                    let pkD = max(contactPeakDensity.removeValue(forKey: pid) ?? 0, touch.density)
                    contactCurrentSize.removeValue(forKey: pid)
                    let dur = (path.last?.timestamp ?? 0) - (path.first?.timestamp ?? 0)
                    let travel = GestureNormalizer.pathLength(path)
                    mtdLog(String(format: "MT-CONTACT pid=%d dur=%.3f travel=%.4f peakSize=%.3f peakDensity=%.3f upSize=%.3f upDensity=%.3f pts=%d",
                                 pid, dur, travel, pkS, pkD, touch.size, touch.density, path.count))
                    if !(anchorPathIndex == pid) {
                        completedPaths.append(path)
                    }
                    anyEnded = true
                } else {
                    contactPeakSize.removeValue(forKey: pid)
                    contactPeakDensity.removeValue(forKey: pid)
                    contactCurrentSize.removeValue(forKey: pid)
                }

            default: break // 0, 1, 2 are pre-touch hover states — ignore
            }
        }

        // Instantaneous max contact size across all fingers currently on the pad
        // (0 when none). Read by the leftMouseDown observer to separate a physical
        // click (finger pressed, size high) from a tap-to-click (finger already gone).
        lastFingerSize = contactCurrentSize.values.max() ?? 0

        if anyBegan {
            completionTimer?.cancel()
            completionTimer = nil
            // Cancel tap sequence timer immediately when new finger touches down.
            // This prevents the single-tap action from firing while the user is
            // still in the process of double-tapping. The timer will be re-evaluated
            // when this new tap completes in handleGestureComplete.
            if tapSequenceCount > 0 && tapSequenceTimer != nil {
                ztLog("ZT: timer-cancelled — new finger down")
                tapSequenceTimer?.cancel()
                tapSequenceTimer = nil
            }
            // Use peakFingerCount — the max simultaneous fingers seen during THIS frame.
            // activeTouches.count may be lower if fingers began AND ended in the same frame.
            updateAnchorActivationState()
            if peakFingerCount > maxFingerCount {
                maxFingerCount = peakFingerCount
                // Cancel active continuous gesture if finger count no longer matches
                if let active = activeContinuousGesture, active.fingerCount != maxFingerCount {
                    logDiag("FINGER COUNT CHANGED \(active.fingerCount)->\(maxFingerCount), canceling \(active.name)")
                    activeContinuousGesture = nil
                    continuousAccumulator = 0
                    continuousDirection = 0
                    continuousStepHistory.removeAll()
                    pinchLastDistance = 0
                }
                // Refresh cached candidates when finger count changes
                cachedContinuousCandidates = GestureStore.shared.gestures.filter { g in
                    g.inputType == .continuous && g.isEnabled && g.fingerCount == maxFingerCount
                }
                cachedPinchCandidates = GestureStore.shared.gestures.filter { g in
                    g.inputType == .pinch && g.isEnabled && g.fingerCount == maxFingerCount
                }
                cachedDialCandidates = GestureStore.shared.gestures.filter { g in
                    g.inputType == .dial && g.isEnabled && g.fingerCount == maxFingerCount
                }
                cachedCandidateFingerCount = maxFingerCount
            }
            updateCaptureFlags()
        }

        // Check if current finger count's layer is satisfied.
        // CRITICAL: startModifierFlags alone is NOT trusted (CGEventSource.flagsState
        // can capture phantom Fn at touch-down). It only counts if a live signal also
        // agrees. Otherwise rely purely on live sources.
        updateAnchorActivationState()
        let recognitionActiveTouches = recognizedActiveTouches()
        let layerForCount = settings.layerKey(for: maxFingerCount)
        let liveLayerSignal = activationSignal(for: layerForCount)
        let startCorroboratedLayer = Self.flagsContain(startModifierFlags, key: layerForCount)
            && liveLayerSignal
        let skipUnapproved = layerForCount != .alwaysOn
            && !liveLayerSignal
            && !startCorroboratedLayer
        let fullTouchSetActive = !recognitionActiveTouches.isEmpty && recognitionActiveTouches.count == maxFingerCount

        if !fullTouchSetActive && AppState.shared.isGestureActive && !anchorActivationActive {
            ztLog("ACTIVE-LAYER: OFF fullTouchSetActive=false active=\(recognitionActiveTouches.count) raw=\(activeTouches.count) max=\(maxFingerCount) desktopIdx=\(WindowManager.currentSpaceIdx)")
            AppState.shared.isGestureActive = false
        }

        // Live X/Y telemetrics — publish primary finger position each frame
        // (skip when editor is open — editor has its own display)
        if !editorOpen && !skipUnapproved && fullTouchSetActive {
            // Use the longest active path as the primary finger
                if let primary = recognitionActiveTouches.values.max(by: { $0.count < $1.count }),
               let last = primary.last {
                let appState = AppState.shared
                if abs(last.x - appState.liveX) > 0.002 || abs(last.y - appState.liveY) > 0.002 {
                    appState.liveX = last.x
                    appState.liveY = last.y
                }
                if !appState.isGestureActive {
                    ztLog("ACTIVE-LAYER: ON f=\(maxFingerCount) layer=\(layerForCount) raw=\(activeTouches.count) desktopIdx=\(WindowManager.currentSpaceIdx) desktopOne=\(WindowManager.isOnDesktopOne())")
                    appState.isGestureActive = true
                }
            }
        }

        // Continuous gesture detection — check on movement frames when not in editor
        // Skip if the current finger count's layer isn't satisfied
        // When dial candidates exist for the same finger count, defer continuous
        // lock-on to give dial detection a chance to claim rotational motion first.
        let hasDialConflict = !cachedDialCandidates.isEmpty
        if !editorOpen && activeContinuousGesture == nil && fullTouchSetActive && !anyEnded && !skipUnapproved {
            if let primary = recognitionActiveTouches.values.max(by: { $0.count < $1.count }),
               let first = primary.first, let last = primary.last {
                let dx = last.x - first.x
                let dy = last.y - first.y
                let dist = sqrt(dx * dx + dy * dy)
                let hasDiscreteConflict = GestureStore.shared.gestures.contains { gesture in
                    gesture.inputType == .discrete && gesture.isEnabled && gesture.fingerCount == maxFingerCount
                }

                // Quick re-lock: if same finger count AND same axis direction as recent
                // continuous gesture, within 2s. Must verify actual movement matches
                // the remembered axis to prevent cross-axis poisoning.
                let currentIsHorizontal = abs(dx) > abs(dy)
                let isRepeat = recentContinuousGesture != nil
                    && (now - recentContinuousTime) < 2.0
                    && recentContinuousGesture!.fingerCount == maxFingerCount
                    && (recentContinuousGesture!.continuousAxis == .horizontal) == currentIsHorizontal

                // Use cached candidates (refreshed when finger count changes)
                let allCandidates = cachedContinuousCandidates
                let hasAxisConflict = allCandidates.count > 1

                // When both axes compete, need more data for a reliable axis decision.
                // When only one axis is configured, lock on quickly without ratio check.
                let minFrames: Int
                let minDist: Double
                let actDist = 0.04

                // Movement coherence: are all fingers moving the same direction?
                // Continuous swipe = high coherence (same dir), dial = low (opposing).
                // Compute this early so we can fast-track coherent motion.
                var fingersCoherent = true
                if hasDialConflict && recognitionActiveTouches.count >= 2 {
                    let vecs = recognitionActiveTouches.values.compactMap { path -> (dx: Double, dy: Double)? in
                        guard path.count >= 3, let f = path.first, let l = path.last else { return nil }
                        let vdx = l.x - f.x; let vdy = l.y - f.y
                        let len = sqrt(vdx * vdx + vdy * vdy)
                        guard len > 0.003 else { return nil }  // finger must have moved
                        return (vdx / len, vdy / len)
                    }
                    if vecs.count >= 2 {
                        // Dot product between each pair: >0 = same direction, <0 = opposing
                        var minDot = 1.0
                        for i in 0..<vecs.count {
                            for j in (i+1)..<vecs.count {
                                let dot = vecs[i].dx * vecs[j].dx + vecs[i].dy * vecs[j].dy
                                minDot = min(minDot, dot)
                            }
                        }
                        // If ANY pair moves in opposing directions (dot < 0.3), it's likely dial
                        fingersCoherent = minDot > 0.3
                    }
                }

                if isRepeat {
                    minFrames = 2; minDist = actDist * 0.375
                } else if hasDialConflict && !fingersCoherent {
                    // Fingers moving in opposing directions — likely dial.
                    // Wait longer to let dial detection claim this.
                    minFrames = 12; minDist = actDist * 2.0
                } else if hasDialConflict {
                    // Fingers coherent (same direction) — safe to lock on quickly
                    minFrames = 4; minDist = actDist * 0.75
                } else if hasAxisConflict {
                    minFrames = 6; minDist = actDist
                } else {
                    minFrames = 3; minDist = actDist * 0.625
                }

                if primary.count >= minFrames && dist > minDist {
                    let isHorizontal = abs(dx) > abs(dy)
                    let effectiveHorizontal: Bool?
                    if isRepeat, let recent = recentContinuousGesture {
                        // Repeat on same axis: reuse remembered axis
                        effectiveHorizontal = recent.continuousAxis == .horizontal
                    } else if hasAxisConflict {
                        // Both axes configured: require 1.8× ratio for confident axis detection
                        let ratio = isHorizontal ? abs(dx) / max(abs(dy), 0.001) : abs(dy) / max(abs(dx), 0.001)
                        effectiveHorizontal = ratio >= 1.8 ? isHorizontal : nil
                    } else {
                        // Single candidate: verify movement matches the configured axis
                        // Require at least 1.3× ratio to avoid locking a horizontal gesture on a vertical swipe
                        if let candidate = allCandidates.first {
                            let wantHorizontal = candidate.continuousAxis == .horizontal
                            let movingHorizontal = abs(dx) > abs(dy)
                            if wantHorizontal == movingHorizontal {
                                effectiveHorizontal = wantHorizontal
                            } else {
                                // Movement is cross-axis — only lock on if the dominant axis
                                // still has meaningful motion (catch diagonal cases)
                                let onAxis = wantHorizontal ? abs(dx) : abs(dy)
                                let offAxis = wantHorizontal ? abs(dy) : abs(dx)
                                effectiveHorizontal = onAxis > offAxis * 1.25 ? wantHorizontal : nil
                            }
                        } else {
                            effectiveHorizontal = nil
                        }
                    }
                    if let effectiveH = effectiveHorizontal,
                       let contGesture = pickContinuousGesture(
                        from: allCandidates,
                        isHorizontal: effectiveH
                    ) {
                        // When dial candidates compete, reject if fingers
                        // are moving in opposing directions (dial-like motion).
                        var accepted = true
                        if hasDialConflict && !fingersCoherent {
                            accepted = false  // let dial have priority
                        }
                        if accepted {
                            // Require strong axis intent for desktop switching so
                            // diagonal/down-then-left movement does not get treated
                            // as a horizontal desktop swipe.
                            let onAxis = effectiveH ? abs(dx) : abs(dy)
                            let offAxis = effectiveH ? abs(dy) : abs(dx)
                            let axisRatio = onAxis / max(offAxis, 0.001)
                            if contGesture.continuousControl.isNavigationControl {
                                // Also check max off-axis excursion at any frame (not just net).
                                // An arc gesture (e.g. down-right-then-up) has a small net off-axis
                                // but a large peak excursion — reject those to prevent accidental fires.
                                let maxOffAxis: Double
                                if effectiveH {
                                    let startY = first.y
                                    maxOffAxis = primary.dropFirst().map { abs($0.y - startY) }.max() ?? offAxis
                                } else {
                                    let startX = first.x
                                    maxOffAxis = primary.dropFirst().map { abs($0.x - startX) }.max() ?? offAxis
                                }
                                let netAxRatio = axisRatio
                                let _ = netAxRatio  // suppress unused warning
                                if contGesture.continuousControl == .cycleWindows {
                                    accepted = axisRatio >= 1.35 && offAxis <= 0.35 && maxOffAxis <= 0.38
                                } else {
                                    accepted = axisRatio >= 2.0 && offAxis <= 0.10 && maxOffAxis <= 0.12
                                }
                                if lastNavLockAccepted != accepted || now - lastNavLockLogTime > logThrottleInterval {
                                    ztLog("NAV-LOCK: control=\(contGesture.continuousControl.rawValue) ratio=\(String(format:"%.2f",axisRatio)) netOff=\(String(format:"%.3f",offAxis)) maxOff=\(String(format:"%.3f",maxOffAxis)) accepted=\(accepted)")
                                    lastNavLockAccepted = accepted
                                    lastNavLockLogTime = now
                                }
                            }
                        }
                        if accepted && hasDiscreteConflict && !anchorActivationActive && !contGesture.continuousControl.isNavigationControl {
                            // When recorded shape gestures exist for this finger count,
                            // only let continuous claim paths that stay mostly straight.
                            let onAxis = effectiveH ? abs(dx) : abs(dy)
                            let maxOffAxis = effectiveH
                                ? (primary.dropFirst().map { abs($0.y - first.y) }.max() ?? abs(dy))
                                : (primary.dropFirst().map { abs($0.x - first.x) }.max() ?? abs(dx))
                            let cumulativeTurn = Self.cumulativeTurn(primary)
                            let offAxisLimit = max(0.06, min(0.12, onAxis * 0.35))
                            accepted = cumulativeTurn <= 0.9 && maxOffAxis <= offAxisLimit
                            if lastShapeGuardAccepted != accepted || now - lastShapeGuardLogTime > logThrottleInterval {
                                ztLog("CONT-SHAPE-GUARD: turn=\(String(format:"%.2f", cumulativeTurn)) maxOff=\(String(format:"%.3f", maxOffAxis)) limit=\(String(format:"%.3f", offAxisLimit)) accepted=\(accepted)")
                                lastShapeGuardAccepted = accepted
                                lastShapeGuardLogTime = now
                            }
                        }
                        if accepted {
                            activeContinuousGesture = contGesture
                            let pos = contGesture.continuousAxis == .horizontal ? last.x : last.y
                            continuousLastPosition = pos
                            continuousDirection = 0
                            continuousStepHistory.removeAll()

                            // Cycle Windows: open Mission Control overview at lock-on so the
                            // user sees all windows while swiping; exit (select) happens on lift.
                            if contGesture.continuousControl == .cycleWindows {
                                WindowManager.enterMissionControl()
                            }

                            if contGesture.continuousControl.isNavigationControl {
                                // Navigation controls fire first step immediately at lock-on.
                                // The 6-frame detection already confirms directional intent.
                                let positive = (contGesture.continuousAxis == .horizontal) ? (dx > 0) : (dy > 0)
                                continuousAccumulator = 0
                                continuousDirection = positive ? 1 : -1
                                lastContinuousStepTime = now
                                ztLog("NAV-STEP: control=\(contGesture.continuousControl.rawValue) dir=\(positive ? "positive" : "negative") min=lock-on")
                                if !AppState.shared.recognitionSettings.testMode {
                                    continuousStepHistory.append((time: now, positive: positive))
                                    ContinuousExecutor.executeStep(gesture: contGesture, positive: positive)
                                }
                            } else if anchorActivationActive && contGesture.continuousControl == .custom {
                                let positive = (contGesture.continuousAxis == .horizontal) ? (dx > 0) : (dy > 0)
                                continuousAccumulator = 0
                                continuousDirection = positive ? 1 : -1
                                lastContinuousStepTime = now
                                ztLog("ANCHOR-CONT-STEP: \(contGesture.name) dir=\(positive ? "positive" : "negative")")
                                if !AppState.shared.recognitionSettings.testMode {
                                    continuousStepHistory.append((time: now, positive: positive))
                                    ContinuousExecutor.executeStep(gesture: contGesture, positive: positive)
                                }
                            } else {
                                // Volume/brightness: credit detection distance for smooth response
                                let startPos = contGesture.continuousAxis == .horizontal ? first.x : first.y
                                continuousAccumulator = pos - startPos
                                lastContinuousStepTime = 0
                            }
                            updateCaptureFlags()
                        } // accepted
                    }
                }
            }
        }

        // Execute continuous steps on movement — skip if fingers are lifting
        // Only for .continuous type — pinch/dial have their own step execution below
          if let contGesture = activeContinuousGesture, !anyEnded, fullTouchSetActive,
           contGesture.inputType == .continuous,
              let primary = recognitionActiveTouches.values.max(by: { $0.count < $1.count }),
           let last = primary.last {
            let currentPos = contGesture.continuousAxis == .horizontal ? last.x : last.y
            let delta = currentPos - continuousLastPosition
            continuousLastPosition = currentPos
            continuousAccumulator += delta

            let threshold = contGesture.continuousStepThreshold
            // Rate limit varies by control type: navigation needs longer pauses
            let minInterval = continuousMinInterval(for: contGesture.continuousControl)
            while abs(continuousAccumulator) >= threshold {
                let elapsed = now - lastContinuousStepTime
                if elapsed < minInterval {
                    if contGesture.continuousControl.isNavigationControl {
                        if now - lastNavigationRateLimitLogTime > 0.12 {
                            ztLog("NAV-RATE-LIMIT: control=\(contGesture.continuousControl.rawValue) elapsed=\(String(format:"%.3f", elapsed)) min=\(String(format:"%.3f", minInterval)) acc=\(String(format:"%.3f", continuousAccumulator))")
                            lastNavigationRateLimitLogTime = now
                        }
                        continuousAccumulator = 0
                    }
                    break
                }
                let positive = continuousAccumulator > 0
                // Direction reversal guard for navigation:
                // Once a direction is established, require 2× threshold to reverse.
                let newDir = positive ? 1 : -1
                if contGesture.continuousControl.isNavigationControl && continuousDirection != 0 && newDir != continuousDirection {
                    if abs(continuousAccumulator) < threshold * 2 { break }
                }
                if contGesture.continuousControl.isNavigationControl {
                    // Navigation: fully reset accumulator after each step.
                    // Prevents leftover distance from triggering an unintended second switch.
                    continuousAccumulator = 0
                } else {
                    continuousAccumulator -= positive ? threshold : -threshold
                }
                continuousDirection = newDir
                lastContinuousStepTime = now
                if contGesture.continuousControl.isNavigationControl {
                    ztLog("NAV-STEP: control=\(contGesture.continuousControl.rawValue) dir=\(positive ? "positive" : "negative") min=\(String(format:"%.3f", minInterval))")
                } else {
                    ztLog("CONT-STEP: control=\(contGesture.continuousControl.rawValue) dir=\(positive ? "positive" : "negative") min=\(String(format:"%.3f", minInterval))")
                }
                if !AppState.shared.recognitionSettings.testMode {
                    continuousStepHistory.append((time: now, positive: positive))
                    ContinuousExecutor.executeStep(gesture: contGesture, positive: positive)
                }
            }
        }

        // Pinch detection — measure inter-finger distance changes (needs ≥2 fingers)
        if !editorOpen && !skipUnapproved && activeContinuousGesture == nil && fullTouchSetActive && !anyEnded
            && recognitionActiveTouches.count >= 2 && !cachedPinchCandidates.isEmpty {
            let positions = recognitionActiveTouches.values.compactMap { $0.last }
            if positions.count >= 2 {
                let avgDist = Self.averagePairwiseDistance(positions)
                // Need a few frames to establish baseline
                let minFrames = recognitionActiveTouches.values.map(\.count).min() ?? 0
                if minFrames >= 4 && pinchLastDistance > 0 {
                    let delta = avgDist - pinchLastDistance
                    // Lock on once meaningful pinch motion is detected
                    // Raise threshold when discrete gestures compete for same finger count
                    if abs(delta) > 0.001 {
                        let totalDelta = avgDist - Self.averagePairwiseDistance(recognitionActiveTouches.values.compactMap(\.first))
                        let hasDiscreteConflict = GestureStore.shared.gestures.contains { g in
                            (g.inputType == .discrete || g.inputType == .zoneTap) && g.isEnabled && g.fingerCount == maxFingerCount
                        }
                        let pinchLockOn: Double = hasDiscreteConflict ? 0.08 : 0.03
                        if abs(totalDelta) > pinchLockOn, let candidate = cachedPinchCandidates.first {
                            activeContinuousGesture = candidate
                            pinchLastDistance = avgDist
                            continuousAccumulator = totalDelta
                            continuousDirection = 0
                            lastContinuousStepTime = 0
                            updateCaptureFlags()
                        }
                    }
                }
                if pinchLastDistance == 0 && minFrames >= 2 {
                    pinchLastDistance = avgDist
                }
            }
        }

        // Dial detection — measure per-finger rotational change around centroid (needs ≥2 fingers)
        if !editorOpen && !skipUnapproved && activeContinuousGesture == nil && fullTouchSetActive && !anyEnded
            && recognitionActiveTouches.count >= 2 && !cachedDialCandidates.isEmpty {
            let minFrames = recognitionActiveTouches.values.map(\.count).min() ?? 0
            if minFrames >= 5 {
                // Build current and start position arrays keyed by pathIndex
                let current = recognitionActiveTouches.map { (key: $0.key, pos: $0.value.last!) }
                let start = recognitionActiveTouches.map { (key: $0.key, pos: $0.value.first!) }
                let totalRotation = Self.computeRotation(current: current, previous: start)

                // Reject predominantly linear motion (scrolling) — compute centroid translation
                let cx0 = start.map(\.pos.x).reduce(0, +) / Double(start.count)
                let cy0 = start.map(\.pos.y).reduce(0, +) / Double(start.count)
                let cx1 = current.map(\.pos.x).reduce(0, +) / Double(current.count)
                let cy1 = current.map(\.pos.y).reduce(0, +) / Double(current.count)
                let translation = sqrt((cx1 - cx0) * (cx1 - cx0) + (cy1 - cy0) * (cy1 - cy0))
                // Rotation arc length at average finger distance from centroid
                let avgRadius = current.map { sqrt(($0.pos.x - cx1) * ($0.pos.x - cx1) + ($0.pos.y - cy1) * ($0.pos.y - cy1)) }.reduce(0, +) / Double(current.count)
                let arcLength = abs(totalRotation) * avgRadius
                // Require rotation arc to be at least 40% of total motion (translation + arc)
                let rotationRatio = (translation + arcLength) > 0.001 ? arcLength / (translation + arcLength) : 0

                // Centroid stability check: during a real dial gesture, the centroid
                // stays relatively stable. During circle drawing, it moves a lot.
                // Require centroid translation to be less than the average finger radius.
                let centroidStable = translation < avgRadius * 1.5

                // When discrete gestures exist for the same finger count, use a time-based
                // guard: require fingers to be down for 0.4s before locking on to dial.
                // Discrete gestures are quick draw-and-lift; dial is sustained rotation.
                let hasDiscreteConflict = GestureStore.shared.gestures.contains { g in
                    (g.inputType == .discrete || g.inputType == .zoneTap) && g.isEnabled && g.fingerCount == maxFingerCount
                }
                let touchDuration = now - gestureStartTime
                let timeGuardMet = !hasDiscreteConflict || touchDuration > 0.4

                // Lock on after ~12° of intentional rotation, with linear motion rejection
                // and centroid stability (rejects independent finger circles)
                if abs(totalRotation) > 0.21 && rotationRatio > 0.4 && centroidStable && timeGuardMet, let candidate = cachedDialCandidates.first {
                    activeContinuousGesture = candidate
                    // Credit the detection rotation into accumulator
                    continuousAccumulator = totalRotation / (2 * .pi)
                    continuousDirection = 0
                    lastContinuousStepTime = 0
                    updateCaptureFlags()
                }
            }
        }

        // Execute pinch/dial steps on movement
        if let contGesture = activeContinuousGesture, !anyEnded, fullTouchSetActive,
           (contGesture.inputType == .pinch || contGesture.inputType == .dial) {
            let positions = recognitionActiveTouches.values.compactMap { $0.last }
            if positions.count >= 2 {
                if contGesture.inputType == .pinch {
                    let avgDist = Self.averagePairwiseDistance(positions)
                    let delta = avgDist - pinchLastDistance
                    pinchLastDistance = avgDist
                    continuousAccumulator += delta
                } else {
                    // Dial: compute per-finger rotation delta from last frame
                    let current = recognitionActiveTouches.map { (key: $0.key, pos: $0.value.last!) }
                    // Use second-to-last positions as "previous" for frame delta
                    let previous = recognitionActiveTouches.compactMap { k, v -> (key: Int32, pos: PathPoint)? in
                        guard v.count >= 2 else { return nil }
                        return (key: k, pos: v[v.count - 2])
                    }
                    if previous.count >= 2 {
                        let frameDelta = Self.computeRotation(current: current, previous: previous)
                        // Scale: radians → normalized (full rotation = 1.0)
                        continuousAccumulator += frameDelta / (2 * .pi)
                    }
                }

                let threshold = contGesture.continuousStepThreshold
                let minInterval = continuousMinInterval(for: contGesture.continuousControl)
                while abs(continuousAccumulator) >= threshold {
                    let elapsed = now - lastContinuousStepTime
                    if elapsed < minInterval {
                        if contGesture.continuousControl.isNavigationControl {
                            if now - lastNavigationRateLimitLogTime > 0.12 {
                                ztLog("NAV-RATE-LIMIT: control=\(contGesture.continuousControl.rawValue) elapsed=\(String(format:"%.3f", elapsed)) min=\(String(format:"%.3f", minInterval)) acc=\(String(format:"%.3f", continuousAccumulator))")
                                lastNavigationRateLimitLogTime = now
                            }
                            continuousAccumulator = 0
                        }
                        break
                    }
                    let positive = continuousAccumulator > 0
                    let newDir = positive ? 1 : -1
                    if contGesture.continuousControl.isNavigationControl && continuousDirection != 0 && newDir != continuousDirection {
                        if abs(continuousAccumulator) < threshold * 2 { break }
                    }
                    if contGesture.continuousControl.isNavigationControl {
                        continuousAccumulator = 0
                    } else {
                        continuousAccumulator -= positive ? threshold : -threshold
                    }
                    continuousDirection = newDir
                    lastContinuousStepTime = now
                    if contGesture.continuousControl.isNavigationControl {
                        ztLog("NAV-STEP: control=\(contGesture.continuousControl.rawValue) dir=\(positive ? "positive" : "negative") min=\(String(format:"%.3f", minInterval))")
                    } else {
                        ztLog("CONT-STEP: control=\(contGesture.continuousControl.rawValue) dir=\(positive ? "positive" : "negative") min=\(String(format:"%.3f", minInterval))")
                    }
                    if !AppState.shared.recognitionSettings.testMode {
                        continuousStepHistory.append((time: now, positive: positive))
                        ContinuousExecutor.executeStep(gesture: contGesture, positive: positive)
                    }
                }
            }
        }

        // Live trace overlay — show as soon as the activation layer is live.
        // (skip when editor is open — editor handles its own overlay)
        if !editorOpen {
            let appearance = AppState.shared.appearanceSettings
            if physicalClickActive || physicalClickTaintedGesture {
                // Physical click in progress — belongs to another app. Stay silent.
                GestureOverlayWindow.shared.hideTrace()
            } else if anchorActivationActive {
                let allPaths = buildAnchorOverlayPaths()
                if !allPaths.isEmpty {
                    GestureOverlayWindow.shared.showTrace(paths: allPaths, fingerCount: recognizedActiveFingerCount())
                }
            } else if anchorPathIndex != nil {
                // Candidate feedback owns the overlay while the hold is being evaluated.
                // The normal live-path branch would otherwise hide it every frame because
                // the Anchor layer is not active yet.
            } else if appearance.showLivePath {
                if !skipUnapproved && fullTouchSetActive {
                    let allPaths = buildAllPaths()
                    let totalPoints = allPaths.reduce(0) { $0 + $1.count }
                    if totalPoints > 0 {
                        GestureOverlayWindow.shared.showTrace(paths: allPaths, fingerCount: self.maxFingerCount)
                    }
                } else {
                    GestureOverlayWindow.shared.hideTrace()
                }
            }
        }

        // Forward live paths to AppState when editor is recording
        if editorOpen && isRecordingArmed {
            let allPaths = buildAllPaths()
            let fingers = maxFingerCount
            let appState = AppState.shared
            appState.recordingLivePaths = allPaths
            appState.recordingLiveFingerCount = fingers
            appState.recordingUpdateCounter += 1
        }

        // Gesture complete — all fingers lifted
        if anyEnded && recognitionActiveTouches.isEmpty && !completedPaths.isEmpty {
            logDiag("ALL LIFTED completed=\(completedPaths.count) fingers=\(maxFingerCount) rawActive=\(activeTouches.count) continuous=\(activeContinuousGesture != nil) editor=\(editorOpen) recording=\(isRecordingArmed)")
            if physicalClickTaintedGesture {
                ztLog("PHYSICAL-CLICK: discarding tainted gesture on lift")
                resetGesture()
                GestureOverlayWindow.shared.hideTrace()
            } else if !editorOpen && anchorActivationActive {
                if let contGesture = activeContinuousGesture {
                    finishAnchorContinuousGesture(contGesture, now: now)
                } else {
                    handleAnchorActivationGesture(paths: completedPaths)
                }
            } else if let contGesture = activeContinuousGesture {
                // Lift rewind: undo steps that fired in the last N ms before lift.
                // This prevents last-moment finger drift from causing extra steps.
                let rewindWindow = AppState.shared.recognitionSettings.continuousLiftRewind
                if rewindWindow > 0.001 && !continuousStepHistory.isEmpty
                    && contGesture.continuousControl != .cycleWindows {
                    let cutoff = now - rewindWindow
                    let stepsToUndo = continuousStepHistory.filter { $0.time >= cutoff }
                    if !stepsToUndo.isEmpty && !AppState.shared.recognitionSettings.testMode {
                        logDiag("LIFT-REWIND: undoing \(stepsToUndo.count) steps from last \(Int(rewindWindow * 1000))ms")
                        for step in stepsToUndo.reversed() {
                            // Fire reverse step to undo
                            ContinuousExecutor.executeStep(gesture: contGesture, positive: !step.positive)
                        }
                    }
                }
                continuousStepHistory.removeAll()
                // Cycle Windows: lift closes Mission Control, landing on (selecting)
                // the window the user cycled to.
                if contGesture.continuousControl == .cycleWindows {
                    WindowManager.exitMissionControl()
                }
                // Remember for quick re-lock on next swipe
                recentContinuousGesture = contGesture
                recentContinuousTime = now
                activeContinuousGesture = nil
                continuousAccumulator = 0
                continuousDirection = 0
                // Update telemetrics for continuous-family gestures
                let appState = AppState.shared
                appState.lastGestureFingerCount = maxFingerCount
                appState.lastGestureTimestamp = Date()
                appState.lastMatchName = contGesture.name
                appState.lastMatchScore = 1.0
                appState.lastAllScores = [(contGesture.name, 1.0)]
                if let primary = completedPaths.max(by: { $0.count < $1.count }) ?? buildAllPaths().max(by: { $0.count < $1.count }) {
                    appState.lastGesturePointCount = primary.count
                    appState.lastGesturePathLength = GestureNormalizer.pathLength(primary)
                    if let first = primary.first {
                        appState.lastGestureStartX = first.x
                        appState.lastGestureStartY = first.y
                    }
                    if let last = primary.last {
                        appState.lastGestureEndX = last.x
                        appState.lastGestureEndY = last.y
                    }
                }
                resetGesture()  // calls updateCaptureFlags()
                if appState.appearanceSettings.showLivePath {
                    GestureOverlayWindow.shared.hideTrace()
                }
            } else if editorOpen && isRecordingArmed {
                // Forward completed gesture to editor via AppState
                let paths = completedPaths
                let fingers = maxFingerCount
                resetGesture()
                let appState = AppState.shared
                appState.isRecordingArmed = false
                appState.recordedPaths = paths
                appState.recordedFingerCount = fingers
                appState.recordingCompletionCounter += 1
            } else if !editorOpen {
                // Layer check at completion — skip full recognition if the modifier
                // for this finger count isn't satisfied. Allow through if a tap sequence
                // is active (first tap already validated the layer).
                // Check BOTH startModifierFlags (captured at gesture start) AND current
                // flags (live) — the start snapshot can miss Fn if captured during a
                // hover frame before Fn was fully registered.
                let finishLayerKey = settings.layerKey(for: maxFingerCount)
                let currentFlags = CGEventSource.flagsState(.hidSystemState)
                // Live signals at lift time — the start-snapshot alone cannot pass
                // unless at least one live source agrees (blocks phantom-Fn captures).
                let liveSources = activationSignal(for: finishLayerKey, flags: currentFlags)
                let startCorroborated = Self.flagsContain(startModifierFlags, key: finishLayerKey)
                    && liveSources
                let layerOK = finishLayerKey == .alwaysOn
                    || liveSources
                    || startCorroborated
                ztLog("ALL-LIFTED-CHECK: layer=\(finishLayerKey) f=\(maxFingerCount) anchor=\(anchorActivationActive) startFn=\(Self.flagsContain(startModifierFlags, key: .fn)) curFn=\(Self.flagsContain(currentFlags, key: .fn)) nsFn=\(Self.nsContains(key: .fn)) polled=\(polledModifierActive) gFn=\(globalFnActive) tapSeq=\(tapSequenceCount) → \(layerOK ? "PASS" : "FAIL")")
                if layerOK {
                    finalizeGesture()
                } else {
                    ztLog("DISCARD: finishLayer=\(finishLayerKey) fingers=\(maxFingerCount) startFlags=\(startModifierFlags.rawValue) curFlags=\(currentFlags.rawValue) polled=\(polledModifierActive) gFn=\(globalFnActive)")
                    resetGesture()
                }
            } else {
                // Editor open but not recording — just discard
                resetGesture()
            }
        } else if anyEnded && !recognitionActiveTouches.isEmpty {
            ztLog("PARTIAL-LIFT: active=\(recognitionActiveTouches.count) raw=\(activeTouches.count) completed=\(completedPaths.count) fingers=\(maxFingerCount) → 0.3s timer")
            AppState.shared.isGestureActive = false
            scheduleCompletionTimeout()
            updateCaptureFlags()
        } else if anyEnded && recognitionActiveTouches.isEmpty && completedPaths.isEmpty {
            // Fingers lifted but no paths accumulated — dead gesture, clean up
            logDiag("DEAD GESTURE - no paths, resetting")
            resetGesture()
        }
    }

    private func handleGestureComplete(primaryPath: [PathPoint], fingerCount: Int, paths: [[PathPoint]]) {
        let settings = AppState.shared.recognitionSettings
        let gestures = GestureStore.shared.gestures

        if AppState.shared.appearanceSettings.showLivePath {
            GestureOverlayWindow.shared.hideTrace()
        }

        // Zone tap detection — stationary tap check
        // A tap is: short duration, minimal movement
        let duration = primaryPath.last?.timestamp ?? 0
        let pathLength = GestureNormalizer.pathLength(primaryPath)
        let isTap = duration < 0.4 && pathLength < 0.08
        ztLog("ZT-check: dur=\(String(format: "%.3f", duration)) path=\(String(format: "%.4f", pathLength)) isTap=\(isTap) f=\(fingerCount)")
        let now = ProcessInfo.processInfo.systemUptime

        if !isTap {
            // Non-tap gesture (swipe, etc.) breaks any active tap sequence
            if tapSequenceCount > 0 {
                resetTapSequence()
            }
            // Per-gesture geometry summary (one line per swipe — low frequency).
            // This is the ground-truth record of swipe direction. For horizontal
            // motion dx>0 = physical RIGHTward on the trackpad; for vertical
            // dy>0 = upward in normalized trackpad coordinates.
            if let s = primaryPath.first, let e = primaryPath.last {
                let dx = e.x - s.x
                let dy = e.y - s.y
                let horiz = abs(dx) >= abs(dy)
                let dir = horiz ? (dx > 0 ? "RIGHT" : "LEFT") : (dy > 0 ? "UP" : "DOWN")
                let axisRatio = max(abs(dx), abs(dy)) / max(min(abs(dx), abs(dy)), 0.001)
                let turn = Self.cumulativeTurn(primaryPath)
                ztLog("SWIPE-GEOM: f=\(fingerCount) dur=\(String(format: "%.3f", duration)) dir=\(dir) dx=\(String(format: "%+.3f", dx)) dy=\(String(format: "%+.3f", dy)) axisRatio=\(String(format: "%.2f", axisRatio)) turn=\(String(format: "%.2f", turn)) pathLen=\(String(format: "%.3f", pathLength)) start=(\(String(format: "%.2f", s.x)),\(String(format: "%.2f", s.y))) end=(\(String(format: "%.2f", e.x)),\(String(format: "%.2f", e.y)))")
            }
        }

        if isTap, let start = primaryPath.first {
            // Determine which zone the tap landed in
            let zone = TrackpadZone.allCases.first { $0.contains(x: start.x, y: start.y) } ?? .center

            // Layer check for zone taps — must satisfy the modifier for this finger count.
            // For subsequent taps in a sequence, the layer was already validated on the first tap,
            // so we skip re-checking (the user may briefly release the modifier between taps).
            // CRITICAL: only allow the bypass if the new tap genuinely continues the same
            // sequence (same zone + same finger count) AND is within the configured window.
            // Otherwise an Fn-tap in one zone would let a non-Fn tap in any other zone fire.
            let ztLayerKey = settings.layerKey(for: fingerCount)
            let seqContinuesSameTarget = tapSequenceCount > 0
                && tapSequenceFingers == fingerCount
                && tapSequenceZone == zone
                && (now - tapSequenceTime) < settings.zoneTapWindow
            // Live signals — current state of the modifier (independent of the
            // start-of-gesture snapshot, which can capture phantom flags).
            let liveFlags = CGEventSource.flagsState(.hidSystemState)
            let liveSources = activationSignal(for: ztLayerKey, flags: liveFlags)
            // The start-snapshot is only trusted if at least one live source agrees.
            // This blocks phantom-Fn captures from CGEventSource.flagsState at touch-down.
            let startCorroborated = Self.flagsContain(startModifierFlags, key: ztLayerKey)
                && liveSources
            let ztLayerOK = ztLayerKey == .alwaysOn
                || liveSources
                || startCorroborated
                || seqContinuesSameTarget
            guard ztLayerOK else {
                // Layer not satisfied — not a zone tap, fall through to discrete matching
                // (which will also fail the layer check and return)
                ztLog("ZT-LAYER-FAIL: zone=\(zone.rawValue) fingers=\(fingerCount) layer=\(ztLayerKey) startFlag=\(Self.flagsContain(startModifierFlags, key: ztLayerKey)) live=\(liveSources)")
                resetTapSequence()
                return
            }

            // Check if this continues an existing tap sequence (same zone, same fingers,
            // within the configured window). The window is measured between consecutive
            // tap-processed events.
            let seqElapsed = tapSequenceCount > 0 ? now - tapSequenceTime : 0
            let continuing = tapSequenceCount > 0 && tapSequenceFingers == fingerCount
                && tapSequenceZone == zone && seqElapsed < settings.zoneTapWindow
            ztLog("ZT: zone=\(zone.rawValue) f=\(fingerCount) seq=\(self.tapSequenceCount) elapsed=\(String(format: "%.3f", seqElapsed))s cont=\(continuing)")
            if continuing {
                tapSequenceCount += 1
            } else {
                // New tap sequence
                tapSequenceCount = 1
                tapSequenceFingers = fingerCount
                tapSequenceZone = zone
            }
            tapSequenceTime = now

            // Check for zone tap gesture matches at current tap count
            let matchingZoneTaps = gestures.filter { g in
                g.inputType == .zoneTap && g.isEnabled
                && g.fingerCount == fingerCount
                && g.tapCount <= tapSequenceCount
                && g.activeZones.contains(zone)
            }

            // Find the gesture requiring the most taps (prefer triple over double over single)
            // Wait for potential additional taps if a higher tap count gesture exists
            let maxConfiguredTaps = gestures
                .filter { $0.inputType == .zoneTap && $0.isEnabled && $0.fingerCount == fingerCount && $0.activeZones.contains(zone) }
                .map(\.tapCount)
                .max() ?? 0

            tapSequenceTimer?.cancel()
            tapSequenceTimer = nil

            ztLog("ZT: seqCount=\(self.tapSequenceCount) maxCfg=\(maxConfiguredTaps) match=\(matchingZoneTaps.count)")

            if tapSequenceCount >= maxConfiguredTaps, let best = matchingZoneTaps.max(by: { $0.tapCount < $1.tapCount }) {
                // We've reached (or exceeded) the maximum configured tap count — fire immediately
                ztLog("ZT: FIRE-NOW \(best.name) taps=\(best.tapCount)")
                executeZoneTap(best, fingerCount: fingerCount)
                resetTapSequence()
                return
            } else if maxConfiguredTaps > tapSequenceCount {
                // Higher tap-count gesture exists. Fire the best match at the CURRENT
                // tap count immediately (no delay) and keep the sequence alive.
                // If another tap arrives, the higher-count gesture will fire and
                // override the already-executed action. This gives instant response
                // for single taps while still supporting double/triple taps.
                if let currentBest = matchingZoneTaps.max(by: { $0.tapCount < $1.tapCount }) {
                    ztLog("ZT: FIRE-EAGER \(currentBest.name) taps=\(currentBest.tapCount) (max=\(maxConfiguredTaps))")
                    executeZoneTap(currentBest, fingerCount: fingerCount)
                }
                // Keep sequence alive briefly for potential follow-up taps.
                // If no follow-up tap arrives, the sequence just resets (action already fired).
                let additionalTapWait: TimeInterval = settings.zoneTapWindow
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    ztLog("ZT: SEQ-TIMEOUT seq=\(self.tapSequenceCount)")
                    self.resetTapSequence()
                }
                tapSequenceTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + additionalTapWait, execute: work)
                // Update telemetrics for tap
                updateTapTelemetrics(zone: zone, fingerCount: fingerCount, tapCount: tapSequenceCount)
                return
            }
            // Not a zone tap — fall through to normal matching
        }

        // Layer check — gate discrete gestures by the per-finger layer setting.
        // Zone taps (above) bypass this check since they're quick stationary touches.
        // Same corroboration rule: startModifierFlags alone is not trusted unless a
        // live source agrees.
        let layerForCount = AppState.shared.recognitionSettings.layerKey(for: fingerCount)
        if layerForCount != .alwaysOn {
            let liveFlagsNow = CGEventSource.flagsState(.hidSystemState)
            let liveSignal = activationSignal(for: layerForCount, flags: liveFlagsNow)
            let startCorroborated = Self.flagsContain(startModifierFlags, key: layerForCount)
                && liveSignal
            guard liveSignal || startCorroborated else {
                return  // layer not satisfied for discrete gestures
            }
        }

        // Normal discrete gesture matching
        let results = GestureMatcher.match(
            performedPath: primaryPath,
            fingerCount: fingerCount,
            gestures: gestures,
            settings: settings
        )

        // Compute all scores for telemetrics (including below threshold)
        let allScores = GestureMatcher.matchAll(
            performedPath: primaryPath,
            fingerCount: fingerCount,
            gestures: gestures,
            settings: settings
        )

        // Update telemetrics
        let appState = AppState.shared
        appState.lastGestureFingerCount = fingerCount
        appState.lastGesturePointCount = primaryPath.count
        appState.lastGestureTimestamp = Date()
        appState.lastAllScores = allScores.map { ($0.gesture.name, $0.score) }
        if let first = primaryPath.first {
            appState.lastGestureStartX = first.x
            appState.lastGestureStartY = first.y
        }
        if let last = primaryPath.last {
            appState.lastGestureEndX = last.x
            appState.lastGestureEndY = last.y
        }
        appState.lastGesturePathLength = GestureNormalizer.pathLength(primaryPath)
        if let best = results.first {
            appState.lastMatchName = best.gesture.name
            appState.lastMatchScore = best.score
        } else {
            appState.lastMatchName = ""
            appState.lastMatchScore = 0
        }

        // Outcome summary (one line per gesture). Shows what discrete gesture won
        // and the top competing scores, so ambiguous swipes are easy to diagnose.
        let topScores = allScores.prefix(3)
            .map { "\($0.gesture.name)=\(String(format: "%.2f", $0.score))" }
            .joined(separator: ", ")

        // Ambiguity guard: if the top two confident candidates are different
        // gestures separated by less than the configured margin, the gesture
        // doesn't fit neatly into one class — suppress rather than fire a
        // coin-flip. Clean gestures separate by >=0.10; ambiguous ones cluster
        // within ~0.02 (see SWIPE-GEOM/DISCRETE telemetry).
        if results.count >= 2 {
            let margin = results[0].score - results[1].score
            if margin < settings.discreteAmbiguityMargin {
                ztLog("DISCRETE-AMBIGUOUS: top=\(results[0].gesture.name)=\(String(format: "%.2f", results[0].score)) second=\(results[1].gesture.name)=\(String(format: "%.2f", results[1].score)) margin=\(String(format: "%.2f", margin)) limit=\(String(format: "%.2f", settings.discreteAmbiguityMargin)) → suppressed")
                return
            }
        }

        if let best = results.first {
            ztLog("DISCRETE-FIRE: \(best.gesture.name) score=\(String(format: "%.2f", best.score)) f=\(fingerCount) act=\(best.gesture.triggerAction.displayName) top=[\(topScores)]")
        } else {
            ztLog("DISCRETE-NOMATCH: f=\(fingerCount) top=[\(topScores)]")
        }

        guard let best = results.first else { return }

        // Acknowledgment overlay
        let appearance = AppState.shared.appearanceSettings
        if appearance.showAcknowledgment {
            GestureOverlayWindow.shared.showAcknowledgment(
                name: best.gesture.name,
                at: .zero,
                intensity: appearance.acknowledgmentIntensity
            )
        }

        if !AppState.shared.recognitionSettings.testMode {
            TriggerExecutor.execute(best.gesture.triggerAction)
        }
    }

    private func executeZoneTap(_ gesture: GestureDefinition, fingerCount: Int) {
        let execTime = ProcessInfo.processInfo.systemUptime
        let latency = execTime - gestureStartTime
        ztLog("ZT-EXEC: \(gesture.name) lat=\(String(format: "%.3f", latency))s f=\(fingerCount) act=\(gesture.triggerAction.displayName)")
        let appState = AppState.shared
        appState.lastGestureFingerCount = fingerCount
        appState.lastGesturePointCount = 1
        appState.lastGestureTimestamp = Date()
        appState.lastMatchName = gesture.name
        appState.lastMatchScore = 1.0
        appState.lastAllScores = [(gesture.name, 1.0)]
        appState.lastGesturePathLength = 0

        let appearance = appState.appearanceSettings
        if appearance.showAcknowledgment {
            GestureOverlayWindow.shared.showAcknowledgment(
                name: gesture.name,
                at: .zero,
                intensity: appearance.acknowledgmentIntensity
            )
        }
        if !appState.recognitionSettings.testMode {
            tcmLog.debug("executeZoneTap: calling TriggerExecutor")
            TriggerExecutor.execute(gesture.triggerAction)
        } else {
            tcmLog.debug("executeZoneTap: SKIPPED — testMode is ON")
        }
    }

    private func updateTapTelemetrics(zone: TrackpadZone, fingerCount: Int, tapCount: Int) {
        let appState = AppState.shared
        appState.lastGestureFingerCount = fingerCount
        appState.lastGesturePointCount = 1
        appState.lastGestureTimestamp = Date()
        appState.lastMatchName = "\(tapCount)x tap in \(zone.rawValue)"
        appState.lastMatchScore = 0
        appState.lastAllScores = []
    }

    private func resetTapSequence() {
        tapSequenceCount = 0
        tapSequenceFingers = 0
        tapSequenceZone = nil
        tapSequenceTimer?.cancel()
        tapSequenceTimer = nil
    }

    /// Called from the .listenOnly tap when a leftMouseDown fires while a finger is
    /// pressed (size >= 0.3). This is a physical trackpad click, not a tap-to-click
    /// or a resting anchor hold, so it must not trigger the overlay. We taint the
    /// current gesture and tear down any in-progress anchor candidate/activation.
    /// Runs on the main runloop (same as touch processing), so no locking needed.
    func handlePhysicalClickDuringTouch() {
        guard !activeTouches.isEmpty || anchorPathIndex != nil || anchorActivationActive else { return }
        if physicalClickTaintedGesture { return }
        physicalClickTaintedGesture = true
        mtdLog(String(format: "PHYSICAL-CLICK detected size=%.3f -> suppress overlay/anchor", lastFingerSize))
        resetAnchorActivation(reason: "physicalClick")
        GestureOverlayWindow.shared.hideTrace()
    }

    private func handleAnchorActivationTouchBegan(pathIndex: Int32, point: PathPoint) {
        guard hasAnchorActivationLayer, !AppState.shared.isShowingEditor else { return }
        if physicalClickTaintedGesture { return }

        // Post-gesture cooldown: don't start the anchor candidate immediately after
        // a gesture ended. This prevents a "transition" finger that briefly rests
        // between strokes from tripping the anchor. The cooldown equals the anchor
        // activation delay itself — so only a deliberate pause (longer than the delay)
        // will reach the anchor candidate phase.
        let elapsed = ProcessInfo.processInfo.systemUptime - lastInteractionEndTime
        let cooldown = AppState.shared.recognitionSettings.anchorActivationDelay
        guard elapsed >= cooldown else {
            ztLog("ANCHOR-ACTIVATION: SKIP cooldown elapsed=\(String(format: "%.3f", elapsed)) < \(String(format: "%.2f", cooldown))")
            return
        }

        if anchorActivationActive { return }

        if let anchorPathIndex, anchorPathIndex != pathIndex {
            if anchorCandidateReadyForGestureFingers() {
                ztLog("ANCHOR-ACTIVATION: EARLY-ON additionalTouch path=\(pathIndex)")
                activateAnchorIfReady(allowAdditionalTouches: true)
                return
            }
            ztLog("ANCHOR-ACTIVATION: CANCEL additionalTouchBeforeActive")
            resetAnchorActivation(reason: "additionalTouchBeforeActive")
            return
        }

        guard anchorPathIndex == nil, activeTouches.count == 1, completedPaths.isEmpty else { return }
        beginAnchorCandidate(pathIndex: pathIndex, point: point)
    }

    /// Creates the anchor candidate for a single resting finger: zone-filters the
    /// start point, then arms the activation and visual-indicator timers. Shared
    /// by the touch-down path and the deferred (post-cooldown) re-evaluation path.
    private func beginAnchorCandidate(pathIndex: Int32, point: PathPoint) {
        // Zone filter: if the user has restricted which zones can start an anchor,
        // map the touch's start position to a 9×9 grid cell index and bail if blocked.
        // Cell index = row * 9 + col; row 0 = top (y≈1), row 8 = bottom (y≈0).
        let allowedZones = AppState.shared.recognitionSettings.anchorAllowedZones
        if allowedZones.count < 81 {
            let col = min(Int(point.x * 9), 8)
            let row = min(Int((1.0 - point.y) * 9), 8)
            let cellIndex = row * 9 + col
            if !allowedZones.contains(cellIndex) {
                ztLog("ANCHOR-ACTIVATION: SKIP cell=\(cellIndex) (blocked zone row=\(row) col=\(col))")
                return
            }
        }

        anchorPathIndex = pathIndex
        anchorStartPoint = point
        let delay = AppState.shared.recognitionSettings.anchorActivationDelay
        let work = DispatchWorkItem { [weak self] in
            self?.activateAnchorIfReady()
        }
        anchorActivationTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        let candidateStartedAt = ProcessInfo.processInfo.systemUptime
        anchorCandidateStartedAt = candidateStartedAt
        anchorCandidateDelay = delay
        // Visual indicator starts earlier than the functional gate so the
        // "emerging" bloom has enough on-screen time to be perceptible.
        let indicatorDelay = max(0.12, delay * 0.4)
        let indicatorWork = DispatchWorkItem { [weak self] in
            self?.updateAnchorCandidateIndicator(pathIndex: pathIndex, startedAt: candidateStartedAt, delay: delay)
        }
        anchorCandidateIndicatorTimer = indicatorWork
        if indicatorDelay < delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + indicatorDelay, execute: indicatorWork)
        }
        ztLog("ANCHOR-ACTIVATION: candidate path=\(pathIndex) delay=\(String(format: "%.2f", delay))")
    }

    /// Re-evaluates anchor candidacy for a finger that is still resting. The
    /// touch-down handler only checks the post-gesture cooldown once, at landing;
    /// a finger that lands within the cooldown is skipped and never reconsidered,
    /// so a deliberate still hold produces no candidate. This runs per frame and
    /// starts the candidate once the cooldown has elapsed, provided the finger is
    /// alone and has not moved past the anchor threshold (a transition/drag finger
    /// would exceed it and is correctly ignored).
    private func maybeStartDeferredAnchorCandidate() {
        guard hasAnchorActivationLayer, !AppState.shared.isShowingEditor else { return }
        if physicalClickTaintedGesture { return }
        guard anchorPathIndex == nil, !anchorActivationActive else { return }
        guard activeTouches.count == 1, completedPaths.isEmpty else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastInteractionEndTime
        guard elapsed >= AppState.shared.recognitionSettings.anchorActivationDelay else { return }
        guard let (pid, path) = activeTouches.first, let last = path.last else { return }
        // Ignore a finger that has been travelling — only a genuinely resting
        // finger should be promoted. Origin is the finger's current position so
        // the movement gate applies from here forward.
        let origin = path.first ?? last
        let dx = last.x - origin.x
        let dy = last.y - origin.y
        guard sqrt(dx * dx + dy * dy) <= anchorMovementThreshold else { return }
        ztLog("ANCHOR-ACTIVATION: DEFERRED-START path=\(pid) (cooldown elapsed)")
        beginAnchorCandidate(pathIndex: pid, point: last)
    }

    private func updateAnchorCandidateIndicator(pathIndex: Int32, startedAt: TimeInterval, delay: TimeInterval) {
        guard !physicalClickTaintedGesture,
              !anchorActivationActive,
              anchorPathIndex == pathIndex,
              let anchorPath = activeTouches[pathIndex],
              !anchorMovedTooFar(anchorPath, threshold: anchorMovementThreshold) else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let visibleStart = max(0.12, delay * 0.4)
        let visibleDuration = max(delay - visibleStart, 0.01)
        let progress = min(max((elapsed - visibleStart) / visibleDuration, 0), 1)
        GestureOverlayWindow.shared.showAnchorCandidate(progress: progress)

        guard progress < 1 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.updateAnchorCandidateIndicator(pathIndex: pathIndex, startedAt: startedAt, delay: delay)
        }
        anchorCandidateIndicatorTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: work)
    }

    private func anchorCandidateReadyForGestureFingers() -> Bool {
        guard anchorPathIndex != nil, anchorCandidateDelay > 0 else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - anchorCandidateStartedAt
        // Promote candidate earlier for tap-driven anchor flows so a quick
        // one-finger touch can become the anchor before the full hold delay.
        let visibleStart = max(0.06, anchorCandidateDelay * 0.25)
        return elapsed >= visibleStart
    }

    private func updateAnchorActivationState() {
        if anchorPathIndex == nil { maybeStartDeferredAnchorCandidate() }
        guard let anchorPathIndex else { return }
        guard let anchorPath = activeTouches[anchorPathIndex] else {
            let heldFor = ProcessInfo.processInfo.systemUptime - anchorCandidateStartedAt
            ztLog("ANCHOR-ACTIVATION: CANCEL reason=\(anchorActivationActive ? "anchorLifted" : "candidateLifted") heldFor=\(String(format: "%.3f", heldFor)) needed=\(String(format: "%.2f", anchorCandidateDelay))")
            if anchorActivationActive {
                resetGesture()
            } else {
                resetAnchorActivation(reason: "candidateLifted")
            }
            return
        }
        if anchorActivationActive { return }
        guard !anchorMovedTooFar(anchorPath, threshold: anchorMovementThreshold) else {
            let dist = anchorMovedDistance(anchorPath)
            ztLog("ANCHOR-ACTIVATION: CANCEL reason=\(anchorActivationActive ? "anchorMovedActive" : "anchorMovedBeforeActive") dist=\(String(format: "%.3f", dist)) threshold=\(String(format: "%.3f", anchorMovementThreshold))")
            resetAnchorActivation(reason: "anchorMovedBeforeActive")
            return
        }
    }

    private func activateAnchorIfReady(allowAdditionalTouches: Bool = false) {
        guard !physicalClickTaintedGesture,
              let anchorPathIndex,
              let anchorPath = activeTouches[anchorPathIndex],
              (allowAdditionalTouches || activeTouches.count == 1),
              !anchorMovedTooFar(anchorPath) else {
                        ztLog("ANCHOR-ACTIVATION: CANCEL activationConditionsChanged")
                        resetAnchorActivation(reason: "activationConditionsChanged")
            return
        }

        anchorActivationActive = true
        anchorCandidateIndicatorTimer?.cancel()
        anchorCandidateIndicatorTimer = nil
        anchorActivationTimer?.cancel()
        anchorActivationTimer = nil
        AppState.shared.isGestureActive = true
        ztLog("ANCHOR-ACTIVATION: ON path=\(anchorPathIndex)")
        let allPaths = buildAnchorOverlayPaths()
        GestureOverlayWindow.shared.showTrace(paths: allPaths.isEmpty ? [visibleAnchorPath(anchorPath)] : allPaths, fingerCount: recognizedActiveFingerCount())
    }

    private func handleAnchorActivationGesture(paths: [[PathPoint]]) {
        let fingerCount = paths.count
        guard (1...5).contains(fingerCount) else {
            ztLog("ANCHOR-ACTIVATION: IGNORE count=\(fingerCount)")
            finishAnchorAdditionalGesture()
            return
        }

        let normalizedPaths = paths.map { path in
            guard let first = path.first else { return path }
            return path.map { point in
                PathPoint(x: point.x, y: point.y, timestamp: point.timestamp - first.timestamp)
            }
        }
        let primaryPath = normalizedPaths.max(by: { $0.count < $1.count }) ?? []

        ztLog("ANCHOR-ACTIVATION: ROUTE count=\(fingerCount)")
        handleGestureComplete(primaryPath: primaryPath, fingerCount: fingerCount, paths: normalizedPaths)
        finishAnchorAdditionalGesture()
    }

    private func finishAnchorContinuousGesture(_ gesture: GestureDefinition, now: TimeInterval) {
        ztLog("ANCHOR-ACTIVATION: CONTINUOUS-END \(gesture.name)")
        continuousStepHistory.removeAll()
        recentContinuousGesture = gesture
        recentContinuousTime = now
        activeContinuousGesture = nil
        continuousAccumulator = 0
        continuousDirection = 0
        pinchLastDistance = 0
        finishAnchorAdditionalGesture()
    }

    private func finishAnchorAdditionalGesture() {
        completionTimer?.cancel()
        completionTimer = nil
        completedPaths.removeAll()
        maxFingerCount = 0
        cachedContinuousCandidates = []
        cachedPinchCandidates = []
        cachedDialCandidates = []
        cachedCandidateFingerCount = 0
        updateCaptureFlags()
        AppState.shared.isGestureActive = true
        let allPaths = buildAnchorOverlayPaths()
        if !allPaths.isEmpty {
            GestureOverlayWindow.shared.showTrace(paths: allPaths, fingerCount: recognizedActiveFingerCount())
        }
    }

    private func anchorMovedTooFar(_ path: [PathPoint], threshold: Double? = nil) -> Bool {
        guard let start = anchorStartPoint, let last = path.last else { return false }
        let dx = last.x - start.x
        let dy = last.y - start.y
        return sqrt(dx * dx + dy * dy) > (threshold ?? anchorMovementThreshold)
    }

    /// Straight-line distance the anchor finger has moved from its origin. Used
    /// for diagnostic logging when a candidate is cancelled for movement.
    private func anchorMovedDistance(_ path: [PathPoint]) -> Double {
        guard let start = anchorStartPoint, let last = path.last else { return 0 }
        let dx = last.x - start.x
        let dy = last.y - start.y
        return sqrt(dx * dx + dy * dy)
    }

    private func resetAnchorActivation(reason: String) {
        if anchorPathIndex != nil || anchorActivationActive {
            ztLog("ANCHOR-ACTIVATION: OFF reason=\(reason) active=\(anchorActivationActive)")
        }
        anchorActivationTimer?.cancel()
        anchorActivationTimer = nil
        anchorCandidateIndicatorTimer?.cancel()
        anchorCandidateIndicatorTimer = nil
        anchorCandidateStartedAt = 0
        anchorCandidateDelay = 0
        anchorPathIndex = nil
        anchorStartPoint = nil
        anchorActivationActive = false
        AppState.shared.isGestureActive = false
        GestureOverlayWindow.shared.hideTrace()
    }

    private func visibleAnchorPath(_ path: [PathPoint]) -> [PathPoint] {
        guard let first = path.first else { return path }
        return path.count > 1 ? path : [first, first]
    }

    private func buildAnchorOverlayPaths() -> [[PathPoint]] {
        var paths = buildAllPaths()
        if let anchorPathIndex, let anchorPath = activeTouches[anchorPathIndex] {
            paths.append(visibleAnchorPath(anchorPath))
        }
        return paths
    }

    private func resetGesture() {
        logDiag("RESET active=\(activeTouches.count) completed=\(completedPaths.count) modAct=\(modifierActivated)")
        completionTimer?.cancel()
        completionTimer = nil
        resetAnchorActivation(reason: "gestureReset")
        // Safety net: ensure Mission Control (Cycle Windows overview) is never left
        // open if the gesture ended via an edge path. Idempotent — no-op if closed.
        WindowManager.exitMissionControl()
        activeTouches.removeAll()
        completedPaths.removeAll()
        contactPeakSize.removeAll()
        contactPeakDensity.removeAll()
        contactCurrentSize.removeAll()
        lastFingerSize = 0
        maxFingerCount = 0
        modifierActivated = false
        activeContinuousGesture = nil
        continuousAccumulator = 0
        pinchLastDistance = 0
        physicalClickTaintedGesture = false
        // Arm the post-gesture cooldown from the ONE central teardown point. Every
        // end-path (anchor lift, discard, finalize, dead gesture, continuous lift)
        // funnels through here, so a rapid re-touch right after any interaction
        // (e.g. one-finger continuous movement with slight lifts) can't immediately
        // re-arm the anchor candidate. See handleAnchorActivationTouchBegan.
        lastInteractionEndTime = ProcessInfo.processInfo.systemUptime
        updateCaptureFlags()
        AppState.shared.isGestureActive = false
    }

    private func finalizeGesture() {
        logDiag("FINALIZE active=\(activeTouches.count) completed=\(completedPaths.count)")
        completionTimer?.cancel()
        completionTimer = nil
        // A physical click during this touch session means it belongs to another
        // app — discard without recognizing anything.
        if physicalClickTaintedGesture {
            ztLog("PHYSICAL-CLICK: discarding tainted gesture in finalize")
            resetGesture()
            GestureOverlayWindow.shared.hideTrace()
            return
        }
        // Merge any remaining active touches as completed
        for (pathIndex, pts) in activeTouches where pathIndex != anchorPathIndex {
            completedPaths.append(pts)
        }
        activeTouches.removeAll()
        updateCaptureFlags()

        guard !completedPaths.isEmpty else {
            resetGesture()
            GestureOverlayWindow.shared.hideTrace()
            return
        }

        let paths = completedPaths
        let fingers = maxFingerCount

        // When editor is open and recording, forward to AppState instead of recognition
        if AppState.shared.isShowingEditor && isRecordingArmed {
            let appStatePaths = paths
            let appStateFingers = fingers
            resetGesture()
            let appState = AppState.shared
            appState.isRecordingArmed = false
            appState.recordedPaths = appStatePaths
            appState.recordedFingerCount = appStateFingers
            appState.recordingCompletionCounter += 1
            return
        }

        // Editor open but not recording — just discard
        if AppState.shared.isShowingEditor {
            resetGesture()
            return
        }

        // Normal recognition flow
        // Use the longest individual finger path for matching — centroid averaging
        // creates noisy zigzag artifacts that destroy direction signal
        let primaryPath = paths.max(by: { $0.count < $1.count }) ?? []
        resetGesture()
        handleGestureComplete(primaryPath: primaryPath, fingerCount: fingers, paths: paths)
    }

    private func scheduleCompletionTimeout() {
        ztLog("COMPLETION-TIMER: scheduled 0.3s (active=\(activeTouches.count) completed=\(completedPaths.count) fingers=\(maxFingerCount))")
        completionTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            ztLog("COMPLETION-TIMER: fired")
            self?.finalizeGesture()
        }
        completionTimer = work
        // 0.3s after last finger lifts with others still down, complete the gesture
        // Use main queue — all touch state mutations must be on main thread
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func buildAllPaths() -> [[PathPoint]] {
        var paths = completedPaths
        for (pathIndex, pts) in activeTouches where pathIndex != anchorPathIndex { paths.append(pts) }
        return paths
    }

    /// Pick a matching continuous gesture from pre-filtered candidates.
    private func pickContinuousGesture(from candidates: [GestureDefinition], isHorizontal: Bool) -> GestureDefinition? {
        guard !candidates.isEmpty else { return nil }
        // If only one candidate, use it regardless of axis
        if candidates.count == 1 { return candidates.first }
        // Multiple candidates — pick the one matching the detected axis
        let targetAxis: ContinuousAxis = isHorizontal ? .horizontal : .vertical
        return candidates.first { $0.continuousAxis == targetAxis } ?? candidates.first
    }

    private func continuousMinInterval(for control: ContinuousControl) -> TimeInterval {
        switch control {
        case .cycleWindows:
            0.32
        case .scrollDesktops:
            0.18
        default:
            0.03
        }
    }

    // MARK: - Geometry Helpers

    /// Average pairwise distance between all finger positions (normalized 0-1 space)
    private static func averagePairwiseDistance(_ positions: [PathPoint]) -> Double {
        guard positions.count >= 2 else { return 0 }
        var total = 0.0
        var count = 0
        for i in 0..<positions.count {
            for j in (i+1)..<positions.count {
                let dx = positions[j].x - positions[i].x
                let dy = positions[j].y - positions[i].y
                total += sqrt(dx * dx + dy * dy)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// Sum absolute direction changes along the path, ignoring tiny jitter segments.
    /// Straight swipes stay near 0, while L-shapes/arcs/circles accumulate larger values.
    private static func cumulativeTurn(_ path: [PathPoint]) -> Double {
        guard path.count >= 3 else { return 0 }

        var angles: [Double] = []
        angles.reserveCapacity(path.count - 1)

        for index in 1..<path.count {
            let dx = path[index].x - path[index - 1].x
            let dy = path[index].y - path[index - 1].y
            let length = sqrt(dx * dx + dy * dy)
            guard length >= 0.004 else { continue }
            angles.append(atan2(dy, dx))
        }

        guard angles.count >= 2 else { return 0 }

        var total = 0.0
        for index in 1..<angles.count {
            var delta = angles[index] - angles[index - 1]
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            total += abs(delta)
        }
        return total
    }

    /// Rotation angle of finger constellation (radians, -π to π).
    /// Uses sorted pathIndex keys for consistent finger ordering across frames.
    /// Computes average per-finger angular change from centroid to measure pure rotation.
    private static func computeRotation(current: [(key: Int32, pos: PathPoint)], previous: [(key: Int32, pos: PathPoint)]) -> Double {
        guard current.count >= 2, previous.count >= 2 else { return 0 }
        // Build lookup for previous positions
        let prevMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0.pos) })
        // Current centroid
        let cx = current.map(\.pos.x).reduce(0, +) / Double(current.count)
        let cy = current.map(\.pos.y).reduce(0, +) / Double(current.count)
        // Previous centroid
        let pcx = previous.map(\.pos.x).reduce(0, +) / Double(previous.count)
        let pcy = previous.map(\.pos.y).reduce(0, +) / Double(previous.count)

        var totalDelta = 0.0
        var count = 0
        for (key, pos) in current {
            guard let prev = prevMap[key] else { continue }
            let curAngle = atan2(pos.y - cy, pos.x - cx)
            let prevAngle = atan2(prev.y - pcy, prev.x - pcx)
            var d = curAngle - prevAngle
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            totalDelta += d
            count += 1
        }
        return count > 0 ? totalDelta / Double(count) : 0
    }

    // MARK: - Diagnostics

    private func logDiag(_ msg: String) {
        let now = ProcessInfo.processInfo.systemUptime
        // Print state transitions + periodic heartbeat every 2s
        if msg.hasPrefix("SKIP") || msg.hasPrefix("MODIFIER") || msg.hasPrefix("RESET") || msg.hasPrefix("FINALIZE") || (now - lastDiagTime) > 2.0 {
            lastDiagTime = now
            print("[TCM] \(msg) | mt=\(mtCallbackCount) proc=\(processedCount) active=\(activeTouches.count) capturing=\(isCapturingGesture) modAct=\(modifierActivated)")
        }
    }

    // MARK: - Modifier Detection

    func isModifierHeld(_ key: RecognitionSettings.LayerActivation) -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return Self.flagsContain(flags, key: key) || Self.nsContains(key: key)
    }

    /// Pure function — no instance state, safe for static context too.
    static func flagsContain(_ flags: CGEventFlags, key: RecognitionSettings.LayerActivation) -> Bool {
        switch key {
        case .alwaysOn: return true
        case .anchor: return false
        case .fn, .globe: return flags.contains(.maskSecondaryFn)
        case .shift: return flags.contains(.maskShift)
        case .control: return flags.contains(.maskControl)
        case .option: return flags.contains(.maskAlternate)
        case .command: return flags.contains(.maskCommand)
        }
    }

    /// Check NSEvent.modifierFlags — works when CGEventSource doesn't (e.g. after recompile).
    static func nsContains(key: RecognitionSettings.LayerActivation) -> Bool {
        let ns = NSEvent.modifierFlags
        switch key {
        case .alwaysOn: return true
        case .anchor: return TouchCaptureManager.shared.anchorActivationActive
        case .fn, .globe:
            // Check NSEvent, AND globalFnActive from flagsChanged monitor
            return ns.contains(.function) || TouchCaptureManager.shared.globalFnActive
        case .shift: return ns.contains(.shift)
        case .control: return ns.contains(.control)
        case .option: return ns.contains(.option)
        case .command: return ns.contains(.command)
        }
    }

    // MARK: - Modifier Polling

    /// Poll the modifier key state at 60Hz so the event tap callback can use
    /// a reliable cached value instead of CGEventSource.flagsState (which is
    /// unreliable inside event tap callbacks for Fn/Globe detection).
    ///
    /// Rising edge is debounced: a single phantom sample of `flagsState` is
    /// not enough to flip `polledModifierActive` to true — we require two
    /// consecutive samples (~32ms) reporting the modifier as held. Falling
    /// edge is immediate so a real key release is honoured without latency.
    private func startModifierPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        var lastFlags: UInt64 = 0
        var lastNSFlags: UInt = 0
        var pendingActive: Bool = false  // tentative true, awaiting confirmation
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = CGEventSource.flagsState(.hidSystemState)
            let rawFlags = flags.rawValue
            let nsFlags = NSEvent.modifierFlags
            let nsRaw = nsFlags.rawValue

            // Log when flags change to see what keys are being detected
            if rawFlags != lastFlags || nsRaw != lastNSFlags {
                if rawFlags != 0 || nsRaw != 0 {
                    ztLog("POLL: cg=0x\(String(rawFlags, radix: 16)) ns=0x\(String(nsRaw, radix: 16)) cgFn=\(flags.contains(.maskSecondaryFn)) nsFn=\(nsFlags.contains(.function)) gFn=\(self.globalFnActive)")
                }
                lastFlags = rawFlags
                lastNSFlags = nsRaw
            }

            // Use reliable sources for modifier detection: listenOnly-tap state
            // plus debounced CGEventSource flags. Avoid trusting NSEvent.function
            // directly because it can transiently report Fn during synthetic flows.
            let rawSample = self.globalFnActive || self.cachedLayerKeys.contains { key in
                key != .alwaysOn && TouchCaptureManager.flagsContain(flags, key: key)
            }

            // Trust listenOnly-tap state immediately; debounce flagsState path.
            let trustedSample = self.globalFnActive

            if trustedSample {
                // Trusted source asserts true — set immediately, clear pending.
                self.polledModifierActive = true
                pendingActive = false
            } else if rawSample {
                // Only the (unreliable) flagsState path says true. Require two
                // consecutive samples before flipping the live signal on.
                if pendingActive {
                    self.polledModifierActive = true
                } else {
                    pendingActive = true
                }
            } else {
                // No source reports the modifier — release immediately.
                self.polledModifierActive = false
                pendingActive = false
            }
        }
        timer.resume()
        modifierPollTimer = timer

        // Global NSEvent monitor for flagsChanged
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            let fnHeld = event.modifierFlags.contains(.function)
            if fnHeld != self.globalFnActive {
                ztLog("FLAGS-MONITOR: fn=\(fnHeld) keyCode=\(event.keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16))")
            }
            self.globalFnActive = fnHeld
            if fnHeld { self.polledModifierActive = true }
        }
        ztLog("NS-MONITOR: created=\(flagsMonitor != nil)")

        // Separate listenOnly CGEventTap for flagsChanged + keyDown/keyUp.
        // A .listenOnly tap receives ALL events including Globe/Fn which macOS
        // may withhold from .defaultTap taps. This is the most reliable Fn source.
        installFnListenTap()
    }

    /// Install a dedicated .listenOnly event tap to capture keyboard modifier
    /// events (including Globe/Fn) that macOS may not deliver to .defaultTap taps.
    private func installFnListenTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                let mgr = TouchCaptureManager.shared

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = mgr.fnListenTap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let hasFn = event.flags.contains(.maskSecondaryFn)

                if type == .flagsChanged {
                    // keyCode 63 = physical Fn/Globe key
                    let isFnKey = keyCode == 63
                    if isFnKey || hasFn != mgr.globalFnActive {
                        ztLog("FN-LISTEN: type=flags keyCode=\(keyCode) hasFn=\(hasFn) isFnKey=\(isFnKey) rawFlags=0x\(String(event.flags.rawValue, radix: 16))")
                    }
                    if isFnKey {
                        // Fn/Globe key event — pressed if maskSecondaryFn is set, released if not
                        mgr.globalFnActive = hasFn
                        if hasFn { mgr.polledModifierActive = true }
                    } else if hasFn {
                        // Another modifier key with Fn held simultaneously
                        mgr.globalFnActive = true
                        mgr.polledModifierActive = true
                    }
                } else if type == .keyDown || type == .keyUp {
                    // Some systems deliver Fn as keyDown/keyUp with keyCode 63
                    if keyCode == 63 {
                        let pressed = type == .keyDown
                        ztLog("FN-LISTEN: type=key\(pressed ? "Down" : "Up") keyCode=63 rawFlags=0x\(String(event.flags.rawValue, radix: 16))")
                        mgr.globalFnActive = pressed
                        if pressed { mgr.polledModifierActive = true }
                    }
                } else if type == .leftMouseDown {
                    // A physical trackpad click arrives as leftMouseDown WHILE the
                    // finger is still pressed (size high). A tap-to-click's synthetic
                    // leftMouseDown arrives ~50ms after the finger has lifted (size ~0).
                    // Only the former should suppress our anchor activation.
                    //
                    // IMPORTANT: while anchor is active the anchor finger stays pressed
                    // on the pad, keeping lastFingerSize high. Gesture taps (tap-to-click)
                    // would therefore always look like a physical click — false positive.
                    // Skip the check entirely while anchor is active; the user's deliberate
                    // anchor + gesture workflow must not be interrupted.
                    if !mgr.anchorActivationActive && mgr.lastFingerSize >= 0.3 {
                        mgr.handlePhysicalClickDuringTouch()
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            ztLog("FN-LISTEN: FAILED to create tap")
            return
        }

        fnListenTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        fnListenSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ztLog("FN-LISTEN: installed ok")
    }

    private func stopModifierPolling() {
        modifierPollTimer?.cancel()
        modifierPollTimer = nil
        polledModifierActive = false
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        physicalClickActive = false
        physicalClickTaintedGesture = false
        if let tap = fnListenTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = fnListenSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        fnListenTap = nil
        fnListenSource = nil
        globalFnActive = false
    }

    // MARK: - System Gesture Blocking

    /// Install a CGEventTap to swallow trackpad/scroll/gesture events while the
    /// modifier key is held. This prevents macOS from interpreting swipes as
    /// Mission Control, desktop switch, etc.
    private func installEventTap() {
        // Block all trackpad-related event types:
        // 22 = scrollWheel, 29 = gesture, 30 = magnify, 31 = swipe,
        // 18 = rotate, 32 = smartMagnify, 33 = quickLook (Force Touch),
        // 34 = pressure, 37 = directTouch
        // Also block right-click (3/5), other mouse (25/26/27) to prevent
        // 2-finger tap context menus and force-click actions.
        // Also include flagsChanged to capture Fn/Globe key presses via the
        // event tap (CGEventSource.flagsState is unreliable for Fn on Tahoe).
        var eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        for t: UInt32 in [18, 27, 29, 30, 31, 32, 33, 34, 37] {
            eventMask |= (1 << t)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                // Re-enable tap if system disabled it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = TouchCaptureManager.shared.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                // CRITICAL: This callback must be ultra-fast. NO @Observable access.
                // All values read here are plain stored properties on non-@Observable TCM,
                // or direct CGEventSource calls. Zero lock acquisition.
                let mgr = TouchCaptureManager.shared

                // Capture Fn/Globe state from flagsChanged events.
                // Also detect Fn via keyCode 63, which may not set .maskSecondaryFn
                // when "Press 🌐 key to" is configured in System Settings.
                if type == .flagsChanged {
                    let hasFn = event.flags.contains(.maskSecondaryFn)
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    if keyCode == 63 {
                        // Physical Fn/Globe key changed state
                        mgr.globalFnActive = hasFn
                    } else if hasFn {
                        // Another modifier changed while Fn is still held
                        mgr.globalFnActive = true
                    }
                    if mgr.globalFnActive { mgr.polledModifierActive = true }
                    return Unmanaged.passUnretained(event)  // always pass through
                }

                // Determine whether to block system events:
                // - If any non-alwaysOn layer's modifier is held AND we're capturing → block
                // - If all active layers are Always On → only block during continuous session
                let shouldBlock: Bool
                // Check modifier state from sources known to be reliable inside
                // an event-tap callback. We deliberately do NOT call
                // CGEventSource.flagsState(.hidSystemState) here — that API can
                // return phantom Fn=true readings, which would cause the tap to
                // swallow legitimate macOS gestures (scroll, etc.) when the user
                // is not holding any modifier.
                //   1. event.flags     — modifiers baked into this event itself
                //   2. polledModifierActive — debounced 16ms poll (see startModifierPolling)
                let eventFlags = event.flags
                let anyModifierHeld = mgr.anchorActivationActive
                    || mgr.polledModifierActive
                    || mgr.cachedLayerKeys.contains(where: { key in
                        key != .alwaysOn && TouchCaptureManager.flagsContain(eventFlags, key: key)
                    })
                let hasAlwaysOnSystemGestureLayer = mgr.cachedLayerKeys.enumerated().contains { index, key in
                    index >= 2 && key == .alwaysOn
                }
                let isNativeGestureEvent = type.rawValue == 29 || type.rawValue == 31

                if anyModifierHeld && (type == .rightMouseDown || type == .rightMouseUp
                    || type == .otherMouseDown || type == .otherMouseUp) {
                    return nil
                }

                if anyModifierHeld {
                    // Only block while we are actively handling a gesture (or when
                    // Fn is confirmed from the listenOnly tap). This avoids transient
                    // modifier spikes from suppressing normal two-finger scrolling.
                    shouldBlock = mgr.isCapturingGesture || mgr.globalFnActive
                } else if hasAlwaysOnSystemGestureLayer && isNativeGestureEvent {
                    // Native Space/Mission Control swipes can arrive before the raw
                    // multitouch callback has raised isAlwaysOnMultitouch. If a 3+
                    // Always On layer exists, own those gesture/swipe events up front.
                    shouldBlock = true
                } else if mgr.isAlwaysOnMultitouch {
                    // 3+ fingers on Always On layer: block immediately to prevent
                    // macOS from interpreting as 2-finger scroll
                    shouldBlock = true
                } else {
                    // No modifier held: only block when a continuous-family gesture is active
                    shouldBlock = mgr.isContinuousSession
                }

                guard shouldBlock else {
                    mgr.isCurrentlyBlocking = false
                    return Unmanaged.passUnretained(event)
                }

                // Block — swallow the system event
                if true {
                    // Safety timeout: never block for more than 5 seconds
                    let now = ProcessInfo.processInfo.systemUptime
                    if !mgr.isCurrentlyBlocking {
                        mgr.blockingStartTime = now
                        mgr.isCurrentlyBlocking = true
                    } else if (now - mgr.blockingStartTime) > mgr.maxBlockingDuration {
                        // Something is stuck — stop blocking to prevent system freeze
                        mgr.isCurrentlyBlocking = false
                        return Unmanaged.passUnretained(event)
                    }
                    return nil  // swallow the event
                }
                mgr.isCurrentlyBlocking = false
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("[TCM] Failed to create event tap — Accessibility permission needed")
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        tapRunLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        tapRunLoopSource = nil
    }
}
