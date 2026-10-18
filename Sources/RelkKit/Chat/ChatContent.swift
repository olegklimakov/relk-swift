/// What the chat screen shows for a history and its load state.
enum ChatContent: Equatable {
    case failed(RelkError)
    case loading
    case empty
    /// `loadingHistory`: the welcome is up while the history is still on its way, as on
    /// every cold start of a user who has one.
    case list(loadingHistory: Bool)

    static func resolve(isEmpty: Bool, loadState: ChatStore.LoadState, hasWelcome: Bool) -> ChatContent {
        guard isEmpty else { return .list(loadingHistory: false) }
        switch (loadState, hasWelcome) {
        case (.failed(let error), _): return .failed(error)
        case (.loaded, false): return .empty
        case (.loaded, true): return .list(loadingHistory: false)
        case (_, false): return .loading
        case (_, true): return .list(loadingHistory: true)
        }
    }
}
