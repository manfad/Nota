import Foundation

/// A `.json` file read into a `StructuredDocument` — the tree the preview
/// column draws beside the source.
///
/// A second walker over the same grammar `JSONFormat` walks, and deliberately
/// not the same one: the two answer different questions. `JSONFormat` never
/// looks *inside* a token — a string is the byte range it occupied and goes
/// back down verbatim, which is the whole of what makes beautify and compact
/// lossless. A tree is read rather than written, so here a string is
/// unescaped for display, a key is the text a row shows, and every node
/// carries the line it starts on so a click can put the caret there. Folding
/// either into the other would cost one of them the thing it exists for.
///
/// Nota's own recursive descent over the UTF-8 bytes, no `JSONSerialization`:
/// keys stay in file order, duplicate keys are both kept, and a number is the
/// characters its author wrote — `1.50` stays `1.50`, never a `Double` that
/// comes back `1.5`. The grammar is RFC 8259 and nothing beside it: no
/// comments, no trailing commas, no single quotes, no unquoted keys.
///
/// A failure is a `StructuredParseError` naming the 1-based line and a short
/// reason — "Expected `:`", "Unterminated string" — which is what the pane
/// puts on screen in place of the tree.
enum JSONTree {

    /// How deep the nesting may go before the file is called malformed. The
    /// parser recurses, and a file made of ten thousand open brackets is a
    /// crash rather than a document.
    static let depthLimit = 256

    static func parse(_ text: String) throws -> StructuredDocument {
        var walker = Walker(bytes: Array(text.utf8))
        let root = try walker.parseDocument()
        return StructuredDocument(roots: [root])
    }

    // MARK: - The walk

    /// A cursor over the source bytes, carrying the line it has reached.
    ///
    /// The line is counted in one place only — `skipWhitespace` — because
    /// that is the only place a newline can be. RFC 8259 forbids a raw
    /// control character inside a string, and no number or literal holds one,
    /// so every line break in a well-formed document is whitespace between
    /// tokens. A file that breaks that rule is refused at the same byte.
    private struct Walker {
        let bytes: [UInt8]
        var index = 0
        var line = 1

        var isAtEnd: Bool { index >= bytes.count }

        func error(_ message: String) -> StructuredParseError {
            StructuredParseError(line: line, message: message)
        }

        mutating func parseDocument() throws -> StructuredNode {
            skipWhitespace()
            guard !isAtEnd else { throw error("Empty file") }
            let value = try parseValue(key: nil, depth: 0)
            skipWhitespace()
            // One document, not a stream: anything after the top-level value
            // is a second document, and this file is not it.
            guard isAtEnd else { throw error("Extra content after the document") }
            return value
        }

        mutating func skipWhitespace() {
            while !isAtEnd {
                switch bytes[index] {
                case 0x0A:  // \n
                    line += 1
                    index += 1
                case 0x20, 0x09, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        mutating func parseValue(key: String?, depth: Int) throws -> StructuredNode {
            guard depth < JSONTree.depthLimit else { throw error("Nested too deeply") }
            guard !isAtEnd else { throw error("Unexpected end of file") }
            let start = line
            switch bytes[index] {
            case 0x7B:  // {
                return StructuredNode(
                    key: key, value: .object,
                    children: try parseObject(depth: depth), line: start
                )
            case 0x5B:  // [
                return StructuredNode(
                    key: key, value: .array,
                    children: try parseArray(depth: depth), line: start
                )
            case 0x22:  // "
                return StructuredNode(key: key, value: .string(try parseString()), line: start)
            case 0x74:  // t
                try expect("true")
                return StructuredNode(key: key, value: .bool(true), line: start)
            case 0x66:  // f
                try expect("false")
                return StructuredNode(key: key, value: .bool(false), line: start)
            case 0x6E:  // n
                try expect("null")
                return StructuredNode(key: key, value: .null, line: start)
            default:
                return StructuredNode(key: key, value: .number(try parseNumber()), line: start)
            }
        }

        mutating func parseObject(depth: Int) throws -> [StructuredNode] {
            index += 1  // {
            var members: [StructuredNode] = []
            skipWhitespace()
            if !isAtEnd, bytes[index] == 0x7D {  // }
                index += 1
                return members
            }
            while true {
                skipWhitespace()
                // The member is written down at its *key*: that is where the
                // reader's eye is, and where a click on the row goes.
                let start = line
                guard !isAtEnd, bytes[index] == 0x22 else { throw error("Expected a key") }
                let key = try parseString()
                skipWhitespace()
                guard !isAtEnd, bytes[index] == 0x3A else { throw error("Expected `:`") }  // :
                index += 1
                skipWhitespace()
                var member = try parseValue(key: key, depth: depth + 1)
                member.line = start
                members.append(member)
                skipWhitespace()
                guard !isAtEnd else { throw error("Unexpected end of file") }
                switch bytes[index] {
                case 0x2C: index += 1                      // ,
                case 0x7D: index += 1; return members      // }
                default: throw error("Expected `,` or `}`")
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> [StructuredNode] {
            index += 1  // [
            var items: [StructuredNode] = []
            skipWhitespace()
            if !isAtEnd, bytes[index] == 0x5D {  // ]
                index += 1
                return items
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(key: nil, depth: depth + 1))
                skipWhitespace()
                guard !isAtEnd else { throw error("Unexpected end of file") }
                switch bytes[index] {
                case 0x2C: index += 1                    // ,
                case 0x5D: index += 1; return items      // ]
                default: throw error("Expected `,` or `]`")
                }
            }
        }

        /// The string a row shows: unescaped, quotes off. `\n` is a newline
        /// here rather than two characters, and `😀` is the emoji
        /// its author meant — the tree is read, not written back.
        mutating func parseString() throws -> String {
            index += 1  // "
            var scalars = String.UnicodeScalarView()
            var bytesRun: [UInt8] = []

            func flushRun() {
                guard !bytesRun.isEmpty else { return }
                scalars.append(contentsOf: String(decoding: bytesRun, as: UTF8.self).unicodeScalars)
                bytesRun.removeAll(keepingCapacity: true)
            }

            while !isAtEnd {
                let byte = bytes[index]
                if byte == 0x22 {  // "
                    index += 1
                    flushRun()
                    return String(scalars)
                }
                if byte == 0x5C {  // \
                    flushRun()
                    index += 1
                    guard !isAtEnd else { throw error("Unterminated string") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: scalars.append("\"")
                    case 0x5C: scalars.append("\\")
                    case 0x2F: scalars.append("/")
                    case 0x62: scalars.append("\u{08}")
                    case 0x66: scalars.append("\u{0C}")
                    case 0x6E: scalars.append("\n")
                    case 0x72: scalars.append("\r")
                    case 0x74: scalars.append("\t")
                    case 0x75: scalars.append(try parseUnicodeEscape())
                    default: throw error("Invalid escape")
                    }
                    continue
                }
                // A raw control character is not JSON — it has to be escaped
                // — and it is also the one way a newline could reach here, so
                // refusing it is what keeps the line count honest.
                if byte < 0x20 { throw error("Control character in a string") }
                bytesRun.append(byte)
                index += 1
            }
            throw error("Unterminated string")
        }

        /// `\uXXXX`, and the surrogate pair that spells anything past the
        /// basic plane. A lone surrogate is not a character, so it comes
        /// through as the replacement rather than as a broken string.
        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let first = try parseHexQuad()
            guard first >= 0xD800, first <= 0xDBFF else {
                return Unicode.Scalar(first) ?? "\u{FFFD}"
            }
            guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                return "\u{FFFD}"
            }
            index += 2  // \u
            let second = try parseHexQuad()
            guard second >= 0xDC00, second <= 0xDFFF else { return "\u{FFFD}" }
            let value = 0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00)
            return Unicode.Scalar(value) ?? "\u{FFFD}"
        }

        mutating func parseHexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard !isAtEnd, let digit = hexValue(bytes[index]) else {
                    throw error("Invalid `\\u` escape")
                }
                value = value << 4 | UInt32(digit)
                index += 1
            }
            return value
        }

        /// As spelled. The tree shows the file, not a `Double`.
        mutating func parseNumber() throws -> String {
            let start = index
            if !isAtEnd, bytes[index] == 0x2D { index += 1 }  // -
            guard !isAtEnd, isDigit(bytes[index]) else { throw error("Expected a value") }
            if bytes[index] == 0x30 {
                index += 1  // a leading zero stands alone
            } else {
                while !isAtEnd, isDigit(bytes[index]) { index += 1 }
            }
            if !isAtEnd, bytes[index] == 0x2E {  // .
                index += 1
                guard !isAtEnd, isDigit(bytes[index]) else { throw error("Invalid number") }
                while !isAtEnd, isDigit(bytes[index]) { index += 1 }
            }
            if !isAtEnd, bytes[index] == 0x65 || bytes[index] == 0x45 {  // e E
                index += 1
                if !isAtEnd, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard !isAtEnd, isDigit(bytes[index]) else { throw error("Invalid number") }
                while !isAtEnd, isDigit(bytes[index]) { index += 1 }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func expect(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected
            else { throw error("Expected a value") }
            index += expected.count
        }

        private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        private func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x61...0x66: byte - 0x61 + 10
            case 0x41...0x46: byte - 0x41 + 10
            default: nil
            }
        }
    }
}
