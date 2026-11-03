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

    init(
        appKey: String,
        serverURL: URL,
        client: APIClient,
        notificationPrompt: RelkNotificationPrompt,
        notifications: any NotificationAuthorizing
    ) {
        self.appKey = appKey
        self.serverURL = serverURL
        self.client = client
        let images = ImageLoader { path in try await client.attachmentData(path: path) }
        self.images = images
        self.chat = ChatStore(
            service: client,
            notificationPrompt: notificationPrompt,
            imageLoader: images,
            notifications: notifications,
            presence: .shared
        )
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
    @ObservationIgnored private var activeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Logger(subsystem: "Relk", category: "runtime")
    @ObservationIgnored private let makeURLSession: () -> URLSession
    @ObservationIgnored private let makeTokenStore: (_ appKey: String) -> any TokenStore
    @ObservationIgnored private let notifications: any NotificationAuthorizing

    init(
        makeURLSession: @escaping () -> URLSession = { .relk() },
        makeTokenStore: @escaping (_ appKey: String) -> any TokenStore = { KeychainTokenStore(account: $0) },
        notifications: any NotificationAuthorizing = SystemNotificationAuthorization()
    ) {
        self.makeURLSession = makeURLSession
        self.makeTokenStore = makeTokenStore
        self.notifications = notifications
    }

    func configure(appKey: String, serverURL: URL, notificationPrompt: RelkNotificationPrompt) {
        if let session, session.appKey == appKey, session.serverURL == serverURL {
            session.chat.notificationPrompt = notificationPrompt
            return
        }
        session?.chat.setLive(false)
        start(appKey: appKey, serverURL: serverURL, notificationPrompt: notificationPrompt)
    }

    /// Replaces the session at once; the old identity retires in the background, and the
    /// new one reads the Keychain only after that. Then unregisters the old push token, so
    /// the old thread's replies stop reaching this device. Offline, that request fails and
    /// the token stays on the old thread until a new identity uploads it.
    func reset() {
        guard let old = session else { return }
        let log = log
        let retiring = Task { try? await old.client.credentials.retire() }
        replace(old, waitingFor: Task { _ = await retiring.value })
        // Through the new session's client: the old one's URLSession is cancelled.
        guard let client = session?.client else { return }
        Task {
            guard let token = await retiring.value else { return }
            do {
                try await client.unregisterDevice(token: token)
            } catch {
                log.error("Push token unregister failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The server deletes the device tokens with the thread, so nothing is unregistered.
    func deleteUserData() async throws(RelkDataDeletionError) {
        guard let old = session else { throw .notConfigured }
        do {
            try await old.client.deleteThread()
        } catch {
            throw RelkDataDeletionError(error)
        }
        // A configure with another key meanwhile replaced this session already.
        guard session === old else { return }
        replace(old, waitingFor: nil)
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

    private func start(
        appKey: String,
        serverURL: URL,
        notificationPrompt: RelkNotificationPrompt,
        replacing: Task<Void, Never>? = nil
    ) {
        let client = APIClient(
            appKey: appKey,
            serverURL: serverURL,
            session: makeURLSession(),
            tokenStore: makeTokenStore(appKey),
            // In an app extension Bundle.main is the .appex, whose id would read as a
            // mismatch with the app's.
            bundleID: Bundle.main.bundleURL.pathExtension == "appex" ? nil : Bundle.main.bundleIdentifier,
            replacing: replacing,
            onRegister: { [weak self] replacedIdentity in
                Task { @MainActor in self?.identityDidChange(replacedIdentity: replacedIdentity) }
            }
        )
        let session = ChatSession(
            appKey: appKey,
            serverURL: serverURL,
            client: client,
            notificationPrompt: notificationPrompt,
            notifications: notifications
        )
        session.chat.onRead = { [weak self] in self?.unreadCount = 0 }
        self.session = session
        unreadTask?.cancel()
        unreadCount = 0

        observeForeground()
        refreshUnread()
        uploadDeviceToken()
        Task { await session.chat.refreshNotificationStatus() }
    }

    /// A fresh chat under the same key with no identity; it registers on the next open. A
    /// chat on screen stays live, and so registers at once.
    private func replace(_ old: ChatSession, waitingFor retiring: Task<Void, Never>?) {
        let wasLive = old.chat.isLive
        old.chat.setLive(false)
        // Cancelled first: an image download still running would cache the old user's
        // image again after the purge.
        old.client.transport.session.invalidateAndCancel()
        old.client.removeCachedResponses()
        start(
            appKey: old.appKey,
            serverURL: old.serverURL,
            notificationPrompt: old.chat.notificationPrompt,
            replacing: retiring
        )
        session?.chat.setLive(wasLive)
        let notifications = notifications
        Task {
            let relk = await notifications.delivered().filter(\.isRelk).map(\.id)
            if !relk.isEmpty { notifications.removeDelivered(withIdentifiers: relk) }
        }
    }

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

    /// The status is re-read on every activation, not only on foreground: a permission
    /// dialog, the SDK's or the host's own, makes the app inactive and nothing more. The
    /// unread count stays on foreground, so closing Control Center costs no request.
    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUnread() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let chat = self?.session?.chat else { return }
                Task { await chat.refreshNotificationStatus() }
            }
        }
    }
}
