import Foundation
import ReSwift

private var timer: Timer?
private var edgeCrossingTimer: Timer?
private var warpEventSource: CGEventSource?
private let edgeMargin: CGFloat = 2

// One-shot flags so an exit-warp landing near the window's edge doesn't
// immediately re-trigger an entry-warp back onto the virtual display, and vice
// versa, when both behaviors are enabled at the same time.
private var skipExitCheckOnce = false
private var skipEntryCheckOnce = false

// Entering the virtual display lands the cursor right at its edge (the window's edge
// maps to the display's edge), which is inside the exit margin. Skipping one tick
// isn't enough — the cursor is still there on the next one — so exit would fire
// immediately and the cursor would bounce in and out, appearing to stick. After an
// entry, exit stays disarmed until the cursor has moved `exitRearmDistance` clear of
// every edge (or left the display).
private var exitArmed = true
private let exitRearmDistance: CGFloat = 12

// Tracks whether the cursor was over the preview window on the previous tick, so
// entry fires on a genuine outside→inside transition rather than requiring the
// cursor to currently sit within a thin edge band — nothing clamps cursor motion
// at a window's edge the way a display's own bounds do, so a fast mouse movement
// can jump straight from clearly outside to clearly inside between two ticks,
// skipping over any such band entirely.
private var wasInsideWindowLastTick = false

// Last cursor position observed while on the virtual display, or nil if the cursor
// wasn't on it on the previous tick. If the virtual display is arranged directly
// next to a real display, a fast mouse movement can carry the cursor across the
// shared edge and far onto the real display within a single polling tick, so the
// exit point can't be derived from the cursor's *current* position (which could be
// anywhere on the real display). Instead, exit is detected as an on→off transition
// and the crossing point is computed from the segment between the last on-display
// position and the current one.
private var lastVirtualLocation: NSPoint?

enum MouseLocationAction: Action {
    case located(isWithinScreen: Bool)
    case requestMove(toPoint: NSPoint)
}

func mouseLocationSideEffect() -> SideEffect {
    return { action, dispatch, getState in
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                let mouseLocation = NSEvent.mouseLocation
                let screens = NSScreen.screens
                let screenContainingMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })
                let isWithinScreen = screenContainingMouse?.displayID == getState()?.screenConfigurationState.displayID
                dispatch(MouseLocationAction.located(isWithinScreen: isWithinScreen))
            }
        }
        switch action {
        case let MouseLocationAction.requestMove(point):
            guard let displayID = getState()?.screenConfigurationState.displayID else {
                return
            }
            CGDisplayMoveCursorToPoint(displayID, point)
        default:
            return
        }
    }
}

// Watches the cursor near the virtual display's and preview window's edges and,
// when enabled (MouseEdgeBehaviorState), warps it across the boundary: out of the
// virtual display onto the mirrored point in the preview window, and/or into the
// virtual display when it reaches the preview window's edge (skipping the need to
// click).
func mouseEdgeCrossingSideEffect() -> SideEffect {
    return { _, dispatch, getState in
        guard edgeCrossingTimer == nil else { return }

        // By default macOS suppresses hardware mouse events for 0.25s after any cursor
        // warp, freezing the cursor for a moment. Every jump here is a warp, so turn
        // that suppression off.
        warpEventSource = CGEventSource(stateID: .combinedSessionState)
        warpEventSource?.localEventsSuppressionInterval = 0

        edgeCrossingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard let state = getState() else { return }

            let behavior = state.mouseEdgeBehaviorState
            guard behavior.jumpOutEnabled || behavior.jumpInEnabled else { return }

            guard
                let displayID = state.screenConfigurationState.displayID,
                let virtualScreen = NSScreen.screens.first(where: { $0.displayID == displayID })
            else { return }

            let virtualFrame = virtualScreen.frame
            guard virtualFrame.width > 0, virtualFrame.height > 0 else { return }

            let contentFrame = state.previewWindowState.contentFrame
            guard contentFrame.width > 0, contentFrame.height > 0 else { return }

            let resolution = state.screenConfigurationState.resolution
            guard resolution.width > 0, resolution.height > 0 else { return }

            let mouseLocation = NSEvent.mouseLocation

            // Inside the window's frame *and* the window is actually what's visible
            // there, so a window covering the preview doesn't get its cursor yanked away.
            // Visibility is only checked on a potential entry (not every tick while already
            // inside): querying the window list at 60Hz is slow enough to make the cursor stutter.
            let wasInsideWindow = wasInsideWindowLastTick
            let isInsideWindow = contentFrame.contains(mouseLocation)
                && (wasInsideWindow || isPreviewWindowVisible(at: mouseLocation))
            wasInsideWindowLastTick = isInsideWindow

            // CGRect.contains is half-open (excludes maxX/maxY), but a cursor clamped at
            // the top or right edge of a display reports exactly maxY/maxX — so use a
            // closed-interval check or the cursor would count as already off the display.
            let isOnVirtual = (virtualFrame.minX ... virtualFrame.maxX).contains(mouseLocation.x)
                && (virtualFrame.minY ... virtualFrame.maxY).contains(mouseLocation.y)
            let previousVirtualLocation = lastVirtualLocation
            lastVirtualLocation = isOnVirtual ? mouseLocation : nil

            // Re-arm exit once the cursor has moved clear of the display's edges (or left
            // the display entirely), see exitArmed.
            if isOnVirtual == false || distanceToNearestEdge(mouseLocation, in: virtualFrame) > exitRearmDistance {
                exitArmed = true
            }

            if skipExitCheckOnce {
                skipExitCheckOnce = false
            } else if behavior.jumpOutEnabled {
                var target: CGPoint?
                if isOnVirtual {
                    // Still on the display: the OS clamps motion at an unneighbored edge,
                    // so the cursor lingers within the margin across several ticks.
                    target = exitArmed ? exitTarget(mouseLocation: mouseLocation, virtualFrame: virtualFrame, contentFrame: contentFrame) : nil
                } else if let previous = previousVirtualLocation {
                    target = crossingExitTarget(from: previous, to: mouseLocation, virtualFrame: virtualFrame, contentFrame: contentFrame)
                }
                if let target {
                    warpCursor(to: target)
                    // The warp itself moves the cursor off the display; forget the last
                    // on-display position so the next tick doesn't mistake the warp for
                    // a fresh exit and warp a second time (to the wrong edge).
                    lastVirtualLocation = nil
                    skipEntryCheckOnce = true
                    return
                }
            }

            if skipEntryCheckOnce {
                skipEntryCheckOnce = false
            } else if behavior.jumpInEnabled, isInsideWindow, wasInsideWindow == false {
                let target = entryTarget(mouseLocation: mouseLocation, contentFrame: contentFrame, resolution: resolution)
                skipExitCheckOnce = true
                exitArmed = false
                dispatch(MouseLocationAction.requestMove(toPoint: target))
            }
        }
    }
}

private func distanceToNearestEdge(_ point: NSPoint, in frame: CGRect) -> CGFloat {
    min(point.x - frame.minX, frame.maxX - point.x, point.y - frame.minY, frame.maxY - point.y)
}

// Point (in the preview window's global screen coordinate space) mirroring where the
// cursor sits along the virtual display's edge, or nil if it isn't currently near one.
private func exitTarget(mouseLocation: NSPoint, virtualFrame: CGRect, contentFrame: CGRect) -> CGPoint? {
    let fractionX = (mouseLocation.x - virtualFrame.minX) / virtualFrame.width
    let fractionY = (mouseLocation.y - virtualFrame.minY) / virtualFrame.height

    // Nearest edge wins, so a cursor in a corner exits through the edge it's actually
    // being pushed against rather than whichever edge is checked first.
    let distances = [
        mouseLocation.x - virtualFrame.minX,
        virtualFrame.maxX - mouseLocation.x,
        mouseLocation.y - virtualFrame.minY,
        virtualFrame.maxY - mouseLocation.y,
    ]
    guard let nearest = distances.enumerated().min(by: { $0.element < $1.element }), nearest.element <= edgeMargin else {
        return nil
    }

    switch nearest.offset {
    case 0: return CGPoint(x: contentFrame.minX + edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
    case 1: return CGPoint(x: contentFrame.maxX - edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
    case 2: return CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.minY + edgeMargin)
    default: return CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.maxY - edgeMargin)
    }
}

// Like exitTarget, but for a cursor that has already left the virtual display: finds
// where the segment from its last on-display position to its current (off-display)
// position crossed the display's boundary, and mirrors that crossing point.
private func crossingExitTarget(from last: NSPoint, to current: NSPoint, virtualFrame: CGRect, contentFrame: CGRect) -> CGPoint? {
    let dx = current.x - last.x
    let dy = current.y - last.y

    // Parametric position (0...1) along the segment at which each violated edge is
    // crossed; the smallest one is the edge actually left through.
    var best: (t: CGFloat, edge: Int)?
    func consider(_ t: CGFloat, _ edge: Int) {
        if best == nil || t < best!.t { best = (t, edge) }
    }
    if current.x < virtualFrame.minX, dx != 0 { consider((virtualFrame.minX - last.x) / dx, 0) }
    if current.x > virtualFrame.maxX, dx != 0 { consider((virtualFrame.maxX - last.x) / dx, 1) }
    if current.y < virtualFrame.minY, dy != 0 { consider((virtualFrame.minY - last.y) / dy, 2) }
    if current.y > virtualFrame.maxY, dy != 0 { consider((virtualFrame.maxY - last.y) / dy, 3) }
    guard let (t, edge) = best else { return nil }

    let crossX = last.x + t * dx
    let crossY = last.y + t * dy
    let fractionX = min(max((crossX - virtualFrame.minX) / virtualFrame.width, 0), 1)
    let fractionY = min(max((crossY - virtualFrame.minY) / virtualFrame.height, 0), 1)

    switch edge {
    case 0: return CGPoint(x: contentFrame.minX + edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
    case 1: return CGPoint(x: contentFrame.maxX - edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
    case 2: return CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.minY + edgeMargin)
    default: return CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.maxY - edgeMargin)
    }
}

// Point (in the virtual display's own top-left-origin coordinate space, as
// CGDisplayMoveCursorToPoint expects — same as the click-to-enter gesture uses)
// mirroring where the cursor currently sits within the preview window.
private func entryTarget(mouseLocation: NSPoint, contentFrame: CGRect, resolution: CGSize) -> CGPoint {
    let fractionX = (mouseLocation.x - contentFrame.minX) / contentFrame.width
    let fractionYFromTop = 1 - (mouseLocation.y - contentFrame.minY) / contentFrame.height
    let clampedFractionX = min(max(fractionX, 0), 1)
    let clampedFractionYFromTop = min(max(fractionYFromTop, 0), 1)
    return CGPoint(x: clampedFractionX * resolution.width, y: clampedFractionYFromTop * resolution.height)
}

// True if the topmost on-screen window under the point belongs to this app. Only
// ordinary content is considered: the desktop (negative layers), fully transparent
// windows and the window server's own cursor/overlay surfaces are skipped, since they
// would otherwise always "cover" the preview.
private func isPreviewWindowVisible(at appKitPoint: NSPoint) -> Bool {
    guard let mainScreenHeight = NSScreen.screens.first?.frame.height,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return true }

    let quartzPoint = CGPoint(x: appKitPoint.x, y: mainScreenHeight - appKitPoint.y)
    let ownPID = ProcessInfo.processInfo.processIdentifier

    // The list is ordered front to back.
    for window in windows {
        guard
            let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
            (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
            window[kCGWindowOwnerName as String] as? String != "Window Server",
            let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            bounds.contains(quartzPoint)
        else { continue }
        return (window[kCGWindowOwnerPID as String] as? Int32) == ownPID
    }
    return true
}

private func warpCursor(to target: CGPoint) {
    guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }
    // NSEvent/NSScreen use a bottom-left-origin coordinate space; CGWarpMouseCursorPosition
    // expects the top-left-origin Quartz global space, so flip Y before warping.
    let quartzTarget = CGPoint(x: target.x, y: mainScreenHeight - target.y)

    CGAssociateMouseAndMouseCursorPosition(0)
    CGWarpMouseCursorPosition(quartzTarget)
    CGAssociateMouseAndMouseCursorPosition(1)
}
