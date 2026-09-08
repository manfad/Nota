import Foundation

/// The query in the box, read closely enough to carry a rowid.
///
/// A page of a table carries the rowid of every row beside its values, which
/// is what a clicked cell is taken back to the `INSERT` that wrote it by
/// (`SQLSourceMap`). A query's result carried none: it is not a table, and
/// `SELECT name FROM customers` has nothing SQLite will call a rowid.
///
/// But the common query *is* a table read: one `SELECT`, one `FROM`, a
/// `WHERE` and an order under it. For that shape the rowid is there for the
/// asking — `SELECT customers.rowid, name FROM customers WHERE …` — and a
/// value in the grid can go back to its line the way a table's does. So the
/// text is read once, loosely, and if it is that shape the rowid is spliced
/// in after the `SELECT` keyword and nothing else about it is touched: the
/// reader's own columns, their own order, their own everything.
///
/// An `INNER JOIN` or `LEFT [OUTER] JOIN` chain reads the same way: each
/// result row still comes from exactly one row of the first `FROM` table, so
/// that table's rowid — its alias, when the reader gave it one — is spliced
/// in exactly as it is for a plain table read, and `Rewrite.table` stays the
/// `FROM` table. A `RIGHT`, `FULL`, `CROSS` or `NATURAL` join can hand back a
/// row with no match on that side, so those are left alone, along with a join
/// onto a sub-select in parentheses.
///
/// Loose on purpose, and refusing on purpose. Anything that is not plainly
/// one table's rows (or an inner/left join's worth of them) — a
/// comma-separated `FROM`, a `GROUP BY`, a `DISTINCT`, a `UNION`, an
/// aggregate, a `WITH`, a sub-select anywhere — is left alone and read as it
/// always was, with no rowids and a quiet grid.
/// The rewrite is an offer, never a requirement: it is prepared under the
/// same read-only authorizer as anything else typed in the box, and a rewrite
/// SQLite will not take is dropped without a word, since the reader asked for
/// their query and not for this one. That last part is load-bearing rather
/// than defensive — an alias in quotes (`FROM customers "c"`) is not read as
/// one here, so the rowid is asked of the table under a name the alias has
/// taken away, SQLite refuses it, and the query runs exactly as written.
enum SQLQueryRewrite {

    /// What the rowid rides in under. Two underscores and the app's name,
    /// because it stands beside columns the reader named and must not collide
    /// with one of them; it is taken back out before the grid sees the page.
    static let rowidColumn = "__nota_rowid"

    /// A query rewritten to carry its table's rowid, and the table those
    /// rowids belong to — the one a clicked row is looked up in.
    struct Rewrite: Equatable {
        let sql: String
        let table: String
    }

    /// The query with its rowid spliced in, or `nil` for anything that is not
    /// one plain table read.
    static func carryingRowid(_ query: String) -> Rewrite? {
        let units = Array(query.utf16)
        var index = 0
        guard let select = SQLSourceMap.nextToken(units, &index), select.kind == .word,
              select.text.lowercased() == "select"
        else { return nil }
        // Where the rowid goes: immediately after the keyword, so every
        // character the reader wrote stays where they wrote it.
        let splice = index

        var tokens: [SQLSourceMap.Token] = []
        var depths: [Int] = []
        var depth = 0
        while let token = SQLSourceMap.nextToken(units, &index) {
            if token.kind == .punctuation {
                if token.text == "(" { depth += 1 }
                if token.text == ")" { depth = max(0, depth - 1) }
            }
            tokens.append(token)
            depths.append(depth)
        }

        guard !tokens.contains(where: { isRefused($0) }),
              !hasAggregate(tokens), !hasPositionalOrder(tokens), !hasDisallowedJoin(tokens),
              let from = tokens.firstIndex(where: {
                  $0.kind == .word && $0.text.lowercased() == "from"
              }), depths[from] == 0
        else { return nil }

        // The table, and the name the rowid is asked of: the alias when the
        // reader gave one, since `FROM customers c` puts `customers` out of
        // reach of everything after it.
        var next = from + 1
        guard next < tokens.count, tokens[next].kind != .punctuation else { return nil }
        let table = tokens[next]
        var qualifier = table.text
        next += 1
        // `main.customers`, or anything else with a dot in it: left alone
        // rather than guessed at.
        if next < tokens.count, tokens[next].kind == .punctuation, tokens[next].text == "." {
            return nil
        }
        if next < tokens.count, tokens[next].kind == .word {
            let word = tokens[next].text.lowercased()
            if word == "as" {
                guard next + 1 < tokens.count, tokens[next + 1].kind != .punctuation else {
                    return nil
                }
                qualifier = tokens[next + 1].text
                next += 2
            } else if !endsTheTable(word) {
                qualifier = tokens[next].text
                next += 1
            }
        }
        // A second table — `FROM customers, orders` — is a comma before the
        // query's next clause. The commas of an `ORDER BY` or of a function's
        // arguments are past it or under it.
        while next < tokens.count {
            let token = tokens[next]
            if token.kind == .word, endsTheTable(token.text.lowercased()) { break }
            if token.kind == .punctuation, token.text == ",", depths[next] == 0 { return nil }
            next += 1
        }

        let head = String(decoding: units[0..<splice], as: UTF16.self)
        let tail = String(decoding: units[splice...], as: UTF16.self)
        let sql = head + " " + SQLDump.quote(qualifier) + ".rowid AS "
            + SQLDump.quote(rowidColumn) + "," + tail
        return Rewrite(sql: sql, table: table.text)
    }

    // MARK: - What is not one table's rows

    /// Words that say the result is not a table's rows however the rest of it
    /// reads: a set operation, a grouping, a sub-select, a window, a `WITH`
    /// inside. A `SELECT` after the first one is a sub-select — the first was
    /// taken before any of this. A join is not refused outright — an inner or
    /// left join is allowed — so it is checked on its own, by `hasDisallowedJoin`.
    private static let refused: Set<String> = [
        "distinct", "union", "intersect", "except", "group", "having",
        "select", "values", "window", "over", "with",
    ]

    /// The aggregates, which are only aggregates when they are called: a
    /// column named `total` or `count` is an ordinary column, and `orders`
    /// has one.
    private static let aggregates: Set<String> = [
        "count", "sum", "avg", "min", "max", "total", "group_concat",
    ]

    /// Where the `FROM` item ends and the rest of the query begins — so the
    /// word after a table is an alias only when it is none of these.
    private static let clauses: Set<String> = [
        "where", "order", "limit", "offset", "group", "having", "window",
        "union", "intersect", "except", "returning", "join", "on", "using",
        "inner", "left", "right", "full", "cross", "natural", "indexed", "not",
    ]

    private static func isRefused(_ token: SQLSourceMap.Token) -> Bool {
        token.kind == .word && refused.contains(token.text.lowercased())
    }

    /// `ORDER BY 2` counts the columns of the select list, and the rewrite
    /// puts a column in front of them: the reader's second column would
    /// quietly become their first. A query that orders by a number is left
    /// exactly as it was written.
    private static func hasPositionalOrder(_ tokens: [SQLSourceMap.Token]) -> Bool {
        for (index, token) in tokens.enumerated() {
            guard token.kind == .word, token.text.lowercased() == "order",
                  index + 2 < tokens.count,
                  tokens[index + 1].kind == .word,
                  tokens[index + 1].text.lowercased() == "by"
            else { continue }
            let term = tokens[index + 2]
            if term.kind == .word, term.text.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The join qualifiers that can sit in front of the `JOIN` keyword itself,
    /// walked backwards from it to read `LEFT OUTER JOIN`, `NATURAL JOIN` and
    /// the rest as one unit rather than one word at a time.
    private static let joinQualifiers: Set<String> = [
        "inner", "left", "right", "full", "cross", "natural", "outer",
    ]

    /// The joins whose result can hold a row with no match on one side —
    /// `RIGHT`, `FULL`, `CROSS`, `NATURAL` — are not one row of the `FROM`
    /// table per result row, and neither is a join onto a sub-select in
    /// parentheses. `[INNER] JOIN` and `LEFT [OUTER] JOIN` are the only ones
    /// left alone.
    private static func hasDisallowedJoin(_ tokens: [SQLSourceMap.Token]) -> Bool {
        for (index, token) in tokens.enumerated() {
            guard token.kind == .word, token.text.lowercased() == "join" else { continue }
            if index + 1 < tokens.count, tokens[index + 1].kind == .punctuation,
               tokens[index + 1].text == "(" {
                return true
            }
            var back = index - 1
            while back >= 0, tokens[back].kind == .word,
                  joinQualifiers.contains(tokens[back].text.lowercased()) {
                let word = tokens[back].text.lowercased()
                if word == "right" || word == "full" || word == "cross" || word == "natural" {
                    return true
                }
                back -= 1
            }
        }
        return false
    }

    private static func hasAggregate(_ tokens: [SQLSourceMap.Token]) -> Bool {
        for (index, token) in tokens.enumerated() {
            guard token.kind == .word, aggregates.contains(token.text.lowercased()),
                  index + 1 < tokens.count
            else { continue }
            let next = tokens[index + 1]
            if next.kind == .punctuation, next.text == "(" { return true }
        }
        return false
    }

    private static func endsTheTable(_ word: String) -> Bool { clauses.contains(word) }
}
