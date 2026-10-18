import Foundation

enum RelkError: Error, Equatable, Sendable {
    /// The request never got an HTTP response.
    case network(URLError.Code)
    /// A 401 on register (app key refused) or on a freshly registered token.
    case unauthorized
    case server(status: Int, code: String?, message: String?)
    case invalidResponse
    case imageUnreadable
    /// Still over the server's upload limit at the lowest JPEG quality.
    case imageTooLarge

    var serverCode: String? {
        if case .server(_, let code, _) = self { code } else { nil }
    }
}

extension RelkError {
    /// Transport already maps `URLError`, so anything else is unexpected.
    static func wrapping(_ error: any Error) -> RelkError {
        error as? RelkError ?? .invalidResponse
    }
}

/// The `error` codes from docs/api.md the SDK acts on.
enum ServerErrorCode {
    static let attachmentUnavailable = "attachment_unavailable"
}
