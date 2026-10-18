import UIKit
import UserNotifications

protocol NotificationAuthorizing: Sendable {
    func status() async -> UNAuthorizationStatus
    /// Shows the system prompt; returns whether the user allowed notifications.
    func request() async throws -> Bool
    @MainActor func registerForRemoteNotifications()
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
