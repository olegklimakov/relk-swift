import Foundation
import Observation
import os
import UserNotifications

protocol ChatService: Sendable {
    func messages(after seq: Int, limit: Int) async throws -> MessagePage
    func send(_ message: NewMessage) async throws -> Message
    func uploadAttachment(_ jpeg: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> MessageAttachment
    func markRead(seq: Int) async throws
    func events() -> AsyncStream<LiveEvent>
}

extension APIClient: ChatService {}

/// State of the one chat thread. Lives as long as the configured session, not
/// the view, so history, drafts and failed messages survive closing the sheet.
///
/// Server messages are kept sorted by `seq` and deduplicated by `id`; a local
/// `Outgoing` is dropped as soon as a server message with its `client_id`
/// arrives, whichever path (POST response, SSE, history) delivers it first.
///
/// `cursor` is the `after` for the next history fetch. Only history pages and
/// SSE advance it: a POST response can carry a seq above a developer reply
/// still waiting in the gap, and advancing past it would lose that reply.
@MainActor
@Observable
final class ChatStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(RelkError)
    }

    static let maxImages = 4
    static let maxBodyLength = 4000
    static let pageSize = 200

    private(set) var loadState: LoadState = .idle
    private(set) var sent: [Message] = []
    private(set) var outgoing: [Outgoing] = []
    private(set) var draftImages: [DraftImage] = []
    private(set) var preparingImageCount = 0
    var isLive: Bool { presence.isLive }
    /// `nil` until first read. Re-read rather than cached in storage: the user
    /// can change it in Settings at any time.
    private(set) var notificationStatus: UNAuthorizationStatus?
    var notificationPrompt: RelkNotificationPrompt
    var draftText = ""
    var attachmentFailed = false

    @ObservationIgnored var onRead: @MainActor () -> Void = {}

    @ObservationIgnored private let service: any ChatService
    @ObservationIgnored private let imageLoader: ImageLoader?
    @ObservationIgnored private let makeContext: (String?) -> MessageContext
    @ObservationIgnored private var knownIDs: Set<UUID> = []
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var lastReadSeq = 0
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherSync = false
    @ObservationIgnored private let notifications: any NotificationAuthorizing
    @ObservationIgnored private let presence: ChatPresence
    @ObservationIgnored private var didRegisterForRemoteNotifications = false
    @ObservationIgnored private let log = Logger(subsystem: "Relk", category: "chat")

    init(
        service: any ChatService,
        notificationPrompt: RelkNotificationPrompt,
        imageLoader: ImageLoader? = nil,
        notifications: any NotificationAuthorizing = SystemNotificationAuthorization(),
        presence: ChatPresence = ChatPresence(),
        makeContext: @escaping (String?) -> MessageContext = { DeviceContext.current(screen: $0) }
    ) {
        self.service = service
        self.notificationPrompt = notificationPrompt
        self.imageLoader = imageLoader
        self.notifications = notifications
        self.presence = presence
        self.makeContext = makeContext
    }

    var messages: [ChatMessage] {
        sent.map(ChatMessage.init) + outgoing.map(ChatMessage.init)
    }

    var lastSeq: Int {
        sent.last?.seq ?? 0
    }

    var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unicode scalars, not `Character`s: the server's limit counts code
    /// points, and one emoji grapheme can be several of them.
    var draftLength: Int {
        trimmedDraft.unicodeScalars.count
    }

    var isDraftTooLong: Bool {
        draftLength > Self.maxBodyLength
    }

    var canSend: Bool {
        (!trimmedDraft.isEmpty || !draftImages.isEmpty) && !isDraftTooLong && preparingImageCount == 0
    }

    var remainingImageSlots: Int {
        max(0, Self.maxImages - draftImages.count - preparingImageCount)
    }

    // MARK: - Notifications

    /// Asked only once the user has a confirmed message in the thread, when a
    /// reply is something they are actually waiting for.
    var showsNotificationPrompt: Bool {
        if case .never = notificationPrompt { return false }
        return notificationStatus == .notDetermined && sent.contains { $0.sender == .user }
    }

    /// Also registers with APNs once per launch when notifications are allowed,
    /// so the host only forwards the token.
    func refreshNotificationStatus() async {
        let status = await notifications.status()
        notificationStatus = status
        if status.allowsRemoteNotifications, !didRegisterForRemoteNotifications {
            didRegisterForRemoteNotifications = true
            notifications.registerForRemoteNotifications()
        }
    }

    /// Under `.host` the store never learns the outcome; `RelkRuntime` re-reads the status
    /// whenever the app becomes active, which the system dialog and Settings both cause.
    func enableNotifications() async {
        switch notificationPrompt {
        case .automatic:
            do {
                _ = try await notifications.request()
            } catch {
                log.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
            }
            await refreshNotificationStatus()
        case .host(let ask):
            ask()
        case .never:
            break
        }
    }

    // MARK: - Live connection

    /// Live while the chat is on screen and the app is active: holds the SSE
    /// stream open and advances the read marker.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        presence.setLive(live)
        liveTask?.cancel()
        liveTask = nil
        guard live else { return }
        markReadIfNeeded()
        liveTask = Task { [weak self] in
            await self?.runLive()
        }
    }

    private func runLive() async {
        await sync()
        for await event in service.events() {
            switch event {
            case .connected:
                await sync()
            case .message(let message):
                merge([message], advancingCursor: true)
            }
        }
    }

    /// A caller arriving during a fetch gets another pass, since the running
    /// one may have started before the gap the caller cares about.
    func sync() async {
        if let syncTask {
            needsAnotherSync = true
            await syncTask.value
            return
        }
        let task = Task {
            repeat {
                needsAnotherSync = false
                await performSync()
            } while needsAnotherSync
        }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync() async {
        if loadState != .loaded { loadState = .loading }
        do {
            var hasMore = true
            while hasMore {
                let page = try await service.messages(after: cursor, limit: Self.pageSize)
                merge(page.messages, advancingCursor: true)
                hasMore = page.hasMore && !page.messages.isEmpty
            }
            loadState = .loaded
        } catch {
            log.error("Sync failed: \(String(describing: error), privacy: .public)")
            if loadState != .loaded { loadState = .failed(.wrapping(error)) }
        }
    }

    func merge(_ incoming: [Message], advancingCursor: Bool) {
        for message in incoming {
            if advancingCursor { cursor = max(cursor, message.seq) }
            if let clientId = message.clientId, outgoing.contains(where: { $0.clientId == clientId }) {
                outgoing.removeAll { $0.clientId == clientId }
            }
            guard knownIDs.insert(message.id).inserted else { continue }
            if let last = sent.last, last.seq > message.seq {
                let index = sent.firstIndex { $0.seq > message.seq } ?? sent.endIndex
                sent.insert(message, at: index)
            } else {
                sent.append(message)
            }
        }
        markReadIfNeeded()
    }

    /// After a 401 the SDK registers a new end user with a new, empty thread
    /// whose seqs restart, and attachments uploaded by the old one are unusable.
    func resetForNewIdentity() {
        sent = []
        knownIDs = []
        cursor = 0
        lastReadSeq = 0
        for index in outgoing.indices {
            outgoing[index].discardUploads()
        }
        if isLive || syncTask != nil {
            Task { await sync() }
        }
    }

    private func markReadIfNeeded() {
        guard isLive, lastSeq > lastReadSeq else { return }
        let previous = lastReadSeq
        let seq = lastSeq
        lastReadSeq = seq
        Task {
            do {
                try await service.markRead(seq: seq)
                onRead()
            } catch {
                log.error("Read marker failed: \(String(describing: error), privacy: .public)")
                if lastReadSeq == seq { lastReadSeq = previous }
            }
        }
    }

    // MARK: - Sending

    @discardableResult
    func send(screen: String?, meta: [String: RelkMetaValue]) -> Task<Void, Never>? {
        guard canSend else { return nil }
        let body = trimmedDraft
        let item = Outgoing(
            clientId: UUID(),
            body: body.isEmpty ? nil : body,
            context: makeContext(screen),
            meta: checked(meta),
            createdAt: .now,
            images: draftImages
        )
        outgoing.append(item)
        draftText = ""
        draftImages = []
        return Task { await deliver(item.clientId) }
    }

    private func checked(_ meta: [String: RelkMetaValue]) -> [String: RelkMetaValue]? {
        switch RelkMeta.validated(meta) {
        case .success(let meta):
            return meta
        case .failure(let problem):
            log.error("Meta dropped, \(problem.description, privacy: .public); the message goes without it")
            return nil
        }
    }

    /// Reuses the `client_id`, so a message the server already stored is not duplicated.
    @discardableResult
    func retry(_ clientId: UUID) -> Task<Void, Never>? {
        guard let index = outgoing.firstIndex(where: { $0.clientId == clientId }),
              outgoing[index].isFailed
        else { return nil }
        outgoing[index].isFailed = false
        return Task { await deliver(clientId) }
    }

    func discard(_ clientId: UUID) {
        outgoing.removeAll { $0.clientId == clientId && $0.isFailed }
    }

    /// On `attachment_unavailable` (expired uploads, or ids owned by the user a
    /// 401 re-registration replaced) the images are uploaded again and the
    /// message resent once, as docs/api.md prescribes. On `meta_invalid`, a meta the
    /// local check passed but the server refused, it is resent without the meta.
    private func deliver(_ clientId: UUID) async {
        do {
            let message: Message?
            do {
                message = try await uploadAndSend(clientId)
            } catch let error as RelkError where error.serverCode == ServerErrorCode.attachmentUnavailable {
                update(clientId) { $0.discardUploads() }
                message = try await uploadAndSend(clientId)
            } catch let error as RelkError where error.serverCode == ServerErrorCode.metaInvalid {
                log.error("Meta refused by the server, \(String(describing: error), privacy: .public); resending without it")
                update(clientId) { $0.meta = nil }
                message = try await uploadAndSend(clientId)
            }
            if let message { merge([message], advancingCursor: false) }
        } catch {
            log.error("Send failed: \(String(describing: error), privacy: .public)")
            update(clientId) { $0.isFailed = true }
        }
    }

    /// `nil` when the message was already confirmed through another path.
    private func uploadAndSend(_ clientId: UUID) async throws -> Message? {
        guard let item = outgoing.first(where: { $0.clientId == clientId }) else { return nil }
        var attachmentIDs: [UUID] = []
        for image in item.images {
            if let uploaded = item.uploaded[image.id] {
                attachmentIDs.append(uploaded.id)
                continue
            }
            let attachment = try await service.uploadAttachment(image.encoded.jpeg) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateProgress(fraction, image: image.id, of: clientId)
                }
            }
            await imageLoader?.seed(image.encoded.jpeg, path: attachment.url)
            update(clientId) { $0.uploaded[image.id] = attachment }
            attachmentIDs.append(attachment.id)
        }
        return try await service.send(NewMessage(
            clientId: clientId,
            body: item.body,
            attachmentIds: attachmentIDs,
            context: item.context,
            meta: item.meta
        ))
    }

    private func updateProgress(_ fraction: Double, image: UUID, of clientId: UUID) {
        update(clientId) { item in
            let previous = item.uploadProgress[image] ?? 0
            // Delegate callbacks arrive per network write; redraw every 5 % at most.
            guard fraction >= 1 || fraction - previous >= 0.05 else { return }
            item.uploadProgress[image] = fraction
        }
    }

    private func update(_ clientId: UUID, _ change: (inout Outgoing) -> Void) {
        guard let index = outgoing.firstIndex(where: { $0.clientId == clientId }) else { return }
        var item = outgoing[index]
        change(&item)
        if item != outgoing[index] { outgoing[index] = item }
    }

    // MARK: - Draft images

    /// Each loader returns the picked image's original bytes.
    @discardableResult
    func addImages(_ loaders: [@Sendable () async throws -> Data]) -> Task<Void, Never>? {
        let accepted = loaders.prefix(remainingImageSlots)
        guard !accepted.isEmpty else { return nil }
        preparingImageCount += accepted.count
        return Task {
            for load in accepted {
                do {
                    let data = try await load()
                    let draft = try await Task.detached(priority: .userInitiated) {
                        try DraftImage.make(from: data)
                    }.value
                    draftImages.append(draft)
                } catch {
                    log.error("Attaching image failed: \(String(describing: error), privacy: .public)")
                    attachmentFailed = true
                }
                preparingImageCount -= 1
            }
        }
    }

    func removeDraftImage(_ id: UUID) {
        draftImages.removeAll { $0.id == id }
    }
}
