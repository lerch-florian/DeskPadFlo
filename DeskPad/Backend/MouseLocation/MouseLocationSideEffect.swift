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

// Seamless mode checks every tick whether the cursor's mapped point on the screen
// window is covered; a window list this old is fresh enough for that, and querying it
// 60 times a second is not affordable.
private let coveredCheckWindowListMaxAge: TimeInterval = 0.1

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

// Used when "Allow Screen Edge Jump" is off: the cursor position on the previous tick
// (on any display), so a move between the virtual display and another display can be
// detected and undone.
private var lastMouseLocation: NSPoint?

// Set by every deliberate cursor warp (exit/entry jumps, click-to-enter, emergency
// hotkey) so the next tick doesn't mistake it for the OS carrying the cursor across a
// display edge and undo it.
private var deliberateWarpPending = false

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
            deliberateWarpPending = true
            // Any entry (auto jump or click) lands wherever the point maps to, possibly
            // right at an edge; keep exit disarmed until the cursor has moved clear of it.
            exitArmed = false
            CGDisplayMoveCursorToPoint(displayID, point)
            let displayOrigin = CGDisplayBounds(displayID).origin
            nudgeDrag(toQuartz: CGPoint(x: displayOrigin.x + point.x, y: displayOrigin.y + point.y))
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

            // Window dragging: in "Click to Enter" mode a window being dragged over the
            // preview can be sent into the virtual screen by shaking or by cmd+shift+D.
            let clickToEnter = behavior.cursorMode == .clickToEnter
            let shook = windowDrag.tick(mouseLocation: mouseLocation, trackShake: clickToEnter && contentFrame.contains(mouseLocation))
            setDragEntryHotKeyRegistered(clickToEnter && windowDrag.isButtonHeldOnForeignWindow, shortcut: state.shortcutsState.dragEntry)

            // Dragging the preview window itself: it moves with the cursor, so a jump would
            // drag it along into the virtual display (invisible) or let the stale window
            // frame trigger entries, and it ends up bouncing between the screen corners.
            // Keep the cursor, and with it the window, on the real displays instead.
            if windowDrag.isHoldingOwnWindow {
                holdPreviewDragOnRealDisplays(mouseLocation: mouseLocation, virtualFrame: virtualFrame)
                return
            }

            // Inside the window's frame *and* the window is actually what's visible
            // there, so a window covering the preview doesn't get its cursor yanked away.
            // Visibility is only checked on a potential entry (not every tick while already
            // inside): querying the window list at 60Hz is slow enough to make the cursor stutter.
            // Modes that need a click to enter never auto-enter, so they skip it entirely.
            let wasInsideWindow = wasInsideWindowLastTick
            let isInsideWindow = behavior.jumpInEnabled
                && contentFrame.contains(mouseLocation)
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
            } else {
                var target: CGPoint?
                if isOnVirtual {
                    // Still on the display: the OS clamps motion at an unneighbored edge,
                    // so the cursor lingers within the margin across several ticks.
                    target = exitArmed ? exitTarget(mouseLocation: mouseLocation, virtualFrame: virtualFrame, contentFrame: contentFrame) : nil
                    if target == nil, behavior.cursorMode.exitsWhereCovered {
                        target = coveredExitTarget(mouseLocation: mouseLocation, virtualFrame: virtualFrame, contentFrame: contentFrame)
                    }
                } else if let previous = previousVirtualLocation {
                    target = crossingExitTarget(from: previous, to: mouseLocation, virtualFrame: virtualFrame, contentFrame: contentFrame)
                }
                if let target {
                    // A window being dragged out of the virtual screen has to end up above
                    // the preview (which entering/clicking raised), or it would land behind
                    // it with its title bar under the preview — and the next grab of it would
                    // drag the preview instead.
                    let draggedWindow = windowDrag.currentDraggedWindowNumber()
                    warpCursor(to: target)
                    if let draggedWindow {
                        (NSApp.delegate as? AppDelegate)?.window.order(.below, relativeTo: draggedWindow)
                    }
                    // The warp itself moves the cursor off the display; forget the last
                    // on-display position so the next tick doesn't mistake the warp for
                    // a fresh exit and warp a second time (to the wrong edge).
                    lastVirtualLocation = nil
                    skipEntryCheckOnce = true
                    return
                }
            }

            // Edge jump disabled: undo any move of the cursor between the virtual display
            // and another display. A warp we performed ourselves is exempt (and consumed).
            let previousLocation = lastMouseLocation
            lastMouseLocation = mouseLocation
            let wasOnVirtual = previousVirtualLocation != nil
            if deliberateWarpPending {
                deliberateWarpPending = false
            } else if
                behavior.blockOSScreenConnection,
                let previousLocation,
                isOnVirtual != wasOnVirtual
            {
                if wasOnVirtual {
                    // Left the virtual display: hold the cursor just inside its edge.
                    let target = edgeHoldTarget(from: previousLocation, to: mouseLocation, in: virtualFrame)
                    warpCursor(to: target, deliberate: false)
                    lastMouseLocation = target
                    lastVirtualLocation = target
                } else {
                    // Entered the virtual display from another one: put it back.
                    warpCursor(to: previousLocation, deliberate: false)
                    lastMouseLocation = previousLocation
                    lastVirtualLocation = nil
                }
                return
            }

            if skipEntryCheckOnce {
                skipEntryCheckOnce = false
            } else if
                behavior.jumpInEnabled,
                isInsideWindow,
                wasInsideWindow == false
            {
                enterVirtualDisplay(at: mouseLocation, state: state, dispatch: dispatch)
            }

            if shook, windowDrag.isDraggingWindow(), isPreviewWindowVisible(at: mouseLocation) {
                enterVirtualDisplay(at: mouseLocation, state: state, dispatch: dispatch)
            }
        }
    }
}

// While the preview window is being dragged: if the cursor crossed onto the virtual
// display (macOS connects it to the real display next to it), put it back where it was.
private func holdPreviewDragOnRealDisplays(mouseLocation: NSPoint, virtualFrame: CGRect) {
    wasInsideWindowLastTick = false
    lastVirtualLocation = nil
    let isOnVirtual = (virtualFrame.minX ... virtualFrame.maxX).contains(mouseLocation.x)
        && (virtualFrame.minY ... virtualFrame.maxY).contains(mouseLocation.y)
    if isOnVirtual, let held = lastMouseLocation {
        warpCursor(to: held, deliberate: false)
    } else {
        lastMouseLocation = mouseLocation
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

// Seamless mode: the cursor on the virtual display is drawn inside the screen window at
// the point its position maps to. Where that point is covered by another window, the
// virtual screen isn't visible there, so the cursor leaves — it's warped to that very
// point, i.e. onto the covering window, without visibly moving. Nil while the mapped
// point is still visible.
private func coveredExitTarget(mouseLocation: NSPoint, virtualFrame: CGRect, contentFrame: CGRect) -> CGPoint? {
    let fractionX = min(max((mouseLocation.x - virtualFrame.minX) / virtualFrame.width, 0), 1)
    let fractionY = min(max((mouseLocation.y - virtualFrame.minY) / virtualFrame.height, 0), 1)
    let mapped = CGPoint(
        x: contentFrame.minX + fractionX * contentFrame.width,
        y: contentFrame.minY + fractionY * contentFrame.height
    )
    return isPreviewWindowVisible(at: mapped, maxAge: coveredCheckWindowListMaxAge) ? nil : mapped
}

// Where to hold the cursor after it left the virtual display: the point where the
// segment from its last on-display position to its current position crossed the
// display's boundary, pulled one point inside so it still counts as on the display.
private func edgeHoldTarget(from last: NSPoint, to current: NSPoint, in frame: CGRect) -> CGPoint {
    let dx = current.x - last.x
    let dy = current.y - last.y
    var t: CGFloat = 1
    if current.x < frame.minX, dx != 0 { t = min(t, (frame.minX - last.x) / dx) }
    if current.x > frame.maxX, dx != 0 { t = min(t, (frame.maxX - last.x) / dx) }
    if current.y < frame.minY, dy != 0 { t = min(t, (frame.minY - last.y) / dy) }
    if current.y > frame.maxY, dy != 0 { t = min(t, (frame.maxY - last.y) / dy) }
    let inset: CGFloat = 1
    return CGPoint(
        x: min(max(last.x + t * dx, frame.minX + inset), frame.maxX - inset),
        y: min(max(last.y + t * dy, frame.minY + inset), frame.maxY - inset)
    )
}

// Emergency escape: puts the cursor in the middle of the main (menu bar) display, e.g.
// when it is stuck on the virtual display.
func jumpCursorToMainScreenCenter() {
    guard let frame = NSScreen.screens.first?.frame else { return }
    warpCursor(to: CGPoint(x: frame.midX, y: frame.midY))
    lastVirtualLocation = nil
    exitArmed = false
    skipExitCheckOnce = true
    skipEntryCheckOnce = true
}

// `deliberate: false` is for the hold-back warps that undo an OS edge crossing: they
// land on the correct side already, and flagging them would let the very next
// crossing (the user is still pushing) slip through unchecked.
private func warpCursor(to target: CGPoint, deliberate: Bool = true) {
    if deliberate { deliberateWarpPending = true }
    guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }
    // NSEvent/NSScreen use a bottom-left-origin coordinate space; CGWarpMouseCursorPosition
    // expects the top-left-origin Quartz global space, so flip Y before warping.
    let quartzTarget = CGPoint(x: target.x, y: mainScreenHeight - target.y)

    CGAssociateMouseAndMouseCursorPosition(0)
    CGWarpMouseCursorPosition(quartzTarget)
    CGAssociateMouseAndMouseCursorPosition(1)
    nudgeDrag(toQuartz: quartzTarget)
}

// A warp alone doesn't tell something that is being dragged with the left button held
// (typically a window) where the cursor went, so it would only catch up on the next
// hardware movement. Posting a drag event at the destination makes it follow at once.
private func nudgeDrag(toQuartz point: CGPoint) {
    guard NSEvent.pressedMouseButtons & 1 != 0,
          let event = CGEvent(mouseEventSource: warpEventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
    else { return }
    event.post(tap: .cghidEventTap)
}

// Sends the cursor into the virtual display at the point mirroring its position on the
// preview window. A window being dragged by the cursor follows it in.
private func enterVirtualDisplay(at mouseLocation: NSPoint, state: AppState, dispatch: DispatchFunction) {
    let target = entryTarget(
        mouseLocation: mouseLocation,
        contentFrame: state.previewWindowState.contentFrame,
        resolution: state.screenConfigurationState.resolution
    )
    skipExitCheckOnce = true
    dispatch(MouseLocationAction.requestMove(toPoint: target))
    if state.mouseEdgeBehaviorState.cursorMode.raisesWindowOnEntry {
        (NSApp.delegate as? AppDelegate)?.window.orderFrontRegardless()
    }
}

// cmd+shift+D during a window drag in "Click to Enter" mode: if the cursor is over the
// visible preview window, send the cursor — and with it the dragged window — in.
func enterVirtualDisplayWithDraggedWindow() {
    let state: AppState = store.state
    let mouseLocation = NSEvent.mouseLocation
    guard
        state.mouseEdgeBehaviorState.cursorMode == .clickToEnter,
        state.previewWindowState.contentFrame.contains(mouseLocation),
        windowDrag.isDraggingWindow(),
        isPreviewWindowVisible(at: mouseLocation)
    else { return }
    enterVirtualDisplay(at: mouseLocation, state: state, dispatch: { store.dispatch($0) })
}
