import AppKit
import Foundation
import PDFKit
import XCTest
@testable import Nota

/// The Export button on the two grids, and what stands behind it: `CSVWriter`
/// itself, `SQLDump.forEachRow` and `CSVTable.exportRows` walking every row in
/// the grid's own sort order, and the button's place before the pager, wired
/// through the stubbed `exportDestination` seam so a test never puts a real
/// panel on screen.
final class CSVExportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var windows: [NSWindow] = []

    @MainActor
    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - CSVWriter

    func testAPlainFieldNeedsNoQuotes() {
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [["hello"]]), "a\nhello\n")
    }

    func testACommaQuotesTheField() {
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [["a,b"]]), "a\n\"a,b\"\n")
    }

    func testADoubleQuoteIsDoubledAndTheFieldQuoted() {
        XCTAssertEqual(
            CSVWriter.write(header: ["a"], rows: [[#"say "hi""#]]),
            "a\n\"say \"\"hi\"\"\"\n"
        )
    }

    func testANewlineQuotesTheField() {
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [["line1\nline2"]]),
                       "a\n\"line1\nline2\"\n")
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [["line1\rline2"]]),
                       "a\n\"line1\rline2\"\n")
    }

    func testNilIsWrittenEmptyAndNeverQuoted() {
        XCTAssertEqual(CSVWriter.write(header: ["a", "b"], rows: [[nil, "x"]]), "a,b\n,x\n")
    }

    func testLeadingOrTrailingSpaceQuotesTheField() {
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [[" x"]]), "a\n\" x\"\n")
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [["x "]]), "a\n\"x \"\n")
        // A space in the middle of a field, with nothing at either edge, is
        // exactly the field it looks like and needs nothing done to it.
        XCTAssertEqual(CSVWriter.write(header: ["a"], rows: [["x y"]]), "a\nx y\n")
    }

    func testAnEmptyRowSetIsJustTheHeader() {
        XCTAssertEqual(CSVWriter.write(header: ["a", "b"], rows: []), "a,b\n")
    }

    func testTheStreamingWriteMatchesTheInMemoryOne() throws {
        let header = ["id", "name", "notes"]
        let rows: [[String?]] = [
            ["1", "Ashby Notebook, A5", nil],
            ["2", #"Pen, "rollerball""#, " leading space"],
        ]
        let inMemory = CSVWriter.write(header: header, rows: rows)

        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("stream.csv")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try CSVWriter.write(header: header, to: handle)
        for row in rows { try CSVWriter.write(row: row, to: handle) }
        try handle.close()

        let streamed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(streamed, inMemory)
    }

    // MARK: - SQLDump.forEachRow

    func testForEachRowWalksATableInSortOrderWithNoLimit() {
        let dump = SQLDump(sql: """
            CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);
            INSERT INTO t VALUES (3, 'c'), (1, 'a'), (2, 'b');
            """)
        var columns: [SQLDump.Column] = []
        var rows: [[SQLDump.Value]] = []
        let failure = dump.forEachRow(
            ofTable: "t", sort: SQLDump.Sort(column: "id", ascending: true),
            onColumns: { columns = $0 }, onRow: { rows.append($0) }
        )
        XCTAssertNil(failure)
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertEqual(rows.map { $0[0] }, [.integer(1), .integer(2), .integer(3)])
    }

    /// The query variant must still refuse a write — the same authorizer the
    /// query box itself reads under — and touch nothing when it does.
    func testForEachRowOfAQueryRespectsTheReadOnlyAuthorizer() {
        let dump = SQLDump(sql: "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), (2);")
        var rows: [[SQLDump.Value]] = []
        let failure = dump.forEachRow(
            ofQuery: "DELETE FROM t", onColumns: { _ in }, onRow: { rows.append($0) }
        )
        XCTAssertNotNil(failure, "a write is refused, not quietly run")
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(dump.rowCount(ofTable: "t"), 2, "the delete never ran")
    }

    /// A table larger than one page (`SQLDump.pageSize`) still exports every
    /// row: `forEachRow` carries no `LIMIT` at all.
    func testForEachRowOfATableLargerThanAPageExportsEveryRow() {
        let count = SQLDump.pageSize + 37
        var sql = "CREATE TABLE big (id INTEGER PRIMARY KEY, name TEXT);\n"
        for index in 1...count { sql += "INSERT INTO big VALUES (\(index), 'row \(index)');\n" }
        let dump = SQLDump(sql: sql)
        XCTAssertNil(dump.failure)
        var rows: [[SQLDump.Value]] = []
        let failure = dump.forEachRow(ofTable: "big", onColumns: { _ in }, onRow: { rows.append($0) })
        XCTAssertNil(failure)
        XCTAssertEqual(rows.count, count)
    }

    // MARK: - CSVTable.exportRows

    func testExportRowsWalksInSortOrderAndNilsAMissingTrailingField() {
        let table = CSVTable(text: "a,b,c\n1,2,3\n4,5\n", separator: .comma)
        let export = table.exportRows()
        XCTAssertEqual(export.header, ["a", "b", "c"])
        XCTAssertEqual(export.rows[0], ["1", "2", "3"])
        XCTAssertEqual(export.rows[1], ["4", "5", nil],
                       "the ragged row never wrote a third field at all")
    }

    func testExportRowsRespectsADescendingSort() {
        let table = CSVTable(text: "n\n3\n1\n2\n", separator: .comma)
        let export = table.exportRows(sort: CSVTable.Sort(column: 0, ascending: false))
        XCTAssertEqual(export.rows.map { $0[0] }, ["3", "2", "1"])
    }

    // MARK: - Examples, exported through SQLDump and parsed back

    /// `Shop.sql`, `Examples/sql/MySQL.sql` and `Examples/sql/PostgreSQL.sql`
    /// each export the `customers` table the same way, whatever dialect wrote
    /// the dump: the row count matches `rowCount(ofTable:)`, the header
    /// matches the schema, and a descending sort puts the highest id first.
    func testExportingCustomersFromEachDialectRoundTrips() throws {
        for file in ["Shop.sql", "sql/MySQL.sql", "sql/PostgreSQL.sql"] {
            let dump = SQLDump(sql: try exampleText(file))
            XCTAssertNil(dump.failure, "\(file) should run whole")
            let expectedCount = try XCTUnwrap(dump.rowCount(ofTable: "customers"), file)
            let expectedColumns = dump.declaredTypes(ofTable: "customers").map(\.name)

            var writtenColumns: [String] = []
            var writtenRows: [[String?]] = []
            let failure = dump.forEachRow(
                ofTable: "customers", sort: SQLDump.Sort(column: "id", ascending: false),
                onColumns: { writtenColumns = $0.map(\.name) },
                onRow: { values in writtenRows.append(values.map(Self.csvField)) }
            )
            XCTAssertNil(failure, file)
            XCTAssertEqual(writtenColumns, expectedColumns, file)

            let csv = CSVWriter.write(header: writtenColumns, rows: writtenRows)
            let reparsed = CSVTable(text: csv, separator: .comma)
            XCTAssertEqual(reparsed.rows.count, expectedCount, file)
            XCTAssertEqual(reparsed.columns, expectedColumns, file)

            // Sorted descending by id: the first row of the reparsed table is
            // the highest id in the file.
            let idIndex = try XCTUnwrap(expectedColumns.firstIndex(of: "id"), file)
            let ids = reparsed.rows.compactMap { Int($0[idIndex]) }
            XCTAssertEqual(ids, ids.sorted(by: >), file)
            XCTAssertEqual(reparsed.rows.first?[idIndex], String(ids.max() ?? 0), file)
        }
    }

    /// A query's own result exports too, with fewer rows than the whole
    /// table it reads.
    func testExportOfAQueryResultHasFewerRowsThanTheTable() throws {
        let dump = SQLDump(sql: try exampleText("Shop.sql"))
        let total = try XCTUnwrap(dump.rowCount(ofTable: "customers"))
        var rows: [[SQLDump.Value]] = []
        let failure = dump.forEachRow(
            ofQuery: "SELECT * FROM customers WHERE city = 'Kyoto'",
            onColumns: { _ in }, onRow: { rows.append($0) }
        )
        XCTAssertNil(failure)
        XCTAssertGreaterThan(rows.count, 0, "the fixture has at least one Kyoto customer")
        XCTAssertLessThan(rows.count, total)
    }

    private static func csvField(_ value: SQLDump.Value) -> String? {
        if case .null = value { return nil }
        return value.displayText
    }

    // MARK: - Products.csv round trip, and a .tsv exporting comma-separated

    func testProductsCSVRoundTrips() throws {
        let text = try exampleText("Products.csv")
        let table = CSVTable(text: text, separator: .comma)
        let export = table.exportRows()
        let written = CSVWriter.write(header: export.header, rows: export.rows)
        let reparsed = CSVTable(text: written, separator: .comma)
        XCTAssertEqual(reparsed.columns, table.columns)
        XCTAssertEqual(reparsed.rows, table.rows)
    }

    func testATSVFixtureExportsAsCommaSeparated() {
        let text = "a\tb\tc\n1\t2\t3\nfour\tfive, six\tseven\n"
        let table = CSVTable(text: text, separator: .tab)
        let export = table.exportRows()
        let written = CSVWriter.write(header: export.header, rows: export.rows)
        XCTAssertTrue(written.contains(","), "the writer always separates on commas")
        // The row that itself held a comma had to be quoted for it — the one
        // tab-separated character that would otherwise change what a comma
        // reader sees.
        XCTAssertTrue(written.contains("\"five, six\""))
        let reparsed = CSVTable(text: written, separator: .comma)
        XCTAssertEqual(reparsed.rows, table.rows)
    }

    // MARK: - The button: SQL pane

    @MainActor
    func testTheExportButtonSitsBeforeThePagerInTheSQLPane() throws {
        let (pane, _) = try makeSQLPane()
        let subviews = pane.barSubviewsForTesting
        let exportIndex = try XCTUnwrap(subviews.firstIndex(of: pane.exportButtonForTesting))
        let previousIndex = try XCTUnwrap(subviews.firstIndex(where: {
            $0.accessibilityIdentifier() == "sql-previous"
        }))
        let nextIndex = try XCTUnwrap(subviews.firstIndex(where: {
            $0.accessibilityIdentifier() == "sql-next"
        }))
        XCTAssertLessThan(exportIndex, previousIndex)
        XCTAssertLessThan(exportIndex, nextIndex)
        XCTAssertEqual(pane.exportButtonTip, "Export as CSV…")
    }

    @MainActor
    func testClickingExportInTheSQLPaneGoesThroughTheStubbedSeamAndWritesTheFile() throws {
        let (pane, _) = try makeSQLPane()
        let note = try exampleSQLNote("Shop.sql")
        try showSQL(note, in: pane)

        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("customers.csv")
        var askedName: String?
        pane.exportDestination = { name, columns in
            askedName = name
            return CSVExportChoice(url: destination, columns: Array(columns.indices))
        }
        pane.pressExportForTesting()

        XCTAssertEqual(askedName, "customers.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("id,name,city,email,joined\n"))
    }

    /// The panel cancelled — `exportDestination` returns `nil` — writes
    /// nothing at all.
    @MainActor
    func testCancellingTheSQLExportPanelWritesNothing() throws {
        let (pane, _) = try makeSQLPane()
        let note = try exampleSQLNote("Shop.sql")
        try showSQL(note, in: pane)
        pane.exportDestination = { _, _ in nil }
        pane.pressExportForTesting()
        // No crash, and nothing to assert a file against — the destination
        // was never handed out.
    }

    /// A query in the box is what the Export button reaches for, and its
    /// default name says so.
    @MainActor
    func testExportingAQueryResultUsesTheQueryDefaultName() throws {
        let (pane, _) = try makeSQLPane()
        let note = try exampleSQLNote("Shop.sql")
        try showSQL(note, in: pane)
        try settleSQL(pane) {
            pane.setQueryForTesting("SELECT * FROM customers WHERE city = 'Kyoto'")
        }

        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("query.csv")
        var askedName: String?
        pane.exportDestination = { name, columns in
            askedName = name
            return CSVExportChoice(url: destination, columns: Array(columns.indices))
        }
        pane.pressExportForTesting()

        XCTAssertEqual(askedName, "Shop-query.csv")
        let written = try String(contentsOf: destination, encoding: .utf8)
        let table = CSVTable(text: written, separator: .comma)
        XCTAssertGreaterThan(table.rows.count, 0)
        XCTAssertLessThan(table.rows.count, try XCTUnwrap(
            SQLDump(sql: try exampleText("Shop.sql")).rowCount(ofTable: "customers")
        ))
    }

    // MARK: - The button: CSV pane

    @MainActor
    func testTheExportButtonSitsBeforeThePagerInTheCSVPane() throws {
        let (pane, _) = try makeCSVPane()
        let subviews = pane.barSubviewsForTesting
        let exportIndex = try XCTUnwrap(subviews.firstIndex(of: pane.exportButtonForTesting))
        let previousIndex = try XCTUnwrap(subviews.firstIndex(where: {
            $0.accessibilityIdentifier() == "csv-previous"
        }))
        let nextIndex = try XCTUnwrap(subviews.firstIndex(where: {
            $0.accessibilityIdentifier() == "csv-next"
        }))
        XCTAssertLessThan(exportIndex, previousIndex)
        XCTAssertLessThan(exportIndex, nextIndex)
        XCTAssertEqual(pane.exportButtonTip, "Export as CSV…")
    }

    @MainActor
    func testClickingExportInTheCSVPaneGoesThroughTheStubbedSeamAndWritesTheFile() throws {
        let (pane, _) = try makeCSVPane()
        let note = makeCSVNote(named: "Products.csv", text: try exampleText("Products.csv"))
        try showCSV(note, in: pane)

        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("Products.csv")
        var askedName: String?
        pane.exportDestination = { name, columns in
            askedName = name
            return CSVExportChoice(url: destination, columns: Array(columns.indices))
        }
        pane.pressExportForTesting()

        XCTAssertEqual(askedName, "Products.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let written = try String(contentsOf: destination, encoding: .utf8)
        let reparsed = CSVTable(text: written, separator: .comma)
        XCTAssertEqual(reparsed.rows.count, pane.shownTable?.rows.count)
    }

    /// A `.tsv` note's default export name is still `.csv`.
    @MainActor
    func testATSVNoteDefaultsToACSVExportName() throws {
        let (pane, _) = try makeCSVPane()
        let note = makeCSVNote(named: "rows.tsv", text: "a\tb\n1\t2\n")
        try showCSV(note, in: pane)
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("rows.csv")
        var askedName: String?
        pane.exportDestination = { name, columns in
            askedName = name
            return CSVExportChoice(url: destination, columns: Array(columns.indices))
        }
        pane.pressExportForTesting()
        XCTAssertEqual(askedName, "rows.csv")
    }

    // MARK: - Preview as PDF — the grid on pages

    /// A `.csv` tab's `Preview as PDF` is the grid itself, ruled onto pages,
    /// and not the source listing it used to fall to: the cells are on the
    /// page and the line they were written on as one comma-joined record is
    /// not. The sort a header click put on the grid comes with them, since
    /// the rows are read off the pane rather than off the file.
    @MainActor
    func testACSVTabExportsItsGridOntoPagesRatherThanItsSource() throws {
        Exporter.installDefaultHooks()
        let (pane, _) = try makeCSVPane()
        let note = makeCSVNote(named: "People.csv", text: "name,city\nAda,London\nGrace,Paris\n")
        try showCSV(note, in: pane)

        let directory = try makeTemporaryDirectory()
        var text = try previewPDFText(of: note, pane: pane,
                                      at: directory.appendingPathComponent("grid.pdf"))
        for cell in ["name", "city", "Ada", "London", "Grace", "Paris"] {
            XCTAssertTrue(text.contains(cell), "“\(cell)” is missing from the page")
        }
        XCTAssertFalse(text.contains("Ada,London"),
                       "the grid on pages, not the source listing")

        // The same tab, sorted by name the other way round: the pages follow
        // the grid, so the rows come out in the order on screen.
        try settleCSV(pane) { pane.clickHeaderForTesting(at: 0) }
        try settleCSV(pane) { pane.clickHeaderForTesting(at: 0) }
        XCTAssertEqual(pane.shownSort, CSVTable.Sort(column: 0, ascending: false))

        text = try previewPDFText(of: note, pane: pane,
                                  at: directory.appendingPathComponent("sorted.pdf"))
        let grace = try XCTUnwrap(text.range(of: "Grace"))
        let ada = try XCTUnwrap(text.range(of: "Ada"))
        XCTAssertLessThan(grace.lowerBound, ada.lowerBound,
                          "descending by name puts Grace on the row above Ada")
    }

    /// A pane in front of the tab is not a pane that has read it: the column
    /// being hidden — the tab exported or printed from editor mode — leaves
    /// the pane with no table behind it, and a big file is not read until the
    /// button asks for it either. The listing stands in for both, the way it
    /// does for a tab with no pane at all, rather than the export failing.
    @MainActor
    func testACSVTabWithAnUnreadPaneFallsBackToTheSourceListing() throws {
        Exporter.installDefaultHooks()
        let (pane, _) = try makeCSVPane()
        let note = makeCSVNote(named: "People.csv", text: "name,city\nAda,London\nGrace,Paris\n")
        // No settle: nothing is read, so the pane never finishes anything.
        pane.show(note, in: csvContext(visible: false))

        let url = try makeTemporaryDirectory().appendingPathComponent("listing.pdf")
        let text = try previewPDFText(of: note, pane: pane, at: url)
        XCTAssertTrue(text.contains("Ada,London"),
                      "the source listing, comma-joined line and all")
    }

    /// File › Export… → Preview as PDF, with the pane in front of the tab,
    /// and the one page it wrote read back.
    @MainActor
    private func previewPDFText(
        of note: Note, pane: any PreviewContent, at url: URL
    ) throws -> String {
        var context = Exporter.Context(
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            paragraphStyle: NSParagraphStyle.default,
            assets: nil,
            showsLineNumbers: false,
            images: .inline
        )
        context.previewContent = pane

        let finished = expectation(description: "export finished")
        var outcome: Result<Void, Error>?
        Exporter.export(note, to: .previewPDF, at: url, context: context) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        try XCTUnwrap(outcome, "the export never answered").get()

        let document = try XCTUnwrap(PDFDocument(url: url), "no readable PDF was written")
        XCTAssertEqual(document.pageCount, 1)
        return try XCTUnwrap(XCTUnwrap(document.page(at: 0)).string)
    }

    // MARK: - SQL pane helpers

    @MainActor
    private func makeSQLPane() throws -> (SQLPreviewView, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        let pane = SQLPreviewView(frame: frame)
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        pane.alertOverrideForTesting = { _, _ in }
        window.layoutIfNeeded()
        return (pane, window)
    }

    private func sqlContext(visible: Bool = true) -> PreviewContext {
        PreviewContext(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                       assets: nil, isVisible: visible)
    }

    @MainActor
    private func showSQL(_ note: Note, in pane: SQLPreviewView) throws {
        try settleSQL(pane) { pane.show(note, in: sqlContext()) }
    }

    @MainActor
    private func settleSQL(_ pane: SQLPreviewView, _ body: () -> Void) throws {
        let finished = expectation(description: "the database answered")
        finished.assertForOverFulfill = false
        pane.onDidFinish = { finished.fulfill() }
        body()
        wait(for: [finished], timeout: 20)
        pane.onDidFinish = nil
    }

    private func exampleSQLNote(_ name: String) throws -> Note {
        Note(fileURL: exampleURL(name), untitledName: nil, text: try exampleText(name),
             attributes: [:], assets: nil)
    }

    // MARK: - CSV pane helpers

    @MainActor
    private func makeCSVPane() throws -> (CSVPreviewView, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        let pane = CSVPreviewView(frame: frame)
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        window.layoutIfNeeded()
        return (pane, window)
    }

    private func csvContext(visible: Bool = true) -> PreviewContext {
        PreviewContext(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                       assets: nil, isVisible: visible)
    }

    @MainActor
    private func showCSV(_ note: Note, in pane: CSVPreviewView) throws {
        try settleCSV(pane) { pane.show(note, in: csvContext()) }
    }

    @MainActor
    private func settleCSV(_ pane: CSVPreviewView, _ body: () -> Void) throws {
        let finished = expectation(description: "the file was read")
        finished.assertForOverFulfill = false
        pane.onDidFinish = { finished.fulfill() }
        body()
        wait(for: [finished], timeout: 20)
        pane.onDidFinish = nil
    }

    private func makeCSVNote(named name: String, text: String) -> Note {
        Note(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), untitledName: nil,
             text: text, attributes: [:], assets: nil)
    }

    // MARK: - Shared helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaCSVExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
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
}
