import Foundation
import os

enum LiveEvent: Sendable, Equatable {
    /// Emitted on every (re)connect; events do not replay, so the consumer fills the gap.
    case connected
    case message(Message)
}

/// The `/v1` API from `docs/api.md`. Every device-token call goes through
/// `authorized(_:)`, which on a 401 discards the token, registers once and
/// retries once.
final class APIClient: Sendable {
    let transport: Transport
    let credentials: Credentials
    private let log = Logger(subsystem: "Relk", category: "api")

    init(
        appKey: String,
        serverURL: URL,
        session: URLSession,
        tokenStore: any TokenStore,
        onRegister: @escaping @Sendable (_ replacedIdentity: Bool) -> Void = { _ in }
    ) {
        let transport = Transport(serverURL: serverURL, session: session)
        self.transport = transport
        self.credentials = Credentials(
            transport: transport,
            appKey: appKey,
            store: tokenStore,
            onRegister: onRegister
        )
    }

    func hasIdentity() async -> Bool {
        // A locked Keychain counts as "no identity yet": callers only skip work.
        (try? await credentials.existingToken()) != nil
    }

    func messages(after seq: Int, limit: Int) async throws -> MessagePage {
        let request = transport.request("GET", "v1/messages", query: [
            URLQueryItem(name: "after", value: String(seq)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try decode(MessagePage.self, from: try await call(request))
    }

    func send(_ message: NewMessage) async throws -> Message {
        let request = try jsonRequest("POST", "v1/messages", body: message)
        return try decode(Message.self, from: try await call(request))
    }

    func uploadAttachment(
        _ jpeg: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MessageAttachment {
        var request = transport.request("POST", "v1/attachments")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: progress)
        let data = try await authorizedData { token in
            try await transport.upload(request.authorized(with: token), body: jpeg, delegate: delegate)
        }
        return try decode(MessageAttachment.self, from: data)
    }

    func attachmentData(path: String) async throws -> Data {
        let request = transport.request("GET", path, cachePolicy: .useProtocolCachePolicy)
        return try await call(request)
    }

    func unreadCount() async throws -> Int {
        let request = transport.request("GET", "v1/unread")
        return try decode(UnreadResponse.self, from: try await call(request)).count
    }

    func markRead(seq: Int) async throws {
        _ = try await call(try jsonRequest("POST", "v1/read", body: ReadMarker(seq: seq)))
    }

    func registerDeviceToken(_ registration: DeviceTokenRegistration) async throws {
        _ = try await call(try jsonRequest("PUT", "v1/device-token", body: registration))
    }

    /// Server-sent events for the caller's thread, reconnecting with backoff
    /// until the consumer stops iterating.
    func events() -> AsyncStream<LiveEvent> {
        AsyncStream { continuation in
            let task = Task { await self.pumpEvents(into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func pumpEvents(into continuation: AsyncStream<LiveEvent>.Continuation) async {
        var request = transport.request("GET", "v1/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // An idle timeout, not a total one: the server's 15 s ping resets it.
        request.timeoutInterval = 60
        let decoder = JSONCoding.makeDecoder()
        var backoff = Backoff()

        while !Task.isCancelled {
            do {
                let (bytes, response) = try await authorized { token in
                    try await transport.bytes(for: request.authorized(with: token))
                }
                // A stream carries no JSON error body to decode.
                try Transport.validate(response, data: Data())
                continuation.yield(.connected)

                var parser = SSEParser()
                for try await byte in bytes {
                    backoff.reset()
                    guard let event = parser.feed(byte), event.type == "message" else { continue }
                    do {
                        continuation.yield(.message(try decoder.decode(Message.self, from: Data(event.data.utf8))))
                    } catch {
                        log.error("Undecodable event: \(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                if Task.isCancelled { break }
                log.info("Event stream dropped: \(String(describing: error), privacy: .public)")
            }
            do {
                try await Task.sleep(for: backoff.next())
            } catch {
                break
            }
        }
        continuation.finish()
    }

    private func call(_ request: URLRequest) async throws -> Data {
        try await authorizedData { token in
            try await transport.data(for: request.authorized(with: token))
        }
    }

    private func authorizedData(
        _ perform: (String) async throws -> (Data, HTTPURLResponse)
    ) async throws -> Data {
        let (data, response) = try await authorized(perform)
        try Transport.validate(response, data: data)
        return data
    }

    /// A second 401 is returned as is; `Transport.validate` turns it into `.unauthorized`.
    private func authorized<T>(
        _ perform: (String) async throws -> (T, HTTPURLResponse)
    ) async throws -> (T, HTTPURLResponse) {
        let token = try await credentials.token()
        let first = try await perform(token)
        guard first.1.statusCode == 401 else { return first }

        await credentials.invalidate(token)
        return try await perform(try await credentials.token())
    }

    private func jsonRequest(_ method: String, _ path: String, body: some Encodable) throws -> URLRequest {
        var request = transport.request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.makeEncoder().encode(body)
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.makeDecoder().decode(type, from: data)
        } catch {
            log.error("Undecodable \(String(describing: type), privacy: .public): \(String(describing: error), privacy: .public)")
            throw RelkError.invalidResponse
        }
    }
}

struct Backoff: Equatable {
    private var attempt = 0

    mutating func next() -> Duration {
        let seconds = min(30, 1 << attempt)
        attempt = min(attempt + 1, 5)
        return .seconds(seconds)
    }

    mutating func reset() {
        attempt = 0
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
