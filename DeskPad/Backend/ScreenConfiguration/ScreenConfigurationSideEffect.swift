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

                var resolution = screen.frame.size
                var scaleFactor = screen.backingScaleFactor

                if hasAppliedDefaultResolution == false {
                    hasAppliedDefaultResolution = true
                    if let override = applyBuiltInResolutionIfNeeded(displayID: displayID, currentScreen: screen) {
                        resolution = override.resolution
                        scaleFactor = override.scaleFactor
                    }
                }

                dispatch(ScreenConfigurationAction.set(resolution: resolution, scaleFactor: scaleFactor))
            }
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

// Switches the virtual display to the built-in display's exact resolution the first
// time it appears, so DeskPad defaults to matching it instead of whatever mode the
// system happened to pick.
private func applyBuiltInResolutionIfNeeded(
    displayID: CGDirectDisplayID,
    currentScreen: NSScreen
) -> (resolution: CGSize, scaleFactor: CGFloat)? {
    guard let builtInScreen = NSScreen.builtIn else { return nil }
    let targetPointSize = builtInScreen.frame.size

    guard
        currentScreen.frame.size != targetPointSize
        || currentScreen.backingScaleFactor != builtInScreen.backingScaleFactor
    else { return nil }

    return switchDisplayMode(displayID: displayID, targetLogicalSize: targetPointSize)
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
