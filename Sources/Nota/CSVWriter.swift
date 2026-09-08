import Foundation

/// An RFC 4180 CSV writer — the mirror of `CSVTable`'s own reader, so what
/// this writes is exactly what that reads back. Nota's own, no dependency
/// and no Foundation CSV.
///
/// A field is quoted only when it has to be: a comma, a double quote, a CR
/// or LF, or a leading or trailing space inside it. Anything else is written
/// bare, because an unquoted field is the plainer file and a stray pair of
/// quotes would say something the field does not mean. A quote inside a
/// quoted field is doubled, the way `CSVTable` reads `""` back as one; a
/// `nil` — a SQL `NULL`, or a CSV row a ragged record never wrote that far
/// into — is written as nothing at all rather than as the word; every line
/// ends on a bare `\n`.
enum CSVWriter {

    /// The whole table as one string, header first: fine for a result small
    /// enough to sit in memory as a string besides the array it was built
    /// from. `write(header:to:)` / `write(row:to:)` are the pair to use
    /// instead of a table that might run past a page or two — a dump of two
    /// hundred thousand rows should never be held twice over, once as what
    /// was read and again as the string this builds.
    static func write(header: [String], rows: [[String?]]) -> String {
        var text = ""
        appendRow(header.map { $0 as String? }, to: &text)
        for row in rows { appendRow(row, to: &text) }
        return text
    }

    /// The header line, written straight to `handle`.
    static func write(header: [String], to handle: FileHandle) throws {
        try write(row: header.map { $0 as String? }, to: handle)
    }

    /// One row, written straight to `handle` and then let go — the streaming
    /// half of the writer: called once per row while a whole table is being
    /// walked, so nothing but the one row in hand and the file's own buffer
    /// is ever held.
    static func write(row fields: [String?], to handle: FileHandle) throws {
        var line = ""
        appendRow(fields, to: &line)
        guard let data = line.data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
    }

    private static func appendRow(_ fields: [String?], to text: inout String) {
        for (index, field) in fields.enumerated() {
            if index > 0 { text.append(",") }
            text.append(quoted(field))
        }
        text.append("\n")
    }

    /// `nil` is empty and never quoted — there is nothing in it to protect.
    /// Anything else is quoted only when it holds a character that would
    /// otherwise be read as something other than itself.
    private static func quoted(_ field: String?) -> String {
        guard let field else { return "" }
        guard needsQuoting(field) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func needsQuoting(_ field: String) -> Bool {
        guard !field.isEmpty else { return false }
        if field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r") {
            return true
        }
        return field.first == " " || field.last == " "
    }
}

/// What stops an export before it ever reaches SQLite or the file system:
/// nothing picked to export at all — a dump with no table and no query.
enum CSVExportError: Error, Equatable {
    case nothingToExport
}
