import AppKit

protocol TabPickerPanelDelegate: AnyObject {
    func tabPicker(_ picker: TabPickerPanel, didChoose tabIndex: Int)
    func tabPicker(_ picker: TabPickerPanel, didChooseHeading heading: MarkdownHeadings.Heading)
    /// The "Add new tab" row was chosen — ⌘T, by another door.
    func tabPickerDidRequestNewTab(_ picker: TabPickerPanel)
    /// The top row in bookmarks mode: bookmark the tab in front, or take the
    /// bookmark off it — ⌘D, by another door.
    func tabPickerDidRequestBookmarkCurrentTab(_ picker: TabPickerPanel)
    /// A bookmark row was chosen: select the tab if the file is already open
    /// in this window, otherwise open it (SPEC Todo 13).
    func tabPicker(_ picker: TabPickerPanel, didChooseBookmark path: String)
    /// ⌘⌫ on a bookmark row: it stops being a bookmark. The panel stays up.
    func tabPicker(_ picker: TabPickerPanel, didRemoveBookmark path: String)
}

/// ⌘P: a small centred panel in the shape of Xcode's Open Quickly — a search
/// field over a list, fuzzy-matched on tab title.
///
/// `@` as the first character (Todo 9) swaps the list for the front `.md`
/// tab's headings, the rest of the query fuzzy-filtering those instead of the
/// tabs; deleting it back out returns to the tab list.
///
/// Above the field sits one fixed row, in every mode. It is not part of the
/// list — nothing filters it away — but ↑ from the top of the list lands on it
/// and Return there chooses it. In `.tabs` and `.headings` it reads "Add new
/// tab", so ⌘P alone can do what ⌘T does; in `.bookmarks` it is the front
/// tab's bookmark toggle, ⌘D by another door. It is a one-row table of its
/// own, sharing the list's cell view and table style, so it is drawn as a list
/// row rather than as something that only looks like one.
final class TabPickerPanel: NSObject {
    private static let panelWidth: CGFloat = 420
    private static let rowHeight: CGFloat = 26
    private static let maximumVisibleRows = 10
    /// Room under the last row, so the list does not sit on the panel's edge.
    private static let bottomInset: CGFloat = 8
    /// A heading is nudged in this far per level below the first — plain
    /// leading spaces in the row's own string, so the bolding of matched
    /// characters (indices into the heading's own text) needs only an offset.
    private static let headingIndentUnit = "  "

    private enum Mode {
        case tabs
        case headings
        /// The bookmark button in the strip: every bookmark, nothing else.
        case bookmarks
    }

    /// One row of the list in `.tabs` and `.bookmarks`. ⌘P shows the open
    /// tabs and, under them, the bookmarks this window does not have open;
    /// the bookmark button shows the bookmarks alone.
    private enum Row {
        case tab(Int)
        /// An index into `bookmarkPaths`, which is whichever list the mode
        /// is showing.
        case bookmark(Int)
    }

    weak var delegate: TabPickerPanelDelegate?

    private let panel: NSPanel
    private let searchField = NSTextField()
    /// The fixed row above the field: a table one row deep, never scrolled.
    private let topRowTable = HoverTrackingTableView()
    private let topRowScrollView = NSScrollView()
    private let tableView = HoverTrackingTableView()
    private let scrollView = NSScrollView()
    private var titles: [String] = []
    /// One per title, in the same order — the file-kind symbol each tab's
    /// row draws (`FileKindIcon`).
    private var symbolNames: [String] = []
    /// In `.tabs`, the bookmarks this window does not already have open —
    /// the ones worth offering. In `.bookmarks`, all of them.
    private var bookmarkPaths: [String] = []
    /// The bookmarks whose file has gone: drawn greyed, and inert.
    private var missingBookmarks: Set<String> = []
    /// The list as it stands after the query, top to bottom.
    private var rows: [(row: Row, result: FuzzyMatch.Result)] = []

    private var mode: Mode = .tabs
    /// What the top row has to say about the tab in front, in `.bookmarks`:
    /// whether there is one to bookmark at all, and whether it already is.
    private var frontTab: (canBookmark: Bool, isBookmarked: Bool) = (false, false)
    /// Supplies the front tab's headings — `nil` immediately for a tab that
    /// is not `.md`, otherwise called once per `show()` and cached; a big
    /// note answers on a background queue, so the completion may land later.
    private var loadHeadings: ((@escaping ([MarkdownHeadings.Heading]) -> Void) -> Void)?
    private var headings: [MarkdownHeadings.Heading]?
    private var isLoadingHeadings = false
    private var headingsGeneration = 0
    private var rankedHeadings: [(index: Int, result: FuzzyMatch.Result)] = []

    var isVisible: Bool { panel.isVisible }

    /// The rows on screen right now, top to bottom — for the tests.
    var visibleRowTexts: [String] {
        switch mode {
        case .tabs, .bookmarks:
            return rows.map { text(of: $0.row) }
        case .headings:
            guard let headings else { return [] }
            return rankedHeadings.map { headings[$0.index].text }
        }
    }

    /// The SF Symbol each row on screen draws, top to bottom — for the tests.
    /// Headings show no icon, so that mode answers with nothing.
    var visibleRowSymbolNames: [String] {
        mode == .headings ? [] : rows.map { symbolName(of: $0.row) ?? "" }
    }

    /// Which rows are bookmarks rather than open tabs — for the tests.
    var visibleRowIsBookmark: [Bool] {
        mode == .headings ? [] : rows.map { if case .bookmark = $0.row { true } else { false } }
    }

    /// Which rows name a file that is no longer there — for the tests. Only
    /// a bookmark can be missing; an open tab is open.
    var visibleRowIsMissing: [Bool] {
        mode == .headings ? [] : rows.map(\.row).map(isMissing)
    }

    /// Whether `@` has switched the list to headings — for the tests.
    var isShowingHeadings: Bool { mode == .headings }

    /// Whether the panel is listing bookmarks alone — for the tests.
    var isShowingBookmarks: Bool { mode == .bookmarks }

    /// Whether the fixed row above the field holds the selection rather than
    /// any list row.
    private(set) var isTopRowSelected = false {
        didSet {
            guard isTopRowSelected != oldValue else { return }
            applyTopRowSelection()
        }
    }

    /// What the fixed row above the field reads right now — for the tests.
    var topRowText: String { topRowTitle }

    /// The symbol it draws — for the tests.
    var topRowSymbol: String { topRowSymbolName }

    /// Whether it can be chosen at all — for the tests. Only a bookmarks
    /// panel with no tab to bookmark has an inert one.
    var topRowIsEnabled: Bool { isTopRowEnabled }

    /// The top row's icon and title x in the panel window's coordinates —
    /// what the tests line it up against the list's rows with.
    var topRowContentXForTesting: (icon: CGFloat, title: CGFloat)? {
        contentX(in: topRowTable, row: 0)
    }

    /// The same two for the first row of the list.
    var firstListRowContentXForTesting: (icon: CGFloat, title: CGFloat)? {
        guard activeRowCount > 0 else { return nil }
        return contentX(in: tableView, row: 0)
    }

    /// What the fixed row above the field is actually drawing: nil when no
    /// row view was ever laid out for it — a blank strip. The frame is in
    /// the table's own coordinates, to be held against `topRowVisibleRect`.
    var topRowCellForTesting: (text: String, frame: NSRect)? {
        guard let cell = topRowTable.view(atColumn: 0, row: 0, makeIfNecessary: false)
            as? TabPickerRowView
        else { return nil }
        return (cell.textField?.stringValue ?? "", topRowTable.convert(cell.bounds, from: cell))
    }

    /// The slice of the top row's table the panel is showing — for the test
    /// that the row is inside it rather than scrolled past.
    var topRowVisibleRectForTesting: NSRect { topRowTable.visibleRect }

    /// The query as the field reads it — for the tests, which have no window
    /// server to type a keystroke into.
    var query: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            reload()
        }
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.text("Go to tab")
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        background.addSubview(searchField)

        // The fixed row is a table of its own rather than a hand-drawn view:
        // sharing the list's cell view and its table style is the only way
        // for the two to indent, highlight and read identically.
        configureRowTable(topRowTable)
        topRowTable.target = self
        topRowTable.action = #selector(topRowClicked)
        topRowTable.refusesFirstResponder = true
        topRowTable.onHover = { [weak self] _ in self?.hoverOverTopRow() }

        topRowScrollView.translatesAutoresizingMaskIntoConstraints = false
        topRowScrollView.documentView = topRowTable
        topRowScrollView.hasVerticalScroller = false
        topRowScrollView.hasHorizontalScroller = false
        topRowScrollView.verticalScrollElasticity = .none
        topRowScrollView.horizontalScrollElasticity = .none
        topRowScrollView.drawsBackground = false
        topRowScrollView.borderType = .noBorder
        background.addSubview(topRowScrollView)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(divider)

        configureRowTable(tableView)
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onHover = { [weak self] row in self?.hoverOverListRow(row) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            topRowScrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            topRowScrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topRowScrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            topRowScrollView.heightAnchor.constraint(equalToConstant: Self.rowHeight),

            searchField.topAnchor.constraint(equalTo: topRowScrollView.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.bottomInset),
        ])
    }

    /// Everything the two tables have to agree on for one row to be drawn
    /// the same in both of them.
    private func configureRowTable(_ table: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    // MARK: - Showing

    /// ⌘P. `bookmarks` is the bookmarks this window does not already have
    /// open — SPEC's "⌘P's switcher offers them under the open tabs".
    func show(
        titles: [String], symbolNames: [String] = [], selectedIndex: Int,
        bookmarks: [String] = [], missingBookmarks: Set<String> = [],
        loadHeadings: @escaping (@escaping ([MarkdownHeadings.Heading]) -> Void) -> Void,
        over window: NSWindow
    ) {
        self.titles = titles
        self.symbolNames = symbolNames
        self.bookmarkPaths = bookmarks
        self.missingBookmarks = missingBookmarks
        self.loadHeadings = loadHeadings
        headings = nil
        isLoadingHeadings = false
        headingsGeneration += 1
        frontTab = (canBookmark: false, isBookmarked: false)
        mode = .tabs
        searchField.placeholderString = L10n.text("Go to tab")
        searchField.stringValue = ""
        reload(preferring: selectedIndex)
        present(over: window)
    }

    /// The bookmark button in the strip: every bookmark, open or not, and no
    /// tabs at all.
    func showBookmarks(
        bookmarks: [String], missingBookmarks: Set<String> = [],
        frontTab: (canBookmark: Bool, isBookmarked: Bool), over window: NSWindow
    ) {
        titles = []
        symbolNames = []
        bookmarkPaths = bookmarks
        self.missingBookmarks = missingBookmarks
        self.frontTab = frontTab
        loadHeadings = nil
        headings = nil
        isLoadingHeadings = false
        headingsGeneration += 1
        mode = .bookmarks
        searchField.placeholderString = L10n.text("Go to bookmark")
        searchField.stringValue = ""
        reload()
        present(over: window)
    }

    private func present(over window: NSWindow) {
        // The list resolves `.automatic` to whichever style AppKit thinks it
        // should have; the fixed row above the field takes that same style
        // as its own, so the two indent and highlight alike.
        topRowTable.style = tableView.effectiveStyle
        topRowTable.reloadData()
        panel.setContentSize(NSSize(width: Self.panelWidth, height: panelHeight))
        if let frame = window.screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelWidth / 2,
                y: frame.midY - panelHeight / 2 + frame.height * 0.12
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        pinTopRowIntoView()
        primeHoverBaseline()
    }

    /// The bookmarks the panel is listing right now — the app's list minus
    /// whatever ⌘⌫ has taken out of it since the panel opened.
    var listedBookmarks: [String] { bookmarkPaths }

    func hide() {
        panel.orderOut(nil)
    }

    /// As if Return had been pressed on the row that is selected right now —
    /// for the tests, which have no window server to send a keystroke to.
    func chooseSelection() { commit() }

    /// As if ↓ had been pressed — for the tests, same reason.
    func moveSelectionDown() {
        if isTopRowSelected {
            guard activeRowCount > 0 else { return }
            isTopRowSelected = false
            selectListRow(0)
            return
        }
        moveListSelection(by: 1)
    }

    /// As if ↑ had been pressed. From the first row — or from the field with
    /// nothing selected, an empty list included — the fixed row above takes
    /// the selection, unless it is the inert one.
    func moveSelectionUp() {
        guard !isTopRowSelected else { return }
        if activeRowCount == 0 || tableView.selectedRow <= 0 {
            selectTopRow()
            return
        }
        moveListSelection(by: -1)
    }

    /// Takes the selection onto the fixed row above the field — what ↑ does
    /// once it reaches the top of the list, and what hovering that row with
    /// the mouse does too. A no-op over the inert row, the same as ↑.
    private func selectTopRow() {
        guard isTopRowEnabled else { return }
        tableView.deselectAll(nil)
        isTopRowSelected = true
    }

    /// Real pointer movement over a list row selects it — the same path
    /// ↓/↑ use, so Return then chooses whatever the pointer is resting on
    /// (Spotlight, VS Code's command palette). The empty-list message row,
    /// and any row `shouldSelectRow` rejects, take no hover.
    private func hoverOverListRow(_ row: Int) {
        guard row < activeRowCount, tableView(tableView, shouldSelectRow: row) else { return }
        isTopRowSelected = false
        selectListRow(row)
    }

    /// Real pointer movement over the fixed row above the field takes the
    /// selection there, exactly as ↑ from the top of the list does.
    private func hoverOverTopRow() {
        selectTopRow()
    }

    /// So the synthetic `mouseMoved` AppKit sends when the panel opens (or
    /// reloads) under a pointer that never left is not mistaken for the
    /// pointer having moved: both tables start out already knowing where it
    /// is, the same way a real `mouseMoved` at an unchanged point is a no-op.
    private func primeHoverBaseline() {
        let windowLocation = panel.mouseLocationOutsideOfEventStream
        tableView.primeHoverBaseline(windowLocation: windowLocation)
        topRowTable.primeHoverBaseline(windowLocation: windowLocation)
    }

    /// As if the pointer had moved onto row `row` of the list — for the
    /// tests, which have no window server to move a pointer through. Runs
    /// the exact dedup-and-select code a real `mouseMoved` runs, so calling
    /// this twice for the same row is the repeated-location no-op a real
    /// stationary `mouseMoved` would be.
    func simulateHover(atRow row: Int) {
        panel.layoutIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        let midpoint = NSPoint(x: tableView.bounds.midX, y: tableView.rect(ofRow: row).midY)
        tableView.handleMove(toWindowLocation: tableView.convert(midpoint, to: nil))
    }

    /// As if the pointer had moved onto the fixed row above the field — same
    /// reason as `simulateHover(atRow:)`.
    func simulateHoverOverTopRow() {
        panel.layoutIfNeeded()
        topRowTable.layoutSubtreeIfNeeded()
        let midpoint = NSPoint(x: topRowTable.bounds.midX, y: topRowTable.rect(ofRow: 0).midY)
        topRowTable.handleMove(toWindowLocation: topRowTable.convert(midpoint, to: nil))
    }

    /// The symbol for the tab at `index` in the titles handed to `show`.
    private func symbolName(at index: Int) -> String {
        symbolNames.indices.contains(index) ? symbolNames[index] : FileKindIcon.untitledSymbolName
    }

    /// What a row says. A bookmark is listed by its file name — the same
    /// thing a tab of it would be titled.
    private func text(of row: Row) -> String {
        switch row {
        case .tab(let index):
            return titles.indices.contains(index) ? titles[index] : ""
        case .bookmark(let index):
            return bookmarkPaths.indices.contains(index)
                ? Bookmarks.name(of: bookmarkPaths[index]) : ""
        }
    }

    private func path(of row: Row) -> String? {
        guard case .bookmark(let index) = row, bookmarkPaths.indices.contains(index) else {
            return nil
        }
        return bookmarkPaths[index]
    }

    /// A bookmark under the open tabs carries the `bookmark` symbol rather
    /// than its file kind, so the two halves of the ⌘P list read apart at a
    /// glance: these are the ones that are not open yet. In bookmarks mode
    /// there is nothing to tell them apart from, so the kind icon is back.
    private func symbolName(of row: Row) -> String? {
        switch row {
        case .tab(let index):
            return symbolName(at: index)
        case .bookmark:
            guard mode == .bookmarks else { return "bookmark" }
            return FileKindIcon.symbolName(forTitle: text(of: row))
        }
    }

    private func isMissing(_ row: Row) -> Bool {
        path(of: row).map(missingBookmarks.contains) ?? false
    }

    private var activeRowCount: Int {
        switch mode {
        case .tabs, .bookmarks: return rows.count
        case .headings: return rankedHeadings.count
        }
    }

    /// The list, plus the fixed row above the field, plus the inset under
    /// the last row.
    private var panelHeight: CGFloat {
        let rows = max(1, min(max(activeRowCount, 1), Self.maximumVisibleRows))
        return CGFloat(rows) * Self.rowHeight + Self.rowHeight + 52 + Self.bottomInset
    }

    private func reload(preferring selectedIndex: Int = -1) {
        let query = searchField.stringValue
        if mode == .bookmarks {
            reloadBookmarks(query: query)
        } else if query.hasPrefix("@") {
            mode = .headings
            reloadHeadings(query: String(query.dropFirst()))
        } else {
            mode = .tabs
            reloadTabs(query: query)
        }
        tableView.reloadData()
        topRowTable.reloadData()

        let row = mode == .tabs
            ? (rows.firstIndex {
                if case .tab(let index) = $0.row { return index == selectedIndex }
                return false
            } ?? 0)
            : 0
        isTopRowSelected = false
        applyTopRowSelection()
        pinTopRowIntoView()
        if activeRowCount > 0 {
            selectListRow(row)
        }
        panel.setContentSize(NSSize(width: Self.panelWidth, height: panelHeight))
        // The list just reshuffled under whatever the pointer was resting on;
        // that is not a move of its own, so hover starts fresh from here.
        primeHoverBaseline()
    }

    /// The open tabs, and under them the bookmarks that are not open. Both
    /// halves are ranked by the same fuzzy match and then merged by score,
    /// with an open tab taking any tie: what is already in front of you comes
    /// before what would have to be fetched off disk.
    private func reloadTabs(query: String) {
        let names = bookmarkPaths.map(Bookmarks.name(of:))
        let tabs = rank(query, in: titles)
        let bookmarks = rank(query, in: names)

        var merged: [(row: Row, result: FuzzyMatch.Result)] = []
        var left = 0
        var right = 0
        while left < tabs.count || right < bookmarks.count {
            let takeTab = right >= bookmarks.count
                || (left < tabs.count && tabs[left].result.score >= bookmarks[right].result.score)
            if takeTab {
                merged.append((row: .tab(tabs[left].index), result: tabs[left].result))
                left += 1
            } else {
                merged.append((row: .bookmark(bookmarks[right].index),
                               result: bookmarks[right].result))
                right += 1
            }
        }
        rows = merged
    }

    /// The bookmark button's list: every bookmark, and nothing else.
    private func reloadBookmarks(query: String) {
        rows = rank(query, in: bookmarkPaths.map(Bookmarks.name(of:)))
            .map { (row: Row.bookmark($0.index), result: $0.result) }
    }

    /// An empty query keeps the list in its own order rather than ranking it.
    private func rank(
        _ query: String, in names: [String]
    ) -> [(index: Int, result: FuzzyMatch.Result)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return names.indices.map {
                (index: $0, result: FuzzyMatch.Result(score: 0, matchedIndices: []))
            }
        }
        return FuzzyMatch.rank(query: query, titles: names)
    }

    /// The headings are asked for once, the first time `@` is typed, and kept
    /// for as long as the panel is showing them; every keystroke after that
    /// just re-filters what is already in hand.
    private func reloadHeadings(query: String) {
        guard let headings else {
            rankedHeadings = []
            guard !isLoadingHeadings else { return }
            isLoadingHeadings = true
            let generation = headingsGeneration
            loadHeadings? { [weak self] result in
                guard let self, generation == self.headingsGeneration else { return }
                self.headings = result
                self.isLoadingHeadings = false
                self.reload()
            }
            return
        }
        let stripped = query.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            rankedHeadings = headings.indices.map {
                (index: $0, result: FuzzyMatch.Result(score: 0, matchedIndices: []))
            }
        } else {
            rankedHeadings = FuzzyMatch.rank(query: stripped, titles: headings.map(\.text))
        }
    }

    private func moveListSelection(by delta: Int) {
        guard activeRowCount > 0 else { return }
        let current = max(0, tableView.selectedRow)
        selectListRow(max(0, min(activeRowCount - 1, current + delta)))
    }

    private func selectListRow(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func commit() {
        if isTopRowSelected {
            chooseTopRow()
            return
        }
        let row = tableView.selectedRow
        switch mode {
        case .tabs, .bookmarks:
            guard rows.indices.contains(row) else { return }
            switch rows[row].row {
            case .tab(let tabIndex):
                hide()
                delegate?.tabPicker(self, didChoose: tabIndex)
            case .bookmark:
                // A bookmark whose file has gone has nothing to open: the
                // row is greyed and Return on it does nothing at all, rather
                // than putting an alert up over the panel.
                guard !isMissing(rows[row].row), let path = path(of: rows[row].row) else { return }
                hide()
                delegate?.tabPicker(self, didChooseBookmark: path)
            }
        case .headings:
            guard rankedHeadings.indices.contains(row), let headings else { return }
            let heading = headings[rankedHeadings[row].index]
            hide()
            delegate?.tabPicker(self, didChooseHeading: heading)
        }
    }

    private var emptyListMessage: String {
        switch mode {
        case .tabs: return L10n.text("No tabs")
        case .headings: return L10n.text("No headings")
        case .bookmarks: return L10n.text("No bookmarks")
        }
    }

    @objc private func rowClicked() { commit() }

    /// ⌘⌫ — or ⌫ with nothing typed — on a bookmark row: it stops being a
    /// bookmark, missing or not, and the panel stays up on the rest of the
    /// list. Says whether it had a bookmark row to take.
    @discardableResult
    func removeSelectedBookmark() -> Bool {
        guard !isTopRowSelected, rows.indices.contains(tableView.selectedRow),
              let path = path(of: rows[tableView.selectedRow].row)
        else { return false }
        let row = tableView.selectedRow
        bookmarkPaths.removeAll { $0 == path }
        missingBookmarks.remove(path)
        delegate?.tabPicker(self, didRemoveBookmark: path)
        reload()
        // Stay where the list was, so a run of removals keeps working under
        // one finger rather than jumping back to the top each time.
        if activeRowCount > 0 { selectListRow(min(row, activeRowCount - 1)) }
        return true
    }

    /// Return, or a click, on the fixed row above the field. What it means
    /// is whatever the row says: a new tab, or the front tab's bookmark.
    private func chooseTopRow() {
        guard isTopRowEnabled else { return }
        hide()
        if mode == .bookmarks {
            delegate?.tabPickerDidRequestBookmarkCurrentTab(self)
        } else {
            delegate?.tabPickerDidRequestNewTab(self)
        }
    }

    @objc private func topRowClicked() {
        guard topRowTable.clickedRow == 0 else { return }
        chooseTopRow()
    }

    // MARK: - The fixed row

    /// In bookmarks mode the row is the front tab's bookmark toggle; in the
    /// other two it is the new-tab row it has always been.
    private var topRowTitle: String {
        guard mode == .bookmarks else { return L10n.text("Add new tab") }
        return L10n.text(
            frontTab.isBookmarked ? "Remove bookmark from this tab" : "Bookmark this tab"
        )
    }

    private var topRowSymbolName: String {
        guard mode == .bookmarks else { return "plus" }
        return frontTab.isBookmarked ? "bookmark.fill" : "bookmark"
    }

    /// With no tab to bookmark the row has nothing to do: it is drawn greyed
    /// and takes no selection, the way a missing bookmark's row is inert.
    private var isTopRowEnabled: Bool { mode == .bookmarks ? frontTab.canBookmark : true }

    /// The row is seen through a window exactly one row tall onto a table
    /// that is taller than it: the inset style pads its content above and
    /// below, so row 0 does not begin at the table's own top. The clip is
    /// pinned to the row's rect rather than left wherever the last resize
    /// put it — which was above the row entirely, drawing nothing at all.
    private func pinTopRowIntoView() {
        topRowTable.layoutSubtreeIfNeeded()
        let row = topRowTable.rect(ofRow: 0)
        guard row.height > 0 else { return }
        topRowScrollView.contentView.scroll(to: NSPoint(x: 0, y: row.minY))
        topRowScrollView.reflectScrolledClipView(topRowScrollView.contentView)
    }

    private func applyTopRowSelection() {
        if isTopRowSelected {
            topRowTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            topRowTable.deselectAll(nil)
        }
    }

    /// Where a row's icon and title stand, in the panel's coordinates —
    /// what the tests measure the two tables against each other with.
    private func contentX(in table: NSTableView, row: Int) -> (icon: CGFloat, title: CGFloat)? {
        panel.layoutIfNeeded()
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? TabPickerRowView
        else { return nil }
        cell.layoutSubtreeIfNeeded()
        return cell.contentXInWindow
    }
}

// MARK: - Field

extension TabPickerPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelectionDown()
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelectionUp()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        // ⌘⌫ takes a bookmark off the list wherever the caret is; plain ⌫
        // only means that once there is nothing left in the field to delete.
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            return removeSelectedBookmark()
        case #selector(NSResponder.deleteBackward(_:)):
            guard searchField.stringValue.isEmpty else { return false }
            return removeSelectedBookmark()
        default:
            return false
        }
    }
}

// MARK: - List

extension TabPickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === topRowTable { return 1 }
        return activeRowCount == 0 ? 1 : activeRowCount
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === topRowTable ? isTopRowEnabled : activeRowCount > 0
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TabPickerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TabPickerRowView
            ?? {
                let view = TabPickerRowView()
                view.identifier = identifier
                return view
            }()

        guard tableView !== topRowTable else {
            cell.configure(
                attributedRow(
                    topRowTitle, matched: [], indent: "", isDimmed: !isTopRowEnabled
                ),
                symbolName: topRowSymbolName,
                isDimmed: !isTopRowEnabled
            )
            return cell
        }

        guard activeRowCount > 0 else {
            cell.configure(
                NSAttributedString(
                    string: emptyListMessage,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ),
                symbolName: nil
            )
            return cell
        }

        switch mode {
        case .tabs, .bookmarks:
            guard rows.indices.contains(row) else { return cell }
            let entry = rows[row]
            cell.configure(
                attributedRow(
                    text(of: entry.row), matched: entry.result.matchedIndices, indent: "",
                    isDimmed: isMissing(entry.row)
                ),
                symbolName: symbolName(of: entry.row),
                isDimmed: isMissing(entry.row)
            )
        case .headings:
            guard let headings, rankedHeadings.indices.contains(row) else { return cell }
            let entry = rankedHeadings[row]
            let heading = headings[entry.index]
            let indent = String(
                repeating: Self.headingIndentUnit, count: max(0, heading.level - 1)
            )
            cell.configure(
                attributedRow(heading.text, matched: entry.result.matchedIndices, indent: indent),
                symbolName: nil
            )
        }
        return cell
    }

    /// `indent` is plain leading spaces in the row's own string, so the
    /// bolding below only has to shift the query's matched indices — which
    /// are into the row's *text*, indent aside — along by its length.
    private func attributedRow(
        _ text: String, matched: [Int], indent: String, isDimmed: Bool = false
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: indent + text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                // A bookmark whose file has gone is greyed rather than
                // dropped: it is still a bookmark, it just cannot be opened.
                .foregroundColor: isDimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]
        )
        for index in matched where index < text.count {
            attributed.addAttribute(
                .font, value: NSFont.boldSystemFont(ofSize: 13),
                range: NSRange(location: index + indent.count, length: 1)
            )
        }
        return attributed
    }
}

// MARK: - Hover

/// A table view that tells a genuine pointer movement over one of its rows
/// apart from a row moving out from under a pointer that never left —
/// the wheel scrolling the list, or the table reloading or resizing under a
/// still cursor. Only the former should move the selection, the way Spotlight
/// and VS Code's command palette follow the mouse.
///
/// The wheel does not raise `mouseMoved` at all, so scrolling under a still
/// pointer is already silent; what needs guarding against is AppKit's own
/// synthetic `mouseMoved`, sent at the pointer's *unchanged* location when a
/// window opens under it or a tracking area is rebuilt. `handleMove` compares
/// against the last location a move actually landed at and drops a repeat,
/// which is also what makes the panel's `primeHoverBaseline()` work: seeding
/// that "last location" with where the pointer already is turns the first
/// synthetic move into a no-op too.
private final class HoverTrackingTableView: NSTableView {
    /// Called with the row a genuine pointer movement landed on.
    var onHover: ((Int) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastMovedWindowLocation: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        handleMove(toWindowLocation: event.locationInWindow)
    }

    /// Seeds the "last real move" location without treating it as a move —
    /// called when the panel opens or reloads, so the synthetic `mouseMoved`
    /// AppKit may send right after (reporting that same, unchanged point) is
    /// filtered out by `handleMove` exactly as a real repeat would be.
    func primeHoverBaseline(windowLocation: NSPoint) {
        lastMovedWindowLocation = windowLocation
    }

    /// The dedup-and-dispatch a real `mouseMoved` runs, in window
    /// coordinates — shared with the tests, which have no window server to
    /// move a pointer through.
    func handleMove(toWindowLocation location: NSPoint) {
        guard lastMovedWindowLocation != location else { return }
        lastMovedWindowLocation = location
        let row = row(at: convert(location, from: nil))
        guard row >= 0 else { return }
        onHover?(row)
    }
}

// MARK: - Rows

/// A list row: the file-kind icon, then the title. A heading row passes no
/// symbol and keeps the bare indent it always had, so the outline still reads
/// as an outline rather than a second list of files.
private final class TabPickerRowView: NSTableCellView {
    static let iconSize: CGFloat = 16
    static let leadingMargin: CGFloat = 14
    static let iconTitleGap: CGFloat = 6

    private let icon = NSImageView()
    /// The title sits after the icon, or at the margin when there is none;
    /// only one of the two is ever on.
    private var titleAfterIcon: NSLayoutConstraint!
    private var titleAtMargin: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
        textField = field

        titleAfterIcon = field.leadingAnchor.constraint(
            equalTo: icon.trailingAnchor, constant: Self.iconTitleGap
        )
        titleAtMargin = field.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.leadingMargin
        )
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingMargin),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),

            titleAfterIcon,
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The icon's and the title's x in window coordinates — what the tests
    /// line the fixed row above the field up against the list with.
    var contentXInWindow: (icon: CGFloat, title: CGFloat)? {
        guard let textField, window != nil else { return nil }
        return (convert(icon.frame, to: nil).minX, convert(textField.frame, to: nil).minX)
    }

    func configure(_ text: NSAttributedString, symbolName: String?, isDimmed: Bool = false) {
        textField?.attributedStringValue = text
        icon.contentTintColor = isDimmed ? .tertiaryLabelColor : .secondaryLabelColor
        if let symbolName {
            icon.image = FileKindIcon.image(named: symbolName, pointSize: Self.iconSize)
            icon.isHidden = false
            titleAtMargin.isActive = false
            titleAfterIcon.isActive = true
        } else {
            icon.image = nil
            icon.isHidden = true
            titleAfterIcon.isActive = false
            titleAtMargin.isActive = true
        }
    }
}
