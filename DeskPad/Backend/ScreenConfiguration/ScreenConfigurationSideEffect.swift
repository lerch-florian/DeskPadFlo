import CoreGraphics
import Foundation
import ReSwift

private var isObserving = false
private var hasAppliedDefaultResolution = false

enum ScreenConfigurationAction: Action {
    case set(resolution: CGSize, scaleFactor: CGFloat)
    case selectResolution(CGSize)
}

func screenConfigurationSideEffect() -> SideEffect {
    return { action, dispatch, getState in
        if isObserving == false {
            isObserving = true
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: NSApplication.shared,
                queue: .main
            ) { _ in
                guard let displayID = getState()?.screenConfigurationState.displayID,
                      let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
                else {
                    return
                }

                arrangeVirtualDisplay(displayID: displayID, disconnected: getState()?.mouseEdgeBehaviorState.blockOSScreenConnection == true)

                var resolution = screen.frame.size
                var scaleFactor = screen.backingScaleFactor

                if hasAppliedDefaultResolution == false {
                    hasAppliedDefaultResolution = true
                    if let override = applyDefaultResolutionIfNeeded(displayID: displayID, currentScreen: screen) {
                        resolution = override.resolution
                        scaleFactor = override.scaleFactor
                    }
                }

                dispatch(ScreenConfigurationAction.set(resolution: resolution, scaleFactor: scaleFactor))
            }
        }

        if
            case let MouseEdgeBehaviorAction.setBlockOSScreenConnection(blocked) = action,
            let displayID = getState()?.screenConfigurationState.displayID
        {
            arrangeVirtualDisplay(displayID: displayID, disconnected: blocked)
        }

        if
            case let ScreenConfigurationAction.selectResolution(targetSize) = action,
            let displayID = getState()?.screenConfigurationState.displayID,
            let result = switchDisplayMode(displayID: displayID, targetLogicalSize: targetSize)
        {
            dispatch(ScreenConfigurationAction.set(resolution: result.resolution, scaleFactor: result.scaleFactor))
        }
    }
}

// Places the virtual display in the OS display arrangement (the space System Settings'
// Displays pane edits). By default macOS puts it right next to the main display, and the
// cursor can then be carried across the shared edge by the OS itself. `disconnected`
// instead places it so that it touches the real displays only at a corner: macOS refuses
// gaps (it snaps them shut — verified), but accepts corner-only contact, and without a
// shared edge segment the cursor has nothing to cross. Applied again whenever the
// display reappears or the displays are reconfigured; it is a no-op when already in place.
private func arrangeVirtualDisplay(displayID: CGDirectDisplayID, disconnected: Bool) {
    let realBounds = NSScreen.screens.map(\.displayID).filter { $0 != displayID }.map(CGDisplayBounds)
    guard var union = realBounds.first else { return }
    for bounds in realBounds.dropFirst() {
        union = union.union(bounds)
    }

    let size = CGDisplayBounds(displayID).size
    let origin: CGPoint
    if disconnected {
        guard let corner = cornerOnlyOrigin(for: size, avoiding: realBounds) else { return }
        origin = corner
    } else {
        // macOS' own default: beside the other displays.
        origin = CGPoint(x: union.maxX, y: union.minY)
    }
    guard CGDisplayBounds(displayID).origin != origin else { return }

    var configRef: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else { return }
    CGConfigureDisplayOrigin(configRef, displayID, Int32(origin.x), Int32(origin.y))
    CGCompleteDisplayConfiguration(configRef, .forSession)
}

// An origin (global Quartz space) for a display of `size` that touches one of the given
// displays exactly at a corner and shares no edge with any of them. The bottom-right of
// the arrangement is preferred.
private func cornerOnlyOrigin(for size: CGSize, avoiding others: [CGRect]) -> CGPoint? {
    func isDisconnected(_ rect: CGRect) -> Bool {
        others.allSatisfy { other in
            let overlapX = min(rect.maxX, other.maxX) - max(rect.minX, other.minX)
            let overlapY = min(rect.maxY, other.maxY) - max(rect.minY, other.minY)
            let overlapsArea = overlapX > 0 && overlapY > 0
            let sharesEdge = (overlapX == 0 && overlapY > 0) || (overlapY == 0 && overlapX > 0)
            return !overlapsArea && !sharesEdge
        }
    }

    for (dx, dy) in [(1, 1), (-1, 1), (1, -1), (-1, -1)] as [(CGFloat, CGFloat)] {
        for other in others {
            let cornerX = dx > 0 ? other.maxX : other.minX
            let cornerY = dy > 0 ? other.maxY : other.minY
            let origin = CGPoint(x: dx > 0 ? cornerX : cornerX - size.width, y: dy > 0 ? cornerY : cornerY - size.height)
            if isDisconnected(CGRect(origin: origin, size: size)) { return origin }
        }
    }
    return nil
}

// Switches the virtual display to its default resolution the first time it appears: a
// quarter of the host (built-in) screen — half its width and half its height — instead
// of whatever mode the system happened to pick. With the preview window opening at
// about a quarter of the screen too, the two then match nearly 1:1. The half-size mode
// is the HiDPI companion of the mode declared at the built-in's own size (see
// ScreenViewController), so it is sharp; if the host's size doesn't halve into an
// available mode, fall back to matching the host exactly.
private func applyDefaultResolutionIfNeeded(
    displayID: CGDirectDisplayID,
    currentScreen: NSScreen
) -> (resolution: CGSize, scaleFactor: CGFloat)? {
    guard let builtInScreen = NSScreen.builtIn else { return nil }
    let hostSize = builtInScreen.frame.size
    let quarterSize = CGSize(width: (hostSize.width / 2).rounded(.down), height: (hostSize.height / 2).rounded(.down))

    for target in [quarterSize, hostSize] {
        if currentScreen.frame.size == target { return nil }
        if let result = switchDisplayMode(displayID: displayID, targetLogicalSize: target) { return result }
    }
    return nil
}

// Switches the virtual display to whichever of its available modes has the given
// logical (point) size, preferring a HiDPI-scaled variant over a plain 1x one when
// both exist for that size, and returns the resolved resolution/scale to dispatch
// immediately — waiting for a follow-up didChangeScreenParametersNotification to
// report it isn't reliable, so callers use this value directly instead of re-reading
// NSScreen afterward.
private func switchDisplayMode(
    displayID: CGDirectDisplayID,
    targetLogicalSize: CGSize
) -> (resolution: CGSize, scaleFactor: CGFloat)? {
    // CGDisplayCopyAllDisplayModes omits scaled/"looks like" modes entirely unless
    // explicitly asked for them.
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }

    let candidates = modes.filter {
        CGFloat($0.width) == targetLogicalSize.width && CGFloat($0.height) == targetLogicalSize.height
    }
    guard let matchingMode = candidates.max(by: { $0.pixelWidth < $1.pixelWidth }) else { return nil }

    var configRef: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else { return nil }
    CGConfigureDisplayWithDisplayMode(configRef, displayID, matchingMode, nil)
    CGCompleteDisplayConfiguration(configRef, .forSession)

    let scaleFactor = targetLogicalSize.width > 0 ? CGFloat(matchingMode.pixelWidth) / targetLogicalSize.width : 1
    return (targetLogicalSize, scaleFactor)
}
