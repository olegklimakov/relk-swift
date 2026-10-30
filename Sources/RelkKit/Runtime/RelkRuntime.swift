import Foundation
import Observation
import os
import UIKit
import UserNotifications

/// Everything one `configure` call creates. Replaced as a whole on reconfigure.
@MainActor
final class ChatSession {
    let appKey: String
    let serverURL: URL
    let client: APIClient
    let chat: ChatStore
    let images: ImageLoader

    init(appKey: String, serverURL: URL, client: APIClient) {
        self.appKey = appKey
        self.serverURL = serverURL
        self.client = client
        let images = ImageLoader { path in try await client.attachmentData(path: path) }
        self.images = images
        self.chat = ChatStore(service: client, imageLoader: images, presence: .shared)
    }
}

/// Process-wide SDK state behind the static `Relk` API.
@MainActor
@Observable
final class RelkRuntime {
    static let shared = RelkRuntime()

    private(set) var session: ChatSession?
    private(set) var unreadCount = 0
    /// Set by a tapped push; consumed by the `.relkChat` modifier.
    var isPresentationRequested = false
    var welcome: RelkWelcome?

    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private var unreadTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Logger(subsystem: "Relk", category: "runtime")

    func configure(appKey: String, serverURL: URL) {
        if let session, session.appKey == appKey, session.serverURL == serverURL { return }
        session?.chat.setLive(false)

        let client = APIClient(
            appKey: appKey,
            serverURL: serverURL,
            session: .relk(),
            tokenStore: KeychainTokenStore(account: appKey),
            // In an app extension Bundle.main is the .appex, whose id would read as a
            // mismatch with the app's.
            bundleID: Bundle.main.bundleURL.pathExtension == "appex" ? nil : Bundle.main.bundleIdentifier,
            onRegister: { [weak self] replacedIdentity in
                Task { @MainActor in self?.identityDidChange(replacedIdentity: replacedIdentity) }
            }
        )
        let session = ChatSession(appKey: appKey, serverURL: serverURL, client: client)
        session.chat.onRead = { [weak self] in self?.unreadCount = 0 }
        self.session = session
        unreadCount = 0

        observeForeground()
        refreshUnread()
        uploadDeviceToken()
        Task { await session.chat.refreshNotificationStatus() }
    }

    func registerDeviceToken(_ token: Data) {
        apnsToken = token.hexEncoded
        uploadDeviceToken()
    }

    func pushOpened() {
        isPresentationRequested = true
        refreshUnread()
    }

    func refreshUnread() {
        guard let session, !session.chat.isLive else { return }
        unreadTask?.cancel()
        unreadTask = Task {
            // Without a token there is no thread yet; asking would register one.
            guard await session.client.hasIdentity() else {
                unreadCount = 0
                return
            }
            do {
                let count = try await session.client.unreadCount()
                if !Task.isCancelled { unreadCount = count }
            } catch {
                log.error("Unread refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Private

    /// A new identity has an empty device-token list on the server.
    private func identityDidChange(replacedIdentity: Bool) {
        if replacedIdentity { session?.chat.resetForNewIdentity() }
        uploadDeviceToken()
        refreshUnread()
    }

    /// Skipped until the user has an identity: registering just to store a
    /// push token would create a thread for every install. `onRegister` retries.
    private func uploadDeviceToken() {
        guard let session, let apnsToken else { return }
        let environment = PushEnvironment.detect()
        Task {
            guard await session.client.hasIdentity() else { return }
            do {
                try await session.client.registerDeviceToken(token: apnsToken, environment: environment)
            } catch {
                log.error("Device token upload failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func didEnterForeground() {
        refreshUnread()
        guard let chat = session?.chat else { return }
        Task { await chat.refreshNotificationStatus() }
    }

    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterForeground() }
        }
    }
}
