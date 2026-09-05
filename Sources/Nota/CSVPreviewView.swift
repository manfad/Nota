import AppKit

/// The preview column holding a `.csv` or `.tsv` file's table, where a
/// Markdown tab would have its render.
///
/// This is the dump's pane (`SQLPreviewView`) with the database taken out of
/// it. A delimited file is already a table — there is nothing to run, nothing
/// to pick between and nothing to ask it — so the chrome is one bar: the
/// button that reads the file again at the leading edge, and `1–100 of 2,345`
/// between ‹ › at the trailing one. Everything below the bar is the same grid
/// the dump is read in, `SQLGridView`, unchanged: the spreadsheet cell cursor,
/// the `#` gutter, ⇧ and Space, and ⌘C as tab-separated text all come with it.
///
/// The text in the editor is the whole of the truth, unsaved edits included.
/// Every time it settles the file is read again by `CSVTable`, off the main
/// thread, with the read before it dropped where it stands — a table two
/// keystrokes old is not news about the file on screen now. A file past the
/// `BigFile` threshold is never read on its own: the bar's one button is what
/// asks for that, exactly as it is for a big dump.
///
/// The bar starts a hover band below the top of the column. That band is the
/// corner slot's (`ModeControlOverlay.hoverBandHeight`), and the Editor ·
/// Split · Reading control floats in it, so the header row is never behind
/// the control.
final class CSVPreviewView: NSView, PreviewContent {

    // MARK: - The chrome

    private let bar = NSView()
    /// Reads the file as it stands now and asks for the same page again,
    /// keeping the sort and the page it was on. It is also the *only* way a
    /// big file is ever read, so there is one button rather than two: for a
    /// file small enough to read itself this says "as the file is now", and
    /// for one that is not it says "read it".
    private let refreshButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let grid = SQLGridView()
    /// The quiet line where the grid would be, for a file with nothing to
    /// show yet — which is only ever the big one waiting to be read.
    private let emptyLabel = NSTextField(labelWithString: "")

    private enum Layout {
        static let blankColumnWidth: CGFloat = 160
        static let inset: CGFloat = 12
        static let rowGap: CGFloat = 10
        static let controlHeight: CGFloat = 22
        static let barSpacing: CGFloat = 8
        static let pageButtonWidth: CGFloat = 24
        static let rowNumberWidth: CGFloat = 46
        static let minimumColumnWidth: CGFloat = 56
        static let maximumColumnWidth: CGFloat = 420
        static let cellPadding: CGFloat = 10
        /// The band the corner slot floats its control in. The pane begins
        /// under it so nothing of the pane is ever behind the control.
        static let topClearance = ModeControlOverlay.hoverBandHeight
    }

    // MARK: - What the pane is showing

    private weak var note: Note?
    private var shownID: UUID?
    /// The text the table was read from. A show with the same text does
    /// nothing at all — a resize and a tab switch both ask again.
    private var shownSource: String?
    private var separator = CSVTable.Separator.comma
    private var table: CSVTable?
    private var page: CSVTable.Page?
    private var sort: CSVTable.Sort?
    private var offset = 0
    /// The page that follows a sort starts at the top of the table, so the
    /// grid goes back up with it.
    private var scrollsToTop = false
    private var isBigFile = false
    private var isColumnVisible = false
    private var cellFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Reads are asked for from the main thread and answered on this one, in
    /// the order they were asked.
    private let queue = DispatchQueue(label: "com.nota.csv-preview", qos: .userInitiated)
    /// The read carries a token, so an answer about the file two keystrokes
    /// ago is not news about the one on screen now.
    private var readToken = 0

    // MARK: - What the pane reports

    var onDropFiles: (([URL]) -> Void)?
    /// Where the row under a clicked cell is written in the file. Split only,
    /// which is what `sendsBlockClicks` says: in reading there is no editor on
    /// screen to point at.
    var onSourceReveal: ((NSRange) -> Void)?
    /// Mirrors the render's own: true in split, where the grid is a way into
    /// the text beside it, and false in reading, where the table is simply
    /// what is being read.
    var sendsBlockClicks = true
    /// Run when a table has landed — for the tests, which have no other way
    /// to wait for a background read.
    var onDidFinish: (() -> Void)?
    /// How many times the file has been read into a table. The one number
    /// that says a big file is not being re-read on every keystroke.
    private(set) var readCount = 0

    // MARK: - Building

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)
        buildBar()
        buildGrid()
        activateConstraints()
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.controlSize = .small
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise",
                                      accessibilityDescription: nil)
        refreshButton.image?.isTemplate = true
        refreshButton.title = "Refresh"
        refreshButton.font = .systemFont(ofSize: 11)
        refreshButton.imagePosition = .imageLeading
        refreshButton.imageHugsTitle = true
        refreshButton.target = self
        refreshButton.action = #selector(refreshTable)
        refreshButton.toolTip = "Read again"
        refreshButton.setAccessibilityIdentifier("csv-refresh")
        bar.addSubview(refreshButton)

        // Numbers that change as the reader pages: tabular figures, so the
        // label does not shuffle sideways between one page and the next.
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.alignment = .center
        rangeLabel.setAccessibilityIdentifier("csv-range")
        bar.addSubview(rangeLabel)

        for (button, symbol, action) in [
            (previousButton, "chevron.left", #selector(showPreviousPage)),
            (nextButton, "chevron.right", #selector(showNextPage)),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            bar.addSubview(button)
        }
        previousButton.toolTip = "Previous page"
        nextButton.toolTip = "Next page"
        previousButton.setAccessibilityIdentifier("csv-previous")
        nextButton.setAccessibilityIdentifier("csv-next")
    }

    private func buildGrid() {
        // Edge to edge, the way a PDF is: a table has its own margins in the
        // gutter and the header, and a second one outside them would be the
        // column paying twice.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = grid
        addSubview(scrollView)

        grid.style = .plain
        grid.rowHeight = 22
        grid.intercellSpacing = NSSize(width: 1, height: 0)
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.gridColor = .separatorColor
        grid.usesAlternatingRowBackgroundColors = true
        grid.allowsMultipleSelection = true
        grid.allowsColumnReordering = false
        grid.allowsColumnResizing = true
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.backgroundColor = .textBackgroundColor
        grid.selectionHighlightStyle = .regular
        grid.headerView = SQLHeaderView()
        grid.dataSource = self
        grid.delegate = self
        grid.copyText = { [weak self] selection in self?.text(of: selection) ?? "" }
        grid.onCellClick = { [weak self] row, _ in self?.revealSource(ofRow: row) }
        grid.setAccessibilityIdentifier("csv-grid")

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.setAccessibilityIdentifier("csv-empty")
        addSubview(emptyLabel)
    }

    private func activateConstraints() {
        // The column is the reader's to size, and nothing in this bar is
        // allowed a say in how narrow it may be dragged: every content view
        // in the column is pinned to its full width at all times, so a
        // control here that refused to be squeezed would be a floor under
        // the whole preview column. They give way instead, in the order they
        // can best be spared, and the range label truncates.
        let giveWay: [(NSView, NSLayoutConstraint.Priority)] = [
            (rangeLabel, .init(rawValue: 140)),
            (refreshButton, .init(rawValue: 160)),
            (previousButton, .init(rawValue: 170)),
            (nextButton, .init(rawValue: 170)),
        ]
        for (view, priority) in giveWay {
            view.setContentCompressionResistancePriority(priority, for: .horizontal)
            view.setContentHuggingPriority(.init(rawValue: 150), for: .horizontal)
        }
        // And the row of controls itself keeps its place rather than its
        // width: a bar too narrow for everything on it clips at the trailing
        // edge instead of holding the column open.
        let barSpacing = previousButton.leadingAnchor.constraint(
            greaterThanOrEqualTo: refreshButton.trailingAnchor, constant: Layout.barSpacing
        )
        barSpacing.priority = .init(rawValue: 200)
        barSpacing.isActive = true

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Layout.topClearance),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.inset),
            bar.heightAnchor.constraint(equalToConstant: Layout.controlHeight),

            refreshButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            nextButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: Layout.pageButtonWidth),

            rangeLabel.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            rangeLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            previousButton.trailingAnchor.constraint(equalTo: rangeLabel.leadingAnchor),
            previousButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: Layout.pageButtonWidth),

            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Layout.rowGap),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Layout.inset
            ),
        ])
    }

    // MARK: - Content

    func show(_ note: Note, in context: PreviewContext) {
        apply(font: context.font)
        if note.id != shownID { adopt(note) }
        self.note = note
        isColumnVisible = context.isVisible
        // A table nobody can see is not worth reading — and a read costs the
        // whole file, so the column being away is a real saving.
        guard context.isVisible else { return }

        isBigFile = BigFile.isBig(length: note.storage.length)
        // A big file is read when it is asked for and never on its own: two
        // hundred thousand rows are not a thing to walk between one keystroke
        // and the next, and certainly not a thing to walk again on the next.
        guard !isBigFile else {
            updateChrome()
            return
        }
        let text = note.storage.string
        guard text != shownSource else { return }
        read(text, of: note.id)
    }

    /// The file on disk changed under the tab. Forgetting what the table was
    /// read from is what makes the next show read it again.
    func invalidateRender() {
        shownSource = nil
    }

    /// A different tab has come forward. Everything about the table is this
    /// tab's, so all of it goes.
    private func adopt(_ note: Note) {
        shownID = note.id
        shownSource = nil
        table = nil
        page = nil
        offset = 0
        sort = nil
        separator = note.fileURL
            .flatMap { CSVTable.Separator(fileExtension: $0.pathExtension) } ?? .comma
        grid.clearCellSelection()
        grid.deselectAll(nil)
        rebuildColumns()
        grid.reloadData()
        updateChrome()
    }

    private func apply(font: NSFont) {
        let monospaced = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        guard monospaced != cellFont else { return }
        cellFont = monospaced
        emptyLabel.font = font
        // A row is the text plus the air a row of text needs; the editor's
        // size carries the grid the way it carries every render.
        grid.rowHeight = max(22, (monospaced.pointSize + 9).rounded())
        rebuildColumns(force: true)
        grid.reloadData()
    }

    // MARK: - Reading

    /// Reads the file, off the main thread, and drops whatever the last read
    /// was doing.
    private func read(_ text: String, of id: UUID, keepingPlace: Bool = false) {
        readToken += 1
        let token = readToken
        let separator = self.separator
        queue.async { [weak self] in
            let table = CSVTable(text: text, separator: separator)
            DispatchQueue.main.async { [weak self] in
                self?.adopt(table, readFrom: text, token: token, of: id,
                            keepingPlace: keepingPlace)
            }
        }
    }

    /// A table has landed. A stale one — the file has moved on, or another tab
    /// has come forward since it was asked for — is dropped where it is.
    private func adopt(
        _ table: CSVTable, readFrom text: String, token: Int, of id: UUID,
        keepingPlace: Bool
    ) {
        guard token == readToken, shownID == id else { return }
        readCount += 1
        self.table = table
        shownSource = text
        // A read the file asked for starts unsorted: the columns may not even
        // be the same ones. A read the *reader* asked for is the same reading
        // again, so the order and the page it was on are kept.
        if !keepingPlace {
            sort = nil
        }
        reload()
    }

    /// Cuts the page the bar says it is showing out of the table in hand.
    /// Paging and sorting are arithmetic over rows already read, so unlike a
    /// dump's page there is nothing here to ask another thread for.
    private func reload() {
        if let table {
            let cut = table.page(offset: offset, sort: sort)
            offset = cut.offset
            page = cut
        } else {
            page = nil
        }
        // Every (row, column) the reader had picked out belongs to the page
        // that has just been replaced.
        grid.clearCellSelection()
        rebuildColumns()
        applySortIndicators()
        grid.reloadData()
        updateChrome()
        if scrollsToTop {
            scrollsToTop = false
            if grid.numberOfRows > 0 { grid.scrollRowToVisible(0) }
        }
        onDidFinish?()
    }

    // MARK: - The bar

    /// The `arrow.clockwise` at the leading edge: the file as it stands now,
    /// read again, and the same page asked for again.
    @objc private func refreshTable(_ sender: Any?) {
        guard let note, isColumnVisible else { return }
        read(note.storage.string, of: note.id, keepingPlace: true)
    }

    @objc private func showPreviousPage(_ sender: Any?) {
        step(by: -CSVTable.pageSize)
    }

    @objc private func showNextPage(_ sender: Any?) {
        step(by: CSVTable.pageSize)
    }

    private func step(by rows: Int) {
        guard let page else { return }
        let next = CSVTable.clamp(offset: offset + rows, total: page.total)
        guard next != offset else { return }
        offset = next
        scrollsToTop = true
        reload()
    }

    // MARK: - Drawing the chrome

    private func updateChrome() {
        updateRange()
        updateEmptyState()
    }

    private func updateRange() {
        guard let page else {
            rangeLabel.stringValue = ""
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            return
        }
        rangeLabel.stringValue = TextStats.rowRange(
            first: page.first, last: page.last, total: page.total
        )
        previousButton.isEnabled = page.offset > 0
        nextButton.isEnabled = page.offset + page.rows.count < page.total
    }

    /// The grid is always there. A file with a header and no rows under it,
    /// and an empty file, are each still a table: the header stands — the
    /// file's own columns, or blank ones when there are none to take — over
    /// the same striped rows, and the bar's range already says "No rows". The
    /// one caption left is the big file's, which is an instruction rather than
    /// a state.
    private func updateEmptyState() {
        let text = table == nil && isBigFile ? "Refresh to read this file." : ""
        emptyLabel.stringValue = text
        emptyLabel.isHidden = text.isEmpty
        scrollView.isHidden = false
    }

    // MARK: - The grid's columns

    /// One column per column of the page, plus the `#` gutter that numbers the
    /// rows from the top of the table rather than from the top of the page —
    /// row 2,101 is row 2,101 whichever page it is being read on.
    ///
    /// A page of the same columns as the last one keeps the columns it has,
    /// header cells and all. That is not only for the widths: the header is
    /// tracking the mouse for as long as a click on it is held, and taking its
    /// columns out from under it mid-click is what a sort used to do.
    private func rebuildColumns(force: Bool = false) {
        let columns = page?.columns ?? fallbackColumns
        let wanted = columns.enumerated().map { Self.identifier(for: $1, at: $0) }
        let hasGutter = grid.tableColumns.first?.identifier == SQLGridView.rowNumberColumn
        let existing = hasGutter ? Array(grid.tableColumns.dropFirst().map(\.identifier.rawValue))
            : nil
        if !force, let existing, existing == wanted {
            fillLastColumn()
            return
        }

        // The same columns keep the widths they have — the ones the reader may
        // have dragged, and the ones the last page settled on. Otherwise
        // paging would shuffle every column sideways on every press, measured
        // against a different hundred rows each time.
        let kept = grid.tableColumns.reduce(into: [String: CGFloat]()) {
            $0[$1.identifier.rawValue] = $1.width
        }
        let sameColumns = existing == wanted
        grid.clearCellSelection()
        for column in grid.tableColumns { grid.removeTableColumn(column) }
        let number = NSTableColumn(identifier: SQLGridView.rowNumberColumn)
        number.headerCell = SQLHeaderCell(textCell: "#")
        number.headerCell.alignment = .right
        number.title = "#"
        number.width = Layout.rowNumberWidth
        number.minWidth = Layout.rowNumberWidth
        number.maxWidth = Layout.rowNumberWidth
        grid.addTableColumn(number)

        for (index, name) in columns.enumerated() {
            let identifier = Self.identifier(for: name, at: index)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.headerCell = SQLHeaderCell(textCell: name)
            column.title = name
            column.headerToolTip = name.isEmpty ? nil : name
            column.width = (sameColumns ? kept[identifier] : nil)
                ?? page.map { width(ofColumn: index, in: $0) } ?? Layout.blankColumnWidth
            column.minWidth = Layout.minimumColumnWidth
            column.maxWidth = 1200
            grid.addTableColumn(column)
        }
        fillLastColumn()
    }

    /// The columns the grid stands on when there is no table to take them
    /// from: three blank ones, so there is still a grid.
    private var fallbackColumns: [String] { Self.blankColumns }

    static let blankColumns = Array(repeating: "", count: 3)

    /// A column's identifier is its position *and* its name. The position
    /// alone would let a re-read that renamed a header keep the old widths and
    /// the old sort; the name alone would not tell two columns called `id`
    /// apart, which a CSV is perfectly free to have.
    static func identifier(for name: String, at index: Int) -> String {
        "csv-\(index)-\(name)"
    }

    /// Whatever the columns leave over goes to the last of them, so a table of
    /// three narrow columns fills the pane rather than trailing off into a
    /// strip of ruled nothing. A table wider than the pane is left alone and
    /// scrolls, which is what a wide table should do.
    private func fillLastColumn() {
        guard let last = grid.tableColumns.last, grid.tableColumns.count > 1 else { return }
        let spacing = grid.intercellSpacing.width
        let taken = grid.tableColumns.reduce(0) { $0 + $1.width + spacing }
        let room = scrollView.contentSize.width
        guard room > 1, room - taken > 1 else { return }
        last.width += room - taken
    }

    /// As wide as the header and the first rows need, within reason. A column
    /// of essays is not allowed to push every other column off the screen, and
    /// a column of ids does not get a hand's width of nothing.
    private func width(ofColumn index: Int, in page: CSVTable.Page) -> CGFloat {
        guard index >= 0, index < page.columns.count else { return 120 }
        var widest = page.columns[index]
            .size(withAttributes: [.font: SQLHeaderCell.font]).width
            + SQLHeaderCell.indicatorRoom
        for row in page.rows.prefix(30) where index < row.count {
            widest = max(widest, row[index].size(withAttributes: [.font: cellFont]).width)
        }
        return min(max(widest + Layout.cellPadding * 2, Layout.minimumColumnWidth),
                   Layout.maximumColumnWidth)
    }

    /// Which header wears the chevron, and which way up. Ours to draw rather
    /// than the system's grey triangle: the sorted column is the one thing
    /// about a grid a reader looks for from across the room.
    private func applySortIndicators() {
        for (index, column) in grid.tableColumns.enumerated() {
            let cell = column.headerCell as? SQLHeaderCell
            // Column 0 is the `#` gutter; the data columns start after it.
            cell?.sortAscending = sort?.column == index - 1 ? sort?.ascending : nil
        }
        grid.headerView?.needsDisplay = true
    }

    // MARK: - Copying

    /// ⌘C: whatever is picked out, tab separated, the way a spreadsheet takes
    /// it — whole rows for a row selection, and only the columns inside the
    /// rectangle for a cell one.
    private func text(of selection: SQLGridView.Selection) -> String {
        guard let page else { return "" }
        switch selection {
        case .none:
            return ""
        case .rows(let rows):
            return rows.compactMap { index -> String? in
                guard index >= 0, index < page.rows.count else { return nil }
                return page.rows[index].joined(separator: "\t")
            }.joined(separator: "\n")
        case .cells(let rows, let columns):
            // A column of the grid is one past its column of the page: the `#`
            // gutter stands in front of them all and is never copied.
            return rows.compactMap { row -> String? in
                guard row >= 0, row < page.rows.count else { return nil }
                let values = page.rows[row]
                return columns.compactMap { column -> String? in
                    let index = column - 1
                    guard index >= 0, index < values.count else { return nil }
                    return values[index]
                }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    // MARK: - Where a row is written

    /// A value clicked: the editor beside the grid goes to the line the row is
    /// written on, the way a click on a rendered Markdown block goes to the
    /// paragraph behind it. A record whose quoted field runs over three lines
    /// lands on the first of them, since that is where the record begins.
    /// Nothing here takes the keyboard: the grid keeps it, so the arrows go on
    /// walking the cells.
    private func revealSource(ofRow row: Int) {
        guard sendsBlockClicks, let onSourceReveal, let page,
              row >= 0, row < page.sources.count
        else { return }
        onSourceReveal(page.sources[row])
    }

    // MARK: - The keyboard

    var takesKeyboard = false

    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(grid) ?? false
    }

    // MARK: - The footer

    /// A table being read is measured in rows and columns, the way a PDF is
    /// measured in pages: while the grid is on screen those are what the
    /// reader is looking at, and the file's own word count is not. In the
    /// editor mode the column is away and the counts stand, since there the
    /// tab is source like any other.
    var footerStatus: PreviewFooterStatus? {
        guard isColumnVisible, let table else { return nil }
        return PreviewFooterStatus(
            summary: TextStats.rowAndColumnCounts(rows: table.rows.count,
                                                  columns: table.columns.count),
            position: page.map {
                TextStats.rowPosition(first: $0.first, last: $0.last, total: $0.total)
            }
        )
    }

    // MARK: - Files let go on the grid

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    // MARK: - Background

    override func layout() {
        super.layout()
        // The column has changed width under the grid: the slack the last
        // column is holding is the wrong size now.
        fillLastColumn()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Both were handed a resolved colour rather than a dynamic one, so
        // light and dark are swapped by handing it over again.
        scrollView.backgroundColor = .textBackgroundColor
        grid.backgroundColor = .textBackgroundColor
        grid.headerView?.needsDisplay = true
        needsDisplay = true
    }

    // MARK: - Tests

    /// What the pane is showing, without reaching into its views.
    var shownTable: CSVTable? { table }
    var shownPage: CSVTable.Page? { page }
    var shownSort: CSVTable.Sort? { sort }
    var rangeText: String { rangeLabel.stringValue }
    var emptyText: String { emptyLabel.stringValue }
    var showsRefreshButton: Bool { !refreshButton.isHidden }
    var refreshButtonTip: String? { refreshButton.toolTip }
    var refreshButtonTitle: String { refreshButton.title }
    var gridForTesting: SQLGridView { grid }
    var barFrameForTesting: NSRect { bar.frame }

    func pressNextForTesting() { showNextPage(nil) }
    func pressPreviousForTesting() { showPreviousPage(nil) }
    func pressRefreshForTesting() { refreshTable(nil) }
    func copyTextForTesting(rows: IndexSet) -> String { text(of: .rows(rows)) }
    func copyTextForTesting(cellRows: ClosedRange<Int>, columns: ClosedRange<Int>) -> String {
        text(of: .cells(rows: cellRows, columns: columns))
    }

    /// Clicks a column's header the way the header view does — the mouse-up
    /// end of it, which is where a sort belongs.
    func clickHeaderForTesting(at index: Int) {
        let column = index + 1
        guard column >= 0, column < grid.tableColumns.count else { return }
        tableView(grid, didClick: grid.tableColumns[column])
    }
}

// MARK: - The grid's data

extension CSVPreviewView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        page?.rows.count ?? 0
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, let page, row >= 0, row < page.rows.count else { return nil }
        let columnIndex = tableView.column(withIdentifier: tableColumn.identifier)
        let cell = self.cell(in: tableView, for: tableColumn)
        cell.highlight = grid.highlight(row: row, column: columnIndex)
        guard let field = cell.textField else { return cell }

        if tableColumn.identifier == SQLGridView.rowNumberColumn {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: max(9, cellFont.pointSize - 2),
                                                    weight: .regular)
            field.textColor = .tertiaryLabelColor
            field.stringValue = "\(page.offset + row + 1)"
            cell.toolTip = nil
            return cell
        }

        let index = columnIndex - 1
        guard index >= 0, index < page.rows[row].count else {
            field.stringValue = ""
            return cell
        }
        let value = page.rows[row][index]
        field.font = cellFont
        field.textColor = .labelColor
        field.attributedStringValue = attributed(value)
        // What the column is too narrow to show is one hover away, rather than
        // gone. A value written over more than one line says so on its own
        // line, since the cell can only ever draw the first.
        let drawn = value.size(withAttributes: [.font: cellFont]).width
        cell.toolTip = drawn > tableColumn.width - Layout.cellPadding
            || value.contains(where: \.isNewline) ? value : nil
        return cell
    }

    /// Every cell of a CSV is text — there is no schema to say otherwise, and
    /// a column of digits in a delimited file is a column of digits, not a
    /// declared number. So the alignment is the reading alignment throughout,
    /// and a value written over lines is drawn as its first line rather than
    /// as a row four times the height of its neighbours.
    private func attributed(_ value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        return NSAttributedString(string: value, attributes: [
            .font: cellFont,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    private func cell(in tableView: NSTableView, for column: NSTableColumn) -> SQLCellView {
        if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self)
            as? SQLCellView {
            return reused
        }
        let cell = SQLCellView()
        cell.identifier = column.identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.drawsBackground = false
        field.isBordered = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor,
                                           constant: Layout.cellPadding / 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor,
                                            constant: -Layout.cellPadding / 2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A click on a header sorts by that column, and a second click turns it
    /// round. The sort orders the whole table and pages it again from the top,
    /// so sorting four thousand rows by name shows the first hundred names and
    /// not the first hundred rows rearranged.
    ///
    /// On the click and not on the press. `mouseDownInHeaderOfTableColumn:`
    /// arrives while the header is still tracking the mouse, and the page it
    /// asks for lands inside that tracking loop — rebuilding the very columns
    /// the header is holding. This one arrives after the header has let go.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier != SQLGridView.rowNumberColumn,
              !tableColumn.title.isEmpty else { return }
        let index = tableView.column(withIdentifier: tableColumn.identifier) - 1
        guard index >= 0 else { return }
        if sort?.column == index, sort?.ascending == true {
            sort = CSVTable.Sort(column: index, ascending: false)
        } else {
            sort = CSVTable.Sort(column: index, ascending: true)
        }
        offset = 0
        scrollsToTop = true
        grid.clearCellSelection()
        reload()
    }
}
