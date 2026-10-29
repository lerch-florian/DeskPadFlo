import Foundation
import ReSwift

enum MouseEdgeBehaviorAction: Action {
    case setJumpOutEnabled(Bool)
    case setJumpInEnabled(Bool)
    case setJumpInOnlyWhenForeground(Bool)
}

struct MouseEdgeBehaviorState: Equatable {
    var jumpOutEnabled: Bool
    var jumpInEnabled: Bool
    // Refinement of jumpInEnabled: only jump in while DeskPad is the frontmost app.
    // Has no effect unless jumpInEnabled is on.
    var jumpInOnlyWhenForeground: Bool

    static var initialState: MouseEdgeBehaviorState {
        return MouseEdgeBehaviorState(jumpOutEnabled: true, jumpInEnabled: false, jumpInOnlyWhenForeground: false)
    }
}

func mouseEdgeBehaviorReducer(action: Action, state: MouseEdgeBehaviorState) -> MouseEdgeBehaviorState {
    var state = state
    switch action {
    case let MouseEdgeBehaviorAction.setJumpOutEnabled(enabled):
        state.jumpOutEnabled = enabled

    case let MouseEdgeBehaviorAction.setJumpInEnabled(enabled):
        state.jumpInEnabled = enabled

    case let MouseEdgeBehaviorAction.setJumpInOnlyWhenForeground(enabled):
        state.jumpInOnlyWhenForeground = enabled

    default:
        break
    }
    return state
}
