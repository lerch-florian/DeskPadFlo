import Foundation
import ReSwift

enum PreviewWindowAction: Action {
    case setContentFrame(CGRect)
}

struct PreviewWindowState: Equatable {
    let contentFrame: CGRect

    static var initialState: PreviewWindowState {
        return PreviewWindowState(contentFrame: .zero)
    }
}

func previewWindowReducer(action: Action, state: PreviewWindowState) -> PreviewWindowState {
    switch action {
    case let PreviewWindowAction.setContentFrame(contentFrame):
        return PreviewWindowState(contentFrame: contentFrame)

    default:
        return state
    }
}
