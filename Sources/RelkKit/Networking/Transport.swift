import Foundation

/// The HTTP layer below auth: URL building, status validation, error mapping.
struct Transport: Sendable {
    let serverURL: URL
    let session: URLSession

    /// `path` may carry a leading slash (attachment URLs do); it is always
    /// resolved below `serverURL`, so a server mounted under a path prefix works.
    func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
    ) -> URLRequest {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var url = serverURL.appending(path: relative)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url, cachePolicy: cachePolicy)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await mappingErrors {
            let (data, response) = try await session.data(for: request)
            return (data, try Self.http(response))
        }
    }

    func upload(
        _ request: URLRequest,
        body: Data,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, HTTPURLResponse) {
        try await mappingErrors {
            let (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
            return (data, try Self.http(response))
        }
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await mappingErrors {
            let (bytes, response) = try await session.bytes(for: request)
            return (bytes, try Self.http(response))
        }
    }

    static func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if response.statusCode == 401 { throw RelkError.unauthorized }
        let body = try? JSONCoding.makeDecoder().decode(ServerErrorBody.self, from: data)
        throw RelkError.server(status: response.statusCode, code: body?.error, message: body?.message)
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw RelkError.invalidResponse }
        return http
    }

    private func mappingErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError {
            throw RelkError.network(error.code)
        }
    }
}

extension URLRequest {
    func authorized(with token: String) -> URLRequest {
        var request = self
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension URLSession {
    static func relk() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        // Attachments are immutable and served with a year-long max-age; a disk
        // cache of their own keeps them out of the host app's shared URLCache.
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "Relk", directoryHint: .isDirectory)
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            directory: directory
        )
        return URLSession(configuration: configuration)
    }
}
