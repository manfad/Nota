import Foundation

/// The handful of spellings a `mysqldump`, phpMyAdmin or `pg_dump` export
/// carries that are not SQLite's own — turned into what SQLite's parser
/// takes, before `sqlite3_prepare_v2` ever sees them.
///
/// Almost none of a dump needs this. The bulk of it is `INSERT` and
/// `COPY … FROM stdin`, and both are read exactly for the data in them.
/// Everything else this file looks at is either session state the
/// exporting client sends that SQLite has no equivalent for and that
/// carries no data at all (`SET …`, `LOCK`/`UNLOCK TABLES`, `USE …`,
/// `\connect`, `GRANT`/`REVOKE`, a `SELECT` of `pg_catalog.set_config` or
/// `.setval`), a transaction verb spelled its own way (`START TRANSACTION`,
/// where SQLite wants `BEGIN`), an object SQLite has no notion of at all
/// (`CREATE EXTENSION`, `CREATE SEQUENCE`, `ALTER … OWNER TO`, adding a
/// constraint after the fact), or `CREATE TABLE`/`CREATE INDEX`, whose
/// column, table and index decorations are the one place either dialect's
/// grammar and SQLite's genuinely disagree. `COMMIT` needs nothing —
/// SQLite already understands it — and MySQL's `/*!40101 … */` conditional
/// comments need nothing either: SQLite's own tokenizer already treats
/// `/* … */` as a comment whatever is inside it, so the statement left
/// behind is a bare `;`, which prepares to nothing and runs to nothing.
enum SQLDumpDialect {

    /// What `SQLDump` should do with a statement, once this file has had a
    /// look at it.
    enum Action: Equatable {
        /// Run nothing. Session state, a privilege grant, an extension or a
        /// constraint added after the fact — none of it is data, and SQLite
        /// has no equivalent for most of it anyway.
        case skip
        /// Run this text instead of what was written: a `CREATE TABLE` or
        /// `CREATE INDEX` with its decoration taken off, or a transaction
        /// verb spelled differently.
        case rewrite(String)
        /// Run the statement exactly as it was written — nothing here
        /// applies to it.
        case run
    }

    /// Whether a statement's leading keyword is one this file has an
    /// opinion about at all. `SQLDump`'s run loop calls this on every
    /// statement before doing anything else, so it has to be cheap: it
    /// reads the first word off the raw buffer and nothing more, without
    /// finding the statement's extent or materialising the rest of it.
    /// `COPY` is not among them — it is not one statement at all, and
    /// `SQLDump` looks for it on its own before this is ever asked.
    static func handles(_ leadingKeyword: String) -> Bool {
        switch leadingKeyword {
        case "SET", "USE", "LOCK", "UNLOCK", "START", "CREATE", "ALTER",
             "SELECT", "GRANT", "REVOKE", "INSERT", "COMMENT": true
        default: false
        }
    }

    /// The first ASCII word at `cursor`, upper-cased, without moving it or
    /// reading past it. `""` for anything that does not start with a
    /// letter — a psql meta-command's leading backslash among them, which
    /// is why `SQLDump` looks for those on its own rather than through this.
    ///
    /// Bounded at twenty characters on purpose: the longest word this file
    /// ever compares against is `TRANSACTION`, and a runaway word past that
    /// is not a keyword this is going to recognise however far it reads.
    static func leadingKeyword(at cursor: UnsafePointer<CChar>) -> String {
        var end = cursor
        var count = 0
        while count < 20, isASCIILetter(end.pointee) {
            end += 1
            count += 1
        }
        guard count > 0 else { return "" }
        return string(from: cursor, to: end).uppercased()
    }

    /// The end of the statement that starts at `cursor` — just past its
    /// terminating `;`, or the end of the text when it never finds one.
    ///
    /// Called for every keyword `handles` answers yes to, and for two
    /// different reasons: a statement like `SET` or `GRANT` will not even
    /// prepare, so SQLite can hand back no tail to say where it ends; and a
    /// `CREATE TABLE` is about to be rewritten, so the tail
    /// `sqlite3_prepare_v2` would give the *rewritten* text is not a
    /// position in the file at all. Either way `SQLSourceMap` needs the
    /// file's own offsets, and this is where they come from — found by the
    /// same rules as SQLite's own tokenizer for what is not code (a `--` or
    /// `/* */` comment, a string or a quoted name) rather than by SQLite's
    /// parser, which is exactly the trade this file exists to make.
    ///
    /// `mysqlDetected` matters here for the same reason it matters to
    /// `action`: a `'…'` or `"…"` in a MySQL dump can hold a backslash-
    /// escaped quote (`'Daniel O\'Brien'`) that is not the string's own end,
    /// and standard SQL's doubling rule alone would stop this scan there —
    /// mid-string, and usually mid-`INSERT` — leaving every statement after
    /// it read from the wrong place. A quoted name never uses backslash
    /// escapes even in a MySQL dump (backtick doubles its own backtick to
    /// escape one), so only `'` and `"` read this way, and only once the
    /// file has shown itself to be MySQL's own.
    static func statementExtent(
        from cursor: UnsafePointer<CChar>, mysqlDetected: Bool = false
    ) -> UnsafePointer<CChar> {
        var cursor = cursor
        while cursor.pointee != 0 {
            switch cursor.pointee {
            case 59:  // ;
                return cursor + 1
            case 39, 34, 96:  // ' " `
                let quote = cursor.pointee
                let backslashEscapes = mysqlDetected && quote != 96
                cursor += 1
                while cursor.pointee != 0 {
                    if backslashEscapes, cursor.pointee == 92 {  // \
                        cursor += 1
                        if cursor.pointee != 0 { cursor += 1 }
                        continue
                    }
                    if cursor.pointee == quote {
                        cursor += 1
                        if cursor.pointee == quote { cursor += 1; continue }
                        break
                    }
                    cursor += 1
                }
            case 45 where cursor[1] == 45:  // --
                cursor += 2
                while cursor.pointee != 0, cursor.pointee != 10 { cursor += 1 }
            case 47 where cursor[1] == 42:  // /*
                cursor += 2
                while cursor.pointee != 0,
                      !(cursor.pointee == 42 && cursor[1] == 47) { cursor += 1 }
                if cursor.pointee != 0 { cursor += 2 }
            default:
                cursor += 1
            }
        }
        return cursor
    }

    /// The bytes from `cursor` up to (not including) `end`, decoded as
    /// UTF-8 — one statement's own text, copied out of the C buffer once it
    /// is known where the statement ends.
    static func string(from cursor: UnsafePointer<CChar>, to end: UnsafePointer<CChar>) -> String {
        let length = cursor.distance(to: end)
        return cursor.withMemoryRebound(to: UInt8.self, capacity: max(length, 1)) { pointer in
            String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
        }
    }

    /// Whether an `INSERT` between `cursor` and `end` could possibly need
    /// `action`'s closer look — a byte scan of the raw buffer, cheap enough
    /// to run on every row of a dump that is nothing but `INSERT`s, unlike
    /// `string(from:to:)` and the tokenising `action` itself does, which are
    /// not.
    ///
    /// An `INSERT` only ever becomes an `Action.rewrite` two ways: a
    /// `public.` schema prefix (Postgres), or — once the dump has shown
    /// itself MySQL — a backslash in one of its string literals. Neither
    /// needs a token to find, just the bytes themselves, so a plain
    /// `INSERT` with neither is told apart from one that might need
    /// rewriting without ever being turned into a `String` at all: it falls
    /// straight through to the ordinary prepare/tail path below, exactly as
    /// an unhandled statement does.
    static func mayNeedRewrite(
        from cursor: UnsafePointer<CChar>, to end: UnsafePointer<CChar>, mysqlDetected: Bool
    ) -> Bool {
        var p = cursor
        while p != end {
            if mysqlDetected, p.pointee == 92 { return true }  // \
            if p.pointee == 112 {  // p — the one byte "public." starts with
                var q = p
                var matched = true
                for byte: CChar in [112, 117, 98, 108, 105, 99, 46] {  // "public."
                    guard q != end, q.pointee == byte else { matched = false; break }
                    q += 1
                }
                if matched { return true }
            }
            p += 1
        }
        return false
    }

    /// What to do with one statement's own text. Only called once `handles`
    /// has already said its leading word is worth a closer look — this is
    /// the closer look, and it is where a keyword match can still turn out
    /// to mean nothing (`LOCK` that is not `LOCK TABLES`, `CREATE` that is
    /// not a `TABLE`, `INDEX`, `EXTENSION` or `SEQUENCE`) and fall back to
    /// running the statement exactly as written, `public.` schema prefixes
    /// stripped and MySQL's own backslash escapes decoded when either was
    /// found.
    ///
    /// `mysqlDetected` is `SQLDump`'s own running answer to "has this file
    /// shown itself to be a MySQL dump yet" (see `looksLikeMySQL`) — a
    /// statement is only ever decoded once the dump has already proven
    /// itself MySQL's own, because standard SQL has no backslash escapes at
    /// all, and running the decoder over a `pg_dump` statement (where `\`
    /// is just a character) would corrupt exactly the strings it meant to
    /// fix.
    static func action(for statement: String, mysqlDetected: Bool) -> Action {
        let base = (mysqlDetected && statement.utf8.contains(92))
            ? decodeMySQLBackslashEscapes(statement) : statement
        let changed = base != statement
        let units = Array(base.utf16)
        var index = 0
        guard let first = SQLSourceMap.nextToken(units, &index), first.kind == .word else {
            return changed ? .rewrite(base) : .run
        }
        switch first.text.uppercased() {
        case "SET", "USE":
            return .skip
        case "LOCK", "UNLOCK":
            return isWord(units, index, "TABLES") ? .skip : (changed ? .rewrite(base) : .run)
        case "START":
            return isWord(units, index, "TRANSACTION") ? .rewrite("BEGIN;")
                : (changed ? .rewrite(base) : .run)
        case "GRANT", "REVOKE":
            return .skip
        case "COMMENT":
            return isWord(units, index, "ON") ? .skip : (changed ? .rewrite(base) : .run)
        case "SELECT":
            return isPgCatalogHelperCall(base) ? .skip : (changed ? .rewrite(base) : .run)
        case "INSERT":
            let destemmed = stripPublicSchema(base)
            return destemmed == statement ? .run : .rewrite(destemmed)
        case "ALTER":
            return alterAction(for: base, alreadyChanged: changed)
        case "CREATE":
            return createAction(for: base, alreadyChanged: changed)
        default:
            return changed ? .rewrite(base) : .run
        }
    }

    /// `CREATE TABLE`, `CREATE INDEX`, `CREATE EXTENSION` and `CREATE
    /// SEQUENCE` each read differently; every other `CREATE` — a view, a
    /// database — is not this file's to touch beyond stripping `public.`
    /// wherever pg_dump wrote one. `alreadyChanged` is whether `statement`
    /// already differs from the file's own text before this looks at it —
    /// MySQL's backslash escapes, decoded by the caller — so the fallback
    /// still rewrites rather than answers `.run` with text that is not
    /// what the file actually wrote.
    private static func createAction(for statement: String, alreadyChanged: Bool) -> Action {
        let destemmed = stripPublicSchema(statement)
        let changed = alreadyChanged || destemmed != statement
        if let rewritten = rewriteCreateTable(destemmed) { return .rewrite(rewritten) }
        if let rewritten = rewriteCreateIndex(destemmed) { return .rewrite(rewritten) }
        if matchesCreateKind(destemmed, "EXTENSION") || matchesCreateKind(destemmed, "SEQUENCE") {
            return .skip
        }
        return changed ? .rewrite(destemmed) : .run
    }

    /// `ALTER TABLE [ONLY] t OWNER TO …` and `ALTER TABLE [ONLY] t ADD
    /// CONSTRAINT … PRIMARY KEY|FOREIGN KEY …` — pg_dump's own way of
    /// naming an owner and of adding a table's constraints after every row
    /// is already in it — neither of which SQLite can run as written, and
    /// neither of which loses anything by being skipped: the rows are
    /// already there, and a table `SQLDump` only ever reads does not need
    /// an owner or a constraint enforced on it. `ALTER SEQUENCE … OWNED BY
    /// …` is the same kind of bookkeeping, for a sequence this file never
    /// created in the first place.
    ///
    /// Anything else under `ALTER` is not one of pg_dump's own — it falls
    /// back to running as written, `public.` stripped where one was found.
    /// `alreadyChanged` is whether `statement` already differs from the
    /// file's own text before this looks at it — MySQL's backslash escapes,
    /// decoded by the caller.
    private static func alterAction(for statement: String, alreadyChanged: Bool) -> Action {
        // Destemmed first, and structurally read from that same destemmed
        // text throughout: `ALTER TABLE public.orders OWNER TO …` has
        // `public`, `.` and `orders` as three separate tokens until this
        // runs, and reading the table name as a single token — which is
        // all the checks below need it for — only works once it is one.
        let destemmed = stripPublicSchema(statement)
        let changed = alreadyChanged || destemmed != statement
        let fallback: Action = changed ? .rewrite(destemmed) : .run
        let units = Array(destemmed.utf16)
        var index = 0
        _ = SQLSourceMap.nextToken(units, &index)  // ALTER
        guard let kind = SQLSourceMap.nextToken(units, &index), kind.kind == .word else {
            return fallback
        }
        switch kind.text.uppercased() {
        case "TABLE":
            var probe = index
            if let only = SQLSourceMap.nextToken(units, &probe), only.kind == .word,
               only.text.uppercased() == "ONLY" {
                index = probe
            }
            guard SQLSourceMap.nextToken(units, &index) != nil else { return fallback }
            guard let verb = SQLSourceMap.nextToken(units, &index), verb.kind == .word else {
                return fallback
            }
            switch verb.text.uppercased() {
            case "OWNER":
                return isWord(units, index, "TO") ? .skip : fallback
            case "ALTER":
                // `ALTER TABLE ONLY t ALTER COLUMN id SET DEFAULT
                // nextval(…);` — the column already has whatever `CREATE
                // TABLE` gave it; a sequence-backed default added this way
                // is bookkeeping pg_dump does after the fact, the same as
                // `OWNER TO` and a constraint added later.
                guard let column = SQLSourceMap.nextToken(units, &index), column.kind == .word,
                      column.text.uppercased() == "COLUMN" else { return fallback }
                _ = SQLSourceMap.nextToken(units, &index)  // the column's own name
                guard let set = SQLSourceMap.nextToken(units, &index), set.kind == .word,
                      set.text.uppercased() == "SET" else { return fallback }
                return isWord(units, index, "DEFAULT") ? .skip : fallback
            case "ADD":
                guard let next = SQLSourceMap.nextToken(units, &index), next.kind == .word,
                      next.text.uppercased() == "CONSTRAINT" else { return fallback }
                _ = SQLSourceMap.nextToken(units, &index)  // the constraint's own name
                guard let ckind = SQLSourceMap.nextToken(units, &index), ckind.kind == .word
                else { return fallback }
                switch ckind.text.uppercased() {
                case "PRIMARY", "FOREIGN":
                    return isWord(units, index, "KEY") ? .skip : fallback
                case "UNIQUE":
                    return .skip
                default:
                    return fallback
                }
            default:
                return fallback
            }
        case "SEQUENCE":
            // `ALTER SEQUENCE s OWNER TO …` and `ALTER SEQUENCE s OWNED BY
            // t.c` — a sequence's own owner, the same bookkeeping a
            // table's is, and which table's column it counts for, which
            // this file never needs since it never created the sequence in
            // the first place.
            guard SQLSourceMap.nextToken(units, &index) != nil else { return fallback }
            guard let verb = SQLSourceMap.nextToken(units, &index), verb.kind == .word else {
                return fallback
            }
            switch verb.text.uppercased() {
            case "OWNED":
                return isWord(units, index, "BY") ? .skip : fallback
            case "OWNER":
                return isWord(units, index, "TO") ? .skip : fallback
            default:
                return fallback
            }
        default:
            return fallback
        }
    }

    /// Whether this is `SELECT pg_catalog.set_config(…)` or `SELECT
    /// pg_catalog.setval(…)` — the two housekeeping calls pg_dump writes
    /// bare, outside any `COPY`, to set a session variable or to leave a
    /// sequence where the dump found it. Neither reads a table, and neither
    /// is a function SQLite has, so both are skipped rather than run.
    private static func isPgCatalogHelperCall(_ statement: String) -> Bool {
        let units = Array(statement.utf16)
        var index = 0
        guard let select = SQLSourceMap.nextToken(units, &index), select.kind == .word,
              select.text.uppercased() == "SELECT" else { return false }
        guard let schema = SQLSourceMap.nextToken(units, &index), schema.kind == .word,
              schema.text.uppercased() == "PG_CATALOG" else { return false }
        guard let dot = SQLSourceMap.nextToken(units, &index), dot.kind == .punctuation,
              dot.text == "." else { return false }
        guard let function = SQLSourceMap.nextToken(units, &index), function.kind == .word
        else { return false }
        let name = function.text.uppercased()
        return name == "SET_CONFIG" || name == "SETVAL"
    }

    /// Whether the next token from `index` is this word, case-insensitively.
    /// A look, not a move: `index` is a copy, so a caller that gets `false`
    /// has not lost its place.
    private static func isWord(_ units: [UInt16], _ index: Int, _ word: String) -> Bool {
        var index = index
        guard let token = SQLSourceMap.nextToken(units, &index), token.kind == .word else {
            return false
        }
        return token.text.uppercased() == word
    }

    // MARK: - Telling MySQL from everything else

    /// Whether `statement` is one of the handful of things only a
    /// `mysqldump`/phpMyAdmin export ever writes: `LOCK TABLES …`, a `SET`
    /// of a MySQL-only session variable (`NAMES`, `SQL_MODE`, `CHARACTER
    /// SET`, `GLOBAL`, `SESSION`) rather than the generic ones every dialect
    /// uses, or a `CREATE TABLE` carrying `ENGINE=`. Any one of them, seen
    /// once, is enough for `SQLDump` to start decoding backslash escapes in
    /// every statement after it — a plain `SET client_encoding = 'UTF8'` on
    /// its own says nothing, `pg_dump` writes those too, which is why this
    /// asks for more than just "a `SET`".
    static func looksLikeMySQL(_ statement: String) -> Bool {
        let units = Array(statement.utf16)
        var index = 0
        guard let first = SQLSourceMap.nextToken(units, &index), first.kind == .word else {
            return false
        }
        switch first.text.uppercased() {
        case "LOCK":
            return true
        case "SET":
            guard let next = SQLSourceMap.nextToken(units, &index), next.kind == .word else {
                return false
            }
            switch next.text.uppercased() {
            case "NAMES", "SQL_MODE", "CHARACTER", "GLOBAL", "SESSION": return true
            default: return false
            }
        case "CREATE":
            guard let table = SQLSourceMap.nextToken(units, &index), table.kind == .word,
                  table.text.uppercased() == "TABLE" else { return false }
            return statement.range(of: "ENGINE", options: [.caseInsensitive]) != nil
        default:
            return false
        }
    }

    /// `statement`'s own string literals with MySQL's backslash escapes
    /// resolved into what SQLite's parser takes: `\'` becomes `''` —
    /// SQLite's own way to embed a quote — and `\\`, `\"`, `\n`, `\r` and
    /// `\t` become the character they stand for. A backslash in front of
    /// anything else this file does not specifically know is dropped and
    /// the character taken literally, MySQL's own rule for it too — except
    /// `\0`, which is dropped outright rather than written as a raw NUL
    /// byte: this text is handed to `sqlite3_prepare_v2` as a C string, and
    /// an embedded NUL would truncate it right there, silently, however
    /// much of the statement was still to come.
    ///
    /// Only single-quoted strings are read this way — a bare `mysqldump`
    /// INSERT never writes a double-quoted one — so a backtick-quoted
    /// identifier or a bare keyword is stepped over untouched; nothing
    /// outside a `'…'` is looked at at all.
    static func decodeMySQLBackslashEscapes(_ statement: String) -> String {
        var result = ""
        result.reserveCapacity(statement.count)
        var inString = false
        var iterator = statement.makeIterator()
        while let character = iterator.next() {
            if inString, character == "\\" {
                guard let next = iterator.next() else {
                    result.append(character)
                    break
                }
                switch next {
                case "'": result.append("''")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "0": break
                case "Z": result.append(Character(UnicodeScalar(0x1A)))
                default: result.append(next)
                }
                continue
            }
            if character == "'" { inString.toggle() }
            result.append(character)
        }
        return result
    }

    // MARK: - Shared token scanning

    /// One token of a statement, with the exact span of the original text
    /// it came from — leading blanks and comments included, so that
    /// consecutive tokens' ranges tile the text with no gap and no overlap.
    /// That is what makes dropping or replacing a token safe: the
    /// whitespace in front of the *next* kept token is that token's own,
    /// not the one before it, so touching a run of tokens never joins two
    /// words together and never leaves a doubled-up separator behind — it
    /// just closes the gap where they were, or puts something else there.
    private struct Scanned {
        let range: Range<Int>
        let token: SQLSourceMap.Token
    }

    private static func scan(_ units: [UInt16]) -> [Scanned] {
        var index = 0
        var tokens: [Scanned] = []
        while true {
            let start = index
            guard let token = SQLSourceMap.nextToken(units, &index) else { break }
            tokens.append(Scanned(range: start..<index, token: token))
        }
        return tokens
    }

    private static func text(_ units: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    /// `tokens`, reassembled with `replacements` applied: a token at an
    /// index the dictionary answers for is replaced by that text (`""` to
    /// drop it outright, a leading space kept in front of anything put back
    /// in its place so it never runs into the token before it); every other
    /// token keeps its own original text, spacing included.
    private static func rebuild(
        _ tokens: [Scanned], _ units: [UInt16], replacing replacements: [Int: String]
    ) -> String {
        var result = ""
        for (index, scanned) in tokens.enumerated() {
            result += replacements[index] ?? text(units, scanned.range)
        }
        return result
    }

    /// Every `public.name` in the statement with the schema taken off —
    /// pg_dump's own habit of schema-qualifying a table it dumps, wherever
    /// it appears: the table itself, a `REFERENCES` clause, a `COPY`'s or
    /// an `INSERT`'s target. SQLite has no `public` database attached, so
    /// left in, any of these would fail with "unknown database public"
    /// rather than run.
    static func stripPublicSchema(_ statement: String) -> String {
        let units = Array(statement.utf16)
        let tokens = scan(units)
        var replacements: [Int: String] = [:]
        var i = 0
        while i < tokens.count {
            if tokens[i].token.kind == .word, tokens[i].token.text.uppercased() == "PUBLIC",
               i + 1 < tokens.count, tokens[i + 1].token.kind == .punctuation,
               tokens[i + 1].token.text == ".",
               i + 2 < tokens.count, tokens[i + 2].token.kind != .punctuation {
                replacements[i] = " "
                replacements[i + 1] = " "
                i += 2
                continue
            }
            i += 1
        }
        guard !replacements.isEmpty else { return statement }
        return rebuild(tokens, units, replacing: replacements)
    }

    private static func isASCIILetter(_ byte: CChar) -> Bool {
        let value = UInt8(bitPattern: byte)
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    // MARK: - CREATE TABLE

    /// A `CREATE TABLE` with its MySQL or PostgreSQL decoration taken off:
    /// everything after the column list's own closing paren
    /// (`ENGINE=InnoDB …`, gone wholesale), the index lines inside the list
    /// SQLite has no equivalent for (`KEY`, `UNIQUE KEY`, `INDEX`,
    /// `FULLTEXT KEY` …, dropped whole), and — column by column — whatever
    /// `rewriteColumnOrConstraint` finds to take off or rewrite.
    /// `PRIMARY KEY (…)`, a bare `UNIQUE (…)`, a `CHECK` and a `FOREIGN KEY`
    /// (with or without a `CONSTRAINT` name) are passed through exactly as
    /// written, which is already what SQLite's own grammar takes.
    ///
    /// `nil` for a statement that does not read as a `CREATE TABLE`, or
    /// whose column list's own parentheses do not balance — the caller runs
    /// the statement exactly as written rather than guess at one, which
    /// fails in exactly the way an unrecognised statement always has.
    private static func rewriteCreateTable(_ statement: String) -> String? {
        let units = Array(statement.utf16)
        let tokens = scan(units)

        func word(_ index: Int) -> String? {
            guard index < tokens.count, tokens[index].token.kind == .word else { return nil }
            return tokens[index].token.text.uppercased()
        }

        var i = 0
        guard word(i) == "CREATE" else { return nil }
        i += 1
        if word(i) == "TEMP" || word(i) == "TEMPORARY" { i += 1 }
        guard word(i) == "TABLE" else { return nil }
        i += 1
        if word(i) == "IF", word(i + 1) == "NOT", word(i + 2) == "EXISTS" { i += 3 }

        // Past the table name — with whatever quoting it is written with —
        // to the column list's own opening paren. Nothing legal appears
        // here that has a `(` of its own, so the first one found is the
        // right one.
        while i < tokens.count,
              !(tokens[i].token.kind == .punctuation && tokens[i].token.text == "(") {
            i += 1
        }
        guard i < tokens.count else { return nil }
        let openIndex = i
        let prefix = text(units, 0..<tokens[openIndex].range.upperBound)

        // The matching close: every `(` and `)` from here counts, so a
        // type's own parentheses (`varchar(100)`, `numeric(10,2)`) do not
        // end the list early.
        var depth = 1
        let bodyStart = openIndex + 1
        i = bodyStart
        var closeIndex: Int?
        while i < tokens.count {
            if tokens[i].token.kind == .punctuation {
                if tokens[i].token.text == "(" {
                    depth += 1
                } else if tokens[i].token.text == ")" {
                    depth -= 1
                    if depth == 0 { closeIndex = i; break }
                }
            }
            i += 1
        }
        guard let bodyEnd = closeIndex, bodyEnd >= bodyStart else { return nil }

        let items = splitItems(tokens, from: bodyStart, to: bodyEnd, units: units)
        let kept = items.compactMap(rewriteItem)
        guard !kept.isEmpty else { return nil }
        // Everything MySQL wrote after the column list — `ENGINE=InnoDB`,
        // `AUTO_INCREMENT=4`, `DEFAULT CHARSET=…`, `COLLATE=…` — goes
        // wholesale, none of it SQLite takes at all. `WITHOUT ROWID` and
        // `STRICT` are not MySQL's: they are SQLite's own table options, and
        // a dump that already read as SQLite's own is not the one this file
        // exists for, but there is no reason to break it either.
        let options = tableOptions(tokens, from: bodyEnd + 1, units: units)
        let suffix = options.isEmpty ? "" : " " + options
        return prefix + kept.joined(separator: ",") + ")" + suffix + ";"
    }

    /// Which of the words after the column list's own closing paren are
    /// SQLite's `WITHOUT ROWID` and `STRICT` — kept exactly as SQLite
    /// spells them — with everything else, MySQL's own table options among
    /// it, left out.
    private static func tableOptions(_ tokens: [Scanned], from start: Int, units: [UInt16]) -> String {
        var kept: [String] = []
        var i = start
        while i < tokens.count {
            if tokens[i].token.kind == .word {
                let upper = tokens[i].token.text.uppercased()
                if upper == "WITHOUT", isWordAt(tokens, i + 1, "ROWID") {
                    kept.append("WITHOUT ROWID")
                    i += 2
                    continue
                }
                if upper == "STRICT" {
                    kept.append("STRICT")
                    i += 1
                    continue
                }
            }
            i += 1
        }
        return kept.joined(separator: ", ")
    }

    /// The column list's own items — one per column definition or table
    /// constraint — split at the commas between them. A comma inside a
    /// type's own parentheses (`decimal(10,2)`, `numeric(10,2)`) is not one
    /// of them: depth is counted the same way the outer parentheses were
    /// found.
    private static func splitItems(
        _ tokens: [Scanned], from bodyStart: Int, to bodyEnd: Int, units: [UInt16]
    ) -> [String] {
        guard bodyStart < bodyEnd else { return [] }
        var items: [String] = []
        var depth = 0
        var itemStart = tokens[bodyStart].range.lowerBound
        var i = bodyStart
        while i < bodyEnd {
            let token = tokens[i].token
            if token.kind == .punctuation {
                if token.text == "(" {
                    depth += 1
                } else if token.text == ")" {
                    depth -= 1
                } else if token.text == "," && depth == 0 {
                    items.append(text(units, itemStart..<tokens[i].range.lowerBound))
                    itemStart = tokens[i].range.upperBound
                    i += 1
                    continue
                }
            }
            i += 1
        }
        items.append(text(units, itemStart..<tokens[bodyEnd].range.lowerBound))
        return items
    }

    /// One item of the column list, kept, dropped, or rewritten:
    /// - `KEY`/`INDEX` (and `UNIQUE KEY`/`UNIQUE INDEX`) are dropped only
    ///   when they are actually *shaped* like an index — see
    ///   `looksLikeIndexLine`. `key` is a legal unquoted column name in
    ///   SQLite (a `settings (key TEXT, value TEXT)` table is an ordinary
    ///   one), and `key varchar(20)` reads as a column for the same reason
    ///   `key TEXT` does — the two are told apart by what stands after the
    ///   word, not by the word itself.
    /// - `FULLTEXT` and `SPATIAL` lines are always dropped — MySQL never
    ///   lets either be a bare column name, so there is no shape to check.
    /// - A bare `UNIQUE (…)` is not dropped — that is already SQLite's own
    ///   table constraint.
    /// - A `CHECK`, named or not, that reads `ANY`/`ARRAY` anywhere in it
    ///   is dropped — SQLite has neither, and the constraint pg_dump wrote
    ///   with them will not run as written (see `hasAnyArrayKeyword`); a
    ///   `CHECK` without either is passed through, along with `PRIMARY KEY
    ///   (…)` and a `FOREIGN KEY` (with or without a `CONSTRAINT` name).
    /// - Anything else is a column definition, and goes through
    ///   `rewriteColumnOrConstraint`.
    ///
    /// `nil` only for the lines that are dropped outright — never for a
    /// column, which always has something worth keeping.
    private static func rewriteItem(_ item: String) -> String? {
        let units = Array(item.utf16)
        let tokens = scan(units)
        guard let firstIndex = tokens.firstIndex(where: { $0.token.kind != .punctuation })
        else { return item }

        func word(_ index: Int) -> String? {
            guard index < tokens.count, tokens[index].token.kind == .word else { return nil }
            return tokens[index].token.text.uppercased()
        }

        switch word(firstIndex) {
        case "KEY", "INDEX":
            return looksLikeIndexLine(tokens, keywordIndex: firstIndex)
                ? nil : rewriteColumnOrConstraint(item, tokens: tokens, units: units)
        case "FULLTEXT", "SPATIAL":
            return nil
        case "UNIQUE":
            let next = word(firstIndex + 1)
            guard next == "KEY" || next == "INDEX" else { return item }
            return looksLikeIndexLine(tokens, keywordIndex: firstIndex + 1)
                ? nil : rewriteColumnOrConstraint(item, tokens: tokens, units: units)
        case "CHECK":
            return hasAnyArrayKeyword(tokens, from: firstIndex) ? nil : item
        case "CONSTRAINT":
            return isCheckWithAnyArray(tokens, constraintIndex: firstIndex) ? nil : item
        case "PRIMARY", "FOREIGN":
            return item
        default:
            return rewriteColumnOrConstraint(item, tokens: tokens, units: units)
        }
    }

    /// Whether `KEY`/`INDEX` at `keywordIndex` (already past any `UNIQUE`)
    /// actually reads as an index rather than as a column happening to be
    /// named `key`: the word right after it is either `(` on its own
    /// (`KEY (…)`), or a name — the index's own — immediately followed by
    /// `(` whose *first* token is itself a name rather than a number. A
    /// number there is a type's own size (`key varchar(20)`), which makes
    /// the line a column regardless of what its name happens to be.
    private static func looksLikeIndexLine(_ tokens: [Scanned], keywordIndex: Int) -> Bool {
        var i = keywordIndex + 1
        guard i < tokens.count else { return false }
        if tokens[i].token.kind == .punctuation, tokens[i].token.text == "(" { return true }
        guard tokens[i].token.kind == .word || tokens[i].token.kind == .quoted else { return false }
        i += 1
        guard i < tokens.count, tokens[i].token.kind == .punctuation, tokens[i].token.text == "("
        else { return false }
        i += 1
        guard i < tokens.count else { return false }
        let inside = tokens[i].token
        let isNumber = inside.kind == .word && !inside.text.isEmpty && inside.text.allSatisfy(\.isNumber)
        return !isNumber
    }

    /// Whether a bare `CHECK` reads `ANY` or `ARRAY` anywhere past it — the
    /// two keywords SQLite's grammar has neither of, and the reason pg_dump's
    /// own `CHECK ((status = ANY (ARRAY[…])))` will not run as written.
    private static func hasAnyArrayKeyword(_ tokens: [Scanned], from checkIndex: Int) -> Bool {
        var i = checkIndex + 1
        while i < tokens.count {
            if tokens[i].token.kind == .word {
                let upper = tokens[i].token.text.uppercased()
                if upper == "ANY" || upper == "ARRAY" { return true }
            }
            i += 1
        }
        return false
    }

    /// The same question for a *named* `CONSTRAINT name CHECK (…)` —
    /// `constraintIndex` is `CONSTRAINT` itself, and the name in between is
    /// stepped over before `hasAnyArrayKeyword` looks at the rest.
    private static func isCheckWithAnyArray(_ tokens: [Scanned], constraintIndex: Int) -> Bool {
        var i = constraintIndex + 1
        guard i < tokens.count else { return false }
        i += 1  // the constraint's own name
        guard i < tokens.count, tokens[i].token.kind == .word,
              tokens[i].token.text.uppercased() == "CHECK" else { return false }
        return hasAnyArrayKeyword(tokens, from: i)
    }

    /// SQLite's own three collating sequences — kept exactly as written
    /// when a column's `COLLATE` names one of them, since dropping
    /// `COLLATE NOCASE` off a dump that was already SQLite's own would
    /// throw its ordering away for nothing.
    private static let sqliteCollations: Set<String> = ["BINARY", "NOCASE", "RTRIM"]

    /// A column definition with the MySQL and PostgreSQL words neither
    /// SQLite has nor needs taken off or swapped for something it does
    /// understand:
    /// - `AUTO_INCREMENT`, `UNSIGNED` and `ZEROFILL` drop as bare words —
    ///   dropping `AUTO_INCREMENT` off `INT … AUTO_INCREMENT PRIMARY KEY`
    ///   is what leaves `PRIMARY KEY` standing so the column can still be
    ///   the rowid alias it was.
    /// - A column's own `CHARACTER SET name` drops whole, and so does
    ///   `COLLATE name` — unless `name` is one of SQLite's own three
    ///   (`BINARY`, `NOCASE`, `RTRIM`), which are kept exactly as written.
    ///   Any other collation is not one SQLite has registered, so left in
    ///   it would fail rather than be ignored.
    /// - `ON UPDATE expr` drops whole, its own parentheses
    ///   (`CURRENT_TIMESTAMP(3)`) included.
    /// - `COMMENT 'text'` drops whole — a column's own remark, not data.
    /// - `DEFAULT func(…)` drops whole, whatever `func` is —
    ///   `nextval(…)` names a sequence this file never created, and
    ///   `now()`/`uuid_generate_v4()` are a moment or a value SQLite has
    ///   its own way to produce (or none at all, which is fine too: a
    ///   grid this file only ever reads does not need a default that never
    ///   fires). `DEFAULT 'literal'::type` keeps the literal and loses only
    ///   the cast — `'pending'::text` becomes `'pending'` — except when the
    ///   type is an array (`'{}'::text[]`), where the literal is Postgres's
    ///   own array syntax and means nothing as a plain SQLite value, so the
    ///   whole default goes rather than keep one that reads as garbage.
    /// - `enum(…)`/`set(…)` and `character varying(n)`/`character(n)`,
    ///   `timestamp with/without time zone`, `boolean`,
    ///   `bigint`/`integer`/`smallint`/`serial`/`bigserial`,
    ///   `numeric(p,s)`/`double precision`, `bytea`, `jsonb`/`json`/`uuid`
    ///   and `text[]` are swapped for the SQLite type whose affinity
    ///   already reads the same data the same way — SQLite's own type
    ///   grammar has no way to write a string inside `enum`'s or `set`'s
    ///   parentheses at all, which is the one of these that would
    ///   otherwise fail to prepare rather than just be read a little
    ///   loosely.
    ///
    /// Everything else, `PRIMARY KEY` and `NOT NULL` among it, is exactly
    /// what it was written as.
    private static func rewriteColumnOrConstraint(
        _ item: String, tokens: [Scanned], units: [UInt16]
    ) -> String {
        var replacements: [Int: String] = [:]
        var i = 0
        while i < tokens.count {
            guard tokens[i].token.kind == .word else { i += 1; continue }
            switch tokens[i].token.text.uppercased() {
            case "AUTO_INCREMENT", "UNSIGNED", "ZEROFILL":
                replacements[i] = " "
                i += 1
            case "CHARACTER" where isWordAt(tokens, i + 1, "SET") && i + 2 < tokens.count:
                replacements[i] = " "; replacements[i + 1] = " "; replacements[i + 2] = " "
                i += 3
            case "CHARACTER" where isWordAt(tokens, i + 1, "VARYING"):
                replacements[i] = " TEXT"
                replacements[i + 1] = " "
                i = dropOptionalParenthesised(tokens, from: i + 2, into: &replacements)
            case "CHARACTER":
                replacements[i] = " TEXT"
                i = dropOptionalParenthesised(tokens, from: i + 1, into: &replacements)
            case "COLLATE" where i + 1 < tokens.count:
                if tokens[i + 1].token.kind == .word,
                   sqliteCollations.contains(tokens[i + 1].token.text.uppercased()) {
                    i += 2
                } else {
                    replacements[i] = " "; replacements[i + 1] = " "
                    i += 2
                }
            case "ON" where isWordAt(tokens, i + 1, "UPDATE") && i + 2 < tokens.count:
                replacements[i] = " "; replacements[i + 1] = " "; replacements[i + 2] = " "
                i = dropOptionalParenthesised(tokens, from: i + 3, into: &replacements)
            case "COMMENT" where i + 1 < tokens.count && tokens[i + 1].token.kind == .quoted:
                replacements[i] = " "; replacements[i + 1] = " "
                i += 2
            case "DEFAULT" where i + 2 < tokens.count && tokens[i + 1].token.kind == .word
                && tokens[i + 2].token.kind == .punctuation && tokens[i + 2].token.text == "(":
                // `DEFAULT now()`, `DEFAULT nextval(…)`,
                // `DEFAULT uuid_generate_v4()` — a function call, whatever
                // it is called, drops whole.
                replacements[i] = " "; replacements[i + 1] = " "
                i = dropOptionalParenthesised(tokens, from: i + 2, into: &replacements)
            case "DEFAULT" where i + 3 < tokens.count && tokens[i + 1].token.kind == .quoted
                && isDoubleColon(tokens, i + 2):
                // `DEFAULT 'pending'::text` keeps the literal and loses only
                // the cast; `DEFAULT '{}'::text[]` is an array's own literal
                // syntax, meaningless once `text[]` is `TEXT`, so the whole
                // default goes rather than keep a value that reads as
                // nothing Postgres meant. Both need `DEFAULT`'s own index
                // to decide whether to drop it too, which is why this is
                // read from here rather than as its own general "a quoted
                // token cast to a type" rule.
                let typeLength = typeNameLength(tokens, from: i + 4)
                var end = i + 4 + typeLength
                let isArray = end < tokens.count && tokens[end].token.kind == .quoted
                    && tokens[end].token.text.isEmpty
                if isArray {
                    replacements[i] = " "
                    replacements[i + 1] = " "
                    end += 1
                }
                for k in (i + 2)..<end { replacements[k] = " " }
                i = end
            case "ENUM", "SET":
                replacements[i] = " TEXT"
                i = dropOptionalParenthesised(tokens, from: i + 1, into: &replacements)
            case "TIMESTAMP":
                var end = i + 1
                if isWordAt(tokens, end, "WITH") || isWordAt(tokens, end, "WITHOUT") {
                    if isWordAt(tokens, end + 1, "TIME"), isWordAt(tokens, end + 2, "ZONE") {
                        end += 3
                    }
                }
                replacements[i] = " TEXT"
                for k in (i + 1)..<end { replacements[k] = " " }
                i = end
            case "BOOLEAN":
                replacements[i] = " INTEGER"
                i += 1
            case "SMALLINT", "SERIAL", "BIGSERIAL", "BIGINT":
                replacements[i] = " INTEGER"
                i += 1
            case "NUMERIC":
                replacements[i] = " REAL"
                i = dropOptionalParenthesised(tokens, from: i + 1, into: &replacements)
            case "DOUBLE" where isWordAt(tokens, i + 1, "PRECISION"):
                replacements[i] = " REAL"; replacements[i + 1] = " "
                i += 2
            case "BYTEA":
                replacements[i] = " BLOB"
                i += 1
            case "JSONB", "JSON", "UUID":
                replacements[i] = " TEXT"
                i += 1
            case "TEXT" where i + 1 < tokens.count && tokens[i + 1].token.kind == .quoted
                && tokens[i + 1].token.text.isEmpty:
                // `text[]` — an array type. `[]` tokenises as one empty
                // quoted token (brackets quote an identifier in this
                // scanner, and there is nothing between them), and SQLite
                // has no array type to keep it for.
                replacements[i + 1] = " "
                i += 2
            default:
                i += 1
            }
        }
        guard !replacements.isEmpty else { return item }
        return rebuild(tokens, units, replacing: replacements)
    }

    /// How many word tokens starting at `from` make up a cast's type name —
    /// almost always one (`text`, `integer`, `uuid`), but `character
    /// varying`, `double precision` and `timestamp with/without time zone`
    /// are two, two and up to four words with no punctuation between them
    /// to mark where the type ends and whatever follows (`NOT NULL`, say)
    /// begins. Read by name rather than just consumed greedily, so a cast
    /// followed immediately by more SQL is not swallowed along with it.
    private static func typeNameLength(_ tokens: [Scanned], from: Int) -> Int {
        if isWordAt(tokens, from, "CHARACTER"), isWordAt(tokens, from + 1, "VARYING") { return 2 }
        if isWordAt(tokens, from, "DOUBLE"), isWordAt(tokens, from + 1, "PRECISION") { return 2 }
        if isWordAt(tokens, from, "TIMESTAMP") {
            if (isWordAt(tokens, from + 1, "WITH") || isWordAt(tokens, from + 1, "WITHOUT")),
               isWordAt(tokens, from + 2, "TIME"), isWordAt(tokens, from + 3, "ZONE") {
                return 4
            }
        }
        return 1
    }

    /// Whether the two tokens at `index` and `index + 1` are `:` and `:` —
    /// a cast's own `::`, tokenised as two one-character punctuation marks
    /// rather than as one, this scanner having no notion of a `::` operator
    /// of its own.
    private static func isDoubleColon(_ tokens: [Scanned], _ index: Int) -> Bool {
        guard index + 1 < tokens.count else { return false }
        return tokens[index].token.kind == .punctuation && tokens[index].token.text == ":"
            && tokens[index + 1].token.kind == .punctuation && tokens[index + 1].token.text == ":"
    }

    /// Past an optional `(…)` right after `from`, dropping every token of
    /// it — the size on a `character varying(100)`, the precision and
    /// scale on a `numeric(10,2)`, the argument to `nextval('…'::regclass)`
    /// or to `CURRENT_TIMESTAMP(3)`. Nested parentheses are counted, so a
    /// cast's own `(…)` inside `nextval(…)`'s argument does not close it
    /// early. Returns the index just past whatever was dropped, or `from`
    /// unchanged when there was no `(` there to drop.
    private static func dropOptionalParenthesised(
        _ tokens: [Scanned], from: Int, into replacements: inout [Int: String]
    ) -> Int {
        var j = from
        guard j < tokens.count, tokens[j].token.kind == .punctuation, tokens[j].token.text == "("
        else { return from }
        var depth = 1
        replacements[j] = " "
        j += 1
        while j < tokens.count, depth > 0 {
            if tokens[j].token.kind == .punctuation {
                if tokens[j].token.text == "(" { depth += 1 }
                else if tokens[j].token.text == ")" { depth -= 1 }
            }
            replacements[j] = " "
            j += 1
        }
        return j
    }

    private static func isWordAt(_ tokens: [Scanned], _ index: Int, _ word: String) -> Bool {
        guard index < tokens.count, tokens[index].token.kind == .word else { return false }
        return tokens[index].token.text.uppercased() == word
    }

    // MARK: - CREATE INDEX

    /// `CREATE [UNIQUE] INDEX name ON table USING btree (cols);` with the
    /// `USING method` clause taken off — SQLite has no such clause at all,
    /// and picks its own index implementation regardless.
    ///
    /// `nil` for anything that is not a `CREATE INDEX`, or that is one but
    /// has no `USING` to take off — a plain `CREATE INDEX` is already what
    /// SQLite takes, and is better run exactly as written than rebuilt for
    /// no reason.
    private static func rewriteCreateIndex(_ statement: String) -> String? {
        let units = Array(statement.utf16)
        let tokens = scan(units)

        func word(_ index: Int) -> String? {
            guard index < tokens.count, tokens[index].token.kind == .word else { return nil }
            return tokens[index].token.text.uppercased()
        }

        var i = 0
        guard word(i) == "CREATE" else { return nil }
        i += 1
        if word(i) == "UNIQUE" { i += 1 }
        guard word(i) == "INDEX" else { return nil }

        var replacements: [Int: String] = [:]
        var found = false
        while i < tokens.count {
            if word(i) == "USING", i + 1 < tokens.count, tokens[i + 1].token.kind == .word {
                replacements[i] = " "
                replacements[i + 1] = " "
                found = true
                i += 2
                continue
            }
            i += 1
        }
        guard found else { return nil }
        return rebuild(tokens, units, replacing: replacements)
    }

    /// Whether `statement` is a `CREATE <kind>` — `CREATE EXTENSION …` or
    /// `CREATE SEQUENCE …`, both looked for by name only: neither creates
    /// anything `SQLDump` reads through the grid, and neither runs in
    /// SQLite as written.
    private static func matchesCreateKind(_ statement: String, _ kind: String) -> Bool {
        let units = Array(statement.utf16)
        var index = 0
        guard let create = SQLSourceMap.nextToken(units, &index), create.kind == .word,
              create.text.uppercased() == "CREATE" else { return false }
        guard let next = SQLSourceMap.nextToken(units, &index), next.kind == .word else {
            return false
        }
        return next.text.uppercased() == kind
    }

    /// The table a `CREATE TABLE` names, and which of its columns were
    /// declared `boolean` — `nil` for anything that does not read as a
    /// `CREATE TABLE` at all.
    ///
    /// Asked for on its own, independently of `rewriteCreateTable`,
    /// because by the time that has run, `boolean` has already become
    /// `INTEGER` — indistinguishable, in the schema SQLite ends up with,
    /// from a column that was `integer` all along. `SQLDump` keeps the
    /// answer beside the table's name so a `COPY` row's `t`/`f` for one of
    /// these columns can be written as `1`/`0` rather than as the two
    /// characters `t` and `f`.
    static func booleanColumns(inCreateTable statement: String) -> (table: String, columns: Set<String>)? {
        let destemmed = stripPublicSchema(statement)
        let units = Array(destemmed.utf16)
        let tokens = scan(units)

        func word(_ index: Int) -> String? {
            guard index < tokens.count, tokens[index].token.kind == .word else { return nil }
            return tokens[index].token.text.uppercased()
        }

        var i = 0
        guard word(i) == "CREATE" else { return nil }
        i += 1
        if word(i) == "TEMP" || word(i) == "TEMPORARY" { i += 1 }
        guard word(i) == "TABLE" else { return nil }
        i += 1
        if word(i) == "IF", word(i + 1) == "NOT", word(i + 2) == "EXISTS" { i += 3 }
        guard i < tokens.count, tokens[i].token.kind != .punctuation else { return nil }
        let table = tokens[i].token.text.lowercased()

        while i < tokens.count,
              !(tokens[i].token.kind == .punctuation && tokens[i].token.text == "(") {
            i += 1
        }
        guard i < tokens.count else { return nil }
        var depth = 1
        let bodyStart = i + 1
        i = bodyStart
        var closeIndex: Int?
        while i < tokens.count {
            if tokens[i].token.kind == .punctuation {
                if tokens[i].token.text == "(" {
                    depth += 1
                } else if tokens[i].token.text == ")" {
                    depth -= 1
                    if depth == 0 { closeIndex = i; break }
                }
            }
            i += 1
        }
        guard let bodyEnd = closeIndex, bodyEnd >= bodyStart else { return nil }

        var booleanColumns = Set<String>()
        for item in splitItems(tokens, from: bodyStart, to: bodyEnd, units: units) {
            let itemUnits = Array(item.utf16)
            let itemTokens = scan(itemUnits)
            guard let firstIndex = itemTokens.firstIndex(where: { $0.token.kind != .punctuation })
            else { continue }
            let firstToken = itemTokens[firstIndex].token
            guard firstToken.kind == .word || firstToken.kind == .quoted else { continue }
            let firstUpper = firstToken.kind == .word ? firstToken.text.uppercased() : ""
            let indexShapedKeywords: Set<String> = [
                "KEY", "INDEX", "UNIQUE", "PRIMARY", "CONSTRAINT", "FOREIGN", "CHECK",
                "FULLTEXT", "SPATIAL",
            ]
            guard !indexShapedKeywords.contains(firstUpper) else { continue }
            if firstIndex + 1 < itemTokens.count, itemTokens[firstIndex + 1].token.kind == .word,
               itemTokens[firstIndex + 1].token.text.uppercased() == "BOOLEAN" {
                booleanColumns.insert(firstToken.text.lowercased())
            }
        }
        return (table, booleanColumns)
    }

    // MARK: - COPY … FROM stdin

    /// One `COPY table (cols) FROM stdin;` block, read whole: the table it
    /// targets, the column list naming what each field of a row is (`nil`
    /// when the header named none, which means every column of the table in
    /// the table's own order), and every data line up to the terminating
    /// `\.` — each kept as its own byte range from the block's start (the
    /// `C` of `COPY`), one line, one row, one range, so a row can point at
    /// exactly the line that wrote it rather than at the block as a whole.
    struct CopyBlock {
        let table: String
        let columns: [String]?
        /// Each row's own fields, split at the raw tab bytes that separate
        /// them but not yet unescaped — `unescapeCopyField` and
        /// `copyFieldIsNull` do that — together with the row's own line, as
        /// a byte range from the block's start.
        let rows: [(fields: [String], range: Range<Int>)]
        /// How far past the block's own start the whole thing reaches — the
        /// header, every data line and the terminating `\.` line's own
        /// newline.
        let length: Int
    }

    /// `cursor` is known to start a `COPY` statement — `nil` when what
    /// follows does not read as one this file recognises (an unexpected
    /// header, or data that never reaches a `\.`), in which case the
    /// caller runs the statement exactly as written, which fails in
    /// exactly the way an unrecognised statement always has.
    static func parseCopyBlock(from cursor: UnsafePointer<CChar>) -> CopyBlock? {
        let headerEnd = statementExtent(from: cursor)
        guard headerEnd != cursor else { return nil }
        var headerText = string(from: cursor, to: headerEnd)
        if headerText.hasSuffix(";") { headerText.removeLast() }
        guard let (table, columns) = copyHeader(headerText) else { return nil }

        var lineStart = headerEnd
        if lineStart.pointee == 13 { lineStart += 1 }
        if lineStart.pointee == 10 { lineStart += 1 }

        var rows: [(fields: [String], range: Range<Int>)] = []
        var p = lineStart
        while p.pointee != 0 {
            let contentStart = p
            while p.pointee != 0, p.pointee != 10, p.pointee != 13 { p += 1 }
            let contentEnd = p
            let lineLength = contentStart.distance(to: contentEnd)
            // The end-of-data marker: a line that is exactly `\.` and
            // nothing else. A genuine data value of those two characters is
            // never written this way — `COPY` escapes a literal backslash
            // as `\\`, precisely so this line can never be mistaken for one.
            if lineLength == 2, contentStart[0] == 92, contentStart[1] == 46 {
                if p.pointee == 13 { p += 1 }
                if p.pointee == 10 { p += 1 }
                return CopyBlock(
                    table: table, columns: columns, rows: rows,
                    length: cursor.distance(to: p)
                )
            }
            let lineText = string(from: contentStart, to: contentEnd)
            rows.append((
                lineText.components(separatedBy: "\t"),
                cursor.distance(to: contentStart)..<cursor.distance(to: contentEnd)
            ))
            if p.pointee == 13 { p += 1 }
            if p.pointee == 10 { p += 1 }
        }
        // Ran off the end of the file without a `\.` — not a block this
        // file recognises.
        return nil
    }

    /// `COPY public.orders (id, customer) FROM stdin` (its trailing `;`
    /// already dropped) read for the table it names — `public.` schema
    /// prefix taken off — and the column list in front of `FROM stdin`,
    /// when the header gave one at all.
    private static func copyHeader(_ header: String) -> (table: String, columns: [String])? {
        let units = Array(header.utf16)
        var index = 0
        guard let copy = SQLSourceMap.nextToken(units, &index), copy.kind == .word,
              copy.text.uppercased() == "COPY" else { return nil }
        guard var tableName = nameToken(units, &index) else { return nil }
        let afterFirst = index
        if let dot = SQLSourceMap.nextToken(units, &index), dot.kind == .punctuation,
           dot.text == "." {
            guard let real = nameToken(units, &index) else { return nil }
            tableName = real
        } else {
            index = afterFirst
        }

        var columns: [String] = []
        var probe = index
        if let open = SQLSourceMap.nextToken(units, &probe), open.kind == .punctuation,
           open.text == "(" {
            index = probe
            while let token = SQLSourceMap.nextToken(units, &index) {
                if token.kind == .punctuation {
                    if token.text == ")" { break }
                    if token.text == "," { continue }
                    return nil
                }
                columns.append(token.text)
            }
        }

        guard let from = SQLSourceMap.nextToken(units, &index), from.kind == .word,
              from.text.uppercased() == "FROM" else { return nil }
        guard let stdin = SQLSourceMap.nextToken(units, &index), stdin.kind == .word,
              stdin.text.uppercased() == "STDIN" else { return nil }
        return (tableName, columns)
    }

    private static func nameToken(_ units: [UInt16], _ index: inout Int) -> String? {
        guard let token = SQLSourceMap.nextToken(units, &index), token.kind != .punctuation
        else { return nil }
        return token.text
    }

    /// Whether a `COPY` field, exactly as it was written on the line, is
    /// Postgres's own spelling of `NULL` — the whole field has to be `\N`
    /// and nothing else, which is why this is asked before any unescaping
    /// rather than after.
    static func copyFieldIsNull(_ raw: String) -> Bool { raw == "\\N" }

    /// One `COPY` field with its own backslash escapes resolved: `\t`,
    /// `\n`, `\r` and `\\` become the character they stand for, and a
    /// backslash in front of anything else this file does not specifically
    /// know is dropped and the character taken literally, which is
    /// Postgres's own rule for it too.
    static func unescapeCopyField(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var result = ""
        result.reserveCapacity(raw.count)
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "r": result.append("\r")
            default: result.append(next)
            }
        }
        return result
    }
}
