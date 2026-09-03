// Standalone listen-only tap that prints every scroll-wheel event reaching apps
// (i.e. everything that got PAST Trackpad Control's blocking tap).
// Run:  swift scripts/scroll_listener.swift
// Needs Input Monitoring permission for the terminal running it.
import Foundation
import CoreGraphics

let fmt = DateFormatter()
fmt.dateFormat = "HH:mm:ss.SSS"

func phaseName(_ v: Int64) -> String {
    switch v {
    case 0: return "-"
    case 1: return "began"
    case 2: return "changed"
    case 4: return "ended"
    case 8: return "cancelled"
    case 128: return "mayBegin"
    default: return "p\(v)"
    }
}
func momentumName(_ v: Int64) -> String {
    switch v {
    case 0: return "-"
    case 1: return "mBegin"
    case 2: return "mContinue"
    case 3: return "mEnd"
    default: return "m\(v)"
    }
}

let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
    | (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.leftMouseUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        let ts = fmt.string(from: Date())
        switch type {
        case .scrollWheel:
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let mom = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            let cont = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            print("\(ts) SCROLL phase=\(phaseName(phase)) mom=\(momentumName(mom)) dy=\(dy) dx=\(dx) cont=\(cont)")
        case .leftMouseDown, .leftMouseUp:
            let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            print("\(ts) \(type == .leftMouseDown ? "LDOWN" : "LUP") srcPid=\(pid)")
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    print("FAILED to create tap — grant Input Monitoring to the terminal app and retry")
    exit(1)
}

let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("\(fmt.string(from: Date())) listening… (Ctrl+C to stop)")
setbuf(stdout, nil)
CFRunLoopRun()
