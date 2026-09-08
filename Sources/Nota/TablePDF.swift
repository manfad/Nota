import AppKit
import PDFKit

/// A table onto pages: the header, the rows, and a rule around every cell.
///
/// What a `.sql` or `.csv` tab's `Preview as PDF` is made of — SPEC "## Export",
/// "Preview as PDF of a grid". Nothing here knows about notes, tabs or panes:
/// it is handed a header, rows of optional strings and the font the grid draws
/// its cells in, and it leaves a PDF behind. Which rows those are — the query
/// in the box, the column a header click sorted by — was decided by the pane
/// long before this file sees them.
///
/// The pages are `PDFPaginator`'s: the same silent `NSPrintOperation` the
/// plates go through (`jobDisposition = .save`, the file in `jobSavingURL`, no
/// panels), the same paper out of `NSPrintInfo.shared`, the same margins, and
/// the same run under the light appearance — a page is paper, so the ink is
/// black whatever the window is in. A grid cannot flow the way a paragraph
/// does, so the view here paginates itself with `knowsPageRange`, exactly as
/// `PDFPaginator.PlatesView` does.
///
/// Three things are decided before a page is drawn, and all three are about
/// the same thing — a table is only readable while its narrow columns are left
/// alone:
///
/// - **The size.** A printed table is not the screen. The grid's own font
///   family and weight are kept, but the size is capped at
///   `maximumFontSize`: thirteen point monospaced is what made six columns
///   not fit across a page.
/// - **The paper.** Columns that want more than a portrait page turn the
///   paper on its side rather than being squeezed into it.
/// - **The columns.** What does not fit is taken off the *widest* columns
///   only, down to one shared threshold, so an `id` or a `balance` keeps the
///   width it asked for and a long note is the one that wraps. Everything
///   gives up an equal share only when nothing else can work.
enum TablePDF {

    // MARK: - The cell

    /// The air between a cell's rule and its text.
    private static let horizontalPadding: CGFloat = 5
    private static let verticalPadding: CGFloat = 3

    /// The largest a cell is set on paper, whatever the grid is showing on
    /// screen. The reader's own font family and weight are kept — this is
    /// about fitting the columns across a page, not about restyling them.
    private static let maximumFontSize: CGFloat = 10

    /// The rule around every cell, and the two washes a page is drawn with.
    /// Fixed sRGB rather than dynamic colours: this runs under the light
    /// appearance and lands on white paper, so there is nothing for a dark
    /// window to resolve.
    private static let ruleWidth: CGFloat = 0.5
    private static let ruleColour = NSColor(white: 0.72, alpha: 1)
    private static let headerFill = NSColor(white: 0.92, alpha: 1)
    private static let inkColour = NSColor.black

    // MARK: - Writing

    /// The table into a PDF at `url`.
    ///
    /// `header` is what the columns are called, and every row is read against
    /// it: a `nil` cell — a SQL `NULL`, or a ragged CSV row's own field it
    /// never wrote that far into — draws as nothing at all rather than as a
    /// word. A table with no columns is `nothingToDraw`; a table with columns
    /// and no rows is one page with the header on it.
    ///
    /// Synchronous: the file is there, with at least one page in it, by the
    /// time this returns.
    static func write(
        header: [String], rows: [[String?]], font: NSFont, to url: URL
    ) throws {
        guard !header.isEmpty else { throw PDFPaginator.Failure.nothingToDraw }
        try? FileManager.default.removeItem(at: url)

        try PDFPaginator.light {
            // The print info is a copy of the shared one, so turning this
            // job's paper on its side is this job's business alone and the
            // next listing still exports portrait.
            let info = PDFPaginator.printInfo(savingTo: url)
            let measure = Measure(header: header, rows: rows, font: font)

            // Wider than a portrait page: turn the paper rather than squeeze
            // the columns onto it. The measure is taken once and read against
            // either paper, so nothing is measured twice to answer this.
            var size = contentSize(of: info)
            if measure.total(cappedTo: size.width / 2) > size.width {
                info.orientation = .landscape
                size = contentSize(of: info)
            }

            let view = TableView(layout: Layout(measure: measure, pageSize: size))
            try PDFPaginator.run(NSPrintOperation(view: view, printInfo: info))
        }

        // The same check `PDFPaginator.join` makes: a job that ran and left
        // nothing readable is a failure, not a file nobody can open.
        guard (PDFDocument(url: url)?.pageCount ?? 0) > 0 else {
            throw PDFPaginator.Failure.noPages
        }
    }

    /// What one page has room for, inside the margins, on the paper this job
    /// is set to.
    private static func contentSize(of info: NSPrintInfo) -> NSSize {
        NSSize(
            width: info.paperSize.width - info.leftMargin - info.rightMargin,
            height: info.paperSize.height - info.topMargin - info.bottomMargin
        )
    }

    // MARK: - The measure

    /// Every cell sized on a single line, once, before any page is chosen.
    ///
    /// Kept apart from `Layout` because it is the expensive half and it does
    /// not depend on the paper: the same measure answers "does this fit a
    /// portrait page?" and then lays the table out on whichever paper won.
    private struct Measure {
        let header: [String]
        let rows: [[String?]]
        /// The grid's font at the size a page is set in, and the header's.
        let font: NSFont
        let headerFont: NSFont
        /// The widest cell of each column on one line, padding included and
        /// nothing capped — what the column would like to be.
        let natural: [CGFloat]
        /// Each header's own single-line width, in the same order.
        let headerWidths: [CGFloat]
        /// Every cell's own single-line width. A cell no wider than the room
        /// inside its column cannot wrap, so it is one line tall and is never
        /// laid out again.
        let cellWidths: [[CGFloat]]
        /// The least a column can be given and still hold anything: one
        /// character of the font, and the air either side of it.
        let minimumColumnWidth: CGFloat

        init(header: [String], rows: [[String?]], font: NSFont) {
            let font = TablePDF.capped(font)
            let headerFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            let padding = TablePDF.horizontalPadding * 2

            let headerWidths = header.map { TablePDF.measure($0, font: headerFont) }
            var natural = headerWidths.map { $0 + padding }
            var cellWidths: [[CGFloat]] = []
            cellWidths.reserveCapacity(rows.count)
            for row in rows {
                var measured = [CGFloat](repeating: 0, count: row.count)
                for (index, value) in row.enumerated() where index < natural.count {
                    guard let value, !value.isEmpty else { continue }
                    let width = TablePDF.measure(value, font: font)
                    measured[index] = width
                    natural[index] = max(natural[index], width + padding)
                }
                cellWidths.append(measured)
            }

            self.header = header
            self.rows = rows
            self.font = font
            self.headerFont = headerFont
            self.natural = natural
            self.headerWidths = headerWidths
            self.cellWidths = cellWidths
            minimumColumnWidth = TablePDF.measure("0", font: font) + padding
        }

        /// What the columns want, with no column allowed more than `cap` —
        /// half the page, so one long note in one row cannot squeeze every
        /// other column to nothing.
        func natural(cappedTo cap: CGFloat) -> [CGFloat] {
            natural.map { min(cap, $0) }
        }

        func total(cappedTo cap: CGFloat) -> CGFloat {
            natural(cappedTo: cap).reduce(0, +)
        }
    }

    /// Where the table lands on this paper: how wide each column is, how tall
    /// each row is, and which rows are on which page.
    private struct Layout {
        let header: [String]
        let rows: [[String?]]
        let font: NSFont
        let headerFont: NSFont
        /// One per column, in the header's order, summing to at most the
        /// page's content width.
        let widths: [CGFloat]
        let headerHeight: CGFloat
        /// The drawn height of each row — the tallest cell on it, and never
        /// taller than one page has room for.
        let rowHeights: [CGFloat]
        /// The rows on each page, in order. Always at least one page, so a
        /// header with no rows under it still prints.
        let pages: [Range<Int>]
        let pageSize: NSSize

        init(measure: Measure, pageSize: NSSize) {
            let widths = TablePDF.fitted(
                measure.natural(cappedTo: pageSize.width / 2),
                into: pageSize.width,
                minimum: measure.minimumColumnWidth
            )

            let headerHeight = min(
                pageSize.height,
                TablePDF.height(
                    of: measure.header, onOneLine: measure.headerWidths,
                    widths: widths, font: measure.headerFont
                )
            )
            // What is left under the header, which repeats on every page. The
            // floor of 1 keeps a pathological page — a header taller than the
            // paper — from asking for an infinite number of them.
            let available = max(1, pageSize.height - headerHeight)
            // A row taller than a whole page is clipped to one: there is
            // nowhere else for it to go, and it must not stall the break.
            let rowHeights = measure.rows.indices.map { index in
                min(available, TablePDF.height(
                    of: measure.rows[index], onOneLine: measure.cellWidths[index],
                    widths: widths, font: measure.font
                ))
            }

            var pages: [Range<Int>] = []
            var start = 0
            var used: CGFloat = 0
            for (index, height) in rowHeights.enumerated() {
                if used + height > available, index > start {
                    pages.append(start..<index)
                    start = index
                    used = 0
                }
                used += height
            }
            pages.append(start..<rowHeights.count)

            header = measure.header
            rows = measure.rows
            font = measure.font
            headerFont = measure.headerFont
            self.widths = widths
            self.headerHeight = headerHeight
            self.rowHeights = rowHeights
            self.pages = pages
            self.pageSize = pageSize
        }

        /// The cells of one row, read against the header: a row that is short
        /// of the header's columns is `nil` the rest of the way, and anything
        /// past them is not drawn.
        func cells(ofRow index: Int) -> [String?] {
            let row = rows[index]
            return (0..<header.count).map { $0 < row.count ? row[$0] : nil }
        }
    }

    /// The grid's own font at the size a page is set in — the family and the
    /// weight kept, the size brought down to `maximumFontSize` where the
    /// reader is working at more than that.
    private static func capped(_ font: NSFont) -> NSFont {
        guard font.pointSize > maximumFontSize else { return font }
        return NSFont(descriptor: font.fontDescriptor, size: maximumFontSize) ?? font
    }

    /// The columns, cut down to the page.
    ///
    /// Nothing is taken off a column that already fits. What has to go, goes
    /// off the widest ones only, down to one shared threshold: the `T` where
    /// the widths — each held to at most `T` — sum to exactly the page. A
    /// column narrower than `T` is left exactly as wide as it asked to be and
    /// never wraps, so an `id`, a date or a `12.50` reads on one line however
    /// long the note beside it is; the columns above `T` are the ones that
    /// wrap, which is where the room was.
    ///
    /// The one case that cannot be answered that way is a table with more
    /// columns than the page could hold at any width at all. Then every
    /// column gives up the same share — all of them wrap, and at least the
    /// page still says what is in the table.
    private static func fitted(
        _ natural: [CGFloat], into width: CGFloat, minimum: CGFloat
    ) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > width else { return natural }
        guard CGFloat(natural.count) * minimum <= width else {
            return natural.map { $0 * width / total }
        }

        // Walked from the narrowest column up: `remaining` is what the
        // columns at or above the threshold still have to share, and `cut` is
        // how many of them there are. The first threshold that does not reach
        // past the column it stopped at is the one — every column below it
        // keeps what it asked for, and the rest are held to it.
        var remaining = width
        var cut = natural.count
        for value in natural.sorted() {
            let threshold = remaining / CGFloat(cut)
            if threshold <= value { return natural.map { min($0, threshold) } }
            remaining -= value
            cut -= 1
        }
        return natural
    }

    /// One cell's text on a single line, which is what a column's natural
    /// width is measured from.
    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// How tall a row of these cells is: the tallest of them wrapped inside
    /// its own column, and never shorter than one line of the font.
    ///
    /// `onOneLine` is how wide each cell was on a single line, measured once
    /// when the columns were sized. A cell no wider than the room inside its
    /// column cannot wrap, so it is one line tall and is not laid out again;
    /// only the cells that must wrap are asked how tall they became. On a
    /// table of short values that is every cell, and nothing is laid out at
    /// all.
    private static func height(
        of cells: [String?], onOneLine: [CGFloat], widths: [CGFloat], font: NSFont
    ) -> CGFloat {
        var tallest = ceil(font.ascender - font.descender + font.leading)
        for (index, value) in cells.enumerated() where index < widths.count {
            guard let value, !value.isEmpty else { continue }
            let measure = max(1, widths[index] - horizontalPadding * 2)
            if index < onOneLine.count, onOneLine[index] <= measure { continue }
            let drawn = attributed(value, font: font).boundingRect(
                with: NSSize(width: measure, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            tallest = max(tallest, ceil(drawn.height))
        }
        return tallest + verticalPadding * 2
    }

    /// A cell's text as it is measured and as it is drawn — the same string
    /// both times, so a row is exactly as tall as what lands on it.
    private static func attributed(_ text: String, font: NSFont) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: inkColour,
            .paragraphStyle: style,
        ])
    }

    // MARK: - The page

    /// The pages, stacked one page-height apart, each drawn into its own page
    /// rect. `knowsPageRange` is what makes the break exact — the print system
    /// asks for the pages rather than working them out from the view's height
    /// — and it is what lets the header repeat at the top of each of them.
    private final class TableView: NSView {
        private let layout: Layout

        init(layout: Layout) {
            self.layout = layout
            super.init(frame: NSRect(
                origin: .zero,
                size: NSSize(
                    width: layout.pageSize.width,
                    height: layout.pageSize.height * CGFloat(max(1, layout.pages.count))
                )
            ))
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// Pages are counted from the top, so the view draws the way it
        /// paginates.
        override var isFlipped: Bool { true }

        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            range.pointee = NSRange(location: 1, length: layout.pages.count)
            return true
        }

        override func rectForPage(_ page: Int) -> NSRect {
            NSRect(
                x: 0, y: CGFloat(page - 1) * layout.pageSize.height,
                width: layout.pageSize.width, height: layout.pageSize.height
            )
        }

        override func draw(_ dirtyRect: NSRect) {
            for index in layout.pages.indices {
                let page = rectForPage(index + 1)
                guard page.intersects(dirtyRect) else { continue }
                draw(page: index, in: page)
            }
        }

        /// The header, then the rows this page holds.
        private func draw(page index: Int, in rect: NSRect) {
            var y = rect.minY
            draw(
                cells: layout.header.map { $0 }, at: y, height: layout.headerHeight,
                x: rect.minX, font: layout.headerFont, fill: TablePDF.headerFill
            )
            y += layout.headerHeight
            for row in layout.pages[index] {
                draw(
                    cells: layout.cells(ofRow: row), at: y, height: layout.rowHeights[row],
                    x: rect.minX, font: layout.font, fill: nil
                )
                y += layout.rowHeights[row]
            }
        }

        /// One row: each cell filled, ruled on all four sides, and its text
        /// laid inside the rule and clipped to it.
        private func draw(
            cells: [String?], at y: CGFloat, height: CGFloat,
            x origin: CGFloat, font: NSFont, fill: NSColor?
        ) {
            var x = origin
            for (index, width) in layout.widths.enumerated() {
                let cell = NSRect(x: x, y: y, width: width, height: height)
                x += width

                if let fill {
                    fill.setFill()
                    cell.fill()
                }

                let rule = NSBezierPath(rect: cell.insetBy(
                    dx: TablePDF.ruleWidth / 2, dy: TablePDF.ruleWidth / 2
                ))
                rule.lineWidth = TablePDF.ruleWidth
                TablePDF.ruleColour.setStroke()
                rule.stroke()

                guard index < cells.count, let text = cells[index], !text.isEmpty else { continue }
                let inside = cell.insetBy(
                    dx: TablePDF.horizontalPadding, dy: TablePDF.verticalPadding
                )
                guard inside.width > 0, inside.height > 0 else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: inside).setClip()
                TablePDF.attributed(text, font: font).draw(
                    with: inside, options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
