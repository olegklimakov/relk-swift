import Foundation

struct SSEEvent: Equatable, Sendable {
    var type: String
    var data: String
}

/// Incremental parser for the `text/event-stream` format (WHATWG HTML §9.2.6),
/// fed byte by byte. `AsyncBytes.lines` can't be used: it drops the blank
/// lines that dispatch events.
struct SSEParser {
    /// A line or an event's data past `maxBytes`; the caller drops the stream.
    struct Overflow: Error {}

    /// A message event stays far below it: a 4,000-character body and 4 KB of meta.
    static let maxBytes = 1 << 20

    private var line: [UInt8] = []
    private var afterCR = false
    private var eventType = ""
    private var data = ""
    /// A whole event or a keepalive comment has arrived: the stream works.
    private(set) var heardFromServer = false

    mutating func feed(_ byte: UInt8) throws(Overflow) -> SSEEvent? {
        let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        if afterCR {
            afterCR = false
            if byte == lf { return nil }
        }
        switch byte {
        case cr:
            afterCR = true
            return try endLine()
        case lf:
            return try endLine()
        default:
            guard line.count < Self.maxBytes else { throw Overflow() }
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() throws(Overflow) -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line.first == UInt8(ascii: ":") {
            heardFromServer = true
            return nil
        }

        // Decoded per whole line so multi-byte characters split across chunks survive.
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }

        switch field {
        case "event": eventType = String(value)
        case "data":
            guard data.utf8.count + value.utf8.count < Self.maxBytes else { throw Overflow() }
            data += value + "\n"
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            data = ""
            eventType = ""
        }
        guard !data.isEmpty else { return nil }
        heardFromServer = true
        return SSEEvent(
            type: eventType.isEmpty ? "message" : eventType,
            data: String(data.dropLast())
        )
    }
}
