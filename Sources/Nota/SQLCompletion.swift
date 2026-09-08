import Foundation

/// What the query box knows about SQL while it is being typed: which word
/// could be finished, and which part of a line is a keyword, a string, a
/// number or a comment.
///
/// All of it is arithmetic over the text. Nothing here opens a database, asks
/// SQLite anything or touches a view — the pane hands over a plain snapshot of
/// the schema (tables, and the columns of each) taken off the main thread
/// where the dump already lives, and everything below is a function of that
/// snapshot and the characters the reader has written.
///
/// The completion is deliberately shallow. It does not parse the query: it
/// reads the word under the caret, and — for `o.` — scans the text for the
/// `FROM orders o` that gave `o` its meaning. A query too tangled for that
/// scan simply offers a little less, which is the right way for a suggestion
/// to fail. It is never wrong about what it inserts, only sometimes short.
enum SQLCompletion {

    // MARK: - The schema

    /// The names of a dump, as a value: the tables in the order the database
    /// lists them, and each one's columns in the order they were declared.
    /// A plain dictionary on purpose — it crosses a queue boundary, and the
    /// database it was read from is not a thing the main thread may hold.
    struct Schema: Equatable {
        let tables: [String]
        let columns: [String: [String]]

        init(tables: [String] = [], columns: [String: [String]] = [:]) {
            self.tables = tables
            self.columns = columns
        }

        static let empty = Schema()

        var isEmpty: Bool { tables.isEmpty && columns.isEmpty }

        /// The table of that name as the schema spells it, whatever case the
        /// reader typed. SQLite does not mind the case of a name and neither
        /// does this.
        func table(named name: String) -> String? {
            let wanted = name.lowercased()
            return tables.first { $0.lowercased() == wanted }
        }

        func columns(ofTable name: String) -> [String] {
            if let exact = columns[name] { return exact }
            guard let table = table(named: name) else { return [] }
            return columns[table] ?? []
        }
    }

    // MARK: - What is offered

    /// What one row of the dropdown stands for. A column carries the table it
    /// belongs to, because that is the only way `id` under six tables reads as
    /// six different things.
    enum Kind: Equatable {
        case keyword
        case table
        case column(table: String)
    }

    /// One suggestion: the text that replaces what was typed, and the grey
    /// word on the right that says where it came from.
    struct Item: Equatable {
        let text: String
        let kind: Kind

        var hint: String {
            switch kind {
            case .keyword: "keyword"
            case .table: "table"
            case .column(let table): table
            }
        }
    }

    /// The vocabulary offered, in the order it is offered in. Written upper
    /// case because that is how it is inserted: a keyword typed in three
    /// lower-case letters comes back as the whole word in capitals, which is
    /// half of why the dropdown is worth having.
    static let keywords: [String] = [
        "SELECT", "DISTINCT", "FROM", "AS", "INNER", "LEFT", "JOIN", "ON",
        "WHERE", "GROUP BY", "HAVING", "UNION", "UNION ALL", "ORDER BY",
        "ASC", "DESC", "LIMIT", "OFFSET", "AND", "OR", "NOT", "IS",
        "IS NULL", "IS NOT NULL", "IN", "BETWEEN", "LIKE", "CASE", "WHEN",
        "THEN", "ELSE", "END", "NULL", "COUNT", "SUM", "AVG", "MIN", "MAX",
    ]

    /// What the caret is standing in, and what could go there.
    ///
    /// `range` is the run of characters the accepted item replaces — the
    /// partial word under the caret, which is empty when the caret sits right
    /// after a `.`. An empty `items` means there is nothing to show, and the
    /// caller closes whatever it had open.
    static func suggestions(
        in text: String, caret: Int, schema: Schema
    ) -> (range: NSRange, items: [Item]) {
        let units = Array(text.utf16)
        let caret = max(0, min(caret, units.count))
        let nothing = (NSRange(location: caret, length: 0), [Item]())

        // The word being typed, back to whatever is not part of a name.
        var start = caret
        while start > 0, isWord(units[start - 1]) { start -= 1 }
        let prefix = String(decoding: units[start..<caret], as: UTF16.self)
        let range = NSRange(location: start, length: caret - start)

        // `orders.` or `o.cus`: the name before the dot says which table's
        // columns these are, and nothing else is offered.
        if start > 0, units[start - 1] == Ascii.dot {
            var qualifierStart = start - 1
            while qualifierStart > 0, isWord(units[qualifierStart - 1]) { qualifierStart -= 1 }
            let qualifier = String(
                decoding: units[qualifierStart..<(start - 1)], as: UTF16.self
            )
            guard !qualifier.isEmpty,
                  let table = resolve(qualifier, in: text, schema: schema)
            else { return nothing }
            let items = schema.columns(ofTable: table)
                .filter { matches(prefix, $0) }
                .map { Item(text: $0, kind: .column(table: table)) }
            return offer(range, deduplicated(items), typed: prefix)
        }

        // A bare word offers everything, but the columns of the tables this
        // query already names come first: the reader is finishing a thought
        // about *those* rows, not about the schema at large.
        guard !prefix.isEmpty else { return nothing }
        let named = references(in: text).tables.compactMap { schema.table(named: $0) }
        var items: [Item] = []
        for table in named {
            items += schema.columns(ofTable: table)
                .filter { matches(prefix, $0) }
                .map { Item(text: $0, kind: .column(table: table)) }
        }
        items += keywords
            .filter { matches(prefix, firstWord(of: $0)) }
            .map { Item(text: $0, kind: .keyword) }
        items += schema.tables
            .filter { matches(prefix, $0) }
            .map { Item(text: $0, kind: .table) }
        for table in schema.tables where !named.contains(table) {
            items += schema.columns(ofTable: table)
                .filter { matches(prefix, $0) }
                .map { Item(text: $0, kind: .column(table: table)) }
        }
        return offer(range, deduplicated(items), typed: prefix)
    }

    /// The one item that is already written out in full is not a suggestion —
    /// it is what the reader has just finished typing, and a dropdown over it
    /// would only be in the way.
    private static func offer(
        _ range: NSRange, _ items: [Item], typed: String
    ) -> (range: NSRange, items: [Item]) {
        if items.count == 1, items[0].text.lowercased() == typed.lowercased() {
            return (range, [])
        }
        return (range, items)
    }

    /// The same name twice — `id` in four tables, a column that happens to
    /// spell a keyword — is one row, the first one, so the list stays as
    /// short and as ordered as it was built.
    private static func deduplicated(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.text.lowercased()).inserted }
    }

    private static func matches(_ prefix: String, _ candidate: String) -> Bool {
        prefix.isEmpty || candidate.lowercased().hasPrefix(prefix.lowercased())
    }

    /// `ORDER BY` is offered by typing `ord`: a keyword written over two
    /// words is matched on the first of them and inserted whole.
    private static func firstWord(of keyword: String) -> String {
        String(keyword.prefix { $0 != " " })
    }

    // MARK: - Where a name came from

    /// The tables a query names, and the short names it gave them.
    ///
    /// `FROM orders o`, `FROM orders AS o`, `JOIN customers c`, `FROM a x, b y`
    /// — all of them read the same way: a table, then optionally `AS`, then a
    /// word that is not the start of the next clause. A table also answers to
    /// its own name, so `orders.` works whether or not an alias was given.
    static func references(in text: String) -> (tables: [String], aliases: [String: String]) {
        let units = Array(text.utf16)
        var index = 0
        var tokens: [SQLSourceMap.Token] = []
        while let token = SQLSourceMap.nextToken(units, &index) { tokens.append(token) }

        var tables: [String] = []
        var aliases: [String: String] = [:]
        var index2 = 0
        while index2 < tokens.count {
            let token = tokens[index2]
            index2 += 1
            guard token.kind == .word, introducesTables(token.text) else { continue }
            // The table list this clause opens, comma by comma.
            while index2 < tokens.count {
                let name = tokens[index2]
                guard name.kind != .punctuation, !isClauseWord(name.text) else { break }
                index2 += 1
                if !tables.contains(where: { $0.lowercased() == name.text.lowercased() }) {
                    tables.append(name.text)
                }
                aliases[name.text.lowercased()] = name.text
                if index2 < tokens.count, tokens[index2].kind == .word,
                   tokens[index2].text.lowercased() == "as" {
                    index2 += 1
                    if index2 < tokens.count, tokens[index2].kind != .punctuation {
                        aliases[tokens[index2].text.lowercased()] = name.text
                        index2 += 1
                    }
                } else if index2 < tokens.count, tokens[index2].kind != .punctuation,
                          !isClauseWord(tokens[index2].text) {
                    aliases[tokens[index2].text.lowercased()] = name.text
                    index2 += 1
                }
                guard index2 < tokens.count, tokens[index2].kind == .punctuation,
                      tokens[index2].text == ","
                else { break }
                index2 += 1
            }
        }
        return (tables, aliases)
    }

    /// Which table `o.` stands for: the alias the query gave, or the table
    /// itself when the name is one.
    private static func resolve(_ qualifier: String, in text: String, schema: Schema) -> String? {
        if let named = references(in: text).aliases[qualifier.lowercased()],
           let table = schema.table(named: named) {
            return table
        }
        return schema.table(named: qualifier)
    }

    private static func introducesTables(_ word: String) -> Bool {
        ["from", "join", "into", "update"].contains(word.lowercased())
    }

    /// A word that starts the next thing rather than naming this one, so it
    /// is never read as an alias.
    private static let clauseWords: Set<String> = [
        "select", "distinct", "from", "as", "inner", "left", "right", "full",
        "outer", "cross", "natural", "join", "on", "using", "where", "group",
        "by", "having", "union", "intersect", "except", "order", "asc", "desc",
        "limit", "offset", "and", "or", "not", "is", "in", "between", "like",
        "case", "when", "then", "else", "end", "null", "set", "values",
        "into", "update", "with", "window", "returning",
    ]

    private static func isClauseWord(_ word: String) -> Bool {
        clauseWords.contains(word.lowercased())
    }

    // MARK: - Colour

    /// What one run of the query is, for the sake of the colour it is drawn
    /// in. Everything not named here is ordinary text and is left alone.
    enum Highlight: Equatable {
        case keyword
        case string
        case number
        case comment
    }

    /// Every coloured run of the text, in order and without overlap.
    ///
    /// Its own scanner rather than `SQLSourceMap.nextToken`, because the
    /// question is different: that one reads *past* comments and strings on
    /// its way to the next piece of code, and this one wants exactly where
    /// they start and stop.
    static func highlights(in text: String) -> [(range: NSRange, kind: Highlight)] {
        let units = Array(text.utf16)
        var runs: [(range: NSRange, kind: Highlight)] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            let start = index
            switch unit {
            case Ascii.dash where index + 1 < units.count && units[index + 1] == Ascii.dash:
                index += 2
                while index < units.count, units[index] != Ascii.newline { index += 1 }
                runs.append((NSRange(location: start, length: index - start), .comment))
            case Ascii.slash where index + 1 < units.count && units[index + 1] == Ascii.star:
                index += 2
                while index + 1 < units.count {
                    if units[index] == Ascii.star, units[index + 1] == Ascii.slash {
                        index += 2
                        break
                    }
                    index += 1
                }
                index = min(max(index, start + 2), units.count)
                runs.append((NSRange(location: start, length: index - start), .comment))
            case Ascii.quote:
                index = endOfLiteral(units, from: index)
                runs.append((NSRange(location: start, length: index - start), .string))
            case Ascii.doubleQuote, Ascii.backtick:
                // A quoted *name*, not a string: SQLite reads `"orders"` as an
                // identifier, so it wears the ordinary colour.
                index = endOfLiteral(units, from: index)
            case Ascii.openBracket:
                index = endOfLiteral(units, from: index, closing: Ascii.closeBracket)
            default:
                if isDigit(unit) {
                    index += 1
                    while index < units.count,
                          isDigit(units[index]) || units[index] == Ascii.dot { index += 1 }
                    runs.append((NSRange(location: start, length: index - start), .number))
                } else if isWord(unit) {
                    index += 1
                    while index < units.count, isWord(units[index]) { index += 1 }
                    let word = String(decoding: units[start..<index], as: UTF16.self)
                    if highlightKeywords.contains(word.uppercased()) {
                        runs.append((NSRange(location: start, length: index - start), .keyword))
                    }
                } else {
                    index += 1
                }
            }
        }
        return runs
    }

    /// Past the closing quote, with a doubled one inside taken as part of the
    /// text — `'it''s'` is one literal.
    private static func endOfLiteral(
        _ units: [UInt16], from index: Int, closing: UInt16? = nil
    ) -> Int {
        let closing = closing ?? units[index]
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

    /// The words drawn as keywords. Wider than the list the dropdown offers:
    /// a reader who pastes an `INSERT` in to look at it should see it coloured
    /// even though the box will refuse to run it.
    static let highlightKeywords: Set<String> = {
        var words = Set(keywords.flatMap { $0.split(separator: " ").map(String.init) })
        words.formUnion([
            "ABORT", "ACTION", "ADD", "AFTER", "ALL", "ALTER", "ALWAYS", "ANALYZE",
            "ATTACH", "AUTOINCREMENT", "BEFORE", "BEGIN", "BY", "CAST", "CHECK",
            "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE",
            "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
            "DATABASE", "DEFAULT", "DEFERRABLE", "DEFERRED", "DELETE", "DESC",
            "DETACH", "DO", "DROP", "EACH", "ESCAPE", "EXCEPT", "EXCLUSIVE",
            "EXISTS", "EXPLAIN", "FAIL", "FILTER", "FOLLOWING", "FOR", "FOREIGN",
            "FULL", "GENERATED", "GLOB", "IF", "IGNORE", "IMMEDIATE", "INDEX",
            "INDEXED", "INITIALLY", "INSERT", "INSTEAD", "INTERSECT", "INTO",
            "ISNULL", "KEY", "MATCH", "NATURAL", "NO", "NOTNULL", "NULLS", "OF",
            "OFFSET", "OUTER", "OVER", "PARTITION", "PLAN", "PRAGMA", "PRECEDING",
            "PRIMARY", "QUERY", "RAISE", "RANGE", "RECURSIVE", "REFERENCES",
            "REGEXP", "REINDEX", "RELEASE", "RENAME", "REPLACE", "RESTRICT",
            "RETURNING", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT", "SET",
            "TABLE", "TEMP", "TEMPORARY", "TIES", "TO", "TRANSACTION", "TRIGGER",
            "UNBOUNDED", "UNIQUE", "UPDATE", "USING", "VACUUM", "VALUES", "VIEW",
            "VIRTUAL", "WINDOW", "WITH", "WITHOUT",
        ])
        return words
    }()

    // MARK: - Characters

    private enum Ascii {
        static let newline: UInt16 = 10
        static let quote: UInt16 = 39
        static let doubleQuote: UInt16 = 34
        static let backtick: UInt16 = 96
        static let openBracket: UInt16 = 91
        static let closeBracket: UInt16 = 93
        static let dash: UInt16 = 45
        static let slash: UInt16 = 47
        static let star: UInt16 = 42
        static let dot: UInt16 = 46
        static let underscore: UInt16 = 95
        static let dollar: UInt16 = 36
    }

    /// The same rule `SQLSourceMap` reads names by: letters, digits, `_`, `$`
    /// and anything past ASCII, since a table may be called `наименования`.
    private static func isWord(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case Ascii.underscore, Ascii.dollar: true
        default: unit >= 0x80
        }
    }

    private static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }

    /// Whether typing this character is worth opening the dropdown for: a
    /// character a name is made of, or the dot that asks for a table's
    /// columns.
    static func opensSuggestions(_ character: Character) -> Bool {
        guard let unit = character.utf16.first, character.utf16.count == 1 else { return false }
        return isWord(unit) || unit == Ascii.dot
    }
}
