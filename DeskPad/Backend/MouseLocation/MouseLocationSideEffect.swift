import Foundation
import ReSwift

private var timer: Timer?
private var edgeCrossingTimer: Timer?
private let edgeMargin: CGFloat = 2

// One-shot flags so an exit-warp landing near the window's edge doesn't
// immediately re-trigger an entry-warp back onto the virtual display, and vice
// versa, when both behaviors are enabled at the same time.
private var skipExitCheckOnce = false
private var skipEntryCheckOnce = false

// Tracks whether the cursor was over the preview window on the previous tick, so
// entry fires on a genuine outside→inside transition rather than requiring the
// cursor to currently sit within a thin edge band — nothing clamps cursor motion
// at a window's edge the way a display's own bounds do, so a fast mouse movement
// can jump straight from clearly outside to clearly inside between two ticks,
// skipping over any such band entirely.
private var wasInsideWindowLastTick = false

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

            let isInsideWindow = contentFrame.contains(mouseLocation)
            let wasInsideWindow = wasInsideWindowLastTick
            wasInsideWindowLastTick = isInsideWindow

            if skipExitCheckOnce {
                skipExitCheckOnce = false
            } else if
                behavior.jumpOutEnabled,
                virtualFrame.contains(mouseLocation),
                let target = exitTarget(mouseLocation: mouseLocation, virtualFrame: virtualFrame, contentFrame: contentFrame)
            {
                warpCursor(to: target)
                skipEntryCheckOnce = true
                return
            }

            if skipEntryCheckOnce {
                skipEntryCheckOnce = false
            } else if behavior.jumpInEnabled, isInsideWindow, wasInsideWindow == false {
                let target = entryTarget(mouseLocation: mouseLocation, contentFrame: contentFrame, resolution: resolution)
                skipExitCheckOnce = true
                dispatch(MouseLocationAction.requestMove(toPoint: target))
            }
        }
    }
}

// Point (in the preview window's global screen coordinate space) mirroring where the
// cursor sits along the virtual display's edge, or nil if it isn't currently near one.
private func exitTarget(mouseLocation: NSPoint, virtualFrame: CGRect, contentFrame: CGRect) -> CGPoint? {
    let fractionX = (mouseLocation.x - virtualFrame.minX) / virtualFrame.width
    let fractionY = (mouseLocation.y - virtualFrame.minY) / virtualFrame.height

    if mouseLocation.x - virtualFrame.minX <= edgeMargin {
        return CGPoint(x: contentFrame.minX + edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
    } else if virtualFrame.maxX - mouseLocation.x <= edgeMargin {
        return CGPoint(x: contentFrame.maxX - edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
    } else if mouseLocation.y - virtualFrame.minY <= edgeMargin {
        return CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.minY + edgeMargin)
    } else if virtualFrame.maxY - mouseLocation.y <= edgeMargin {
        return CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.maxY - edgeMargin)
    }
    return nil
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

private func warpCursor(to target: CGPoint) {
    guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }
    // NSEvent/NSScreen use a bottom-left-origin coordinate space; CGWarpMouseCursorPosition
    // expects the top-left-origin Quartz global space, so flip Y before warping.
    let quartzTarget = CGPoint(x: target.x, y: mainScreenHeight - target.y)

    CGAssociateMouseAndMouseCursorPosition(0)
    CGWarpMouseCursorPosition(quartzTarget)
    CGAssociateMouseAndMouseCursorPosition(1)
}
