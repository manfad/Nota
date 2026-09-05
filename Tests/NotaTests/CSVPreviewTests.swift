import AppKit
import Foundation
import XCTest
@testable import Nota

/// The preview that is only read. A `.csv` or `.tsv` tab is a tab like a `.md`
/// one — the same three modes, the same control, the same session — and what
/// stands beside the source is the table the file already is, a hundred rows
/// at a time, in the grid a dump is read in.
final class CSVPreviewTests: XCTestCase {
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

    // MARK: - What counts as a table

    func testATableIsKnownByItsSpellingWhateverCaseItIsIn() throws {
        for spelling in ["csv", "CSV", "Csv", "tsv", "TSV"] {
            XCTAssertEqual(RenderedPreviewKind(fileExtension: spelling), .csv,
                           "\(spelling) is a delimited file")
        }
        for spelling in ["txt", "sql", "md", "tab", "psv"] {
            XCTAssertNotEqual(RenderedPreviewKind(fileExtension: spelling), .csv,
                              "\(spelling) is not one Nota reads as a table")
        }
        XCTAssertEqual(CSVTable.Separator(fileExtension: "csv"), .comma)
        XCTAssertEqual(CSVTable.Separator(fileExtension: "TSV"), .tab)
        XCTAssertNil(CSVTable.Separator(fileExtension: "txt"))
    }

    func testATableHasTheThreeModesAndAPlainTextFileHasNone() throws {
        let table = makeNote(named: "Products.csv", text: "a,b\n1,2\n")
        XCTAssertEqual(table.previewKind, .csv)
        XCTAssertTrue(table.supportsRenderedPreview, "so ⇧⌘P and the control mean something")
        XCTAssertTrue(table.hasPreviewContent)
        table.previewMode = .split
        XCTAssertEqual(table.previewMode, .split)
        table.previewMode = .reading
        XCTAssertEqual(table.previewMode, .reading)

        let plain = makeNote(named: "rows.txt", text: "a,b\n1,2\n")
        XCTAssertNil(plain.previewKind, "the same commas in a .txt are text")
        XCTAssertFalse(plain.supportsRenderedPreview)
        XCTAssertFalse(plain.hasPreviewContent)

        let untitled = Note(fileURL: nil, untitledName: "Untitled", text: "a,b\n1,2\n",
                            attributes: [:], assets: nil)
        XCTAssertNil(untitled.previewKind, "Save As to .csv is what makes one")
    }

    @MainActor
    func testTheTableIsTheColumnsEighthContent() throws {
        _ = NSApplication.shared
        XCTAssertEqual(PreviewContentKind(makeNote(named: "Products.csv", text: "")), .csv)
        XCTAssertEqual(PreviewContentKind(makeNote(named: "Rows.tsv", text: "")), .csv)

        let column = PreviewPaneView(dragBandHeight: 12)
        column.bringForward(makeNote(named: "Products.csv", text: ""))
        XCTAssertEqual(column.panes.kind, .csv)
        XCTAssertTrue(column.panes.showsTable)
        XCTAssertFalse(column.panes.showsDatabase, "a table is not a database")
        XCTAssertFalse(column.panes.csv.isHidden)
        XCTAssertTrue(column.panes.sql.isHidden)
        XCTAssertTrue(column.panes.markdown.isHidden)

        column.bringForward(makeNote(named: "notes.txt", text: ""))
        XCTAssertTrue(column.panes.csv.isHidden, "and it waits behind the render again")
    }

    // MARK: - Reading the file

    func testTheHeaderIsTheFirstRecordAndTheRestAreRows() throws {
        let table = CSVTable(text: "id,name,price\n1,Pencil,1.20\n2,Lamp,44.00\n",
                             separator: .comma)
        XCTAssertEqual(table.columns, ["id", "name", "price"])
        XCTAssertEqual(table.rows, [["1", "Pencil", "1.20"], ["2", "Lamp", "44.00"]])
    }

    func testAQuotedFieldHoldsSeparatorsQuotesAndNewlines() throws {
        let text = #"""
        id,name,notes
        1,"Notebook, A5","Ruled, 96 pages"
        2,"Sleeve 16""","Fits a 16"" laptop"
        3,Chair,"Assembly required.
        Two people, twenty minutes."
        """#
        let table = CSVTable(text: text, separator: .comma)
        XCTAssertEqual(table.rows[0], ["1", "Notebook, A5", "Ruled, 96 pages"],
                       "a comma inside the quotes is text")
        XCTAssertEqual(table.rows[1], ["2", "Sleeve 16\"", "Fits a 16\" laptop"],
                       "\"\" is one quote")
        XCTAssertEqual(table.rows[2],
                       ["3", "Chair", "Assembly required.\nTwo people, twenty minutes."],
                       "and a newline inside the quotes is not the end of the record")
        XCTAssertEqual(table.rows.count, 3, "three records over four lines")
    }

    func testAQuoteInAFieldThatDoesNotOpenWithOneIsACharacter() throws {
        let table = CSVTable(text: "a,b\nSleeve 14\",x\n", separator: .comma)
        XCTAssertEqual(table.rows, [["Sleeve 14\"", "x"]], "five inches, not a quoted field")
    }

    func testCRLFAndALoneCREndARecordJustAsLFDoes() throws {
        for ending in ["\r\n", "\r", "\n"] {
            let text = "a,b" + ending + "1,2" + ending + "3,4" + ending
            let table = CSVTable(text: text, separator: .comma)
            XCTAssertEqual(table.columns, ["a", "b"], "line ending \(ending.debugDescription)")
            XCTAssertEqual(table.rows, [["1", "2"], ["3", "4"]],
                           "line ending \(ending.debugDescription)")
        }
    }

    func testATrailingNewlineIsAnEndingRatherThanAnEmptyRow() throws {
        XCTAssertEqual(CSVTable(text: "a,b\n1,2\n", separator: .comma).rows, [["1", "2"]])
        XCTAssertEqual(CSVTable(text: "a,b\n1,2", separator: .comma).rows, [["1", "2"]],
                       "and a file with no trailing newline reads the same")
        XCTAssertEqual(CSVTable(text: "a,b\n\n1,2\n\n", separator: .comma).rows, [["1", "2"]],
                       "a blank line is whitespace, not a row of nothing")
    }

    func testRaggedRowsArePaddedAndLongOnesWidenTheTable() throws {
        let table = CSVTable(text: "a,b,c\n1\n1,2,3,4\n", separator: .comma)
        XCTAssertEqual(table.columns, ["a", "b", "c", "Column 4"],
                       "the long row widens it, and the column it made is named for its place")
        XCTAssertEqual(table.rows, [["1", "", "", ""], ["1", "2", "3", "4"]])
    }

    func testABlankHeaderCellIsNamedForItsPlace() throws {
        let table = CSVTable(text: "id,,price\n1,x,2\n", separator: .comma)
        XCTAssertEqual(table.columns, ["id", "Column 2", "price"])
    }

    func testAHeaderOnlyFileIsColumnsAndNoRows() throws {
        let table = CSVTable(text: "id,name,price\n", separator: .comma)
        XCTAssertEqual(table.columns, ["id", "name", "price"])
        XCTAssertTrue(table.rows.isEmpty)
        let page = table.page(offset: 0)
        XCTAssertEqual(page.total, 0)
        XCTAssertEqual(TextStats.rowRange(first: page.first, last: page.last,
                                          total: page.total), "No rows")
    }

    func testAnEmptyFileIsAnEmptyTable() throws {
        for text in ["", "\n", "   \n\n"] {
            let table = CSVTable(text: text, separator: .comma)
            XCTAssertTrue(table.rows.isEmpty, text.debugDescription)
            XCTAssertTrue(table.columns.isEmpty || table.columns == ["Column 1"],
                          "nothing to head a table with: \(table.columns)")
        }
        XCTAssertTrue(CSVTable(text: "", separator: .comma).columns.isEmpty)
    }

    func testAByteOrderMarkIsNotTheFirstLetterOfTheFirstHeader() throws {
        let table = CSVTable(text: "\u{FEFF}id,name\n1,Pencil\n", separator: .comma)
        XCTAssertEqual(table.columns, ["id", "name"])
        XCTAssertEqual(table.rows, [["1", "Pencil"]])
        XCTAssertEqual(table.sources.first?.location, 9,
                       "and the mark is still one character of the file the row is measured in")
    }

    func testATabSeparatedFileIsReadOnTabs() throws {
        let table = CSVTable(text: "id\tname\n1\tPencil, HB\n", separator: .tab)
        XCTAssertEqual(table.columns, ["id", "name"])
        XCTAssertEqual(table.rows, [["1", "Pencil, HB"]], "a comma is a character in a .tsv")
    }

    // MARK: - Pages

    func testATableIsReadAHundredRowsAtATime() throws {
        let table = CSVTable(text: generated(rows: 250), separator: .comma)
        XCTAssertEqual(table.rows.count, 250)

        let first = table.page(offset: 0)
        XCTAssertEqual(first.rows.count, 100)
        XCTAssertEqual(first.total, 250)
        XCTAssertEqual(first.first, 1)
        XCTAssertEqual(first.last, 100)
        XCTAssertEqual(first.rows.first?[0], "1")

        let last = table.page(offset: 200)
        XCTAssertEqual(last.rows.count, 50)
        XCTAssertEqual(last.first, 201)
        XCTAssertEqual(last.last, 250)

        XCTAssertEqual(table.page(offset: 900).offset, 200, "and never past the last page")
        XCTAssertEqual(CSVTable.clamp(offset: -10, total: 250), 0)
    }

    @MainActor
    func testThePageButtonsWalkTheTableAndStopAtItsEnds() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "big.csv", text: generated(rows: 250)), in: pane)
        XCTAssertEqual(pane.rangeText, "1–100 of 250")

        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertEqual(pane.rangeText, "101–200 of 250")
        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertEqual(pane.rangeText, "201–250 of 250")
        pane.pressNextForTesting()
        XCTAssertEqual(pane.rangeText, "201–250 of 250", "the last page is the last page")
        try settle(pane) { pane.pressPreviousForTesting() }
        XCTAssertEqual(pane.rangeText, "101–200 of 250")
    }

    // MARK: - Sorting

    func testAColumnOfNumbersIsSortedAsNumbers() throws {
        let table = CSVTable(text: "n,name\n9,i\n10,j\n2,k\n", separator: .comma)
        let up = table.page(offset: 0, sort: CSVTable.Sort(column: 0, ascending: true))
        XCTAssertEqual(up.rows.map { $0[0] }, ["2", "9", "10"], "9 before 10, not after it")
        let down = table.page(offset: 0, sort: CSVTable.Sort(column: 0, ascending: false))
        XCTAssertEqual(down.rows.map { $0[0] }, ["10", "9", "2"])
    }

    func testAColumnWithOneWordInItIsSortedAsText() throws {
        let table = CSVTable(text: "n\n9\n10\nx\n", separator: .comma)
        let up = table.page(offset: 0, sort: CSVTable.Sort(column: 0, ascending: true))
        XCTAssertEqual(up.rows.map { $0[0] }, ["10", "9", "x"],
                       "one value that is not a number makes the whole column text")
    }

    func testTextIsSortedTheReadersOwnWayAndCaseIsNotAnOrder() throws {
        let table = CSVTable(text: "name\nbeta\nAlpha\ndelta\nCharlie\n", separator: .comma)
        let up = table.page(offset: 0, sort: CSVTable.Sort(column: 0, ascending: true))
        XCTAssertEqual(up.rows.map { $0[0] }, ["Alpha", "beta", "Charlie", "delta"])
    }

    func testAnEmptyCellSortsBeforeEverything() throws {
        let table = CSVTable(text: "n,x\n3,a\n,b\n1,c\n", separator: .comma)
        let up = table.page(offset: 0, sort: CSVTable.Sort(column: 0, ascending: true))
        XCTAssertEqual(up.rows.map { $0[0] }, ["", "1", "3"], "nothing sorts before everything")
        let down = table.page(offset: 0, sort: CSVTable.Sort(column: 0, ascending: false))
        XCTAssertEqual(down.rows.map { $0[0] }, ["3", "1", ""])
    }

    @MainActor
    func testAHeaderClickSortsTheWholeTableAndTheSecondClickTurnsItRound() throws {
        let (pane, window) = try makePane()
        try show(makeNote(named: "big.csv", text: generated(rows: 250)), in: pane)
        // Page two first, so the sort is plainly of the table and not of the
        // hundred rows on screen.
        try settle(pane) { pane.pressNextForTesting() }

        try settle(pane) { clickHeader(of: pane, at: 0, named: "n", in: window) }
        XCTAssertEqual(pane.shownSort, CSVTable.Sort(column: 0, ascending: true))
        XCTAssertEqual(pane.rangeText, "1–100 of 250", "a sort goes back to the top")
        XCTAssertEqual(pane.shownPage?.rows.first?[0], "1")

        try settle(pane) { clickHeader(of: pane, at: 0, named: "n", in: window) }
        XCTAssertEqual(pane.shownSort, CSVTable.Sort(column: 0, ascending: false))
        XCTAssertEqual(pane.shownPage?.rows.first?[0], "250")
    }

    @MainActor
    func testTheSortedColumnWearsTheChevronAndTheGutterIsNotSortable() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "rows.csv", text: "a,b\n2,x\n1,y\n"), in: pane)
        try settle(pane) { pane.clickHeaderForTesting(at: 1) }

        let grid = pane.gridForTesting
        func chevron(atColumn column: Int) -> Bool? {
            (grid.tableColumns[column].headerCell as? SQLHeaderCell)?.sortAscending ?? nil
        }
        XCTAssertNil(chevron(atColumn: 0), "the # gutter is not a column of the file")
        XCTAssertNil(chevron(atColumn: 1))
        XCTAssertEqual(chevron(atColumn: 2), true, "the one that was clicked")

        // The gutter is not sortable however it is clicked.
        pane.clickHeaderForTesting(at: -1)
        XCTAssertEqual(pane.shownSort, CSVTable.Sort(column: 1, ascending: true))
    }

    // MARK: - Live, and the refresh button

    @MainActor
    func testTheEditorsTextIsWhatIsShownAndItIsReadAgainWhenItMoves() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("rows.csv")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: "a,b\n1,2\n",
                        attributes: [:], assets: nil)

        try show(note, in: pane)
        XCTAssertEqual(pane.readCount, 1)
        XCTAssertEqual(pane.shownPage?.total, 1)

        // A resize and a tab switch ask again with the text unmoved.
        pane.show(note, in: context())
        pane.show(note, in: context())
        XCTAssertEqual(pane.readCount, 1, "nothing it is made from has moved")

        note.storage.append(NSAttributedString(string: "3,4\n"))
        try show(note, in: pane)
        XCTAssertEqual(pane.readCount, 2)
        XCTAssertEqual(pane.shownPage?.total, 2, "unsaved edits are the table")
        XCTAssertEqual(pane.shownPage?.rows.last, ["3", "4"])
    }

    @MainActor
    func testABigFileIsReadOnlyWhenAskedAndNeverAgainOnTyping() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("big.csv")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: bigTable(),
                        attributes: [:], assets: nil)
        XCTAssertTrue(BigFile.isBig(length: note.storage.length))

        pane.show(note, in: context())
        XCTAssertEqual(pane.readCount, 0, "a hundred thousand rows are not read on a glance")
        XCTAssertTrue(pane.showsRefreshButton, "the one button, and the only way in")
        XCTAssertNil(pane.shownPage)
        XCTAssertEqual(pane.emptyText, "Refresh to read this file.")

        try settle(pane) { pane.pressRefreshForTesting() }
        XCTAssertEqual(pane.readCount, 1)
        XCTAssertGreaterThan(pane.shownPage?.total ?? 0, 100)
        XCTAssertEqual(pane.emptyText, "", "and the instruction goes when it is done")

        note.storage.append(NSAttributedString(string: "9,9,9\n"))
        pane.show(note, in: context())
        pane.show(note, in: context())
        XCTAssertEqual(pane.readCount, 1, "still the one read the reader asked for")
    }

    @MainActor
    func testRefreshKeepsTheSortAndThePageAndTypingDoesNot() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("rows.csv")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: generated(rows: 250),
                        attributes: [:], assets: nil)
        try show(note, in: pane)

        try settle(pane) { pane.clickHeaderForTesting(at: 0) }
        try settle(pane) { pane.pressNextForTesting() }
        XCTAssertEqual(pane.shownSort, CSVTable.Sort(column: 0, ascending: true))
        XCTAssertEqual(pane.rangeText, "101–200 of 250")

        try settle(pane) { pane.pressRefreshForTesting() }
        XCTAssertEqual(pane.readCount, 2)
        XCTAssertEqual(pane.shownSort, CSVTable.Sort(column: 0, ascending: true),
                       "the reader asked for the same reading again")
        XCTAssertEqual(pane.rangeText, "101–200 of 250")

        // A read the *file* asked for is a different table; the columns may
        // not even be the same ones, so the order goes.
        note.storage.append(NSAttributedString(string: "999,row 999\n"))
        try show(note, in: pane)
        XCTAssertNil(pane.shownSort)
    }

    @MainActor
    func testTheRefreshButtonWearsItsWordAndThePagersHaveTheirTips() throws {
        let (pane, _) = try makePane()
        XCTAssertTrue(pane.showsRefreshButton)
        XCTAssertEqual(pane.refreshButtonTitle, "Refresh")
        XCTAssertEqual(pane.refreshButtonTip, "Read again")
    }

    @MainActor
    func testTheBarStartsBelowTheCornerSlotsBand() throws {
        let (pane, _) = try makePane()
        pane.layoutSubtreeIfNeeded()
        let bar = pane.barFrameForTesting
        XCTAssertEqual(pane.bounds.maxY - bar.maxY, ModeControlOverlay.hoverBandHeight,
                       accuracy: 0.5,
                       "the floating mode control never covers the header row")
    }

    // MARK: - The footer

    @MainActor
    func testTheFooterSaysRowsAndColumnsAndWhichOnesAreOnScreen() throws {
        XCTAssertEqual(TextStats.rowAndColumnCounts(rows: 2345, columns: 6),
                       "2,345 rows · 6 columns")
        XCTAssertEqual(TextStats.rowAndColumnCounts(rows: 1, columns: 1),
                       "1 row · 1 column", "singulars, the way they are said")

        let (pane, _) = try makePane()
        try show(makeNote(named: "big.csv", text: generated(rows: 250)), in: pane)
        let status = try XCTUnwrap(pane.footerStatus)
        XCTAssertEqual(status.summary, "250 rows · 2 columns")
        XCTAssertEqual(status.position, "Rows 1–100 of 250")
    }

    @MainActor
    func testThePaneAnswersForTheFooterOnlyWhileTheColumnIsOnScreen() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "rows.csv", text: "a,b\n1,2\n"), in: pane)
        XCTAssertNotNil(pane.footerStatus)

        pane.show(makeNote(named: "rows.csv", text: "a,b\n1,2\n"), in: context(visible: false))
        XCTAssertNil(pane.footerStatus, "in the editor mode a .csv is source like any other")
    }

    // MARK: - Copying

    @MainActor
    func testCopyingTakesWhatIsDrawnTabSeparated() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "rows.csv", text: "a,b,c\n1,2,3\n4,5,6\n"), in: pane)
        XCTAssertEqual(pane.copyTextForTesting(rows: IndexSet([0, 1])), "1\t2\t3\n4\t5\t6")
        XCTAssertEqual(pane.copyTextForTesting(cellRows: 0...1, columns: 2...3), "2\t3\n5\t6",
                       "only the columns inside the rectangle, and never the # gutter")
    }

    // MARK: - Where a row is written

    func testEachRowKnowsWhichLinesItIsWrittenOn() throws {
        let text = """
        id,name
        1,Pencil
        2,"Assembly required.
        Two people."
        3,Lamp
        """
        let table = CSVTable(text: text, separator: .comma)
        let source = text as NSString
        XCTAssertEqual(table.sources.count, 3)
        XCTAssertEqual(source.substring(with: table.sources[0]), "1,Pencil")
        XCTAssertEqual(source.substring(with: table.sources[1]),
                       "2,\"Assembly required.\nTwo people.\"",
                       "both lines the record is written over")
        XCTAssertEqual(table.sources[1].location, source.range(of: "2,\"Assembly").location,
                       "and it begins where the record begins")
        XCTAssertEqual(source.substring(with: table.sources[2]), "3,Lamp")
    }

    @MainActor
    func testClickingACellInSplitMovesTheCaretAndKeepsTheKeyboard() throws {
        _ = NSApplication.shared
        let text = """
        id,name
        1,Pencil
        2,"Assembly required.
        Two people."
        3,Lamp
        """
        let controller = try makeController(showing: text, named: "Rows.csv")
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        let pane = controller.previewPanes.csv
        try waitForPage(pane)
        window.layoutIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(cellEvent(.leftMouseDown, in: pane, window: window,
                                                     row: 1, column: 2)))
        XCTAssertEqual(controller.currentTabState.selection,
                       (text as NSString).range(of: "2,\"Assembly").location,
                       "the first line of the record, quoted field and all")
        XCTAssertTrue(window.firstResponder === grid,
                      "the grid keeps the keyboard: this is a look, not a jump")
    }

    @MainActor
    func testClickingACellInReadingModeSaysNothing() throws {
        let (pane, window) = try makePane()
        try show(makeNote(named: "rows.csv", text: "a,b\n1,2\n3,4\n"), in: pane)
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
        XCTAssertEqual(reveals.first?.location, ("a,b\n1,2\n" as NSString).length,
                       "the second row, where the second row is written")
    }

    // MARK: - The demo file

    func testTheExampleReadsAsItIsWritten() throws {
        let table = CSVTable(text: try exampleText("Products.csv"), separator: .comma)
        XCTAssertEqual(table.columns,
                       ["id", "name", "category", "price", "in_stock", "notes"])
        XCTAssertEqual(table.rows.count, 40)
        XCTAssertEqual(table.rows[0][1], "Ashby Notebook, A5", "a comma inside the quotes")
        XCTAssertEqual(table.rows[19][5], "Fits a 16\" laptop", "and a quote inside them")
        XCTAssertTrue(table.rows[8][5].contains("\n"), "one record is written over two lines")
    }

    // MARK: - The session

    func testTheModeIsAllTheSessionKeepsAboutATable() throws {
        let note = makeNote(named: "Products.csv", text: "a,b\n1,2\n")
        note.previewMode = .reading

        let tab = note.sessionTab()
        XCTAssertEqual(tab.previewMode, .reading)
        XCTAssertNil(tab.sqlTable, "a table has no database to be left in")
        XCTAssertNil(tab.sqlQuery)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)
        XCTAssertEqual(decoded, tab)
        XCTAssertEqual(decoded.previewMode, .reading)
    }

    @MainActor
    func testAWindowBringsATableBackInTheModeItWasLeftIn() throws {
        _ = NSApplication.shared
        let controller = try makeController(showing: "a,b\n1,2\n", named: "Rows.csv")
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        XCTAssertEqual(controller.previewMode, .split, "the mode the session was written with")
        XCTAssertTrue(controller.canShowRenderedPreview)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .csv)
        XCTAssertTrue(controller.previewPanes.showsTable)
        try waitForPage(controller.previewPanes.csv)
        XCTAssertEqual(controller.previewPanes.csv.shownPage?.total, 1)
    }

    // MARK: - Helpers

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
    private func waitForPage(_ pane: CSVPreviewView, timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while pane.shownPage == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(pane.shownPage, "the file was never read")
    }

    @MainActor
    private func makePane() throws -> (CSVPreviewView, NSWindow) {
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

    /// Clicks a column header the way a reader does — a press on the header
    /// view itself, with the release already in the queue so the header's own
    /// tracking loop finds it and ends.
    @MainActor
    private func clickHeader(
        of pane: CSVPreviewView, at index: Int, named name: String, in window: NSWindow
    ) {
        let grid = pane.gridForTesting
        guard let header = grid.headerView else { return XCTFail("no header to click") }
        let identifier = CSVPreviewView.identifier(for: name, at: index)
        let column = grid.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
        guard column >= 0 else { return XCTFail("no column named \(name)") }
        let rect = header.headerRect(ofColumn: column)
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
        _ type: NSEvent.EventType, in pane: CSVPreviewView, window: NSWindow,
        row: Int, column: Int
    ) -> NSEvent? {
        let grid = pane.gridForTesting
        let rect = grid.frameOfCell(atColumn: column, row: row)
        let point = grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 3, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func context(visible: Bool = true) -> PreviewContext {
        PreviewContext(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                       assets: nil, isVisible: visible)
    }

    /// Shows the note and waits for the table to have landed — it is read off
    /// the main thread, so nothing about the pane is true the instant the call
    /// returns.
    @MainActor
    private func show(_ note: Note, in pane: CSVPreviewView) throws {
        try settle(pane) { pane.show(note, in: context()) }
    }

    /// Does something to the pane and waits for whatever it set off.
    @MainActor
    private func settle(_ pane: CSVPreviewView, _ body: () -> Void) throws {
        let finished = expectation(description: "the file was read")
        finished.assertForOverFulfill = false
        pane.onDidFinish = { finished.fulfill() }
        body()
        wait(for: [finished], timeout: 20)
        pane.onDidFinish = nil
    }

    /// A table of `rows` numbered rows under a two-column header.
    private func generated(rows: Int) -> String {
        var text = "n,name\n"
        for index in 1...rows { text += "\(index),row \(index)\n" }
        return text
    }

    /// A table past the big-file threshold, and cheap to build.
    private func bigTable() -> String {
        let row = "1,a row of a big table,yes\n"
        let repeats = (BigFile.threshold / row.utf16.count) + 200
        return "id,note,in_stock\n" + String(repeating: row, count: repeats)
    }

    private func makeNote(named name: String, text: String) -> Note {
        Note(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), untitledName: nil,
             text: text, attributes: [:], assets: nil)
    }

    private func exampleText(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL, encoding: .utf8)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaCSVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
