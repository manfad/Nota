import Foundation

/// What a `.json`, `.yaml`, `.toml` or `.xml` file is, once read: a tree.
///
/// Four grammars, one shape. A JSON object, a YAML mapping, a TOML table and
/// an XML element are all a thing with named parts; a JSON array, a YAML
/// sequence and a TOML array are all a thing with numbered parts; and the
/// leaves are strings, numbers, booleans, nulls and — for XML — runs of text.
/// The tree view that shows them knows only this shape, which is what lets
/// one view serve all four, and a parser's whole job is to turn its own
/// grammar into it.
///
/// Every node remembers where it is written: the line it starts on, 1-based
/// the way the editor counts, and — where its parser could say — the whole
/// span of source it was made from, so a click on a row selects the node
/// rather than pointing at the start of a line that may hold the whole file.
struct StructuredNode: Equatable {

    /// What the node holds. A branch's parts are its `children`; a leaf's
    /// value is spelled here.
    enum Value: Equatable {
        /// Named parts: a JSON object, a YAML mapping, a TOML table or inline
        /// table, an XML element (its attributes and its content).
        case object
        /// Numbered parts: a JSON array, a YAML sequence, a TOML array or
        /// array of tables.
        case array
        case string(String)
        /// As spelled in the source — `1.50` stays `1.50`, `0x1F` stays
        /// `0x1F` — since the view shows the file, not a Double.
        case number(String)
        case bool(Bool)
        case null
        /// A TOML date or time, as spelled.
        case date(String)
        /// A run of text or CDATA inside an XML element.
        case text(String)
        /// An XML comment.
        case comment(String)
    }

    /// The member's key, the element's name, or the attribute's name spelled
    /// `@name`. `nil` for an item of an array and for XML text.
    var key: String?
    var value: Value
    var children: [StructuredNode]
    /// The 1-based source line the node starts on.
    var line: Int
    /// The node's whole span in the source, in the UTF-16 units an
    /// `NSTextStorage` counts in — a member from its key through the end of
    /// its value, an item from the value itself, a branch through its closing
    /// bracket. `nil` where the parser could not say, and the line stands in
    /// for it.
    var range: NSRange?
    /// The *value* alone, without the key that names it: `"Nota"` of
    /// `name = "Nota"`, quotes and all, because they are the value's own
    /// characters and a selection that left them out would point at something
    /// the file does not say.
    ///
    /// For a branch it is the bracketed form where the grammar has one — a
    /// JSON object, a TOML inline table or array, a YAML flow collection —
    /// and `nil` where it does not: a YAML block mapping, a TOML `[table]`
    /// and an XML element are their key and their body with nothing around
    /// them, so there is no "value part" to point at.
    var valueRange: NSRange?

    init(
        key: String? = nil, value: Value, children: [StructuredNode] = [],
        line: Int, range: NSRange? = nil, valueRange: NSRange? = nil
    ) {
        self.key = key
        self.value = value
        self.children = children
        self.line = line
        self.range = range
        self.valueRange = valueRange
    }

    var isBranch: Bool {
        switch value {
        case .object, .array: true
        default: false
        }
    }
}

/// A whole file. Usually one root; a YAML stream with `---` between its
/// documents has several, and an XML file's root element may have comments
/// beside it.
struct StructuredDocument: Equatable {
    var roots: [StructuredNode]
}

/// The parse stopped, and this is where: the 1-based line, and a short
/// reason for the footer or a tool tip ("Unexpected `}`", "Tab in indent").
struct StructuredParseError: Error, Equatable {
    let line: Int
    let message: String
}

/// The four grammars a tree preview reads, and which parser each goes to.
enum StructuredFormat: Equatable {
    case json, yaml, toml, xml

    /// By the file's own name, the way `RenderedPreviewKind` spells things:
    /// what a file is *rendered as* is its author's word.
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "json": self = .json
        case "yaml", "yml": self = .yaml
        case "toml": self = .toml
        case "xml": self = .xml
        default: return nil
        }
    }

    func parse(_ text: String) throws -> StructuredDocument {
        switch self {
        case .json: try JSONTree.parse(text)
        case .yaml: try YAMLTree.parse(text)
        case .toml: try TOMLTree.parse(text)
        case .xml: try XMLTree.parse(text)
        }
    }
}

/// Where a parser's own counting lands in the editor's.
///
/// A node's range is an `NSRange` over the note's `NSTextStorage`, which
/// counts in UTF-16 units, and not one parser here counts that way: the JSON
/// walker steps over UTF-8 bytes, the TOML and YAML walkers over
/// `Character`s, and `XMLParser` reports columns in Unicode scalars. Every one
/// of those is the same string held against a different ruler, so the
/// conversion is made once, in a single pass over the text, and remembers only
/// the places where the two rulers part company — for an ASCII file, nowhere
/// at all, and the lookup is then the identity.
struct SourceOffsets {

    /// The positions, in the parser's own units, where the running difference
    /// between the two rulers changes, and what it becomes there. Both start
    /// with the zero every string starts with, so a lookup always finds
    /// something.
    private var marks: [Int] = [0]
    private var differences: [Int] = [0]

    /// For a walk over `Array(text.utf8)` — the JSON parser's.
    static func utf8(of text: String) -> SourceOffsets {
        var offsets = SourceOffsets()
        for scalar in text.unicodeScalars {
            offsets.step(unit: UTF8.width(scalar), utf16: UTF16.width(scalar))
        }
        return offsets
    }

    /// For a walk over `Array(text)` — the TOML and YAML parsers'.
    static func characters(of text: String) -> SourceOffsets {
        var offsets = SourceOffsets()
        for character in text { offsets.step(unit: 1, utf16: character.utf16.count) }
        return offsets
    }

    /// For `XMLParser`'s columns, which libxml counts in Unicode scalars.
    static func scalars(of text: String) -> SourceOffsets {
        var offsets = SourceOffsets()
        for scalar in text.unicodeScalars { offsets.step(unit: 1, utf16: UTF16.width(scalar)) }
        return offsets
    }

    private mutating func step(unit: Int, utf16: Int) {
        position += unit
        guard unit != utf16 else { return }
        difference += utf16 - unit
        marks.append(position)
        differences.append(difference)
    }

    private var position = 0
    private var difference = 0

    /// One position, in UTF-16. A position inside a unit the two rulers
    /// disagree about — which no parser here ever hands over — comes back at
    /// that unit's own start.
    func utf16(_ position: Int) -> Int {
        var low = 0
        var high = marks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if marks[middle] <= position { low = middle } else { high = middle - 1 }
        }
        return position + differences[low]
    }

    /// A span, from one position to another, as the editor counts it.
    func range(from start: Int, to end: Int) -> NSRange {
        let location = utf16(start)
        return NSRange(location: location, length: max(0, utf16(end) - location))
    }
}
