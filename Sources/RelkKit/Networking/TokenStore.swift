import Foundation
import os
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
/// They stay on this device: a backup restored to another one starts a new thread (D57).
struct KeychainTokenStore: TokenStore {
    let account: String

    /// After first unlock because push-triggered refreshes can run while the device is locked.
    private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

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
            keepOnThisDevice()
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
        attributes[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// RelkKit 0.3.0 and earlier saved the token as `kSecAttrAccessibleAfterFirstUnlock`, which a
    /// backup carries to another device. Matching on that class makes this a no-op once
    /// the item has moved; a failure leaves the token as it was, still readable.
    private func keepOnThisDevice() {
        var stale = query
        stale[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let update = [kSecAttrAccessible as String: Self.accessibility]
        let status = SecItemUpdate(stale as CFDictionary, update as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Logger(subsystem: "Relk", category: "keychain")
                .error("Moving the token to this device failed: \(status, privacy: .public)")
        }
    }
}
