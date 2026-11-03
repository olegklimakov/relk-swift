import Foundation

/// A JSON value in the host's `meta`, which the chat attaches to the messages it sends
/// (see `relkChat(isPresented:screen:meta:tint:presentsPushes:)`). The literals make a
/// meta read like JSON: `["kind": "report", "path_id": "\(path.id)", "day": 3]`.
///
/// Numbers are `Double`s within ±2^53 (I-JSON), so send ids as strings.
public enum RelkMetaValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([RelkMetaValue])
    case object([String: RelkMetaValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RelkMetaValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RelkMetaValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension RelkMetaValue: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension RelkMetaValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension RelkMetaValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension RelkMetaValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension RelkMetaValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension RelkMetaValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: RelkMetaValue...) {
        self = .array(elements)
    }
}

extension RelkMetaValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, RelkMetaValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}

/// The server's limits on a meta (docs/api.md), checked before sending: a meta over one
/// is dropped and the message goes without it.
enum RelkMeta {
    static let maxBytes = 4096
    static let maxDepth = 3
    static let maxKeyLength = 64
    static let maxNumber = 9_007_199_254_740_992.0

    /// The meta to send: `nil` when it is empty, which the server treats as none, or when
    /// it breaks a limit, with the reason.
    static func validated(_ meta: [String: RelkMetaValue]) -> Result<[String: RelkMetaValue]?, Problem> {
        guard !meta.isEmpty else { return .success(nil) }
        if let problem = problem(in: .object(meta), depth: 1) { return .failure(problem) }
        guard let size = size(of: meta) else { return .failure(.unencodable) }
        return size > maxBytes ? .failure(.tooLarge(size)) : .success(meta)
    }

    /// Bytes as compact UTF-8 JSON, which is what the server counts (`meta_size` in
    /// server/src/relk/schemas.py). Python escapes no `/`; Foundation does by default.
    static func size(of meta: [String: RelkMetaValue]) -> Int? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try? encoder.encode(meta).count
    }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case tooLarge(Int)
        case tooDeep
        case longKey
        case nul
        case notFinite
        case bigNumber
        case unencodable

        var description: String {
            switch self {
            case .tooLarge(let size): "\(size) bytes, over \(RelkMeta.maxBytes)"
            case .tooDeep: "nested deeper than \(RelkMeta.maxDepth) levels"
            case .longKey: "a key is longer than \(RelkMeta.maxKeyLength) characters"
            // Postgres refuses U+0000 inside JSONB.
            case .nul: "a string holds U+0000"
            case .notFinite: "a number is not finite"
            case .bigNumber: "a number is beyond ±2^53"
            case .unencodable: "not encodable as JSON"
            }
        }
    }

    private static func problem(in value: RelkMetaValue, depth: Int) -> Problem? {
        let children: [RelkMetaValue]
        switch value {
        case .string(let string):
            return string.unicodeScalars.contains("\0") ? .nul : nil
        case .number(let number):
            guard number.isFinite else { return .notFinite }
            return abs(number) > maxNumber ? .bigNumber : nil
        case .bool, .null:
            return nil
        case .array(let items):
            children = items
        case .object(let object):
            // Unicode scalars, as Python's `len` counts a key.
            if object.keys.contains(where: { $0.unicodeScalars.count > maxKeyLength }) { return .longKey }
            if object.keys.contains(where: { $0.unicodeScalars.contains("\0") }) { return .nul }
            children = Array(object.values)
        }
        if depth > maxDepth { return .tooDeep }
        return children.lazy.compactMap { problem(in: $0, depth: depth + 1) }.first
    }
}
