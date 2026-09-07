import AppKit

/// The grid a dump is read in: a plain table with a spreadsheet's cursor over
/// it.
///
/// A database browser is not a list of rows, it is a sheet of cells, and a
/// reader reaching for one value wants that value and not the four hundred
/// characters of the row it sits in. So a click picks out one cell, a drag
/// picks out a rectangle of them, and ⌘C takes exactly what is drawn — tab
/// separated, a line per row, the shape a spreadsheet pastes.
///
/// Whole rows are still there for the times a row is what is wanted: a click
/// in the `#` gutter takes one, and ⇧ anywhere takes the range. The two never
/// stand at once — picking either puts the other down — because a wash under
/// a wash says nothing about what ⌘C would copy.
///
/// What is *in* the grid, how wide its columns are and what a header click
/// means all belong to `SQLPreviewView`, which is the only thing that knows
/// what a page is.
final class SQLGridView: NSTableView {
    static let rowNumberColumn = NSUserInterfaceItemIdentifier("sql-row-number")

    /// What is picked out. `cells` is in grid columns, where column 0 is the
    /// `#` gutter and is never part of one.
    enum Selection: Equatable {
        case none
        case rows(IndexSet)
        case cells(rows: ClosedRange<Int>, columns: ClosedRange<Int>)
    }

    /// The selection as text, from whoever is holding the page.
    var copyText: ((Selection) -> String)?

    /// The pane's ⌘F over this grid. Two jobs in one reference: the cells ask
    /// it which of them wear a find band, and the Find menu's nil-targeted
    /// `performTextFinderAction:` items land here whenever the grid has the
    /// keyboard and are handed on to it.
    weak var findSession: GridFindSession?

    /// A cell picked out with the mouse, in grid coordinates. Whoever holds
    /// the page answers it — here it is only a click; what a row *means* is
    /// the pane's business, which is the only thing that knows the rowid
    /// under it and the file it came out of.
    var onCellClick: ((_ row: Int, _ column: Int) -> Void)?

    /// Everything *else* the reader does that means "show me this": a click in
    /// the `#` gutter, a ⇧-click, a drag growing the rectangle or the run of
    /// rows, Space standing a row up, a ⇧-arrow. `onCellClick` above already
    /// says the plain click on one cell, so the two never both fire for the
    /// same gesture — and a drag says it again on every mouse event that
    /// actually moves an edge, which is the coalescing.
    ///
    /// What a selection *means* is the pane's business: this hands over the
    /// shape and nothing else.
    var onSelectionReveal: ((Selection) -> Void)?

    /// Whether the pane this grid is in owns the keyboard, which is reading
    /// mode. A click puts the first responder here in split too, and that must
    /// not take ⌘F off the editor beside it — so the Find menu is answered by
    /// this rather than by where the first responder happens to be.
    var takesKeyboard = false

    /// Where the rectangle was started from, and where its moving end is. The
    /// two are the same cell for a selection of one, which is what a click
    /// makes.
    private(set) var cellAnchor: (row: Int, column: Int)?
    private(set) var cellCursor: (row: Int, column: Int)?
    private(set) var cellSelection: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)?
    /// Where a run of whole rows was started from, so ⇧ and a drag both know
    /// which end of it is not moving.
    private var rowAnchor: Int?
    /// The cell Space stood up from, so Space again can sit back down on it.
    private var cellBeforeRowSelection: (row: Int, column: Int)?

    /// What ⌘C would take.
    var selection: Selection {
        if let cellSelection {
            return .cells(rows: cellSelection.rows, columns: cellSelection.columns)
        }
        return selectedRowIndexes.isEmpty ? .none : .rows(selectedRowIndexes)
    }

    /// One range over the lot, the way a selection over three paragraphs of
    /// text is one range: from the earliest start to the latest end, whatever
    /// lies between them included. `nil` for nothing to span.
    static func span(of ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.first else { return nil }
        var start = first.location
        var end = NSMaxRange(first)
        for range in ranges.dropFirst() {
            start = min(start, range.location)
            end = max(end, NSMaxRange(range))
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Keeping the cursor honest

    /// Called wherever the coordinates stop meaning what they meant — a new
    /// page, a sort, a different set of columns. A (row, column) held across
    /// one of those would quietly point at somebody else's value.
    func clearCellSelection() {
        // Whatever Space could have sat back down on goes with it: a page or a
        // sort has moved every cell out from under the coordinates.
        cellBeforeRowSelection = nil
        guard cellAnchor != nil || cellSelection != nil || cellCursor != nil else { return }
        cellAnchor = nil
        cellSelection = nil
        cellCursor = nil
        updateCellRendering()
    }

    /// Moves the cursor, collapsing the rectangle onto it — or grows the
    /// rectangle from the anchor, when the reader is holding ⇧.
    func setCursor(row: Int, column: Int, extend: Bool = false) {
        guard numberOfRows > 0, tableColumns.count > 1 else { return }
        let target = (
            row: min(max(row, 0), numberOfRows - 1),
            column: min(max(column, 1), tableColumns.count - 1)
        )
        if extend, let anchor = cellAnchor {
            cellSelection = SQLGridView.rectangle(from: anchor, to: target)
        } else {
            cellAnchor = target
            cellSelection = (rows: target.row...target.row,
                             columns: target.column...target.column)
        }
        cellCursor = target
        // A cell selection and a row selection would be two answers to the
        // same question.
        if !selectedRowIndexes.isEmpty { deselectAll(nil) }
        updateCellRendering()
        scrollRowToVisible(target.row)
        scrollColumnToVisible(target.column)
    }

    private static func rectangle(
        from start: (row: Int, column: Int), to end: (row: Int, column: Int)
    ) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        (rows: min(start.row, end.row)...max(start.row, end.row),
         columns: min(start.column, end.column)...max(start.column, end.column))
    }

    /// How one cell of the grid is drawn, given what is picked out and what
    /// ⌘F has found. The rectangle's outer edges carry the hairline; the
    /// cursor carries a border of its own, so a selection of many still says
    /// which one the arrows will move from.
    ///
    /// The find band goes under all of it: a cell can be a match *and* be
    /// picked out — the current match is the cell cursor — and the accent over
    /// the band is what says so.
    func highlight(row: Int, column: Int) -> SQLCellView.Highlight {
        var band = selectionHighlight(row: row, column: column)
        // The gutter is not a value and never a match; `column - 1` is the
        // data column the session counts in.
        if column > 0, let findSession {
            switch findSession.band(pageRow: row, dataColumn: column - 1) {
            case .none: break
            case .match: band.isMatch = true
            case .current: band.isCurrentMatch = true
            }
        }
        return band
    }

    private func selectionHighlight(row: Int, column: Int) -> SQLCellView.Highlight {
        guard let selection = cellSelection else {
            guard column == 0, selectedRowIndexes.contains(row) else { return .none }
            return SQLCellView.Highlight(isGutter: true, isSelected: true)
        }
        if column == 0 {
            return SQLCellView.Highlight(
                isGutter: true, isSelected: selection.rows.contains(row)
            )
        }
        guard selection.rows.contains(row), selection.columns.contains(column) else {
            return .none
        }
        return SQLCellView.Highlight(
            isSelected: true,
            isCursor: cellCursor.map { $0.row == row && $0.column == column } ?? false,
            top: row == selection.rows.lowerBound,
            leading: column == selection.columns.lowerBound,
            bottom: row == selection.rows.upperBound,
            trailing: column == selection.columns.upperBound
        )
    }

    /// Every cell on screen re-asked. Cells that scroll in afterwards are the
    /// data source's business, which asks the same question.
    func updateCellRendering() {
        enumerateAvailableRowViews { rowView, row in
            for column in 0..<self.tableColumns.count {
                guard let cell = rowView.view(atColumn: column) as? SQLCellView else { continue }
                cell.highlight = self.highlight(row: row, column: column)
            }
        }
    }

    override func reloadData() {
        super.reloadData()
        updateCellRendering()
    }

    // MARK: - The mouse

    /// One click, one cell. A click in the `#` gutter, and any click with ⇧
    /// held, is about rows instead.
    ///
    /// Neither goes to `super`. The table's own mouse handling runs a
    /// tracking loop of its own until the button comes up, and a page landing
    /// inside one of those is what a sort used to do to the header. Doing
    /// both selections here keeps every mouse event ordinary, which is also
    /// the only way a test can drive one.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        guard event.clickCount == 1, row >= 0 else {
            clearCellSelection()
            super.mouseDown(with: event)
            return
        }
        // A click is where the keyboard goes: ⌘C has to arrive here rather
        // than at whatever the reader was typing in before it.
        window?.makeFirstResponder(self)
        guard !event.modifierFlags.contains(.shift), column > 0 else {
            selectRows(to: row, extend: event.modifierFlags.contains(.shift))
            // A run of whole rows is a reader pointing at rows, and the editor
            // beside the grid goes to them the way it goes to a clicked value.
            onSelectionReveal?(selection)
            return
        }
        setCursor(row: row, column: column)
        // A plain click on a value, which is the one thing that means "show me
        // where this came from". A ⇧-click is a selection being grown and a
        // gutter click is a whole row, and neither is a reader pointing at a
        // value; a drag begins with a press like this one and so says it once,
        // at the cell it started from.
        onCellClick?(row, column)
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = min(max(self.row(at: point), 0), max(0, numberOfRows - 1))
        if let anchor = cellAnchor {
            let column = min(max(self.column(at: point), 1), max(1, tableColumns.count - 1))
            let grown = SQLGridView.rectangle(from: anchor, to: (row, column))
            // Only when an edge actually moved. A drag is a great many events
            // over the same cell, and the editor is not told the same thing
            // forty times.
            let moved = cellSelection?.rows != grown.rows
                || cellSelection?.columns != grown.columns
            cellSelection = grown
            cellCursor = (row, column)
            updateCellRendering()
            if moved { onSelectionReveal?(selection) }
            return
        }
        guard rowAnchor != nil else { return super.mouseDragged(with: event) }
        let before = selectedRowIndexes
        selectRows(to: row, extend: true)
        if selectedRowIndexes != before { onSelectionReveal?(selection) }
    }

    /// A run of whole rows, from wherever the run was started to here. The
    /// rectangle goes: one wash under another says nothing about what ⌘C
    /// would take.
    private func selectRows(to row: Int, extend: Bool) {
        guard row >= 0, row < numberOfRows else { return }
        clearCellSelection()
        let anchor = extend ? (rowAnchor ?? selectedRowIndexes.first ?? row) : row
        rowAnchor = anchor
        selectRowIndexes(IndexSet(integersIn: min(anchor, row)...max(anchor, row)),
                         byExtendingSelection: false)
    }

    // MARK: - The keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {  // Esc
            if cellSelection != nil {
                clearCellSelection()
                return
            }
            if !selectedRowIndexes.isEmpty {
                deselectAll(nil)
                updateCellRendering()
                return
            }
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return
        }
        if event.keyCode == 49 {  // Space
            toggleRowSelection()
            return
        }
        switch event.keyCode {
        case 123, 124, 125, 126:  // ← → ↓ ↑
            // ⌃ and ⌘ mean nothing over a grid; swallowed rather than passed
            // up the chain to be beeped at.
            guard !flags.contains(.control), !flags.contains(.command) else { return }
            moveCursor(keyCode: event.keyCode, extend: flags.contains(.shift))
            return
        default:
            super.keyDown(with: event)
        }
    }

    /// Space stands the cursor up into the whole row it is in — the same
    /// selection a click in the `#` gutter makes — and Space again sits it
    /// back down on the cell it came from. One key for both, because they are
    /// the same thought said twice: *this row*, then *this value again*.
    ///
    /// It never reaches anything else. A table's own Space scrolls the page,
    /// which over a grid being read a cell at a time is nothing anyone asked
    /// for, and the editor beside it would take a space as typing.
    private func toggleRowSelection() {
        if let cursor = cellCursor {
            // `selectRows` puts the rectangle down, and the cell to come back
            // to is written after it rather than before.
            selectRows(to: cursor.row, extend: false)
            cellBeforeRowSelection = cursor
            onSelectionReveal?(selection)
            return
        }
        guard let cell = cellBeforeRowSelection, !selectedRowIndexes.isEmpty else { return }
        setCursor(row: cell.row, column: cell.column)
        onSelectionReveal?(selection)
    }

    /// The arrows drive the cell cursor rather than the row selection. The
    /// first press with nothing picked out puts the cursor on the first cell,
    /// which is where a reader coming in from the keyboard expects to land.
    private func moveCursor(keyCode: UInt16, extend: Bool) {
        guard numberOfRows > 0, tableColumns.count > 1 else { return }
        let lastRow = numberOfRows - 1
        let lastColumn = tableColumns.count - 1
        guard var target = cellCursor ?? cellSelection.map({ ($0.rows.lowerBound,
                                                             $0.columns.lowerBound) })
            ?? selectedRowIndexes.first.map({ ($0, 1) })
        else {
            setCursor(row: 0, column: 1)
            return
        }
        switch keyCode {
        case 126: target.row = max(0, target.row - 1)               // ↑
        case 125: target.row = min(lastRow, target.row + 1)         // ↓
        case 123: target.column = max(1, target.column - 1)         // ←
        case 124: target.column = min(lastColumn, target.column + 1) // →
        default: break
        }
        let grows = extend && cellAnchor != nil
        setCursor(row: target.row, column: target.column, extend: grows)
        // A ⇧-arrow is the rectangle being grown, which is the same gesture as
        // a drag and says the same thing. A plain arrow only walks the cursor
        // and has never moved the caret beside it.
        if grows { onSelectionReveal?(selection) }
    }

    /// Where ⌘C writes: the Mac's clipboard, unless a test lends the grid a
    /// private board — a suite that copied two customers' names onto the
    /// real clipboard every run did exactly that, for weeks.
    var pasteboard: NSPasteboard = .general

    @objc func copy(_ sender: Any?) {
        let text = copyText?(selection) ?? ""
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - The Find menu

    /// Find…, Find Next, Find Previous and Use Selection for Find are
    /// nil-targeted `performTextFinderAction:` items, so they land here
    /// whenever this grid is the first responder — and a click puts it there
    /// in split as well as in reading. `takesKeyboard` is what decides, not
    /// where the first responder is: in split the editor beside the grid owns
    /// ⌘F, so the action is handed straight back up the chain, where the
    /// window gives it to the editor's own session.
    ///
    /// Taking the selector at all is what makes the pass-up necessary: a view
    /// that implements it *is* the target, and doing nothing here would grey
    /// ⌘F out over a whole mode.
    override func performTextFinderAction(_ sender: Any?) {
        guard takesKeyboard, findSession != nil else {
            nextResponder?.tryToPerform(#selector(performTextFinderAction(_:)), with: sender)
            return
        }
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession?.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != .none }
        if item.action == #selector(performTextFinderAction(_:)) {
            guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
            // In split the item stays enabled for the editor's sake — it is
            // the editor's ⌘F that the key is about to run.
            guard takesKeyboard, findSession != nil else {
                return TextFindSession.handles(action)
            }
            return GridFindSession.handles(action)
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Row selection made by the table itself — a `#` click, a ⇧ drag — has
    /// to reach the gutter's wash too.
    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        updateCellRendering()
    }

    override func deselectAll(_ sender: Any?) {
        super.deselectAll(sender)
        updateCellRendering()
    }
}

// MARK: - One cell

/// A cell of the grid, and the wash and hairlines that say it is picked out.
///
/// The wash is the accent at low strength rather than the system's own
/// selection fill: a selection here is a rectangle of cells and not a run of
/// rows, and it has to read as one shape with an edge round it. The edge is
/// drawn only where the rectangle actually ends, so a block of forty cells is
/// one outlined block and not forty outlined cells.
final class SQLCellView: NSTableCellView {

    struct Highlight: Equatable {
        var isGutter = false
        var isSelected = false
        var isCursor = false
        var top = false
        var leading = false
        var bottom = false
        var trailing = false
        /// The cell holds ⌘F's query. Quiet, the way the editor's other
        /// matches are.
        var isMatch = false
        /// And the one of them the reader is standing on, which is also the
        /// cell cursor.
        var isCurrentMatch = false

        static let none = Highlight()
    }

    var highlight: Highlight = .none {
        didSet {
            guard highlight != oldValue else { return }
            applyText()
            needsDisplay = true
        }
    }

    /// What the cell says. Held here rather than pushed straight at the text
    /// field, because the current find match has to be re-coloured every time
    /// ⌘G moves — and ⌘G moves the band without the table reloading a row.
    var text: NSAttributedString? {
        didSet { applyText() }
    }

    /// `findHighlightColor` is AppKit's own find yellow, and it is the same
    /// light colour in both appearances — so the text on it is spelled out
    /// black rather than left as `labelColor`, which turns white in dark mode
    /// and disappears into the band. The same swap the editor's bands make.
    private func applyText() {
        guard let textField, let text else { return }
        guard highlight.isCurrentMatch else {
            textField.attributedStringValue = text
            return
        }
        let onYellow = NSMutableAttributedString(attributedString: text)
        onYellow.addAttribute(.foregroundColor, value: NSColor.black,
                              range: NSRange(location: 0, length: onYellow.length))
        textField.attributedStringValue = onYellow
    }

    private enum Wash {
        static let cells: CGFloat = 0.18
        static let gutter: CGFloat = 0.10
        static let edge: CGFloat = 1
        static let cursor: CGFloat = 1.5
        /// The same alpha the editor's quiet band is laid on at.
        static let findBand: CGFloat = 0.12
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlight.isSelected || highlight.isCursor
            || highlight.isMatch || highlight.isCurrentMatch else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The find band goes down first, under the selection wash: the
            // current match is the cell cursor, so the two are on the same
            // cell whenever ⌘F has landed.
            if highlight.isCurrentMatch {
                NSColor.findHighlightColor.setFill()
                bounds.fill()
            } else if highlight.isMatch {
                NSTextView.quietFindBand(alpha: Wash.findBand).setFill()
                bounds.fill()
            }
            guard highlight.isSelected || highlight.isCursor else { return }
            let accent = NSColor.controlAccentColor
            if highlight.isSelected {
                accent.withAlphaComponent(highlight.isGutter ? Wash.gutter : Wash.cells).setFill()
                bounds.fill()
            }
            guard !highlight.isGutter else { return }
            accent.setFill()
            let edge = Wash.edge
            let top = isFlipped
                ? NSRect(x: 0, y: 0, width: bounds.width, height: edge)
                : NSRect(x: 0, y: bounds.maxY - edge, width: bounds.width, height: edge)
            let bottom = isFlipped
                ? NSRect(x: 0, y: bounds.maxY - edge, width: bounds.width, height: edge)
                : NSRect(x: 0, y: 0, width: bounds.width, height: edge)
            if highlight.top { top.fill() }
            if highlight.bottom { bottom.fill() }
            if highlight.leading {
                NSRect(x: 0, y: 0, width: edge, height: bounds.height).fill()
            }
            if highlight.trailing {
                NSRect(x: bounds.maxX - edge, y: 0, width: edge, height: bounds.height).fill()
            }
            guard highlight.isCursor else { return }
            let border = NSBezierPath(rect: bounds.insetBy(dx: Wash.cursor / 2,
                                                           dy: Wash.cursor / 2))
            border.lineWidth = Wash.cursor
            accent.setStroke()
            border.stroke()
        }
    }
}

// MARK: - The header

/// The grid's header row. Stock `NSTableHeaderView` leaves the strip past the
/// last column undrawn, which shows as the header stopping short of the
/// scroll view's trailing edge; this fills the row first and lets the cells
/// draw on top.
final class SQLHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.separatorColor.setFill()
            let y = isFlipped ? bounds.maxY - 1 : bounds.minY
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
    }
}

/// One column's header. Flat rather than the system's gradient bezel, which
/// is built for a light window and shows as a pale band in a dark one, and
/// with its own chevron for the sort: the system's grey triangle is small
/// enough to be missed, and the sorted column is the one thing about a grid
/// a reader looks for first.
final class SQLHeaderCell: NSTableHeaderCell {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// What the title has to leave free at the trailing edge for a chevron.
    static let indicatorRoom: CGFloat = 16

    /// Which way the chevron points, or nothing at all for a column that is
    /// not the one being sorted by.
    var sortAscending: Bool?

    private enum Metrics {
        static let inset: CGFloat = 8
        static let chevron = NSSize(width: 7, height: 4)
    }

    /// No `super`: the stock header cell lays a bezel gradient down before
    /// anything of ours lands, and it leaks out round the edges of the fill.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            cellFrame.fill()

            let sorted = sortAscending != nil
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: sorted ? NSFont.systemFont(ofSize: 11, weight: .semibold)
                    : SQLHeaderCell.font,
                .foregroundColor: sorted ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let title = stringValue
            let size = title.size(withAttributes: attributes)
            var text = cellFrame.insetBy(dx: Metrics.inset, dy: 0)
            if sorted { text.size.width = max(0, text.width - SQLHeaderCell.indicatorRoom) }
            text.origin.y = cellFrame.minY + ((cellFrame.height - size.height) / 2).rounded()
            text.size.height = size.height
            title.draw(in: text, withAttributes: attributes)

            guard let ascending = sortAscending else { return }
            drawChevron(ascending: ascending, in: cellFrame, flipped: controlView.isFlipped)
        }
    }

    /// A small filled chevron in the accent, pointing the way the rows run.
    private func drawChevron(ascending: Bool, in cellFrame: NSRect, flipped: Bool) {
        let size = Metrics.chevron
        let x = cellFrame.maxX - Metrics.inset - size.width
        let y = cellFrame.minY + ((cellFrame.height - size.height) / 2).rounded()
        // Up for ascending on screen: in a flipped header that is the point
        // at the smaller y.
        let pointsUp = ascending == flipped
        let path = NSBezierPath()
        if pointsUp {
            path.move(to: NSPoint(x: x, y: y + size.height))
            path.line(to: NSPoint(x: x + size.width, y: y + size.height))
            path.line(to: NSPoint(x: x + size.width / 2, y: y))
        } else {
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + size.width, y: y))
            path.line(to: NSPoint(x: x + size.width / 2, y: y + size.height))
        }
        path.close()
        NSColor.controlAccentColor.setFill()
        path.fill()
    }
}
