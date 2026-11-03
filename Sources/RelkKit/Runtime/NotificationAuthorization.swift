import UIKit
import UserNotifications

protocol NotificationAuthorizing: Sendable {
    func status() async -> UNAuthorizationStatus
    /// Shows the system prompt; returns whether the user allowed notifications.
    func request() async throws -> Bool
    @MainActor func registerForRemoteNotifications()
    /// What Notification Center still shows, for a reset to clear the old thread's replies.
    func delivered() async -> [DeliveredNotification]
    func removeDelivered(withIdentifiers ids: [String])
}

struct DeliveredNotification: Sendable, Equatable {
    let id: String
    let threadIdentifier: String
    let hasRelkKey: Bool

    /// Relk's reply pushes and the test push carry both marks (docs/api.md, "Push payload").
    var isRelk: Bool { threadIdentifier == "relk" || hasRelkKey }
}

struct SystemNotificationAuthorization: NotificationAuthorizing {
    func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func delivered() async -> [DeliveredNotification] {
        await UNUserNotificationCenter.current().deliveredNotifications().map {
            DeliveredNotification(
                id: $0.request.identifier,
                threadIdentifier: $0.request.content.threadIdentifier,
                hasRelkKey: Relk.isRelkPush($0.request.content.userInfo)
            )
        }
    }

    func removeDelivered(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}

extension UNAuthorizationStatus {
    var allowsRemoteNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }
}
