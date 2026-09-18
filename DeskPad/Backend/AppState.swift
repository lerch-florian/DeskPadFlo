import ReSwift

struct AppState: Equatable {
    let mouseLocationState: MouseLocationState
    let screenConfigurationState: ScreenConfigurationState
    let previewWindowState: PreviewWindowState
    let mouseEdgeBehaviorState: MouseEdgeBehaviorState

    static var initialState: AppState {
        return AppState(
            mouseLocationState: .initialState,
            screenConfigurationState: .initialState,
            previewWindowState: .initialState,
            mouseEdgeBehaviorState: .initialState
        )
    }
}

func appReducer(action: Action, state: AppState?) -> AppState {
    let state = state ?? .initialState

    return AppState(
        mouseLocationState: mouseLocationReducer(action: action, state: state.mouseLocationState),
        screenConfigurationState: screenConfigurationReducer(action: action, state: state.screenConfigurationState),
        previewWindowState: previewWindowReducer(action: action, state: state.previewWindowState),
        mouseEdgeBehaviorState: mouseEdgeBehaviorReducer(action: action, state: state.mouseEdgeBehaviorState)
    )
}
