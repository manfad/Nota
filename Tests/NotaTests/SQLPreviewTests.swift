import AppKit
import Foundation
import XCTest
@testable import Nota

/// The preview that has to be run to be seen. A `.sql` tab is a tab like a
/// `.md` one — the same three modes, the same control, the same session — and
/// what stands beside the source is the database the file builds, read a
/// hundred rows at a time.
final class SQLPreviewTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []
    private var windows: [NSWindow] = []
    /// Every alert the pane raised, in order — the red line under the box is
    /// gone and this is what stands in its place.
    private var alerts: [(message: String, informative: String)] = []

    @MainActor
    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        alerts = []
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - What counts as a dump

    func testADumpIsKnownByItsSpellingWhateverCaseItIsIn() throws {
        for spelling in ["sql", "SQL", "Sql"] {
            XCTAssertEqual(RenderedPreviewKind(fileExtension: spelling), .sql,
                           "\(spelling) is a dump")
        }
        for spelling in ["txt", "sqlite", "db", "csv"] {
            XCTAssertNotEqual(RenderedPreviewKind(fileExtension: spelling), .sql,
                              "\(spelling) is not a dump Nota runs")
        }
    }

    func testADumpHasTheThreeModesAndAPlainTextFileHasNone() throws {
        let dump = makeNote(named: "Shop.sql", text: "CREATE TABLE t (a);")
        XCTAssertEqual(dump.previewKind, .sql)
        XCTAssertTrue(dump.supportsRenderedPreview, "so ⌘P and the control mean something")
        XCTAssertTrue(dump.hasPreviewContent)
        dump.previewMode = .split
        XCTAssertEqual(dump.previewMode, .split)
        dump.previewMode = .reading
        XCTAssertEqual(dump.previewMode, .reading)

        let plain = makeNote(named: "notes.txt", text: "CREATE TABLE t (a);")
        XCTAssertNil(plain.previewKind, "the same statements in a .txt are text")
        XCTAssertFalse(plain.supportsRenderedPreview)
        XCTAssertFalse(plain.hasPreviewContent)

        let untitled = Note(fileURL: nil, untitledName: "Untitled",
                            text: "CREATE TABLE t (a);", attributes: [:], assets: nil)
        XCTAssertNil(untitled.previewKind, "Save As to .sql is what makes one")
    }

    @MainActor
    func testTheGridIsTheColumnsSeventhContent() throws {
        _ = NSApplication.shared
        XCTAssertEqual(PreviewContentKind(makeNote(named: "Shop.sql", text: "")), .sql)

        let column = PreviewPaneView(dragBandHeight: 12)
        column.bringForward(makeNote(named: "Shop.sql", text: ""))
        XCTAssertEqual(column.panes.kind, .sql)
        XCTAssertTrue(column.panes.showsDatabase)
        XCTAssertFalse(column.panes.sql.isHidden)
        XCTAssertTrue(column.panes.markdown.isHidden)
        XCTAssertTrue(column.panes.html.isHidden)

        column.bringForward(makeNote(named: "notes.md", text: ""))
        XCTAssertEqual(column.panes.kind, .markdown)
        XCTAssertTrue(column.panes.sql.isHidden, "and it waits behind the render again")
    }

    // MARK: - Running the file

    func testTheDumpRunsAndListsItsTables() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        XCTAssertNil(dump.failure, "the example goes in whole")
        XCTAssertEqual(dump.tables, ["customers", "order_items", "orders", "products"],
                       "tables in name order, and no index or sqlite_ bookkeeping")
        XCTAssertEqual(dump.rowCount(ofTable: "customers"), 120)
        XCTAssertEqual(dump.rowCount(ofTable: "orders"), 420)
    }

    func testTheSchemasOwnColumnTypesAreWhatTheHeadersKnow() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let columns = dump.declaredTypes(ofTable: "products")
        XCTAssertEqual(columns.map(\.name),
                       ["id", "name", "category", "price", "in_stock", "thumbnail"])
        XCTAssertEqual(columns.map { $0.declaredType ?? "" },
                       ["INTEGER", "TEXT", "TEXT", "REAL", "INTEGER", "BLOB"])
    }

    func testAFailingStatementStopsTheRunAndSaysWhichOneItWas() throws {
        let dump = SQLDump(sql: """
        CREATE TABLE t (a INTEGER);
        INSERT INTO t VALUES (1);
        INSRT INTO t VALUES (2);
        INSERT INTO t VALUES (3);
        """)
        let failure = try XCTUnwrap(dump.failure)
        XCTAssertTrue(failure.message.contains("syntax error"), failure.message)
        XCTAssertTrue(failure.statement.hasPrefix("INSRT INTO t VALUES (2);"),
                      "the statement it stopped on, not the whole file: \(failure.statement)")
        // Half a database is still a database: what went in before the slip
        // is readable.
        XCTAssertEqual(dump.tables, ["t"])
        XCTAssertEqual(dump.rowCount(ofTable: "t"), 1, "and the third insert never ran")
    }

    func testASemicolonInsideAStringIsNotTheEndOfAStatement() throws {
        let dump = SQLDump(sql: """
        CREATE TABLE t (a TEXT);
        INSERT INTO t VALUES ('one; two');
        """)
        XCTAssertNil(dump.failure)
        let page = try page(of: dump, table: "t")
        XCTAssertEqual(page.rows.first?.first, .text("one; two"))
    }

    // MARK: - A MySQL dump

    /// A `mysqldump` / phpMyAdmin export in the wild: the session state the
    /// MySQL client sends and SQLite has no equivalent for, the conditional
    /// comments phpMyAdmin wraps its own `SET`s in, and a `CREATE TABLE`
    /// carrying every MySQL-only decoration `SQLDumpDialect` knows to take
    /// off. None of it should stop the run, and the `INSERT` under it all is
    /// untouched by any of this.
    func testAMySQLDumpsSessionStateAndTableDecorationAreSteppedOver() throws {
        let dump = SQLDump(sql: mySQLDump())
        XCTAssertNil(dump.failure, dump.failure?.message ?? "")
        XCTAssertEqual(dump.tables, ["orders"], "SET, LOCK/UNLOCK and the rest wrote no table")

        let page = try page(of: dump, table: "orders")
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.rows.map { $0[1] }, [.text("Alice"), .text("Bob"), .text("Carol")])

        // The insert itself was never rewritten, so the source map lands on
        // the row's own tuple exactly as it always has.
        let source = mySQLDump() as NSString
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 2, inTable: "orders"),
                       source.range(of: "(2, 'Bob', 45.00, '2026-01-02 11:30:00')"))
    }

    /// Nothing about reading MySQL's own spellings should paper over an
    /// actual mistake: a statement gone wrong still stops the run and still
    /// says which one it was.
    func testAGenuineMistakeInAMySQLDumpStillStopsTheRunAndSaysWhichStatement() throws {
        let broken = mySQLDump().replacingOccurrences(
            of: "INSERT INTO `orders`", with: "INSRT INTO `orders`"
        )
        let dump = SQLDump(sql: broken)
        let failure = try XCTUnwrap(dump.failure)
        XCTAssertTrue(failure.message.contains("syntax error"), failure.message)
        XCTAssertTrue(failure.statement.hasPrefix("INSRT INTO `orders`"), failure.statement)
        XCTAssertEqual(dump.tables, ["orders"], "the table itself still went in before the slip")
    }

    private func mySQLDump() -> String {
        """
        -- phpMyAdmin SQL Dump
        -- version 5.2.1
        SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
        START TRANSACTION;
        SET time_zone = "+00:00";

        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
        /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
        /*!40101 SET NAMES utf8mb4 */;

        CREATE TABLE `orders` (
          `id` int(11) UNSIGNED NOT NULL AUTO_INCREMENT,
          `customer` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
          `total` decimal(10,2) NOT NULL DEFAULT 0.00,
          `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
          PRIMARY KEY (`id`),
          KEY `idx_customer` (`customer`)
        ) ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

        LOCK TABLES `orders` WRITE;
        INSERT INTO `orders` (`id`, `customer`, `total`, `created_at`) VALUES
        (1, 'Alice', 19.99, '2026-01-01 10:00:00'),
        (2, 'Bob', 45.00, '2026-01-02 11:30:00'),
        (3, 'Carol', 12.50, '2026-01-03 09:15:00');
        UNLOCK TABLES;
        COMMIT;

        /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
        /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
        /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
        """
    }

    // MARK: - A PostgreSQL dump

    /// A `pg_dump` (plain SQL) export in the wild: the session `SET`s and
    /// `pg_catalog.set_config`/`.setval` calls, a sequence built for a
    /// column and handed to it, a `CREATE TABLE` in PostgreSQL's own type
    /// spellings, the owner and constraint statements pg_dump adds after
    /// the fact, an index with its own `USING btree`, and the table's rows
    /// written as a `COPY … FROM stdin` block rather than as `INSERT`s.
    /// None of it should stop the run, and a row the block wrote still
    /// traces back to its own line in the file.
    func testAPostgresDumpsSessionStateCopyBlockAndTableDecorationAreSteppedOver() throws {
        let dump = SQLDump(sql: postgresDump())
        XCTAssertNil(dump.failure, dump.failure?.message ?? "")
        XCTAssertEqual(dump.tables, ["orders"],
                       "the sequence and the index wrote no table of their own")

        let page = try page(of: dump, table: "orders")
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.rows.map { $0[0] }, [.integer(1), .integer(2), .integer(3)])
        // The `\N` pg_dump wrote for the second row's `placed_at` is a NULL
        // cell, not the two characters `\N`.
        XCTAssertEqual(page.rows[1][2], .null)
        // The tab pg_dump escaped inside the second row's `customer` field
        // is a real tab in the cell, not the two characters `\t`.
        XCTAssertEqual(page.rows[1][1], .text("Bo\tb"))

        // COPY's own rows are batched INSERTs under the hood, but the
        // source map still lands on the row's own line in the file, one
        // row at a time.
        let row2Line = postgresRows()[1].joined(separator: "\t")
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 2, inTable: "orders"),
                       (postgresDump() as NSString).range(of: row2Line))
    }

    private func postgresRows() -> [[String]] {
        [
            ["1", "Alice", "2026-01-01 10:00:00", "t"],
            ["2", "Bo\\tb", "\\N", "f"],
            ["3", "Carol", "2026-01-03 09:15:00", "t"],
        ]
    }

    private func postgresDump() -> String {
        let header = """
        --
        -- PostgreSQL database dump
        --

        SET statement_timeout = 0;
        SET lock_timeout = 0;
        SET idle_in_transaction_session_timeout = 0;
        SET client_encoding = 'UTF8';
        SET standard_conforming_strings = on;
        SELECT pg_catalog.set_config('search_path', '', false);
        SET check_function_bodies = false;
        SET row_security = off;

        --
        -- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
        --

        CREATE SEQUENCE public.orders_id_seq
            AS integer
            START WITH 1
            INCREMENT BY 1
            NO MINVALUE
            NO MAXVALUE
            CACHE 1;

        ALTER TABLE public.orders_id_seq OWNER TO postgres;

        --
        -- Name: orders; Type: TABLE; Schema: public; Owner: postgres
        --

        CREATE TABLE public.orders (
            id integer DEFAULT nextval('public.orders_id_seq'::regclass) NOT NULL,
            customer character varying(100) NOT NULL,
            placed_at timestamp without time zone,
            is_paid boolean DEFAULT false NOT NULL
        );

        ALTER TABLE public.orders OWNER TO postgres;

        ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;

        --
        -- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: postgres
        --

        """
        let copy = "COPY public.orders (id, customer, placed_at, is_paid) FROM stdin;\n"
            + postgresRows().map { $0.joined(separator: "\t") }.joined(separator: "\n")
            + "\n\\.\n"
        let footer = """

        SELECT pg_catalog.setval('public.orders_id_seq', 3, true);

        --
        -- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
        --

        ALTER TABLE ONLY public.orders
            ADD CONSTRAINT orders_pkey PRIMARY KEY (id);

        --
        -- Name: orders_customer_idx; Type: INDEX; Schema: public; Owner: postgres
        --

        CREATE INDEX orders_customer_idx ON public.orders USING btree (customer);

        GRANT ALL ON TABLE public.orders TO someone;
        """
        return header + copy + footer
    }

    /// `key` is a legal unquoted column name in SQLite — a
    /// `settings (key TEXT, value TEXT)` table is an ordinary one — and
    /// must not be mistaken for the start of an index line just because it
    /// spells the same word an index's own keyword does. A genuine index
    /// line naming itself `idx_name` is still dropped.
    func testAnUnquotedKeyColumnSurvivesAndAGenuineIndexLineIsStillDropped() throws {
        let settings = SQLDump(sql: """
        CREATE TABLE settings (key TEXT, value TEXT);
        INSERT INTO settings VALUES ('currency', 'MYR');
        """)
        XCTAssertNil(settings.failure)
        XCTAssertEqual(settings.declaredTypes(ofTable: "settings").map(\.name), ["key", "value"])
        let settingsPage = try page(of: settings, table: "settings")
        XCTAssertEqual(settingsPage.rows.first, [.text("currency"), .text("MYR")])

        let indexed = SQLDump(sql: """
        CREATE TABLE t (name TEXT, KEY idx_name (name));
        INSERT INTO t VALUES ('x');
        """)
        XCTAssertNil(indexed.failure)
        XCTAssertEqual(indexed.declaredTypes(ofTable: "t").map(\.name), ["name"],
                       "the index line itself, not a column named after it")
    }

    /// A real phpMyAdmin export of a small shop, read from `Examples/sql`:
    /// five tables, a dozen-odd rows apiece, and `Daniel O\'Brien`'s
    /// backslash-escaped quote among them — the reason a MySQL dump's own
    /// string literals have to be decoded before SQLite ever sees them.
    func testTheMySQLExampleLoadsWhole() throws {
        let dump = SQLDump(sql: try exampleText("sql/MySQL.sql"))
        XCTAssertNil(dump.failure, dump.failure?.message ?? "")
        XCTAssertEqual(dump.tables, ["customers", "order_items", "orders", "products", "settings"])
        XCTAssertEqual(dump.rowCount(ofTable: "customers"), 12)
        XCTAssertEqual(dump.rowCount(ofTable: "products"), 10)
        XCTAssertEqual(dump.rowCount(ofTable: "orders"), 14)
        XCTAssertEqual(dump.rowCount(ofTable: "order_items"), 17)
        XCTAssertEqual(dump.rowCount(ofTable: "settings"), 3)
        XCTAssertEqual(dump.declaredTypes(ofTable: "settings").map(\.name), ["key", "value"])

        let customers = try page(of: dump, table: "customers")
        XCTAssertEqual(customers.rows[2][1], .text("Daniel O'Brien"),
                       "the escaped quote decoded rather than breaking the statement")

        let products = try page(of: dump, table: "products")
        XCTAssertEqual(products.rows[0][6], .text("Folds flat.\nShips in a tube."),
                       "\\n decoded to a real newline")
        XCTAssertEqual(products.rows[8][6], .text("C:\\shop\\art\\tote.svg"),
                       "a doubled backslash decoded to one")
        guard case .text(let ironGallNotes) = products.rows[6][6] else {
            return XCTFail("row 7's notes should be text")
        }
        XCTAssertTrue(ironGallNotes.contains("\"blue-black\""), ironGallNotes)
    }

    /// The same shop as a real `pg_dump` (plain SQL) export, read from
    /// `Examples/sql`: the same five tables and row counts, its rows
    /// written as `COPY … FROM stdin` blocks rather than `INSERT`s, a
    /// `boolean` column's `t`/`f` read back as `1`/`0`, and an array or
    /// jsonb value left exactly as the text it was dumped as.
    func testThePostgreSQLExampleLoadsWhole() throws {
        let dump = SQLDump(sql: try exampleText("sql/PostgreSQL.sql"))
        XCTAssertNil(dump.failure, dump.failure?.message ?? "")
        XCTAssertEqual(dump.tables, ["customers", "order_items", "orders", "products", "settings"])
        XCTAssertEqual(dump.rowCount(ofTable: "customers"), 12)
        XCTAssertEqual(dump.rowCount(ofTable: "products"), 10)
        XCTAssertEqual(dump.rowCount(ofTable: "orders"), 14)
        XCTAssertEqual(dump.rowCount(ofTable: "order_items"), 17)
        XCTAssertEqual(dump.rowCount(ofTable: "settings"), 3)

        let customers = try page(of: dump, table: "customers")
        XCTAssertEqual(customers.rows[2][1], .text("Daniel O'Brien"),
                       "a literal quote in COPY's own text format, doubled for SQLite")
        XCTAssertEqual(customers.rows[4][3], .null, "row 5's email, written as \\N")
        XCTAssertEqual(customers.rows[5][1], .text("Hans \"Hansi\" Müller"))
        XCTAssertEqual(customers.rows[0][5], .integer(1), "newsletter's t decoded to 1")
        XCTAssertEqual(customers.rows[1][5], .integer(0), "newsletter's f decoded to 0")

        let products = try page(of: dump, table: "products")
        guard case .text(let penRollNotes) = products.rows[9][6] else {
            return XCTFail("row 10's notes should be text")
        }
        XCTAssertTrue(penRollNotes.contains("\t"), "the escaped tab decoded to a real one")

        let orders = try page(of: dump, table: "orders")
        XCTAssertEqual(orders.rows[0][5], .text("{gift}"), "an array literal, left as text")
        XCTAssertEqual(orders.rows[0][6], .text("{\"courier\": \"poslaju\"}"), "jsonb, left as text")
    }

    // MARK: - Paging

    func testATableIsReadAHundredRowsAtATime() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let first = try page(of: dump, table: "order_items")
        XCTAssertEqual(first.rows.count, 100)
        XCTAssertEqual(first.offset, 0)
        XCTAssertEqual(first.first, 1)
        XCTAssertEqual(first.last, 100)
        XCTAssertEqual(first.total, 1047)

        let second = try page(of: dump, table: "order_items", offset: 100)
        XCTAssertEqual(second.rows.count, 100)
        XCTAssertEqual(second.first, 101)
        XCTAssertNotEqual(second.rows.first?.first, first.rows.first?.first)

        // The last page is the short one, and an offset past the end lands on
        // it rather than on nothing.
        let last = try page(of: dump, table: "order_items", offset: 1000)
        XCTAssertEqual(last.rows.count, 47)
        XCTAssertEqual(last.first, 1001)
        XCTAssertEqual(last.last, 1047)
        XCTAssertEqual(SQLDump.clamp(offset: 99_000, total: 1047), 1000)
        XCTAssertEqual(SQLDump.clamp(offset: -5, total: 1047), 0)
    }

    func testAnEmptyTableIsAPageOfNothingRatherThanAFailure() throws {
        let dump = SQLDump(sql: "CREATE TABLE t (a INTEGER, b TEXT);")
        let page = try page(of: dump, table: "t")
        XCTAssertEqual(page.rows.count, 0)
        XCTAssertEqual(page.total, 0)
        XCTAssertEqual(page.first, 0)
        XCTAssertEqual(page.columns.map(\.name), ["a", "b"],
                       "an empty table still knows what its columns are")
    }

    // MARK: - The query box asks and never edits

    func testTheAuthorizerRefusesAWriteAndTheMultiStatementTrick() throws {
        let dump = SQLDump(sql: """
        CREATE TABLE t (a INTEGER);
        INSERT INTO t VALUES (1);
        INSERT INTO t VALUES (2);
        """)
        XCTAssertNil(dump.failure)

        for attempt in ["DELETE FROM t",
                        "SELECT 1; DELETE FROM t",
                        "UPDATE t SET a = 9",
                        "DROP TABLE t",
                        "INSERT INTO t VALUES (3)"] {
            switch dump.page(ofQuery: attempt) {
            case .success:
                XCTFail("\(attempt) was allowed to run")
            case .failure(let failure):
                XCTAssertTrue(failure.message.contains("not authorized"),
                              "\(attempt): \(failure.message)")
            }
        }
        XCTAssertEqual(dump.rowCount(ofTable: "t"), 2, "and nothing in the database moved")
    }

    func testAQueryIsPagedAndCountedLikeATable() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let page = try XCTUnwrap(try? dump.page(ofQuery: "SELECT * FROM orders WHERE status = 'shipped'").get())
        XCTAssertGreaterThan(page.total, 0)
        XCTAssertEqual(page.rows.count, min(100, page.total))
        XCTAssertEqual(page.columns.map(\.name), ["id", "customer_id", "placed", "status", "note"])
    }

    func testAQueryThatWillNotParseComesBackWithItsOwnMessage() throws {
        let dump = SQLDump(sql: "CREATE TABLE t (a INTEGER);")
        switch dump.page(ofQuery: "SELECT * FRM t") {
        case .success: XCTFail("that is not a query")
        case .failure(let failure):
            XCTAssertTrue(failure.message.contains("syntax error"), failure.message)
        }
    }

    // MARK: - What a cell says

    func testWhatTheGridDrawsForEachStorageClass() throws {
        XCTAssertEqual(SQLDump.Value.null.displayText, "NULL")
        XCTAssertEqual(SQLDump.Value.integer(42).displayText, "42")
        XCTAssertEqual(SQLDump.Value.real(12).displayText, "12", "and not 12.0")
        XCTAssertEqual(SQLDump.Value.real(12.5).displayText, "12.5")
        XCTAssertEqual(SQLDump.Value.text("hello").displayText, "hello")
        let blob = SQLDump.Value.blob(bytes: 12_000).displayText
        XCTAssertTrue(blob.hasPrefix("⟨") && blob.hasSuffix("⟩"), blob)
        XCTAssertTrue(blob.contains("KB"), "a blob is its size, never its bytes: \(blob)")

        XCTAssertTrue(SQLDump.Value.integer(1).isNumber, "numbers are set right")
        XCTAssertFalse(SQLDump.Value.text("1").isNumber)
        XCTAssertFalse(SQLDump.Value.null.isNumber)
    }

    // MARK: - The footer

    func testTheFooterSaysTablesAndRows() throws {
        XCTAssertEqual(TextStats.tableCounts(7), "7 tables")
        XCTAssertEqual(TextStats.tableCounts(1), "1 table")
        XCTAssertEqual(TextStats.rowRange(first: 1, last: 100, total: 4213), "1–100 of 4,213")
        XCTAssertEqual(TextStats.rowPosition(first: 1, last: 100, total: 4213),
                       "Rows 1–100 of 4,213")
        XCTAssertEqual(TextStats.rowRange(first: 0, last: 0, total: 0), "No rows")
        XCTAssertEqual(TextStats.rowPosition(first: 0, last: 0, total: 0), "No rows")
    }

    @MainActor
    func testThePaneAnswersForTheFooterOnlyWhileTheColumnIsOnScreen() throws {
        let (pane, _) = try makePane()
        let note = try exampleNote("Shop.sql")
        try show(note, in: pane)

        let status = try XCTUnwrap(pane.footerStatus)
        XCTAssertEqual(status.summary, "4 tables")
        XCTAssertEqual(status.position, "Rows 1–100 of 120")

        // In the editor mode the column is away and a `.sql` tab is source
        // like any other: the word counts and the caret stand.
        pane.show(note, in: context(visible: false))
        XCTAssertNil(pane.footerStatus)
    }

    // MARK: - The pane

    @MainActor
    func testShowingADumpFillsThePickerAndTheFirstPage() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)

        XCTAssertEqual(pane.tables, ["customers", "order_items", "orders", "products"])
        XCTAssertEqual(pane.shownTable, "customers", "the first table, until one is picked")
        XCTAssertEqual(pane.shownPage?.rows.count, 100)
        XCTAssertEqual(pane.rangeText, "1–100 of 120")
        XCTAssertTrue(alerts.isEmpty, "a dump that goes in whole says nothing")
        XCTAssertTrue(pane.showsRefreshButton, "and one button to run it again")
    }

    @MainActor
    func testThePagesButtonsWalkTheTableAndStopAtItsEnds() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)

        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertEqual(pane.rangeText, "101–120 of 120")
        XCTAssertEqual(pane.shownPage?.rows.count, 20)

        try settle(pane) { pane.pressPreviousForTesting() }
        XCTAssertEqual(pane.rangeText, "1–100 of 120")
    }

    @MainActor
    func testPickingATableAndAskingAQuestionAndTakingItBack() throws {
        let (pane, _) = try makePane()
        let note = try exampleNote("Shop.sql")
        try show(note, in: pane)

        try settle(pane) { pane.pickTableForTesting("products") }
        XCTAssertEqual(pane.shownTable, "products")
        XCTAssertEqual(pane.shownPage?.total, 60)
        XCTAssertEqual(note.sqlTable, "products", "and the tab remembers it")

        try settle(pane) { pane.setQueryForTesting("SELECT name FROM customers LIMIT 3") }
        XCTAssertEqual(pane.shownPage?.columns.map(\.name), ["name"])
        XCTAssertEqual(pane.shownPage?.total, 3)
        XCTAssertEqual(note.sqlQuery, "SELECT name FROM customers LIMIT 3")

        // Esc puts the question down and the table comes back.
        try settle(pane) { pane.escapeQueryForTesting() }
        XCTAssertEqual(pane.queryText, "")
        XCTAssertEqual(pane.shownPage?.total, 60, "back to products")
        XCTAssertNil(note.sqlQuery)
    }

    @MainActor
    func testAQueryThatWillNotRunIsAnAlertAndLeavesTheGridAlone() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        let before = pane.shownPage?.total

        try settle(pane) { pane.setQueryForTesting("DELETE FROM customers") }
        let alert = try XCTUnwrap(alerts.last)
        XCTAssertEqual(alert.message, "Couldn’t run the query.")
        XCTAssertEqual(alert.informative, SQLPreviewView.readOnlyRule,
                       "a refused write says the rule, not SQLite's \"not authorized\"")
        XCTAssertEqual(pane.shownPage?.total, before,
                       "the page being read is not taken away by a refused question")

        // A second bad question is a second alert: the reader asked for it
        // each time, one ⌘↩ at a time.
        try settle(pane) { pane.setQueryForTesting("SELECT * FRM customers") }
        XCTAssertEqual(alerts.count, 2)
        let second = try XCTUnwrap(alerts.last)
        XCTAssertTrue(second.informative.hasPrefix("near \"FRM\": syntax error"), second.informative)
        XCTAssertTrue(second.informative.hasSuffix(SQLPreviewView.readOnlyRule),
                      "a syntax error keeps SQLite's words and adds the rule under them")
        XCTAssertTrue(try XCTUnwrap(alerts.last).informative.contains("syntax error"))
    }

    @MainActor
    func testTheDumpsOwnFailureIsAnAlertRaisedOncePerMessage() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("broken.sql")
        let text = "CREATE TABLE t (a INTEGER);\nINSRT INTO t VALUES (1);\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let note = Note(fileURL: file, untitledName: nil, text: text,
                        attributes: [:], assets: nil)
        try show(note, in: pane)

        let alert = try XCTUnwrap(alerts.last)
        XCTAssertEqual(alert.message, "Couldn’t run “broken.sql”.")
        XCTAssertTrue(alert.informative.contains("syntax error"), alert.informative)
        XCTAssertTrue(alert.informative.contains("INSRT"),
                      "and the statement it stopped on: \(alert.informative)")
        XCTAssertEqual(pane.tables, ["t"], "what went in before the slip is still there")

        // A file mid-edit is broken on almost every keystroke. The same
        // complaint is made once and then held.
        note.storage.append(NSAttributedString(string: "\n"))
        try show(note, in: pane)
        note.storage.append(NSAttributedString(string: "\n"))
        try show(note, in: pane)
        XCTAssertEqual(alerts.count, 1, "the same message, said once")

        // A different slip is different news.
        note.storage.append(NSAttributedString(string: "SELCT 1;\n"))
        try show(note, in: pane)
        XCTAssertEqual(alerts.count, 1, "the run still stops at the first slip")

        // And a file that runs clean puts the whole thing down again, so the
        // next time it breaks the reader hears about it.
        note.storage.setAttributedString(NSAttributedString(string: "CREATE TABLE t (a);"))
        try show(note, in: pane)
        XCTAssertEqual(alerts.count, 1)
        note.storage.setAttributedString(NSAttributedString(string: text))
        try show(note, in: pane)
        XCTAssertEqual(alerts.count, 2, "broken again, and said again")
    }

    @MainActor
    func testCopyingRowsTakesThemTabSeparated() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)

        let text = pane.copyTextForTesting(rows: IndexSet([0, 1]))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].split(separator: "\t", omittingEmptySubsequences: false).count, 5,
                       "one field per column of the page")
        XCTAssertTrue(lines[0].hasPrefix("1\t"), lines[0].description)
    }

    // MARK: - Sorting by a header

    @MainActor
    func testClickingAHeaderSortsTheWholeTableAndClickingItAgainTurnsItRound() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        let unsorted = try XCTUnwrap(pane.shownPage?.rows.first?.first?.displayText)
        XCTAssertNil(pane.shownSort)

        try settle(pane) { clickHeader(of: pane, column: "name", in: window) }
        XCTAssertEqual(pane.shownSort, SQLDump.Sort(column: "name", ascending: true))
        let first = try XCTUnwrap(pane.shownPage?.rows.first)
        XCTAssertNotEqual(first.first?.displayText, unsorted,
                          "the first page is the first hundred names, not the first hundred rows")
        let names = pane.shownPage?.rows.compactMap { row -> String? in
            if case .text(let value) = row[1] { return value }
            return nil
        } ?? []
        XCTAssertEqual(names, names.sorted(), "and they are in order")
        XCTAssertEqual(pane.shownPage?.offset, 0, "sorting reads the table from the top")

        // The same header again turns it round, and the whole table turns
        // with it — the last name in the table is now the first row.
        try settle(pane) { clickHeader(of: pane, column: "name", in: window) }
        XCTAssertEqual(pane.shownSort, SQLDump.Sort(column: "name", ascending: false))
        let reversed = pane.shownPage?.rows.compactMap { row -> String? in
            if case .text(let value) = row[1] { return value }
            return nil
        } ?? []
        XCTAssertEqual(reversed, reversed.sorted().reversed(), "descending, all of it")
        XCTAssertNotEqual(reversed.first, names.first)
    }

    @MainActor
    func testTheSortedColumnWearsTheChevronAndTheGutterIsNotSortable() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)

        try settle(pane) { clickHeader(of: pane, column: "city", in: window) }
        let cells = pane.gridForTesting.tableColumns.map {
            ($0.identifier.rawValue, ($0.headerCell as? SQLHeaderCell)?.sortAscending)
        }
        for (name, ascending) in cells {
            XCTAssertEqual(ascending, name == "city" ? true : nil, name)
        }

        // The `#` gutter numbers the rows; it is not a column of the table
        // and there is nothing to sort by.
        pane.clickHeaderForTesting(SQLGridView.rowNumberColumn.rawValue)
        XCTAssertEqual(pane.shownSort, SQLDump.Sort(column: "city", ascending: true))
    }

    @MainActor
    func testASortSurvivesAPageOfTheSameColumnsAndGoesWithANewQuery() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)

        try settle(pane) { clickHeader(of: pane, column: "name", in: window) }
        let columns = pane.gridForTesting.tableColumns
        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertEqual(pane.shownSort, SQLDump.Sort(column: "name", ascending: true))
        XCTAssertEqual(pane.gridForTesting.tableColumns, columns,
                       "the same columns are the same objects: the header keeps its cells")

        // A question of its own is a different set of columns and a different
        // order; the old sort has nothing left to be about.
        try settle(pane) { pane.setQueryForTesting("SELECT city FROM customers") }
        XCTAssertNil(pane.shownSort)
    }

    // MARK: - The query box

    @MainActor
    func testTheQueryBoxIsFiveRowsAndStartsBelowTheCornerSlotsBand() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()

        let box = pane.queryBoxForTesting
        XCTAssertEqual(pane.bounds.maxY - box.frame.maxY, ModeControlOverlay.hoverBandHeight,
                       accuracy: 0.5,
                       "the corner control's own band is left clear above the box; the Run button lives in it")
        XCTAssertEqual(box.frame.height, box.height(forRows: 5), accuracy: 0.5)
        let line = box.height(forRows: 2) - box.height(forRows: 1)
        XCTAssertEqual(box.frame.height - box.height(forRows: 1), line * 4, accuracy: 0.5,
                       "five rows, not one")
        XCTAssertGreaterThan(box.frame.minY,
                             pane.gridForTesting.enclosingScrollView?.frame.maxY ?? 0,
                             "the bar and the grid follow below it")
    }

    @MainActor
    func testReturnMakesALineAndCommandReturnRunsTheQuery() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        let box = pane.queryBoxForTesting
        window.makeFirstResponder(box.textViewForTesting)

        box.typeForTesting("SELECT name")
        box.pressReturnForTesting()
        box.typeForTesting("FROM customers LIMIT 3")
        XCTAssertEqual(box.string, "SELECT name\nFROM customers LIMIT 3",
                       "Return is a newline: a query is written over lines")
        XCTAssertEqual(pane.shownPage?.total, 120, "and nothing has run yet")

        try settle(pane) { box.pressRunForTesting() }
        XCTAssertEqual(pane.shownPage?.columns.map(\.name), ["name"])
        XCTAssertEqual(pane.shownPage?.total, 3)

        // Esc puts the question down and the table comes back.
        try settle(pane) { box.pressEscapeForTesting() }
        XCTAssertEqual(box.string, "")
        XCTAssertEqual(pane.shownPage?.total, 120)
    }

    // MARK: - Picking cells out of the grid

    @MainActor
    func testAClickPicksOneCellAndADragPicksOutARectangle() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        let down = try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                          row: 1, column: 2))
        grid.mouseDown(with: down)
        XCTAssertEqual(grid.selection, .cells(rows: 1...1, columns: 2...2))
        XCTAssertTrue(grid.selectedRowIndexes.isEmpty, "a cell and a row are never both up")
        XCTAssertEqual(grid.highlight(row: 1, column: 2).isCursor, true)

        // Dragging out to a cell two rows down and two columns across takes
        // the whole rectangle between them.
        let dragged = try XCTUnwrap(cellEvent(.leftMouseDragged, in: pane, window: window,
                                             row: 3, column: 4))
        grid.mouseDragged(with: dragged)
        XCTAssertEqual(grid.selection, .cells(rows: 1...3, columns: 2...4))
        // The hairline is drawn where the rectangle ends and nowhere inside.
        let corner = grid.highlight(row: 1, column: 2)
        XCTAssertTrue(corner.top && corner.leading)
        XCTAssertFalse(corner.bottom || corner.trailing)
        let middle = grid.highlight(row: 2, column: 3)
        XCTAssertTrue(middle.isSelected)
        XCTAssertFalse(middle.top || middle.leading || middle.bottom || middle.trailing)
        XCTAssertFalse(grid.highlight(row: 4, column: 3).isSelected)

        let copied = pane.copyTextForTesting(cellRows: 1...3, columns: 2...4)
        let lines = copied.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, "a line per row")
        XCTAssertEqual(lines[0].split(separator: "\t", omittingEmptySubsequences: false).count, 3,
                       "and only the columns inside the rectangle")
        let page = try XCTUnwrap(pane.shownPage)
        XCTAssertEqual(String(lines[0]), page.rows[1][1...3].map(\.displayText)
            .joined(separator: "\t"))
    }

    @MainActor
    func testTheGutterAndShiftTakeWholeRows() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        // A cell first, so there is something for the row click to put down.
        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                    row: 2, column: 3)))
        XCTAssertNotNil(grid.cellSelection)

        let gutter = try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                            row: 2, column: 0))
        grid.mouseDown(with: gutter)
        XCTAssertNil(grid.cellSelection, "the rectangle goes when a row is taken")
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet(integer: 2))
        XCTAssertEqual(grid.selection, .rows(IndexSet(integer: 2)))
        XCTAssertTrue(grid.highlight(row: 2, column: 0).isSelected, "and the gutter says so")

        // ⇧ over a cell means rows too, and the table extends the range.
        let shifted = try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                             row: 5, column: 3, shift: true))
        grid.mouseDown(with: shifted)
        XCTAssertNil(grid.cellSelection)
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet(integersIn: 2...5))

        let copied = pane.copyTextForTesting(rows: grid.selectedRowIndexes)
        XCTAssertEqual(copied.split(separator: "\n").count, 4)
        XCTAssertEqual(copied.split(separator: "\n")[0]
            .split(separator: "\t", omittingEmptySubsequences: false).count, 5,
                       "a whole row is every column of it")
    }

    @MainActor
    func testTheArrowsMoveTheCellCursorAndShiftGrowsTheRectangle() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        // Nothing picked out: the first arrow puts the cursor on the first
        // cell rather than moving something that is not there.
        grid.keyDown(with: try XCTUnwrap(key(125)))
        XCTAssertEqual(grid.selection, .cells(rows: 0...0, columns: 1...1))

        grid.keyDown(with: try XCTUnwrap(key(125)))  // ↓
        grid.keyDown(with: try XCTUnwrap(key(124)))  // →
        XCTAssertEqual(grid.selection, .cells(rows: 1...1, columns: 2...2))

        grid.keyDown(with: try XCTUnwrap(key(124, shift: true)))  // ⇧→
        grid.keyDown(with: try XCTUnwrap(key(125, shift: true)))  // ⇧↓
        XCTAssertEqual(grid.selection, .cells(rows: 1...2, columns: 2...3),
                       "⇧ grows the rectangle from where it was anchored")

        // ⌘C over the rectangle takes exactly it — onto a board of the test's
        // own, never the Mac's clipboard.
        let board = NSPasteboard(name: NSPasteboard.Name("SQLPreviewTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        grid.pasteboard = board
        grid.keyDown(with: try XCTUnwrap(key(8, command: true)))
        let copied = board.string(forType: .string) ?? ""
        XCTAssertEqual(copied, pane.copyTextForTesting(cellRows: 1...2, columns: 2...3))

        // Esc puts it down.
        grid.keyDown(with: try XCTUnwrap(key(53)))
        XCTAssertEqual(grid.selection, .none)
    }

    @MainActor
    func testANewPagePutsTheCellSelectionDown() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                    row: 2, column: 3)))
        XCTAssertNotNil(grid.cellSelection)
        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertNil(grid.cellSelection,
                     "row 2 column 3 of the last page is somebody else's value now")
    }

    // MARK: - A big dump waits to be asked

    @MainActor
    func testABigDumpRunsOnlyWhenAskedAndNeverAgainOnTyping() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("big.sql")
        let text = bigDump()
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: text,
                        attributes: [:], assets: nil)
        XCTAssertTrue(BigFile.isBig(length: note.storage.length))

        pane.show(note, in: context())
        XCTAssertEqual(pane.runCount, 0, "a hundred thousand inserts are not run on a glance")
        XCTAssertTrue(pane.showsRefreshButton, "the one button, and the only way in")
        XCTAssertNil(pane.shownPage)

        try settle(pane) { pane.pressRefreshForTesting() }
        XCTAssertEqual(pane.runCount, 1)
        XCTAssertEqual(pane.tables, ["big"])
        XCTAssertGreaterThan(pane.shownPage?.total ?? 0, 100)

        // Typing in a big dump does not run it again: the Run button is what
        // asks for that.
        note.storage.append(NSAttributedString(string: "INSERT INTO big VALUES (9, 'x');\n"))
        pane.show(note, in: context())
        pane.show(note, in: context())
        XCTAssertEqual(pane.runCount, 1, "still the one run the reader asked for")
    }

    @MainActor
    func testASmallDumpIsRunAgainWhenItsTextMovesAndNotWhenItDoesNot() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("small.sql")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil,
                        text: "CREATE TABLE a (x INTEGER);", attributes: [:], assets: nil)

        try show(note, in: pane)
        XCTAssertEqual(pane.runCount, 1)
        XCTAssertEqual(pane.tables, ["a"])

        // A resize and a tab switch ask again with the text unmoved.
        pane.show(note, in: context())
        pane.show(note, in: context())
        XCTAssertEqual(pane.runCount, 1, "nothing it is made from has moved")

        note.storage.append(NSAttributedString(string: "\nCREATE TABLE b (y TEXT);"))
        try show(note, in: pane)
        XCTAssertEqual(pane.runCount, 2)
        XCTAssertEqual(pane.tables, ["a", "b"], "unsaved edits are the database")
    }

    // MARK: - The session

    func testTheTableAndTheQuerySurviveASessionRoundTrip() throws {
        let file = URL(fileURLWithPath: "/tmp/Shop.sql")
        let note = Note(fileURL: file, untitledName: nil, text: "CREATE TABLE t (a);",
                        attributes: [:], assets: nil)
        note.previewMode = .split
        note.sqlTable = "orders"
        note.sqlQuery = "SELECT * FROM orders WHERE status = 'shipped'"

        let tab = note.sessionTab()
        XCTAssertEqual(tab.sqlTable, "orders")
        XCTAssertEqual(tab.sqlQuery, "SELECT * FROM orders WHERE status = 'shipped'")

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)
        XCTAssertEqual(decoded, tab)
        XCTAssertEqual(decoded.sqlTable, "orders")
        XCTAssertEqual(decoded.sqlQuery, "SELECT * FROM orders WHERE status = 'shipped'")
    }

    func testATabThatIsNotADumpKeepsNeitherOfThem() throws {
        let note = Note(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), untitledName: nil,
                        text: "hi", attributes: [:], assets: nil)
        note.sqlTable = "orders"
        note.sqlQuery = "SELECT 1"
        XCTAssertNil(note.sessionTab().sqlTable)
        XCTAssertNil(note.sessionTab().sqlQuery)
    }

    func testASessionWrittenBeforeDumpsHadAGridStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","path":"/tmp/Shop.sql","isDirty":false,
         "selection":0,"previewMode":"split"}
        """
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data(json.utf8))
        XCTAssertNil(tab.sqlTable)
        XCTAssertNil(tab.sqlQuery)
        XCTAssertEqual(tab.previewMode, .split)
    }

    @MainActor
    func testAWindowRestoresTheTableAndQueryOntoTheTab() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("Shop.sql")
        try exampleText("Shop.sql").write(to: file, atomically: true, encoding: .utf8)
        let store = SessionStore(directory: directory)
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil, isDirty: false,
                selection: 0, format: .default, previewMode: .split,
                sqlTable: "orders", sqlQuery: "SELECT * FROM orders"
            )],
            selectedTabID: id,
            fontSize: 13
        ))

        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }

        XCTAssertEqual(controller.currentTabDatabase.table, "orders")
        XCTAssertEqual(controller.currentTabDatabase.query, "SELECT * FROM orders")
        XCTAssertEqual(controller.previewState.mode, .split)
        XCTAssertTrue(controller.canShowRenderedPreview, "a dump has the three modes")
    }

    // MARK: - The buttons that say what the keys do

    /// "Run" over the box does what ⌘↩ does, for the reader who does not
    /// know the key; "Refresh" on the bar wears its word, not only its arrow.
    @MainActor
    func testTheRunButtonRunsTheBoxAndTheRefreshButtonSaysSo() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        XCTAssertEqual(pane.runButtonTitle, "Run")
        XCTAssertEqual(pane.refreshButtonTitle, "Refresh")

        pane.queryBoxForTesting.string = "SELECT id, name FROM customers WHERE city = 'Kyoto'"
        try settle(pane) { pane.pressRunQueryForTesting() }
        XCTAssertEqual(pane.shownPage?.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(pane.shownPage?.rows.count, 12)
    }

    // MARK: - The grid with nothing in it

    /// A table with no rows is still that table: its columns stand in the
    /// header over the striped rows, and the bar says "No rows".
    @MainActor
    func testAnEmptyTableKeepsItsColumnsInTheHeader() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "empty.sql", text: """
            CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT, price REAL);
            """), in: pane)
        XCTAssertFalse(pane.gridForTesting.enclosingScrollView?.isHidden ?? true, "the grid stays up")
        XCTAssertEqual(pane.gridForTesting.tableColumns.map(\.title), ["#", "id", "name", "price"])
        XCTAssertEqual(pane.gridForTesting.numberOfRows, 0)
        XCTAssertEqual(pane.rangeText, "No rows")
    }

    /// A file with no tables in it yet — a dump being started — shows a grid
    /// all the same: the gutter and three blank columns, nothing to sort.
    @MainActor
    func testAFileWithNoTablesShowsBlankColumns() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "nothing.sql", text: "-- nothing here yet\n"), in: pane)
        let grid = pane.gridForTesting
        XCTAssertFalse(grid.enclosingScrollView?.isHidden ?? true)
        XCTAssertEqual(grid.tableColumns.map(\.title), ["#", "", "", ""])
        XCTAssertEqual(Set(grid.tableColumns.map(\.identifier.rawValue)).count, 4,
                       "blank columns still tell apart")
        XCTAssertNil(pane.shownPage)
        XCTAssertEqual(pane.rangeText, "")

        // A header click on a blank column is not a sort of anything.
        pane.tableView(grid, didClick: grid.tableColumns[1])
        XCTAssertNil(pane.shownSort)
        XCTAssertTrue(alerts.isEmpty, "and not an alert either")
    }

    /// A query that finds nothing keeps the query's own columns, so the
    /// header still says what was asked for.
    @MainActor
    func testAQueryThatFindsNothingKeepsItsColumns() throws {
        let (pane, _) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        try settle(pane) { pane.setQueryForTesting("SELECT name, city FROM customers WHERE city = 'Nowhere'") }
        XCTAssertEqual(pane.gridForTesting.tableColumns.map(\.title), ["#", "name", "city"])
        XCTAssertEqual(pane.gridForTesting.numberOfRows, 0)
        XCTAssertEqual(pane.rangeText, "No rows")
    }

    // MARK: - Running it again

    /// One button rather than two: `arrow.clockwise` beside the picker runs
    /// the file as it stands now, and puts the reader back where they were —
    /// same table, same sort, same page.
    @MainActor
    func testTheRefreshButtonRunsTheFileAgainAndKeepsThePlace() throws {
        let (pane, window) = try makePane()
        let note = try exampleNote("Shop.sql")
        try show(note, in: pane)
        XCTAssertEqual(pane.runCount, 1)
        XCTAssertEqual(pane.refreshButtonTip, "Run again")

        try settle(pane) { clickHeader(of: pane, column: "name", in: window) }
        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertEqual(pane.rangeText, "101–120 of 120")

        // A table the file did not have before is proof the run was a fresh
        // database and not the one already standing.
        note.storage.append(NSAttributedString(string: "\nCREATE TABLE extras (a);\n"))
        try settle(pane) { pane.pressRefreshForTesting() }

        XCTAssertEqual(pane.runCount, 2)
        XCTAssertTrue(pane.tables.contains("extras"), "the file as it is now")
        XCTAssertEqual(pane.shownTable, "customers", "and the reader is where they were")
        XCTAssertEqual(pane.shownSort, SQLDump.Sort(column: "name", ascending: true))
        XCTAssertEqual(pane.rangeText, "101–120 of 120")
    }

    // MARK: - Space stands a row up

    /// Space takes the whole row the cell cursor is in — the same selection
    /// the `#` gutter makes — and Space again sits back down on the cell.
    /// Neither scrolls the grid, which is what a table would do with it.
    @MainActor
    func testSpaceStandsTheCursorUpIntoItsRowAndSitsItBackDown() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting
        let clip = try XCTUnwrap(grid.enclosingScrollView?.contentView)

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                     row: 2, column: 3)))
        XCTAssertEqual(grid.selection, .cells(rows: 2...2, columns: 3...3))
        let origin = clip.bounds.origin

        grid.keyDown(with: try XCTUnwrap(key(49)))
        XCTAssertEqual(grid.selection, .rows(IndexSet(integer: 2)), "the whole row")
        XCTAssertNil(grid.cellSelection, "and the rectangle is down")
        XCTAssertEqual(clip.bounds.origin, origin, "Space is not a page down")

        grid.keyDown(with: try XCTUnwrap(key(49)))
        XCTAssertEqual(grid.selection, .cells(rows: 2...2, columns: 3...3),
                       "back on the cell it stood up from")
        XCTAssertTrue(grid.selectedRowIndexes.isEmpty)
        XCTAssertEqual(clip.bounds.origin, origin)
    }

    /// A row picked out from the gutter was not stood up from anywhere, so
    /// Space over it has nowhere to sit back down and does nothing.
    @MainActor
    func testSpaceOverAGutterRowSelectionHasNothingToGoBackTo() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                     row: 1, column: 0)))
        XCTAssertEqual(grid.selection, .rows(IndexSet(integer: 1)))
        grid.keyDown(with: try XCTUnwrap(key(49)))
        XCTAssertEqual(grid.selection, .rows(IndexSet(integer: 1)), "unmoved")
    }

    // MARK: - Where a row is written

    func testEachRowsInsertIsWrittenDownAsTheFileRuns() throws {
        let text = """
        CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO customers VALUES (1, 'Ada');
        INSERT INTO customers VALUES (2, 'Bo');
        UPDATE customers SET name = 'Bo Jr' WHERE id = 2;
        """
        let dump = SQLDump(sql: text)
        XCTAssertNil(dump.failure)
        let source = text as NSString

        XCTAssertEqual(dump.sourceMap.range(ofRowid: 1, inTable: "customers"),
                       source.range(of: "INSERT INTO customers VALUES (1, 'Ada');"))
        // The row was changed further down the file and still points at where
        // it is *written*, which is what a reader clicking it is asking for.
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 2, inTable: "customers"),
                       source.range(of: "INSERT INTO customers VALUES (2, 'Bo');"))
        XCTAssertNil(dump.sourceMap.range(ofRowid: 9, inTable: "customers"),
                     "a rowid this file never wrote")
        XCTAssertNil(dump.sourceMap.range(ofRowid: 1, inTable: "nowhere"))
    }

    /// A multi-row insert lands on the row's own tuple, not on the statement's
    /// head: an insert of two hundred rows is not one place in the file.
    func testAMultiRowInsertLandsOnTheRowsOwnTuple() throws {
        let text = """
        CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT);
        INSERT INTO t (id, note) VALUES
          (1, 'one'),
          (2, 'two; not the end'),
          (3, 'three (really)');
        """
        let dump = SQLDump(sql: text)
        XCTAssertNil(dump.failure)
        let source = text as NSString

        XCTAssertEqual(dump.sourceMap.range(ofRowid: 2, inTable: "t"),
                       source.range(of: "(2, 'two; not the end')"))
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 3, inTable: "t"),
                       source.range(of: "(3, 'three (really)')"),
                       "a bracket inside the text is not the end of the tuple")
        // And the column list in front of VALUES is not one of the rows.
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 1, inTable: "t"),
                       source.range(of: "(1, 'one')"))
    }

    func testTheTupleLocatorCountsParenthesesOutsideStringsAndComments() throws {
        let tuples = SQLSourceMap.valueTuples(in: """
        INSERT INTO t (a, b) VALUES (1, 'a)b'), /* (nope) */ (2, "c)d"), (3, '--(');
        """)
        XCTAssertEqual(tuples.count, 3, "three rows, and nothing that only looks like one")
        let statement = """
        INSERT INTO t (a, b) VALUES (1, 'a)b'), /* (nope) */ (2, "c)d"), (3, '--(');
        """ as NSString
        XCTAssertEqual(tuples[0], statement.range(of: "(1, 'a)b')"))
        XCTAssertEqual(tuples[2], statement.range(of: "(3, '--(')"))
        // A statement with no VALUES at all has no tuples to offer.
        XCTAssertTrue(SQLSourceMap.valueTuples(in: "INSERT INTO t SELECT * FROM u;").isEmpty)
    }

    // MARK: - Where one value is written

    func testTheValueLocatorWalksATupleOnceAndHonoursWhatIsInIt() throws {
        let tuple = "(1, 'it''s, really', NULL, -3, X'4a4b', (1 + 2), \"a,b\")"
        let text = tuple as NSString
        func value(_ position: Int) throws -> String {
            text.substring(with: try XCTUnwrap(
                SQLSourceMap.valueRange(at: position, inTuple: tuple)
            ))
        }
        XCTAssertEqual(try value(0), "1")
        XCTAssertEqual(try value(1), "'it''s, really'",
                       "a comma and a doubled quote inside a string are text")
        XCTAssertEqual(try value(2), "NULL")
        XCTAssertEqual(try value(3), "-3", "the sign is part of the number")
        XCTAssertEqual(try value(4), "X'4a4b'", "a blob is its whole literal")
        XCTAssertEqual(try value(5), "(1 + 2)",
                       "an expression written as a value is one value")
        XCTAssertEqual(try value(6), "\"a,b\"")
        XCTAssertNil(SQLSourceMap.valueRange(at: 7, inTuple: tuple),
                     "there is no eighth value to point at")
        XCTAssertNil(SQLSourceMap.valueRange(at: 0, inTuple: "(1, 'never closed"),
                     "a tuple that does not close is nothing to measure from")
        XCTAssertEqual(
            SQLSourceMap.valueRange(at: 1, inTuple: "(1,   'a'   )"),
            ("(1,   'a'   )" as NSString).range(of: "'a'"),
            "the blanks around a value are none of it and its quotes are all of it"
        )
    }

    func testTheColumnListAnInsertNamesIsReadOffIt() throws {
        XCTAssertEqual(SQLSourceMap.insertColumns(in: "INSERT INTO t (a, B) VALUES (1, 2)"),
                       ["a", "b"])
        XCTAssertEqual(
            SQLSourceMap.insertColumns(in: "insert or replace into main.\"T\" (\"od d\") VALUES (1)"),
            ["od d"]
        )
        XCTAssertNil(SQLSourceMap.insertColumns(in: "INSERT INTO t VALUES (1, 2)"),
                     "an insert that named no columns writes the table's own order")
        XCTAssertNil(SQLSourceMap.insertColumns(in: "UPDATE t SET a = 1"))
    }

    /// A cell of a table's page is placed by its column's name, and what comes
    /// back is that value's own text — quotes included, comma and blanks left
    /// out.
    func testACellOfATableIsTakenToItsOwnValue() throws {
        let text = """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, tag TEXT);
        INSERT INTO notes VALUES
          (1, 'first, really', 'a'),
          (2, 'second', NULL);
        """
        let dump = SQLDump(sql: text)
        XCTAssertNil(dump.failure)
        let source = text as NSString
        let columns = dump.declaredTypes(ofTable: "notes").map(\.name)
        func value(_ rowid: Int64, _ column: String) throws -> String {
            source.substring(with: try XCTUnwrap(dump.sourceMap.range(
                ofRowid: rowid, inTable: "notes", column: column, tableColumns: columns
            )))
        }
        XCTAssertEqual(try value(1, "body"), "'first, really'")
        XCTAssertEqual(try value(1, "id"), "1")
        XCTAssertEqual(try value(2, "tag"), "NULL")
        XCTAssertEqual(try value(2, "BODY"), "'second'",
                       "SQLite's names are not case sensitive and neither is this")
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 2, inTable: "notes",
                                            column: "nowhere", tableColumns: columns),
                       source.range(of: "(2, 'second', NULL)"),
                       "a name in neither list falls back to the tuple, never to nothing")
        XCTAssertNil(dump.sourceMap.range(ofRowid: 9, inTable: "notes",
                                          column: "body", tableColumns: columns),
                     "and a rowid this file never wrote is still nothing at all")
    }

    /// An insert that named its own column list writes them in its own order,
    /// so the value is found by name and not by the table's order.
    func testAnInsertWithAColumnListIsMappedByName() throws {
        let text = """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, tag TEXT);
        INSERT INTO notes (tag, body, id) VALUES ('a', 'first', 1), ('b', 'second', 2);
        """
        let dump = SQLDump(sql: text)
        XCTAssertNil(dump.failure)
        let source = text as NSString
        let columns = dump.declaredTypes(ofTable: "notes").map(\.name)
        func value(_ rowid: Int64, _ column: String) throws -> String {
            source.substring(with: try XCTUnwrap(dump.sourceMap.range(
                ofRowid: rowid, inTable: "notes", column: column, tableColumns: columns
            )))
        }
        XCTAssertEqual(try value(1, "body"), "'first'", "the second value, as the list says")
        XCTAssertEqual(try value(1, "tag"), "'a'")
        XCTAssertEqual(try value(2, "id"), "2")
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 1, inTable: "notes",
                                            column: "missing", tableColumns: columns),
                       source.range(of: "('a', 'first', 1)"),
                       "a column the list never names is the tuple")
    }

    /// A query's own columns are placed by name too, and a column that is not
    /// a column of the table — a computed one — is the tuple instead.
    @MainActor
    func testAQuerysCellIsItsValueAndAComputedColumnIsTheTuple() throws {
        let text = """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
        INSERT INTO notes VALUES (1, 'first'), (2, 'second'), (3, 'third');
        """
        let (pane, window) = try makePane()
        try show(makeNote(named: "notes.sql", text: text), in: pane)
        pane.layoutSubtreeIfNeeded()
        let source = text as NSString
        var reveals: [NSRange] = []
        pane.onSourceReveal = { reveals.append($0) }
        pane.sendsBlockClicks = true

        try settle(pane) { pane.setQueryForTesting("SELECT body, id FROM notes") }
        pane.layoutSubtreeIfNeeded()
        pane.gridForTesting.mouseDown(
            with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                          row: 1, column: 1)))
        XCTAssertEqual(reveals.last.map { source.substring(with: $0) }, "'second'",
                       "the query's own first column is the table's second value")

        try settle(pane) { pane.setQueryForTesting("SELECT id * 2 FROM notes") }
        pane.layoutSubtreeIfNeeded()
        pane.gridForTesting.mouseDown(
            with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                          row: 2, column: 1)))
        XCTAssertEqual(reveals.last, source.range(of: "(3, 'third')"),
                       "a computed column is no column of the table, so the tuple is the answer")
    }

    func testTheTableNameIsReadOffTheInsertHoweverItIsSpelled() throws {
        XCTAssertEqual(SQLSourceMap.insertTable(in: "INSERT INTO customers VALUES (1)"),
                       "customers")
        XCTAssertEqual(SQLSourceMap.insertTable(in: "insert or replace into \"Order Items\" VALUES (1)"),
                       "order items")
        XCTAssertEqual(SQLSourceMap.insertTable(in: "INSERT INTO main.`odd name` VALUES (1)"),
                       "odd name")
        XCTAssertEqual(SQLSourceMap.insertTable(in: "REPLACE INTO [t] VALUES (1)"), "t")
        XCTAssertNil(SQLSourceMap.insertTable(in: "UPDATE t SET a = 1"))
        XCTAssertNil(SQLSourceMap.insertTable(in: "CREATE TABLE t (a)"))
    }

    /// A quoted name in the file is the same table as the plain one in the
    /// picker, so a click on its rows still finds the statement.
    func testAQuotedTableNameIsStillTheTableThePickerNames() throws {
        let text = """
        CREATE TABLE "Order Items" (id INTEGER PRIMARY KEY, qty INTEGER);
        INSERT INTO "Order Items" VALUES (1, 4);
        """
        let dump = SQLDump(sql: text)
        XCTAssertNil(dump.failure)
        XCTAssertEqual(dump.tables, ["Order Items"])
        XCTAssertEqual(dump.sourceMap.range(ofRowid: 1, inTable: "Order Items"),
                       (text as NSString).range(of: "INSERT INTO \"Order Items\" VALUES (1, 4);"))
    }

    /// A `WITHOUT ROWID` table has no rowid to look anything up by, so it has
    /// no map and no page of rowids — and a click on it does nothing rather
    /// than landing on somebody else's line.
    func testAWithoutRowidTableHasNothingToPointAt() throws {
        let text = """
        CREATE TABLE codes (code TEXT PRIMARY KEY, label TEXT) WITHOUT ROWID;
        INSERT INTO codes VALUES ('a', 'Alpha');
        """
        let dump = SQLDump(sql: text)
        XCTAssertNil(dump.failure)
        XCTAssertNil(dump.sourceMap.range(ofRowid: 1, inTable: "codes"))
        XCTAssertNil(try page(of: dump, table: "codes").rowids, "and no rowids on the page")
    }

    func testAPageOfATableCarriesItsRowidsAndAJoinsResultDoesNot() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let table = try page(of: dump, table: "customers")
        XCTAssertEqual(table.rowids?.count, 100)
        XCTAssertEqual(table.rowidTable, "customers")
        XCTAssertEqual(table.columns.map(\.name).first, "id", "the rowid is not a column")
        XCTAssertFalse(table.columns.contains { $0.name == "rowid" })

        let joined = try page(of: dump, query: """
            SELECT c.name, o.id FROM customers c JOIN orders o ON o.customer_id = c.id
            """)
        XCTAssertNil(joined.rowids, "two tables' rows are neither table's")
        XCTAssertNil(joined.rowidTable)
    }

    // MARK: - A query that reads one table

    /// The common query is a table read with a `WHERE` on it, and its rows are
    /// that table's rows: they come back carrying its rowids, so a value in
    /// the grid can go back to the `INSERT` that wrote it.
    func testAQueryThatReadsOneTableCarriesThatTablesRowids() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        for query in [
            "SELECT id, name FROM customers",
            "SELECT * FROM customers",
            "SELECT c.name FROM customers c",
            "SELECT name FROM customers AS c WHERE city = 'Cork' ORDER BY name",
            "select name from customers;",
        ] {
            let answer = try page(of: dump, query: query)
            XCTAssertEqual(answer.rowidTable?.lowercased(), "customers", query)
            XCTAssertEqual(answer.rowids?.count, answer.rows.count, query)
            XCTAssertFalse(answer.columns.contains { $0.name == SQLQueryRewrite.rowidColumn },
                           "and the rowid never reaches the grid: \(query)")
        }

        // The columns are the reader's own, in the reader's own order.
        let two = try page(of: dump, query: "SELECT city, name FROM customers")
        XCTAssertEqual(two.columns.map(\.name), ["city", "name"])
        let all = try page(of: dump, query: "SELECT * FROM customers")
        XCTAssertEqual(all.columns.map(\.name), ["id", "name", "city", "email", "joined"])
        XCTAssertEqual(all.total, 120, "and the count is the query's count")
    }

    /// The rewrite is a splice and nothing else: the rowid goes in after the
    /// `SELECT` keyword and every other character stays where it was written.
    func testTheRewriteOnlyAddsTheRowidToWhatWasTyped() throws {
        let rewrite = try XCTUnwrap(
            SQLQueryRewrite.carryingRowid("SELECT name, city\nFROM customers\nWHERE id > 5")
        )
        XCTAssertEqual(rewrite.table, "customers")
        XCTAssertEqual(rewrite.sql,
                       "SELECT \"customers\".rowid AS \"__nota_rowid\", name, city\n"
                       + "FROM customers\nWHERE id > 5")
        // An alias is what the rowid is asked of: `customers` is out of reach
        // once the reader has renamed it.
        XCTAssertEqual(SQLQueryRewrite.carryingRowid("SELECT * FROM customers c")?.sql,
                       "SELECT \"c\".rowid AS \"__nota_rowid\", * FROM customers c")
        XCTAssertEqual(SQLQueryRewrite.carryingRowid("select * from customers as C")?.sql,
                       "select \"C\".rowid AS \"__nota_rowid\", * from customers as C")
    }

    /// Anything that is not plainly one table's rows is left exactly as it was
    /// written: no rowids, and no alert either — the query still runs.
    func testAQueryOfAnyOtherShapeIsLeftAsItWasWritten() throws {
        for query in [
            "SELECT c.name, o.id FROM customers c JOIN orders o ON o.customer_id = c.id",
            "SELECT c.name, o.id FROM customers c, orders o WHERE o.customer_id = c.id",
            "SELECT city, COUNT(*) FROM customers GROUP BY city",
            "SELECT COUNT(*) FROM customers",
            "SELECT DISTINCT city FROM customers",
            "WITH c AS (SELECT * FROM customers) SELECT * FROM c",
            "SELECT name FROM customers UNION SELECT name FROM products",
            "SELECT name FROM (SELECT name FROM customers)",
            "SELECT name FROM customers ORDER BY 1",
            "SELECT 1",
        ] {
            XCTAssertNil(SQLQueryRewrite.carryingRowid(query), "not one table's rows: \(query)")
        }

        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let grouped = try page(of: dump, query: "SELECT city, COUNT(*) FROM customers GROUP BY city")
        XCTAssertNil(grouped.rowids, "and it is still answered, with nothing to point at")
        XCTAssertNil(grouped.rowidTable)
        XCTAssertGreaterThan(grouped.rows.count, 0)

        // A column called `total` or `count` is a column and not the
        // aggregate: an aggregate is a word with a `(` after it.
        let counted = SQLDump(sql: """
        CREATE TABLE tallies (id INTEGER PRIMARY KEY, count INTEGER, total REAL);
        INSERT INTO tallies VALUES (1, 3, 9.5);
        """)
        let totals = try page(of: counted, query: "SELECT count, total FROM tallies")
        XCTAssertEqual(totals.rowidTable?.lowercased(), "tallies")
        XCTAssertEqual(totals.rowids, [1])
    }

    /// A `WITHOUT ROWID` table has no rowid to be asked for, so the query that
    /// reads it is run as written.
    func testAQueryOfAWithoutRowidTableCarriesNoRowids() throws {
        let dump = SQLDump(sql: """
        CREATE TABLE codes (code TEXT PRIMARY KEY, label TEXT) WITHOUT ROWID;
        INSERT INTO codes VALUES ('a', 'Alpha'), ('b', 'Beta');
        """)
        XCTAssertNil(dump.failure)
        let answer = try page(of: dump, query: "SELECT label FROM codes")
        XCTAssertNil(answer.rowids)
        XCTAssertNil(answer.rowidTable)
        XCTAssertEqual(answer.rows.count, 2, "and the query itself is answered as ever")
    }

    /// The parse is loose, so it is sometimes wrong — an alias in quotes is
    /// not read as one, and the rowid is then asked of a name the alias has
    /// taken away. SQLite refuses the rewrite and the reader's own query is
    /// run instead, with no rowids and nothing said about any of it.
    func testARewriteSQLiteRefusesFallsBackToTheQueryAsWritten() throws {
        let quotedAlias = "SELECT name FROM customers \"c\" WHERE id < 4"
        let rewrite = try XCTUnwrap(SQLQueryRewrite.carryingRowid(quotedAlias))
        XCTAssertTrue(rewrite.sql.contains("\"customers\".rowid"),
                      "the rewrite asks for a name the alias has taken away")

        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let answer = try page(of: dump, query: quotedAlias)
        XCTAssertNil(answer.rowids, "so the rewrite is dropped")
        XCTAssertEqual(answer.columns.map(\.name), ["name"])
        XCTAssertEqual(answer.rows.count, 3, "and the query is exactly the one that was typed")
    }

    /// The count, a header's sort and the second page are all asked of the
    /// rewritten query, so none of them loses the rowids.
    func testACountASortAndASecondPageAllKeepTheRowids() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let first = try page(of: dump, query: "SELECT id, name FROM customers")
        XCTAssertEqual(first.total, 120)
        XCTAssertEqual(first.rowids?.count, 100)

        let second = try page(of: dump, query: "SELECT id, name FROM customers", offset: 100)
        XCTAssertEqual(second.rows.count, 20)
        XCTAssertEqual(second.rowids?.count, 20)
        XCTAssertEqual(second.rowidTable?.lowercased(), "customers")

        let sorted = try page(of: dump, query: "SELECT id, name FROM customers",
                              sort: SQLDump.Sort(column: "name", ascending: true))
        XCTAssertEqual(sorted.rowids?.count, 100)
        // The rowid moved with its row: the first row of the sorted page is
        // the row the map says it is.
        let text = try exampleText("Shop.sql") as NSString
        let rowid = try XCTUnwrap(sorted.rowids?.first)
        let range = try XCTUnwrap(dump.sourceMap.range(ofRowid: rowid, inTable: "customers"))
        XCTAssertTrue(text.substring(with: range)
            .contains(sorted.rows[0][1].displayText), text.substring(with: range))
    }

    // MARK: - A cell clicked is a line in the editor

    /// In split, clicking a value walks the editor to the `INSERT` that wrote
    /// it — its own tuple in a multi-row one — and leaves the keyboard in the
    /// grid, so the arrows go on walking the cells.
    @MainActor
    func testClickingACellInSplitSelectsThatValueAndKeepsTheKeyboard() throws {
        _ = NSApplication.shared
        let text = """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
        INSERT INTO notes VALUES (1, 'first'), (2, 'second'), (3, 'third');
        """
        let controller = try makeController(showing: text, named: "Notes.sql")
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        let pane = controller.previewPanes.sql
        try waitForPage(pane)
        window.layoutIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                     row: 1, column: 2)))

        XCTAssertEqual(controller.editorScrolling.textView.selectedRange(),
                       (text as NSString).range(of: "'second'"),
                       "the clicked cell's own value inside the second row's tuple")
        XCTAssertTrue(window.firstResponder === grid,
                      "the grid keeps the keyboard: this is a look, not a jump")
    }

    /// Reading mode has no editor on screen, so a click on a value is a click
    /// on a value and nothing else.
    @MainActor
    func testClickingACellInReadingModeSaysNothing() throws {
        let (pane, window) = try makePane()
        try show(makeNote(named: "notes.sql", text: """
            CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
            INSERT INTO notes VALUES (1, 'first'), (2, 'second');
            """), in: pane)
        pane.layoutSubtreeIfNeeded()
        var reveals: [NSRange] = []
        pane.onSourceReveal = { reveals.append($0) }

        pane.sendsBlockClicks = false
        pane.gridForTesting.mouseDown(
            with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                          row: 1, column: 2)))
        XCTAssertTrue(reveals.isEmpty, "nothing to point at when there is no editor")

        pane.sendsBlockClicks = true
        pane.gridForTesting.mouseDown(
            with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                          row: 1, column: 2)))
        XCTAssertEqual(reveals.count, 1, "and in split it says exactly once")
    }

    /// A query that is not one table's rows has no rowid, so there is nothing
    /// to take back to the file and a click on one is quiet.
    @MainActor
    func testClickingACellOfAJoinsResultSaysNothing() throws {
        let (pane, window) = try makePane()
        try show(try exampleNote("Shop.sql"), in: pane)
        try settle(pane) {
            pane.setQueryForTesting("""
                SELECT c.name, o.id FROM customers c JOIN orders o ON o.customer_id = c.id
                """)
        }
        pane.layoutSubtreeIfNeeded()
        var reveals: [NSRange] = []
        pane.onSourceReveal = { reveals.append($0) }
        pane.gridForTesting.mouseDown(
            with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                          row: 1, column: 1)))
        XCTAssertTrue(reveals.isEmpty)
    }

    /// A query that reads one table is read like the table: a click on one of
    /// its values walks the editor to the `INSERT` that wrote that row, its
    /// own tuple in a multi-row one.
    @MainActor
    func testClickingACellOfAQuerysResultSelectsItsValue() throws {
        _ = NSApplication.shared
        let text = """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
        INSERT INTO notes VALUES (1, 'first'), (2, 'second'), (3, 'third');
        """
        let controller = try makeController(showing: text, named: "Notes.sql")
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        let pane = controller.previewPanes.sql
        try waitForPage(pane)
        try settle(pane) { pane.setQueryForTesting("SELECT body FROM notes WHERE id > 1") }
        window.layoutIfNeeded()
        let grid = pane.gridForTesting
        XCTAssertEqual(grid.numberOfRows, 2, "the query's own two rows")

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                     row: 1, column: 1)))

        XCTAssertEqual(controller.editorScrolling.textView.selectedRange(),
                       (text as NSString).range(of: "'third'"),
                       "the third row's own body, through the query")
        XCTAssertTrue(window.firstResponder === grid, "and the grid keeps the keyboard")
    }

    /// Running a query, running the file again and turning the page each
    /// replace every row on screen — and none of them leaves the grid unable
    /// to pick a cell out afterwards. One click both takes the keyboard from
    /// the query box and picks the cell out; there is no click to spare.
    @MainActor
    func testTheCellCursorStillWorksAfterAQueryARefreshAndAPage() throws {
        let (pane, window) = try makePane()
        let note = try exampleNote("Shop.sql")
        try show(note, in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting
        var clicks: [Int] = []
        let paneAnswers = grid.onCellClick
        grid.onCellClick = { row, column in
            clicks.append(row)
            paneAnswers?(row, column)
        }

        func clickCell(row: Int, _ what: String) throws {
            pane.layoutSubtreeIfNeeded()
            grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                         row: row, column: 2)))
            XCTAssertEqual(grid.cellCursor?.row, row, "the cursor lands \(what)")
            XCTAssertEqual(grid.cellCursor?.column, 2, "on the cell that was clicked \(what)")
            XCTAssertEqual(clicks.last, row, "and the click is reported \(what)")
        }

        try clickCell(row: 1, "on the table")

        // The typing was in the box when ⌘↩ ran the query, which is where a
        // reader leaves it.
        try settle(pane) {
            window.makeFirstResponder(pane.queryBoxForTesting.textViewForTesting)
            pane.setQueryForTesting("SELECT id, name FROM customers")
        }
        try clickCell(row: 2, "after the query")

        try settle(pane) { pane.pressRefreshForTesting() }
        try clickCell(row: 3, "after the file was run again")

        try settle(pane) { pane.pressNextForTesting() }
        try clickCell(row: 4, "after the page was turned")
        XCTAssertEqual(clicks.count, 4)
    }

    /// The same query, through the window: a click after a run reaches the
    /// editor beside the grid, which is the whole point of split.
    @MainActor
    func testACellClickedAfterAQueryStillReachesTheEditorInSplit() throws {
        _ = NSApplication.shared
        let text = """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
        INSERT INTO notes VALUES (1, 'first');
        INSERT INTO notes VALUES (2, 'second');
        """
        let controller = try makeController(showing: text, named: "Notes.sql")
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        let pane = controller.previewPanes.sql
        try waitForPage(pane)
        try settle(pane) {
            window.makeFirstResponder(pane.queryBoxForTesting.textViewForTesting)
            pane.setQueryForTesting("SELECT body FROM notes")
        }
        window.layoutIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                     row: 1, column: 1)))
        XCTAssertEqual(grid.cellCursor?.row, 1, "the cell is picked out")
        XCTAssertEqual(controller.editorScrolling.textView.selectedRange(),
                       (text as NSString).range(of: "'second'"),
                       "and the editor holds the clicked value of the row's own insert")
    }

    // MARK: - The grid with nothing in it, drawn

    /// The empty grid is the same table with nothing in it: the striped rows
    /// run on under the header rather than leaving a blank sheet. Read off
    /// the drawing itself, since it is the drawing that was wrong.
    @MainActor
    func testTheEmptyGridDrawsItsStripedRows() throws {
        let (pane, window) = try makePane()
        try show(makeNote(named: "empty.sql", text: """
            CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT, price REAL);
            """), in: pane)
        window.layoutIfNeeded()
        let grid = pane.gridForTesting
        XCTAssertEqual(grid.numberOfRows, 0)
        XCTAssertGreaterThan(grid.bounds.height, grid.rowHeight * 3,
                             "the grid fills the room under the header")

        grid.displayIfNeeded()
        let rep = try XCTUnwrap(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
        grid.cacheDisplay(in: grid.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / grid.bounds.width
        func brightness(atRow row: Int) throws -> CGFloat {
            let y = Int(((CGFloat(row) + 0.5) * grid.rowHeight) * scale)
            let colour = try XCTUnwrap(rep.colorAt(x: Int(120 * scale), y: y))
            return try XCTUnwrap(colour.usingColorSpace(.deviceRGB)).brightnessComponent
        }
        let first = try brightness(atRow: 0)
        let second = try brightness(atRow: 1)
        XCTAssertNotEqual(first, second, accuracy: 0,
                          "two rows of nothing still alternate")
        XCTAssertGreaterThan(abs(first - second), 0.005,
                             "and the stripe is actually drawn: \(first) vs \(second)")
    }

    // MARK: - Helpers

    /// A window over one dump, in split, the way a session brings one back.
    @MainActor
    private func makeController(
        showing text: String, named name: String
    ) throws -> MainWindowController {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = SessionStore(directory: directory)
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil, isDirty: false,
                selection: 0, format: .default, previewMode: .split
            )],
            selectedTabID: id,
            fontSize: 13
        ))
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 620))
        window.layoutIfNeeded()
        return controller
    }

    /// Waits for a pane a window built for itself, which has no `onDidFinish`
    /// a test could have hung on in time.
    @MainActor
    private func waitForPage(_ pane: SQLPreviewView, timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while pane.shownPage == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(pane.shownPage, "the database never answered")
    }

    @MainActor
    private func makePane() throws -> (SQLPreviewView, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        let pane = SQLPreviewView(frame: frame)
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        // Never a real modal in a test: a sheet or a `runModal` here would
        // hang the run rather than fail it.
        pane.alertOverrideForTesting = { [weak self] message, informative in
            self?.alerts.append((message, informative))
        }
        window.layoutIfNeeded()
        return (pane, window)
    }

    /// Clicks a column header the way a reader does — a press on the header
    /// view itself, with the release already in the queue so the header's own
    /// tracking loop finds it and ends.
    @MainActor
    private func clickHeader(of pane: SQLPreviewView, column: String, in window: NSWindow) {
        let grid = pane.gridForTesting
        guard let header = grid.headerView else { return XCTFail("no header to click") }
        let index = grid.column(withIdentifier: NSUserInterfaceItemIdentifier(column))
        guard index >= 0 else { return XCTFail("no column named \(column)") }
        let rect = header.headerRect(ofColumn: index)
        let point = header.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.02,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0
        ) else { return XCTFail("no events") }
        window.postEvent(up, atStart: false)
        header.mouseDown(with: down)
    }

    /// A mouse event over the middle of one cell of the grid.
    @MainActor
    private func cellEvent(
        _ type: NSEvent.EventType, in pane: SQLPreviewView, window: NSWindow,
        row: Int, column: Int, shift: Bool = false
    ) -> NSEvent? {
        let grid = pane.gridForTesting
        let rect = grid.frameOfCell(atColumn: column, row: row)
        let point = grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: shift ? [.shift] : [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 3, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    @MainActor
    private func key(_ code: UInt16, shift: Bool = false, command: Bool = false) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        let characters = command ? "c" : (code == 49 ? " " : "")
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )
    }

    private func context(visible: Bool = true) -> PreviewContext {
        PreviewContext(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                       assets: nil, isVisible: visible)
    }

    /// Shows the note and waits for the database and its first page to have
    /// landed — both are built off the main thread, so nothing about the pane
    /// is true the instant the call returns.
    @MainActor
    private func show(_ note: Note, in pane: SQLPreviewView) throws {
        try settle(pane) { pane.show(note, in: context()) }
    }

    /// Does something to the pane and waits for whatever it set off.
    @MainActor
    private func settle(_ pane: SQLPreviewView, _ body: () -> Void) throws {
        let finished = expectation(description: "the database answered")
        finished.assertForOverFulfill = false
        pane.onDidFinish = { finished.fulfill() }
        body()
        wait(for: [finished], timeout: 20)
        pane.onDidFinish = nil
    }

    private func page(
        of dump: SQLDump, table: String, offset: Int = 0
    ) throws -> SQLDump.Page {
        switch dump.page(ofTable: table, offset: offset) {
        case .success(let page): return page
        case .failure(let failure):
            throw XCTSkip("the page did not come back: \(failure.message)")
        }
    }

    /// One page of a query, failing the test rather than the page: every
    /// query asked for here is one the box is meant to answer.
    private func page(
        of dump: SQLDump, query: String, offset: Int = 0, sort: SQLDump.Sort? = nil
    ) throws -> SQLDump.Page {
        switch dump.page(ofQuery: query, offset: offset, sort: sort) {
        case .success(let page): return page
        case .failure(let failure):
            throw XCTSkip("the query did not come back: \(failure.message)")
        }
    }

    /// A dump past the big-file threshold, and cheap to build: one table and
    /// enough inserts to take it over a million characters.
    private func bigDump() -> String {
        let statement = "INSERT INTO big VALUES (1, 'a row of a big dump');\n"
        let repeats = (BigFile.threshold / statement.utf16.count) + 200
        return "CREATE TABLE big (id INTEGER, note TEXT);\n"
            + String(repeating: statement, count: repeats)
    }

    private func makeNote(named name: String, text: String) -> Note {
        Note(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), untitledName: nil,
             text: text, attributes: [:], assets: nil)
    }

    private func exampleNote(_ name: String) throws -> Note {
        let file = exampleURL(name)
        return Note(fileURL: file, untitledName: nil, text: try exampleText(name),
                    attributes: [:], assets: nil)
    }

    private func exampleText(_ name: String) throws -> String {
        try String(contentsOf: exampleURL(name), encoding: .utf8)
    }

    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaSQLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
