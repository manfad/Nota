import Foundation
import SQLite3

/// A `.sql` file read as the database it describes.
///
/// A dump is a program, not a document: the only way to know what
/// `Shop.sql` holds is to run it. So Nota does — into a database that
/// exists only in memory, for as long as the tab is open. Nothing is
/// written anywhere: the file on disk is never opened by SQLite, only its
/// text is, and the database it builds is thrown away with the tab.
///
/// The statements are run one at a time rather than through
/// `sqlite3_exec`, for the one thing `exec` cannot say: *which* statement
/// failed. A dump that stops halfway is the common case — a syntax slip in
/// the middle of two hundred inserts — and the reader needs the line, not
/// just the complaint.
///
/// Reading is a different connection in spirit if not in fact: the query
/// box runs whatever is typed into it with an authorizer standing over the
/// handle that refuses every action but a read, so a query is a question
/// and can never be an edit. The dump itself runs with no authorizer at
/// all — it is all writes, and they are the point.
///
/// A dump does not have to be SQLite's own: an export from `mysqldump`,
/// phpMyAdmin or `pg_dump` is welcome too. `SQLDumpDialect` is where each
/// one's own spellings — `SET`, `LOCK`/`UNLOCK TABLES`, `START TRANSACTION`,
/// a `CREATE TABLE`'s `ENGINE=` or `character varying`, `GRANT`, `ALTER …
/// OWNER TO` and the rest — are turned into what SQLite's parser takes, or
/// skipped outright where there is no data in them to lose. A `pg_dump`'s
/// `COPY table FROM stdin` block is the one shape neither skip nor rewrite
/// fits — see `runCopyBlock` below.
final class SQLDump {

    /// How many rows a page holds. A page is what the grid draws and what
    /// the footer counts in: a table of four thousand rows is read a
    /// hundred at a time, the way any database browser reads one.
    static let pageSize = 100

    /// What stopped a run: the message SQLite gave, and the statement it
    /// gave it about. Both, because neither is any use alone — "near
    /// \"VALUE\": syntax error" says nothing about where, and the statement
    /// alone says nothing about what is wrong with it.
    struct Failure: Equatable, Error {
        let message: String
        /// The statement as it was written, clipped: an error about an
        /// insert of two hundred rows is not helped by all two hundred.
        let statement: String

        init(message: String, statement: String) {
            self.message = message
            self.statement = Failure.clip(statement)
        }

        /// One line, and no more of it than reads at a glance.
        private static func clip(_ statement: String, limit: Int = 160) -> String {
            let joined = statement
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard joined.count > limit else { return joined }
            return String(joined.prefix(limit)) + "…"
        }
    }

    /// One column of a page: what it is called, and what the schema says it
    /// holds. The declared type is SQLite's own word for it and may be
    /// anything at all — the header tool tip shows it as written rather
    /// than tidying it into a type system SQLite does not have.
    struct Column: Equatable {
        let name: String
        let declaredType: String?
    }

    /// One value out of the database, in the storage class it came back as.
    /// A blob keeps its length and not its bytes: the grid draws `⟨12 KB⟩`
    /// for it, and nothing in a cell that size would be readable anyway.
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(bytes: Int)

        /// Whether the cell is set right in its column. Numbers are read
        /// against each other, so they line up on their last digit; text is
        /// read from its first letter.
        var isNumber: Bool {
            switch self {
            case .integer, .real: true
            case .null, .text, .blob: false
            }
        }

        /// What the cell says on screen — and what ⌘C copies, so what is
        /// copied is what was read.
        var displayText: String {
            switch self {
            case .null: "NULL"
            case .integer(let value): String(value)
            case .real(let value): Value.write(value)
            case .text(let value): value
            case .blob(let bytes): "⟨" + Value.write(bytes: bytes) + "⟩"
            }
        }

        /// A double the way a person writes it: `12` rather than `12.0`,
        /// and everything else as Swift spells it.
        private static func write(_ value: Double) -> String {
            guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else {
                return String(value)
            }
            return String(Int64(value))
        }

        private static func write(bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    /// One hundred rows of a table or a query, and how many there are
    /// altogether — the pair the bar and the footer are both written from.
    struct Page: Equatable {
        let columns: [Column]
        let rows: [[Value]]
        /// How many rows were skipped to reach this page.
        let offset: Int
        /// How many rows there are in the whole table or query.
        let total: Int
        /// The rowid of each row, in the page's own order — the one thing a
        /// value on screen can be taken back to the statement that wrote it
        /// by. `nil` where there is nothing to take: a `WITHOUT ROWID` table
        /// has no rowids, and neither has a query this file could not read as
        /// one plain table read (`SQLQueryRewrite`).
        let rowids: [Int64]?
        /// Which table those rowids are of — the picked table for a table's
        /// page, and the one table a query read for a query's. `nil` wherever
        /// `rowids` is: the two are one answer.
        let rowidTable: String?

        init(columns: [Column], rows: [[Value]], offset: Int, total: Int,
             rowids: [Int64]? = nil, rowidTable: String? = nil) {
            self.columns = columns
            self.rows = rows
            self.offset = offset
            self.total = total
            self.rowids = rowids
            self.rowidTable = rowidTable
        }

        /// The first and last row on this page, 1-based, the way they are
        /// counted out loud. An empty page is `0` and `0` — there is no
        /// first row of nothing.
        var first: Int { rows.isEmpty ? 0 : offset + 1 }
        var last: Int { offset + rows.count }
    }

    /// Which column a page is ordered by, and which way round.
    struct Sort: Equatable {
        let column: String
        let ascending: Bool
    }

    /// One row that ⌘F over the grid found: where it sits in the whole table
    /// in the order on screen, 0-based, and its values. *Which* of them
    /// actually matches is not decided here — see `hits(for:inTable:…)`.
    struct Hit: Equatable {
        let row: Int
        let values: [Value]
    }

    /// The failure that stopped the dump, if one did. Everything the
    /// statements before it made is still in the database and still
    /// readable: a dump that stops halfway is half a database, not none.
    let failure: Failure?

    /// Every table the dump made, in name order — views and SQLite's own
    /// bookkeeping tables left out.
    private(set) var tables: [String] = []

    /// Where every row of the file is written, taken down as the run went:
    /// what a click on a cell is answered from. See `SQLSourceMap`.
    private(set) var sourceMap = SQLSourceMap()

    private var handle: OpaquePointer?

    /// Opens a database in memory and runs the file into it.
    ///
    /// Never fails: a dump SQLite cannot even open leaves a database with
    /// nothing in it and a failure to show, which is exactly what a dump
    /// whose first statement is a syntax error leaves too.
    init(sql: String) {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(
            ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard opened == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "The database could not be opened."
            if let handle { sqlite3_close(handle) }
            self.handle = nil
            self.failure = Failure(message: message, statement: "")
            return
        }
        self.handle = handle
        SQLDump.registerDialectFunctions(in: handle)
        let (failure, map) = SQLDump.run(sql, in: handle)
        self.failure = failure
        self.sourceMap = map
        self.tables = SQLDump.readTables(in: handle)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - The functions another dialect writes

    /// The handful of Oracle functions a SQL Developer export writes inside
    /// its values — `to_date('05-JAN-24','DD-MON-RR')`, `to_timestamp`,
    /// `to_char`, `to_number`, `nvl`, `hextoraw`, `empty_clob` — registered
    /// on the database itself rather than rewritten out of the text.
    ///
    /// A door rather than an edit, for two reasons. A rewrite would have to
    /// find each call's own parentheses in every statement of a file that is
    /// almost nothing but inserts, and get the nesting right every time; a
    /// function is registered once and costs nothing after. And a registered
    /// function goes on standing when the run is over: a reader who types
    /// `to_date(placed, 'DD-MON-RR')` into the query box beside an Oracle
    /// dump — the spelling their own database taught them — gets an answer
    /// rather than "no such function".
    ///
    /// None of them computes anything, and none pretends to. Nota reads a
    /// dump; it does not keep Oracle's date arithmetic, and the string the
    /// file wrote is exactly what the grid should show. So `to_date` and its
    /// neighbours hand back their first argument as it came in, `to_number`
    /// hands it back as a number where it reads as one, `hextoraw` decodes
    /// its hex to the bytes it stands for, and the two `empty_` calls answer
    /// with an empty value. All are deterministic — the same arguments
    /// always give the same answer — and all are reachable from the query
    /// box, whose authorizer already allows `SQLITE_FUNCTION`.
    private static func registerDialectFunctions(in handle: OpaquePointer) {
        // `SQLITE_DETERMINISTIC` rides along with the encoding, and is not
        // exposed by name either.
        let flags = SQLITE_UTF8 | 0x800

        func define(
            _ name: String, _ arguments: Int32,
            _ body: @escaping @convention(c) (
                OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?
            ) -> Void
        ) {
            sqlite3_create_function_v2(handle, name, arguments, flags, nil, body, nil, nil, nil)
        }

        let first: @convention(c) (
            OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?
        ) -> Void = { context, count, values in
            guard count > 0, let values, let value = values[0] else {
                sqlite3_result_null(context)
                return
            }
            sqlite3_result_value(context, value)
        }
        for name in ["to_date", "to_timestamp", "to_timestamp_tz", "to_char",
                     "to_dsinterval", "to_yminterval", "to_clob", "to_nchar"] {
            define(name, -1, first)
        }

        define("to_number", -1) { context, count, values in
            guard count > 0, let values, let value = values[0] else {
                sqlite3_result_null(context)
                return
            }
            switch sqlite3_value_type(value) {
            case SQLITE_INTEGER, SQLITE_FLOAT:
                sqlite3_result_value(context, value)
            case SQLITE_NULL:
                sqlite3_result_null(context)
            default:
                guard let text = sqlite3_value_text(value) else {
                    sqlite3_result_null(context)
                    return
                }
                if let number = Double(String(cString: text)) {
                    sqlite3_result_double(context, number)
                } else {
                    sqlite3_result_value(context, value)
                }
            }
        }

        // Oracle's own `ifnull`, and the two-argument one is the only shape
        // an export ever writes.
        define("nvl", 2) { context, count, values in
            guard count == 2, let values, let value = values[0], let fallback = values[1] else {
                sqlite3_result_null(context)
                return
            }
            sqlite3_result_value(
                context, sqlite3_value_type(value) == SQLITE_NULL ? fallback : value
            )
        }

        define("hextoraw", 1) { context, count, values in
            guard count == 1, let values, let value = values[0],
                  let text = sqlite3_value_text(value) else {
                sqlite3_result_null(context)
                return
            }
            let digits = Array(String(cString: text).utf8)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(digits.count / 2)
            var index = 0
            while index + 1 < digits.count {
                guard let high = SQLDump.hexValue(digits[index]),
                      let low = SQLDump.hexValue(digits[index + 1]) else {
                    // Not hex after all — the text itself is the best answer
                    // there is, and better than nothing.
                    sqlite3_result_value(context, value)
                    return
                }
                bytes.append(high << 4 | low)
                index += 2
            }
            guard !bytes.isEmpty else {
                sqlite3_result_zeroblob(context, 0)
                return
            }
            bytes.withUnsafeBufferPointer { buffer in
                sqlite3_result_blob(
                    context, buffer.baseAddress, Int32(buffer.count), SQLDump.transient
                )
            }
        }

        define("empty_clob", 0) { context, _, _ in
            sqlite3_result_text(context, "", 0, SQLDump.transient)
        }
        define("empty_blob", 0) { context, _, _ in
            sqlite3_result_zeroblob(context, 0)
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48          // 0–9
        case 65...70: byte - 65 + 10     // A–F
        case 97...102: byte - 97 + 10    // a–f
        default: nil
        }
    }

    // MARK: - Running the file

    /// One statement's own place in the file while the run is still going:
    /// byte offsets into the C buffer rather than the UTF-16 ranges the map
    /// ends up holding, what the statement inserted, and which shape it was
    /// written in. `sourceMap(of:in:backslashEscapes:)` turns a run's worth
    /// of these into `SQLSourceMap.Statement`s in one pass.
    private typealias Span = (
        start: Int, end: Int, table: String?, rowids: ClosedRange<Int64>?,
        form: SQLSourceMap.Statement.Form
    )

    /// The tail loop: prepare one statement, run it, move on to whatever is
    /// left of the text, and stop at the first thing that will not go in.
    ///
    /// The tail is what makes this correct where splitting on `;` is not: a
    /// semicolon inside a string literal is a semicolon in a string, and
    /// only the parser knows the difference.
    ///
    /// It is also where the source map is taken down. The tail already says
    /// where every statement ends and the cursor says where it began, so the
    /// file's own characters are free; what an insert *made* is the extra
    /// question, and `sqlite3_changes` with `sqlite3_last_insert_rowid` after
    /// the step answer it. See `SQLSourceMap`.
    private static func run(
        _ sql: String, in handle: OpaquePointer
    ) -> (Failure?, SQLSourceMap) {
        var failure: Failure?
        // Byte offsets while the run is going — the C buffer is what the
        // cursor walks — and turned into the text's own UTF-16 offsets at the
        // end, in one pass.
        var spans: [Span] = []
        var rowidTables: [String: Bool] = [:]
        // Whether the file has shown itself to be a MySQL dump yet (a
        // `LOCK TABLES`, a MySQL-only `SET`, or a `CREATE TABLE` with
        // `ENGINE=` — see `SQLDumpDialect.looksLikeMySQL`), which is what
        // tells `SQLDumpDialect.action` it may decode a statement's own
        // backslash escapes rather than leave a `pg_dump` export's own `\`
        // characters alone.
        var mysqlDetected = false
        // Which exporter wrote the file, asked of the text once before the
        // first statement is read rather than as the run goes. A `mysqldump`
        // or `pg_dump` export ends every statement with a `;`, so MySQL can
        // be recognised late and nothing is lost; an SSMS script ends its
        // batches with a lone `GO` and a SQL*Plus one ends a `REM` at its
        // line, so where the *first* statement ends already depends on the
        // answer. See `SQLDumpDialect.detectFlavor`.
        let flavor = SQLDumpDialect.detectFlavor(in: sql)
        // Which of a table's columns were declared `boolean`, kept beside
        // its name from the moment its `CREATE TABLE` runs — by the time a
        // `COPY` block for it is read, `boolean` has already become
        // `INTEGER` in the schema itself, so this is the only place left
        // that still knows which columns they were.
        var booleanColumnsByTable: [String: Set<String>] = [:]
        sql.withCString { start in
            var cursor = UnsafePointer(start)
            while cursor.pointee != 0 {
                // Past the blanks and comments in front of the statement, so
                // the range begins on its first letter rather than on the
                // newline before it.
                cursor = skippingBlanks(cursor)
                // Past everything that is not the start of a real statement
                // but that `skippingBlanks` does not know is blank: a
                // statement of nothing at all — the `;` a MySQL conditional
                // comment (`/*!40101 … */;`) leaves behind once the comment
                // itself is skipped above, or just a stray extra semicolon
                // — and a psql meta-command (`\restrict …`, `\connect …`),
                // which is not SQL at all and ends at its own line rather
                // than at a `;`. `sqlite3_prepare_v2` does not stop at a
                // leading `;`: given nothing but one in front of real SQL it
                // reads straight through and compiles the statement after
                // it, so this file has to skip both kinds itself — to keep
                // `begin` on the statement that is actually about to run,
                // and so the dialect check below is asked about that
                // statement's own leading word rather than about a `;` or a
                // `\`.
                while true {
                    let before = cursor
                    while cursor.pointee == 59 {
                        cursor = skippingBlanks(cursor + 1)
                    }
                    if cursor.pointee == 92 {
                        while cursor.pointee != 0, cursor.pointee != 10 { cursor += 1 }
                        cursor = skippingBlanks(cursor)
                    }
                    // SQL*Plus's own terminator: a line holding nothing but a
                    // `/`, which ends the PL/SQL block above it. The blocks
                    // themselves are skipped whole below, so by the time one
                    // of these is reached on its own there is nothing left for
                    // it to end — but it is not SQL either, and left standing
                    // it would stop the run.
                    if flavor == .oracle, let past = SQLDumpDialect.slashLineEnd(at: cursor) {
                        cursor = skippingBlanks(past)
                    }
                    if cursor == before { break }
                }
                guard cursor.pointee != 0 else { return }
                let begin = start.distance(to: cursor)

                // `COPY table (cols) FROM stdin;` — a `pg_dump` export's own
                // way of writing a table's rows — is not one statement at
                // all: the header ends at its `;` like anything else, but
                // the rows follow as their own lines, ended by a lone `\.`
                // rather than by SQL of any kind. It is looked for before
                // anything else because it fits none of `SQLDumpDialect`'s
                // skip/rewrite/run shape: one block becomes many `INSERT`s,
                // batched, and one source-map span *per row* rather than
                // one for the whole thing.
                if SQLDumpDialect.leadingKeyword(at: cursor) == "COPY",
                   let block = SQLDumpDialect.parseCopyBlock(from: cursor) {
                    let blockEnd = cursor + block.length
                    let booleanColumns = booleanColumnsByTable[block.table.lowercased()] ?? []
                    guard runCopyBlock(
                        block, handle: handle, begin: begin, booleanColumns: booleanColumns,
                        spans: &spans
                    ) else {
                        failure = Failure(
                            message: String(cString: sqlite3_errmsg(handle)),
                            statement: SQLDumpDialect.string(from: cursor, to: blockEnd)
                        )
                        return
                    }
                    cursor = blockEnd
                    continue
                }

                // MySQL's and PostgreSQL's own spellings — a `SET`, `USE`,
                // `LOCK`/`UNLOCK TABLES`, `START TRANSACTION`, `GRANT`,
                // `ALTER … OWNER TO`, `CREATE TABLE`/`CREATE INDEX` and the
                // rest a `mysqldump`, phpMyAdmin or `pg_dump` export
                // carries — are looked at before anything is prepared.
                // `handles` is a one-word check against the raw buffer, so
                // every other statement (every `INSERT` with nothing to
                // rewrite, above all) pays for nothing more than that.
                // See `SQLDumpDialect`.
                let leadingKeyword = SQLDumpDialect.leadingKeyword(at: cursor)

                // A PL/SQL block — `CREATE OR REPLACE TRIGGER … END; /`, or
                // an anonymous `BEGIN … END; /` — is not one statement and
                // does not end like one: the `;`s in it are its own
                // statements', and the block ends at the `/` on the line
                // after it. SQLite has no procedural language at all, so the
                // whole thing is stepped over as one unit, before anything
                // asks where a statement would end.
                if flavor == .oracle,
                   let blockEnd = SQLDumpDialect.plsqlBlockEnd(
                       from: cursor, keyword: leadingKeyword
                   ) {
                    cursor = blockEnd
                    continue
                }

                if SQLDumpDialect.handles(leadingKeyword, flavor: flavor) {
                    let extentEnd = SQLDumpDialect.statementExtent(
                        from: cursor, mysqlDetected: mysqlDetected, flavor: flavor
                    )
                    // `INSERT` is the one keyword here that shows up once a
                    // row rather than once a table — a `.dump`'s worth of
                    // them is most of the file — so before building a
                    // `String` and tokenising it, a byte scan alone asks
                    // whether this one could possibly need `action`'s
                    // closer look at all: a `public.` prefix, or, once the
                    // dump is known to be MySQL's, a backslash. Neither
                    // found, and a plain `INSERT` falls straight through to
                    // the ordinary prepare below, exactly as an unhandled
                    // statement does — no `String`, no tokens, the same
                    // cost this file already paid before `INSERT` was ever
                    // one of the keywords `handles` answers yes to.
                    let looksAtThisStatement = leadingKeyword != "INSERT"
                        || SQLDumpDialect.mayNeedRewrite(
                            from: cursor, to: extentEnd, mysqlDetected: mysqlDetected,
                            flavor: flavor
                        )
                    if looksAtThisStatement {
                        let rawText = SQLDumpDialect.string(from: cursor, to: extentEnd)
                        if !mysqlDetected, flavor == .standard {
                            mysqlDetected = SQLDumpDialect.looksLikeMySQL(rawText)
                        }
                        if leadingKeyword == "CREATE",
                           let info = SQLDumpDialect.booleanColumns(inCreateTable: rawText) {
                            booleanColumnsByTable[info.table] = info.columns
                        }
                        switch SQLDumpDialect.action(
                            for: rawText, mysqlDetected: mysqlDetected, flavor: flavor
                        ) {
                        case .skip:
                            cursor = extentEnd
                            continue
                        case .attempt(let rewritten):
                            // Run it if it runs, and say nothing if it does
                            // not. The one shape worth trying without
                            // promising: an Oracle view, whose `SELECT` may
                            // be written in a dialect nothing here
                            // translates, and which no grid shows anyway.
                            _ = runRewritten(rewritten, in: handle)
                            cursor = extentEnd
                            continue
                        case .rewrite(let rewritten):
                            // The rewritten text is prepared on its own —
                            // its tail is a position in a string that
                            // exists nowhere in the file, so `extentEnd`,
                            // found before the rewrite, is what the source
                            // map and the cursor both use instead. A
                            // rewrite that still will not run stops the
                            // whole dump exactly as an unrecognised
                            // statement always has, and shows the statement
                            // as the file itself wrote it.
                            guard runRewritten(rewritten, in: handle) else {
                                failure = Failure(
                                    message: String(cString: sqlite3_errmsg(handle)),
                                    statement: rawText
                                )
                                return
                            }
                            // A rewritten insert is an insert: its rows go
                            // on the map like every other row's, read off
                            // the statement as the *file* wrote it, since
                            // that is what the ranges are into.
                            let made = insertRecord(
                                writtenBy: rawText, in: handle, rowidTables: &rowidTables
                            )
                            spans.append((begin, start.distance(to: extentEnd),
                                          made.table, made.rowids, .statement))
                            cursor = extentEnd
                            continue
                        case .run:
                            break
                        }
                    }
                }

                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let prepared = sqlite3_prepare_v2(handle, cursor, -1, &statement, &tail)
                guard prepared == SQLITE_OK else {
                    failure = Failure(
                        message: String(cString: sqlite3_errmsg(handle)),
                        statement: firstStatement(at: cursor)
                    )
                    return
                }
                // Whitespace or a comment: nothing to run, and the tail has
                // already moved past it.
                guard let statement else {
                    guard let tail, tail != cursor else { return }
                    cursor = tail
                    continue
                }
                let text = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
                var stepped = sqlite3_step(statement)
                while stepped == SQLITE_ROW { stepped = sqlite3_step(statement) }
                sqlite3_finalize(statement)
                guard stepped == SQLITE_DONE else {
                    failure = Failure(
                        message: String(cString: sqlite3_errmsg(handle)), statement: text
                    )
                    return
                }
                let end = tail.map { start.distance(to: $0) } ?? begin
                let made = insertRecord(
                    writtenBy: text, in: handle, rowidTables: &rowidTables
                )
                spans.append((begin, end, made.table, made.rowids, .statement))
                guard let tail, tail != cursor else { return }
                cursor = tail
            }
        }
        return (failure, sourceMap(of: spans, in: sql, backslashEscapes: mysqlDetected))
    }

    /// One statement of text prepared and run on its own, away from the tail
    /// loop — which is what a rewritten statement needs, its tail being a
    /// position in a string that exists nowhere in the file.
    ///
    /// `false` for anything that will not prepare or will not step,
    /// `sqlite3_errmsg` left set for a caller that means to make a `Failure`
    /// of it — and ignored by the one caller that does not.
    @discardableResult
    private static func runRewritten(_ sql: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        guard let statement else { return true }
        var stepped = sqlite3_step(statement)
        while stepped == SQLITE_ROW { stepped = sqlite3_step(statement) }
        sqlite3_finalize(statement)
        return stepped == SQLITE_DONE
    }

    /// What the statement just run put in, for the source map: the table an
    /// `INSERT` named and the run of rowids it made — `sqlite3_changes` says
    /// how many rows went in and `sqlite3_last_insert_rowid` says the last of
    /// them, so the run is the pair read together, and it has to be asked the
    /// moment the statement is done.
    ///
    /// A `WITHOUT ROWID` table leaves `last_insert_rowid` where it was, so
    /// its inserts are recorded with no rowids at all rather than with
    /// somebody else's; `rowidTables` remembers the answer, since the
    /// question is the same for every insert into the same table.
    ///
    /// Both halves of the run ask this: the statement SQLite prepared for
    /// itself, and the one `SQLDumpDialect` rewrote on the way in. A
    /// mysqldump's `INSERT` is rewritten and is still an insert, and its rows
    /// belong on the map beside everybody else's.
    private static func insertRecord(
        writtenBy text: String, in handle: OpaquePointer,
        rowidTables: inout [String: Bool]
    ) -> (table: String?, rowids: ClosedRange<Int64>?) {
        guard let name = SQLSourceMap.insertTable(in: text) else { return (nil, nil) }
        let changes = Int64(sqlite3_changes(handle))
        let keepsRowids = rowidTables[name] ?? SQLDump.hasRowid(name, in: handle)
        rowidTables[name] = keepsRowids
        guard changes > 0, keepsRowids else { return (name, nil) }
        let last = sqlite3_last_insert_rowid(handle)
        return (name, (last - changes + 1)...last)
    }

    /// One `COPY` block's rows, run as `INSERT`s two hundred at a time —
    /// enough that a table of thousands of rows is a handful of statements
    /// rather than one per row, and few enough that the SQL text of any one
    /// of them stays reasonable.
    ///
    /// The batching is invisible to the source map: whichever statement
    /// physically wrote a row, the span recorded for it is the row's own
    /// line in the file, one rowid to one span, so `range(ofRowid:)` never
    /// has to parse a batch's `VALUES (…),(…),(…)` back apart to find it —
    /// the same shortcut a single-row span already takes.
    ///
    /// `false` for the first batch that will not run, leaving
    /// `sqlite3_errmsg` set for the caller to build a `Failure` from —
    /// nothing already run is undone, matching a plain statement's own
    /// failure, which never undoes what came before it either.
    private static func runCopyBlock(
        _ block: SQLDumpDialect.CopyBlock, handle: OpaquePointer, begin: Int,
        booleanColumns: Set<String>,
        spans: inout [Span]
    ) -> Bool {
        guard !block.rows.isEmpty else { return true }
        let quotedTable = quote(block.table)
        let columnList = block.columns.map { columns in
            "(" + columns.map(quote).joined(separator: ", ") + ")"
        } ?? ""
        // A `WITHOUT ROWID` table leaves `last_insert_rowid` where it was,
        // so its rows are recorded with no spans at all rather than with
        // somebody else's — the same rule a plain `INSERT`'s own rows
        // follow.
        let keepsRowids = hasRowid(block.table, in: handle)
        // The header's own list, as the source map wants it: lowercased, and
        // `nil` for a header that named no columns at all — which is the
        // table's own order, and what `range(ofRowid:…column:)` falls back to.
        let mappedColumns = block.columns.flatMap {
            $0.isEmpty ? nil : $0.map { $0.lowercased() }
        }
        let batchSize = 200
        var index = 0
        while index < block.rows.count {
            let batch = block.rows[index..<min(index + batchSize, block.rows.count)]
            let values = batch.map { row -> String in
                "(" + row.fields.enumerated().map { position, field -> String in
                    // Postgres's own spelling for a boolean is the bare
                    // letter `t` or `f`, not the word `true`/`false` — the
                    // column's own name (from the header, in the row's
                    // order) is what says whether this field is one.
                    let column = (block.columns?.indices.contains(position) ?? false)
                        ? block.columns![position].lowercased() : nil
                    if SQLDumpDialect.copyFieldIsNull(field) { return "NULL" }
                    if let column, booleanColumns.contains(column) {
                        if field == "t" { return "1" }
                        if field == "f" { return "0" }
                    }
                    return "'" + SQLDumpDialect.unescapeCopyField(field)
                        .replacingOccurrences(of: "'", with: "''") + "'"
                }.joined(separator: ", ") + ")"
            }.joined(separator: ",")
            let insertSQL = "INSERT INTO \(quotedTable)\(columnList) VALUES \(values);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            if let statement {
                var stepped = sqlite3_step(statement)
                while stepped == SQLITE_ROW { stepped = sqlite3_step(statement) }
                sqlite3_finalize(statement)
                guard stepped == SQLITE_DONE else { return false }
            }
            if keepsRowids {
                let changes = Int64(sqlite3_changes(handle))
                if changes > 0 {
                    let last = sqlite3_last_insert_rowid(handle)
                    let firstRowid = last - changes + 1
                    for (offset, row) in batch.enumerated() {
                        let rowid = firstRowid + Int64(offset)
                        spans.append((
                            begin + row.range.lowerBound, begin + row.range.upperBound,
                            block.table.lowercased(), rowid...rowid,
                            .copyRow(columns: mappedColumns)
                        ))
                    }
                }
            }
            index += batchSize
        }
        return true
    }

    /// The spans as the text's own UTF-16 ranges. Every offset the run took
    /// down is a byte offset into the UTF-8 the C buffer holds, and every
    /// range the editor understands is in UTF-16 units; for an ASCII file the
    /// two are the same number, and for any other one this is the single pass
    /// that turns them over.
    private static func sourceMap(
        of spans: [Span], in sql: String, backslashEscapes: Bool
    ) -> SQLSourceMap {
        guard !spans.isEmpty else {
            return SQLSourceMap(source: sql, backslashEscapes: backslashEscapes)
        }
        let offsets = spans.flatMap { [$0.start, $0.end] }
        let positions = utf16Positions(ofUTF8: offsets, in: sql)
        let statements = spans.enumerated().map { index, span in
            let start = positions[index * 2]
            let end = max(start, positions[index * 2 + 1])
            return SQLSourceMap.Statement(
                range: NSRange(location: start, length: end - start),
                table: span.table, rowids: span.rowids, form: span.form
            )
        }
        return SQLSourceMap(
            source: sql, statements: statements, backslashEscapes: backslashEscapes
        )
    }

    /// UTF-8 byte offsets, in increasing order, as UTF-16 offsets into the
    /// same string.
    private static func utf16Positions(ofUTF8 offsets: [Int], in sql: String) -> [Int] {
        guard !offsets.isEmpty else { return [] }
        // All ASCII: every offset is already the answer, and a file of two
        // hundred thousand statements is spared the walk.
        if sql.utf8.count == sql.utf16.count { return offsets }
        var positions = [Int](repeating: 0, count: offsets.count)
        var next = 0
        var bytes = 0
        var units = 0
        for scalar in sql.unicodeScalars {
            while next < offsets.count, offsets[next] <= bytes {
                positions[next] = units
                next += 1
            }
            if next == offsets.count { break }
            let value = scalar.value
            bytes += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
            units += value < 0x10000 ? 1 : 2
        }
        while next < offsets.count {
            positions[next] = units
            next += 1
        }
        return positions
    }

    /// Past the whitespace and comments at the cursor. Every character it
    /// steps over is ASCII, and a UTF-8 continuation byte is never one, so
    /// this is safe to do a byte at a time whatever the file is written in.
    private static func skippingBlanks(
        _ cursor: UnsafePointer<CChar>
    ) -> UnsafePointer<CChar> {
        var cursor = cursor
        while true {
            switch cursor.pointee {
            case 32, 9, 10, 13:
                cursor += 1
            case 45 where cursor[1] == 45:  // --
                cursor += 2
                while cursor.pointee != 0, cursor.pointee != 10 { cursor += 1 }
            case 47 where cursor[1] == 42:  // /*
                cursor += 2
                while cursor.pointee != 0,
                      !(cursor.pointee == 42 && cursor[1] == 47) { cursor += 1 }
                if cursor.pointee != 0 { cursor += 2 }
            default:
                return cursor
            }
        }
    }

    /// Whether a table keeps rowids. A `WITHOUT ROWID` table does not, and
    /// neither its pages nor its inserts have anything to be looked up by —
    /// `SELECT rowid FROM` it will not even prepare, which is the question
    /// asked here.
    static func hasRowid(_ table: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT rowid FROM \(quote(table)) LIMIT 0"
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK
        if let statement { sqlite3_finalize(statement) }
        return prepared
    }

    /// What to show for a statement that would not even parse. SQLite says
    /// nothing about where such a statement ends — there is no parse to ask
    /// — so this reads to the next semicolon, which is right for everything
    /// but the rare literal that holds one.
    private static func firstStatement(at cursor: UnsafePointer<CChar>) -> String {
        let rest = String(cString: cursor)
        guard let end = rest.firstIndex(of: ";") else { return rest }
        return String(rest[rest.startIndex...end])
    }

    private static func readTables(in handle: OpaquePointer) -> [String] {
        let sql = """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            names.append(String(cString: text))
        }
        return names
    }

    // MARK: - Reading a table

    /// How many rows a table holds, or `nil` for a name that is not a table
    /// of this database.
    func rowCount(ofTable table: String) -> Int? {
        guard tables.contains(table), let handle else { return nil }
        return SQLDump.count(handle, sql: "SELECT COUNT(*) FROM \(SQLDump.quote(table))")
    }

    /// One page of a table, ordered as asked. A table is read by name and
    /// never by anything the reader typed, so the name is quoted and the
    /// statement is otherwise this file's own.
    func page(ofTable table: String, offset: Int = 0, sort: Sort? = nil) -> Result<Page, Failure> {
        guard let handle else {
            return .failure(Failure(message: "No database.", statement: table))
        }
        guard tables.contains(table) else {
            return .failure(Failure(message: "no such table: \(table)", statement: table))
        }
        let quoted = SQLDump.quote(table)
        guard let total = SQLDump.count(handle, sql: "SELECT COUNT(*) FROM \(quoted)") else {
            return .failure(Failure(
                message: String(cString: sqlite3_errmsg(handle)), statement: table
            ))
        }
        let start = SQLDump.clamp(offset: offset, total: total)
        let order = SQLDump.orderClause(sort, columns: declaredTypes(ofTable: table).map(\.name))
        // The rowid rides in front of the values, where it is read off and
        // taken out again: it is not a column of the table and never shows in
        // the grid, it is only what a clicked cell is looked up by. A table
        // without one is read as it always was.
        let keepsRowids = SQLDump.hasRowid(table, in: handle)
        let selection = keepsRowids ? "rowid, *" : "*"
        let sql = "SELECT \(selection) FROM \(quoted)\(order) "
            + "LIMIT \(Self.pageSize) OFFSET \(start)"
        return read(sql, offset: start, total: total,
                    declared: declaredTypes(ofTable: table), statement: table,
                    rowidTable: keepsRowids ? table : nil)
    }

    /// The declared types of a table's columns, straight out of
    /// `PRAGMA table_info`. Asked of the schema rather than of a result,
    /// so an empty table still knows what its columns hold.
    func declaredTypes(ofTable table: String) -> [Column] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(SQLDump.quote(table)))"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns: [Column] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            let declared = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            columns.append(Column(
                name: String(cString: name),
                declaredType: (declared?.isEmpty ?? true) ? nil : declared
            ))
        }
        return columns
    }

    // MARK: - Every row, for an export

    /// Every row of a table, walked in the sort order asked — no `LIMIT`, no
    /// `OFFSET`: an export wants the whole table and a page exists to leave
    /// most of it out. `onColumns` is called first and once, with the
    /// columns in the order every row's own values come in; `onRow` is then
    /// called once per row, in the same order the grid would page it in.
    /// Nothing is held past a call: a table of two hundred thousand rows
    /// never sits in memory as anything more than the one row in hand and
    /// whatever the caller does with it.
    func forEachRow(
        ofTable table: String, sort: Sort? = nil,
        onColumns: ([Column]) -> Void, onRow: ([Value]) -> Void
    ) -> Failure? {
        guard handle != nil else {
            return Failure(message: "No database.", statement: table)
        }
        guard tables.contains(table) else {
            return Failure(message: "no such table: \(table)", statement: table)
        }
        let quoted = SQLDump.quote(table)
        let declared = declaredTypes(ofTable: table)
        let order = SQLDump.orderClause(sort, columns: declared.map(\.name))
        let sql = "SELECT * FROM \(quoted)\(order)"
        return forEachRow(sql, declared: declared, statement: table,
                          onColumns: onColumns, onRow: onRow)
    }

    /// Every row of whatever is typed in the query box, walked in the sort
    /// order asked. The same authorizer the query box reads under stands
    /// here too: what runs is the reader's own text, and it must still
    /// refuse a write. Unlike `page(ofQuery:)` this never asks
    /// `SQLQueryRewrite` for a rowid — an export has no cell to click back to
    /// the file, so there is nothing the splice would buy it.
    func forEachRow(
        ofQuery query: String, sort: Sort? = nil,
        onColumns: ([Column]) -> Void, onRow: ([Value]) -> Void
    ) -> Failure? {
        guard let handle else {
            return Failure(message: "No database.", statement: query)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Failure(message: "The query is empty.", statement: "")
        }

        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            SQLDump.isRead(action) ? SQLITE_OK : SQLITE_DENY
        }, nil)
        defer { sqlite3_set_authorizer(handle, nil, nil) }

        let statements: [String]
        switch SQLDump.statements(in: trimmed, of: handle) {
        case .success(let prepared): statements = prepared
        case .failure(let failure): return failure
        }
        guard let last = statements.last else {
            return Failure(message: "The query is empty.", statement: "")
        }
        let base = SQLDump.dropTrailingSemicolon(last)
        let order = SQLDump.orderClause(sort, columns: nil)
        let sql = "SELECT * FROM (\(base))\(order)"
        return forEachRow(sql, declared: nil, statement: last,
                          onColumns: onColumns, onRow: onRow)
    }

    /// Runs `sql` and calls `onColumns` once and then `onRow` once per row it
    /// steps — the shared tail of both `forEachRow` overloads, and the
    /// column-naming half of `read(_:offset:total:...)` besides: a table's
    /// columns are described by its schema and a query's by whatever SQLite
    /// can say about the expression it selected, in `SQLDump.columns(of:declared:)`.
    /// No rowid dance here — that is what a page's cell-click needs and an
    /// export never does.
    private func forEachRow(
        _ sql: String, declared: [Column]?, statement source: String,
        onColumns: ([Column]) -> Void, onRow: ([Value]) -> Void
    ) -> Failure? {
        guard let handle else {
            return Failure(message: "No database.", statement: source)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return Failure(message: String(cString: sqlite3_errmsg(handle)), statement: source)
        }
        defer { sqlite3_finalize(statement) }
        let columns = SQLDump.columns(of: statement, declared: declared)
        onColumns(columns)
        let count = columns.count
        var stepped = sqlite3_step(statement)
        while stepped == SQLITE_ROW {
            onRow((0..<count).map { value(of: statement, at: Int32($0)) })
            stepped = sqlite3_step(statement)
        }
        guard stepped == SQLITE_DONE else {
            return Failure(message: String(cString: sqlite3_errmsg(handle)), statement: source)
        }
        return nil
    }

    // MARK: - Reading a query

    /// One page of whatever was typed in the query box.
    ///
    /// Two things stand between the text and the database. The authorizer
    /// refuses every action that is not a read, so `DELETE FROM t` comes
    /// back as "not authorized" rather than as an empty table; and the
    /// whole text is prepared statement by statement before anything runs,
    /// so `SELECT 1; DELETE FROM t` is refused for its second half rather
    /// than quietly answering with its first. What is drawn is the last
    /// statement of the text — with every write denied, the ones before it
    /// can have changed nothing.
    ///
    /// That last statement is also read once by `SQLQueryRewrite`: a query
    /// that is plainly one table's rows comes back carrying that table's
    /// rowids, so a cell of it goes back to the file the way a table's cell
    /// does. Anything else — and any rewrite SQLite will not take — is run
    /// exactly as it was written, with no rowids and no word about it.
    func page(ofQuery query: String, offset: Int = 0, sort: Sort? = nil) -> Result<Page, Failure> {
        guard let handle else {
            return .failure(Failure(message: "No database.", statement: query))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(Failure(message: "The query is empty.", statement: ""))
        }

        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            SQLDump.isRead(action) ? SQLITE_OK : SQLITE_DENY
        }, nil)
        defer { sqlite3_set_authorizer(handle, nil, nil) }

        let statements: [String]
        switch SQLDump.statements(in: trimmed, of: handle) {
        case .success(let prepared): statements = prepared
        case .failure(let failure): return .failure(failure)
        }
        guard let last = statements.last else {
            return .failure(Failure(message: "The query is empty.", statement: ""))
        }

        let base = SQLDump.dropTrailingSemicolon(last)
        // A query that plainly reads one table is asked again with that
        // table's rowid in front of its columns, so a value in the grid can
        // go back to the `INSERT` that wrote it the way a table's value does.
        // The offer is silent both ways: a query of any other shape is not
        // rewritten, and a rewrite SQLite will not take is dropped and the
        // reader's own query is read as it always was.
        if let rewrite = SQLQueryRewrite.carryingRowid(base),
           SQLDump.hasRowid(rewrite.table, in: handle),
           case .success(let page) = page(
               ofSubquery: rewrite.sql, offset: offset, sort: sort,
               statement: last, rowidTable: rewrite.table
           ) {
            return .success(page)
        }
        return page(ofSubquery: base, offset: offset, sort: sort, statement: last,
                    rowidTable: nil)
    }

    /// One page of a statement wrapped as a sub-select, which is how the
    /// paging and the count stay this file's arithmetic rather than something
    /// the query has to have been written for.
    private func page(
        ofSubquery query: String, offset: Int, sort: Sort?, statement: String,
        rowidTable: String?
    ) -> Result<Page, Failure> {
        guard let handle else {
            return .failure(Failure(message: "No database.", statement: statement))
        }
        let subquery = "(" + query + ")"
        guard let total = SQLDump.count(handle, sql: "SELECT COUNT(*) FROM \(subquery)") else {
            return .failure(Failure(
                message: String(cString: sqlite3_errmsg(handle)), statement: statement
            ))
        }
        let start = SQLDump.clamp(offset: offset, total: total)
        let order = SQLDump.orderClause(sort, columns: nil)
        let sql = "SELECT * FROM \(subquery)\(order) LIMIT \(Self.pageSize) OFFSET \(start)"
        return read(sql, offset: start, total: total, declared: nil, statement: statement,
                    rowidTable: rowidTable)
    }

    /// Every statement of the text, prepared and thrown away — the check
    /// that runs before a query does. Prepared under the authorizer, so a
    /// write anywhere in the text is refused here.
    private static func statements(
        in sql: String, of handle: OpaquePointer
    ) -> Result<[String], Failure> {
        var texts: [String] = []
        var failure: Failure?
        sql.withCString { start in
            var cursor = UnsafePointer(start)
            while cursor.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let prepared = sqlite3_prepare_v2(handle, cursor, -1, &statement, &tail)
                guard prepared == SQLITE_OK else {
                    failure = Failure(
                        message: String(cString: sqlite3_errmsg(handle)),
                        statement: firstStatement(at: cursor)
                    )
                    return
                }
                if let statement {
                    texts.append(sqlite3_sql(statement).map { String(cString: $0) } ?? "")
                    sqlite3_finalize(statement)
                }
                guard let tail, tail != cursor else { return }
                cursor = tail
            }
        }
        if let failure { return .failure(failure) }
        return .success(texts)
    }

    /// Which SQLite actions a query is allowed to take: reading, and the
    /// machinery reading is made of. Everything else — every insert,
    /// update, delete, create, drop, attach, pragma and transaction — is
    /// denied, so the box beside a dump is a question and never an edit.
    private static func isRead(_ action: Int32) -> Bool {
        switch action {
        case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE: true
        default: false
        }
    }

    // MARK: - Finding a row

    /// Which rows of a table hold a piece of text somewhere in them, for ⌘F
    /// over the grid.
    ///
    /// The whole table is searched and not the page on screen, which is the
    /// only thing that makes a count and a wrap mean anything. Walking the
    /// pages by hand to do it would be a `LIMIT … OFFSET` per hundred rows,
    /// each one reading everything before it; this is one statement.
    ///
    /// `row_number()` over the very `ORDER BY` the page is cut with is what
    /// gives each hit its place in the table, so a match on row 2,140 is
    /// answered as 2,140 rather than as "somewhere". The filter is SQLite's
    /// own `instr` over `lower(CAST(… AS TEXT))`, one `OR` per column — a
    /// coarse sieve on purpose: it is case-insensitive for ASCII and exact for
    /// everything else, and *which* column of a returned row is a match is
    /// decided afterwards in Swift, from the text the grid actually draws, so
    /// a `NULL` and a number behave like what the reader sees.
    func hits(for needle: String, inTable table: String, sort: Sort?, limit: Int) -> [Hit] {
        guard tables.contains(table) else { return [] }
        let columns = declaredTypes(ofTable: table).map(\.name)
        return hits(for: needle, from: SQLDump.quote(table),
                    order: SQLDump.orderClause(sort, columns: columns),
                    columns: columns, limit: limit)
    }

    /// The same over whatever is in the query box. The reader's own query is
    /// the sub-select, exactly as `page(ofQuery:)` reads it — the rowid
    /// rewrite is left out, so the columns line up with the page on screen —
    /// and it is prepared under the same authorizer, so a search cannot do
    /// what a query cannot.
    func hits(for needle: String, inQuery query: String, sort: Sort?, limit: Int) -> [Hit] {
        guard let handle else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            SQLDump.isRead(action) ? SQLITE_OK : SQLITE_DENY
        }, nil)
        defer { sqlite3_set_authorizer(handle, nil, nil) }
        guard case .success(let statements) = SQLDump.statements(in: trimmed, of: handle),
              let last = statements.last
        else { return [] }
        let base = "(" + SQLDump.dropTrailingSemicolon(last) + ")"
        return hits(for: needle, from: base,
                    order: SQLDump.orderClause(sort, columns: nil),
                    columns: SQLDump.columnNames(of: base, in: handle), limit: limit)
    }

    /// The column names of a sub-select, as SQLite names them — which for a
    /// plain read of a table are the table's own, and for a computed column
    /// are whatever SQLite calls the expression.
    private static func columnNames(of subquery: String, in handle: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        let sql = "SELECT * FROM \(subquery) LIMIT 0"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        return (0..<Int(sqlite3_column_count(statement))).map {
            sqlite3_column_name(statement, Int32($0)).map { String(cString: $0) } ?? ""
        }
    }

    /// What the row number is called while it rides in front of the values. A
    /// name nothing in a real schema is spelled, so a table free to have a
    /// column called anything does not have this one taken from it.
    private static let rowNumberColumn = "nota_find_row"

    private func hits(
        for needle: String, from base: String, order: String, columns: [String], limit: Int
    ) -> [Hit] {
        guard let handle, !needle.isEmpty, limit > 0 else { return [] }
        // A name that is empty, or that two columns of the same result share,
        // cannot be written into a `WHERE` that means one of them — so it is
        // left out of the sieve rather than made the whole statement fail. A
        // query of nothing but expressions finds nothing, which is honest.
        var seen = Set<String>()
        var repeated = Set<String>()
        for name in columns where !name.isEmpty {
            if !seen.insert(name).inserted { repeated.insert(name) }
        }
        let searchable = columns.filter { !$0.isEmpty && !repeated.contains($0) }
        guard !searchable.isEmpty else { return [] }
        let tests = searchable
            .map { "instr(lower(CAST(\(SQLDump.quote($0)) AS TEXT)), lower(?1)) > 0" }
            .joined(separator: " OR ")
        let numbered = "SELECT row_number() OVER (\(order)) - 1 "
            + "AS \(SQLDump.quote(SQLDump.rowNumberColumn)), * FROM \(base)"
        let sql = "SELECT * FROM (\(numbered)) WHERE \(tests) LIMIT \(limit)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        // Copied by SQLite rather than borrowed: the Swift string the pointer
        // is bridged from is gone the moment the call returns.
        sqlite3_bind_text(statement, 1, needle, -1, SQLDump.transient)
        let count = Int(sqlite3_column_count(statement))
        guard count > 1 else { return [] }
        var found: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.append(Hit(
                row: Int(sqlite3_column_int64(statement, 0)),
                values: (1..<count).map { value(of: statement, at: Int32($0)) }
            ))
        }
        return found
    }

    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    // MARK: - Running one statement

    /// Runs one statement this file wrote and reads its rows back.
    ///
    /// `rowidTable` is both flags in one: a page whose first column is a
    /// rowid says which table those rowids are of, and a page with no rowid
    /// in front of it says nothing.
    private func read(
        _ sql: String, offset: Int, total: Int, declared: [Column]?, statement source: String,
        rowidTable: String? = nil
    ) -> Result<Page, Failure> {
        let rowidColumn = rowidTable != nil
        guard let handle else {
            return .failure(Failure(message: "No database.", statement: source))
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return .failure(Failure(
                message: String(cString: sqlite3_errmsg(handle)), statement: source
            ))
        }
        defer { sqlite3_finalize(statement) }

        // Column 0 is the rowid when one was asked for, and belongs to
        // nobody's header.
        let first = rowidColumn ? 1 : 0
        let count = Int(sqlite3_column_count(statement))
        let columns = SQLDump.columns(of: statement, declared: declared, from: first)

        var rows: [[Value]] = []
        var rowids: [Int64]? = rowidColumn ? [] : nil
        var stepped = sqlite3_step(statement)
        while stepped == SQLITE_ROW {
            if rowidColumn { rowids?.append(sqlite3_column_int64(statement, 0)) }
            rows.append((first..<count).map { value(of: statement, at: Int32($0)) })
            stepped = sqlite3_step(statement)
        }
        guard stepped == SQLITE_DONE else {
            return .failure(Failure(
                message: String(cString: sqlite3_errmsg(handle)), statement: source
            ))
        }
        return .success(Page(columns: columns, rows: rows, offset: offset, total: total,
                             rowids: rowids, rowidTable: rowidTable))
    }

    /// The columns of a prepared statement, from `first` on — 1 skips a
    /// leading rowid column that belongs to nobody's header. A name a
    /// table's own schema already describes keeps that description; anything
    /// else is named after whatever SQLite can say about the expression it
    /// selected. Shared by a page's own read and a whole export's
    /// `forEachRow`, so a query's columns read the same in both.
    private static func columns(
        of statement: OpaquePointer, declared: [Column]?, from first: Int = 0
    ) -> [Column] {
        let count = Int(sqlite3_column_count(statement))
        return (first..<count).map { index -> Column in
            let name = sqlite3_column_name(statement, Int32(index))
                .map { String(cString: $0) } ?? ""
            if let declared, let match = declared.first(where: { $0.name == name }) {
                return match
            }
            let type = sqlite3_column_decltype(statement, Int32(index))
                .map { String(cString: $0) }
            return Column(name: name, declaredType: type)
        }
    }

    private func value(of statement: OpaquePointer, at index: Int32) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
        case SQLITE_BLOB: .blob(bytes: Int(sqlite3_column_bytes(statement, index)))
        case SQLITE_NULL: .null
        default:
            sqlite3_column_text(statement, index)
                .map { Value.text(String(cString: $0)) } ?? .null
        }
    }

    private static func count(_ handle: OpaquePointer, sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Writing SQL

    /// An identifier as SQLite spells one: in double quotes, with any quote
    /// inside it doubled. A table name comes out of the database itself
    /// rather than from anything typed, but a table called `"` is still a
    /// table.
    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The `ORDER BY` a clicked header asks for, and nothing at all when no
    /// header has been clicked — a table with no order clause comes back in
    /// the order SQLite keeps it, which is what a dump's own rows read as.
    ///
    /// A sort on a column the page does not have is dropped rather than
    /// passed on: the columns change under a new query, and an order by a
    /// name that has gone would fail the whole page.
    private static func orderClause(_ sort: Sort?, columns: [String]?) -> String {
        guard let sort else { return "" }
        if let columns, !columns.contains(sort.column) { return "" }
        return " ORDER BY \(quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
    }

    private static func dropTrailingSemicolon(_ sql: String) -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Which page an offset actually lands on: a whole number of pages from
    /// the top, and never past the last row there is.
    static func clamp(offset: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let last = ((total - 1) / pageSize) * pageSize
        return min(max(0, offset), last)
    }
}
