import Foundation
import UserNotifications

/// ```swift
/// Relk.configure(appKey: "rk_pub_…")
/// ```
/// The SDK asks for notification permission itself, inside the chat after the
/// user's first message, and calls `registerForRemoteNotifications()` whenever
/// notifications are allowed. The host only forwards the token and the
/// `UNUserNotificationCenterDelegate` callbacks. See docs/integration.md.
@MainActor
public enum Relk {
    /// Call once at launch. Calling again with the same key and server keeps the session;
    /// `welcome` is replaced on every call.
    /// - Parameters:
    ///   - serverURL: Only for a self-hosted server. The default is compiled into every
    ///     host app that ships, so it can never move (D32).
    ///   - welcome: The developer's greeting at the top of the chat; `nil` shows the
    ///     SDK's own empty state.
    public static func configure(
        appKey: String,
        serverURL: URL = URL(string: "https://api.relk.dev")!,
        welcome: RelkWelcome? = nil
    ) {
        RelkRuntime.shared.welcome = welcome
        RelkRuntime.shared.configure(appKey: appKey, serverURL: serverURL)
    }

    /// Pass the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func registerDeviceToken(_ token: Data) {
        RelkRuntime.shared.registerDeviceToken(token)
    }

    /// Developer replies the user hasn't seen. Observable, so a SwiftUI badge
    /// bound to it updates on its own.
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

    nonisolated static func isRelkPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["relk"] != nil
    }
}
