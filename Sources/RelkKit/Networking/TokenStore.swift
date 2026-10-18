import Foundation
import Security

protocol TokenStore: Sendable {
    /// `nil` only when there is no token; unreadable (e.g. locked) throws.
    func load() throws -> String?
    func save(_ token: String) throws
    func delete()
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// Keychain items survive app reinstall, so a user who reinstalls keeps their thread.
struct KeychainTokenStore: TokenStore {
    let account: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "relk",
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            // errSecInteractionNotAllowed before first unlock after a reboot;
            // reading that as "no token" would register a new identity.
            throw KeychainError(status: status)
        }
    }

    func save(_ token: String) throws {
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        // Push-triggered refreshes can run while the device is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
