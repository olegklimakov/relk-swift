import Foundation

struct Message: Codable, Sendable, Equatable, Identifiable {
    enum Sender: String, Codable, Sendable {
        case user
        case developer
        case system

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // A sender added server-side later must not fail a whole history page.
            self = Sender(rawValue: raw) ?? .system
        }
    }

    let id: UUID
    let seq: Int
    let clientId: UUID?
    let sender: Sender
    let body: String?
    let attachments: [MessageAttachment]
    let createdAt: Date
}

struct MessageAttachment: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let width: Int
    let height: Int
    /// Path relative to the server URL, e.g. `/v1/attachments/<id>`.
    let url: String
}

struct MessagePage: Decodable, Sendable, Equatable {
    let messages: [Message]
    let hasMore: Bool
}

struct MessageContext: Codable, Sendable, Equatable {
    var appVersion: String?
    var build: String?
    var os: String?
    var device: String?
    var locale: String?
    /// The language the host app, and so the chat UI, is shown in; `locale`
    /// is the region setting and can differ.
    var language: String?
    var screen: String?
}

struct NewMessage: Encodable, Sendable, Equatable {
    let clientId: UUID
    let body: String?
    let attachmentIds: [UUID]
    let context: MessageContext
}

struct RegisterResponse: Decodable, Sendable {
    let token: String
}

struct UnreadResponse: Decodable, Sendable {
    let count: Int
}

struct ReadMarker: Encodable, Sendable {
    let seq: Int
}

// `bundleID`, here and in RegisterRequest, lets the dashboard spot an app set up under a
// different bundle ID, which Apple refuses pushes for; servers older than A3 PR 12b
// ignore it.
struct DeviceTokenRegistration: Encodable, Sendable, Equatable {
    let token: String
    let environment: PushEnvironment
    let bundleID: String?
}

struct RegisterRequest: Encodable, Sendable {
    let bundleID: String
}

struct ServerErrorBody: Decodable, Sendable {
    let error: String
    let message: String?
}
