import Foundation

/// An `.xml` file read into a `StructuredDocument`. Stub: the parser is on
/// its way (Todo: tree previews, 2026-09-06).
enum XMLTree {
    static func parse(_ text: String) throws -> StructuredDocument {
        throw StructuredParseError(line: 1, message: "XML is not read yet")
    }
}
