import AppKit

/// The preview column holding a `.sql` file's database: the tables the dump
/// builds, a hundred rows at a time, where a Markdown tab would have its
/// render.
///
/// A dump is the one preview in Nota that has to be *run* to be seen. The
/// text in the editor is the whole of the truth — unsaved edits included —
/// and every time it settles the file is run again into a fresh database in
/// memory (`SQLDump`), off the main thread, with the run before it dropped
/// where it stands. What comes back is a picker of tables, a page of rows and,
/// when a statement would not go in, an alert naming the file and the
/// statement it stopped on.
///
/// The query box above the grid asks questions of that database and can never
/// change it: every statement typed there is prepared under an authorizer that
/// refuses everything but a read, so `DELETE FROM orders` comes back as "not
/// authorized" rather than as a table with rows missing. Nothing here ever
/// touches the file on disk — SQLite never opens it; only the editor's text
/// reaches the database, and the database is thrown away with the tab.
///
/// The pane starts a hover band below the top of the column. That band is the
/// corner slot's (`ModeControlOverlay.hoverBandHeight`), and the Editor ·
/// Split · Reading control floats in it: the query box is five rows tall and
/// full width, so the two would otherwise share the same corner.
final class SQLPreviewView: NSView, PreviewContent {

    // MARK: - The chrome

    /// Five rows of a monospaced editor, because a query is laid out over
    /// lines. Return makes one of them; ⌘↩ is what runs the query.
    private let queryBox = SQLQueryBox()
    private let bar = NSView()
    private let tablePicker = NSPopUpButton()
    /// Runs the file into a fresh database and asks for the page again,
    /// keeping the table, the query, the sort and the page it was on. It is
    /// also the *only* way a big file is ever run, so there is one button
    /// rather than two: for a dump small enough to run itself this says "as
    /// the file is now", and for one that is not it says "read it".
    private let refreshButton = NSButton()
    /// "Run" over the query box at its leading edge, in the band the corner
    /// control keeps clear, for the reader who does not know ⌘↩. The same
    /// run the key makes.
    private let runQueryButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let grid = SQLGridView()
    /// The quiet line where the grid would be, for a dump with nothing to
    /// show yet: a big file waiting to be run, a database with no tables, a
    /// query that matched nothing.
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
        /// Where the Run button starts: low in the band, 6pt over the box.
        static let runTop = topClearance - controlHeight - 6
        /// How much of a query the box shows without being scrolled.
        static let queryRows = 5
    }

    private var queryHeight: NSLayoutConstraint?

    // MARK: - What the pane is showing

    /// The tab in front, so the table picked and the query typed can be
    /// written where the session will find them.
    private weak var note: Note?
    private var shownID: UUID?
    /// The text the database was built from. A show with the same text does
    /// nothing at all — a resize and a tab switch both ask again.
    private var shownSource: String?
    private var dump: SQLDump?
    private var page: SQLDump.Page?
    private var pickedTable: String?
    private var sort: SQLDump.Sort?
    private var offset = 0
    /// The run failure the reader has already been told about, so a file
    /// being edited into shape does not put the same alert up on every run.
    /// Cleared when the file runs clean, and when another tab comes forward.
    private var announcedRunFailure: String?
    /// The page that follows a sort starts at the top of the table, so the
    /// grid goes back up with it.
    private var scrollsToTop = false
    private var isBigFile = false
    private var isColumnVisible = false
    private var cellFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Runs are asked for from the main thread and answered on this one, in
    /// the order they were asked. A database handle belongs to one queue, so
    /// every question this pane ever puts to SQLite is put here.
    private let queue = DispatchQueue(label: "com.nota.sql-preview", qos: .userInitiated)
    /// The run and the page each carry a token, so an answer about the file
    /// two keystrokes ago is not news about the one on screen now.
    private var runToken = 0
    private var pageToken = 0

    // MARK: - What the pane reports

    var onDropFiles: (([URL]) -> Void)?
    var onStateChange: (() -> Void)?
    /// Where the row under a clicked cell is written in the file. Split only,
    /// which is what `sendsBlockClicks` says: in reading there is no editor on
    /// screen to point at.
    var onSourceReveal: ((NSRange) -> Void)?
    /// Mirrors the render's own: true in split, where the grid is a way into
    /// the text beside it, and false in reading, where the database is simply
    /// what is being read.
    var sendsBlockClicks = true
    /// Run when a database, or a page of one, has landed — for the tests,
    /// which have no other way to wait for a background run.
    var onDidFinish: (() -> Void)?
    /// How many times the file has been run into a database. The one number
    /// that says a big file is not being re-run on every keystroke.
    private(set) var runCount = 0

    /// Stands in for the alert, so a test can drive a failing query without
    /// putting a modal on screen — the same hook the window's own
    /// `confirmDiscardOverrideForTesting` is. Nothing in the app sets it.
    var alertOverrideForTesting: ((String, String) -> Void)?
    /// The last alert this pane raised, message and informative text.
    private(set) var lastAlert: (message: String, informative: String)?

    // MARK: - Building

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)
        buildQueryRow()
        buildBar()
        buildGrid()
        activateConstraints()
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildQueryRow() {
        queryBox.translatesAutoresizingMaskIntoConstraints = false
        queryBox.placeholder = "SELECT …"
        queryBox.font = cellFont
        queryBox.onRun = { [weak self] in self?.runQuery() }
        queryBox.onCancel = { [weak self] in self?.escapeQuery() }
        queryBox.setAccessibilityIdentifier("sql-query")
        addSubview(queryBox)
    }

    private func buildBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        tablePicker.translatesAutoresizingMaskIntoConstraints = false
        tablePicker.controlSize = .small
        tablePicker.font = .systemFont(ofSize: 11)
        tablePicker.target = self
        tablePicker.action = #selector(pickTable)
        tablePicker.setAccessibilityIdentifier("sql-tables")
        bar.addSubview(tablePicker)

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
        refreshButton.action = #selector(refreshDump)
        refreshButton.toolTip = "Run again"
        refreshButton.setAccessibilityIdentifier("sql-refresh")
        bar.addSubview(refreshButton)

        runQueryButton.translatesAutoresizingMaskIntoConstraints = false
        runQueryButton.bezelStyle = .rounded
        runQueryButton.controlSize = .small
        runQueryButton.font = .systemFont(ofSize: 11)
        runQueryButton.title = "Run"
        runQueryButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        runQueryButton.image?.isTemplate = true
        runQueryButton.imagePosition = .imageLeading
        runQueryButton.imageHugsTitle = true
        runQueryButton.target = self
        runQueryButton.action = #selector(runQueryFromButton)
        runQueryButton.toolTip = "Run the query  ⌘↩"
        runQueryButton.setAccessibilityIdentifier("sql-run")
        addSubview(runQueryButton)

        // Numbers that change as the reader pages: tabular figures, so the
        // label does not shuffle sideways between one page and the next.
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.alignment = .center
        rangeLabel.setAccessibilityIdentifier("sql-range")
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
        previousButton.setAccessibilityIdentifier("sql-previous")
        nextButton.setAccessibilityIdentifier("sql-next")
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
        grid.setAccessibilityIdentifier("sql-grid")

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.setAccessibilityIdentifier("sql-empty")
        addSubview(emptyLabel)
    }

    private func activateConstraints() {
        // The column is the reader's to size, and nothing in this bar is
        // allowed a say in how narrow it may be dragged: every content view
        // in the column is pinned to its full width at all times, so a
        // control here that refused to be squeezed would be a floor under
        // the whole preview column — under the Markdown render's too, which
        // has never had one. They give way instead, in the order they can
        // best be spared, and the picker and the range label truncate.
        let giveWay: [(NSView, NSLayoutConstraint.Priority)] = [
            (tablePicker, .init(rawValue: 150)),
            (rangeLabel, .init(rawValue: 140)),
            (refreshButton, .init(rawValue: 160)),
            (runQueryButton, .init(rawValue: 160)),
            (queryBox, .init(rawValue: 150)),
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

        let height = queryBox.heightAnchor.constraint(
            equalToConstant: queryBox.height(forRows: Layout.queryRows)
        )
        queryHeight = height

        NSLayoutConstraint.activate([
            // The Run button stands in the band above the box, at the leading
            // edge, sitting low in it so it reads as the box's own rather
            // than the strip's: the band's clearance was already there, so
            // the box is no lower for it.
            runQueryButton.topAnchor.constraint(equalTo: topAnchor, constant: Layout.runTop),
            runQueryButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
            runQueryButton.heightAnchor.constraint(equalToConstant: Layout.controlHeight),

            queryBox.topAnchor.constraint(equalTo: topAnchor, constant: Layout.topClearance),
            queryBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
            queryBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.inset),
            height,

            bar.topAnchor.constraint(equalTo: queryBox.bottomAnchor, constant: Layout.rowGap),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.inset),
            bar.heightAnchor.constraint(equalToConstant: Layout.controlHeight),

            tablePicker.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            tablePicker.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tablePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            refreshButton.leadingAnchor.constraint(
                equalTo: tablePicker.trailingAnchor, constant: Layout.barSpacing
            ),
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
        // A database nobody can see is not worth building — and a run costs
        // the whole file, so the column being away is a real saving.
        guard context.isVisible else { return }

        isBigFile = BigFile.isBig(length: note.storage.length)
        // A big dump is run when it is asked for and never on its own: a
        // hundred megabytes of inserts is not a thing to start between one
        // keystroke and the next, and it is certainly not a thing to start
        // again on the next one.
        guard !isBigFile else {
            updateChrome()
            return
        }
        let sql = note.storage.string
        guard sql != shownSource else { return }
        run(sql, of: note.id)
    }

    /// The file on disk changed under the tab, or a picture in the store did.
    /// Forgetting what the database was built from is what makes the next
    /// show build it again.
    func invalidateRender() {
        shownSource = nil
    }

    /// A different tab has come forward. Everything about the database is
    /// this tab's, so all of it goes; the table it was open at and the query
    /// it was being read with come back off the note.
    private func adopt(_ note: Note) {
        shownID = note.id
        shownSource = nil
        dump = nil
        page = nil
        announcedRunFailure = nil
        offset = 0
        sort = nil
        pickedTable = note.sqlTable
        queryBox.string = note.sqlQuery ?? ""
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
        queryBox.font = monospaced
        queryHeight?.constant = queryBox.height(forRows: Layout.queryRows)
        emptyLabel.font = font
        // A row is the text plus the air a row of text needs; the editor's
        // size carries the grid the way it carries every render.
        grid.rowHeight = max(22, (monospaced.pointSize + 9).rounded())
        rebuildColumns(force: true)
        grid.reloadData()
    }

    // MARK: - Running

    /// Builds the database, off the main thread, and drops whatever the last
    /// run was doing.
    private func run(_ sql: String, of id: UUID, keepingPlace: Bool = false) {
        runToken += 1
        pageToken += 1
        let token = runToken
        queue.async { [weak self] in
            let dump = SQLDump(sql: sql)
            DispatchQueue.main.async { [weak self] in
                self?.adopt(dump, builtFrom: sql, token: token, of: id,
                            keepingPlace: keepingPlace)
            }
        }
    }

    /// A database has landed. A stale one — the file has moved on, or another
    /// tab has come forward since it was asked for — is dropped where it is.
    private func adopt(
        _ dump: SQLDump, builtFrom sql: String, token: Int, of id: UUID,
        keepingPlace: Bool = false
    ) {
        guard token == runToken, shownID == id else { return }
        runCount += 1
        self.dump = dump
        shownSource = sql
        // The table the tab was left at, if the file still has it — and the
        // first one otherwise, since a database opened on nothing has nothing
        // to say.
        if pickedTable == nil || !dump.tables.contains(pickedTable ?? "") {
            pickedTable = dump.tables.first
            offset = 0
        }
        // A run the file asked for starts unsorted: the columns may not even
        // be the same ones. A run the *reader* asked for is the same reading
        // again, so the order and the page it was on are kept.
        if !keepingPlace {
            sort = nil
            applySortIndicators()
        }
        announce(dump.failure)
        reload()
    }

    /// Asks the database for the page the bar says it is showing: the query
    /// when there is one in the box, the picked table when there is not.
    private func reload() {
        guard let dump else {
            page = nil
            rebuildColumns()
            grid.reloadData()
            updateChrome()
            onDidFinish?()
            return
        }
        pageToken += 1
        let token = pageToken
        let query = queryBox.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let table = pickedTable
        let offset = self.offset
        let sort = self.sort
        queue.async { [weak self] in
            var answer: Result<SQLDump.Page, SQLDump.Failure>?
            if !query.isEmpty {
                answer = dump.page(ofQuery: query, offset: offset, sort: sort)
            } else if let table {
                answer = dump.page(ofTable: table, offset: offset, sort: sort)
            }
            DispatchQueue.main.async { [weak self] in
                self?.adopt(answer, token: token, wasQuery: !query.isEmpty)
            }
        }
    }

    /// A page has landed, or the question that would have made one came back
    /// refused.
    private func adopt(
        _ answer: Result<SQLDump.Page, SQLDump.Failure>?, token: Int, wasQuery: Bool
    ) {
        guard token == pageToken else { return }
        switch answer {
        case .success(let page):
            self.page = page
            offset = page.offset
            // Every (row, column) the reader had picked out belongs to the
            // page that has just been replaced.
            grid.clearCellSelection()
        case .failure(let failure):
            // The grid keeps the page it had: a query that will not run is
            // not a reason to take away what was being read.
            announce(queryFailure: failure, wasQuery: wasQuery)
        case nil:
            page = nil
            grid.clearCellSelection()
        }
        rebuildColumns()
        grid.reloadData()
        updateChrome()
        if scrollsToTop {
            scrollsToTop = false
            if grid.numberOfRows > 0 { grid.scrollRowToVisible(0) }
        }
        onDidFinish?()
    }

    // MARK: - Saying what would not run

    /// The alert a failing query puts up. A question is asked one press at a
    /// time, so it is answered one alert at a time — nothing is held back.
    private func announce(queryFailure failure: SQLDump.Failure, wasQuery: Bool) {
        guard wasQuery else {
            present("Couldn’t read “\(fileName)”.", informative: failure.message)
            return
        }
        // SQLite's own words first — `near "*": syntax error` says where —
        // and then the rule the box works under, because the message alone
        // does not: a refused DELETE reads "not authorized", and a mistyped
        // one is a syntax error that never got as far as being refused.
        let detail = failure.message.contains("not authorized")
            ? Self.readOnlyRule
            : failure.message + "\n\n" + Self.readOnlyRule
        present("Couldn’t run the query.", informative: detail)
    }

    /// What the query box accepts, said the same way in every alert it puts
    /// up. Tested against, so worded once.
    static let readOnlyRule = "Only SELECT queries run here. The tables are read-only."

    /// The alert the file's own failure puts up — once. A dump being typed is
    /// broken most of the way through being written, and an alert on every
    /// keystroke would be the pane arguing with the reader. The same message
    /// is said once and then held until the file runs clean again.
    private func announce(_ failure: SQLDump.Failure?) {
        guard let failure else {
            announcedRunFailure = nil
            return
        }
        let key = failure.message + "\u{1}" + failure.statement
        guard key != announcedRunFailure else { return }
        announcedRunFailure = key
        let detail = failure.statement.isEmpty
            ? failure.message
            : failure.message + "\n\n" + failure.statement
        present("Couldn’t run “\(fileName)”.", informative: detail)
    }

    private var fileName: String { note?.title ?? "the dump" }

    /// One OK button, on the window as a sheet — the same alert Nota puts up
    /// for a file it could not open, in the same words.
    private func present(_ message: String, informative: String) {
        lastAlert = (message, informative)
        if let alertOverrideForTesting {
            alertOverrideForTesting(message, informative)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - The bar

    @objc private func pickTable(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, title != pickedTable
            || !queryBox.string.isEmpty
        else { return }
        pickedTable = title
        // Picking a table is asking for that table, so the question in the
        // box is put down rather than left standing over the answer.
        clearQuery()
        offset = 0
        sort = nil
        applySortIndicators()
        note?.sqlTable = title
        onStateChange?()
        reload()
    }

    /// The `arrow.clockwise` beside the picker: the file as it stands now,
    /// run into a database of its own, and the same page asked for again.
    /// The reader pressed it, so a file that still will not run says so again
    /// rather than holding the message it was holding.
    /// The Run button over the box: the same run ⌘↩ makes.
    @objc private func runQueryFromButton(_ sender: Any?) {
        runQuery()
    }

    @objc private func refreshDump(_ sender: Any?) {
        guard let note, isColumnVisible else { return }
        announcedRunFailure = nil
        run(note.storage.string, of: note.id, keepingPlace: true)
    }

    @objc private func showPreviousPage(_ sender: Any?) {
        step(by: -SQLDump.pageSize)
    }

    @objc private func showNextPage(_ sender: Any?) {
        step(by: SQLDump.pageSize)
    }

    private func step(by rows: Int) {
        guard let page else { return }
        let next = SQLDump.clamp(offset: offset + rows, total: page.total)
        guard next != offset else { return }
        offset = next
        scrollsToTop = true
        reload()
    }

    // MARK: - The query box

    /// ⌘↩ in the query box. Return there is a newline: the box is five rows
    /// tall because a query is written over lines, and a key that ran the
    /// thing half-written would make those rows unusable.
    private func runQuery() {
        let query = queryBox.string.trimmingCharacters(in: .whitespacesAndNewlines)
        note?.sqlQuery = query.isEmpty ? nil : query
        onStateChange?()
        offset = 0
        sort = nil
        applySortIndicators()
        scrollsToTop = true
        reload()
    }

    /// Esc: the question goes and the table comes back.
    private func clearQuery() {
        guard !queryBox.string.isEmpty else { return }
        queryBox.string = ""
        note?.sqlQuery = nil
        onStateChange?()
        offset = 0
    }

    private func escapeQuery() {
        guard !queryBox.string.isEmpty else { return }
        clearQuery()
        sort = nil
        applySortIndicators()
        reload()
    }

    // MARK: - Drawing the chrome

    private func updateChrome() {
        updateTablePicker()
        updateRange()
        updateEmptyState()
    }

    private func updateTablePicker() {
        let tables = dump?.tables ?? []
        if tablePicker.itemTitles != tables {
            tablePicker.removeAllItems()
            tablePicker.addItems(withTitles: tables)
        }
        if let pickedTable, tables.contains(pickedTable) {
            tablePicker.selectItem(withTitle: pickedTable)
        }
        tablePicker.isEnabled = !tables.isEmpty
        tablePicker.toolTip = tables.isEmpty ? nil : TextStats.tableCounts(tables.count)
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

    /// The grid is always there. A table with no rows, a query that found
    /// none, a file with no tables in it yet — each is still a table: the
    /// header stands (the picked table's columns, or blank ones when there
    /// is no table to take them from) over the same striped rows, so the
    /// pane looks like what it is rather than like nothing. The bar's range
    /// already says "No rows"; the one caption left is the big file's, which
    /// is an instruction rather than a state.
    private func updateEmptyState() {
        let text = dump == nil && isBigFile ? "Run to read this dump." : ""
        emptyLabel.stringValue = text
        emptyLabel.isHidden = text.isEmpty
        scrollView.isHidden = false
    }

    // MARK: - The grid's columns

    /// One column per column of the page, plus the `#` gutter that numbers
    /// the rows from the top of the table rather than from the top of the
    /// page — row 2,101 is row 2,101 whichever page it is being read on.
    ///
    /// A page of the same columns as the last one keeps the columns it has,
    /// header cells and all. That is not only for the widths: the header is
    /// tracking the mouse for as long as a click on it is held, and taking
    /// its columns out from under it mid-click is what a sort used to do.
    private func rebuildColumns(force: Bool = false) {
        let columns = page?.columns ?? fallbackColumns
        let wanted = columns.enumerated().map { Self.identifier(for: $1, at: $0) }
        let hasGutter = grid.tableColumns.first?.identifier == SQLGridView.rowNumberColumn
        let existing = hasGutter ? Array(grid.tableColumns.dropFirst().map(\.identifier.rawValue))
            : nil
        if !force, let existing, existing == wanted {
            applyColumnTips()
            applySortIndicators()
            fillLastColumn()
            return
        }

        // The same columns keep the widths they have — the ones the reader
        // may have dragged, and the ones the last page settled on. Otherwise
        // paging a table would shuffle every column sideways on every press,
        // measured against a different hundred rows each time.
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

        for (index, column) in columns.enumerated() {
            let identifier = Self.identifier(for: column, at: index)
            let table = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            table.headerCell = SQLHeaderCell(textCell: column.name)
            table.title = column.name
            table.width = (sameColumns ? kept[identifier] : nil)
                ?? page.map { width(of: column, in: $0) } ?? Layout.blankColumnWidth
            table.minWidth = Layout.minimumColumnWidth
            table.maxWidth = 1200
            grid.addTableColumn(table)
        }
        applyColumnTips()
        applySortIndicators()
        fillLastColumn()
    }

    /// The columns the grid stands on when there is no page to take them
    /// from: the picked table's own, from the schema, so an empty table still
    /// shows what it is a table of; and, with no table at all, three blank
    /// ones, so there is still a grid.
    private var fallbackColumns: [SQLDump.Column] {
        if let dump, let pickedTable, dump.tables.contains(pickedTable) {
            let declared = dump.declaredTypes(ofTable: pickedTable)
            if !declared.isEmpty { return declared }
        }
        return Self.blankColumns
    }

    static let blankColumns = Array(repeating: SQLDump.Column(name: "", declaredType: nil), count: 3)

    /// A column's identifier is its name — the sort and the tips look it up
    /// by that — except a blank one, which has none and gets its position.
    static func identifier(for column: SQLDump.Column, at index: Int) -> String {
        column.name.isEmpty ? "sql-blank-\(index)" : column.name
    }

    /// What the schema says a column holds, where a reader looks for it: over
    /// the name itself.
    private func applyColumnTips() {
        guard let page else { return }
        for column in grid.tableColumns.dropFirst() {
            guard let match = page.columns.first(where: { $0.name == column.identifier.rawValue })
            else { continue }
            column.headerToolTip = match.declaredType.map { "\(match.name)  ·  \($0)" } ?? match.name
        }
    }

    /// Whatever the columns leave over goes to the last of them, so a table
    /// of three narrow columns fills the pane rather than trailing off into a
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
    /// of essays is not allowed to push every other column off the screen,
    /// and a column of ids does not get a hand's width of nothing.
    private func width(of column: SQLDump.Column, in page: SQLDump.Page) -> CGFloat {
        guard let index = page.columns.firstIndex(where: { $0.name == column.name }) else {
            return 120
        }
        var widest = column.name.size(withAttributes: [.font: SQLHeaderCell.font]).width
            + SQLHeaderCell.indicatorRoom
        for row in page.rows.prefix(30) where index < row.count {
            widest = max(widest, row[index].displayText
                .size(withAttributes: [.font: cellFont]).width)
        }
        return min(max(widest + Layout.cellPadding * 2, Layout.minimumColumnWidth),
                   Layout.maximumColumnWidth)
    }

    /// Which header wears the chevron, and which way up. Ours to draw rather
    /// than the system's grey triangle: the sorted column is the one thing
    /// about a grid a reader looks for from across the room.
    private func applySortIndicators() {
        for column in grid.tableColumns {
            let cell = column.headerCell as? SQLHeaderCell
            cell?.sortAscending = sort?.column == column.identifier.rawValue
                ? sort?.ascending : nil
        }
        grid.headerView?.needsDisplay = true
    }

    // MARK: - Copying

    /// ⌘C: whatever is picked out, tab separated, the way a spreadsheet takes
    /// it — whole rows for a row selection, and only the columns inside the
    /// rectangle for a cell one. `NULL` is copied as the word, because that
    /// is what the cell says and pasting an empty cell for it would be
    /// pasting something else.
    private func text(of selection: SQLGridView.Selection) -> String {
        guard let page else { return "" }
        switch selection {
        case .none:
            return ""
        case .rows(let rows):
            return rows.compactMap { index -> String? in
                guard index >= 0, index < page.rows.count else { return nil }
                return page.rows[index].map(\.displayText).joined(separator: "\t")
            }.joined(separator: "\n")
        case .cells(let rows, let columns):
            // A column of the grid is one past its column of the page: the
            // `#` gutter stands in front of them all and is never copied.
            return rows.compactMap { row -> String? in
                guard row >= 0, row < page.rows.count else { return nil }
                let values = page.rows[row]
                return columns.compactMap { column -> String? in
                    let index = column - 1
                    guard index >= 0, index < values.count else { return nil }
                    return values[index].displayText
                }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    // MARK: - Where a row is written

    /// A value clicked: the editor beside the grid goes to the `INSERT` that
    /// wrote the row it is in, the way a click on a rendered Markdown block
    /// goes to the paragraph behind it.
    ///
    /// The page carries a rowid per row and `SQLSourceMap` knows which
    /// statement made which rowid, so a row of a multi-row insert lands on its
    /// own tuple rather than on the statement's head. The page also says which
    /// table those rowids are of — the picked one when a table is being read,
    /// and the one table the query read when it is a query — so a query's rows
    /// point at the file too. Everything that has no rowid to be looked up
    /// by — a query of any other shape, a `WITHOUT ROWID` table, a row whose
    /// insert is not in this file — does nothing at all, which is better than
    /// landing somewhere arbitrary. Nothing here takes the keyboard: the grid
    /// keeps it, so the arrows go on walking the cells.
    private func revealSource(ofRow row: Int) {
        guard sendsBlockClicks, let onSourceReveal, let dump, let page,
              let rowids = page.rowids, let table = page.rowidTable,
              row >= 0, row < rowids.count,
              let range = dump.sourceMap.range(ofRowid: rowids[row], inTable: table)
        else { return }
        onSourceReveal(range)
    }

    // MARK: - The keyboard

    var takesKeyboard = false

    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(grid) ?? false
    }

    // MARK: - The footer

    /// A dump being read is measured in tables and rows, the way a PDF is
    /// measured in pages: while the grid is on screen those are what the
    /// reader is looking at, and the file's own word count is not. In the
    /// editor mode the column is away and the counts stand, since there the
    /// tab is source like any other.
    var footerStatus: PreviewFooterStatus? {
        guard isColumnVisible, let dump else { return nil }
        return PreviewFooterStatus(
            summary: TextStats.tableCounts(dump.tables.count),
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

    /// What the pane is showing, without reaching into its views: the tables
    /// the dump built, the page on screen, and the last alert it raised.
    var tables: [String] { dump?.tables ?? [] }
    var shownPage: SQLDump.Page? { page }
    var shownTable: String? { pickedTable }
    var shownSort: SQLDump.Sort? { sort }
    var rangeText: String { rangeLabel.stringValue }
    var showsRefreshButton: Bool { !refreshButton.isHidden }
    var refreshButtonTip: String? { refreshButton.toolTip }
    var refreshButtonTitle: String { refreshButton.title }
    var runButtonTitle: String { runQueryButton.title }
    func pressRunQueryForTesting() { runQueryButton.performClick(nil) }
    var queryText: String { queryBox.string }
    var gridForTesting: SQLGridView { grid }
    var queryBoxForTesting: SQLQueryBox { queryBox }

    func setQueryForTesting(_ query: String) {
        queryBox.string = query
        runQuery()
    }

    func escapeQueryForTesting() { escapeQuery() }
    func pickTableForTesting(_ table: String) {
        tablePicker.selectItem(withTitle: table)
        pickTable(tablePicker)
    }

    func pressNextForTesting() { showNextPage(nil) }
    func pressPreviousForTesting() { showPreviousPage(nil) }
    func pressRefreshForTesting() { refreshDump(nil) }
    func copyTextForTesting(rows: IndexSet) -> String { text(of: .rows(rows)) }
    func copyTextForTesting(cellRows: ClosedRange<Int>, columns: ClosedRange<Int>) -> String {
        text(of: .cells(rows: cellRows, columns: columns))
    }

    /// Clicks a column's header the way the header view does — the mouse-up
    /// end of it, which is where a sort belongs.
    func clickHeaderForTesting(_ column: String) {
        guard let table = grid.tableColumns.first(where: { $0.identifier.rawValue == column })
        else { return }
        tableView(grid, didClick: table)
    }
}

// MARK: - The grid's data

extension SQLPreviewView: NSTableViewDataSource, NSTableViewDelegate {

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

        guard let index = page.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue }),
              index < page.rows[row].count
        else {
            field.stringValue = ""
            return cell
        }
        let value = page.rows[row][index]
        field.font = cellFont
        // Numbers are read against each other, so they line up on their last
        // digit; text is read from its first letter.
        field.alignment = value.isNumber ? .right : .left
        field.textColor = .labelColor
        field.attributedStringValue = attributed(value)
        // What the column is too narrow to show is one hover away, rather
        // than gone.
        let text = value.displayText
        let drawn = text.size(withAttributes: [.font: cellFont]).width
        cell.toolTip = drawn > tableColumn.width - Layout.cellPadding ? text : nil
        return cell
    }

    /// `NULL` is not a value, and it does not read as one: dimmed and set
    /// aslant, so a column of them is plainly a column of nothing rather
    /// than a column of the word.
    private func attributed(_ value: SQLDump.Value) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = value.isNumber ? .right : .left
        var attributes: [NSAttributedString.Key: Any] = [
            .font: cellFont,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor,
        ]
        if case .null = value {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            attributes[.obliqueness] = 0.2
        }
        if case .blob = value {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: value.displayText, attributes: attributes)
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
    /// round. The sort is the database's, not the page's: it orders the whole
    /// table and pages it again from the top, so sorting four thousand rows
    /// by name shows the first hundred names and not the first hundred rows
    /// rearranged.
    ///
    /// On the click and not on the press. `mouseDownInHeaderOfTableColumn:`
    /// arrives while the header is still tracking the mouse, and the page it
    /// asks for lands inside that tracking loop — rebuilding the very columns
    /// the header is holding. This one arrives after the header has let go.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier != SQLGridView.rowNumberColumn,
              !tableColumn.title.isEmpty else { return }
        let name = tableColumn.identifier.rawValue
        if sort?.column == name, sort?.ascending == true {
            sort = SQLDump.Sort(column: name, ascending: false)
        } else {
            sort = SQLDump.Sort(column: name, ascending: true)
        }
        offset = 0
        scrollsToTop = true
        grid.clearCellSelection()
        applySortIndicators()
        reload()
    }
}
