import Foundation

/// A `.yaml` file read into a `StructuredDocument`.
///
/// Hand-written, like the JSON walker beside it and for the same reason: the
/// tree view shows the *file*, so `1.50` has to come back `1.50`, `0x1F` has
/// to come back `0x1F`, and every member has to keep the line it was written
/// on. Nothing here builds a `Foundation` object and reads it back.
///
/// The one difference from the JSON walker is what it walks. That one steps
/// over raw UTF-8 because it hands back byte ranges; this one steps over
/// `[Character]` lines, because YAML's punctuation *is* the indentation and a
/// column is counted in characters. So the source is cut into lines once, and
/// the parser is a pair of coordinates into them: `i`, the line, and `col`,
/// the column. A node begins wherever those two point, which is what makes
/// the compact forms — `- - a`, `- key: v` — fall out for free: the nested
/// node's indentation is simply the column the cursor already stands at.
///
/// The subset is the part real configuration files use:
///
/// * block mappings and block sequences, including a sequence written at the
///   same indentation as the key that owns it;
/// * flow collections `{a: 1, b: [x, y]}`, across lines, empty ones included;
/// * all five scalar styles — plain (a multi-line plain folds to one line),
///   single-quoted, double-quoted, and the `|` and `>` block scalars with
///   `+`/`-` chomping and an explicit indentation digit;
/// * `#` comments, `---` documents and the `...` that ends one, and a leading
///   `%YAML` directive;
/// * anchors, aliases and `<<` merge keys; tags stripped, except that
///   `!!str`, `!!int`, `!!float`, `!!bool` and `!!null` overrule the schema;
/// * the YAML 1.2 core schema for what a plain scalar *is* — `null`/`~`/empty,
///   the six spellings of the booleans, decimal, `0x` and `0o` integers,
///   floats with an exponent, `.inf`, `-.inf`, `.nan` — and a string for
///   everything else, and for anything quoted.
///
/// What it does not do it refuses, with the line: a complex `? ` key, a tab in
/// indentation, a dedent that lands between two levels, a mapping key where a
/// sequence item belongs and the other way round, an alias with no anchor, a
/// flow collection left open, a quote never closed. Silence would be worse
/// than a message — a tree that quietly disagrees with the file is the one
/// thing the view must never show.
enum YAMLTree {

    static func parse(_ text: String) throws -> StructuredDocument {
        var lines: [Line] = []
        var number = 1
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var characters = Array(raw)
            if characters.last == "\r" { characters.removeLast() }
            lines.append(Line(number: number, text: characters))
            number += 1
        }
        var parser = Parser(lines: lines)
        return StructuredDocument(roots: try parser.parseStream())
    }

    /// One physical line of the source, with the number the editor shows.
    private struct Line {
        let number: Int
        let text: [Character]
    }

    /// A member of a mapping, or the `<<` that pulls another mapping's members
    /// in. Merges are held until the whole mapping is read, because a merged
    /// key loses to one the mapping spells out — wherever it spells it out.
    private enum MappingItem {
        case entry(StructuredNode)
        case merge([StructuredNode])
    }

    // MARK: - The parser

    private struct Parser {
        let lines: [Line]
        /// The line the cursor is on.
        var i = 0
        /// The column within that line. At the start of a node it is that
        /// node's indentation, which is the only thing block YAML asks about.
        var col = 0
        var anchors: [String: StructuredNode] = [:]

        var atEnd: Bool { i >= lines.count }
        var text: [Character] { lines[i].text }
        var lineNumber: Int { i < lines.count ? lines[i].number : (lines.last?.number ?? 1) }

        func error(_ message: String, line: Int? = nil) -> StructuredParseError {
            StructuredParseError(line: line ?? lineNumber, message: message)
        }

        // MARK: Cursor

        /// The column of a line's first content character, or `nil` when the
        /// line is blank or nothing but a comment. A tab in the indentation of
        /// a line that has content is the error YAML says it is: the file
        /// looks aligned in one editor and is not in another.
        func indent(of index: Int) throws -> Int? {
            let t = lines[index].text
            var c = 0
            while c < t.count, t[c] == " " || t[c] == "\t" {
                if t[c] == "\t" {
                    var d = c
                    while d < t.count, t[d] == " " || t[d] == "\t" { d += 1 }
                    if d < t.count, t[d] != "#" {
                        throw StructuredParseError(
                            line: lines[index].number, message: "Tab in indentation")
                    }
                    return nil
                }
                c += 1
            }
            if c >= t.count || t[c] == "#" { return nil }
            return c
        }

        /// Move to the next line that has something on it, and put `col` at
        /// its first content character.
        mutating func seekContent() throws {
            while i < lines.count {
                if let found = try indent(of: i) {
                    col = found
                    return
                }
                i += 1
            }
            col = 0
        }

        mutating func skipSpacesOnLine() {
            guard i < lines.count else { return }
            let t = text
            while col < t.count, t[col] == " " || t[col] == "\t" { col += 1 }
        }

        /// Nothing left on this line but whitespace and, perhaps, a comment.
        var atLineEnd: Bool {
            guard i < lines.count else { return true }
            let t = text
            return col >= t.count || t[col] == "#"
        }

        /// `---` or `...`, which mean anything only in column zero.
        func isMarkerHere(_ mark: Character) -> Bool {
            guard i < lines.count, col == 0 else { return false }
            let t = text
            guard t.count >= 3, t[0] == mark, t[1] == mark, t[2] == mark else { return false }
            return t.count == 3 || t[3] == " " || t[3] == "\t"
        }

        var atDocumentBoundary: Bool { isMarkerHere("-") || isMarkerHere(".") }

        func isSequenceEntryHere() -> Bool {
            guard i < lines.count else { return false }
            let t = text
            guard col < t.count, t[col] == "-" else { return false }
            return col + 1 >= t.count || t[col + 1] == " " || t[col + 1] == "\t"
        }

        /// The rest of the line, once a value has been read: whitespace, or a
        /// comment, and nothing else.
        mutating func finishLine() throws {
            if i < lines.count {
                skipSpacesOnLine()
                if !atLineEnd { throw error("Unexpected text after a value") }
                i += 1
            }
            try seekContent()
        }

        // MARK: The stream

        mutating func parseStream() throws -> [StructuredNode] {
            var roots: [StructuredNode] = []
            try seekContent()
            while !atEnd {
                // A `%YAML` or `%TAG` directive says how to read the file, not
                // what is in it.
                if col == 0, text.first == "%" {
                    i += 1
                    try seekContent()
                    continue
                }
                if isMarkerHere(".") {
                    i += 1
                    try seekContent()
                    continue
                }
                var startLine = lineNumber
                if isMarkerHere("-") {
                    // Each document is its own world: an anchor does not reach
                    // across a `---`.
                    anchors.removeAll()
                    startLine = lineNumber
                    col = 3
                    skipSpacesOnLine()
                    if atLineEnd {
                        i += 1
                        try seekContent()
                        if atEnd || atDocumentBoundary {
                            roots.append(StructuredNode(value: .null, line: startLine))
                            continue
                        }
                        startLine = lineNumber
                    }
                }
                roots.append(
                    try parseNode(ownerIndent: -1, entryLine: startLine, seqAtOwnerIndent: false))
                if !atEnd, !atDocumentBoundary { throw error("Bad indentation") }
            }
            if roots.isEmpty { roots.append(StructuredNode(value: .null, line: 1)) }
            return roots
        }

        // MARK: Nodes

        /// The node that begins where the cursor stands. `ownerIndent` is the
        /// indentation of the `key:` or the `-` this value belongs to — the
        /// column a block written *beneath* has to beat.
        mutating func parseNode(
            ownerIndent: Int, entryLine: Int, seqAtOwnerIndent: Bool
        ) throws -> StructuredNode {
            if isSequenceEntryHere() { return try parseSequence(indent: col) }
            if try findKey(from: col) != nil { return try parseMapping(indent: col) }
            return try parseInline(
                ownerIndent: ownerIndent, entryLine: entryLine,
                seqAtOwnerIndent: seqAtOwnerIndent)
        }

        /// The value written on the lines *below* an entry, indented past it —
        /// or, for a mapping key, a sequence written at the key's own column.
        mutating func parseBlockBeneath(
            ownerIndent: Int, entryLine: Int, seqAtOwnerIndent: Bool
        ) throws -> StructuredNode {
            i += 1
            try seekContent()
            if atEnd || atDocumentBoundary { return StructuredNode(value: .null, line: entryLine) }
            if col > ownerIndent {
                return try parseNode(
                    ownerIndent: col, entryLine: lineNumber, seqAtOwnerIndent: false)
            }
            if seqAtOwnerIndent, col == ownerIndent, isSequenceEntryHere() {
                return try parseSequence(indent: ownerIndent)
            }
            return StructuredNode(value: .null, line: entryLine)
        }

        mutating func parseMapping(indent: Int) throws -> StructuredNode {
            let startLine = lineNumber
            var items: [MappingItem] = []
            while true {
                if atEnd || atDocumentBoundary { break }
                if col < indent { break }
                if col > indent { throw error("Bad indentation") }
                if isSequenceEntryHere() { throw error("Expected a mapping key") }
                guard let (key, colonAt) = try findKey(from: col) else {
                    throw error("Expected a mapping key")
                }
                let keyLine = lineNumber
                col = colonAt + 1
                skipSpacesOnLine()
                var value: StructuredNode
                if atLineEnd {
                    value = try parseBlockBeneath(
                        ownerIndent: indent, entryLine: keyLine, seqAtOwnerIndent: true)
                } else {
                    value = try parseNode(
                        ownerIndent: indent, entryLine: keyLine, seqAtOwnerIndent: true)
                }
                if key == "<<" {
                    items.append(.merge(try mergeSources(value, line: keyLine)))
                } else {
                    value.key = key
                    value.line = keyLine
                    items.append(.entry(value))
                }
            }
            return StructuredNode(value: .object, children: resolve(items), line: startLine)
        }

        /// A merged key loses to one the mapping writes out, and the first
        /// merge source wins over a later one.
        func resolve(_ items: [MappingItem]) -> [StructuredNode] {
            var spelledOut: Set<String> = []
            for case .entry(let node) in items {
                if let key = node.key { spelledOut.insert(key) }
            }
            var merged: Set<String> = []
            var members: [StructuredNode] = []
            for item in items {
                switch item {
                case .entry(let node):
                    members.append(node)
                case .merge(let sources):
                    for source in sources {
                        for member in source.children {
                            guard let key = member.key else { continue }
                            if spelledOut.contains(key) || merged.contains(key) { continue }
                            merged.insert(key)
                            members.append(member)
                        }
                    }
                }
            }
            return members
        }

        func mergeSources(_ node: StructuredNode, line: Int) throws -> [StructuredNode] {
            switch node.value {
            case .object:
                return [node]
            case .array:
                for child in node.children where child.value != .object {
                    throw error("Merge key must be a mapping", line: line)
                }
                return node.children
            default:
                throw error("Merge key must be a mapping", line: line)
            }
        }

        mutating func parseSequence(indent: Int) throws -> StructuredNode {
            let startLine = lineNumber
            var items: [StructuredNode] = []
            while true {
                if atEnd || atDocumentBoundary { break }
                if col < indent { break }
                if col > indent { throw error("Bad indentation") }
                guard isSequenceEntryHere() else { throw error("Expected a sequence item") }
                let itemLine = lineNumber
                col += 1
                skipSpacesOnLine()
                var item: StructuredNode
                if atLineEnd {
                    item = try parseBlockBeneath(
                        ownerIndent: indent, entryLine: itemLine, seqAtOwnerIndent: false)
                } else {
                    item = try parseNode(
                        ownerIndent: indent, entryLine: itemLine, seqAtOwnerIndent: false)
                }
                item.key = nil
                item.line = itemLine
                items.append(item)
            }
            return StructuredNode(value: .array, children: items, line: startLine)
        }

        // MARK: Keys

        /// Does the line, from `start`, begin `key:`? Returns the key and the
        /// column of its colon. A colon ends a key only when a space or the
        /// end of the line follows it, which is why `url: http://x` is one key
        /// and one value rather than three.
        mutating func findKey(from start: Int) throws -> (String, Int)? {
            guard i < lines.count else { return nil }
            let t = text
            guard start < t.count else { return nil }
            if t[start] == "?", start + 1 >= t.count || t[start + 1] == " " {
                throw error("Complex keys are not supported")
            }
            if "{[*&!|>".contains(t[start]) { return nil }

            if t[start] == "\"" || t[start] == "'" {
                let savedLine = i
                let savedColumn = col
                col = start
                let key: String
                do {
                    key = t[start] == "\"" ? try readDoubleQuoted() : try readSingleQuoted()
                } catch {
                    i = savedLine
                    col = savedColumn
                    throw error
                }
                // An implicit key has to fit on its line; a quoted scalar that
                // ran on to the next one is a value, not a key.
                let ranOn = i != savedLine
                var c = col
                let after = i < lines.count ? lines[i].text : []
                i = savedLine
                col = savedColumn
                guard !ranOn else { return nil }
                while c < after.count, after[c] == " " { c += 1 }
                guard c < after.count, after[c] == ":",
                    c + 1 >= after.count || after[c + 1] == " " || after[c + 1] == "\t"
                else { return nil }
                return (key, c)
            }

            var c = start
            while c < t.count {
                if t[c] == ":", c + 1 >= t.count || t[c + 1] == " " || t[c + 1] == "\t" {
                    var end = c
                    while end > start, t[end - 1] == " " || t[end - 1] == "\t" { end -= 1 }
                    return (String(t[start..<end]), c)
                }
                if t[c] == "#", c > start, t[c - 1] == " " || t[c - 1] == "\t" { return nil }
                c += 1
            }
            return nil
        }

        // MARK: Scalars, and the rest of a line

        /// A value written on the rest of the line: properties, then an alias,
        /// a flow collection, a block scalar, or a plain or quoted scalar.
        mutating func parseInline(
            ownerIndent: Int, entryLine: Int, seqAtOwnerIndent: Bool
        ) throws -> StructuredNode {
            var anchor: String?
            var tag: String?
            while !atLineEnd, text[col] == "&" || text[col] == "!" {
                let marker = text[col]
                col += 1
                let start = col
                let t = text
                while col < t.count, t[col] != " ", t[col] != "\t" { col += 1 }
                let name = String(t[start..<col])
                if marker == "&" {
                    guard !name.isEmpty else { throw error("Empty anchor name") }
                    anchor = name
                } else {
                    tag = name
                }
                skipSpacesOnLine()
            }

            var node: StructuredNode
            if atLineEnd {
                node = try parseBlockBeneath(
                    ownerIndent: ownerIndent, entryLine: entryLine,
                    seqAtOwnerIndent: seqAtOwnerIndent)
            } else if text[col] == "*" {
                let aliasLine = lineNumber
                col += 1
                let t = text
                let start = col
                while col < t.count, !" \t,[]{}".contains(t[col]) { col += 1 }
                let name = String(t[start..<col])
                guard var target = anchors[name] else { throw error("Unknown alias `\(name)`") }
                target.key = nil
                target.line = aliasLine
                node = target
                try finishLine()
            } else if text[col] == "{" || text[col] == "[" {
                node = try parseFlowValue(openLine: lineNumber, depth: 0)
                try finishLine()
            } else if text[col] == "|" || text[col] == ">" {
                node = try parseBlockScalar(ownerIndent: ownerIndent)
            } else {
                let line = lineNumber
                var quoted = true
                let raw: String
                if text[col] == "\"" {
                    raw = try readDoubleQuoted()
                    try finishLine()
                } else if text[col] == "'" {
                    raw = try readSingleQuoted()
                    try finishLine()
                } else {
                    quoted = false
                    raw = try readPlain(ownerIndent: ownerIndent)
                }
                node = StructuredNode(value: scalarValue(raw, quoted: quoted, tag: tag), line: line)
            }
            if let anchor { anchors[anchor] = node }
            return node
        }

        /// A plain scalar, folded: the lines that follow it, indented past the
        /// entry that owns it and starting no entry of their own, are the same
        /// scalar and join with a space.
        mutating func readPlain(ownerIndent: Int) throws -> String {
            var out = plainRun()
            i += 1
            while i < lines.count {
                guard let next = try indent(of: i) else { break }
                if next <= ownerIndent { break }
                col = next
                if atDocumentBoundary || isSequenceEntryHere() { break }
                if try findKey(from: col) != nil { break }
                let piece = plainRun()
                if !piece.isEmpty { out += " " + piece }
                i += 1
            }
            try seekContent()
            return out
        }

        /// The plain text on this line from `col`: everything up to a ` #`
        /// comment, with trailing spaces dropped.
        func plainRun() -> String {
            let t = text
            var c = col
            var end = col
            while c < t.count {
                if t[c] == "#", c > col, t[c - 1] == " " || t[c - 1] == "\t" { break }
                c += 1
                if t[c - 1] != " ", t[c - 1] != "\t" { end = c }
            }
            return String(t[col..<end])
        }

        mutating func readSingleQuoted() throws -> String {
            let openLine = lineNumber
            col += 1
            var out = ""
            var pendingFold = false
            while true {
                if col >= text.count {
                    i += 1
                    guard i < lines.count else { throw error("Unterminated quote", line: openLine) }
                    col = 0
                    skipSpacesOnLine()
                    pendingFold = true
                    continue
                }
                let t = text
                if t[col] == "'" {
                    if col + 1 < t.count, t[col + 1] == "'" {
                        if pendingFold { out += " " ; pendingFold = false }
                        out += "'"
                        col += 2
                        continue
                    }
                    col += 1
                    return out
                }
                if pendingFold { out += " " ; pendingFold = false }
                out.append(t[col])
                col += 1
            }
        }

        mutating func readDoubleQuoted() throws -> String {
            let openLine = lineNumber
            col += 1
            var out = ""
            var pendingFold = false
            while true {
                if col >= text.count {
                    i += 1
                    guard i < lines.count else { throw error("Unterminated quote", line: openLine) }
                    col = 0
                    skipSpacesOnLine()
                    pendingFold = true
                    continue
                }
                let t = text
                if t[col] == "\"" {
                    col += 1
                    return out
                }
                if t[col] == "\\", col + 1 >= t.count {
                    // A backslash at the end of a line joins it to the next
                    // with nothing in between.
                    i += 1
                    guard i < lines.count else { throw error("Unterminated quote", line: openLine) }
                    col = 0
                    skipSpacesOnLine()
                    pendingFold = false
                    continue
                }
                if pendingFold { out += " " ; pendingFold = false }
                if t[col] == "\\" {
                    col += 1
                    switch t[col] {
                    case "n": out += "\n"; col += 1
                    case "t": out += "\t"; col += 1
                    case "r": out += "\r"; col += 1
                    case "b": out += "\u{08}"; col += 1
                    case "f": out += "\u{0C}"; col += 1
                    case "0": out += "\u{00}"; col += 1
                    case "\"": out += "\""; col += 1
                    case "\\": out += "\\"; col += 1
                    case "/": out += "/"; col += 1
                    case " ": out += " "; col += 1
                    case "x": out += try readHexEscape(digits: 2)
                    case "u": out += try readHexEscape(digits: 4)
                    case "U": out += try readHexEscape(digits: 8)
                    default: throw error("Invalid escape `\\\(t[col])`")
                    }
                    continue
                }
                out.append(t[col])
                col += 1
            }
        }

        mutating func readHexEscape(digits: Int) throws -> String {
            col += 1
            let t = text
            guard col + digits <= t.count else { throw error("Truncated escape") }
            var value: UInt32 = 0
            for _ in 0..<digits {
                guard let digit = t[col].hexDigitValue else { throw error("Truncated escape") }
                value = value * 16 + UInt32(digit)
                col += 1
            }
            guard let scalar = Unicode.Scalar(value) else { throw error("Truncated escape") }
            return String(Character(scalar))
        }

        // MARK: Block scalars

        mutating func parseBlockScalar(ownerIndent: Int) throws -> StructuredNode {
            let line = lineNumber
            let folded = text[col] == ">"
            col += 1
            var chomp: Character = "c"
            var explicit: Int?
            while col < text.count {
                let c = text[col]
                if c == "+" || c == "-" {
                    chomp = c
                } else if c.isASCII, c.isNumber {
                    guard let digit = c.wholeNumberValue, digit > 0 else {
                        throw error("Bad block scalar indentation")
                    }
                    explicit = digit
                } else {
                    break
                }
                col += 1
            }
            skipSpacesOnLine()
            guard atLineEnd else { throw error("Unexpected text after a block scalar header") }
            i += 1

            // Without an explicit digit the width is the first non-empty
            // line's own indentation, which is what the author meant by it.
            var contentIndent = explicit.map { max(ownerIndent, 0) + $0 }
            if contentIndent == nil {
                var scan = i
                while scan < lines.count {
                    let t = lines[scan].text
                    var c = 0
                    while c < t.count, t[c] == " " { c += 1 }
                    if c < t.count {
                        contentIndent = c
                        break
                    }
                    scan += 1
                }
            }
            let width = contentIndent ?? 0

            var body: [String] = []
            while i < lines.count {
                let t = lines[i].text
                var c = 0
                while c < t.count, t[c] == " " { c += 1 }
                if c >= t.count {
                    body.append(t.count > width ? String(t[width..<t.count]) : "")
                    i += 1
                    continue
                }
                if c < width { break }
                body.append(String(t[width..<t.count]))
                i += 1
            }

            var trailing = 0
            while let last = body.last, last.isEmpty {
                body.removeLast()
                trailing += 1
            }

            var out = folded ? fold(body) : body.joined(separator: "\n")
            switch chomp {
            case "-": break
            case "+": out += String(repeating: "\n", count: out.isEmpty ? trailing : trailing + 1)
            default: if !out.isEmpty { out += "\n" }
            }
            try seekContent()
            return StructuredNode(value: .string(out), line: line)
        }

        /// `>` folding: a single break between two ordinary lines becomes a
        /// space, a blank line stays a break, and a line indented past the
        /// rest keeps the breaks around it.
        func fold(_ body: [String]) -> String {
            var out = ""
            var breaks = 0
            var first = true
            var previousDeeper = false
            for lineText in body {
                if lineText.isEmpty {
                    breaks += 1
                    continue
                }
                let deeper = lineText.first == " "
                if first {
                    out += lineText
                    first = false
                } else if breaks > 0 {
                    out += String(repeating: "\n", count: breaks) + lineText
                } else if deeper || previousDeeper {
                    out += "\n" + lineText
                } else {
                    out += " " + lineText
                }
                breaks = 0
                previousDeeper = deeper
            }
            return out
        }

        // MARK: Flow collections

        /// The next character that matters inside a flow collection, which may
        /// be on a later line: flow ignores the line breaks inside it.
        mutating func flowSkip(openLine: Int) throws {
            while true {
                guard i < lines.count else {
                    throw error("Flow collection left open", line: openLine)
                }
                let t = lines[i].text
                while col < t.count, t[col] == " " || t[col] == "\t" { col += 1 }
                if col < t.count, t[col] != "#" { return }
                i += 1
                col = 0
            }
        }

        mutating func parseFlowValue(openLine: Int, depth: Int) throws -> StructuredNode {
            guard depth < 128 else { throw error("Flow collection nested too deep") }
            try flowSkip(openLine: openLine)
            var anchor: String?
            var tag: String?
            while true {
                let t = lines[i].text
                guard t[col] == "&" || t[col] == "!" else { break }
                let marker = t[col]
                col += 1
                let start = col
                while col < t.count, !" \t,[]{}".contains(t[col]) { col += 1 }
                let name = String(t[start..<col])
                if marker == "&" { anchor = name } else { tag = name }
                try flowSkip(openLine: openLine)
            }
            let line = lines[i].number
            var node: StructuredNode
            switch lines[i].text[col] {
            case "{":
                node = try parseFlowMapping(openLine: line, depth: depth)
            case "[":
                node = try parseFlowSequence(openLine: line, depth: depth)
            case "*":
                col += 1
                let t = lines[i].text
                let start = col
                while col < t.count, !" \t,[]{}".contains(t[col]) { col += 1 }
                let name = String(t[start..<col])
                guard var target = anchors[name] else {
                    throw error("Unknown alias `\(name)`", line: line)
                }
                target.key = nil
                target.line = line
                node = target
            case "\"":
                node = StructuredNode(
                    value: scalarValue(try readDoubleQuoted(), quoted: true, tag: tag), line: line)
            case "'":
                node = StructuredNode(
                    value: scalarValue(try readSingleQuoted(), quoted: true, tag: tag), line: line)
            default:
                node = StructuredNode(
                    value: scalarValue(readFlowPlain(), quoted: false, tag: tag), line: line)
            }
            if let anchor { anchors[anchor] = node }
            return node
        }

        /// A plain scalar inside a flow collection: it ends at the punctuation
        /// that structures the collection, and never runs past its line.
        mutating func readFlowPlain() -> String {
            let t = lines[i].text
            var end = col
            var c = col
            while c < t.count {
                if ",[]{}".contains(t[c]) { break }
                if t[c] == ":", c + 1 >= t.count || " \t,[]{}".contains(t[c + 1]) { break }
                if t[c] == "#", c > col, t[c - 1] == " " { break }
                c += 1
                if t[c - 1] != " ", t[c - 1] != "\t" { end = c }
            }
            let out = String(t[col..<end])
            col = c
            return out
        }

        mutating func parseFlowMapping(openLine: Int, depth: Int) throws -> StructuredNode {
            col += 1
            var items: [MappingItem] = []
            try flowSkip(openLine: openLine)
            if lines[i].text[col] == "}" {
                col += 1
                return StructuredNode(value: .object, children: [], line: openLine)
            }
            while true {
                try flowSkip(openLine: openLine)
                let keyLine = lines[i].number
                let key: String
                switch lines[i].text[col] {
                case "\"": key = try readDoubleQuoted()
                case "'": key = try readSingleQuoted()
                case "?": throw error("Complex keys are not supported", line: keyLine)
                default: key = readFlowPlain()
                }
                try flowSkip(openLine: openLine)
                var value: StructuredNode
                if lines[i].text[col] == ":" {
                    col += 1
                    value = try parseFlowValue(openLine: openLine, depth: depth + 1)
                } else {
                    value = StructuredNode(value: .null, line: keyLine)
                }
                if key == "<<" {
                    items.append(.merge(try mergeSources(value, line: keyLine)))
                } else {
                    value.key = key
                    value.line = keyLine
                    items.append(.entry(value))
                }
                try flowSkip(openLine: openLine)
                switch lines[i].text[col] {
                case ",":
                    col += 1
                    try flowSkip(openLine: openLine)
                    if lines[i].text[col] == "}" {
                        col += 1
                        return StructuredNode(
                            value: .object, children: resolve(items), line: openLine)
                    }
                case "}":
                    col += 1
                    return StructuredNode(value: .object, children: resolve(items), line: openLine)
                default:
                    throw error("Expected `,` or `}` in a flow mapping")
                }
            }
        }

        mutating func parseFlowSequence(openLine: Int, depth: Int) throws -> StructuredNode {
            col += 1
            var items: [StructuredNode] = []
            try flowSkip(openLine: openLine)
            if lines[i].text[col] == "]" {
                col += 1
                return StructuredNode(value: .array, children: [], line: openLine)
            }
            while true {
                var item = try parseFlowValue(openLine: openLine, depth: depth + 1)
                item.key = nil
                items.append(item)
                try flowSkip(openLine: openLine)
                switch lines[i].text[col] {
                case ",":
                    col += 1
                    try flowSkip(openLine: openLine)
                    if lines[i].text[col] == "]" {
                        col += 1
                        return StructuredNode(value: .array, children: items, line: openLine)
                    }
                case "]":
                    col += 1
                    return StructuredNode(value: .array, children: items, line: openLine)
                default:
                    throw error("Expected `,` or `]` in a flow sequence")
                }
            }
        }

        // MARK: The core schema

        /// What a scalar *is*. A tag overrules the schema — that is what a tag
        /// is for — and anything quoted is a string, which is how a YAML file
        /// says that `"12"` is a version and not a number.
        func scalarValue(_ raw: String, quoted: Bool, tag: String?) -> StructuredNode.Value {
            if var tag {
                while tag.hasPrefix("!") { tag.removeFirst() }
                switch tag {
                case "str": return .string(raw)
                case "int", "float": return .number(raw)
                case "bool": return .bool(raw.lowercased() == "true")
                case "null": return .null
                default: break
                }
            }
            if quoted { return .string(raw) }
            switch raw {
            case "", "~", "null", "Null", "NULL": return .null
            case "true", "True", "TRUE": return .bool(true)
            case "false", "False", "FALSE": return .bool(false)
            default: break
            }
            return YAMLTree.isNumber(raw) ? .number(raw) : .string(raw)
        }
    }

    // MARK: - Numbers

    /// The core schema's integers and floats and nothing beside them: no
    /// `1_000`, no `0b1010`, no sexagesimal `1:30`. Those are YAML 1.1, and a
    /// 1.2 reader calls them strings.
    private static func isNumber(_ raw: String) -> Bool {
        var body = Substring(raw)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        guard !body.isEmpty else { return false }

        switch body {
        case ".inf", ".Inf", ".INF", ".nan", ".NaN", ".NAN": return true
        default: break
        }
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            let digits = body.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy { $0.isHexDigit && $0.isASCII }
        }
        if body.hasPrefix("0o") || body.hasPrefix("0O") {
            let digits = body.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy { ("0"..."7").contains($0) }
        }

        var seenDigit = false
        var index = body.startIndex
        while index < body.endIndex, body[index].isASCII, body[index].isNumber {
            seenDigit = true
            index = body.index(after: index)
        }
        if index < body.endIndex, body[index] == "." {
            index = body.index(after: index)
            while index < body.endIndex, body[index].isASCII, body[index].isNumber {
                seenDigit = true
                index = body.index(after: index)
            }
        }
        guard seenDigit else { return false }
        if index < body.endIndex, body[index] == "e" || body[index] == "E" {
            index = body.index(after: index)
            if index < body.endIndex, body[index] == "+" || body[index] == "-" {
                index = body.index(after: index)
            }
            var seenExponent = false
            while index < body.endIndex, body[index].isASCII, body[index].isNumber {
                seenExponent = true
                index = body.index(after: index)
            }
            guard seenExponent else { return false }
        }
        return index == body.endIndex
    }
}
