import Foundation

struct SSEEvent: Equatable, Sendable {
    var type: String
    var data: String
}

/// Incremental parser for the `text/event-stream` format (WHATWG HTML §9.2.6),
/// fed byte by byte. `AsyncBytes.lines` can't be used: it drops the blank
/// lines that dispatch events.
struct SSEParser {
    private var line: [UInt8] = []
    private var afterCR = false
    private var eventType = ""
    private var data = ""

    mutating func feed(_ byte: UInt8) -> SSEEvent? {
        let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        if afterCR {
            afterCR = false
            if byte == lf { return nil }
        }
        switch byte {
        case cr:
            afterCR = true
            return endLine()
        case lf:
            return endLine()
        default:
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line.first == UInt8(ascii: ":") { return nil }

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
        case "data": data += value + "\n"
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
        return SSEEvent(
            type: eventType.isEmpty ? "message" : eventType,
            data: String(data.dropLast())
        )
    }
}
