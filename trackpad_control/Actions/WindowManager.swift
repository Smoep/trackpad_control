import AppKit
import os.log
import Foundation

private let wmLog = Logger(subsystem: "com.trackpadcontrol.debug", category: "WindowManager")

// Bulletproof file logger — os_log archive only captures .error in Release.
// Keep desktop/overlay diagnostics in the main app diagnostics log so gesture,
// activation, space, and overlay decisions share one timeline.
private let mtdLogURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("TrackpadControl", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("tc-debug.log")
}()
private let mtdLogQueue = DispatchQueue(label: "tc-debug.mtd.queue")
private let mtdLogFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
func mtdLog(_ s: String) {
    let line = "\(mtdLogFormatter.string(from: Date())) \(s)\n"
    mtdLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: mtdLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: mtdLogURL) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            }
        } else {
            try? data.write(to: mtdLogURL)
        }
    }
}

private let moveLeftDesktopScript: NSAppleScript = {
    let script = NSAppleScript(source: "tell application \"System Events\" to key code 123 using control down")!
    script.compileAndReturnError(nil)
    return script
}()

private let moveRightDesktopScript: NSAppleScript = {
    let script = NSAppleScript(source: "tell application \"System Events\" to key code 124 using control down")!
    script.compileAndReturnError(nil)
    return script
}()

// Private AX function to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// Private CGS APIs for Spaces management (used by Moom, Magnet, etc.)
typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ conn: CGSConnectionID, _ windows: NSArray, _ spaceID: UInt64) -> Void

// SkyLight (SLS*) variants — on macOS Tahoe, CGS* APIs were renamed/aliased to
// SLS*. Some build/sign permutations only respond to SLS. We'll prefer SLS.
// SkyLight is a private framework not exposed to the linker, so we resolve
// symbols at runtime via dlsym from RTLD_DEFAULT (already loaded with AppKit).
private let _slsHandle: UnsafeMutableRawPointer? = {
    // Attempt to load SkyLight explicitly so its symbols are present in our process.
    return dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
}()

private func slsSym<T>(_ name: String, as type: T.Type) -> T? {
    let handle = _slsHandle ?? UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    guard let raw = dlsym(handle, name) else { return nil }
    return unsafeBitCast(raw, to: type)
}

private typealias SLSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
private typealias SLSAddRemoveFn = @convention(c) (CGSConnectionID, NSArray, NSArray) -> Void
private typealias SLSMoveFn = @convention(c) (CGSConnectionID, NSArray, UInt64) -> Void
private typealias SLSCopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> CFArray

private let SLSMainConnectionID_dyn: SLSMainConnectionIDFn? = slsSym("SLSMainConnectionID", as: SLSMainConnectionIDFn.self)
private let SLSAddWindowsToSpaces_dyn: SLSAddRemoveFn? = slsSym("SLSAddWindowsToSpaces", as: SLSAddRemoveFn.self)
private let SLSRemoveWindowsFromSpaces_dyn: SLSAddRemoveFn? = slsSym("SLSRemoveWindowsFromSpaces", as: SLSAddRemoveFn.self)
private let SLSMoveWindowsToManagedSpace_dyn: SLSMoveFn? = slsSym("SLSMoveWindowsToManagedSpace", as: SLSMoveFn.self)
private let SLSCopySpacesForWindows_dyn: SLSCopySpacesForWindowsFn? = slsSym("SLSCopySpacesForWindows", as: SLSCopySpacesForWindowsFn.self)

// CoreDock private API — toggles Mission Control / Exposé. Resolved at runtime
// (RTLD_DEFAULT, with a framework fallback) to stay shortcut-independent.
private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Void
private let _coreDockHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock", RTLD_LAZY)
}()
private let CoreDockSendNotification_dyn: CoreDockSendNotificationFn? = {
    let handle = _coreDockHandle ?? UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    guard let raw = dlsym(handle, "CoreDockSendNotification") else { return nil }
    return unsafeBitCast(raw, to: CoreDockSendNotificationFn.self)
}()

/// Moves and resizes the frontmost window using the Accessibility API.
enum WindowManager {

    // App-tracked current desktop index in the user-visible spaces list.
    // macOS Tahoe broke the "current space" query APIs (they all return the
    // dock/internal space), so we maintain our own counter. Initial value 0 =
    // assume Desktop 1 at app launch. Updated on every move-to-desktop.
    nonisolated(unsafe) static var currentSpaceIdx: Int = 0
    nonisolated(unsafe) static var internalSwitchInFlight: Bool = false
    nonisolated(unsafe) static var pendingInternalSpaceDelta: Int = 0

    /// Returns true only when the active desktop is Desktop 1.
    /// Falls back to the tracked index if private API probing is unavailable.
    static func isOnDesktopOne() -> Bool {
        if let idx = activeDesktopIndex() {
            currentSpaceIdx = idx
            return idx == 0
        }
        return currentSpaceIdx == 0
    }

    /// Best-effort probe of the active desktop index using managed display spaces.
    /// Index is relative to user desktop spaces (Desktop 1 == 0).
    private static func activeDesktopIndex() -> Int? {
        let conn = SLSMainConnectionID_dyn?() ?? CGSMainConnectionID()
        let rawSpaces = CGSCopyManagedDisplaySpaces(conn) as NSArray

        for case let display as NSDictionary in rawSpaces {
            guard let current = display["Current Space"] as? NSDictionary else { continue }
            let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
                ?? (current["id64"] as? NSNumber)?.uint64Value
            guard let currentID else { continue }

            guard let spaces = display["Spaces"] as? [NSDictionary], !spaces.isEmpty else { continue }

            var desktopIndex = 0
            for space in spaces {
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                let spaceID = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
                    ?? (space["id64"] as? NSNumber)?.uint64Value

                if type == 0 {
                    if spaceID == currentID {
                        return desktopIndex
                    }
                    desktopIndex += 1
                }
            }
        }

        return nil
    }

    /// Call once at app launch to subscribe to space-change notifications so we
    /// can reset our tracked index when the user switches desktops outside our
    /// gestures (Mission Control, swipe, Ctrl+Arrow keyboard shortcut, etc.).
    static func startTrackingSpaceChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let probed = activeDesktopIndex() {
                currentSpaceIdx = probed
                mtdLog("[MTD] activeSpaceDidChange probed idx=\(probed) internal=\(internalSwitchInFlight)")
            } else if internalSwitchInFlight {
                currentSpaceIdx = max(0, currentSpaceIdx + pendingInternalSpaceDelta)
                mtdLog("[MTD] activeSpaceDidChange internal fallback idx=\(currentSpaceIdx) delta=\(pendingInternalSpaceDelta)")
            } else {
                mtdLog("[MTD] activeSpaceDidChange EXTERNAL — keeping idx=\(currentSpaceIdx) (probe unavailable)")
            }
            pendingInternalSpaceDelta = 0
        }
    }

    // Sticky target: remember last targeted app so consecutive window actions
    // within a few seconds target the same window even if the cursor moves over
    // a different window between gestures.
    private static var stickyPID: pid_t = 0
    private static var stickyTime: TimeInterval = 0
    private static let stickyDuration: TimeInterval = 3.0

    private enum HorizontalSide {
        case left
        case right
    }

    private enum HorizontalLayout: Int, CaseIterable {
        case half
        case quarter
        case threeQuarters
    }

    private static var horizontalCycleSideByPID: [pid_t: HorizontalSide] = [:]
    private static var horizontalCycleIndexByPID: [pid_t: Int] = [:]
    private static var horizontalCycleTimeByPID: [pid_t: TimeInterval] = [:]
    private static let horizontalCycleResetInterval: TimeInterval = 1.25

    private struct WindowCycleCandidate {
        let windowID: CGWindowID
        let pid: pid_t
        let title: String
    }

    private static var windowCycleCandidates: [WindowCycleCandidate] = []
    private static var windowCycleIndex: Int = 0
    private static var windowCycleTime: TimeInterval = 0
    private static let windowCycleResetInterval: TimeInterval = 1.0

    // MARK: - Mission Control overview (Cycle Windows)

    nonisolated(unsafe) private static var missionControlActive = false

    /// Open Mission Control (all-windows overview). Idempotent.
    static func enterMissionControl() {
        DispatchQueue.main.async {
            guard !missionControlActive else { return }
            missionControlActive = true
            CoreDockSendNotification_dyn?("com.apple.expose.awake" as CFString, 0)
        }
    }

    /// Close Mission Control, landing on the currently-focused window. Idempotent.
    static func exitMissionControl() {
        DispatchQueue.main.async {
            guard missionControlActive else { return }
            missionControlActive = false
            CoreDockSendNotification_dyn?("com.apple.expose.awake" as CFString, 0)
        }
    }

    static func cycleVisibleWindows(positive: Bool) {
        DispatchQueue.main.async {
            cycleVisibleWindowsOnMain(positive: positive)
        }
    }

    private static func cycleVisibleWindowsOnMain(positive: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let isNewSession = windowCycleCandidates.isEmpty || (now - windowCycleTime) > windowCycleResetInterval

        if isNewSession {
            let visibleCandidates = visibleWindowCycleCandidates()
            guard !visibleCandidates.isEmpty else { return }

            if windowCycleCandidates.isEmpty || !sameWindowSet(windowCycleCandidates, visibleCandidates) {
                windowCycleCandidates = visibleCandidates
            }

            guard !windowCycleCandidates.isEmpty else { return }

            if let focusedID = focusedWindowID(),
               let focusedIndex = windowCycleCandidates.firstIndex(where: { $0.windowID == focusedID }) {
                windowCycleIndex = focusedIndex
            } else {
                windowCycleIndex = 0
            }
        }

        guard windowCycleCandidates.count > 1 else { return }

        for _ in 0..<windowCycleCandidates.count {
            windowCycleIndex = wrappedWindowCycleIndex(windowCycleIndex + (positive ? 1 : -1))
            let candidate = windowCycleCandidates[windowCycleIndex]
            if focusWindow(candidate) {
                windowCycleTime = now
                mtdLog("[WINCYCLE] focused pid=\(candidate.pid) wid=\(candidate.windowID) title=\(candidate.title)")
                return
            }
        }

        windowCycleCandidates.removeAll()
    }

    private static func sameWindowSet(_ lhs: [WindowCycleCandidate], _ rhs: [WindowCycleCandidate]) -> Bool {
        Set(lhs.map(\.windowID)) == Set(rhs.map(\.windowID))
    }

    private static func wrappedWindowCycleIndex(_ index: Int) -> Int {
        guard !windowCycleCandidates.isEmpty else { return 0 }
        let count = windowCycleCandidates.count
        return ((index % count) + count) % count
    }

    private static func visibleWindowCycleCandidates() -> [WindowCycleCandidate] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seen = Set<CGWindowID>()
        return infoList.compactMap { info -> WindowCycleCandidate? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80,
                  bounds.height >= 60 else {
                return nil
            }

            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0.01 {
                return nil
            }

            let windowID = CGWindowID(windowNumber.uint32Value)
            guard !seen.contains(windowID) else { return nil }
            seen.insert(windowID)

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? owner
            if owner == "Dock" || owner == "Window Server" { return nil }

            return WindowCycleCandidate(windowID: windowID, pid: pid_t(pidNumber.int32Value), title: title)
        }
    }

    private static func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return nil }
        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(windowRef as! AXUIElement, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    private static func focusWindow(_ candidate: WindowCycleCandidate) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: candidate.pid), !app.isTerminated else { return false }
        let appElement = AXUIElementCreateApplication(candidate.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows {
            var windowID = CGWindowID(0)
            guard _AXUIElementGetWindow(window, &windowID) == .success, windowID == candidate.windowID else { continue }
            app.activate(options: .activateIgnoringOtherApps)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                app.activate(options: .activateIgnoringOtherApps)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            return true
        }

        return false
    }

    static func cycleHorizontalTiling(positive: Bool) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let screenH = screen.frame.height

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return }
        let axWindow = windowRef as! AXUIElement

        let side: HorizontalSide = positive ? .right : .left
        let now = ProcessInfo.processInfo.systemUptime
        let pid = app.processIdentifier
        let lastSide = horizontalCycleSideByPID[pid]
        let lastTime = horizontalCycleTimeByPID[pid] ?? 0
        let shouldReset = (lastSide != side) || ((now - lastTime) > horizontalCycleResetInterval)

        let nextIndex: Int
        if shouldReset {
            nextIndex = 0
        } else {
            let prev = horizontalCycleIndexByPID[pid] ?? 0
            nextIndex = (prev + 1) % HorizontalLayout.allCases.count
        }
        let layout = HorizontalLayout(rawValue: nextIndex) ?? .half

        let target = horizontalTargetFrame(side: side, layout: layout, visible: visible)
        setWindowFrame(axWindow, target: target, screenHeight: screenH)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        app.activate()

        horizontalCycleSideByPID[pid] = side
        horizontalCycleIndexByPID[pid] = nextIndex
        horizontalCycleTimeByPID[pid] = now
    }

    static func execute(_ action: WindowAction) {
        mtdLog("execute called: action=\(action.rawValue)")
        wmLog.error("execute called: action=\(action.rawValue)")
        // Desktop switching uses key simulation, not AX
        if action == .moveToLeftDesktop || action == .moveToRightDesktop {
            mtdLog("execute: entering moveToDesktop branch")
            wmLog.error("execute: entering moveToDesktop branch")
            moveToDesktop(direction: action == .moveToLeftDesktop ? .left : .right)
            return
        }

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame  // excludes menu bar and dock (bottom-left origin)
        let screenH = screen.frame.height  // full screen height for coordinate flip

        // Determine target app.
        //
        // Prefer the genuine frontmost window: if the user intentionally selected a
        // different window (click, Cycle Windows, ⌘-Tab), the frontmost app reflects
        // that and we must honor it — otherwise we'd move the previously targeted
        // window instead of the one now in front.
        //
        // The sticky target is only a fallback for the case it was meant to guard:
        // when the frontmost app is missing, or is our own app (our overlay/window can
        // momentarily steal focus during a gesture). In those cases we fall back to the
        // last targeted window so a rapid sequence of tilings stays on the same window.
        let now = ProcessInfo.processInfo.systemUptime
        let ownPID = NSRunningApplication.current.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let targetApp: NSRunningApplication
        if let front = frontmost, front.processIdentifier != ownPID {
            // A real, non-self app is in front — target it and refresh the sticky.
            targetApp = front
        } else if (now - stickyTime) < stickyDuration,
                  stickyPID != 0,
                  let lastApp = NSRunningApplication(processIdentifier: stickyPID),
                  !lastApp.isTerminated {
            // Frontmost is missing or is our own app — fall back to the sticky target.
            targetApp = lastApp
            targetApp.activate()
        } else if let front = frontmost {
            targetApp = front
        } else {
            return
        }

        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return }

        let axWindow = window as! AXUIElement

        // For center: read current window frame to preserve size
        if action == .center {
            var currentPos = CGPoint.zero
            var currentSize = CGSize.zero

            var posRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
               let posVal = posRef {
                AXValueGetValue(posVal as! AXValue, .cgPoint, &currentPos)
            }
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sizeVal = sizeRef {
                AXValueGetValue(sizeVal as! AXValue, .cgSize, &currentSize)
            }

            // Center horizontally, keep vertical position and size
            let axX = visible.origin.x + (visible.width - currentSize.width) / 2
            var position = CGPoint(x: axX, y: currentPos.y)
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
            }
        } else {
            let target = targetFrame(for: action, in: visible)

            // Convert from NSScreen coords (origin bottom-left) to Accessibility coords (origin top-left)
            let axX = target.origin.x
            let axY = screenH - target.origin.y - target.height

            // Set position first, then size (order matters for screen edge clamping)
            var position = CGPoint(x: axX, y: axY)
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
            }

            var size = CGSize(width: target.size.width, height: target.size.height)
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
            }
        }

        // Raise the window so it stays focused even if the cursor is over a different window
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        targetApp.activate()

        // Remember target for sticky re-use
        stickyPID = targetApp.processIdentifier
        stickyTime = ProcessInfo.processInfo.systemUptime

        // Delayed re-activation — macOS may re-focus based on cursor after our call
        let pid = targetApp.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            }
        }
    }

    private static func targetFrame(for action: WindowAction, in visible: CGRect) -> CGRect {
        let x = visible.origin.x
        let y = visible.origin.y
        let w = visible.width
        let h = visible.height
        let halfW = w / 2
        let halfH = h / 2

        switch action {
        case .leftHalf:
            return CGRect(x: x, y: y, width: halfW, height: h)
        case .rightHalf:
            return CGRect(x: x + halfW, y: y, width: halfW, height: h)
        case .topHalf:
            return CGRect(x: x, y: y + halfH, width: w, height: halfH)
        case .bottomHalf:
            return CGRect(x: x, y: y, width: w, height: halfH)
        case .topLeftQuarter:
            return CGRect(x: x, y: y + halfH, width: halfW, height: halfH)
        case .topRightQuarter:
            return CGRect(x: x + halfW, y: y + halfH, width: halfW, height: halfH)
        case .bottomLeftQuarter:
            return CGRect(x: x, y: y, width: halfW, height: halfH)
        case .bottomRightQuarter:
            return CGRect(x: x + halfW, y: y, width: halfW, height: halfH)
        case .maximize:
            return CGRect(x: x, y: y, width: w, height: h)
        case .center, .moveToLeftDesktop, .moveToRightDesktop:
            return .zero  // handled separately
        }
    }

    private static func horizontalTargetFrame(side: HorizontalSide, layout: HorizontalLayout, visible: CGRect) -> CGRect {
        let x = visible.origin.x
        let y = visible.origin.y
        let w = visible.width
        let h = visible.height

        switch (side, layout) {
        case (.left, .half):
            return CGRect(x: x, y: y, width: w * 0.5, height: h)
        case (.left, .quarter):
            return CGRect(x: x, y: y, width: w * 0.25, height: h)
        case (.left, .threeQuarters):
            return CGRect(x: x, y: y, width: w * 0.75, height: h)
        case (.right, .half):
            return CGRect(x: x + w * 0.5, y: y, width: w * 0.5, height: h)
        case (.right, .quarter):
            return CGRect(x: x + w * 0.75, y: y, width: w * 0.25, height: h)
        case (.right, .threeQuarters):
            return CGRect(x: x + w * 0.25, y: y, width: w * 0.75, height: h)
        }
    }

    private static func setWindowFrame(_ axWindow: AXUIElement, target: CGRect, screenHeight: CGFloat) {
        let axX = target.origin.x
        let axY = screenHeight - target.origin.y - target.height

        var position = CGPoint(x: axX, y: axY)
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        }

        var size = CGSize(width: target.size.width, height: target.size.height)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    // MARK: - Desktop Switching

    private enum Direction { case left, right }

    private static func windowFrame(of window: AXUIElement) -> (position: CGPoint, size: CGSize)? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef,
              let sizeRef else {
            return nil
        }
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        AXValueGetValue(posValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return (position, size)
    }

    private static func titleBarGrabPoint(app: NSRunningApplication, position: CGPoint, size: CGSize) -> CGPoint {
        // Universal grab point: the top 2-4px strip of the window is draggable
        // in EVERY native macOS window — both traditional title bars (Safari)
        // and unified NSToolbar windows (Notes, Finder, Mail, System Settings).
        // Toolbar buttons begin a few pixels below the top edge, so y+3 lands
        // above them. Horizontal center avoids traffic lights (left ~70px) and
        // any right-side window controls (close-tab buttons, etc).
        //
        // Slight horizontal offset from exact center in case the window title
        // is centered and intercepts clicks (rare but defensive).
        let x = position.x + size.width * 0.5 - 30
        let y = position.y + 3
        return CGPoint(x: x, y: y)
    }

    private static func dragPoints(for grab: CGPoint, frame: CGRect) -> [CGPoint] {
        // Minimal drag — just 2px to trigger drag mode.
        let endX = grab.x + 2
        return [CGPoint(x: endX, y: grab.y)]
    }

    private static func postLeftMouseEvent(type: CGEventType, at point: CGPoint, source: CGEventSource) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private static func switchDesktop(direction: Direction) {
        let script = direction == .left ? moveLeftDesktopScript : moveRightDesktopScript
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            wmLog.error("Desktop switch AppleScript failed: \(String(describing: error))")
        }
    }

    static func switchToDesktop(number: Int) {
        let targetIndex = max(0, number - 1)
        let currentIndex = activeDesktopIndex() ?? currentSpaceIdx
        let delta = targetIndex - currentIndex
        guard delta != 0 else {
            mtdLog("[MTD] switchToDesktop no-op target=\(number) currentIdx=\(currentIndex)")
            return
        }

        let direction: Direction = delta > 0 ? .right : .left
        let stepDelta = delta > 0 ? 1 : -1
        let steps = abs(delta)
        mtdLog("[MTD] switchToDesktop target=\(number) currentIdx=\(currentIndex) steps=\(steps) dir=\(direction == .right ? "right" : "left")")

        for step in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.22) {
                internalSwitchInFlight = true
                pendingInternalSpaceDelta += stepDelta
                switchDesktop(direction: direction)
            }
        }
    }

    /// Moves the focused window to the adjacent desktop.
    ///
    /// Approach: synthesize a mouse drag of the title bar, then trigger a
    /// Ctrl+Arrow space switch while the drag is held — macOS's window server
    /// keeps the window glued to the cursor across the space transition. This
    /// is the only approach that works on macOS Tahoe without disabling SIP;
    /// the private CGS/SLS Spaces APIs silently no-op for foreign-process
    /// windows.
    private static func moveToDesktop(direction: Direction) {
        mtdLog("moveToDesktop ENTRY dir=\(direction == .left ? "left" : "right")")
        DispatchQueue.global(qos: .userInteractive).async {
            mtdLog("[MTD] START async dir=\(direction == .left ? "left" : "right")")

            // 1. Get focused window AXUIElement and its frame
            guard let app = NSWorkspace.shared.frontmostApplication else {
                mtdLog("[MTD] BAIL: no frontmost app"); return
            }
            mtdLog("[MTD] app=\(app.bundleIdentifier ?? "?")")
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowRef: CFTypeRef?
            let axErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
            guard axErr == .success, let windowRef else {
                mtdLog("[MTD] BAIL: AX focused window failed axErr=\(axErr.rawValue)"); return
            }
            let axWindow = windowRef as! AXUIElement

            guard let frame = windowFrame(of: axWindow) else {
                mtdLog("[MTD] BAIL: cannot read window frame"); return
            }
            mtdLog("[MTD] frame pos=\(frame.position) size=\(frame.size)")

            // 2. Compute a reliable title-bar grab point (avoids traffic lights,
            //    title text, Safari address bar)
            let grab = titleBarGrabPoint(app: app, position: frame.position, size: frame.size)
            mtdLog("[MTD] grab=\(grab)")

            // 3. Save current cursor location so we can restore it
            let savedCursor = NSEvent.mouseLocation  // bottom-left origin
            // Convert AppKit (bottom-left) to CG (top-left) for restore later
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let savedCG = CGPoint(x: savedCursor.x, y: screenH - savedCursor.y)

            guard let source = CGEventSource(stateID: .combinedSessionState) else {
                mtdLog("[MTD] BAIL: no CGEventSource"); return
            }

            // 4. Move cursor to grab point and press
            CGWarpMouseCursorPosition(grab)
            CGAssociateMouseAndMouseCursorPosition(0)
            postLeftMouseEvent(type: .leftMouseDown, at: grab, source: source)
            mtdLog("[MTD] mouseDown at \(grab)")
            usleep(40_000)

            // 5. Tiny drag to engage drag mode
            let dragStart = CGPoint(x: grab.x + 3, y: grab.y)
            postLeftMouseEvent(type: .leftMouseDragged, at: dragStart, source: source)
            usleep(20_000)

            // 6. Trigger desktop switch while still holding
            internalSwitchInFlight = true
            pendingInternalSpaceDelta = (direction == .left) ? -1 : 1
            switchDesktop(direction: direction)
            mtdLog("[MTD] switchDesktop called (drag held)")

            // 7. Keep dragging slightly during the transition (700ms is the
            //    typical Mission Control space-switch duration).
            //    We oscillate around the grab point so the window doesn't drift.
            let steps = 14
            for i in 1...steps {
                // Tiny back-and-forth motion to keep the drag "alive" without
                // accumulating any horizontal offset.
                let dx: CGFloat = (i % 2 == 0) ? 0 : 1
                let p = CGPoint(x: grab.x + dx, y: grab.y)
                postLeftMouseEvent(type: .leftMouseDragged, at: p, source: source)
                usleep(50_000)  // 14 * 50ms = 700ms
            }

            // 8. Release exactly at the grab point so the window snaps back to
            //    its original position on the new desktop.
            postLeftMouseEvent(type: .leftMouseDragged, at: grab, source: source)
            usleep(10_000)
            postLeftMouseEvent(type: .leftMouseUp, at: grab, source: source)
            mtdLog("[MTD] mouseUp at \(grab)")

            // 9. Re-enable mouse association and restore cursor
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(savedCG)

            // 10. Restore original window position via AX, and re-focus.
            //     AX writes must run on the main thread — AppKit asserts when
            //     the target window belongs to our own process.
            let pid = app.processIdentifier
            let originalPos = frame.position
            DispatchQueue.main.async {
                var origin = originalPos
                if let posValue = AXValueCreate(.cgPoint, &origin) {
                    AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
                    mtdLog("[MTD] restored position to \(origin)")
                }
                NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                mtdLog("[MTD] DONE")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    internalSwitchInFlight = false
                }
            }
        }
    }

    private static func directionLabel(for direction: Direction) -> String {
        switch direction {
        case .left:
            return "left"
        case .right:
            return "right"
        }
    }
}
