import Foundation
import ReSwift

enum MouseEdgeBehaviorAction: Action {
    case setJumpOutEnabled(Bool)
    case setJumpInEnabled(Bool)
}

struct MouseEdgeBehaviorState: Equatable {
    let jumpOutEnabled: Bool
    let jumpInEnabled: Bool

    static var initialState: MouseEdgeBehaviorState {
        return MouseEdgeBehaviorState(jumpOutEnabled: true, jumpInEnabled: false)
    }
}

func mouseEdgeBehaviorReducer(action: Action, state: MouseEdgeBehaviorState) -> MouseEdgeBehaviorState {
    switch action {
    case let MouseEdgeBehaviorAction.setJumpOutEnabled(enabled):
        return MouseEdgeBehaviorState(jumpOutEnabled: enabled, jumpInEnabled: state.jumpInEnabled)

    case let MouseEdgeBehaviorAction.setJumpInEnabled(enabled):
        return MouseEdgeBehaviorState(jumpOutEnabled: state.jumpOutEnabled, jumpInEnabled: enabled)

    default:
        return state
    }
}
