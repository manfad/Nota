import Foundation

/// A `.toml` file read into a `StructuredDocument`.
///
/// Hand-written, for the reason the JSON walker beside it is hand-written: the
/// tree shows the file. A number is the characters its author typed — `1_000`
/// stays `1_000`, `0x1F` stays `0x1F`, `3.0` never comes back `3` — and a date
/// is kept as spelled too, because `1979-05-27T07:32:00Z` and
/// `1979-05-27 07:32:00Z` are the same instant and two different lines of a
/// file. Every key remembers the line it was written on.
///
/// The walk is over `[Character]`, not raw UTF-8: a `\r\n` is one Character in
/// Swift, which makes "the end of a line" a single test rather than a pair of
/// them, and TOML asks that question constantly — a value ends at the end of
/// its line, a basic string may not cross one.
///
/// TOML 1.0, and the whole of it that a configuration file uses: bare, quoted
/// and dotted keys; `[table]`, `[a.b.c]` with the super-tables it implies, and
/// `[[array of tables]]`; inline tables and arrays, the arrays across as many
/// lines, trailing commas and comments as they like; the four string forms;
/// integers in four bases, floats, `inf` and `nan`, booleans; and the four
/// date and time shapes, offset, local, date-only and time-only.
///
/// The shape of the answer is the thing worth naming. A `[a.b.c]` header does
/// not make one node, it makes three, and the two above `c` are `.object`s
/// nobody wrote — conjured where they were first mentioned, keeping that
/// line, so the tree reads down the way the file reads down rather than in
/// whatever order the headers happened to arrive. A `[[x]]` is an `.array`
/// whose line is the first header's and whose items each keep their own.
///
/// What it refuses, it refuses with the line: a key written twice, a table
/// opened twice, a header that would tunnel through a value, a dotted key
/// reaching into an inline table (which is closed the moment its `}` is
/// typed), a bad escape, a string left open, a missing `=`, a number or date
/// that is neither, and anything at all after a value on its line.
enum TOMLTree {

    static func parse(_ text: String) throws -> StructuredDocument {
        var walker = Walker(characters: Array(text))
        return StructuredDocument(roots: [try walker.parseDocument()])
    }

    // MARK: - The tree under construction

    /// A node while the file is still being read. A reference type on purpose:
    /// a `[a.b.c]` header reaches back into a table three levels up and adds to
    /// it, and threading that through value types would be a lot of ceremony
    /// for no gain. The three flags are the whole of TOML's rule about what
    /// may still be added to what.
    private final class Node {
        enum Kind {
            case table
            case arrayOfTables
            case array
            case leaf(StructuredNode.Value)
        }

        var kind: Kind
        var line: Int
        var children: [(key: String?, node: Node)] = []
        /// Written out — `[table]`, `[[table]]`, `{ }` — rather than conjured
        /// as a super-table on the way to one. An explicit table may not be
        /// opened a second time.
        var explicit = false
        /// Written as `{ }`, and so closed: a later dotted key may not reach
        /// inside it.
        var inline = false
        /// Conjured by a dotted key, which closes it to `[table]` as well.
        var dotted = false

        init(kind: Kind, line: Int) {
            self.kind = kind
            self.line = line
        }

        func child(_ key: String) -> Node? {
            children.first { $0.key == key }?.node
        }
    }

    // MARK: - The walk

    private struct Walker {
        let characters: [Character]
        var index = 0
        var line = 1
        let root: Node
        /// Where a key/value pair goes: the root, or the table the last header
        /// opened.
        var current: Node

        init(characters: [Character]) {
            self.characters = characters
            let root = Node(kind: .table, line: 1)
            root.explicit = true
            self.root = root
            self.current = root
        }

        func error(_ message: String, line: Int? = nil) -> StructuredParseError {
            StructuredParseError(line: line ?? self.line, message: message)
        }

        // MARK: Cursor

        var atEnd: Bool { index >= characters.count }
        var peek: Character? { index < characters.count ? characters[index] : nil }

        mutating func advance() {
            guard index < characters.count else { return }
            if characters[index].isNewline { line += 1 }
            index += 1
        }

        mutating func skipSpace() {
            while let ch = peek, ch == " " || ch == "\t" { advance() }
        }

        mutating func skipComment() {
            guard peek == "#" else { return }
            while let ch = peek, !ch.isNewline { advance() }
        }

        /// Whitespace, line breaks and comments: everything between two things
        /// the grammar cares about.
        mutating func skipBlank() {
            while let ch = peek {
                if ch == "#" {
                    skipComment()
                } else if ch.isWhitespace {
                    advance()
                } else {
                    return
                }
            }
        }

        /// The rest of the line, once a value or a header has been read.
        mutating func endOfLine() throws {
            skipSpace()
            skipComment()
            guard let ch = peek else { return }
            guard ch.isNewline else { throw error("Unexpected text after a value") }
            advance()
        }

        // MARK: The document

        mutating func parseDocument() throws -> StructuredNode {
            while true {
                skipBlank()
                if atEnd { break }
                if peek == "[" {
                    try parseHeader()
                } else {
                    try parseKeyValue(into: current)
                }
                try endOfLine()
            }
            return TOMLTree.convert(root, key: nil)
        }

        // MARK: Headers

        mutating func parseHeader() throws {
            let headerLine = line
            advance()  // [
            var arrayOfTables = false
            if peek == "[" {
                arrayOfTables = true
                advance()
            }
            let path = try parseKeyPath()
            skipSpace()
            guard peek == "]" else { throw error("Expected `]`") }
            advance()
            if arrayOfTables {
                guard peek == "]" else { throw error("Expected `]]`") }
                advance()
            }
            current = try open(path: path, arrayOfTables: arrayOfTables, line: headerLine)
        }

        /// The table a header names, made if it is not there yet — and, on the
        /// way, every super-table it implies, each remembering the line it was
        /// first mentioned on.
        mutating func open(
            path: [String], arrayOfTables: Bool, line headerLine: Int
        ) throws -> Node {
            var node = root
            for segment in path.dropLast() {
                node = try descend(node, segment, line: headerLine, viaDottedKey: false)
            }
            guard let last = path.last else { throw error("Expected a key", line: headerLine) }
            let name = path.joined(separator: ".")

            if arrayOfTables {
                let item = Node(kind: .table, line: headerLine)
                item.explicit = true
                if let existing = node.child(last) {
                    guard case .arrayOfTables = existing.kind else {
                        throw error("`\(name)` is not an array of tables", line: headerLine)
                    }
                    existing.children.append((nil, item))
                    return item
                }
                let array = Node(kind: .arrayOfTables, line: headerLine)
                array.explicit = true
                array.children.append((nil, item))
                node.children.append((last, array))
                return item
            }

            if let existing = node.child(last) {
                guard case .table = existing.kind else {
                    throw error("`\(name)` is not a table", line: headerLine)
                }
                guard !existing.explicit, !existing.inline, !existing.dotted else {
                    throw error("Table `\(name)` is defined twice", line: headerLine)
                }
                existing.explicit = true
                return existing
            }
            let table = Node(kind: .table, line: headerLine)
            table.explicit = true
            node.children.append((last, table))
            return table
        }

        /// One step of a dotted path. A super-table nobody wrote is made here,
        /// at the line it was first mentioned; `[[x]]` is stepped into at its
        /// last item, which is what makes `[[x]]` … `[x.y]` work.
        mutating func descend(
            _ parent: Node, _ segment: String, line: Int, viaDottedKey: Bool
        ) throws -> Node {
            if let existing = parent.child(segment) {
                switch existing.kind {
                case .table:
                    if existing.inline {
                        throw error("Inline table `\(segment)` is closed", line: line)
                    }
                    return existing
                case .arrayOfTables:
                    guard !viaDottedKey, let last = existing.children.last?.node else {
                        throw error("`\(segment)` is not a table", line: line)
                    }
                    return last
                default:
                    throw error("`\(segment)` is not a table", line: line)
                }
            }
            let table = Node(kind: .table, line: line)
            table.dotted = viaDottedKey
            parent.children.append((segment, table))
            return table
        }

        // MARK: Keys

        mutating func parseKeyPath() throws -> [String] {
            var path: [String] = []
            while true {
                skipSpace()
                path.append(try parseKeySegment())
                skipSpace()
                if peek == "." {
                    advance()
                    continue
                }
                return path
            }
        }

        mutating func parseKeySegment() throws -> String {
            switch peek {
            case "\"": return try parseBasicString()
            case "'": return try parseLiteralString()
            default:
                var out = ""
                while let ch = peek,
                    ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
                {
                    out.append(ch)
                    advance()
                }
                guard !out.isEmpty else { throw error("Expected a key") }
                return out
            }
        }

        mutating func parseKeyValue(into table: Node) throws {
            let keyLine = line
            let path = try parseKeyPath()
            skipSpace()
            guard peek == "=" else { throw error("Expected `=`", line: keyLine) }
            advance()
            skipSpace()

            var target = table
            for segment in path.dropLast() {
                target = try descend(target, segment, line: keyLine, viaDottedKey: true)
            }
            guard let last = path.last else { throw error("Expected a key", line: keyLine) }
            guard target.child(last) == nil else {
                throw error("Duplicate key `\(last)`", line: keyLine)
            }
            let value = try parseValue()
            // A pair is written down at its key: that is where the reader's
            // eye is, and where a click on the row goes.
            value.line = keyLine
            target.children.append((last, value))
        }

        // MARK: Values

        mutating func parseValue() throws -> Node {
            let valueLine = line
            guard let ch = peek else { throw error("Expected a value") }
            switch ch {
            case "\"":
                return Node(kind: .leaf(.string(try parseBasicString())), line: valueLine)
            case "'":
                return Node(kind: .leaf(.string(try parseLiteralString())), line: valueLine)
            case "[":
                return try parseArray()
            case "{":
                return try parseInlineTable()
            default:
                let token = readBareValue()
                if token == "true" { return Node(kind: .leaf(.bool(true)), line: valueLine) }
                if token == "false" { return Node(kind: .leaf(.bool(false)), line: valueLine) }
                guard let value = TOMLTree.classify(token) else {
                    throw error("Bad value `\(token)`", line: valueLine)
                }
                return Node(kind: .leaf(value), line: valueLine)
            }
        }

        /// The run of characters a bare value is spelled with. The one place
        /// it may hold a space is between a date and the time after it, which
        /// TOML allows in place of the `T`.
        mutating func readBareValue() -> String {
            var out = run()
            if out.count == 10, TOMLTree.isLocalDate(Substring(out)), peek == " ",
                index + 3 < characters.count,
                characters[index + 1].isNumber, characters[index + 2].isNumber,
                characters[index + 3] == ":"
            {
                advance()
                out += " " + run()
            }
            return out

            func run() -> String {
                var piece = ""
                while let ch = peek, !ch.isNewline, ch != " ", ch != "\t", ch != ",", ch != "]",
                    ch != "}", ch != "#"
                {
                    piece.append(ch)
                    advance()
                }
                return piece
            }
        }

        mutating func parseArray() throws -> Node {
            let openLine = line
            advance()  // [
            let array = Node(kind: .array, line: openLine)
            while true {
                skipBlank()
                guard let ch = peek else { throw error("Array left open", line: openLine) }
                if ch == "]" {
                    advance()
                    return array
                }
                array.children.append((nil, try parseValue()))
                skipBlank()
                guard let separator = peek else {
                    throw error("Array left open", line: openLine)
                }
                if separator == "," {
                    advance()
                    continue
                }
                if separator == "]" {
                    advance()
                    return array
                }
                throw error("Expected `,` or `]`")
            }
        }

        mutating func parseInlineTable() throws -> Node {
            let openLine = line
            advance()  // {
            let table = Node(kind: .table, line: openLine)
            table.explicit = true
            table.inline = true
            skipBlank()
            if peek == "}" {
                advance()
                return table
            }
            while true {
                skipBlank()
                try parseKeyValue(into: table)
                skipBlank()
                guard let separator = peek else {
                    throw error("Inline table left open", line: openLine)
                }
                if separator == "," {
                    advance()
                    continue
                }
                if separator == "}" {
                    advance()
                    return table
                }
                throw error("Expected `,` or `}`")
            }
        }

        // MARK: Strings

        /// `"…"`, or `"""…"""` when three quotes open it.
        mutating func parseBasicString() throws -> String {
            let openLine = line
            var quotes = 0
            while peek == "\"", quotes < 3 {
                advance()
                quotes += 1
            }
            if quotes == 2 { return "" }
            if quotes == 1 {
                var out = ""
                while true {
                    guard let ch = peek, !ch.isNewline else {
                        throw error("Unterminated string", line: openLine)
                    }
                    if ch == "\"" {
                        advance()
                        return out
                    }
                    if ch == "\\" {
                        advance()
                        out += try readEscape()
                        continue
                    }
                    out.append(ch)
                    advance()
                }
            }
            // A newline straight after `"""` is the delimiter's, not the
            // string's.
            if peek?.isNewline == true { advance() }
            var out = ""
            while true {
                guard let ch = peek else { throw error("Unterminated string", line: openLine) }
                if ch == "\"" {
                    var seen = 0
                    while peek == "\"" {
                        advance()
                        seen += 1
                    }
                    if seen >= 3 {
                        return out + String(repeating: "\"", count: seen - 3)
                    }
                    out += String(repeating: "\"", count: seen)
                    continue
                }
                if ch == "\\" {
                    if try skipLineEndingBackslash() { continue }
                    advance()
                    out += try readEscape()
                    continue
                }
                out.append(ch)
                advance()
            }
        }

        /// A `\` with nothing but whitespace after it on its line swallows the
        /// break and the indentation of the next line.
        mutating func skipLineEndingBackslash() throws -> Bool {
            var scan = index + 1
            while scan < characters.count, characters[scan] == " " || characters[scan] == "\t" {
                scan += 1
            }
            guard scan < characters.count, characters[scan].isNewline else { return false }
            advance()  // the backslash
            while let ch = peek, ch.isWhitespace { advance() }
            return true
        }

        mutating func readEscape() throws -> String {
            guard let ch = peek else { throw error("Unterminated string") }
            advance()
            switch ch {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "u": return try readHex(digits: 4)
            case "U": return try readHex(digits: 8)
            default: throw error("Invalid escape `\\\(ch)`")
            }
        }

        mutating func readHex(digits: Int) throws -> String {
            var value: UInt32 = 0
            for _ in 0..<digits {
                guard let ch = peek, let digit = ch.hexDigitValue else {
                    throw error("Invalid escape")
                }
                value = value * 16 + UInt32(digit)
                advance()
            }
            guard let scalar = Unicode.Scalar(value) else { throw error("Invalid escape") }
            return String(Character(scalar))
        }

        /// `'…'`, or `'''…'''`. Nothing inside is an escape: that is the point
        /// of them, and why a Windows path lives in one.
        mutating func parseLiteralString() throws -> String {
            let openLine = line
            var quotes = 0
            while peek == "'", quotes < 3 {
                advance()
                quotes += 1
            }
            if quotes == 2 { return "" }
            if quotes == 1 {
                var out = ""
                while true {
                    guard let ch = peek, !ch.isNewline else {
                        throw error("Unterminated string", line: openLine)
                    }
                    if ch == "'" {
                        advance()
                        return out
                    }
                    out.append(ch)
                    advance()
                }
            }
            if peek?.isNewline == true { advance() }
            var out = ""
            while true {
                guard let ch = peek else { throw error("Unterminated string", line: openLine) }
                if ch == "'" {
                    var seen = 0
                    while peek == "'" {
                        advance()
                        seen += 1
                    }
                    if seen >= 3 {
                        return out + String(repeating: "'", count: seen - 3)
                    }
                    out += String(repeating: "'", count: seen)
                    continue
                }
                out.append(ch)
                advance()
            }
        }
    }

    // MARK: - Finishing the tree

    private static func convert(_ node: Node, key: String?) -> StructuredNode {
        switch node.kind {
        case .table:
            return StructuredNode(
                key: key, value: .object,
                children: node.children.map { convert($0.node, key: $0.key) }, line: node.line)
        case .arrayOfTables, .array:
            return StructuredNode(
                key: key, value: .array,
                children: node.children.map { convert($0.node, key: nil) }, line: node.line)
        case .leaf(let value):
            return StructuredNode(key: key, value: value, line: node.line)
        }
    }

    // MARK: - What a bare token is

    /// A number, a date or a time — kept exactly as spelled, because that is
    /// what the file says and the tree is a view of the file. `nil` for
    /// anything that is none of the three, which is how a typo becomes a line
    /// number rather than a mystery.
    private static func classify(_ token: String) -> StructuredNode.Value? {
        if token.isEmpty { return nil }
        if isDateOrTime(token) { return .date(token) }
        if isNumber(token) { return .number(token) }
        return nil
    }

    /// Digits with `_` between them: never leading, never trailing, never two
    /// in a row.
    private static func isDigitRun(_ body: Substring, allowed: (Character) -> Bool) -> Bool {
        guard !body.isEmpty, body.first != "_", body.last != "_" else { return false }
        var previousWasUnderscore = false
        for ch in body {
            if ch == "_" {
                if previousWasUnderscore { return false }
                previousWasUnderscore = true
                continue
            }
            guard allowed(ch) else { return false }
            previousWasUnderscore = false
        }
        return true
    }

    private static func isDecimalRun(_ body: Substring) -> Bool {
        isDigitRun(body) { $0.isASCII && $0.isNumber }
    }

    static func isNumber(_ token: String) -> Bool {
        var body = Substring(token)
        var signed = false
        if body.first == "+" || body.first == "-" {
            body = body.dropFirst()
            signed = true
        }
        guard !body.isEmpty else { return false }
        if body == "inf" || body == "nan" { return true }

        if !signed, body.count > 2, body.first == "0" {
            let marker = body[body.index(after: body.startIndex)]
            let digits = body.dropFirst(2)
            switch marker {
            case "x": return isDigitRun(digits) { $0.isHexDigit && $0.isASCII }
            case "o": return isDigitRun(digits) { ("0"..."7").contains($0) }
            case "b": return isDigitRun(digits) { $0 == "0" || $0 == "1" }
            default: break
            }
        }

        // A float is an integer, then a fraction, an exponent, or both.
        var mantissa = body
        var exponent: Substring?
        if let e = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = body[..<e]
            var tail = body[body.index(after: e)...]
            if tail.first == "+" || tail.first == "-" { tail = tail.dropFirst() }
            exponent = tail
        }
        if let exponent, !isDecimalRun(exponent) { return false }

        if let dot = mantissa.firstIndex(of: ".") {
            let whole = mantissa[..<dot]
            let fraction = mantissa[mantissa.index(after: dot)...]
            return isDecimalRun(whole) && isDecimalRun(fraction)
        }
        return isDecimalRun(mantissa)
    }

    /// `YYYY-MM-DD`, and nothing that merely looks like it.
    static func isLocalDate(_ body: Substring) -> Bool {
        guard body.count == 10 else { return false }
        let parts = body.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// `HH:MM:SS`, with as many fractional digits as the author liked, or the
    /// `HH:MM` that TOML also allows.
    private static func isLocalTime(_ body: Substring) -> Bool {
        var rest = body
        if let dot = rest.firstIndex(of: ".") {
            let fraction = rest[rest.index(after: dot)...]
            guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber })
            else { return false }
            rest = rest[..<dot]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private static func isOffset(_ body: Substring) -> Bool {
        guard body.count == 6, body.first == "+" || body.first == "-" else { return false }
        return isLocalTime(body.dropFirst())
    }

    private static func isDateOrTime(_ token: String) -> Bool {
        let whole = Substring(token)
        if isLocalDate(whole) { return true }
        if isLocalTime(whole) { return true }
        guard whole.count > 11 else { return false }
        let date = whole.prefix(10)
        let separator = whole[whole.index(whole.startIndex, offsetBy: 10)]
        guard isLocalDate(date), separator == "T" || separator == "t" || separator == " "
        else { return false }

        var time = whole.dropFirst(11)
        if time.last == "Z" || time.last == "z" {
            time = time.dropLast()
        } else if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }),
            time.distance(from: time.startIndex, to: sign) >= 5
        {
            guard isOffset(time[sign...]) else { return false }
            time = time[..<sign]
        }
        return isLocalTime(time)
    }
}
