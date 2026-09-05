import Foundation

/// The two shapes a `.json` file is kept in, and Nota's own walker between
/// them.
///
/// Nothing here goes through `JSONSerialization`. That would answer the
/// question by throwing the document away and building a new one: keys come
/// back in whatever order a dictionary feels like, `1.50` comes back `1.5`,
/// `é` comes back as `é`, and a file the author had spelled one way
/// arrives spelled another. The whole point of the corner button is that it
/// only ever changes the whitespace *between* the tokens — so the parse keeps
/// every token as the byte range it occupied in the source and the writer puts
/// those bytes back down verbatim. Key order, array order, number spelling and
/// every escape inside a string survive both directions, and beautifying a
/// file and compacting it again gives back exactly what was there.
///
/// Three questions, all asked of the text and nothing else:
///
/// * `reformat(_:as:)` — the pretty form (two-space indent, `"key": value`,
///   one element to a line, an empty `{}` or `[]` left on the line it is on)
///   or the compact one (no whitespace at all outside a string).
/// * `isPretty(_:)` — which way the button should point: a newline anywhere
///   outside a string literal means the file is already laid out. The file's
///   own trailing newline is not one, since every well-kept text file has it.
/// * `errorLine(in:)` — where the parse gave up, 1-based, for the tool tip on
///   the disabled button.
///
/// The grammar is RFC 8259 and nothing beside it: no comments, no trailing
/// commas, no single quotes, no unquoted keys. A file that wants those is not
/// JSON, and the button says so rather than quietly rewriting it.
enum JSONFormat {

    /// Which of the two shapes to write.
    enum Style {
        case pretty, compact
    }

    /// The parse stopped, and this is the line it stopped on — 1-based, the
    /// way an editor counts.
    struct ParseError: Error, Equatable {
        let line: Int
    }

    /// How deep the nesting may go before the document is called malformed.
    /// The writer and the parser both recurse, and a file made of ten thousand
    /// open brackets is a crash rather than a document.
    private static let depthLimit = 256

    /// The indent one level costs in the pretty form.
    private static let indentUnit = "  "

    // MARK: - The three questions

    /// The same document, laid out the other way. Throws `ParseError` if the
    /// text is not JSON.
    ///
    /// The file's trailing newline is kept if it had one: reformatting is not
    /// the moment to take the last line ending off a file.
    static func reformat(_ text: String, as style: Style) throws -> String {
        let bytes = Array(text.utf8)
        var walker = Walker(bytes: bytes)
        let value = try walker.parseDocument()
        var out = ""
        // A rough guess at the answer's size, so the string is not grown a
        // character at a time through a long document.
        out.reserveCapacity(bytes.count + bytes.count / 4)
        write(value, bytes: bytes, style: style, indent: 0, into: &out)
        if text.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Whether the text is already laid out: a newline outside a string
    /// literal, the file's own trailing newline not counted.
    ///
    /// Asked of the characters rather than of a parse, so it costs one pass
    /// and answers the same for a document the parse would refuse.
    static func isPretty(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var end = bytes.count
        while end > 0, isWhitespace(bytes[end - 1]) { end -= 1 }

        var inString = false
        var escaped = false
        for index in 0..<end {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // \
                    escaped = true
                } else if byte == 0x22 {  // "
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x0A || byte == 0x0D {
                return true
            }
        }
        return false
    }

    /// The 1-based line the parse stopped at, or `nil` when the text is JSON.
    static func errorLine(in text: String) -> Int? {
        var walker = Walker(bytes: Array(text.utf8))
        do {
            _ = try walker.parseDocument()
            return nil
        } catch let error as ParseError {
            return error.line
        } catch {
            return nil
        }
    }

    // MARK: - The document

    /// One token or one container. A scalar — a string, a number, `true`,
    /// `false` or `null` — is the range of source it came from and nothing
    /// else, which is what keeps it spelled the way its author spelled it.
    private enum Value {
        case scalar(Range<Int>)
        case array([Value])
        case object([Member])
    }

    /// One `"key": value` pair. The key keeps its quotes and its escapes: it
    /// is a source range like any other scalar.
    private struct Member {
        let key: Range<Int>
        let value: Value
    }

    // MARK: - Writing

    private static func write(
        _ value: Value, bytes: [UInt8], style: Style, indent: Int, into out: inout String
    ) {
        switch value {
        case .scalar(let range):
            out += String(decoding: bytes[range], as: UTF8.self)

        case .array(let elements):
            // An empty container is one pair of brackets, on the line it is
            // already on: a `[]` opened and closed over two lines is noise.
            guard !elements.isEmpty else { return out += "[]" }
            out += "["
            for (position, element) in elements.enumerated() {
                if position > 0 { out += "," }
                if style == .pretty { out += "\n" + pad(indent + 1) }
                write(element, bytes: bytes, style: style, indent: indent + 1, into: &out)
            }
            if style == .pretty { out += "\n" + pad(indent) }
            out += "]"

        case .object(let members):
            guard !members.isEmpty else { return out += "{}" }
            out += "{"
            for (position, member) in members.enumerated() {
                if position > 0 { out += "," }
                if style == .pretty { out += "\n" + pad(indent + 1) }
                out += String(decoding: bytes[member.key], as: UTF8.self)
                out += style == .pretty ? ": " : ":"
                write(member.value, bytes: bytes, style: style, indent: indent + 1, into: &out)
            }
            if style == .pretty { out += "\n" + pad(indent) }
            out += "}"
        }
    }

    private static func pad(_ indent: Int) -> String {
        String(repeating: indentUnit, count: indent)
    }

    // MARK: - Parsing

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// A cursor over the source bytes. Every failure is a `ParseError` naming
    /// the line the cursor had reached, so "not valid JSON: line 12" is the
    /// place the reader has to look.
    private struct Walker {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        func error() -> ParseError {
            var line = 1
            for position in 0..<min(index, bytes.count) where bytes[position] == 0x0A {
                line += 1
            }
            return ParseError(line: line)
        }

        mutating func parseDocument() throws -> Value {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            // One document, not a stream: anything after the top-level value
            // is a second document, and this file is not it.
            guard isAtEnd else { throw error() }
            return value
        }

        mutating func skipWhitespace() {
            while !isAtEnd, JSONFormat.isWhitespace(bytes[index]) { index += 1 }
        }

        mutating func parseValue(depth: Int) throws -> Value {
            guard depth < JSONFormat.depthLimit else { throw error() }
            guard !isAtEnd else { throw error() }
            switch bytes[index] {
            case 0x7B: return try parseObject(depth: depth)      // {
            case 0x5B: return try parseArray(depth: depth)       // [
            case 0x22: return .scalar(try parseString())         // "
            case 0x74: return .scalar(try parseWord("true"))
            case 0x66: return .scalar(try parseWord("false"))
            case 0x6E: return .scalar(try parseWord("null"))
            default: return .scalar(try parseNumber())
            }
        }

        mutating func parseObject(depth: Int) throws -> Value {
            index += 1  // {
            var members: [Member] = []
            skipWhitespace()
            if !isAtEnd, bytes[index] == 0x7D {  // }
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                guard !isAtEnd, bytes[index] == 0x3A else { throw error() }  // :
                index += 1
                skipWhitespace()
                members.append(Member(key: key, value: try parseValue(depth: depth + 1)))
                skipWhitespace()
                guard !isAtEnd else { throw error() }
                switch bytes[index] {
                case 0x2C: index += 1                        // ,
                case 0x7D: index += 1; return .object(members)
                default: throw error()
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> Value {
            index += 1  // [
            var elements: [Value] = []
            skipWhitespace()
            if !isAtEnd, bytes[index] == 0x5D {  // ]
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard !isAtEnd else { throw error() }
                switch bytes[index] {
                case 0x2C: index += 1                        // ,
                case 0x5D: index += 1; return .array(elements)
                default: throw error()
                }
            }
        }

        /// The whole literal including both quotes, unread: whatever is
        /// between them goes back down exactly as it came up, `\n`, `\uD83D`
        /// and all.
        mutating func parseString() throws -> Range<Int> {
            let start = index
            guard !isAtEnd, bytes[index] == 0x22 else { throw error() }
            index += 1
            while !isAtEnd {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    return start..<index
                }
                if byte == 0x5C {  // \
                    index += 1
                    guard !isAtEnd else { throw error() }
                    switch bytes[index] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        index += 1
                    case 0x75:  // u
                        index += 1
                        for _ in 0..<4 {
                            guard !isAtEnd, isHexDigit(bytes[index]) else { throw error() }
                            index += 1
                        }
                    default:
                        throw error()
                    }
                    continue
                }
                // A raw control character is not allowed in a JSON string —
                // it has to be escaped — and letting one through here would
                // mean writing a file back that no other reader accepts.
                if byte < 0x20 { throw error() }
                index += 1
            }
            throw error()
        }

        mutating func parseNumber() throws -> Range<Int> {
            let start = index
            if !isAtEnd, bytes[index] == 0x2D { index += 1 }  // -
            guard !isAtEnd, isDigit(bytes[index]) else { throw error() }
            if bytes[index] == 0x30 {
                index += 1  // a leading zero stands alone
            } else {
                while !isAtEnd, isDigit(bytes[index]) { index += 1 }
            }
            if !isAtEnd, bytes[index] == 0x2E {  // .
                index += 1
                guard !isAtEnd, isDigit(bytes[index]) else { throw error() }
                while !isAtEnd, isDigit(bytes[index]) { index += 1 }
            }
            if !isAtEnd, bytes[index] == 0x65 || bytes[index] == 0x45 {  // e E
                index += 1
                if !isAtEnd, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard !isAtEnd, isDigit(bytes[index]) else { throw error() }
                while !isAtEnd, isDigit(bytes[index]) { index += 1 }
            }
            return start..<index
        }

        mutating func parseWord(_ word: String) throws -> Range<Int> {
            let expected = Array(word.utf8)
            let start = index
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected
            else { throw error() }
            index += expected.count
            return start..<index
        }

        private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        private func isHexDigit(_ byte: UInt8) -> Bool {
            isDigit(byte) || (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x66
        }
    }
}
