import Foundation
import UserNotifications

/// The SDK's entry point: configuration, push forwarding and the unread count.
///
/// ```swift
/// Relk.configure(appKey: "rk_pub_…")
/// ```
/// By default the SDK asks for notification permission itself, inside the chat after
/// the user's first message (see `RelkNotificationPrompt`), and calls
/// `registerForRemoteNotifications()` whenever notifications are allowed. The host only
/// forwards the token and the `UNUserNotificationCenterDelegate` callbacks. See
/// docs/integration.md.
@MainActor
public enum Relk {
    /// Call once at launch. Calling again with the same key and server keeps the session;
    /// `welcome` and `notificationPrompt` are replaced on every call.
    /// - Parameters:
    ///   - appKey: The app's public key (`rk_pub_…`). Each key keeps its own anonymous
    ///     user in the Keychain, so switching keys starts a separate conversation.
    ///   - serverURL: Only for a self-hosted server. The default is compiled into every
    ///     host app that ships, so it can never move. Must be `https`; plain `http` only
    ///     to `localhost`, `127.0.0.1` or `::1`, which is the Mac in the simulator. A device
    ///     reaches a development server by an https tunnel, not by LAN IP or `.local`. Any
    ///     other URL stops the app with a precondition failure.
    ///   - welcome: The developer's greeting at the top of the chat; `nil` shows the
    ///     SDK's own empty state.
    ///   - notificationPrompt: Who asks for notification permission; `.automatic` lets the
    ///     chat ask after the user's first message.
    public static func configure(
        appKey: String,
        serverURL: URL = URL(string: "https://api.relk.dev")!,
        welcome: RelkWelcome? = nil,
        notificationPrompt: RelkNotificationPrompt = .automatic
    ) {
        precondition(isAllowedServerURL(serverURL), "Relk: serverURL must be https, or http to localhost: \(serverURL)")
        RelkRuntime.shared.welcome = welcome
        RelkRuntime.shared.configure(appKey: appKey, serverURL: serverURL, notificationPrompt: notificationPrompt)
    }

    /// Pass the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// Safe before the user has a conversation: the SDK uploads it once there is one.
    public static func registerDeviceToken(_ token: Data) {
        RelkRuntime.shared.registerDeviceToken(token)
    }

    /// Forgets this install's user, for a sign-out: drops the token from the Keychain and
    /// the chat's history, drafts and cached images, removes Relk's notifications from
    /// Notification Center, sets `unreadCount` to 0, and asks the server to stop pushing the
    /// old conversation's replies to this device. The next time
    /// the chat opens, the SDK registers a new user with an empty conversation. The old
    /// conversation stays on the server, where you can still read it.
    public static func reset() {
        RelkRuntime.shared.reset()
    }

    /// Deletes this install's conversation from the Relk server, for account deletion: its
    /// messages, images and push tokens at once, and the Telegram topic it was mirrored to
    /// soon after; then does what `reset()` does. Throws `RelkDataDeletionError`, keeping the
    /// token and the chat: call it again, not `reset()`, which would leave the conversation
    /// with nothing to delete it by. A second call after a success deletes nothing. Without
    /// a conversation (the chat was never opened) it only resets.
    public static func deleteUserData() async throws(RelkDataDeletionError) {
        try await RelkRuntime.shared.deleteUserData()
    }

    /// Developer replies the user hasn't seen. Observable, so a SwiftUI badge
    /// bound to it updates on its own. Refreshed at launch, on return to the
    /// foreground and on a Relk push; `0` until the chat has been opened once, which
    /// is when the SDK registers the user.
    public static var unreadCount: Int {
        RelkRuntime.shared.unreadCount
    }

    /// Call from `userNotificationCenter(_:didReceive:)`. Returns `false` for
    /// pushes that aren't Relk's. For Relk pushes it asks every
    /// `.relkChat` modifier to present the chat.
    public nonisolated static func handle(_ response: UNNotificationResponse) -> Bool {
        guard isRelkPush(response.notification.request.content.userInfo) else { return false }
        Task { @MainActor in RelkRuntime.shared.pushOpened() }
        return true
    }

    /// Call from `userNotificationCenter(_:willPresent:)`. Returns `nil` for
    /// pushes that aren't Relk's; for Relk pushes, no banner while the
    /// chat is on screen and a banner otherwise.
    public nonisolated static func presentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions? {
        guard isRelkPush(notification.request.content.userInfo) else { return nil }
        if ChatPresence.shared.isLive { return [] }
        Task { @MainActor in RelkRuntime.shared.refreshUnread() }
        return [.banner, .list, .sound]
    }

    /// Every request carries the device token, which names the conversation.
    nonisolated static func isAllowedServerURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
            return ["localhost", "127.0.0.1", "::1"].contains(host)
        default:
            return false
        }
    }

    nonisolated static func isRelkPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["relk"] != nil
    }
}
