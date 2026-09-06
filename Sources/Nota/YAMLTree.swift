import Foundation

/// A `.yaml` file read into a `StructuredDocument`. Stub: the parser is on
/// its way (Todo: tree previews, 2026-09-06).
enum YAMLTree {
    static func parse(_ text: String) throws -> StructuredDocument {
        throw StructuredParseError(line: 1, message: "YAML is not read yet")
    }
}
