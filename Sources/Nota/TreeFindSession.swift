import AppKit

/// Which part of a row a query was found in — the name the file gives a
/// member, or the value it gives that name.
///
/// It is what the caret follows: a value match takes the editor to the value
/// alone, a key match to the whole member, since a key has no span of its own
/// to point at.
enum TreeFindKind: Equatable {
    case key, value
}

/// One searchable part of a row, and where it begins in the row's own text.
///
/// A row is drawn as its key, a gap, then its value, so a match found in the
/// value has to be shifted along by everything in front of it before it can be
/// banded: the band goes on the row's attributed string, and that string is
/// the whole line.
struct TreeFindField {
    let kind: TreeFindKind
    let text: String
    /// The offset of `text` inside the row's own text, in the UTF-16 units an
    /// `NSAttributedString` counts in.
    let offset: Int
}

/// What a query means in one tree: the matches, the bands over them, which one
/// is current, and how ⌘G walks between them.
///
/// The third of the shape `TextFindSession` and `PDFFindSession` share, and
/// the closest to the document's: there is no text storage to lay a temporary
/// attribute on and nothing to replace, so the bands are drawn into the rows'
/// own titles and the replace pill is out of reach.
///
/// A tree is searched by what it *shows*. The matches are the keys the file
/// names its members with and the values as the rows spell them — a string in
/// its quotes, a number as it is written, a comment as it stands — and never
/// the punctuation the grammar puts between them. A row is a line of the
/// reader's tree, not a line of the file.
///
/// Nothing a search does reaches the file. It expands what it has to expand to
/// show a match and collapses nothing: a search is a way of looking at the
/// document, not a rearrangement of it.
final class TreeFindSession {

    /// How many matches wear a band at once, and the same number the editor
    /// and a document stop at. The count says `2000+` rather than a total
    /// nobody asked for.
    static let highlightLimit = TextFindSession.highlightLimit

    /// The band a match not being stood on wears — the editor's own, so a
    /// tree and the source beside it are marked the same way.
    private static let bandAlpha: CGFloat = 0.12

    let bar: FindBarView
    private weak var tree: TreePreviewView?

    /// Run when the pill arrives or leaves, so the column's mode control can
    /// get out of its corner.
    var onVisibilityChange: ((Bool) -> Void)?

    /// Every match, in the order the rows are written, and whether the list
    /// stopped at the cap.
    private(set) var matches: [Match] = []
    private(set) var isCapped = false

    /// The same matches by the row they are on, since a row asks for its own
    /// bands as it is drawn and there may be two thousand of them.
    private var matchesByRow: [ObjectIdentifier: [Match]] = [:]

    /// Which of them the reader is standing on, if any.
    private(set) var currentIndex: Int?

    /// The query the last search ran with. It outlives the bar, so ⌘G keeps
    /// working after Escape.
    private(set) var query = ""

    /// Where an incremental search counts from: the first row on screen when
    /// the bar opened, and afterwards the match ⌘G last landed on. Typing
    /// walks forward from there rather than from the match the last keystroke
    /// found, which would creep down the tree one letter at a time.
    private var anchor = Position.start

    /// The rows wearing a band, so the ones that stop wearing one are drawn
    /// again as well as the ones that start.
    private var bandedRows: [TreePreviewView.Row] = []

    /// Whether the bands are up at all. Escape puts them down and leaves the
    /// matches standing, so ⌘G goes on working with the bar closed — and
    /// brings the bands back with it, the way the editor's and a document's
    /// do.
    private var showsBands = true

    var isVisible: Bool { bar.isShown }

    var currentMatch: Match? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    init(bar: FindBarView, tree: TreePreviewView) {
        self.bar = bar
        self.tree = tree
        // A tree cannot be typed into, so the glass is only a glass and the
        // replace pill is out of reach.
        bar.canReplace = false
        bar.handlesAction = { Self.handles($0) }
        bar.onFinderAction = { [weak self] action in self?.perform(action) }
        bar.onQueryChange = { [weak self] _ in self?.runSearch(moving: true) }
        bar.onVisibilityChange = { [weak self] shown in self?.onVisibilityChange?(shown) }
    }

    // MARK: - The menu's actions

    /// Which of `NSTextFinder`'s actions a tree answers for. Not the replace
    /// half: there is nothing here to replace, so Find and Replace… is greyed
    /// out over a tree rather than opening a pill that could do nothing.
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

    /// ⌘F. The last query comes back with all of it selected, so the next
    /// thing typed replaces it, and the search starts from the row at the top
    /// of the column rather than from the root of the document.
    ///
    /// The selected row is deliberately *not* read into the field the way a
    /// PDF's selection is. A tree always has a selected row — the caret lights
    /// one, and the last match left one behind — so seeding from it would mean
    /// ⌘G, ⌘F typed over its own answer every time.
    func show() {
        anchor = anchorAtTop()
        bar.setShown(true)
        bar.focusField()
        runSearch(moving: true)
    }

    /// Escape, the ✕, or Hide Find Interface. The bands go down, the row the
    /// reader landed on stays selected, and the keyboard goes back to the
    /// tree.
    func hide() {
        guard bar.isShown else { return }
        bar.setShown(false)
        clearBands()
        tree?.focusOutline()
    }

    /// The tab in front changed, or another file went into the pane: every
    /// row held here belongs to a tree that is no longer being read.
    func close() {
        hide()
        clearBands()
        matches = []
        matchesByRow = [:]
        bandedRows = []
        isCapped = false
        currentIndex = nil
    }

    // MARK: - Searching

    /// ⌘G and ⇧⌘G, and Return and ⇧Return in the field. Both wrap round the
    /// end of the tree, and both work with the bar closed — the query outlives
    /// it.
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
            // Nothing stood on yet: forward from where the bar opened, back
            // from the end of the tree.
            next = forward ? (indexOfMatch(atOrAfter: anchor) ?? 0) : matches.count - 1
        }
        land(on: next, movingAnchor: true)
        applyBands()
        updateStatus()
    }

    /// ⌘E. The selected row becomes the query — its value where it has one,
    /// its key where it does not — here and on the find pasteboard, so it is
    /// the string the next app's ⌘G looks for too. A string's quotes are left
    /// off: the reader means the word inside them.
    func useSelectionForFind() {
        guard let selected = tree?.selectionTextForFind, !selected.isEmpty else { return }
        bar.query = selected
        query = selected
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(selected, forType: .string)
        if let order = tree?.selectedFindRowOrder {
            anchor = Position(row: order, field: 0, offset: 0)
        }
        // With the bar up the search runs at once, landing on the very row
        // that seeded it; with it down the matches are still made, so a ⌘G
        // straight afterwards walks the new query.
        if bar.isShown {
            runSearch(moving: true)
        } else {
            scanMatches()
            currentIndex = nil
        }
    }

    /// The rows have been made again — the file was typed in, or the pane was
    /// shown a fresh parse of it. The query is run over the new rows; the
    /// match the reader was standing on stays current if the same part of the
    /// same node is still there, and is otherwise let go.
    func refresh() {
        guard !query.isEmpty else {
            matches = []
            matchesByRow = [:]
            bandedRows = []
            currentIndex = nil
            return
        }
        let standing = currentMatch
        scanMatches()
        currentIndex = standing.flatMap { previous in
            matches.firstIndex {
                $0.row.path == previous.row.path && $0.kind == previous.kind
                    && $0.range.location == previous.range.location
            }
        }
        // The rows the bands were on are gone with the parse that made them;
        // the new ones are drawn from the new matches, and only while the bar
        // has them up at all.
        bandedRows = []
        if showsBands { applyBands() }
        updateStatus()
    }

    /// One pass of the query: the matches, the bands, the count, and — while
    /// the reader is typing — the first match at or after the row the bar
    /// opened over.
    private func runSearch(moving: Bool) {
        query = bar.query
        scanMatches()
        if query.isEmpty {
            currentIndex = nil
        } else if moving {
            currentIndex = nil
            if let index = indexOfMatch(atOrAfter: anchor) ?? (matches.isEmpty ? nil : 0) {
                // The anchor stays where the bar opened while the reader
                // types: an incremental search that moved it would creep down
                // the tree one letter at a time.
                land(on: index, movingAnchor: false)
            }
        }
        applyBands()
        updateStatus()
    }

    /// Case- and diacritic-insensitive, the same as every other bar in the
    /// app: `cafe` finds `Café`.
    private static let options: NSString.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive,
    ]

    /// Every match in the tree, in the order the rows are written — a node's
    /// key before its value, a parent before its children — and no more than
    /// `highlightLimit` of them. Rows inside a closed branch are searched
    /// like any other: a match is what opens the branch.
    private func scanMatches() {
        matches = []
        matchesByRow = [:]
        isCapped = false
        guard let tree, !query.isEmpty else { return }
        var found: [Match] = []
        rows: for (order, row) in tree.findRows.enumerated() {
            for (fieldIndex, field) in tree.findFields(of: row).enumerated() {
                let text = field.text as NSString
                var from = 0
                while from < text.length {
                    let rest = NSRange(location: from, length: text.length - from)
                    let hit = text.range(of: query, options: Self.options, range: rest)
                    guard hit.location != NSNotFound else { break }
                    found.append(Match(
                        row: row, kind: field.kind,
                        range: NSRange(location: field.offset + hit.location, length: hit.length),
                        position: Position(row: order, field: fieldIndex, offset: hit.location)
                    ))
                    if found.count >= Self.highlightLimit { break rows }
                    from = hit.location + max(hit.length, 1)
                }
            }
        }
        matches = found
        for match in found { matchesByRow[ObjectIdentifier(match.row), default: []].append(match) }
        // The scan stops at the cap rather than counting past it, so reaching
        // it is what "capped" means here — the same rule the editor's is read
        // by.
        isCapped = found.count >= Self.highlightLimit
    }

    /// The first match at or after a place in the tree, in reading order.
    private func indexOfMatch(atOrAfter position: Position) -> Int? {
        matches.firstIndex { $0.position >= position }
    }

    /// Lands on a match: every branch above it opens, the row is brought into
    /// view and selected, and the editor's caret follows the part of the node
    /// that matched — the value alone where the value matched, the whole
    /// member where its key did.
    ///
    /// The caret follows in every mode, and not only where a click's would.
    /// A find is the reader saying where they want to be; leaving the source
    /// behind would mean flipping back to the editor and looking for it a
    /// second time.
    private func land(on index: Int, movingAnchor: Bool) {
        guard matches.indices.contains(index) else { return }
        currentIndex = index
        let match = matches[index]
        if movingAnchor { anchor = match.position }
        guard let tree else { return }
        tree.expandAncestors(of: match.row)
        tree.selectFindRow(match.row)
        tree.revealFindSource(of: match.row, kind: match.kind)
    }

    /// Where an incremental search starts: the first row on screen, so typing
    /// finds the first thing in front of the reader rather than the first
    /// thing in the file.
    private func anchorAtTop() -> Position {
        guard let tree, let order = tree.firstVisibleFindRowOrder else { return .start }
        return Position(row: order, field: 0, offset: 0)
    }

    // MARK: - The bands

    /// The bands a row is wearing, in its own text's coordinates — asked by
    /// the pane as it builds the row's title, which is the only string there
    /// is to lay a colour on.
    func bands(of row: TreePreviewView.Row) -> [(range: NSRange, isCurrent: Bool)] {
        guard showsBands, let found = matchesByRow[ObjectIdentifier(row)] else { return [] }
        let current = currentMatch
        return found.map { match in
            let isCurrent = current.map { standing in
                standing.row === match.row && standing.kind == match.kind
                    && standing.range.location == match.range.location
            } ?? false
            return (range: match.range, isCurrent: isCurrent)
        }
    }

    /// The quiet band, and AppKit's own find yellow for the one being stood
    /// on. The same two colours the editor's matches wear.
    static var quietBand: NSColor { NSTextView.quietFindBand(alpha: bandAlpha) }
    static var currentBand: NSColor { .findHighlightColor }

    /// Draws the rows whose bands have changed — the ones that have them now
    /// and the ones that had them a moment ago.
    private func applyBands() {
        showsBands = true
        let wearing = uniqueRows(of: matches)
        var redraw = bandedRows
        for row in wearing where !redraw.contains(where: { $0 === row }) { redraw.append(row) }
        bandedRows = wearing
        tree?.redrawFindRows(redraw)
    }

    /// The bands go down. What is selected is left alone — that is the row the
    /// reader was standing on, and closing the bar hands it to them.
    private func clearBands() {
        showsBands = false
        let previous = bandedRows
        bandedRows = []
        tree?.redrawFindRows(previous)
    }

    private func uniqueRows(of matches: [Match]) -> [TreePreviewView.Row] {
        var seen = Set<ObjectIdentifier>()
        var rows: [TreePreviewView.Row] = []
        for match in matches where seen.insert(ObjectIdentifier(match.row)).inserted {
            rows.append(match.row)
        }
        return rows
    }

    // MARK: - The count

    /// `"3 of 12"` while there are matches and one of them is current,
    /// `"12 matches"` when none is, `"No matches"` when there are none, and
    /// nothing at all while the field is empty — the wording every other bar
    /// in the app uses. A tree big enough to have stopped the list says
    /// `2000+` for the total rather than a number it did not count.
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
        guard let currentIndex else {
            bar.setStatus(matches.count == 1 && !isCapped ? "1 match" : "\(total) matches")
            return
        }
        bar.setStatus("\(currentIndex + 1) of \(total)")
    }
}

// MARK: - A match and where it is

extension TreeFindSession {

    /// One hit: the row it is on, the part of that row it was found in, where
    /// it sits in the row's own text, and where the row sits in the tree.
    struct Match {
        let row: TreePreviewView.Row
        let kind: TreeFindKind
        /// The matched substring, in the row's own text — what the band is
        /// painted over.
        let range: NSRange
        let position: Position
    }

    /// Where a match sits in the tree, in reading order: which row, which part
    /// of it, and how far into that part.
    ///
    /// A `Row` has no index of its own, and the rows are made afresh on every
    /// parse, so this is what orders the matches for an incremental search and
    /// what the anchor is spelled in.
    struct Position: Comparable {
        let row: Int
        let field: Int
        let offset: Int

        /// Before every match there could be.
        static let start = Position(row: 0, field: 0, offset: 0)

        static func < (lhs: Position, rhs: Position) -> Bool {
            if lhs.row != rhs.row { return lhs.row < rhs.row }
            if lhs.field != rhs.field { return lhs.field < rhs.field }
            return lhs.offset < rhs.offset
        }
    }
}
