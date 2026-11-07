import Foundation
import ReSwift

// How the cursor moves between the real desktop and the virtual display. The jump
// behavior the 60Hz watcher applies is derived from the selected mode.
enum CursorMode: String, Equatable, CaseIterable {
    case seamless
    case auto
    case clickToEnter

    var title: String {
        switch self {
        case .seamless: return "Seamless"
        case .auto: return "Auto"
        case .clickToEnter: return "Click to Enter"
        }
    }

    var summary: String {
        switch self {
        case .seamless:
            return "The cursor enters and leaves wherever the virtual screen is visible. "
                + "The screen window stays in its current stacking position."
        case .auto:
            return "The cursor enters wherever the virtual screen is visible and leaves "
                + "whenever it reaches any border of the virtual screen. Entering always "
                + "brings the screen window to the top."
        case .clickToEnter:
            return "The cursor enters when you click the screen window and leaves "
                + "whenever it reaches any border of the virtual screen."
        }
    }

    // Moving onto a visible part of the screen window sends the cursor into the
    // virtual display without a click.
    var entersAutomatically: Bool { self != .clickToEnter }

    // The cursor also leaves where its position on the screen window would be covered
    // by another window, not just at the virtual display's borders.
    var exitsWhereCovered: Bool { self == .seamless }

    // Entering brings the screen window to the top.
    var raisesWindowOnEntry: Bool { self == .auto }

    // A click on the virtual display brings the screen window to the top.
    var raisesWindowOnVirtualClick: Bool { self != .seamless }
}

enum MouseEdgeBehaviorAction: Action {
    case setCursorMode(CursorMode)
    case setBlockOSScreenConnection(Bool)
}

struct MouseEdgeBehaviorState: Equatable {
    var cursorMode: CursorMode
    // Stops macOS from carrying the cursor across the shared edge between the virtual
    // display and a real display arranged next to it. When on, the two have no direct
    // connection and the cursor is held back at the edge; only the mode's own jumps move
    // it across.
    var blockOSScreenConnection: Bool

    var jumpInEnabled: Bool { cursorMode.entersAutomatically }

    // The Options menu settings are remembered between launches (UserDefaults); the
    // defaults apply the first time, or if a stored value isn't recognised.
    private enum DefaultsKey {
        static let cursorMode = "cursorMode"
        static let blockOSScreenConnection = "blockOSScreenConnection"
    }

    static var initialState: MouseEdgeBehaviorState {
        let defaults = UserDefaults.standard
        return MouseEdgeBehaviorState(
            cursorMode: defaults.string(forKey: DefaultsKey.cursorMode).flatMap(CursorMode.init(rawValue:)) ?? .auto,
            blockOSScreenConnection: defaults.object(forKey: DefaultsKey.blockOSScreenConnection) as? Bool ?? true
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(cursorMode.rawValue, forKey: DefaultsKey.cursorMode)
        defaults.set(blockOSScreenConnection, forKey: DefaultsKey.blockOSScreenConnection)
    }
}

// Writes the settings out whenever one of them changes.
func mouseEdgeBehaviorPersistenceSideEffect() -> SideEffect {
    return { action, _, getState in
        guard action is MouseEdgeBehaviorAction else { return }
        getState()?.mouseEdgeBehaviorState.save()
    }
}

func mouseEdgeBehaviorReducer(action: Action, state: MouseEdgeBehaviorState) -> MouseEdgeBehaviorState {
    var state = state
    switch action {
    case let MouseEdgeBehaviorAction.setCursorMode(mode):
        state.cursorMode = mode

    case let MouseEdgeBehaviorAction.setBlockOSScreenConnection(blocked):
        state.blockOSScreenConnection = blocked

    default:
        break
    }
    return state
}
