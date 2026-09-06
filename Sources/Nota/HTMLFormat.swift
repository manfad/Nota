import Foundation

/// Beautify and Minify for a `.html` file — `JSONFormat`'s three questions,
/// asked of a page. Stub: the formatter is on its way (Todo: the corner slot
/// with four options, 2026-09-06).
enum HTMLFormat {

    /// Which of the two shapes to write.
    enum Style {
        case pretty, minified
    }

    /// The parse stopped, and this is the line it stopped on — 1-based.
    struct ParseError: Error, Equatable {
        let line: Int
    }

    /// The same page, laid out the other way. Throws `ParseError` if the text
    /// cannot be read as a page at all.
    static func reformat(_ text: String, as style: Style) throws -> String {
        throw ParseError(line: 1)
    }

    /// Whether the page is already laid out in lines.
    static func isPretty(_ text: String) -> Bool { true }

    /// Where the parse gave up, or `nil` for a page that reads.
    static func errorLine(in text: String) -> Int? { 1 }
}
