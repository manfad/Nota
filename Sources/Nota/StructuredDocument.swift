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
/// Every node remembers the line it starts on, 1-based the way the editor
/// counts, so a click on a row can put the caret there.
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

    init(key: String? = nil, value: Value, children: [StructuredNode] = [], line: Int) {
        self.key = key
        self.value = value
        self.children = children
        self.line = line
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
