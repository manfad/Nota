import AppKit
import Foundation
import XCTest
@testable import Nota

/// ⌘F over a grid, and what the editor is shown when something in one is
/// picked out: the `.csv` table's grid and the `.sql` dump's, which are the
/// same grid over two completely different ways of finding a row. The whole
/// table is searched and not the page on screen, so a match two pages down
/// turns the page to it.
final class GridFindTests: AppKitTestCase {
    private var windows: [NSWindow] = []
    private var alerts: [(message: String, informative: String)] = []

    @MainActor
    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        alerts = []
        super.tearDown()
    }

    // MARK: - The table

    /// The pill is the same one every other column floats, and there is
    /// nothing in a table to replace.
    @MainActor
    func testTheTablesPillIsTheSameOneWithNothingToReplace() throws {
        let (pane, _) = try makeCSVPane()
        let bar = pane.findBarForTesting
        XCTAssertTrue(bar.field.placeholderString?.isEmpty ?? true)
        XCTAssertFalse(bar.isShown)
        XCTAssertFalse(bar.canReplace, "a preview is read-only")
        XCTAssertFalse(pane.isFindBarVisible)
    }

    /// Typing counts the matches over the whole table and lands on the first
    /// of them, case- and diacritic-insensitively.
    @MainActor
    func testTypingCountsTheMatchesAndLandsOnTheFirst() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let bar = pane.findBarForTesting

        pane.gridForTesting.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertTrue(bar.isShown)
        XCTAssertTrue(pane.isFindBarVisible)

        type("paris", into: bar)
        XCTAssertEqual(bar.status, "1 of 2", "two cities say Paris, and the first is current")
        XCTAssertEqual(pane.findSessionForTesting.matches,
                       [GridMatch(row: 0, column: 2), GridMatch(row: 2, column: 2)])
        // The current match is the cell cursor: a match in a grid is a cell.
        XCTAssertEqual(pane.gridForTesting.cellCursor?.row, 0)
        XCTAssertEqual(pane.gridForTesting.cellCursor?.column, 3)

        type("PÁRIS", into: bar)
        XCTAssertEqual(bar.status, "1 of 2", "case and diacritics are not the query")

        type("zurich", into: bar)
        XCTAssertEqual(bar.status, "No matches")
    }

    /// Every match wears a quiet band and the one being stood on wears the
    /// loud one — asked of the grid, which is what draws them.
    @MainActor
    func testEveryMatchWearsABandAndTheCurrentOneIsLoud() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        grid.performTextFinderAction(finderItem(.showFindInterface))
        type("paris", into: pane.findBarForTesting)

        let current = grid.highlight(row: 0, column: 3)
        XCTAssertTrue(current.isCurrentMatch)
        XCTAssertFalse(current.isMatch, "the loud band is not also the quiet one")
        XCTAssertTrue(current.isCursor, "and the match is where the arrows move from")

        let quiet = grid.highlight(row: 2, column: 3)
        XCTAssertTrue(quiet.isMatch)
        XCTAssertFalse(quiet.isCurrentMatch)

        XCTAssertFalse(grid.highlight(row: 1, column: 3).isMatch, "Berlin is not Paris")
        XCTAssertFalse(grid.highlight(row: 0, column: 1).isMatch, "and the id column is not")
        XCTAssertFalse(grid.highlight(row: 0, column: 0).isMatch, "the # gutter never bands")
    }

    /// ⌘G walks the matches and wraps round the end of the table; ⇧⌘G walks
    /// them back.
    @MainActor
    func testCommandGWalksTheMatchesAndWraps() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        grid.performTextFinderAction(finderItem(.showFindInterface))
        type("paris", into: pane.findBarForTesting)
        XCTAssertEqual(pane.findBarForTesting.status, "1 of 2")

        grid.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(pane.findBarForTesting.status, "2 of 2")
        XCTAssertEqual(grid.cellCursor?.row, 2)

        grid.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(pane.findBarForTesting.status, "1 of 2", "round the end of the table")

        grid.performTextFinderAction(finderItem(.previousMatch))
        XCTAssertEqual(pane.findBarForTesting.status, "2 of 2", "and back round the top")
    }

    /// A match on the second page turns the page to it and puts the cursor on
    /// the cell — the whole table is searched, not the hundred rows on screen.
    @MainActor
    func testAMatchOnTheSecondPageTurnsThePageToIt() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "Rows.csv", text: Self.generated(rows: 150)), in: pane)
        XCTAssertEqual(pane.shownPage?.offset, 0)

        pane.gridForTesting.performTextFinderAction(finderItem(.showFindInterface))
        type("row 130", into: pane.findBarForTesting)

        XCTAssertEqual(pane.findBarForTesting.status, "1 of 1")
        XCTAssertEqual(pane.shownPage?.offset, 100, "the page the row is on")
        XCTAssertEqual(pane.gridForTesting.cellCursor?.row, 29, "row 130 is the 30th of it")
        XCTAssertEqual(pane.gridForTesting.cellCursor?.column, 2)
        XCTAssertTrue(pane.gridForTesting.highlight(row: 29, column: 2).isCurrentMatch)
    }

    /// The editor's caret follows the match, the way it follows a clicked
    /// cell: the field as it is written, and no keyboard taken.
    @MainActor
    func testTheEditorsCaretFollowsTheMatch() throws {
        let (pane, window) = try makeCSVPane()
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        window.makeFirstResponder(grid)

        grid.performTextFinderAction(finderItem(.showFindInterface))
        type("paris", into: pane.findBarForTesting)

        let range = try XCTUnwrap(revealed.last?.first)
        XCTAssertEqual((Self.people as NSString).substring(with: range), "Paris",
                       "the field the match is in, as it is written")
        XCTAssertTrue(window.firstResponder === pane.findBarForTesting.field
            || window.firstResponder is NSTextView,
            "the query field kept the keyboard; the grid never took it back")
    }

    /// Escape puts the bands down and leaves the reader standing on the match,
    /// with the keyboard back in the grid. ⌘G goes on working after it.
    @MainActor
    func testEscapeKeepsTheCursorAndGivesTheGridTheKeyboard() throws {
        let (pane, window) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        grid.performTextFinderAction(finderItem(.showFindInterface))
        type("paris", into: pane.findBarForTesting)
        XCTAssertEqual(grid.cellCursor?.row, 0)

        grid.performTextFinderAction(finderItem(.hideFindInterface))

        XCTAssertFalse(pane.findBarForTesting.isShown)
        XCTAssertFalse(pane.isFindBarVisible)
        XCTAssertEqual(grid.cellCursor?.row, 0, "the match is where the reader is")
        XCTAssertEqual(grid.cellCursor?.column, 3)
        XCTAssertFalse(grid.highlight(row: 2, column: 3).isMatch, "the bands went with the pill")
        XCTAssertTrue(window.firstResponder === grid, "and the keyboard came back")

        // The query outlives the bar.
        grid.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(grid.cellCursor?.row, 2)
    }

    /// The Find menu's items are enabled while the grid has the keyboard —
    /// which is how ⌘F ever arrives here at all — and the replace half is not.
    @MainActor
    func testTheFindItemsValidateWithTheGridAsFirstResponder() throws {
        let (pane, window) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        window.makeFirstResponder(grid)
        XCTAssertTrue(window.firstResponder === grid)

        for action in [NSTextFinder.Action.showFindInterface, .nextMatch, .previousMatch,
                       .setSearchString, .hideFindInterface] {
            XCTAssertTrue(grid.validateUserInterfaceItem(finderItem(action)),
                          "\(action) has to stay enabled or the key never arrives")
        }
        XCTAssertFalse(grid.validateUserInterfaceItem(finderItem(.showReplaceInterface)),
                       "there is nothing in a preview to replace")
    }

    /// ⌘E takes the cell the cursor is on for the query.
    @MainActor
    func testUseSelectionForFindTakesTheCursorCell() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        grid.setCursor(row: 1, column: 3)  // Berlin

        grid.performTextFinderAction(finderItem(.setSearchString))
        XCTAssertEqual(pane.findBarForTesting.query, "Berlin")

        grid.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertEqual(pane.findBarForTesting.status, "1 of 1")
    }

    /// A sort changes which row is first, and the search is over the order on
    /// screen rather than over the file.
    @MainActor
    func testASortChangesWhichRowTheFirstMatchIsOn() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        grid.performTextFinderAction(finderItem(.showFindInterface))
        type("paris", into: pane.findBarForTesting)
        XCTAssertEqual(pane.findSessionForTesting.matches.map(\.row), [0, 2])

        // By city: Berlin, London, Paris, Paris.
        pane.clickHeaderForTesting(at: 2)
        XCTAssertEqual(pane.shownSort?.column, 2)

        XCTAssertEqual(pane.findSessionForTesting.matches.map(\.row), [2, 3],
                       "the same two rows, in the places the sort put them")
        grid.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(grid.cellCursor?.row, 2)
    }

    /// Another tab coming forward takes the search with it: every (row,
    /// column) here points into a table nobody is reading.
    @MainActor
    func testAnotherTabTakesTheSearchDown() throws {
        let (pane, _) = try makeCSVPane()
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        pane.gridForTesting.performTextFinderAction(finderItem(.showFindInterface))
        type("paris", into: pane.findBarForTesting)
        XCTAssertFalse(pane.findSessionForTesting.matches.isEmpty)

        try show(makeNote(named: "Other.csv", text: "a,b\n1,2\n"), in: pane)

        XCTAssertFalse(pane.findBarForTesting.isShown)
        XCTAssertTrue(pane.findSessionForTesting.matches.isEmpty)
        XCTAssertEqual(pane.findBarForTesting.status, nil)
    }

    // MARK: - The dump

    /// The same search over a table of the example dump, and a match on the
    /// second page turns the page to it.
    @MainActor
    func testTheDumpsGridIsSearchedWholeAndTurnsThePage() throws {
        let (pane, _) = try makeSQLPane()
        try show(try exampleNote("Shop.sql"), in: pane)
        XCTAssertEqual(pane.shownTable, "customers")
        XCTAssertEqual(pane.shownPage?.offset, 0)

        let grid = pane.gridForTesting
        grid.performTextFinderAction(finderItem(.showFindInterface))
        type("zara ueda", into: pane.findBarForTesting)
        waitUntil({ pane.shownPage?.offset == 100 }, "the page the row is on never came back")

        XCTAssertEqual(pane.findBarForTesting.status, "1 of 1")
        XCTAssertEqual(pane.findSessionForTesting.matches,
                       [GridMatch(row: 110, column: 1)],
                       "customer 111, in the name column")
        XCTAssertEqual(grid.cellCursor?.row, 10, "the eleventh row of the second page")
        XCTAssertEqual(grid.cellCursor?.column, 2)
        XCTAssertTrue(grid.highlight(row: 10, column: 2).isCurrentMatch)
    }

    /// A `NULL` reads as the word on screen, so that is what a search of it
    /// finds — the display text and not the storage class.
    @MainActor
    func testTheDumpIsSearchedByWhatTheCellSays() throws {
        let (pane, _) = try makeSQLPane()
        try show(makeNote(named: "T.sql", text: """
        CREATE TABLE t (a TEXT, b REAL);
        INSERT INTO t VALUES ('one', 12.0);
        INSERT INTO t VALUES (NULL, 3.5);
        """), in: pane)

        pane.gridForTesting.performTextFinderAction(finderItem(.showFindInterface))
        type("12", into: pane.findBarForTesting)
        XCTAssertEqual(pane.findSessionForTesting.matches, [GridMatch(row: 0, column: 1)],
                       "the cell says 12, not 12.0")
    }

    /// A query's result is searched the same way, over the whole of it.
    @MainActor
    func testAQueryResultIsSearchedToo() throws {
        let (pane, _) = try makeSQLPane()
        try show(try exampleNote("Shop.sql"), in: pane)
        try settle(pane) {
            pane.setQueryForTesting("SELECT name, city FROM customers WHERE city = 'Kyoto'")
        }
        XCTAssertEqual(pane.shownPage?.total, 12)

        pane.gridForTesting.performTextFinderAction(finderItem(.showFindInterface))
        type("kyoto", into: pane.findBarForTesting)

        XCTAssertEqual(pane.findBarForTesting.status, "1 of 12")
        XCTAssertEqual(pane.findSessionForTesting.matches.map(\.column), Array(repeating: 1, count: 12),
                       "every hit is in the city column the query asked for")
        XCTAssertEqual(pane.gridForTesting.cellCursor?.column, 2)
    }

    /// ⌘F with the caret in the query box searches the rows rather than the
    /// five lines of the question.
    @MainActor
    func testTheQueryBoxHandsCommandFToTheGrid() throws {
        let (pane, window) = try makeSQLPane()
        try show(try exampleNote("Shop.sql"), in: pane)
        let box = pane.queryBoxForTesting.textViewForTesting
        window.makeFirstResponder(box)

        XCTAssertTrue(box.validateUserInterfaceItem(finderItem(.showFindInterface)))
        box.performTextFinderAction(finderItem(.showFindInterface))

        XCTAssertTrue(pane.findBarForTesting.isShown, "the grid's pill, not AppKit's own bar")
        type("kyoto", into: pane.findBarForTesting)
        XCTAssertEqual(pane.findBarForTesting.status, "1 of 12")
    }

    // MARK: - What a selection shows the editor

    /// A click in the `#` gutter takes the whole row, and the editor goes to
    /// the record it is written as — not to one field of it.
    @MainActor
    func testAGutterClickRevealsTheWholeRecord() throws {
        let (pane, window) = try makeCSVPane()
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        pane.layoutSubtreeIfNeeded()

        pane.gridForTesting.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: pane.gridForTesting, window: window, row: 1, column: 0)
        ))

        XCTAssertEqual(pane.gridForTesting.selection, .rows(IndexSet(integer: 1)))
        XCTAssertEqual(revealed.last?.count, 1, "a whole row is one span")
        XCTAssertEqual(substring(of: try XCTUnwrap(revealed.last?.first), in: Self.people),
                       "2,Bo,Berlin", "the record's own line, and all of it")
    }

    /// A ⇧-click grows the run of rows, and the editor is shown the one span
    /// from the first record to the last — the way a selection over three
    /// paragraphs of text is one range.
    @MainActor
    func testAShiftClickRevealsTheSpanOfEveryRowInTheRun() throws {
        let (pane, window) = try makeCSVPane()
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: grid, window: window, row: 0, column: 0)
        ))
        grid.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: grid, window: window, row: 2, column: 0, shift: true)
        ))

        XCTAssertEqual(grid.selection, .rows(IndexSet(integersIn: 0...2)))
        XCTAssertEqual(revealed.last?.count, 1, "a run of whole rows stays one span")
        XCTAssertEqual(substring(of: try XCTUnwrap(revealed.last?.first), in: Self.people),
                       "1,Ada,Paris\n2,Bo,Berlin\n3,Cara,Paris")
    }

    /// The editor follows the drag rather than staying on the cell the press
    /// landed on: every mouse event that moves an edge of the rectangle says
    /// so again, and the last of them says the rectangle's own rows — one
    /// range per row, and not one span smeared across the ones between.
    @MainActor
    func testTheEditorFollowsACellDragAcrossTheRectangle() throws {
        let (pane, window) = try makeCSVPane()
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: grid, window: window, row: 0, column: 1)
        ))
        XCTAssertEqual(substring(of: try XCTUnwrap(revealed.last?.first), in: Self.people), "1",
                       "the press is one cell, exactly as it was")

        grid.mouseDragged(with: try XCTUnwrap(
            cellEvent(.leftMouseDragged, in: grid, window: window, row: 1, column: 2)
        ))

        XCTAssertEqual(grid.selection, .cells(rows: 0...1, columns: 1...2))
        XCTAssertEqual(revealed.last?.map { substring(of: $0, in: Self.people) },
                       ["1,Ada", "2,Bo"],
                       "one range per row — the id and name columns of each, not the city field "
                           + "beside them, and never the two rows squeezed into one span")

        // A second event over the same cell is the same rectangle, and the
        // editor is not told the same thing twice.
        let count = revealed.count
        grid.mouseDragged(with: try XCTUnwrap(
            cellEvent(.leftMouseDragged, in: grid, window: window, row: 1, column: 2)
        ))
        XCTAssertEqual(revealed.count, count, "a drag that moved nothing says nothing")
    }

    /// The same over a dump: a whole row is the `INSERT` it was written as,
    /// and a run of them is the span from the first to the last.
    @MainActor
    func testADumpsRowRevealsItsInsertAndARunRevealsTheSpan() throws {
        let text = """
        CREATE TABLE t (a TEXT, b TEXT);
        INSERT INTO t VALUES ('one', 'two');
        INSERT INTO t VALUES ('three', 'four');
        INSERT INTO t VALUES ('five', 'six');
        """
        let (pane, window) = try makeSQLPane()
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }
        try show(makeNote(named: "T.sql", text: text), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: grid, window: window, row: 1, column: 0)
        ))
        XCTAssertEqual(substring(of: try XCTUnwrap(revealed.last?.first), in: text),
                       "INSERT INTO t VALUES ('three', 'four');",
                       "the tuple the row was written as, not one value in it")

        grid.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: grid, window: window, row: 2, column: 0, shift: true)
        ))
        XCTAssertEqual(revealed.last?.count, 1, "a run of whole rows stays one span")
        XCTAssertEqual(substring(of: try XCTUnwrap(revealed.last?.first), in: text),
                       "INSERT INTO t VALUES ('three', 'four');\n"
                           + "INSERT INTO t VALUES ('five', 'six');")
    }

    /// And a drag over a dump's cells is one span per row of the values it
    /// crossed on that row — never one span reaching into the next row.
    @MainActor
    func testADumpsCellDragSpansTheValuesItCrossed() throws {
        let text = """
        CREATE TABLE t (a TEXT, b TEXT);
        INSERT INTO t VALUES ('one', 'two');
        INSERT INTO t VALUES ('three', 'four');
        """
        let (pane, window) = try makeSQLPane()
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }
        try show(makeNote(named: "T.sql", text: text), in: pane)
        pane.layoutSubtreeIfNeeded()
        let grid = pane.gridForTesting

        grid.mouseDown(with: try XCTUnwrap(
            cellEvent(.leftMouseDown, in: grid, window: window, row: 0, column: 1)
        ))
        XCTAssertEqual(substring(of: try XCTUnwrap(revealed.last?.first), in: text), "'one'")

        grid.mouseDragged(with: try XCTUnwrap(
            cellEvent(.leftMouseDragged, in: grid, window: window, row: 1, column: 2)
        ))
        XCTAssertEqual(grid.selection, .cells(rows: 0...1, columns: 1...2))
        XCTAssertEqual(revealed.last?.map { substring(of: $0, in: text) },
                       ["'one', 'two'", "'three', 'four'"],
                       "one range per row — both columns of that row, and never another row's")
    }

    // MARK: - Whose ⌘F it is

    /// In split the editor beside the grid owns ⌘F, even though a click has
    /// left the first responder in the grid. The item stays enabled — it is
    /// about to run the editor's find — and the action is handed back up the
    /// chain rather than opening the table's pill.
    @MainActor
    func testInSplitTheGridHandsCommandFBackToTheEditor() throws {
        let (pane, window) = try makeCSVPane()
        pane.takesKeyboard = false
        try show(makeNote(named: "People.csv", text: Self.people), in: pane)
        let grid = pane.gridForTesting
        window.makeFirstResponder(grid)

        XCTAssertTrue(grid.validateUserInterfaceItem(finderItem(.showFindInterface)),
                      "the editor's ⌘F must not be greyed out by the grid holding the key")
        grid.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertFalse(pane.findBarForTesting.isShown, "the table's pill stayed down")

        // And the replace half, which the editor answers for and the grid does
        // not, is enabled all the same.
        XCTAssertTrue(grid.validateUserInterfaceItem(finderItem(.showReplaceInterface)))
    }

    /// The query box says the same thing: in split it is the editor's key.
    @MainActor
    func testInSplitTheQueryBoxHandsCommandFBackToo() throws {
        let (pane, window) = try makeSQLPane()
        pane.takesKeyboard = false
        try show(try exampleNote("Shop.sql"), in: pane)
        let box = pane.queryBoxForTesting.textViewForTesting
        window.makeFirstResponder(box)

        XCTAssertTrue(box.validateUserInterfaceItem(finderItem(.showFindInterface)))
        box.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertFalse(pane.findBarForTesting.isShown)
    }

    // MARK: - Helpers

    /// Four people in three cities: two of them in Paris, which is what every
    /// count in here is counting.
    private static let people = "id,name,city\n1,Ada,Paris\n2,Bo,Berlin\n"
        + "3,Cara,Paris\n4,Dan,London\n"

    /// A table of `rows` numbered rows under a two-column header, so a match
    /// can be put on the second page.
    private static func generated(rows: Int) -> String {
        var text = "n,name\n"
        for index in 1...rows { text += "\(index),row \(index)\n" }
        return text
    }

    @MainActor
    private func makeCSVPane() throws -> (CSVPreviewView, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        let pane = CSVPreviewView(frame: frame)
        // Reading mode: the grid owns ⌘F only where the editor is not on
        // screen beside it.
        pane.takesKeyboard = true
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        window.layoutIfNeeded()
        return (pane, window)
    }

    @MainActor
    private func makeSQLPane() throws -> (SQLPreviewView, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        let pane = SQLPreviewView(frame: frame)
        pane.takesKeyboard = true
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        // Never a real modal in a test: a sheet here would hang the run rather
        // than fail it.
        pane.alertOverrideForTesting = { [weak self] message, informative in
            self?.alerts.append((message, informative))
        }
        window.layoutIfNeeded()
        return (pane, window)
    }

    private func context() -> PreviewContext {
        PreviewContext(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                       assets: nil, isVisible: true)
    }

    @MainActor
    private func show(_ note: Note, in pane: CSVPreviewView) throws {
        try settle(pane) { pane.show(note, in: context()) }
    }

    @MainActor
    private func show(_ note: Note, in pane: SQLPreviewView) throws {
        try settle(pane) { pane.show(note, in: context()) }
    }

    @MainActor
    private func settle(_ pane: CSVPreviewView, _ body: () -> Void) throws {
        let finished = expectation(description: "the file was read")
        finished.assertForOverFulfill = false
        pane.onDidFinish = { finished.fulfill() }
        body()
        wait(for: [finished], timeout: 20)
        pane.onDidFinish = nil
    }

    @MainActor
    private func settle(_ pane: SQLPreviewView, _ body: () -> Void) throws {
        let finished = expectation(description: "the database answered")
        finished.assertForOverFulfill = false
        pane.onDidFinish = { finished.fulfill() }
        body()
        wait(for: [finished], timeout: 20)
        pane.onDidFinish = nil
    }

    /// Turns the run loop until something is true — a page a search asked for
    /// comes back off the pane's own queue, and there is nothing else to hang
    /// on.
    @MainActor
    private func waitUntil(
        _ condition: () -> Bool, timeout: TimeInterval = 20, _ message: String
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }

    /// A Find menu item as the menu builds it: nil-targeted, with the action
    /// in its tag.
    private func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(NSTextView.performTextFinderAction(_:))
        item.tag = action.rawValue
        return item
    }

    /// The reader typing in the field, which is what drives an incremental
    /// search.
    private func type(_ query: String, into bar: FindBarView) {
        bar.query = query
        bar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: bar.field)
        )
    }

    /// A mouse event over the middle of one cell of the grid, the way the
    /// dump's own suite drives the cell cursor. Column 0 is the `#` gutter.
    @MainActor
    private func cellEvent(
        _ type: NSEvent.EventType, in grid: SQLGridView, window: NSWindow,
        row: Int, column: Int, shift: Bool = false
    ) -> NSEvent? {
        let rect = grid.frameOfCell(atColumn: column, row: row)
        let point = grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: shift ? [.shift] : [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 3, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func substring(of range: NSRange, in text: String) -> String {
        (text as NSString).substring(with: range)
    }

    private func makeNote(named name: String, text: String) -> Note {
        Note(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), untitledName: nil,
             text: text, attributes: [:], assets: nil)
    }

    private func exampleNote(_ name: String) throws -> Note {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
        return Note(fileURL: file, untitledName: nil,
                    text: try String(contentsOf: file, encoding: .utf8),
                    attributes: [:], assets: nil)
    }
}
