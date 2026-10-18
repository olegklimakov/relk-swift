import Foundation
import os

/// Owns the device token: loads it from the store, registers when there is
/// none, and coalesces concurrent registrations into one request.
actor Credentials {
    private let transport: Transport
    private let appKey: String
    private let store: any TokenStore
    private let onRegister: @Sendable (_ replacedIdentity: Bool) -> Void
    private let log = Logger(subsystem: "Relk", category: "credentials")

    private var cached: String?
    private var didLoad = false
    private var registration: Task<String, any Error>?
    private var discardedToken = false

    init(
        transport: Transport,
        appKey: String,
        store: any TokenStore,
        onRegister: @escaping @Sendable (_ replacedIdentity: Bool) -> Void
    ) {
        self.transport = transport
        self.appKey = appKey
        self.store = store
        self.onRegister = onRegister
    }

    func existingToken() throws -> String? {
        if !didLoad {
            cached = try store.load()
            didLoad = true
        }
        return cached
    }

    func token() async throws -> String {
        if let existing = try existingToken() { return existing }
        if let registration { return try await registration.value }

        let task = Task { try await register() }
        registration = task
        defer { registration = nil }
        let token = try await task.value
        let replaced = discardedToken
        discardedToken = false
        onRegister(replaced)
        return token
    }

    /// Discards `token` only if it is still current, so several requests
    /// failing with the same stale token cause a single re-registration.
    func invalidate(_ token: String) {
        guard cached == token else { return }
        cached = nil
        discardedToken = true
        store.delete()
    }

    private func register() async throws -> String {
        var request = transport.request("POST", "v1/register")
        request.setValue(appKey, forHTTPHeaderField: "X-Relk-App-Key")
        let (data, response) = try await transport.data(for: request)
        try Transport.validate(response, data: data)
        let token = try JSONCoding.makeDecoder().decode(RegisterResponse.self, from: data).token
        cached = token
        do {
            try store.save(token)
        } catch {
            // Keep the in-memory token: the chat still works for this launch,
            // the next launch registers a new (empty) thread.
            log.error("Keychain save failed: \(String(describing: error), privacy: .public)")
        }
        return token
    }
}
