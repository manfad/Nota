import Foundation

/// Where each row of a dump is written in the file that made it.
///
/// A Markdown render is a picture of its own text, so a click on a block can
/// be answered by the block itself (`MarkdownSourceMap`). A database is not: a
/// row of `customers` is the *result* of a statement that ran, and the only
/// way back to the line that wrote it is to have watched the run.
///
/// So `SQLDump` keeps a note as it goes. Every statement it runs leaves its
/// own characters behind — where it begins in the file and where it ends — and
/// an `INSERT` leaves the rowids it made as well: `sqlite3_changes` says how
/// many rows went in and `sqlite3_last_insert_rowid` says the last of them, so
/// the run of rowids is the pair read together. A page of a table carries its
/// rowids beside its values (`SELECT rowid, * FROM …`), and a click on a cell
/// asks this for the rowid under it.
///
/// Two things it deliberately does not do. A table with no rowid — a
/// `WITHOUT ROWID` table, and the result of a query no rowid could be got
/// into (`SQLQueryRewrite`) — has nothing to look up by, so it has no map and
/// a click on it does nothing rather than landing somewhere arbitrary. And a row that was written by one statement and then
/// changed by an `UPDATE` further down the file still points at the `INSERT`
/// that made it: that is where the row is *written*, which is what a reader
/// clicking it is asking to see.
struct SQLSourceMap {

    /// One statement of the file, as it was run.
    struct Statement: Equatable {
        /// The statement's own characters in the file, from its first letter
        /// through its semicolon. UTF-16, so it is a range the editor's text
        /// storage understands without translation.
        let range: NSRange
        /// The table an `INSERT` named, folded to lower case — SQLite's
        /// identifiers are, so `Customers` and `customers` are one table.
        /// `nil` for everything that is not an insert.
        let table: String?
        /// The rowids the insert made, when the table it inserted into keeps
        /// rowids at all.
        ///
        /// A run rather than a list: a multi-row insert numbers its rows one
        /// after another, and the pair SQLite hands back is the last rowid and
        /// the count. Where that assumption does not hold — an insert that
        /// picked its own scattered ids — the tuple it points at is checked
        /// before it is used, and a statement whose tuples do not add up is
        /// pointed at as a whole instead.
        let rowids: ClosedRange<Int64>?
    }

    private(set) var statements: [Statement]
    /// The text the ranges are into, kept so a tuple can be found inside a
    /// statement without the file being handed back in. Held as `NSString`
    /// because every range here is one.
    private let source: NSString

    init(source: String = "", statements: [Statement] = []) {
        self.source = source as NSString
        self.statements = statements
    }

    var isEmpty: Bool { statements.isEmpty }

    // MARK: - Looking a row up

    /// Where the row with this rowid is written: its own tuple inside a
    /// multi-row `INSERT … VALUES (…),(…)`, and the whole statement's start
    /// otherwise.
    ///
    /// The last statement that claims the rowid wins, so a row deleted and put
    /// back further down the file points at the insert that is actually
    /// standing.
    func range(ofRowid rowid: Int64, inTable table: String) -> NSRange? {
        guard let found = statement(claiming: rowid, inTable: table) else { return nil }
        guard found.rowids.count > 1 else { return found.statement.range }
        // Only when the writing and the count agree. A statement whose tuples
        // cannot be counted — `INSERT … SELECT`, or an insert that named its
        // own ids out of order — is pointed at whole rather than pointed at
        // wrongly.
        return tuple(of: rowid, in: found) ?? found.statement.range
    }

    /// Where *one value* of that row is written: the cell's own text inside
    /// the tuple, its quotes part of it, the comma and the blanks around it
    /// not. That is what a click on a cell selects.
    ///
    /// Which value it is comes from the column's name rather than from the
    /// grid's own order, because the two need not agree: an
    /// `INSERT INTO t (b, a) VALUES (…)` writes the columns in its own order,
    /// and a query names whichever of them it asked for. So the column list
    /// the insert gave decides when there is one, and the table's own columns
    /// decide when there is not.
    ///
    /// Everything that cannot be placed falls back to the row's own range and
    /// never to nothing: a name in neither list, a tuple that will not read, a
    /// value position past the end of it. A reader who clicked a cell is
    /// asking where the row is, and the tuple is always at least that.
    func range(
        ofRowid rowid: Int64, inTable table: String,
        column name: String, tableColumns: [String]
    ) -> NSRange? {
        guard let found = statement(claiming: rowid, inTable: table) else { return nil }
        let row = found.rowids.count > 1
            ? (tuple(of: rowid, in: found) ?? found.statement.range)
            : found.statement.range
        guard let tupleRange = tuple(of: rowid, in: found),
              let position = position(
                  of: name, in: found.statement.range, tableColumns: tableColumns
              ),
              let value = SQLSourceMap.valueRange(
                  at: position, inTuple: source.substring(with: tupleRange)
              )
        else { return row }
        return NSRange(location: tupleRange.location + value.location, length: value.length)
    }

    /// The statement that wrote this row, and the run of rowids it made. The
    /// last one that claims the rowid wins, so a row deleted and put back
    /// further down the file points at the insert that is actually standing.
    private func statement(
        claiming rowid: Int64, inTable table: String
    ) -> (statement: Statement, rowids: ClosedRange<Int64>)? {
        let key = table.lowercased()
        guard let statement = statements.last(where: {
            $0.table == key && ($0.rowids?.contains(rowid) ?? false)
        }), let rowids = statement.rowids else { return nil }
        return (statement, rowids)
    }

    /// The row's own `(…)` inside the statement, in the file's coordinates.
    /// `nil` when the statement's tuples do not add up to the rows it claims.
    private func tuple(
        of rowid: Int64, in found: (statement: Statement, rowids: ClosedRange<Int64>)
    ) -> NSRange? {
        let range = found.statement.range
        guard range.location >= 0, range.upperBound <= source.length else { return nil }
        let tuples = SQLSourceMap.valueTuples(in: source.substring(with: range))
        let index = Int(rowid - found.rowids.lowerBound)
        guard tuples.count == found.rowids.count, index >= 0, index < tuples.count else {
            return nil
        }
        return NSRange(location: range.location + tuples[index].location,
                       length: tuples[index].length)
    }

    /// Which value of the tuple a column's name stands for: its place in the
    /// list the insert named, and its place in the table otherwise. `nil` for
    /// a name in neither, which is a cell that cannot be placed.
    private func position(
        of name: String, in statement: NSRange, tableColumns: [String]
    ) -> Int? {
        let wanted = name.lowercased()
        if statement.location >= 0, statement.upperBound <= source.length,
           let named = SQLSourceMap.insertColumns(in: source.substring(with: statement)) {
            return named.firstIndex(of: wanted)
        }
        return tableColumns.firstIndex { $0.lowercased() == wanted }
    }

    // MARK: - Reading the statement's own text

    /// The `(…)` groups after `VALUES`, in the statement's own coordinates —
    /// one per row of a multi-row insert.
    ///
    /// Parentheses are counted outside string literals, quoted identifiers and
    /// comments, so `('a, b)')` is one value and not the end of a tuple. The
    /// column list of `INSERT INTO t (a, b) VALUES (…)` is before the keyword
    /// and is not one of these; the keyword itself is only taken at depth
    /// zero, so a column called `values` is not mistaken for it.
    static func valueTuples(in statement: String) -> [NSRange] {
        let units = Array(statement.utf16)
        var index = 0
        var afterValues = false
        var depth = 0
        var start = 0
        var tuples: [NSRange] = []
        while index < units.count {
            if let skipped = skipping(units, from: index) {
                index = skipped
                continue
            }
            let unit = units[index]
            if unit == Ascii.openParen {
                if afterValues, depth == 0 { start = index }
                depth += 1
            } else if unit == Ascii.closeParen, depth > 0 {
                depth -= 1
                if afterValues, depth == 0 {
                    tuples.append(NSRange(location: start, length: index + 1 - start))
                }
            } else if !afterValues, depth == 0, matches("VALUES", units, at: index) {
                afterValues = true
                index += 6
                continue
            }
            index += 1
        }
        return tuples
    }

    /// The nth value inside one tuple's text, in the tuple's own coordinates
    /// — `(1, 'it''s, really', NULL)` asked for its second value is the
    /// eleven characters of `'it''s, really'`, quotes included.
    ///
    /// One walk over the tuple. A string literal, a quoted name and a comment
    /// are stepped over whole, so a comma inside `'…'` is a comma of the text
    /// and not a boundary; a `(` opens a depth, so an expression written as a
    /// value (`(1 + 2)`) is one value and its own comma is not counted. The
    /// blanks around a value are none of it and neither are the commas; its
    /// quotes are.
    ///
    /// `nil` for a tuple that never closes, and for a position past the end
    /// of one — a caller with nothing to point at is told so rather than
    /// handed the wrong value.
    static func valueRange(at position: Int, inTuple tuple: String) -> NSRange? {
        let units = Array(tuple.utf16)
        guard let open = units.firstIndex(of: Ascii.openParen) else { return nil }
        var index = open + 1
        var start = index
        var depth = 0
        var values: [NSRange] = []
        var closed = false
        while index < units.count {
            if let skipped = skipping(units, from: index), skipped > index {
                index = skipped
                continue
            }
            let unit = units[index]
            if unit == Ascii.openParen {
                depth += 1
            } else if unit == Ascii.closeParen {
                guard depth > 0 else {
                    values.append(NSRange(location: start, length: index - start))
                    closed = true
                    break
                }
                depth -= 1
            } else if unit == Ascii.comma, depth == 0 {
                values.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        guard closed, position >= 0, position < values.count else { return nil }
        return trimming(values[position], in: units)
    }

    /// A value with the blanks and the comments around it taken off. Never a
    /// quote: `'a'` is three characters of value and not one.
    private static func trimming(_ range: NSRange, in units: [UInt16]) -> NSRange {
        var start = range.location
        let limit = range.upperBound
        while start < limit {
            let unit = units[start]
            if isBlank(unit) {
                start += 1
                continue
            }
            let comment = (unit == Ascii.dash && start + 1 < limit && units[start + 1] == Ascii.dash)
                || (unit == Ascii.slash && start + 1 < limit && units[start + 1] == Ascii.star)
            guard comment, let end = skipping(units, from: start), end > start else { break }
            start = min(end, limit)
        }
        var end = limit
        while end > start, isBlank(units[end - 1]) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The columns an `INSERT INTO t (a, b) VALUES …` names, unquoted and
    /// folded to lower case, or `nil` for an insert that named none — which
    /// is the one that writes the table's own columns in the table's own
    /// order.
    static func insertColumns(in statement: String) -> [String]? {
        let units = Array(statement.utf16)
        var index = 0
        guard let verb = nextToken(units, &index), verb.kind == .word,
              verb.text.lowercased() == "insert" || verb.text.lowercased() == "replace"
        else { return nil }
        var token = nextToken(units, &index)
        if let word = token, word.kind == .word, word.text.lowercased() == "or" {
            _ = nextToken(units, &index)  // ABORT · FAIL · IGNORE · REPLACE · ROLLBACK
            token = nextToken(units, &index)
        }
        guard let into = token, into.kind == .word, into.text.lowercased() == "into"
        else { return nil }
        guard let name = nextToken(units, &index), name.kind != .punctuation else { return nil }
        var next = nextToken(units, &index)
        // `schema.table`: the list, if there is one, is after the second half.
        if let dot = next, dot.kind == .punctuation, dot.text == "." {
            guard let second = nextToken(units, &index), second.kind != .punctuation else {
                return nil
            }
            next = nextToken(units, &index)
        }
        guard let open = next, open.kind == .punctuation, open.text == "(" else { return nil }
        var names: [String] = []
        while let token = nextToken(units, &index) {
            if token.kind == .punctuation {
                if token.text == ")" { return names }
                if token.text == "," { continue }
                return nil
            }
            names.append(token.text.lowercased())
        }
        return nil
    }

    /// The table an `INSERT … INTO` names, unquoted and folded to lower case,
    /// or `nil` for a statement that is not one.
    ///
    /// Loose on purpose, because the statement has already been through
    /// SQLite's own parser and is known to be good: the verb, an optional
    /// `OR ROLLBACK`-style clause, `INTO`, and then the name — bare, or in
    /// any of the four quotes SQLite takes, with an optional `schema.` in
    /// front of it.
    static func insertTable(in statement: String) -> String? {
        let units = Array(statement.utf16)
        var index = 0
        guard let verb = nextToken(units, &index), verb.kind == .word,
              verb.text.lowercased() == "insert" || verb.text.lowercased() == "replace"
        else { return nil }
        var token = nextToken(units, &index)
        if let word = token, word.kind == .word, word.text.lowercased() == "or" {
            _ = nextToken(units, &index)  // ABORT · FAIL · IGNORE · REPLACE · ROLLBACK
            token = nextToken(units, &index)
        }
        guard let into = token, into.kind == .word, into.text.lowercased() == "into"
        else { return nil }
        guard var name = nextToken(units, &index), name.kind != .punctuation else { return nil }
        // `schema.table`: the name is the second half.
        let afterName = index
        if let dot = nextToken(units, &index), dot.kind == .punctuation, dot.text == "." {
            guard let real = nextToken(units, &index), real.kind != .punctuation else {
                return nil
            }
            name = real
        } else {
            index = afterName
        }
        return name.text.isEmpty ? nil : name.text.lowercased()
    }

    // MARK: - The scanner

    private enum Ascii {
        static let tab: UInt16 = 9
        static let newline: UInt16 = 10
        static let carriageReturn: UInt16 = 13
        static let space: UInt16 = 32
        static let quote: UInt16 = 39
        static let doubleQuote: UInt16 = 34
        static let backtick: UInt16 = 96
        static let openBracket: UInt16 = 91
        static let closeBracket: UInt16 = 93
        static let openParen: UInt16 = 40
        static let closeParen: UInt16 = 41
        static let comma: UInt16 = 44
        static let dash: UInt16 = 45
        static let slash: UInt16 = 47
        static let star: UInt16 = 42
        static let underscore: UInt16 = 95
        static let dollar: UInt16 = 36
    }

    /// A token's own kind. Internal, with `nextToken`, because the scanner
    /// below is the one this file's own two readers and `SQLQueryRewrite` all
    /// run on: one way of reading SQL text, not three.
    enum TokenKind { case word, quoted, punctuation }

    struct Token {
        let text: String
        let kind: TokenKind
    }

    /// Whatever at `index` is not code — blanks, a `--` line comment, a
    /// `/* */` block, a string literal, a quoted identifier — and where it
    /// ends. `nil` when what is there is code.
    private static func skipping(_ units: [UInt16], from index: Int) -> Int? {
        let unit = units[index]
        switch unit {
        case Ascii.space, Ascii.tab, Ascii.newline, Ascii.carriageReturn:
            var end = index
            while end < units.count, isBlank(units[end]) { end += 1 }
            return end
        case Ascii.quote, Ascii.doubleQuote, Ascii.backtick:
            return endOfQuoted(units, from: index, closing: unit)
        case Ascii.openBracket:
            return endOfQuoted(units, from: index, closing: Ascii.closeBracket)
        case Ascii.dash where index + 1 < units.count && units[index + 1] == Ascii.dash:
            var end = index + 2
            while end < units.count, units[end] != Ascii.newline { end += 1 }
            return end
        case Ascii.slash where index + 1 < units.count && units[index + 1] == Ascii.star:
            var end = index + 2
            while end + 1 < units.count {
                if units[end] == Ascii.star, units[end + 1] == Ascii.slash { return end + 2 }
                end += 1
            }
            return units.count
        default:
            return nil
        }
    }

    /// Past the closing quote, with a doubled quote inside taken as one
    /// character of the text rather than as the end — `'it''s'` is one string.
    /// `[…]` has no doubling and closes on its bracket.
    private static func endOfQuoted(
        _ units: [UInt16], from index: Int, closing: UInt16
    ) -> Int {
        let doubles = closing != Ascii.closeBracket
        var end = index + 1
        while end < units.count {
            if units[end] == closing {
                if doubles, end + 1 < units.count, units[end + 1] == closing {
                    end += 2
                    continue
                }
                return end + 1
            }
            end += 1
        }
        return units.count
    }

    private static func isBlank(_ unit: UInt16) -> Bool {
        unit == Ascii.space || unit == Ascii.tab
            || unit == Ascii.newline || unit == Ascii.carriageReturn
    }

    /// What an identifier or keyword is made of. Anything past ASCII counts:
    /// a table may be called `наименования` and SQLite does not mind.
    private static func isWord(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case Ascii.underscore, Ascii.dollar: true
        default: unit >= 0x80
        }
    }

    /// Whether an ASCII keyword stands at `index`, in any case, with nothing
    /// of a longer word on either side of it.
    private static func matches(_ keyword: String, _ units: [UInt16], at index: Int) -> Bool {
        let wanted = Array(keyword.utf16)
        guard index + wanted.count <= units.count else { return false }
        for (offset, unit) in wanted.enumerated() {
            let found = units[index + offset]
            guard found == unit || found == unit + 32 else { return false }
        }
        if index > 0, isWord(units[index - 1]) { return false }
        let after = index + wanted.count
        return after >= units.count || !isWord(units[after])
    }

    /// The next thing along: a word, a quoted name with its quotes taken off,
    /// or one character of punctuation. Blanks and comments are stepped over
    /// on the way.
    static func nextToken(_ units: [UInt16], _ index: inout Int) -> Token? {
        while index < units.count {
            let unit = units[index]
            if isBlank(unit) || unit == Ascii.dash || unit == Ascii.slash,
               let skipped = skipping(units, from: index), skipped > index {
                index = skipped
                continue
            }
            break
        }
        guard index < units.count else { return nil }
        let unit = units[index]
        if unit == Ascii.quote || unit == Ascii.doubleQuote || unit == Ascii.backtick
            || unit == Ascii.openBracket {
            let closing = unit == Ascii.openBracket ? Ascii.closeBracket : unit
            let end = endOfQuoted(units, from: index, closing: closing)
            let inner = Array(units[(index + 1)..<max(index + 1, end - 1)])
            index = end
            let text = String(decoding: inner, as: UTF16.self)
            // A doubled quote inside is one character of the name.
            let quote = String(decoding: [closing], as: UTF16.self)
            return Token(text: closing == Ascii.closeBracket ? text
                : text.replacingOccurrences(of: quote + quote, with: quote),
                kind: .quoted)
        }
        if isWord(unit) {
            var end = index
            while end < units.count, isWord(units[end]) { end += 1 }
            let text = String(decoding: units[index..<end], as: UTF16.self)
            index = end
            return Token(text: text, kind: .word)
        }
        index += 1
        return Token(text: String(decoding: [unit], as: UTF16.self), kind: .punctuation)
    }
}
