import Foundation
import os

/// Owns the device token: loads it from the store, registers when there is
/// none, and coalesces concurrent registrations into one request. Retired
/// (`Relk.reset()`, `Relk.deleteUserData()`), it never registers again.
actor Credentials {
    private let transport: Transport
    private let appKey: String
    private let bundleID: String?
    private let store: any TokenStore
    private let onRegister: @Sendable (_ replacedIdentity: Bool) -> Void
    private let log = Logger(subsystem: "Relk", category: "credentials")

    private var cached: String?
    private var didLoad = false
    private var registration: Task<String, any Error>?
    private var discardedToken = false
    private var retiring = 0
    private var retired = false
    /// The previous identity's credentials retiring: the store still holds their token
    /// until that finishes.
    private var replacing: Task<Void, Never>?

    init(
        transport: Transport,
        appKey: String,
        bundleID: String?,
        store: any TokenStore,
        replacing: Task<Void, Never>? = nil,
        onRegister: @escaping @Sendable (_ replacedIdentity: Bool) -> Void
    ) {
        self.transport = transport
        self.appKey = appKey
        self.bundleID = bundleID
        self.store = store
        self.replacing = replacing
        self.onRegister = onRegister
    }

    func existingToken() async throws -> String? {
        if retired { return nil }
        if let replacing {
            await replacing.value
            self.replacing = nil
        }
        if !didLoad {
            cached = try store.load()
            didLoad = true
        }
        return cached
    }

    func token() async throws -> String {
        if let existing = try await existingToken() { return existing }
        // After the await above, which may have spanned a retirement.
        if retired { throw RelkError.unauthorized }
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
        guard retiring == 0, !retired, cached == token else { return }
        cached = nil
        discardedToken = true
        store.delete()
    }

    /// Ends this identity: the token leaves the store, and no request made through these
    /// credentials registers again. `last`, when given, runs first with the token if there
    /// is one; meanwhile a 401, which its success causes, cannot replace the token. If
    /// `last` throws, or the store cannot be read for it, nothing ends. Returns the token.
    @discardableResult
    func retire(after last: (@Sendable (String) async throws -> Void)? = nil) async throws -> String? {
        // A sign-out ends the identity even when the token cannot be read; a deletion must
        // not, or it would forget a thread it never deleted.
        let token: String?
        if last == nil {
            token = try? await existingToken()
        } else {
            token = try await existingToken()
        }
        retiring += 1
        defer { retiring -= 1 }
        if let last, let token { try await last(token) }
        retired = true
        cached = nil
        store.delete()
        return token
    }

    private func register() async throws -> String {
        var request = transport.request("POST", "v1/register")
        request.setValue(appKey, forHTTPHeaderField: "X-Relk-App-Key")
        if let bundleID {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCoding.makeEncoder().encode(RegisterRequest(bundleID: bundleID))
        }
        let (data, response) = try await transport.data(for: request)
        try Transport.validate(response, data: data)
        let token = try JSONCoding.makeDecoder().decode(RegisterResponse.self, from: data).token
        // Retired while the request was out: the store is the next identity's now.
        if retired { throw RelkError.unauthorized }
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
