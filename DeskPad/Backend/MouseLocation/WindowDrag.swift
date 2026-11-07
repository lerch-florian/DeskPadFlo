import Carbon.HIToolbox
import Cocoa

// MARK: - Window list

struct WindowSnapshot {
    let number: Int
    let bounds: CGRect
    let ownerPID: Int32
}

private var windowSnapshotCache: (takenAt: Date, windows: [WindowSnapshot])?

// On-screen windows front to back. Only ordinary content is kept: the desktop (negative
// layers), fully transparent windows and the window server's own cursor/overlay
// surfaces are skipped, since they would otherwise always "cover" the preview. A
// snapshot younger than `maxAge` is reused; pass 0 to always query afresh.
func frontToBackWindows(maxAge: TimeInterval) -> [WindowSnapshot]? {
    if let cache = windowSnapshotCache, Date().timeIntervalSince(cache.takenAt) < maxAge {
        return cache.windows
    }
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    let windows: [WindowSnapshot] = infos.compactMap { window in
        guard
            let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
            (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
            window[kCGWindowOwnerName as String] as? String != "Window Server",
            let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return WindowSnapshot(
            number: window[kCGWindowNumber as String] as? Int ?? -1,
            bounds: bounds,
            ownerPID: window[kCGWindowOwnerPID as String] as? Int32 ?? -1
        )
    }
    windowSnapshotCache = (Date(), windows)
    return windows
}

// True if the topmost on-screen window under the point belongs to this app. A window
// that is being dragged right now is ignored: it is carried along under the cursor and
// would otherwise always cover the preview, making it impossible to drag a window into it.
func isPreviewWindowVisible(at appKitPoint: NSPoint, maxAge: TimeInterval = 0) -> Bool {
    guard let mainScreenHeight = NSScreen.screens.first?.frame.height,
          let windows = frontToBackWindows(maxAge: maxAge)
    else { return true }

    let quartzPoint = CGPoint(x: appKitPoint.x, y: mainScreenHeight - appKitPoint.y)
    let dragged = windowDrag.draggedWindowNumber(in: windows)
    guard let topmost = windows.first(where: { $0.number != dragged && $0.bounds.contains(quartzPoint) }) else {
        return true
    }
    return topmost.ownerPID == ProcessInfo.processInfo.processIdentifier
}

// MARK: - Drag tracking

let windowDrag = WindowDragTracker()

// Follows the left mouse button to tell when another app's window is being dragged. That
// matters for two things: the dragged window must not count as covering the preview, and
// in "Click to Enter" mode a dragged window can be sent into the virtual screen with a
// shake or a shortcut.
final class WindowDragTracker {
    private var wasLeftButtonDown = false
    // The window under the cursor when the button went down (not ours), and where it was.
    private var grabbed: (number: Int, origin: CGPoint)?
    // The button went down on the preview window itself (dragging it by its title bar or
    // background). It then moves under the cursor, so none of the jump logic may act on
    // the cursor until the button is released.
    private var grabbedOwnWindow = false
    private var shake = ShakeDetector()

    var isButtonHeldOnForeignWindow: Bool { leftButtonDown && grabbed != nil }
    var isHoldingOwnWindow: Bool { leftButtonDown && grabbedOwnWindow }

    private var leftButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    // Call every tick. Returns true when the shake gesture has just been completed.
    func tick(mouseLocation: NSPoint, trackShake: Bool) -> Bool {
        let isDown = leftButtonDown
        defer { wasLeftButtonDown = isDown }

        if isDown, wasLeftButtonDown == false {
            let topmost = topmostWindow(at: mouseLocation)
            grabbedOwnWindow = topmost?.ownerPID == ProcessInfo.processInfo.processIdentifier
            grabbed = topmost.flatMap { grabbedOwnWindow ? nil : ($0.number, $0.bounds.origin) }
            shake.reset()
        } else if isDown == false {
            grabbed = nil
            grabbedOwnWindow = false
            shake.reset()
        }

        guard trackShake, isDown, grabbed != nil else {
            shake.reset()
            return false
        }
        return shake.add(mouseLocation, at: ProcessInfo.processInfo.systemUptime)
    }

    // Number of the grabbed window if it has actually moved since the button went down
    // (i.e. it is being dragged rather than just pressed on), judged from `windows`.
    func draggedWindowNumber(in windows: [WindowSnapshot]) -> Int? {
        guard leftButtonDown, let grabbed,
              let current = windows.first(where: { $0.number == grabbed.number }),
              current.bounds.origin != grabbed.origin
        else { return nil }
        return grabbed.number
    }

    // Fresh check: the number of the window being dragged right now, if any.
    func currentDraggedWindowNumber() -> Int? {
        guard let windows = frontToBackWindows(maxAge: 0) else { return nil }
        return draggedWindowNumber(in: windows)
    }

    func isDraggingWindow() -> Bool {
        currentDraggedWindowNumber() != nil
    }

    private func topmostWindow(at appKitPoint: NSPoint) -> WindowSnapshot? {
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height,
              let windows = frontToBackWindows(maxAge: 0)
        else { return nil }
        let quartzPoint = CGPoint(x: appKitPoint.x, y: mainScreenHeight - appKitPoint.y)
        return windows.first(where: { $0.bounds.contains(quartzPoint) })
    }
}

// Detects a quick back-and-forth movement of the cursor: several direction reversals,
// each swing at least `minSwing` points, within `timeWindow` seconds.
struct ShakeDetector {
    private let timeWindow: TimeInterval = 0.8
    private let minSwing: CGFloat = 35
    private let requiredReversals = 3

    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    mutating func reset() {
        samples.removeAll()
    }

    mutating func add(_ point: CGPoint, at time: TimeInterval) -> Bool {
        samples.append((time, point))
        samples.removeAll { time - $0.time > timeWindow }
        guard reversals(along: \.x) >= requiredReversals || reversals(along: \.y) >= requiredReversals else {
            return false
        }
        samples.removeAll()
        return true
    }

    private func reversals(along axis: KeyPath<CGPoint, CGFloat>) -> Int {
        guard var extreme = samples.first?.point[keyPath: axis] else { return 0 }
        var direction = 0
        var count = 0
        for sample in samples.dropFirst() {
            let value = sample.point[keyPath: axis]
            switch direction {
            case 0:
                if abs(value - extreme) >= minSwing {
                    direction = value > extreme ? 1 : -1
                    extreme = value
                }
            case 1:
                if value > extreme {
                    extreme = value
                } else if extreme - value >= minSwing {
                    direction = -1
                    extreme = value
                    count += 1
                }
            default:
                if value < extreme {
                    extreme = value
                } else if value - extreme >= minSwing {
                    direction = 1
                    extreme = value
                    count += 1
                }
            }
        }
        return count
    }
}

// MARK: - Hotkeys

private var emergencyHotKeyRef: EventHotKeyRef?
private var dragEntryHotKeyRef: EventHotKeyRef?
private let hotKeySignature = OSType(0x4450_4144) // 'DPAD'

private enum HotKeyID: UInt32 {
    case emergency = 1
    case dragEntry = 2
}

// Registers the emergency reset (cmd+option+shift+H) system-wide, and installs the one
// handler that serves every DeskPad hotkey. Hotkeys work while DeskPad isn't frontmost
// and need no accessibility permission.
func registerEmergencyHotKey() {
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        switch HotKeyID(rawValue: hotKeyID.id) {
        case .emergency: jumpCursorToMainScreenCenter()
        case .dragEntry: enterVirtualDisplayWithDraggedWindow()
        case nil: break
        }
        return noErr
    }, 1, &eventType, nil, nil)
    RegisterEventHotKey(
        UInt32(kVK_ANSI_H), UInt32(cmdKey | optionKey | shiftKey),
        EventHotKeyID(signature: hotKeySignature, id: HotKeyID.emergency.rawValue),
        GetApplicationEventTarget(), 0, &emergencyHotKeyRef
    )
}

// cmd+shift+D is a common shortcut in other apps (e.g. bookmarking), so it is only
// claimed system-wide while it can actually do something: during a window drag in
// "Click to Enter" mode.
func setDragEntryHotKeyRegistered(_ registered: Bool) {
    if registered, dragEntryHotKeyRef == nil {
        RegisterEventHotKey(
            UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: hotKeySignature, id: HotKeyID.dragEntry.rawValue),
            GetApplicationEventTarget(), 0, &dragEntryHotKeyRef
        )
    } else if registered == false, let ref = dragEntryHotKeyRef {
        UnregisterEventHotKey(ref)
        dragEntryHotKeyRef = nil
    }
}
