import AppKit

/// One cell holding the query: which row of the *whole* table it is in, and
/// which column of that row.
///
/// The row is counted over the table in the order the grid is sorted in, from
/// zero — not over the page on screen. A search reads the whole table, and the
/// page a match lands on is worked out from this number rather than being what
/// was searched.
struct GridMatch: Equatable {
    /// The row's place in the whole table, in the order on screen, 0-based.
    let row: Int
    /// The data column, 0-based. The `#` gutter is not one of them.
    let column: Int
}

/// What a pane has to be able to answer for the grid in it to be searchable.
///
/// Two panes adopt it — the dump's and the delimited file's — and they answer
/// it in completely different ways: one asks SQLite, the other walks a table
/// it has already read. The session below knows neither.
protocol GridFindSource: AnyObject {

    /// Every cell of the *whole* table holding the query, in row order, and no
    /// more than `limit` of them. Case- and diacritic-insensitive, over the
    /// text the grid actually draws.
    func matches(for query: String, limit: Int) -> [GridMatch]

    /// Where the page on screen starts, counted in rows of the whole table.
    var findPageOffset: Int { get }

    /// How many data columns the page has. A page of different columns is a
    /// different table as far as a held match is concerned.
    var findColumnCount: Int { get }

    /// What one cell of the page on screen says, by page-relative row and data
    /// column — what ⌘E takes for the query.
    func findCellText(pageRow: Int, column: Int) -> String?

    /// Turns to the page the row is on, puts the cell cursor on the cell,
    /// scrolls it into view and walks the editor's caret to it. Whether that
    /// happens now or when a page comes back off a queue is the pane's own
    /// business.
    func revealFindMatch(row: Int, column: Int)
}

/// What a query means over a grid: the matches, the bands over the cells, which
/// one is current, and how ⌘G walks between them.
///
/// The third of the shape `TextFindSession` and `PDFFindSession` share, and the
/// first over something that is neither text nor a document. There is no
/// storage to lay a temporary attribute on and nothing to replace; a match is a
/// pair of numbers, the band is drawn by the cell, and landing on one may mean
/// turning a page first. Two hundred lines of the same story told a third way
/// is the honest answer — a protocol over the three would only be the pill's
/// own interface written three times.
///
/// Nothing a search does reaches the file, and nothing it does reaches the
/// database either: the whole table is *read* and the matches are numbers held
/// here.
final class GridFindSession {

    /// How many matches wear a band at once, and the same number the editor
    /// stops at. A one-letter query over a table of two hundred thousand rows
    /// is otherwise a list nobody asked for; the count says `2000+` instead.
    static let highlightLimit = TextFindSession.highlightLimit

    /// Case- and diacritic-insensitive, the same as every other bar in Nota:
    /// `cafe` finds `Café`.
    static let matchOptions: NSString.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive,
    ]

    /// How a cell of the page on screen is banded.
    enum Band {
        case none
        case match
        case current
    }

    let bar: FindBarView
    private weak var grid: SQLGridView?
    private weak var source: GridFindSource?

    /// Run when the pill arrives or leaves, so the column's mode control and
    /// the pane's own bar can get out of its corner.
    var onVisibilityChange: ((Bool) -> Void)?

    /// The matches wearing a band, up to `highlightLimit`, and whether the list
    /// stopped at it.
    private(set) var matches: [GridMatch] = []
    private(set) var isCapped = false

    /// The match the reader is on, as an index into `matches`. It is also the
    /// grid's cell cursor: a match is a cell, and there is nothing else in a
    /// grid for "here" to mean.
    private(set) var currentIndex: Int?

    var currentMatch: GridMatch? {
        guard let currentIndex, currentIndex >= 0, currentIndex < matches.count else { return nil }
        return matches[currentIndex]
    }

    /// The query the last search ran with. It outlives the bar, so ⌘G keeps
    /// working after Escape.
    private(set) var query = ""

    /// Where an incremental search counts from: the first row of the page on
    /// screen when the bar opened, and afterwards the match ⌘G last landed on.
    /// Typing walks forward from there rather than from the match the last
    /// keystroke found, which would creep down the table one letter at a time.
    private var anchor = 0

    /// Which rows hold matches, and which columns of them. A page of a hundred
    /// rows asks the band question a thousand times per redraw, and walking two
    /// thousand matches for each of those is a table that will not scroll.
    private var rows: [Int: Set<Int>] = [:]

    /// How many columns the table had when the list was made. A page of other
    /// columns is another table, and a match held across that would band
    /// somebody else's value.
    private var scannedColumns = 0

    /// True while a match is being landed on. The landing turns a page, and a
    /// page landing asks for a refresh — which would run the whole search
    /// again, in the middle of the search that asked for it.
    private var isRevealing = false

    var isVisible: Bool { bar.isShown }

    init(bar: FindBarView, grid: SQLGridView, source: GridFindSource) {
        self.bar = bar
        self.grid = grid
        self.source = source
        // A grid cannot be typed into, so the glass is only a glass and the
        // replace pill is out of reach.
        bar.canReplace = false
        bar.handlesAction = { Self.handles($0) }
        bar.onFinderAction = { [weak self] action in self?.perform(action) }
        bar.onQueryChange = { [weak self] _ in self?.runSearch(moving: true) }
        bar.onVisibilityChange = { [weak self] shown in self?.onVisibilityChange?(shown) }
    }

    // MARK: - The menu's actions

    /// Which of `NSTextFinder`'s actions a grid answers for. Not the replace
    /// half: a preview is read-only, so Find and Replace… is greyed out over a
    /// table rather than opening a pill that could do nothing.
    static func handles(_ action: NSTextFinder.Action) -> Bool {
        switch action {
        case .showFindInterface, .hideFindInterface, .nextMatch, .previousMatch,
             .setSearchString:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func perform(_ action: NSTextFinder.Action) -> Bool {
        switch action {
        case .showFindInterface: show()
        case .hideFindInterface: hide()
        case .nextMatch: step(forward: true)
        case .previousMatch: step(forward: false)
        case .setSearchString: useSelectionForFind()
        default: return false
        }
        return true
    }

    // MARK: - Opening and closing

    /// ⌘F. The last query comes back with all of it selected, so typing
    /// replaces it, and the search starts from the page being read rather than
    /// from the top of the table.
    func show() {
        anchor = source?.findPageOffset ?? 0
        bar.setShown(true)
        bar.focusField()
        runSearch(moving: true)
    }

    /// Escape, the ✕, or Hide Find Interface. The bands go down and the cursor
    /// stays on the cell the reader was standing on — the match is where they
    /// are, not something the bar was holding for them — and the keyboard goes
    /// back to the grid. The matches themselves stay, so ⌘G goes on walking
    /// them with the pill down.
    func hide() {
        guard bar.isShown else { return }
        bar.setShown(false)
        updateBands()
        guard let grid else { return }
        grid.window?.makeFirstResponder(grid)
    }

    /// The tab in front changed, or another file went into the pane: every
    /// (row, column) held here points into a table nobody is reading.
    func close() {
        hide()
        matches = []
        rows = [:]
        isCapped = false
        currentIndex = nil
        scannedColumns = 0
        query = ""
        bar.query = ""
        anchor = 0
        bar.setStatus(nil)
        updateBands()
    }

    // MARK: - Searching

    /// ⌘G and ⇧⌘G, and Return and ⇧Return in the field. Both wrap round the end
    /// of the table, and both work with the bar closed — the query outlives it.
    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        if matches.isEmpty { scanMatches() }
        guard !matches.isEmpty else {
            updateStatus()
            return
        }
        let next: Int
        if let currentIndex {
            next = forward
                ? (currentIndex + 1) % matches.count
                : (currentIndex + matches.count - 1) % matches.count
        } else {
            next = forward
                ? (firstIndex(atOrAfter: anchor) ?? 0)
                : (lastIndex(before: anchor) ?? matches.count - 1)
        }
        land(on: next)
    }

    /// ⌘E. The cell the cursor is on becomes the query — here and on the find
    /// pasteboard, so it is the string the next app's ⌘G looks for too —
    /// without opening the bar.
    func useSelectionForFind() {
        guard let grid, let source, let cursor = grid.cellCursor else { return }
        guard let text = source.findCellText(pageRow: cursor.row, column: cursor.column - 1),
              !text.isEmpty
        else { return }
        bar.query = text
        query = text
        anchor = source.findPageOffset + cursor.row
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(text, forType: .string)
        // With the bar up the search runs at once, landing on the very cell
        // that seeded it.
        if bar.isShown { runSearch(moving: true) }
    }

    /// The page under the session moved: another page was turned to, the table
    /// was sorted, the file was read again, a query was run, another table was
    /// picked. Every one of those is the same news — the coordinates the list
    /// holds may not mean what they meant — so the search runs again and the
    /// match the reader was on is kept if it is still there.
    func refresh() {
        guard !query.isEmpty else {
            guard !matches.isEmpty else { return }
            matches = []
            rows = [:]
            isCapped = false
            currentIndex = nil
            updateBands()
            return
        }
        // The page that is landing is the one this session asked for. Searching
        // again inside a search would be the same answer, bought twice.
        guard !isRevealing else {
            updateBands()
            return
        }
        let sameShape = source?.findColumnCount == scannedColumns
        let current = sameShape ? currentMatch : nil
        scanMatches()
        currentIndex = current.flatMap { matches.firstIndex(of: $0) }
        updateBands()
        updateStatus()
    }

    /// One pass of the query: the matches, the bands, the count, and — while
    /// the reader is typing — the first match at or after where the bar opened.
    private func runSearch(moving: Bool) {
        query = bar.query
        scanMatches()
        if query.isEmpty {
            currentIndex = nil
        } else if moving {
            currentIndex = nil
            if let next = firstIndex(atOrAfter: anchor) ?? (matches.isEmpty ? nil : 0) {
                land(on: next)
                return
            }
        }
        updateBands()
        updateStatus()
    }

    /// Every match in the table, and no more than `highlightLimit` of them.
    private func scanMatches() {
        matches = []
        rows = [:]
        isCapped = false
        guard let source, !query.isEmpty else {
            scannedColumns = 0
            return
        }
        scannedColumns = source.findColumnCount
        let found = source.matches(for: query, limit: Self.highlightLimit)
        isCapped = found.count >= Self.highlightLimit
        matches = found
        for match in found { rows[match.row, default: []].insert(match.column) }
    }

    /// Lands on a match: it becomes the cell cursor, wears the loud band, and
    /// the page it is on is turned to if it is not the page on screen.
    private func land(on index: Int) {
        guard index >= 0, index < matches.count else { return }
        currentIndex = index
        let match = matches[index]
        anchor = match.row
        isRevealing = true
        source?.revealFindMatch(row: match.row, column: match.column)
        isRevealing = false
        updateBands()
        updateStatus()
    }

    /// The first match at or after a row of the table, in reading order.
    private func firstIndex(atOrAfter row: Int) -> Int? {
        matches.firstIndex { $0.row >= row }
    }

    /// The last match before a row — where ⇧⌘G starts from with nothing
    /// current.
    private func lastIndex(before row: Int) -> Int? {
        matches.lastIndex { $0.row < row }
    }

    // MARK: - The bands

    /// How one cell of the page on screen is banded, asked by the grid as it
    /// draws. `pageRow` is a row of the page and `dataColumn` counts from the
    /// first real column, the `#` gutter left out.
    ///
    /// Only while the pill is up. Escape puts the bands down and leaves the
    /// cursor where it is, which is what the reader was looking for.
    func band(pageRow: Int, dataColumn: Int) -> Band {
        guard bar.isShown, !matches.isEmpty, dataColumn >= 0, let source else { return .none }
        let row = source.findPageOffset + pageRow
        if let current = currentMatch, current.row == row, current.column == dataColumn {
            return .current
        }
        return rows[row]?.contains(dataColumn) == true ? .match : .none
    }

    private func updateBands() {
        grid?.updateCellRendering()
    }

    // MARK: - The count

    /// `"3 of 12"` while there are matches and one of them is current,
    /// `"12 matches"` when none is, `"No matches"` when there are none, and
    /// nothing at all while the field is empty. A table big enough to have
    /// stopped the list says `2000+` for the total rather than a number it did
    /// not count.
    private func updateStatus() {
        guard !query.isEmpty else {
            bar.setStatus(nil)
            return
        }
        guard !matches.isEmpty else {
            bar.setStatus("No matches")
            return
        }
        let total = isCapped ? "\(Self.highlightLimit)+" : "\(matches.count)"
        guard let currentIndex, currentIndex < matches.count else {
            bar.setStatus(matches.count == 1 && !isCapped ? "1 match" : "\(total) matches")
            return
        }
        bar.setStatus("\(currentIndex + 1) of \(total)")
    }
}
