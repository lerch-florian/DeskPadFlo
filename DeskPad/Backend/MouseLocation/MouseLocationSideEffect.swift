import Foundation
import ReSwift

private var timer: Timer?
private var edgeExitTimer: Timer?
private let edgeMargin: CGFloat = 2

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

// Watches the cursor while it's on the virtual display and, once it reaches an
// edge, warps it back onto the physical screen at the matching spot inside the
// preview window's content area, so the cursor appears to "leave" the virtual
// screen through that edge.
func mouseEdgeExitSideEffect() -> SideEffect {
    return { _, _, getState in
        guard edgeExitTimer == nil else { return }

        edgeExitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard
                let state = getState(),
                let displayID = state.screenConfigurationState.displayID,
                let virtualScreen = NSScreen.screens.first(where: { $0.displayID == displayID })
            else { return }

            let virtualFrame = virtualScreen.frame
            guard virtualFrame.width > 0, virtualFrame.height > 0 else { return }

            let contentFrame = state.previewWindowState.contentFrame
            guard contentFrame.width > 0, contentFrame.height > 0 else { return }

            let mouseLocation = NSEvent.mouseLocation
            guard virtualFrame.contains(mouseLocation) else { return }

            let fractionX = (mouseLocation.x - virtualFrame.minX) / virtualFrame.width
            let fractionY = (mouseLocation.y - virtualFrame.minY) / virtualFrame.height

            let exitedLeft = mouseLocation.x - virtualFrame.minX <= edgeMargin
            let exitedRight = virtualFrame.maxX - mouseLocation.x <= edgeMargin
            let exitedBottom = mouseLocation.y - virtualFrame.minY <= edgeMargin
            let exitedTop = virtualFrame.maxY - mouseLocation.y <= edgeMargin

            let target: CGPoint
            if exitedLeft {
                target = CGPoint(x: contentFrame.minX + edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
            } else if exitedRight {
                target = CGPoint(x: contentFrame.maxX - edgeMargin, y: contentFrame.minY + fractionY * contentFrame.height)
            } else if exitedBottom {
                target = CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.minY + edgeMargin)
            } else if exitedTop {
                target = CGPoint(x: contentFrame.minX + fractionX * contentFrame.width, y: contentFrame.maxY - edgeMargin)
            } else {
                return
            }

            guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }
            // NSEvent/NSScreen use a bottom-left-origin coordinate space; CGWarpMouseCursorPosition
            // expects the top-left-origin Quartz global space, so flip Y before warping.
            let quartzTarget = CGPoint(x: target.x, y: mainScreenHeight - target.y)

            CGAssociateMouseAndMouseCursorPosition(0)
            CGWarpMouseCursorPosition(quartzTarget)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
