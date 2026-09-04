import AppKit
import PDFKit

/// What a query means in one PDF: the matches, the bands over them, which one
/// is current, and how ⌘G walks between them.
///
/// The twin of `TextFindSession`, over a document rather than a text view. The
/// two share the pill — the same `FindBarView` floats in the corner of a PDF
/// column as floats over the render — and share nothing else: a PDF has no
/// storage to lay a temporary attribute on, no caret, and nothing to replace,
/// so the mechanism underneath is PDFKit's own selections and every word of it
/// is different. Two classes of the same shape are the honest answer; a
/// protocol over them would only be the pill's own interface written twice.
///
/// Nothing a search does reaches the file. `highlightedSelections` are drawn
/// over the page by the view, never into the document, and a PDF tab is never
/// written to at all.
final class PDFFindSession {

    /// How many matches wear a band at once, and the same number the editor
    /// stops at. A one-letter query over a thousand-page report is otherwise a
    /// list PDFKit builds and the view draws between one keystroke and the
    /// next; the count says `2000+` rather than a total nobody asked for.
    static let highlightLimit = TextFindSession.highlightLimit

    /// A match wears a quiet band, the way the editor's do. It is spelled
    /// black rather than `labelColor` because the paper under it is white in
    /// both appearances — a PDF page does not turn dark when the app does, so
    /// a band that resolved to white would simply not be there. A touch
    /// stronger than the editor's 0.12, since this is drawn over the page's
    /// own ink rather than composited behind the glyphs.
    private static let bandAlpha: CGFloat = 0.18

    let bar: FindBarView
    private weak var pdfView: PDFView?

    /// Run when the pill arrives or leaves, so the column's mode control can
    /// get out of its corner — a PDF has none, but the column asks all the
    /// same.
    var onVisibilityChange: ((Bool) -> Void)?

    /// The matches wearing a band, up to `highlightLimit`, and whether the
    /// list stopped at it.
    private(set) var matches: [PDFSelection] = []
    private(set) var isCapped = false

    /// The match the reader is on. It is also what is selected on the page —
    /// unlike the editor's, where a selection under a find field draws in a
    /// grey that hides the band. PDFKit draws `highlightedSelections` over the
    /// selection rather than under it, so the yellow stays legible and the
    /// match can be a real selection the whole time.
    private(set) var currentMatch: PDFSelection?

    /// Where an incremental search counts from: the top of the page the reader
    /// was on when the bar opened, and afterwards the match ⌘G last landed on.
    /// Typing walks forward from there rather than from the match the last
    /// keystroke found, which would creep down the document one letter at a
    /// time.
    private var anchor = Position.start

    /// The query the last search ran with. It outlives the bar, so ⌘G keeps
    /// working after Escape.
    private(set) var query = ""

    var isVisible: Bool { bar.isShown }

    init(bar: FindBarView, pdfView: PDFView) {
        self.bar = bar
        self.pdfView = pdfView
        // A document cannot be typed into, so the glass is only a glass and
        // the replace pill is out of reach.
        bar.canReplace = false
        bar.handlesAction = { Self.handles($0) }
        bar.onFinderAction = { [weak self] action in self?.perform(action) }
        bar.onQueryChange = { [weak self] _ in self?.runSearch(moving: true) }
        bar.onVisibilityChange = { [weak self] shown in self?.onVisibilityChange?(shown) }
    }

    // MARK: - The menu's actions

    /// Which of `NSTextFinder`'s actions a document answers for. Not the
    /// replace half: there is nothing here to replace, so Find and Replace…
    /// is greyed out over a PDF rather than opening a pill that could do
    /// nothing.
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

    /// ⌘F. A selection on the page comes up in the field ready to be searched
    /// for; anything else keeps the last query, all of it selected, so typing
    /// replaces it. The search starts from the page being read rather than
    /// from the top of the document.
    func show() {
        if let selected = pdfView?.currentSelection?.string, !selected.isEmpty {
            bar.query = selected
        }
        anchor = anchorForCurrentPage()
        bar.setShown(true)
        bar.focusField()
        runSearch(moving: true)
    }

    /// Escape, the ✕, or Hide Find Interface. The bands go down and the match
    /// the reader was on stays selected on the page — there is no field
    /// holding the keyboard any more, so nothing is drawing over it — and the
    /// keyboard goes back to the document.
    func hide() {
        guard bar.isShown else { return }
        bar.setShown(false)
        clearHighlights()
        guard let pdfView else { return }
        if let currentMatch { pdfView.setCurrentSelection(currentMatch, animate: false) }
        pdfView.window?.makeFirstResponder(pdfView)
    }

    /// The tab in front changed, or another document went into the pane:
    /// every selection held here points into a document that is no longer
    /// being read.
    func close() {
        hide()
        matches = []
        isCapped = false
        currentMatch = nil
    }

    // MARK: - Searching

    /// ⌘G and ⇧⌘G, and Return and ⇧Return in the field. Both wrap round the
    /// end of the document, and both work with the bar closed — the query
    /// outlives it.
    func step(forward: Bool) {
        guard let document, !query.isEmpty else { return }
        var options = Self.options
        if !forward { options.insert(.backwards) }
        // From the match being stood on, or — the reader having clicked
        // somewhere else on the page meanwhile — from wherever they clicked.
        let from = currentMatch ?? pdfView?.currentSelection
        let found = document.findString(query, fromSelection: from, withOptions: options)
            // Nothing that way: round the end of the document, which is where
            // a `nil` selection starts from in whichever direction is asked.
            ?? document.findString(query, fromSelection: nil, withOptions: options)
        guard let found else {
            updateStatus()
            return
        }
        anchor = Position(of: found, in: document)
        select(found)
        applyHighlights()
        updateStatus()
    }

    /// ⌘E. The selection on the page becomes the query — here and on the find
    /// pasteboard, so it is the string the next app's ⌘G looks for too —
    /// without opening the bar or moving off what is selected.
    func useSelectionForFind() {
        guard let selection = pdfView?.currentSelection,
              let selected = selection.string, !selected.isEmpty
        else { return }
        bar.query = selected
        query = selected
        if let document { anchor = Position(of: selection, in: document) }
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(selected, forType: .string)
        // With the bar up the search runs at once, landing on the very
        // selection that seeded it.
        if bar.isShown { runSearch(moving: true) }
    }

    /// One pass of the query: the matches, the bands, the count, and — while
    /// the reader is typing — the first match at or after where the bar
    /// opened.
    ///
    /// A document never edits, so this is one scan per query rather than the
    /// editor's debounced re-scan: the only thing that can move a match here
    /// is the reader typing another letter.
    private func runSearch(moving: Bool) {
        query = bar.query
        scanMatches()
        if query.isEmpty {
            currentMatch = nil
        } else if moving {
            currentMatch = nil
            if let match = firstMatch(atOrAfter: anchor) ?? matches.first { select(match) }
        }
        applyHighlights()
        updateStatus()
    }

    /// Case- and diacritic-insensitive, the same as the editor's bar: `cafe`
    /// finds `Café`.
    private static let options: NSString.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive,
    ]

    private var document: PDFDocument? { pdfView?.document }

    /// Every match in the document, and no more than `highlightLimit` of them.
    private func scanMatches() {
        matches = []
        isCapped = false
        guard let document, !query.isEmpty else { return }
        let found = document.findString(query, withOptions: Self.options)
        isCapped = found.count > Self.highlightLimit
        matches = isCapped ? Array(found.prefix(Self.highlightLimit)) : found
    }

    /// The first match at or after a place in the document, in reading order.
    private func firstMatch(atOrAfter position: Position) -> PDFSelection? {
        guard let document else { return nil }
        return matches.first { Position(of: $0, in: document) >= position }
    }

    /// Lands on a match: it becomes the page's selection, wears the loud band
    /// in `applyHighlights`, and is brought into view.
    private func select(_ selection: PDFSelection) {
        currentMatch = selection
        guard let pdfView else { return }
        pdfView.setCurrentSelection(selection, animate: false)
        pdfView.scrollSelectionToVisible(nil)
    }

    /// Where an incremental search starts: the top of the page being read, so
    /// typing finds the first thing on the page in front rather than the first
    /// thing in the document.
    private func anchorForCurrentPage() -> Position {
        guard let document, let page = pdfView?.currentPage else { return .start }
        let index = document.index(for: page)
        return Position(page: index == NSNotFound ? 0 : index, down: -.greatestFiniteMagnitude,
                        across: -.greatestFiniteMagnitude)
    }

    // MARK: - The bands

    /// Every match into the view's `highlightedSelections`, quiet but for the
    /// one the reader is on. A `PDFSelection` carries the colour it is drawn
    /// in, so the current match is the same object in the same list wearing
    /// AppKit's own find yellow.
    private func applyHighlights() {
        guard let pdfView, let document else { return }
        guard !matches.isEmpty || currentMatch != nil else {
            pdfView.highlightedSelections = nil
            return
        }
        let quiet = NSColor.black.withAlphaComponent(Self.bandAlpha)
        let current = currentMatch.map { Position(of: $0, in: document) }
        var drawn: [PDFSelection] = []
        var hasCurrent = false
        for match in matches {
            let band = PDFSelection(document: document)
            band.add(match)
            if let current, Position(of: match, in: document) == current {
                band.color = .findHighlightColor
                hasCurrent = true
            } else {
                band.color = quiet
            }
            drawn.append(band)
        }
        // A match past the cap is still the one being stood on, and still
        // wears its band even though the list does not hold it.
        if !hasCurrent, let currentMatch {
            let band = PDFSelection(document: document)
            band.add(currentMatch)
            band.color = .findHighlightColor
            drawn.append(band)
        }
        pdfView.highlightedSelections = drawn
    }

    /// The bands go down. What is selected on the page is left alone — that is
    /// the match the reader was standing on, and closing the bar hands it to
    /// them.
    private func clearHighlights() {
        pdfView?.highlightedSelections = nil
    }

    // MARK: - The count

    /// `"3 of 12"` while there are matches and one of them is current,
    /// `"12 matches"` when none is, `"No matches"` when there are none, and
    /// nothing at all while the field is empty. A document big enough to have
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
        guard let document, let currentMatch else {
            bar.setStatus(matches.count == 1 && !isCapped ? "1 match" : "\(total) matches")
            return
        }
        let current = Position(of: currentMatch, in: document)
        guard let index = matches.firstIndex(where: { Position(of: $0, in: document) == current })
        else {
            // Past the cap: the reader is standing on a match the list does
            // not hold, so there is no number to count from.
            bar.setStatus(matches.count == 1 && !isCapped ? "1 match" : "\(total) matches")
            return
        }
        bar.setStatus("\(index + 1) of \(total)")
    }
}

// MARK: - Where a match is

extension PDFFindSession {

    /// Where a selection sits in the document, in reading order — which page,
    /// how far down it, and how far across.
    ///
    /// A `PDFSelection` has no index into the document and no useful identity
    /// of its own: two selections over the same words are different objects
    /// and compare unequal. This is what stands in for both — it orders the
    /// matches for an incremental search and it says which of them the reader
    /// is standing on.
    ///
    /// PDF coordinates count up from the foot of the page, so "down" is the
    /// top of the selection negated: a smaller number is higher up.
    struct Position: Comparable {
        let page: Int
        let down: CGFloat
        let across: CGFloat

        /// The top of the first page — before every match there could be.
        static let start = Position(page: 0, down: -.greatestFiniteMagnitude,
                                    across: -.greatestFiniteMagnitude)

        init(page: Int, down: CGFloat, across: CGFloat) {
            self.page = page
            self.down = down
            self.across = across
        }

        init(of selection: PDFSelection, in document: PDFDocument) {
            guard let page = selection.pages.first else {
                self = .start
                return
            }
            let index = document.index(for: page)
            let bounds = selection.bounds(for: page)
            self.init(page: index == NSNotFound ? 0 : index,
                      down: -bounds.maxY, across: bounds.minX)
        }

        static func < (lhs: Position, rhs: Position) -> Bool {
            if lhs.page != rhs.page { return lhs.page < rhs.page }
            if lhs.down != rhs.down { return lhs.down < rhs.down }
            return lhs.across < rhs.across
        }
    }
}
