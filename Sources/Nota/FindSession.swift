import AppKit

/// What a query means in one text view: the matches, the bands behind them,
/// which one is current, and how ⌘G walks between them.
///
/// One of these binds a `FindBarView` to an `NSTextView`. The editor has one
/// and the rendered page has one, and neither knows about the other — reading
/// mode's ⌘F searches the render because the render's own text view is the
/// first responder there, not because anything here says so.
///
/// Nothing a search does ever reaches the text. The bands are the layout
/// manager's *temporary* attributes, which live beside the storage rather than
/// in it, exactly as vim's `'hlsearch'` does — so a highlight can never reach
/// the cache, the pasteboard or the file.
final class TextFindSession {

    /// How many matches wear a band at once. The editor opens files of any
    /// size, and a single letter typed into the bar over a hundred megabytes
    /// would otherwise be a hundred thousand temporary attributes laid on the
    /// main thread between one keystroke and the next. The scan stops at the
    /// cap, so it costs the same on a huge file as on a small one; the count
    /// says `2000+` rather than pretending to know the total.
    static let highlightLimit = 2000

    /// A match wears the same quiet band vim's `'hlsearch'` uses. The one
    /// the reader is on wears `findHighlightColor` instead — the selection
    /// alone will not do it, since the keyboard is in the find field and an
    /// inactive selection draws in almost exactly this grey.
    private static let bandAlpha: CGFloat = 0.12

    let bar: FindBarView
    private weak var textView: NSTextView?

    /// Run when the pill arrives or leaves, so the column's mode control can
    /// get out of its corner and come back.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Run when the bar puts its bands down, so whatever else lights this view
    /// — vim's own search — can put its back.
    var onHighlightsCleared: (() -> Void)?

    /// The matches wearing a band, up to `highlightLimit`, and whether the
    /// scan stopped at it.
    private(set) var matches: [NSRange] = []
    private(set) var isCapped = false

    /// The match the reader is on, which is also what is selected. Kept here
    /// rather than read back off the selection, so a match past the highlight
    /// cap — one the list does not hold — still wears its own band.
    private(set) var currentMatch: NSRange?

    /// Where an incremental search counts from: where the caret was when the
    /// bar opened. Typing walks forward from there rather than from the match
    /// the last keystroke landed on, which would otherwise creep down the note
    /// one letter at a time.
    private var anchor = 0

    /// The query the last search ran with. It outlives the bar, so ⌘G keeps
    /// working after Escape.
    private(set) var query = ""

    var isVisible: Bool { bar.isShown }

    init(bar: FindBarView, textView: NSTextView) {
        self.bar = bar
        self.textView = textView
        bar.onFinderAction = { [weak self] action in self?.perform(action) }
        bar.onQueryChange = { [weak self] _ in self?.runSearch(moving: true) }
        bar.onVisibilityChange = { [weak self] shown in self?.onVisibilityChange?(shown) }
    }

    // MARK: - The menu's four actions

    /// Which of `NSTextFinder`'s actions Nota's bar answers for. The replace
    /// half of the native finder is not in the Find menu and is not here
    /// either.
    static func handles(_ action: NSTextFinder.Action) -> Bool {
        switch action {
        case .showFindInterface, .hideFindInterface, .nextMatch, .previousMatch,
             .setSearchString, .showReplaceInterface, .hideReplaceInterface,
             .replace, .replaceAll:
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
        case .showReplaceInterface: showReplace()
        case .hideReplaceInterface: hideReplace()
        case .replace: replace()
        case .replaceAll: replaceAll()
        default: return false
        }
        return true
    }

    // MARK: - Opening and closing

    /// ⌘F. A selection comes up in the field ready to be searched for;
    /// anything else keeps the last query, all of it selected, so typing
    /// replaces it.
    ///
    /// ⌘F over a bar that is already showing its replace row folds that row
    /// away and puts the keyboard back in the query field: the one key both
    /// opens find and comes back to it.
    func show() {
        guard let textView else { return }
        if bar.isShown, bar.isExpanded { bar.setExpanded(false) }
        // A rendered page, and a tab that cannot be typed in, have nothing to
        // replace: the word there is only a word.
        bar.canReplace = textView.isEditable
        let selection = textView.selectedRange()
        if selection.length > 0 {
            bar.query = (textView.string as NSString).substring(with: selection)
        }
        anchor = selection.location
        bar.setShown(true)
        bar.focusField()
        runSearch(moving: true)
    }

    /// Escape, the ✕, or Hide Find Interface. The bands go, the match you were
    /// on is handed over as a real selection — there is no field holding the
    /// keyboard any more, so nothing is drawing over it — and the keyboard
    /// goes back to the text.
    func hide() {
        guard bar.isShown else { return }
        bar.setShown(false)
        // The replace row is asked for, never inherited: the next ⌘F opens
        // find and no more.
        bar.setExpanded(false)
        let landing = currentMatch
        clearHighlights()
        guard let textView else { return }
        // An edit may have shortened the note under a match found before it.
        if let landing, NSMaxRange(landing) <= (textView.textStorage?.length ?? 0) {
            textView.setSelectedRange(landing)
        }
        textView.window?.makeFirstResponder(textView)
    }

    /// ⌘R. The same bar with its replace row out, and the keyboard in
    /// whichever field there is still something to type in. Where nothing can
    /// be edited it is ⌘F and no more.
    ///
    /// Pressed again over a row that is already out it folds it away and
    /// hands the keyboard back to the query field — the same key both ways,
    /// like ⌘F.
    func showReplace() {
        if bar.isShown, bar.isExpanded {
            hideReplace()
            return
        }
        show()
        guard textView?.isEditable == true else { return }
        bar.setExpanded(true)
        if !bar.query.isEmpty { bar.focusReplaceField() }
    }

    /// The replace row folds away — the word `Replace` was clicked, or ⌘R was
    /// pressed over a row that was already out — and the keyboard goes back to
    /// the query field, which is the only field left to type in.
    func hideReplace() {
        guard bar.isExpanded else { return }
        bar.setExpanded(false)
        if bar.isShown { bar.focusField() }
    }

    /// The tab in front changed, or the page was rendered again: whatever was
    /// lit belonged to text that is no longer there.
    func close() {
        guard bar.isShown else { return }
        hide()
    }

    /// The text under the bar was replaced — a fresh render of the same page.
    /// The temporary attributes went with the old storage, so they are laid on
    /// again for what is there now, without moving what is selected.
    func refresh() {
        guard bar.isShown else { return }
        runSearch(moving: false)
    }

    // MARK: - Searching

    /// ⌘G and ⇧⌘G, and Return and ⇧Return in the field. Both wrap, and both
    /// work with the bar closed — the query outlives it.
    func step(forward: Bool) {
        guard let text, !query.isEmpty else { return }
        let here = stepOrigin
        let from = forward ? NSMaxRange(here) : here.location
        guard let match = match(in: text, from: from, forward: forward) else {
            updateStatus()
            return
        }
        anchor = match.location
        select(match)
        applyHighlights()
        updateStatus()
    }

    /// The match the reader is actually standing on, or nothing if they have
    /// moved off it since. Replace works on this and on nothing else.
    private var standingMatch: NSRange? {
        guard let current = currentMatch, let selection = textView?.selectedRange(),
              isStanding(on: current, with: selection)
        else { return nil }
        return current
    }

    /// Where a step counts from: the match being stood on, or — the reader
    /// having clicked somewhere else in the text meanwhile — wherever they
    /// clicked, which becomes the new place to walk from.
    private var stepOrigin: NSRange {
        let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        guard let current = currentMatch, isStanding(on: current, with: selection) else {
            currentMatch = nil
            return selection
        }
        return current
    }

    /// Whether `selection` is the reader still on `match`. While the bar is
    /// up that is a caret at the match's start, since the match itself is
    /// deliberately left unselected; with the bar closed it is the match.
    private func isStanding(on match: NSRange, with selection: NSRange) -> Bool {
        bar.isShown
            ? selection.length == 0 && selection.location == match.location
            : selection == match
    }

    /// ⌘E. The selection becomes the query — here and on the find pasteboard,
    /// so it is the string the next app's ⌘G looks for too — without opening
    /// the bar or moving off what is selected.
    func useSelectionForFind() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        let selected = (textView.string as NSString).substring(with: selection)
        bar.query = selected
        query = selected
        anchor = selection.location
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(selected, forType: .string)
        // With the bar up the search runs at once, landing on the very range
        // that was selected — which is how that selection becomes a caret and
        // a band, like every other match the bar lands on.
        if bar.isShown { runSearch(moving: true) }
    }

    /// One pass of the query: the matches, the bands, the count, and — while
    /// the reader is typing — the first match at or after where the bar
    /// opened.
    ///
    /// The text is reached once and handed down, rather than each step asking
    /// the view for it again.
    private func runSearch(moving: Bool) {
        query = bar.query
        let text = self.text
        scanMatches(in: text)
        if moving, !query.isEmpty, let text,
           let match = match(in: text, from: anchor, forward: true) {
            select(match)
        } else {
            // An edit has not moved the reader: the match they were on is
            // still theirs if they are still standing on it.
            let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            currentMatch = matches.first { isStanding(on: $0, with: selection) }
        }
        applyHighlights()
        updateStatus()
    }

    /// The text as one `NSString`. `NSTextStorage` keeps an `NSString`-backed
    /// store, so this is a proxy rather than a copy — measured at 0.0002 ms
    /// on twenty megabytes, against 93 ms for one pass of a query that
    /// matches nothing. The cost is the search, never the reaching.
    private var text: NSString? { textView?.textStorage?.string as NSString? }

    /// Case- and diacritic-insensitive, the way the native bar searched: `cafe`
    /// finds `Café`.
    private static let options: NSString.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive,
    ]

    /// The first match at or after `location`, or before it going backwards,
    /// wrapping round the end of the text when there is none that way.
    private func match(in string: NSString, from location: Int, forward: Bool) -> NSRange? {
        guard !query.isEmpty else { return nil }
        let length = string.length
        let whole = NSRange(location: 0, length: length)
        let bound = min(max(0, location), length)
        let options = forward ? Self.options : Self.options.union(.backwards)
        let searched = forward
            ? NSRange(location: bound, length: length - bound)
            : NSRange(location: 0, length: bound)
        let found = string.range(of: query, options: options, range: searched)
        if found.location != NSNotFound { return found }
        let wrapped = string.range(of: query, options: options, range: whole)
        return wrapped.location == NSNotFound ? nil : wrapped
    }

    /// Every match from the top of the text, and no more than `highlightLimit`
    /// of them.
    private func scanMatches(in string: NSString?) {
        matches = []
        isCapped = false
        guard let string, !query.isEmpty else { return }
        matches = scan(string, limit: Self.highlightLimit)
        isCapped = matches.count >= Self.highlightLimit
    }

    /// The matches, up to `limit` of them.
    private func scan(_ string: NSString, limit: Int) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let length = string.length
        var found: [NSRange] = []
        var location = 0
        while location < length {
            let range = string.range(
                of: query, options: Self.options,
                range: NSRange(location: location, length: length - location)
            )
            guard range.location != NSNotFound else { break }
            found.append(range)
            if found.count >= limit { break }
            location = range.location + max(1, range.length)
        }
        return found
    }

    /// Lands on a match.
    ///
    /// While the bar is up the match is deliberately *not* selected. The
    /// keyboard is in the find field, so a selection in the text draws
    /// unemphasized — a flat grey that goes over the top of the band and
    /// hides the one thing saying where the reader is, and that colour is
    /// AppKit's, not ours to change. The caret goes to the match's start
    /// instead, nothing is selected, and `currentMatch` is what knows. The
    /// whole match is still brought into view, and closing the bar hands it
    /// over as a real selection.
    private func select(_ range: NSRange) {
        guard let textView else { return }
        currentMatch = range
        textView.setSelectedRange(
            bar.isShown ? NSRange(location: range.location, length: 0) : range
        )
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Replacing

    /// Return in the replace field, or the Replace button. It acts on the
    /// match being stood on and on nothing else — a reader who has clicked
    /// away is walked to the next match instead, which is what the native bar
    /// did rather than replacing wherever the caret had wandered to.
    ///
    /// The edit goes in the way a keystroke does: `shouldChangeText` before
    /// and `didChangeText` after, so undo, the dirty flag, the debounced save,
    /// the render and vim all see an ordinary edit rather than something done
    /// behind their backs.
    func replace() {
        guard let textView, textView.isEditable, !query.isEmpty else { return }
        guard let current = standingMatch else {
            step(forward: true)
            return
        }
        let replacement = bar.replacement
        guard textView.shouldChangeText(in: current, replacementString: replacement) else {
            return
        }
        textView.breakUndoCoalescing()
        textView.textStorage?.replaceCharacters(in: current, with: replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()

        // The next match is measured from the far side of what was just put
        // in, so replacing `a` with `aa` walks on rather than replacing its
        // own output for ever.
        currentMatch = nil
        anchor = current.location + (replacement as NSString).length
        let text = self.text
        scanMatches(in: text)
        if let text, let next = match(in: text, from: anchor, forward: true) {
            select(next)
        }
        applyHighlights()
        updateStatus()
    }

    /// ⌥Return in the replace field, or the All button. Every match in the
    /// note, not only the ones wearing a band — the cap is about what can be
    /// drawn between two keystrokes, and this is one deliberate action.
    ///
    /// One undo puts the lot back: the whole span the matches cover goes in
    /// as one edit, so there is one operation to undo rather than one per
    /// match.
    func replaceAll() {
        guard let textView, textView.isEditable, !query.isEmpty, let text else { return }
        // The span the matches cover, found with one pass from each end
        // rather than by enumerating every match — a hundred megabytes has no
        // reason to build a list here.
        let whole = NSRange(location: 0, length: text.length)
        let first = text.range(of: query, options: Self.options, range: whole)
        guard first.location != NSNotFound else { return }
        let last = text.range(of: query, options: Self.options.union(.backwards), range: whole)
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)

        let replacement = bar.replacement
        let replaced = text.substring(with: span).replacingOccurrences(
            of: query, with: replacement, options: Self.options,
            range: nil
        )
        guard textView.shouldChangeText(in: span, replacementString: replaced) else { return }
        let caret = textView.selectedRange().location
        textView.breakUndoCoalescing()
        let storage = textView.textStorage
        storage?.replaceCharacters(in: span, with: replaced)
        textView.didChangeText()
        textView.breakUndoCoalescing()

        // The reader is left where they were rather than at the end of a
        // sweep they never walked.
        currentMatch = nil
        let length = storage?.length ?? 0
        textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        anchor = min(caret, length)
        scanMatches(in: self.text)
        applyHighlights()
        updateStatus()
    }

    // MARK: - The bands

    private func applyHighlights() {
        guard let textView else { return }
        // The editor's own view keeps the book on what is lit, since vim's
        // search draws with the same mechanism and has to know it was taken
        // over. Every other text view is lit directly.
        if let editor = textView as? NotaTextView {
            editor.setSearchHighlights(matches, current: currentMatch)
        } else {
            textView.setFindHighlights(matches, current: currentMatch, alpha: Self.bandAlpha)
        }
    }

    private func clearHighlights() {
        guard let textView else { return }
        currentMatch = nil
        if let editor = textView as? NotaTextView {
            editor.clearSearchHighlights()
        } else {
            textView.setFindHighlights([], current: nil, alpha: Self.bandAlpha)
        }
        onHighlightsCleared?()
    }

    // MARK: - The count

    /// `"3 of 12"` while there are matches and the caret is on one of them,
    /// `"12 matches"` when an edit has moved them out from under it,
    /// `"No matches"` when there are none, and nothing at all while the field
    /// is empty. A file big enough to have stopped the scan says `2000+` for
    /// the total rather than a number it did not count.
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
        guard let current = currentMatch,
              let index = matches.firstIndex(where: { $0 == current })
        else {
            // An edit has moved the matches out from under the caret, so
            // there is no current one to count from — only how many there
            // are now.
            bar.setStatus(matches.count == 1 && !isCapped ? "1 match" : "\(total) matches")
            return
        }
        bar.setStatus("\(index + 1) of \(total)")
    }
}

// MARK: - Bands on any text view

extension NSTextView {
    /// A quiet band behind every range, and a louder one behind `current`,
    /// laid on with the layout manager's temporary attributes — beside the
    /// text rather than in it, so nothing here can reach the storage, and
    /// therefore neither the cache nor the file. An empty list and no current
    /// puts them all out.
    ///
    /// The band the matches not being stood on wear. In light mode it is
    /// the label colour at `alpha`, the faint grey it has always been. In
    /// dark mode that same wash — white over near-black — all but vanishes,
    /// so there the band is the find yellow itself, dimmed to a third: still
    /// plainly a match, still plainly not the one the reader is on, and the
    /// white text over it stays readable. One colour object per alpha, so a
    /// band can be compared with what painted it.
    static func quietFindBand(alpha: CGFloat) -> NSColor {
        if let cached = quietFindBands[alpha] { return cached }
        let band = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor.findHighlightColor.withAlphaComponent(0.3)
                : NSColor.labelColor.withAlphaComponent(alpha)
        }
        quietFindBands[alpha] = band
        return band
    }

    private static var quietFindBands: [CGFloat: NSColor] = [:]

    /// `current` is the match ⌘F is standing on. Vim's `'hlsearch'` has no
    /// such thing and passes `nil`, which leaves every match quiet.
    func setFindHighlights(_ ranges: [NSRange], current: NSRange?, alpha: CGFloat) {
        guard let layoutManager, let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        let quiet = NSTextView.quietFindBand(alpha: alpha)
        for range in ranges where range != current {
            let clamped = NSIntersectionRange(range, whole)
            guard clamped.length > 0 else { continue }
            layoutManager.addTemporaryAttributes(
                [.backgroundColor: quiet], forCharacterRange: clamped
            )
        }
        guard let current else { return }
        let clamped = NSIntersectionRange(current, whole)
        guard clamped.length > 0 else { return }
        // `findHighlightColor` is AppKit's own find yellow, and it is the
        // same light colour in both appearances — so the text on it is
        // spelled out black rather than left as `labelColor`, which turns
        // white in dark mode and disappears into the band.
        layoutManager.addTemporaryAttributes([
            .backgroundColor: NSColor.findHighlightColor,
            .foregroundColor: NSColor.black,
        ], forCharacterRange: clamped)
    }
}
