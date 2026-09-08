import Foundation

/// A `.csv` or `.tsv` file read as the table it is.
///
/// A dump has to be *run* to be seen (`SQLDump`); a delimited file has only
/// to be read, and that is the whole difference between the two panes. There
/// is no engine here and no dependency: Nota's own RFC 4180 scanner walks the
/// text once and comes back with a header, the records under it, and where
/// each record is written.
///
/// The rules it keeps, because a real file breaks all of them:
/// - The separator is the comma for a `.csv` and the tab for a `.tsv`, and
///   nothing is sniffed — the name the author gave the file is the answer, the
///   same way `RenderedPreviewKind` decides everything else.
/// - A field that opens with `"` is quoted: `""` inside it is one quote, and a
///   separator or a newline inside it is text rather than a boundary. A field
///   that does *not* open with one keeps its quotes as characters, because a
///   file that writes `5" pipe` means five inches.
/// - CRLF, LF and a lone CR all end a record, and a trailing newline is the
///   end of the last record rather than the start of an empty one. A blank
///   line anywhere is skipped: it is whitespace in the file, not a row of
///   nothing.
/// - The first record is the header. A header cell with nothing in it is
///   named for its position (`Column 3`), the way `SQLPreviewView` names a
///   column it has no name for, so every column has something to click on.
/// - Rows are ragged in practice. A short one is padded with empty cells and a
///   long one widens the table — nothing is ever thrown away, and no record is
///   ever a failure.
///
/// Where a record is written is taken down as it is read: `sources` holds, per
/// row, the characters of the record from the start of the line it begins on
/// to the end of the line it ends on. A record whose quoted field runs over
/// three lines has all three, and the range's own location is the first of
/// them — which is what a click on a cell walks the editor to.
///
/// `fieldSources` is the same note taken one level down: per row, where every
/// field of it is written, *as written* — a quoted field's own quotes are part
/// of it, because they are its text in the file. A click on a cell selects
/// that, and only a cell that cannot be placed — a ragged row that never wrote
/// the field, a click with no column under it — falls back to the record.
struct CSVTable: Equatable {

    /// How many rows a page holds — the same hundred a dump's page holds, so
    /// the two grids page at the same rate and the bar over them reads the
    /// same.
    static let pageSize = SQLDump.pageSize

    /// What separates one field from the next. Spelled by the file's name and
    /// by nothing else.
    enum Separator: Equatable {
        case comma, tab

        var character: Character {
            switch self {
            case .comma: ","
            case .tab: "\t"
            }
        }

        /// `nil` for every other spelling: a `.txt` full of commas is a
        /// `.txt`.
        init?(fileExtension: String) {
            if fileExtension.caseInsensitiveCompare("csv") == .orderedSame {
                self = .comma
                return
            }
            if fileExtension.caseInsensitiveCompare("tsv") == .orderedSame {
                self = .tab
                return
            }
            return nil
        }
    }

    /// The header, one name per column, blanks named for their position.
    let columns: [String]
    /// Every record after the header, each as wide as `columns`.
    let rows: [[String]]
    /// Where each row is written, in the same order — `rows[i]` is written at
    /// `sources[i]`.
    let sources: [NSRange]
    /// Where each field of each row is written, quotes included. As long as
    /// the record actually was: a ragged row that wrote three fields has
    /// three, not as many as `columns` has, since the ones it never wrote are
    /// nowhere in the file to be pointed at.
    let fieldSources: [[NSRange]]

    /// Reads the whole file. Never fails: a file this cannot make sense of is
    /// a table with odd rows in it, which is what the reader wants to see.
    init(text: String, separator: Separator) {
        let records = CSVTable.scan(text, separator: separator.character)
        guard let header = records.first else {
            columns = []
            rows = []
            sources = []
            fieldSources = []
            return
        }
        // A long row widens the table rather than being clipped: the file is
        // the truth, and a value with no header over it is still a value.
        let width = records.reduce(0) { max($0, $1.fields.count) }
        columns = (0..<width).map { index in
            let name = index < header.fields.count
                ? header.fields[index].trimmingCharacters(in: .whitespaces) : ""
            return name.isEmpty ? CSVTable.placeholderName(at: index) : name
        }
        rows = records.dropFirst().map { record in
            record.fields.count == width
                ? record.fields
                : record.fields + Array(repeating: "", count: width - record.fields.count)
        }
        sources = records.dropFirst().map(\.range)
        fieldSources = records.dropFirst().map(\.fieldRanges)
    }

    /// What a column with no name in the header is called. Its position,
    /// counted the way a reader counts columns.
    static func placeholderName(at index: Int) -> String { "Column \(index + 1)" }

    // MARK: - Reading the text

    private struct Record {
        var fields: [String]
        /// The characters of the record: from the first character of the line
        /// it begins on to the last character of the line it ends on, the
        /// terminator itself left out.
        var range: NSRange
        /// The characters of each field, in the same order as `fields` and as
        /// written — the opening and closing quotes of a quoted field are
        /// part of it, and the separators between fields are part of none of
        /// them.
        var fieldRanges: [NSRange]
    }

    /// One pass over the text. UTF-16 offsets are counted as it goes, because
    /// that is what an `NSRange` into the editor's storage is measured in.
    private static func scan(_ text: String, separator: Character) -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var fieldRanges: [NSRange] = []
        var field = ""
        var start = 0
        var offset = 0
        // Where the field in hand began. Every field begins somewhere — at
        // the start of the record, or one unit past the separator before it —
        // and ends where the next separator or terminator stands, so its
        // range is the pair read together.
        var fieldStart = 0
        var characters = Substring(text)
        // A byte-order mark is the encoding saying hello, not the first
        // letter of the first header.
        if characters.first == "\u{FEFF}" {
            characters = characters.dropFirst()
            offset = 1
            start = 1
            fieldStart = 1
        }

        /// Ends the record at `end`, unless it is a blank line.
        func endRecord(at end: Int) {
            fields.append(field)
            fieldRanges.append(NSRange(location: fieldStart, length: end - fieldStart))
            field = ""
            defer {
                fields = []
                fieldRanges = []
            }
            guard fields != [""] else { return }
            records.append(Record(fields: fields,
                                  range: NSRange(location: start, length: end - start),
                                  fieldRanges: fieldRanges))
        }

        var index = characters.startIndex
        var atFieldStart = true
        while index < characters.endIndex {
            let character = characters[index]
            let width = character.utf16.count

            if atFieldStart, character == "\"" {
                atFieldStart = false
                offset += width
                index = characters.index(after: index)
                // Inside the quotes: everything is text until an unpaired
                // quote closes the field.
                while index < characters.endIndex {
                    let quoted = characters[index]
                    offset += quoted.utf16.count
                    index = characters.index(after: index)
                    guard quoted == "\"" else {
                        field.append(quoted)
                        continue
                    }
                    // `""` is one quote; anything else closes the field.
                    if index < characters.endIndex, characters[index] == "\"" {
                        field.append("\"")
                        offset += 1
                        index = characters.index(after: index)
                        continue
                    }
                    break
                }
                continue
            }
            atFieldStart = false

            switch character {
            case separator:
                fields.append(field)
                fieldRanges.append(NSRange(location: fieldStart, length: offset - fieldStart))
                field = ""
                atFieldStart = true
                offset += width
                fieldStart = offset
                index = characters.index(after: index)
            // CRLF is one `Character` in Swift and two UTF-16 units, which is
            // exactly the shape the record wants: one terminator, counted as
            // the two units the editor's storage holds.
            case "\n", "\r", "\r\n":
                let end = offset
                offset += width
                index = characters.index(after: index)
                endRecord(at: end)
                start = offset
                fieldStart = offset
                atFieldStart = true
            default:
                field.append(character)
                offset += width
                index = characters.index(after: index)
            }
        }
        // Whatever is still in hand at the end of the file is the last record
        // — unless the file ended on a terminator, in which case there is
        // nothing in hand at all.
        if !field.isEmpty || !fields.isEmpty || offset > start {
            endRecord(at: offset)
        }
        return records
    }

    // MARK: - Pages

    /// Which column a page is ordered by, and which way round. By position
    /// rather than by name: two columns of a CSV are allowed the same header,
    /// and a click has to sort the one that was clicked.
    struct Sort: Equatable {
        let column: Int
        let ascending: Bool
    }

    /// A hundred rows of the table, and how many there are altogether — the
    /// pair the bar and the footer are both written from.
    struct Page: Equatable {
        let columns: [String]
        let rows: [[String]]
        /// Where each row of *this page* is written, in the page's own order.
        let sources: [NSRange]
        /// Where each field of each row of *this page* is written, quotes
        /// included — what a click on a cell selects.
        let fieldSources: [[NSRange]]
        /// How many rows were skipped to reach this page.
        let offset: Int
        /// How many rows there are in the whole table.
        let total: Int

        /// The first and last row on this page, 1-based, the way they are
        /// counted out loud. An empty page is `0` and `0` — there is no first
        /// row of nothing.
        var first: Int { rows.isEmpty ? 0 : offset + 1 }
        var last: Int { offset + rows.count }
    }

    /// One page of the table, in the order the sort asks for. The sort orders
    /// the whole table and the page is cut from that, so sorting four thousand
    /// rows by name shows the first hundred names and not the first hundred
    /// rows rearranged.
    func page(offset requested: Int, sort: Sort? = nil) -> Page {
        let offset = CSVTable.clamp(offset: requested, total: rows.count)
        let order = ordering(sort)
        let slice = order[min(offset, order.count)..<min(offset + CSVTable.pageSize, order.count)]
        return Page(columns: columns,
                    rows: slice.map { rows[$0] },
                    sources: slice.map { sources[$0] },
                    fieldSources: slice.map { fieldSources[$0] },
                    offset: offset,
                    total: rows.count)
    }

    /// The row indices in the order the sort asks for, and in the file's own
    /// order when there is none. ⌘F over the grid walks it too: a match is
    /// where the row sits on screen, which is this order and not the file's.
    func ordering(_ sort: Sort?) -> [Int] {
        let indices = Array(rows.indices)
        guard let sort, sort.column >= 0, sort.column < columns.count else { return indices }
        let values = rows.map { row -> String in
            sort.column < row.count ? row[sort.column] : ""
        }
        // A column of numbers is read as numbers — `9` before `10`, not after
        // it. One value that is not a number is enough to make the whole
        // column text, since half a numeric order is no order at all.
        let numbers = CSVTable.numbers(of: values)
        return indices.sorted { left, right in
            let ordered = CSVTable.precedes(
                left: left, right: right, values: values, numbers: numbers
            )
            switch ordered {
            // Equal values keep the file's own order, whichever way the
            // column is pointing: a sort that shuffled its ties would shuffle
            // them again on every page.
            case .orderedSame: return left < right
            case .orderedAscending: return sort.ascending
            case .orderedDescending: return !sort.ascending
            }
        }
    }

    /// The column as numbers, or `nil` if any value in it is not one. An
    /// empty cell is not a number and not a disqualification either: it is
    /// nothing, and nothing sorts before everything.
    private static func numbers(of values: [String]) -> [Double?]? {
        var parsed: [Double?] = []
        parsed.reserveCapacity(values.count)
        var sawOne = false
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                parsed.append(nil)
                continue
            }
            guard let number = Double(trimmed) else { return nil }
            sawOne = true
            parsed.append(number)
        }
        return sawOne ? parsed : nil
    }

    private static func precedes(
        left: Int, right: Int, values: [String], numbers: [Double?]?
    ) -> ComparisonResult {
        if let numbers {
            switch (numbers[left], numbers[right]) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedAscending
            case (_, nil): return .orderedDescending
            case (let a?, let b?):
                if a == b { return .orderedSame }
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        // The reader's own language decides what comes before what: `é` sits
        // with `e` rather than after `z`, and case is not a sort order.
        return values[left].compare(values[right],
                                    options: [.caseInsensitive],
                                    range: nil,
                                    locale: .current)
    }

    // MARK: - Export

    /// The header and every row, in the order `ordering(sort)` gives — the
    /// whole table, with no page cut out of it. A field is its text as read,
    /// except a trailing one a ragged row never wrote at all: that comes
    /// back `nil` rather than `""`, since the two are not the same field and
    /// `CSVWriter` only knows to leave a `nil` out rather than write it
    /// empty. `fieldSources[index].count` is how many fields that record
    /// actually wrote, before `rows` padded it out to the table's width.
    func exportRows(sort: Sort? = nil) -> (header: [String], rows: [[String?]]) {
        let order = ordering(sort)
        let exported: [[String?]] = order.map { index in
            let written = fieldSources[index].count
            return rows[index].enumerated().map { position, value in
                position < written ? value : nil
            }
        }
        return (columns, exported)
    }

    /// Which page an offset actually lands on: a whole number of pages from
    /// the top, and never past the last row there is.
    static func clamp(offset: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let last = ((total - 1) / pageSize) * pageSize
        return min(max(0, offset), last)
    }
}
