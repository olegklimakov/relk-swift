import Foundation

enum RelkError: Error, Equatable, Sendable {
    /// The request never got an HTTP response.
    case network(URLError.Code)
    /// A 401 on register (app key refused) or on a freshly registered token, or a request
    /// through credentials that `Relk.reset()` or `Relk.deleteUserData()` retired.
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
    static let metaInvalid = "meta_invalid"
}

/// Why `Relk.deleteUserData()` deleted nothing. The token and the chat are kept in every
/// case, so the call can be repeated.
public enum RelkDataDeletionError: Error, Equatable, Sendable {
    /// Called before `Relk.configure`.
    case notConfigured
    /// The Keychain could not be read: the device has not been unlocked since it restarted.
    /// Try again once it has.
    case keychainUnavailable
    /// No answer from the Relk server: offline, or it could not be reached.
    case unreachable
    /// The server answered with this HTTP status instead of deleting.
    case refused(status: Int)

    init(_ error: any Error) {
        switch error {
        case is KeychainError:
            self = .keychainUnavailable
        case RelkError.server(let status, _, _):
            self = .refused(status: status)
        case RelkError.unauthorized:
            self = .refused(status: 401)
        default:
            self = .unreachable
        }
    }
}

