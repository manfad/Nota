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
        /// Run this text if it will run, and skip it without a word if it
        /// will not. The one shape where a refusal is not worth stopping a
        /// dump for: an Oracle view, whose `SELECT` may be written in a
        /// dialect this file never claimed to translate, and which no grid
        /// shows anyway — `SQLDump.tables` lists tables and not views, so a
        /// view that runs is a convenience for the query box and a view that
        /// does not is nothing lost.
        case attempt(String)
        /// Run the statement exactly as it was written — nothing here
        /// applies to it.
        case run
    }

    /// Which exporter's spelling a file is written in.
    ///
    /// `standard` covers `mysqldump`, phpMyAdmin, `pg_dump` and a dump that
    /// was already SQLite's own — everything this file read before the other
    /// two were added, and all of it terminated by semicolons, which is what
    /// lets one set of rules serve them. MySQL is a shade of `standard`
    /// rather than a flavour of its own (`looksLikeMySQL`, and the
    /// `mysqlDetected` flag threaded through this file), because the only
    /// thing it changes is how a string literal ends.
    ///
    /// The other two are told apart from `standard` before the run starts
    /// rather than statement by statement (`detectFlavor`), because in both
    /// of them a statement does not have to end at a `;` at all — SSMS
    /// writes whole scripts with no semicolon anywhere, ending each batch
    /// with a lone `GO`, and SQL*Plus ends `REM` and `PROMPT` at the line
    /// and a PL/SQL block at a lone `/`. Finding a statement's extent is the
    /// first thing the run loop does, so what the file is has to be known
    /// before the first one is read.
    enum Flavor: Equatable {
        case standard
        case sqlServer
        case oracle
    }

    /// Whether a statement's leading keyword is one this file has an
    /// opinion about at all. `SQLDump`'s run loop calls this on every
    /// statement before doing anything else, so it has to be cheap: it
    /// reads the first word off the raw buffer and nothing more, without
    /// finding the statement's extent or materialising the rest of it.
    /// `COPY` is not among them — it is not one statement at all, and
    /// `SQLDump` looks for it on its own before this is ever asked.
    /// The words the other two flavours add are theirs alone: a `BEGIN` in a
    /// dump that is already SQLite's own is a transaction and must run, and
    /// a `COMMIT` there is the one that ends it. Only a file that has shown
    /// itself to be SSMS's or SQL*Plus's puts either up for skipping.
    static func handles(_ leadingKeyword: String, flavor: Flavor = .standard) -> Bool {
        switch leadingKeyword {
        case "SET", "USE", "LOCK", "UNLOCK", "START", "CREATE", "ALTER",
             "SELECT", "GRANT", "REVOKE", "INSERT", "COMMENT": return true
        default: break
        }
        switch flavor {
        case .standard:
            return false
        case .sqlServer:
            switch leadingKeyword {
            case "GO", "PRINT", "DECLARE", "EXEC", "EXECUTE", "IF", "WHILE",
                 "BEGIN", "COMMIT", "ROLLBACK", "DENY", "DROP", "TRUNCATE",
                 "RAISERROR": return true
            default: return false
            }
        case .oracle:
            switch leadingKeyword {
            case "REM", "PROMPT", "SPOOL", "WHENEVER", "EXIT", "SHOW", "DEFINE",
                 "CONNECT", "BEGIN", "DECLARE", "COMMIT", "ROLLBACK", "DROP",
                 "TRUNCATE", "EXEC", "EXECUTE": return true
            default: return false
            }
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
        from cursor: UnsafePointer<CChar>, mysqlDetected: Bool = false,
        flavor: Flavor = .standard
    ) -> UnsafePointer<CChar> {
        switch flavor {
        case .standard: return standardExtent(from: cursor, mysqlDetected: mysqlDetected)
        case .sqlServer: return sqlServerExtent(from: cursor)
        case .oracle: return oracleExtent(from: cursor)
        }
    }

    private static func standardExtent(
        from cursor: UnsafePointer<CChar>, mysqlDetected: Bool
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
    ///
    /// An SSMS or SQL*Plus export answers yes to all of them without a scan:
    /// every `INSERT` either of those writes needs the closer look anyway —
    /// a `[dbo].` schema to take off and an `N'…'` prefix to drop for one, a
    /// `SHOP.` schema and Oracle's own bare `SYSDATE` for the other — so
    /// there is nothing for a byte scan to rule out.
    static func mayNeedRewrite(
        from cursor: UnsafePointer<CChar>, to end: UnsafePointer<CChar>, mysqlDetected: Bool,
        flavor: Flavor = .standard
    ) -> Bool {
        guard flavor == .standard else { return true }
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
    static func action(
        for statement: String, mysqlDetected: Bool, flavor: Flavor = .standard
    ) -> Action {
        switch flavor {
        case .standard: return standardAction(for: statement, mysqlDetected: mysqlDetected)
        case .sqlServer: return sqlServerAction(for: statement)
        case .oracle: return oracleAction(for: statement)
        }
    }

    private static func standardAction(for statement: String, mysqlDetected: Bool) -> Action {
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
    private static func rewriteCreateTable(
        _ statement: String, flavor: Flavor = .standard
    ) -> String? {
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
        let kept: [String]
        switch flavor {
        case .standard: kept = items.compactMap(rewriteItem)
        case .sqlServer: kept = items.compactMap(rewriteSQLServerItem)
        case .oracle: kept = items.compactMap(rewriteOracleItem)
        }
        guard !kept.isEmpty else { return nil }
        // Everything an SSMS or SQL*Plus export writes after the column list
        // — `ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]`, `SEGMENT CREATION
        // IMMEDIATE … STORAGE(…) TABLESPACE "USERS"`, a partition clause —
        // is where the table's storage goes, and a database held in memory
        // for as long as a tab is open has nowhere to put any of it.
        guard flavor == .standard else {
            return prefix + kept.joined(separator: ",") + ");"
        }
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

    // MARK: - Telling SSMS and SQL*Plus from everything else

    /// Which exporter wrote this file, decided once before the run starts.
    ///
    /// MySQL is sniffed statement by statement (`looksLikeMySQL`) because
    /// the only thing it changes is how a string literal ends, and a
    /// statement read before the marker turns up is read no worse for it.
    /// The other two cannot wait: in an SSMS script a statement often ends
    /// at a lone `GO` and not at a `;` — most such scripts have no `;`
    /// anywhere at all — and in a SQL*Plus script a `REM` ends at its line
    /// and a PL/SQL block at a lone `/`. Read the first statement of either
    /// with the standard rule and its extent runs to the next semicolon,
    /// which may be the end of the file. So the question is asked of the
    /// text itself, once, before anything is read.
    ///
    /// The file's own head is enough: every exporter here writes its
    /// giveaways in the preamble and the first `CREATE TABLE`. A dump that
    /// says outright it is `mysqldump`'s, phpMyAdmin's or `pg_dump`'s is
    /// never one of these two, whatever else it holds — that is asked first,
    /// so a Postgres dump with the word `TABLESPACE` in it, or a MySQL one
    /// whose data happens to hold a line reading `GO`, is left exactly as it
    /// was read before either flavour existed.
    static func detectFlavor(in sql: String) -> Flavor {
        let head = String(sql.prefix(120_000))
        func has(_ marker: String) -> Bool {
            head.range(of: marker, options: [.caseInsensitive]) != nil
        }
        for marker in ["ENGINE=", "AUTO_INCREMENT", "phpMyAdmin", "pg_dump",
                       "FROM stdin", "`"] where has(marker) {
            return .standard
        }
        for marker in ["SET ANSI_NULLS", "SET QUOTED_IDENTIFIER", "SET IDENTITY_INSERT",
                       "[dbo].", "IDENTITY(", "NONCLUSTERED", "TEXTIMAGE_ON",
                       "sp_addextendedproperty"] where has(marker) {
            return .sqlServer
        }
        for marker in ["VARCHAR2", "SET DEFINE OFF", "SEGMENT CREATION", "REM INSERTING",
                       "NUMBER(", "to_date(", "USING INDEX"] where has(marker) {
            return .oracle
        }
        return .standard
    }

    // MARK: - Where a statement ends in SSMS and SQL*Plus

    /// The end of an SSMS statement: its `;` where it has one, and the line
    /// before the next lone `GO` where it has not.
    ///
    /// `GO` is not SQL and not a statement — it is where the client cuts the
    /// script into batches — so it is left standing as its own "statement"
    /// for the run loop to hand back here, recognise, and skip. Ending the
    /// statement *before* it rather than past it is what makes that work,
    /// and it keeps the statement's own characters — which is what the
    /// source map is written from — free of a word the file's author never
    /// meant as part of it.
    ///
    /// A batch that holds a block (`IF … BEGIN … END`, a procedure, a
    /// trigger) is read to the `GO` and not to the first `;`: those
    /// semicolons are inside the block, and cutting there would leave
    /// fragments that prepare to nothing. Nothing is lost by reading such a
    /// batch whole, because every one of them is skipped anyway.
    private static func sqlServerExtent(from cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        if let end = batchSeparatorEnd(at: cursor) { return end }
        let stopsAtSemicolon = !runsToBatchEnd(at: cursor)
        var cursor = cursor
        while cursor.pointee != 0 {
            switch cursor.pointee {
            case 59 where stopsAtSemicolon:  // ;
                return cursor + 1
            case 10, 13:  // a newline — is a `GO` standing on the next line?
                let next = (cursor.pointee == 13 && cursor[1] == 10) ? cursor + 2 : cursor + 1
                if batchSeparatorEnd(at: next) != nil { return cursor }
                if stopsAtSemicolon, startsStatement(at: next) { return cursor }
                cursor = next
            case 39, 34, 91:  // ' " [
                cursor = pastQuoted(cursor)
            case 45 where cursor[1] == 45:  // --
                cursor = pastLineComment(cursor)
            case 47 where cursor[1] == 42:  // /*
                cursor = pastBlockComment(cursor)
            default:
                cursor += 1
            }
        }
        return cursor
    }

    /// The end of a SQL*Plus statement: its `;`, or the end of the line for
    /// a SQL*Plus command — `REM`, `PROMPT`, `SET DEFINE OFF` and the rest
    /// are the client's own words, not SQL, and none of them needs a
    /// semicolon to end (`REM` may hold one and still mean nothing by it).
    /// A lone `/` on the next line ends a statement too, for the file that
    /// wrote one without a `;` before it.
    private static func oracleExtent(from cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        if let end = slashLineEnd(at: cursor) { return end }
        let endsAtLine = sqlPlusCommands.contains(leadingKeyword(at: cursor))
        var cursor = cursor
        while cursor.pointee != 0 {
            switch cursor.pointee {
            case 59 where !endsAtLine:  // ;
                return cursor + 1
            case 10, 13:
                if endsAtLine { return cursor }
                let next = (cursor.pointee == 13 && cursor[1] == 10) ? cursor + 2 : cursor + 1
                if slashLineEnd(at: next) != nil { return cursor }
                cursor = next
            case 39, 34:  // ' "
                cursor = pastQuoted(cursor)
            case 45 where cursor[1] == 45:  // --
                cursor = pastLineComment(cursor)
            case 47 where cursor[1] == 42:  // /*
                cursor = pastBlockComment(cursor)
            default:
                cursor += 1
            }
        }
        return cursor
    }

    /// The SQL*Plus commands a script is driven by rather than made of. All
    /// of them are skipped, and all of them end at their line.
    private static let sqlPlusCommands: Set<String> = [
        "REM", "PROMPT", "SET", "SPOOL", "WHENEVER", "EXIT", "QUIT", "SHOW",
        "DEFINE", "UNDEFINE", "CONNECT", "TTITLE", "BTITLE", "ACCEPT", "PAUSE",
        "COLUMN",
    ]

    /// Whether the batch starting here holds a block, and so has to be read
    /// to its `GO` rather than to its first `;` — everything with a `BEGIN
    /// … END` in it, and the four objects SSMS scripts with a body.
    private static func runsToBatchEnd(at cursor: UnsafePointer<CChar>) -> Bool {
        switch leadingKeyword(at: cursor) {
        case "IF", "WHILE", "BEGIN", "DECLARE", "EXEC", "EXECUTE", "PRINT", "RAISERROR":
            return true
        case "CREATE", "ALTER":
            switch secondKeyword(at: cursor) {
            case "PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "VIEW", "TYPE": return true
            default: return false
            }
        default:
            return false
        }
    }

    /// Whether a new statement starts at `cursor` — which in a T-SQL script
    /// is a question worth asking at every line, because SSMS's own data
    /// script has no semicolons in it at all: `SET IDENTITY_INSERT … ON`, a
    /// blank line, then one `INSERT` per line for a whole table, and a `GO`
    /// only at the end of the lot. Read with the ordinary rule the first
    /// `SET` would swallow every insert after it, and every insert but the
    /// first would be lost without a word.
    ///
    /// So a line beginning with a word that can only *start* a statement
    /// ends the one before it. Only where a statement is already known to
    /// end at a semicolon: inside a block (`IF … BEGIN … END`) these same
    /// words are its own body, and cutting there would leave fragments.
    private static func startsStatement(at cursor: UnsafePointer<CChar>) -> Bool {
        var p = cursor
        while p.pointee == 32 || p.pointee == 9 { p += 1 }
        switch leadingKeyword(at: p) {
        case "INSERT", "UPDATE", "DELETE", "SET", "CREATE", "ALTER", "DROP",
             "TRUNCATE", "EXEC", "EXECUTE", "PRINT", "USE", "GO", "IF", "BEGIN",
             "COMMIT", "ROLLBACK", "GRANT", "DENY", "REVOKE", "DECLARE", "RAISERROR":
            return true
        default:
            return false
        }
    }

    /// Whether the line at `cursor` is a batch separator — `GO` alone, with
    /// blanks and at most a trailing `;` for company — and where it ends.
    /// `nil` for anything else, a longer word starting with those two
    /// letters (`GOTO`) included.
    static func batchSeparatorEnd(at cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
        var p = cursor
        while p.pointee == 32 || p.pointee == 9 { p += 1 }
        guard p.pointee != 0 else { return nil }
        let first = UInt8(bitPattern: p.pointee)
        guard first == 71 || first == 103 else { return nil }  // G g
        let second = UInt8(bitPattern: p[1])
        guard second == 79 || second == 111 else { return nil }  // O o
        p += 2
        guard !isWordByte(p.pointee) else { return nil }
        while p.pointee == 32 || p.pointee == 9 { p += 1 }
        if p.pointee == 59 {  // ;
            p += 1
            while p.pointee == 32 || p.pointee == 9 { p += 1 }
        }
        guard p.pointee == 0 || p.pointee == 10 || p.pointee == 13 else { return nil }
        if p.pointee == 13 { p += 1 }
        if p.pointee == 10 { p += 1 }
        return p
    }

    /// Whether the line at `cursor` is SQL*Plus's own statement terminator —
    /// a `/` alone — and where it ends. That is how a PL/SQL block is ended:
    /// the block's own `END;` is not the end of anything, since a `;` inside
    /// it is one of its statements' and not the block's.
    static func slashLineEnd(at cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
        var p = cursor
        while p.pointee == 32 || p.pointee == 9 { p += 1 }
        guard p.pointee == 47 else { return nil }  // /
        p += 1
        while p.pointee == 32 || p.pointee == 9 { p += 1 }
        guard p.pointee == 0 || p.pointee == 10 || p.pointee == 13 else { return nil }
        if p.pointee == 13 { p += 1 }
        if p.pointee == 10 { p += 1 }
        return p
    }

    /// The end of a PL/SQL block starting at `cursor` — a `CREATE [OR
    /// REPLACE] TRIGGER|PROCEDURE|FUNCTION|PACKAGE|TYPE`, or an anonymous
    /// `DECLARE`/`BEGIN` — which is the line after it holding nothing but a
    /// `/`. SQLite has no procedural language at all, so the whole block is
    /// skipped as one; it is found here rather than through `statementExtent`
    /// because a block is not one statement and does not end like one.
    ///
    /// `nil` for a `CREATE` that is not one of those (a table, an index, a
    /// view), and for a block whose `/` never comes — a file that ends
    /// mid-block is better read statement by statement, badly, than
    /// swallowed whole.
    static func plsqlBlockEnd(
        from cursor: UnsafePointer<CChar>, keyword: String
    ) -> UnsafePointer<CChar>? {
        switch keyword {
        case "BEGIN", "DECLARE":
            break
        case "CREATE":
            let kind = createKind(of: headText(at: cursor, limit: 200),
                                  modifiers: oracleCreateModifiers)
            switch kind {
            case "TRIGGER", "PROCEDURE", "FUNCTION", "PACKAGE", "TYPE", "LIBRARY": break
            default: return nil
            }
        default:
            return nil
        }
        var p = cursor
        while p.pointee != 0 {
            while p.pointee != 0, p.pointee != 10, p.pointee != 13 { p += 1 }
            if p.pointee == 13 { p += 1 }
            if p.pointee == 10 { p += 1 }
            if let end = slashLineEnd(at: p) { return end }
        }
        return nil
    }

    /// The second word of the statement at `cursor`, upper-cased — read off
    /// the raw buffer the way `leadingKeyword` reads the first.
    private static func secondKeyword(at cursor: UnsafePointer<CChar>) -> String {
        var p = cursor
        while isASCIILetter(p.pointee) { p += 1 }
        while p.pointee == 32 || p.pointee == 9 || p.pointee == 10 || p.pointee == 13 { p += 1 }
        return leadingKeyword(at: p)
    }

    /// The first `limit` bytes at `cursor` as text — enough of a statement's
    /// head to read the words that say what it creates, without copying out
    /// a statement that may be a megabyte of rows.
    private static func headText(at cursor: UnsafePointer<CChar>, limit: Int) -> String {
        var p = cursor
        var count = 0
        while count < limit, p.pointee != 0 { p += 1; count += 1 }
        return string(from: cursor, to: p)
    }

    private static func isWordByte(_ byte: CChar) -> Bool {
        let value = UInt8(bitPattern: byte)
        return isASCIILetter(byte) || (value >= 48 && value <= 57) || value == 95
    }

    /// Past a string literal or a quoted name starting at `cursor`, with a
    /// doubled quote inside taken as one character of it. No backslash rule:
    /// neither T-SQL nor Oracle has one.
    private static func pastQuoted(_ cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        let opening = cursor.pointee
        let closing: CChar = opening == 91 ? 93 : opening  // [ ]
        var cursor = cursor + 1
        while cursor.pointee != 0 {
            if cursor.pointee == closing {
                cursor += 1
                if closing != 93, cursor.pointee == closing { cursor += 1; continue }
                return cursor
            }
            cursor += 1
        }
        return cursor
    }

    private static func pastLineComment(_ cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        var cursor = cursor + 2
        while cursor.pointee != 0, cursor.pointee != 10 { cursor += 1 }
        return cursor
    }

    private static func pastBlockComment(_ cursor: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        var cursor = cursor + 2
        while cursor.pointee != 0, !(cursor.pointee == 42 && cursor[1] == 47) { cursor += 1 }
        return cursor.pointee == 0 ? cursor : cursor + 2
    }

    // MARK: - Shared between the two

    /// What a `CREATE` creates, past whatever modifiers stand in front of
    /// the word: `CREATE OR REPLACE FORCE VIEW` creates a `VIEW`, `CREATE
    /// UNIQUE NONCLUSTERED INDEX` an `INDEX`. `""` for anything that is not
    /// a `CREATE` at all.
    private static func createKind(of statement: String, modifiers: Set<String>) -> String {
        let units = Array(statement.utf16)
        var index = 0
        guard let create = SQLSourceMap.nextToken(units, &index), create.kind == .word,
              create.text.uppercased() == "CREATE" else { return "" }
        while let token = SQLSourceMap.nextToken(units, &index), token.kind == .word {
            let word = token.text.uppercased()
            if modifiers.contains(word) { continue }
            return word
        }
        return ""
    }

    private static let sqlServerCreateModifiers: Set<String> = [
        "OR", "ALTER", "UNIQUE", "CLUSTERED", "NONCLUSTERED", "COLUMNSTORE",
    ]

    private static let oracleCreateModifiers: Set<String> = [
        "OR", "REPLACE", "FORCE", "NOFORCE", "EDITIONABLE", "NONEDITIONABLE",
        "PUBLIC", "GLOBAL", "PRIVATE", "TEMPORARY", "UNIQUE", "BITMAP",
        "SHARDED", "DUPLICATED",
    ]

    /// Every `schema.name` in the statement with the schema taken off — the
    /// same thing `stripPublicSchema` does for pg_dump, for the two dialects
    /// that write a schema wherever they name a table: SSMS's `[dbo].[t]`
    /// and SQL Developer's `"SHOP"."T"`. SQLite reads either as a *database*
    /// prefix and there is no such database attached, so left in, every one
    /// of them fails.
    ///
    /// Only where a dump ever writes one: after `INSERT`, `INTO`, `TABLE`,
    /// `REFERENCES`, `INDEX`, `UPDATE`, and after the `ON` of a `CREATE
    /// INDEX`, which is told from the `ON` of a join by the column list that
    /// has to follow it. Everywhere else `a.b` is a column of a table and
    /// taking the table off it would be the opposite of a fix.
    static func stripSchemaQualifiers(_ statement: String) -> String {
        let units = Array(statement.utf16)
        let tokens = scan(units)
        var replacements: [Int: String] = [:]
        var i = 0
        while i + 2 < tokens.count {
            guard tokens[i].token.kind != .punctuation,
                  tokens[i + 1].token.kind == .punctuation, tokens[i + 1].token.text == ".",
                  tokens[i + 2].token.kind != .punctuation,
                  i > 0, tokens[i - 1].token.kind == .word
            else { i += 1; continue }
            let qualifies: Bool
            switch tokens[i - 1].token.text.uppercased() {
            case "INSERT", "INTO", "TABLE", "REFERENCES", "INDEX", "UPDATE", "VIEW":
                qualifies = true
            case "ON":
                qualifies = isPunctuation(tokens, i + 3, "(")
            default:
                qualifies = false
            }
            guard qualifies else { i += 1; continue }
            replacements[i] = " "
            replacements[i + 1] = ""
            i += 3
        }
        guard !replacements.isEmpty else { return statement }
        return rebuild(tokens, units, replacing: replacements)
    }

    /// `CREATE [UNIQUE] [NONCLUSTERED|BITMAP] INDEX ix ON t (cols) …` as
    /// SQLite spells it: the words in front that name an implementation
    /// SQLite does not have to be told about, dropped; everything after the
    /// column list — `INCLUDE (…)`, `WITH (PAD_INDEX = OFF, …)`, `ON
    /// [PRIMARY]`, Oracle's `PCTFREE 10 … TABLESPACE "USERS"` — dropped
    /// wholesale, all of it storage.
    ///
    /// `nil` for anything that does not read as a `CREATE INDEX` with a
    /// column list, which the caller skips rather than guesses at.
    private static func rewriteDecoratedCreateIndex(_ statement: String) -> String? {
        let units = Array(statement.utf16)
        let tokens = scan(units)

        func word(_ index: Int) -> String? {
            guard index < tokens.count, tokens[index].token.kind == .word else { return nil }
            return tokens[index].token.text.uppercased()
        }

        var i = 0
        guard word(i) == "CREATE" else { return nil }
        i += 1
        var replacements: [Int: String] = [:]
        while let next = word(i),
              ["UNIQUE", "CLUSTERED", "NONCLUSTERED", "BITMAP", "COLUMNSTORE"].contains(next) {
            if next != "UNIQUE" { replacements[i] = " " }
            i += 1
        }
        guard word(i) == "INDEX" else { return nil }
        while i < tokens.count, !isPunctuation(tokens, i, "(") { i += 1 }
        guard i < tokens.count else { return nil }
        var depth = 1
        var closeIndex: Int?
        var j = i + 1
        while j < tokens.count {
            if tokens[j].token.kind == .punctuation {
                if tokens[j].token.text == "(" {
                    depth += 1
                } else if tokens[j].token.text == ")" {
                    depth -= 1
                    if depth == 0 { closeIndex = j; break }
                }
            }
            j += 1
        }
        guard let close = closeIndex else { return nil }
        for k in (close + 1)..<tokens.count { replacements[k] = "" }
        return rebuild(tokens, units, replacing: replacements) + ";"
    }

    private static func isPunctuation(_ tokens: [Scanned], _ index: Int, _ text: String) -> Bool {
        guard index < tokens.count, tokens[index].token.kind == .punctuation else { return false }
        return tokens[index].token.text == text
    }

    /// The quote a token was written with — `'` for a string, `"`, `` ` ``
    /// or `[` for a name — since `Token` itself keeps only what was inside
    /// it. That is the difference between the `N` of `N'Alice'`, which has
    /// to go, and a column called `n` standing in front of a bracketed name.
    private static func openingQuote(_ scanned: Scanned, in units: [UInt16]) -> UInt16? {
        for unit in units[scanned.range] where unit == 39 || unit == 34 || unit == 96
            || unit == 91 {
            return unit
        }
        return nil
    }

    // MARK: - SQL Server

    /// What to do with one statement of an SSMS "Generate Scripts" or
    /// "Script Table as" export.
    ///
    /// Most of such a script is not the database: `GO` cuts it into batches,
    /// `USE [db]` and the `SET`s put the session in a known state, `PRINT`
    /// talks to the reader, and `EXEC sys.sp_addextendedproperty` files a
    /// description away in a catalogue SQLite has no equivalent of. None of
    /// it holds a row, and none of it runs here.
    ///
    /// What is left is a `CREATE TABLE` and a `CREATE INDEX` with their
    /// decoration taken off, and the `INSERT`s — see
    /// `sqlServerInsertAction`. Everything SSMS adds after the fact —
    /// `ALTER TABLE … ADD CONSTRAINT`, `ALTER TABLE … CHECK CONSTRAINT`,
    /// `ALTER TABLE … ADD DEFAULT` — is skipped for the same reason
    /// pg_dump's is: the rows are already in, and a database only ever read
    /// does not need a constraint enforced on it.
    private static func sqlServerAction(for statement: String) -> Action {
        let units = Array(statement.utf16)
        var index = 0
        guard let first = SQLSourceMap.nextToken(units, &index), first.kind == .word else {
            return .run
        }
        switch first.text.uppercased() {
        case "GO", "USE", "SET", "PRINT", "DECLARE", "EXEC", "EXECUTE", "IF", "WHILE",
             "RAISERROR", "GRANT", "REVOKE", "DENY", "DROP", "TRUNCATE", "ALTER",
             "LOCK", "UNLOCK", "START", "ROLLBACK", "COMMENT":
            return .skip
        case "BEGIN":
            return isWord(units, index, "TRANSACTION") || isWord(units, index, "TRAN")
                ? .rewrite("BEGIN;") : .skip
        case "COMMIT":
            return isWord(units, index, "TRANSACTION") || isWord(units, index, "TRAN")
                ? .rewrite("COMMIT;") : .run
        case "CREATE":
            return sqlServerCreateAction(statement)
        case "INSERT":
            return sqlServerInsertAction(statement)
        default:
            return .run
        }
    }

    /// A `CREATE` in an SSMS script: a table and an index are rewritten, and
    /// everything else — a database, a schema, a login, a view, a procedure,
    /// a trigger, a type — is skipped. T-SQL's own body language is not
    /// something this file translates, and the run stops at the first thing
    /// that will not go in, so an object SQLite has no notion of is better
    /// left out than tried.
    private static func sqlServerCreateAction(_ statement: String) -> Action {
        let destemmed = stripSchemaQualifiers(statement)
        switch createKind(of: destemmed, modifiers: sqlServerCreateModifiers) {
        case "TABLE":
            guard let rewritten = rewriteCreateTable(destemmed, flavor: .sqlServer) else {
                return .skip
            }
            return .rewrite(rewritten)
        case "INDEX":
            guard let rewritten = rewriteDecoratedCreateIndex(destemmed) else { return .skip }
            return .rewrite(rewritten)
        default:
            return .skip
        }
    }

    /// `INSERT [dbo].[Customers] ([Id], [Name], [Joined]) VALUES (1,
    /// N'Alice', CAST(N'2024-01-05T00:00:00.000' AS DateTime))` as SQLite
    /// takes it. Four things stand between the two:
    /// - the `[dbo].` schema, taken off with everything else's;
    /// - the missing `INTO`, which T-SQL makes optional and SQLite does not;
    /// - the `N` in front of a string, which says the literal is national
    ///   character data. Every string SQLite holds is Unicode already, so
    ///   the prefix says nothing here — and it does not parse, either;
    /// - `CAST(x AS DateTime)`, whose wrapper is dropped and whose literal
    ///   is kept. The date SSMS wrote is an ISO 8601 string and stays one,
    ///   which is what the column became too (`[datetime2]` is `TEXT`), so
    ///   there is nothing left for the cast to do.
    ///
    /// A `0x…` binary literal becomes SQLite's own `X'…'`. Strings escape a
    /// quote by doubling it in both dialects, so nothing there needs
    /// touching.
    private static func sqlServerInsertAction(_ statement: String) -> Action {
        let destemmed = stripSchemaQualifiers(statement)
        let units = Array(destemmed.utf16)
        let tokens = scan(units)
        let unchanged: Action = destemmed == statement ? .run : .rewrite(destemmed)
        guard let verb = tokens.firstIndex(where: { $0.token.kind != .punctuation }),
              tokens[verb].token.kind == .word,
              tokens[verb].token.text.uppercased() == "INSERT"
        else { return unchanged }

        var replacements: [Int: String] = [:]
        if !isWordAt(tokens, verb + 1, "INTO") {
            replacements[verb] = text(units, tokens[verb].range) + " INTO"
        }
        var i = verb + 1
        while i < tokens.count {
            guard tokens[i].token.kind == .word else { i += 1; continue }
            let word = tokens[i].token.text.uppercased()
            if word == "N", i + 1 < tokens.count, tokens[i + 1].token.kind == .quoted,
               openingQuote(tokens[i + 1], in: units) == 39 {
                replacements[i] = " "
                i += 1
                continue
            }
            if word == "CAST", isPunctuation(tokens, i + 1, "(") {
                i = unwrapCast(tokens, at: i, into: &replacements)
                continue
            }
            if let literal = hexLiteral(word) {
                replacements[i] = " " + literal
                i += 1
                continue
            }
            i += 1
        }
        guard !replacements.isEmpty else { return unchanged }
        return .rewrite(rebuild(tokens, units, replacing: replacements))
    }

    /// A `CAST(value AS type)` with the wrapper dropped and the value left
    /// standing — the index to go on with is the value's own, so an `N'…'`
    /// inside is still seen by the walk that drops those.
    private static func unwrapCast(
        _ tokens: [Scanned], at index: Int, into replacements: inout [Int: String]
    ) -> Int {
        var depth = 0
        var keyword: Int?
        var closeIndex: Int?
        var j = index + 1
        while j < tokens.count {
            if tokens[j].token.kind == .punctuation {
                if tokens[j].token.text == "(" {
                    depth += 1
                } else if tokens[j].token.text == ")" {
                    depth -= 1
                    if depth == 0 { closeIndex = j; break }
                }
            } else if depth == 1, keyword == nil, tokens[j].token.kind == .word,
                      tokens[j].token.text.uppercased() == "AS" {
                keyword = j
            }
            j += 1
        }
        guard let close = closeIndex, let asIndex = keyword else { return index + 1 }
        replacements[index] = " "
        replacements[index + 1] = " "
        for k in asIndex...close { replacements[k] = " " }
        return index + 2
    }

    /// `0x1F8B…` as SQLite's own `X'1F8B…'`, or `nil` for a word that only
    /// looks like one — an odd number of digits, or a digit that is not one.
    private static func hexLiteral(_ word: String) -> String? {
        guard word.count > 2, word.hasPrefix("0X") else { return nil }
        let digits = word.dropFirst(2)
        guard digits.count % 2 == 0, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "X'" + digits + "'"
    }

    /// One item of an SSMS `CREATE TABLE`'s column list. An inline `INDEX`
    /// and a `PERIOD FOR SYSTEM_TIME` are dropped whole — SQLite has neither
    /// — and everything else keeps what it means and loses what it is stored
    /// with.
    private static func rewriteSQLServerItem(_ item: String) -> String? {
        let units = Array(item.utf16)
        let tokens = scan(units)
        guard let first = tokens.firstIndex(where: { $0.token.kind != .punctuation })
        else { return item }
        let leading = tokens[first].token.kind == .word
            ? tokens[first].token.text.uppercased() : ""
        switch leading {
        case "INDEX", "PERIOD":
            return nil
        case "CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK":
            return sqlServerStripped(tokens, units, typeIndex: nil)
        default:
            return sqlServerStripped(tokens, units, typeIndex: first + 1)
        }
    }

    /// A column or a table constraint with T-SQL's storage words taken off:
    /// - `IDENTITY(1,1)` — a counter SQLite spells `INTEGER PRIMARY KEY`,
    ///   and which the column's own `PRIMARY KEY` already says;
    /// - `CLUSTERED`/`NONCLUSTERED`, which is how an index is stored;
    /// - `WITH (PAD_INDEX = OFF, …)`, `ON [PRIMARY]`, `TEXTIMAGE_ON
    ///   [PRIMARY]`, `FILESTREAM_ON …` — where it all lives on disk;
    /// - `ROWGUIDCOL`, `SPARSE`, `NOT FOR REPLICATION`;
    /// - a `COLLATE` naming a collation SQLite has not got, and a `DEFAULT
    ///   ((0))` or `DEFAULT (getdate())`, whose parenthesised expression is
    ///   T-SQL's and not always SQLite's. A default never fires in a
    ///   database only ever read.
    ///
    /// `ON DELETE`/`ON UPDATE` are a foreign key's own words and stay: the
    /// `ON` that goes is the one naming a filegroup.
    private static func sqlServerStripped(
        _ tokens: [Scanned], _ units: [UInt16], typeIndex: Int?
    ) -> String {
        var replacements: [Int: String] = [:]
        var i = 0
        while i < tokens.count {
            if i == typeIndex {
                i = rewriteSQLServerType(tokens, at: i, into: &replacements)
                continue
            }
            guard tokens[i].token.kind == .word else { i += 1; continue }
            switch tokens[i].token.text.uppercased() {
            case "IDENTITY":
                replacements[i] = " "
                i = dropOptionalParenthesised(tokens, from: i + 1, into: &replacements)
            case "CLUSTERED", "NONCLUSTERED", "ROWGUIDCOL", "SPARSE", "FILESTREAM":
                replacements[i] = " "
                i += 1
            case "NOT" where isWordAt(tokens, i + 1, "FOR") && isWordAt(tokens, i + 2, "REPLICATION"):
                replacements[i] = " "; replacements[i + 1] = " "; replacements[i + 2] = " "
                i += 3
            case "WITH" where isPunctuation(tokens, i + 1, "("):
                replacements[i] = " "
                i = dropOptionalParenthesised(tokens, from: i + 1, into: &replacements)
            case "ON" where isFileGroup(tokens, i + 1), "TEXTIMAGE_ON", "FILESTREAM_ON":
                replacements[i] = " "
                if i + 1 < tokens.count { replacements[i + 1] = " " }
                i += 2
            case "COLLATE" where i + 1 < tokens.count:
                if tokens[i + 1].token.kind == .word,
                   sqliteCollations.contains(tokens[i + 1].token.text.uppercased()) {
                    i += 2
                } else {
                    replacements[i] = " "; replacements[i + 1] = " "
                    i += 2
                }
            case "DEFAULT" where isPunctuation(tokens, i + 1, "("):
                replacements[i] = " "
                i = dropOptionalParenthesised(tokens, from: i + 1, into: &replacements)
            default:
                i += 1
            }
        }
        guard !replacements.isEmpty else { return text(units, 0..<units.count) }
        return rebuild(tokens, units, replacing: replacements)
    }

    /// Whether what stands after an `ON` is a filegroup's name rather than
    /// the `DELETE` or `UPDATE` of a foreign key's own clause.
    private static func isFileGroup(_ tokens: [Scanned], _ index: Int) -> Bool {
        guard index < tokens.count else { return false }
        switch tokens[index].token.kind {
        case .quoted: return true
        case .word:
            let word = tokens[index].token.text.uppercased()
            return word != "DELETE" && word != "UPDATE"
        case .punctuation: return false
        }
    }

    /// A T-SQL type as the SQLite type whose affinity reads the same data
    /// the same way, with the size or precision after it dropped —
    /// `[nvarchar](100)` and `[varchar](max)` are both just `TEXT`, and
    /// SQLite has no `max` to write anyway. A type this table does not know
    /// (a user-defined one, `[dbo].[Money]` with the schema already off) is
    /// left exactly as written: SQLite takes any word at all as a type name.
    private static func rewriteSQLServerType(
        _ tokens: [Scanned], at index: Int, into replacements: inout [Int: String]
    ) -> Int {
        guard index < tokens.count, tokens[index].token.kind != .punctuation else {
            return index + 1
        }
        guard let mapped = sqlServerTypes[tokens[index].token.text.uppercased()] else {
            return index + 1
        }
        replacements[index] = " " + mapped
        return dropOptionalParenthesised(tokens, from: index + 1, into: &replacements)
    }

    private static let sqlServerTypes: [String: String] = [
        "INT": "INTEGER", "BIGINT": "INTEGER", "SMALLINT": "INTEGER",
        "TINYINT": "INTEGER", "BIT": "INTEGER",
        "DECIMAL": "NUMERIC", "NUMERIC": "NUMERIC", "MONEY": "NUMERIC",
        "SMALLMONEY": "NUMERIC",
        "FLOAT": "REAL", "REAL": "REAL",
        "CHAR": "TEXT", "NCHAR": "TEXT", "VARCHAR": "TEXT", "NVARCHAR": "TEXT",
        "TEXT": "TEXT", "NTEXT": "TEXT", "XML": "TEXT", "SYSNAME": "TEXT",
        "UNIQUEIDENTIFIER": "TEXT", "DATE": "TEXT", "TIME": "TEXT",
        "DATETIME": "TEXT", "DATETIME2": "TEXT", "SMALLDATETIME": "TEXT",
        "DATETIMEOFFSET": "TEXT", "SQL_VARIANT": "TEXT",
        "BINARY": "BLOB", "VARBINARY": "BLOB", "IMAGE": "BLOB",
        "TIMESTAMP": "BLOB", "ROWVERSION": "BLOB", "GEOGRAPHY": "BLOB",
        "GEOMETRY": "BLOB", "HIERARCHYID": "BLOB",
    ]

    // MARK: - Oracle

    /// What to do with one statement of a SQL Developer "Export → Insert" or
    /// SQL*Plus script.
    ///
    /// The SQL*Plus commands that drive the script (`REM`, `PROMPT`, `SET
    /// DEFINE OFF`, `SPOOL`, `WHENEVER`) are not SQL and are skipped, and so
    /// is everything Oracle has that SQLite has not: a sequence, a synonym,
    /// a tablespace, a user, a grant, a trigger, a package. A `COMMIT` goes
    /// too — nothing here opened a transaction, and SQLite refuses one that
    /// ends nothing.
    ///
    /// What is left is a `CREATE TABLE` and a `CREATE INDEX` with their
    /// storage clauses taken off, a view tried on the chance that it runs,
    /// and the `Insert into`s — see `oracleInsertAction`.
    private static func oracleAction(for statement: String) -> Action {
        let units = Array(statement.utf16)
        var index = 0
        guard let first = SQLSourceMap.nextToken(units, &index), first.kind == .word else {
            return .run
        }
        switch first.text.uppercased() {
        case "REM", "PROMPT", "SET", "SPOOL", "WHENEVER", "EXIT", "QUIT", "SHOW",
             "DEFINE", "UNDEFINE", "CONNECT", "TTITLE", "BTITLE", "ACCEPT", "PAUSE",
             "COLUMN", "USE", "GRANT", "REVOKE", "ALTER", "DROP", "TRUNCATE",
             "LOCK", "UNLOCK", "START", "EXEC", "EXECUTE", "BEGIN", "DECLARE",
             "COMMIT", "ROLLBACK", "COMMENT":
            return .skip
        case "CREATE":
            return oracleCreateAction(statement)
        case "INSERT":
            return oracleInsertAction(statement)
        default:
            return .run
        }
    }

    private static func oracleCreateAction(_ statement: String) -> Action {
        let destemmed = stripSchemaQualifiers(statement)
        switch createKind(of: destemmed, modifiers: oracleCreateModifiers) {
        case "TABLE":
            guard let rewritten = rewriteCreateTable(destemmed, flavor: .oracle) else {
                return .skip
            }
            return .rewrite(rewritten)
        case "INDEX":
            guard let rewritten = rewriteDecoratedCreateIndex(destemmed) else { return .skip }
            return .rewrite(rewritten)
        case "VIEW":
            // SQLite has views, and a view over tables that are all here may
            // well run. Its `SELECT` is Oracle's, though, and nothing in this
            // file translates that — so it is tried rather than promised, and
            // a refusal is skipped rather than shown.
            return .attempt(rewriteOracleView(destemmed))
        default:
            return .skip
        }
    }

    /// `CREATE OR REPLACE FORCE EDITIONABLE VIEW "V" ("A") AS SELECT …` with
    /// the four words in front of `VIEW` dropped — SQLite's own `CREATE
    /// VIEW` takes a column list and an `AS SELECT`, and nothing else of
    /// what Oracle writes there.
    private static func rewriteOracleView(_ statement: String) -> String {
        let units = Array(statement.utf16)
        let tokens = scan(units)
        guard !tokens.isEmpty, tokens[0].token.kind == .word,
              tokens[0].token.text.uppercased() == "CREATE" else { return statement }
        var replacements: [Int: String] = [:]
        var i = 1
        while i < tokens.count, tokens[i].token.kind == .word {
            let word = tokens[i].token.text.uppercased()
            guard ["OR", "REPLACE", "FORCE", "NOFORCE", "EDITIONABLE", "NONEDITIONABLE"]
                .contains(word) else { break }
            replacements[i] = " "
            i += 1
        }
        guard !replacements.isEmpty else { return statement }
        return rebuild(tokens, units, replacing: replacements)
    }

    /// `Insert into SHOP.ORDERS (ID,PLACED) values (1, to_date('05-JAN-24',
    /// 'DD-MON-RR'));` as SQLite takes it — which is almost as written.
    ///
    /// The schema goes, the same as everywhere else. `SYSDATE` and
    /// `SYSTIMESTAMP` become `CURRENT_TIMESTAMP`: they are bare words in
    /// Oracle rather than calls, so SQLite reads them as a column that is
    /// not there and refuses the statement — the one thing here that cannot
    /// be answered with a function. Everything else Oracle writes in a value
    /// — `to_date`, `to_timestamp`, `to_char`, `to_number`, `hextoraw`,
    /// `nvl` — *is* a call, and `SQLDump` registers all of them on the
    /// database when it opens it, so they run as written and go on running
    /// for a reader who types one into the query box.
    ///
    /// `INSERT ALL … SELECT 1 FROM DUAL` is skipped: it is many inserts in
    /// one statement, in a shape SQLite has no equivalent for.
    private static func oracleInsertAction(_ statement: String) -> Action {
        let destemmed = stripSchemaQualifiers(statement)
        let units = Array(destemmed.utf16)
        let tokens = scan(units)
        let unchanged: Action = destemmed == statement ? .run : .rewrite(destemmed)
        guard let verb = tokens.firstIndex(where: { $0.token.kind != .punctuation })
        else { return unchanged }
        if isWordAt(tokens, verb + 1, "ALL") || isWordAt(tokens, verb + 1, "FIRST") {
            return .skip
        }
        var replacements: [Int: String] = [:]
        for i in tokens.indices where tokens[i].token.kind == .word {
            switch tokens[i].token.text.uppercased() {
            case "SYSDATE", "SYSTIMESTAMP":
                replacements[i] = " CURRENT_TIMESTAMP"
            default:
                break
            }
        }
        guard !replacements.isEmpty else { return unchanged }
        return .rewrite(rebuild(tokens, units, replacing: replacements))
    }

    /// One item of an Oracle `CREATE TABLE`'s column list. A partition or a
    /// supplemental-log clause is dropped whole; everything else keeps what
    /// it means and loses the storage words around it.
    private static func rewriteOracleItem(_ item: String) -> String? {
        let units = Array(item.utf16)
        let tokens = scan(units)
        guard let first = tokens.firstIndex(where: { $0.token.kind != .punctuation })
        else { return item }
        let leading = tokens[first].token.kind == .word
            ? tokens[first].token.text.uppercased() : ""
        switch leading {
        case "SUPPLEMENTAL", "PERIOD", "PARTITION":
            return nil
        case "CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK":
            return oracleStripped(tokens, units, typeIndex: nil)
        default:
            return oracleStripped(tokens, units, typeIndex: first + 1)
        }
    }

    /// A column or a table constraint with Oracle's own words taken off:
    /// - `ENABLE`, `DISABLE`, `VALIDATE`, `NOVALIDATE`, `RELY`, `VISIBLE` —
    ///   whether a constraint is being enforced, which is not a question a
    ///   database only ever read has to answer;
    /// - everything from a `USING INDEX` to the end of the item, which is
    ///   where the constraint's own index is stored (`PCTFREE 10 INITRANS 2
    ///   … STORAGE(…) TABLESPACE "USERS"`);
    /// - `GENERATED [ALWAYS|BY DEFAULT] AS IDENTITY (…)`, a counter SQLite
    ///   already has in `INTEGER PRIMARY KEY`;
    /// - the `ON NULL` of a `DEFAULT ON NULL 0`, and a `DEFAULT` that calls
    ///   a function, which is the same thing `pg_dump`'s `DEFAULT now()` is
    ///   and goes the same way.
    ///
    /// `SYSDATE` standing as a default becomes `CURRENT_TIMESTAMP` for the
    /// same reason it does inside an insert: it is a word and not a call.
    private static func oracleStripped(
        _ tokens: [Scanned], _ units: [UInt16], typeIndex: Int?
    ) -> String {
        var replacements: [Int: String] = [:]
        var i = 0
        while i < tokens.count {
            if i == typeIndex {
                i = rewriteOracleType(tokens, at: i, into: &replacements)
                continue
            }
            guard tokens[i].token.kind == .word else { i += 1; continue }
            switch tokens[i].token.text.uppercased() {
            case "ENABLE", "DISABLE", "NOVALIDATE", "VALIDATE", "RELY", "NORELY",
                 "VISIBLE", "INVISIBLE":
                replacements[i] = " "
                i += 1
            case "USING":
                for k in i..<tokens.count { replacements[k] = "" }
                i = tokens.count
            case "GENERATED":
                var end = i + 1
                while end < tokens.count, tokens[end].token.kind == .word,
                      ["ALWAYS", "BY", "DEFAULT", "ON", "NULL", "AS", "IDENTITY"]
                          .contains(tokens[end].token.text.uppercased()) {
                    end += 1
                }
                for k in i..<end { replacements[k] = " " }
                i = dropOptionalParenthesised(tokens, from: end, into: &replacements)
            case "DEFAULT" where isWordAt(tokens, i + 1, "ON") && isWordAt(tokens, i + 2, "NULL"):
                replacements[i + 1] = " "; replacements[i + 2] = " "
                i += 3
            case "DEFAULT" where i + 2 < tokens.count && tokens[i + 1].token.kind == .word
                && isPunctuation(tokens, i + 2, "("):
                replacements[i] = " "; replacements[i + 1] = " "
                i = dropOptionalParenthesised(tokens, from: i + 2, into: &replacements)
            case "SYSDATE", "SYSTIMESTAMP":
                replacements[i] = " CURRENT_TIMESTAMP"
                i += 1
            case "COLLATE" where i + 1 < tokens.count:
                if tokens[i + 1].token.kind == .word,
                   sqliteCollations.contains(tokens[i + 1].token.text.uppercased()) {
                    i += 2
                } else {
                    replacements[i] = " "; replacements[i + 1] = " "
                    i += 2
                }
            default:
                i += 1
            }
        }
        guard !replacements.isEmpty else { return text(units, 0..<units.count) }
        return rebuild(tokens, units, replacing: replacements)
    }

    /// An Oracle type as the SQLite type whose affinity reads the same data
    /// the same way. `NUMBER` is the one that has to be read and not just
    /// looked up: `NUMBER(10,0)` counts whole things and is an `INTEGER`,
    /// `NUMBER(12,2)` is money and is `NUMERIC`, and a bare `NUMBER` is
    /// whatever anybody put in it.
    ///
    /// A length is dropped along with the word, `VARCHAR2(100 BYTE)`'s unit
    /// among it; `TIMESTAMP (6) WITH LOCAL TIME ZONE` loses all four words
    /// after it, and `LONG RAW` is bytes where a bare `LONG` is a very long
    /// string.
    private static func rewriteOracleType(
        _ tokens: [Scanned], at index: Int, into replacements: inout [Int: String]
    ) -> Int {
        guard index < tokens.count, tokens[index].token.kind != .punctuation else {
            return index + 1
        }
        switch tokens[index].token.text.uppercased() {
        case "NUMBER", "DECIMAL", "DEC", "NUMERIC":
            let scale = parenthesisedScale(tokens, from: index + 1)
            replacements[index] = scale == 0 ? " INTEGER" : " NUMERIC"
            return dropOptionalParenthesised(tokens, from: index + 1, into: &replacements)
        case "INTEGER", "INT", "SMALLINT":
            replacements[index] = " INTEGER"
            return dropOptionalParenthesised(tokens, from: index + 1, into: &replacements)
        case "FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE", "DOUBLE":
            replacements[index] = " REAL"
            var next = index + 1
            if isWordAt(tokens, next, "PRECISION") {
                replacements[next] = " "
                next += 1
            }
            return dropOptionalParenthesised(tokens, from: next, into: &replacements)
        case "VARCHAR2", "NVARCHAR2", "VARCHAR", "NVARCHAR", "CHAR", "NCHAR",
             "CHARACTER", "CLOB", "NCLOB", "ROWID", "UROWID", "XMLTYPE":
            replacements[index] = " TEXT"
            return dropOptionalParenthesised(tokens, from: index + 1, into: &replacements)
        case "LONG":
            if isWordAt(tokens, index + 1, "RAW") {
                replacements[index] = " BLOB"
                replacements[index + 1] = " "
                return index + 2
            }
            replacements[index] = " TEXT"
            return index + 1
        case "DATE":
            replacements[index] = " TEXT"
            return index + 1
        case "TIMESTAMP":
            replacements[index] = " TEXT"
            var next = dropOptionalParenthesised(tokens, from: index + 1, into: &replacements)
            if isWordAt(tokens, next, "WITH") {
                var end = next + 1
                if isWordAt(tokens, end, "LOCAL") { end += 1 }
                if isWordAt(tokens, end, "TIME"), isWordAt(tokens, end + 1, "ZONE") {
                    end += 2
                    for k in next..<end { replacements[k] = " " }
                    next = end
                }
            }
            return next
        case "INTERVAL":
            var end = index + 1
            while end < tokens.count, tokens[end].token.kind == .word,
                  ["YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "TO"]
                      .contains(tokens[end].token.text.uppercased()) {
                end = dropOptionalParenthesised(tokens, from: end + 1, into: &replacements)
            }
            replacements[index] = " TEXT"
            for k in (index + 1)..<end { replacements[k] = " " }
            return end
        case "RAW", "BLOB", "BFILE":
            replacements[index] = " BLOB"
            return dropOptionalParenthesised(tokens, from: index + 1, into: &replacements)
        default:
            return index + 1
        }
    }

    /// The scale of a `NUMBER(p,s)` — `0` for a `NUMBER(10)`, which has none
    /// and means whole numbers, and `nil` for a bare `NUMBER` with no
    /// parentheses at all, which means anything.
    private static func parenthesisedScale(_ tokens: [Scanned], from index: Int) -> Int? {
        guard isPunctuation(tokens, index, "(") else { return nil }
        var numbers: [String] = []
        var j = index + 1
        while j < tokens.count {
            let token = tokens[j].token
            if token.kind == .punctuation, token.text == ")" { break }
            if token.kind == .word { numbers.append(token.text) }
            j += 1
        }
        guard numbers.count > 1 else { return numbers.isEmpty ? nil : 0 }
        return Int(numbers[1]) ?? 0
    }
}
