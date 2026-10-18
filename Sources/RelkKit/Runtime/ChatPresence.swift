import os

/// Whether a chat is live, readable from the notification delegate's
/// synchronous callbacks: those must call their completion handler on the
/// thread they were called on, so they can't await the main actor.
final class ChatPresence: Sendable {
    static let shared = ChatPresence()

    private let live = OSAllocatedUnfairLock(initialState: false)

    var isLive: Bool {
        live.withLock { $0 }
    }

    func setLive(_ isLive: Bool) {
        live.withLock { $0 = isLive }
    }
}
