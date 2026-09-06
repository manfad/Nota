import AppKit

extension NSPasteboard.PasteboardType {
    /// Nota's own flavour: the note's plain text, tokens and all. Copying
    /// inside Nota uses this, so an image moves between tabs by reference and
    /// no second copy of the file is ever made.
    static let notaNote = NSPasteboard.PasteboardType("com.manfad.nota.note")

    /// The same flavour under the app's old name. Nothing writes it any more,
    /// but a copy taken before the rename can still be sitting on the board,
    /// so reading accepts it.
    static let legacyJotNote = NSPasteboard.PasteboardType("com.manfad.jot.note")
}

/// A plain-text view that also understands images.
///
/// Formatting stays off — no bold, no font changes, `isRichText` is still
/// false — but attachments are allowed through, and every paste, drop and
/// copy is routed so that what lands in the storage is an attachment and what
/// lands on disk is a token.
final class NotaTextView: NSTextView {

    /// Where images are imported to and read back from.
    var assets: AssetStore?
    /// The editor's current typing attributes, from `Preferences`.
    var attributesProvider: (() -> [NSAttributedString.Key: Any])?
    /// A chip was clicked; the character index of the attachment.
    var onChipClick: ((Int) -> Void)?
    /// Text files were dropped on the editor. They belong in tabs of their
    /// own, which only the window controller can make.
    var onOpenFiles: (([URL]) -> Void)?

    /// Vim's first refusal on a key press. Returning true swallows it.
    var vimKeyHandler: ((NSEvent) -> Bool)?

    /// The caret's shape. `.bar` is AppKit's own, and what plain Nota uses.
    var vimCursorStyle: VimCursorStyle = .bar {
        didSet {
            guard oldValue != vimCursorStyle else { return }
            needsDisplay = true
        }
    }

    /// Settings › Editor › "Highlight current line". One of two inputs to
    /// `showsCursorLine`; see it for why they are kept apart.
    var highlightsCurrentLine = false {
        didSet {
            guard oldValue != highlightsCurrentLine else { return }
            refreshCursorLine()
        }
    }

    /// Vim's `set cursorline`. The other input to `showsCursorLine`.
    var vimCursorLine = false {
        didSet {
            guard oldValue != vimCursorLine else { return }
            refreshCursorLine()
        }
    }

    /// The band actually drawn under the caret's line: on when either the
    /// preference or vim's `:set cursorline` asks for it, so neither can turn
    /// off a band the other one wants. Read-only — tests read it, but only
    /// `highlightsCurrentLine` and `vimCursorLine` ever set it.
    private(set) var showsCursorLine = false

    private func refreshCursorLine() {
        let value = highlightsCurrentLine || vimCursorLine
        guard value != showsCursorLine else { return }
        showsCursorLine = value
        needsDisplay = true
    }

    /// Read order. The first type the pasteboard also carries wins, so a copy
    /// from Nota never degrades to RTF or bare text.
    ///
    /// The web flavours sit at the back, ahead of plain text alone: a browser
    /// offers no RTF, so they are the only way a picture copied off a page
    /// arrives at all — and they are taken only when there really is one, so
    /// a text-only copy still lands as the `.string` it always did.
    private static let readPriority: [NSPasteboard.PasteboardType] =
        [.notaNote, .legacyJotNote, .fileURL, .png, .tiff, .rtfd, .rtf]
        + HTMLClipboard.types + [.string]

    private static let dropPriority: [NSPasteboard.PasteboardType] = [
        .notaNote, .legacyJotNote, .fileURL, .png, .tiff, .rtfd,
    ]

    private var attributes: [NSAttributedString.Key: Any] {
        attributesProvider?() ?? [.font: NSFont.systemFont(ofSize: 13)]
    }

    // MARK: - Keys

    /// Vim gets first refusal, and only ever on events without ⌘ — which is
    /// what keeps every menu shortcut working in every mode. `performKey`
    /// `Equivalent` is deliberately left alone for the same reason.
    override func keyDown(with event: NSEvent) {
        if vimKeyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: - Find

    /// The editor's ⌘F bar. Find…, Find Next, Find Previous and Use Selection
    /// for Find are nil-targeted `performTextFinderAction:` menu items, so
    /// they arrive at whatever text view has the keyboard — which is how the
    /// same four keys search the editor here and the rendered page in reading
    /// mode, without either knowing about the other.
    weak var findSession: TextFindSession?

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession?.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let enabled = validateLineOperation(item) { return enabled }
        guard item.action == #selector(NSTextView.performTextFinderAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return TextFindSession.handles(action)
    }

    // MARK: - Line operations

    /// The front note's line table — where every hard line starts, folded
    /// forward one edit at a time by the note itself. The line keys ask it
    /// rather than walking the text, so ⌥↓ in a 100 MB log costs the two
    /// lines it swaps. An editor with no note behind it (a bare view in a
    /// test) works the table out from its own storage instead.
    var lineIndexProvider: (() -> LineIndex?)?

    /// How the file being edited is spelled — the one thing ⌘/ needs, since
    /// what a line is commented with is the author's own word for what the
    /// file is.
    var fileExtensionProvider: (() -> String?)?

    /// Whether the line keys are the editor's to run at all. Plain Nota:
    /// always. Vim mode: only while inserting, since everywhere else those
    /// keys are vim's own and the menu must stand aside for them.
    var lineOperationsAllowed: (() -> Bool)?

    private var lineIndex: LineIndex {
        if let index = lineIndexProvider?() { return index }
        return LineIndex(textStorage?.mutableString ?? NSMutableString())
    }

    private var lineOperationsEnabled: Bool {
        isEditable && (lineOperationsAllowed?() ?? true)
    }

    /// What the Edit menu's line items are validated on: this editor is the
    /// one holding the keyboard, its note can be edited, and vim is not
    /// holding the keys.
    var canRunLineOperations: Bool {
        lineOperationsEnabled && window?.firstResponder === self
    }

    /// The token this file's lines are commented with, or nil where the
    /// format has none and ⌘/ is greyed out.
    private var lineCommentToken: String? {
        guard let spelling = fileExtensionProvider?(), !spelling.isEmpty else { return nil }
        return LineOperations.commentToken(forExtension: spelling)
    }

    @objc func moveLinesUp(_ sender: Any?) { runLineOperation(LineOperations.moveUp) }

    @objc func moveLinesDown(_ sender: Any?) { runLineOperation(LineOperations.moveDown) }

    @objc func duplicateLines(_ sender: Any?) { runLineOperation(LineOperations.duplicate) }

    @objc func indentLines(_ sender: Any?) { runLineOperation(LineOperations.indent) }

    @objc func outdentLines(_ sender: Any?) { runLineOperation(LineOperations.outdent) }

    /// ⌘D is two hands in one key: with nothing selected it duplicates the
    /// line, and with something selected it reaches for the next place the
    /// same characters appear.
    @objc func duplicateOrSelectNext(_ sender: Any?) {
        guard lineOperationsEnabled else { return }
        if selectedRange().length > 0 {
            selectNextOccurrence()
        } else {
            duplicateLines(sender)
        }
    }

    @objc func toggleLineComment(_ sender: Any?) {
        guard let token = lineCommentToken else { return }
        runLineOperation { text, index, selection in
            LineOperations.toggleComment(
                text: text, index: index, selection: selection, token: token
            )
        }
    }

    /// The next occurrence joins the selection rather than replacing it —
    /// press again for the one after, round the end of the note and back.
    /// Once every occurrence is in hand there is nothing left to add and the
    /// key does nothing.
    private func selectNextOccurrence() {
        guard lineOperationsEnabled, let storage = textStorage else { return }
        let text = storage.mutableString
        let ranges = selectedRanges.map(\.rangeValue).sorted { $0.location < $1.location }
        guard let first = ranges.first, first.length > 0 else { return }
        let needle = text.substring(with: first)
        let from = ranges.map { NSMaxRange($0) }.max() ?? NSMaxRange(first)
        guard let found = LineOperations.nextOccurrence(
            of: needle, in: text, from: from, skipping: ranges
        ) else { return }
        selectedRanges = (ranges + [found])
            .sorted { $0.location < $1.location }.map { NSValue(range: $0) }
        scrollRangeToVisible(found)
    }

    private func runLineOperation(
        _ operation: (NSString, LineIndex, NSRange) -> LineOperations.Edit?
    ) {
        guard lineOperationsEnabled, let storage = textStorage else { return }
        guard let edit = operation(storage.mutableString, lineIndex, selectedRange()) else { return }
        apply(edit)
    }

    /// One press, one edit, one undo step. The pieces that are the note's own
    /// characters are lifted out of the storage with their attributes on —
    /// which is what carries a picture through a line that moves — and the
    /// lot goes in as a single replacement through `shouldChangeText` /
    /// `didChangeText`, so undo, the dirty flag, the save and vim all see one
    /// edit.
    private func apply(_ edit: LineOperations.Edit) {
        guard let storage = textStorage else { return }
        let replacement = NSMutableAttributedString()
        for piece in edit.pieces {
            switch piece {
            case .copy(let range):
                replacement.append(storage.attributedSubstring(from: range))
            case .text(let value):
                replacement.append(NSAttributedString(string: value, attributes: attributes))
            }
        }
        guard shouldChangeText(in: edit.range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: edit.range, with: replacement)
        didChangeText()

        let length = storage.length
        let selection = edit.selection.map { range -> NSValue in
            let location = max(0, min(range.location, length))
            return NSValue(range: NSRange(
                location: location, length: max(0, min(range.length, length - location))
            ))
        }
        selectedRanges = selection
        scrollRangeToVisible(selectedRange())
    }

    /// Tab and ⇧Tab with more than one line in hand indent and outdent the
    /// block; on a single line Tab is still the tab character AppKit puts in.
    override func insertTab(_ sender: Any?) {
        guard lineOperationsEnabled, selectionSpansLines else {
            super.insertTab(sender)
            return
        }
        indentLines(sender)
    }

    /// ⇧Tab outdents the caret's line even with nothing selected — the
    /// mirror of a Tab at the line's start — since a backtab has nothing
    /// else it could mean; a selection across lines outdents them all.
    override func insertBacktab(_ sender: Any?) {
        guard lineOperationsEnabled else {
            super.insertBacktab(sender)
            return
        }
        outdentLines(sender)
    }

    /// Return at the end of a list item opens the next one — `2.` after `1.`,
    /// `b)` after `a)`, a fresh `- [ ]` after a task — and on an item with
    /// nothing typed on it takes the marker off instead, which is how a list
    /// is ended. `ListContinuation` works out what the key means; this only
    /// puts the answer in, as one `shouldChangeText` edit so that undo, the
    /// dirty flag, the save and vim all see a single step.
    ///
    /// It stands aside for ⇧Return and ⌥Return, which are the plain newline,
    /// for a selection with anything in it, for ⌘D's extra carets, and — like
    /// every other key here — for every vim mode but insert.
    override func insertNewline(_ sender: Any?) {
        if continueList() { return }
        super.insertNewline(sender)
    }

    private func continueList() -> Bool {
        guard lineOperationsEnabled, !plainNewlineWanted, selectedRanges.count == 1,
              let storage = textStorage,
              let edit = ListContinuation.edit(
                  forReturnIn: storage.mutableString, at: selectedRange()
              ),
              shouldChangeText(in: edit.range, replacementString: edit.text)
        else { return false }
        storage.replaceCharacters(
            in: edit.range, with: NSAttributedString(string: edit.text, attributes: attributes)
        )
        didChangeText()
        setSelectedRange(NSRange(location: min(edit.caret, storage.length), length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// ⇧Return and ⌥Return: whatever the line says, the newline is plain.
    private var plainNewlineWanted: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return !event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.shift, .option])
    }

    private var selectionSpansLines: Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let lines = LineOperations.lines(touching: range, in: lineIndex)
        return lines.lowerBound != lines.upperBound
    }

    /// The carets a multi-range edit left behind. AppKit keeps a
    /// discontiguous selection only while every range has something in it:
    /// set two empty ones and it folds them into the first. So the editor
    /// remembers them itself, and the next character typed still goes to all
    /// of them — which is the whole point of ⌘D's second range. Any other
    /// move of the selection puts them down.
    private var multiCarets: [NSRange]?
    private var isRestoringMultiCarets = false

    /// The ranges a typed character means: every selected range while there
    /// is more than one, and otherwise the carets the last multi-range edit
    /// left, as long as the selection is still standing on one of them.
    private func typingRanges(for replacementRange: NSRange) -> [NSRange] {
        let meansTheSelection = replacementRange.location == NSNotFound
            || NSEqualRanges(replacementRange, selectedRange())
        guard meansTheSelection else { return [] }
        let selected = selectedRanges.map(\.rangeValue).sorted { $0.location < $1.location }
        if selected.count > 1 { return selected }
        if let carets = multiCarets, carets.count > 1, let one = selected.first, one.length == 0,
           carets.contains(where: { NSEqualRanges($0, one) }) {
            return carets
        }
        return selected
    }

    /// AppKit keeps more than one selected range but types into only the
    /// first of them, so ⌘D's second range would sit there doing nothing.
    /// The editor types into all of them: back to front, so the earlier
    /// ranges keep their places, in one undo step, each left as a caret after
    /// what it took.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let ranges = typingRanges(for: replacementRange)
        guard ranges.count > 1, let storage = textStorage else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard shouldChangeText(
            inRanges: ranges.map { NSValue(range: $0) },
            replacementStrings: Array(repeating: typed, count: ranges.count)
        ) else { return }

        let attributed = NSAttributedString(string: typed, attributes: attributes)
        for range in ranges.reversed() {
            storage.replaceCharacters(in: range, with: attributed)
        }
        didChangeText()

        var carets: [NSRange] = []
        var delta = 0
        for range in ranges {
            carets.append(NSRange(
                location: range.location + delta + attributed.length, length: 0
            ))
            delta += attributed.length - range.length
        }
        // The last one is the one on screen — the place the next key that is
        // not a character will act — and the rest are remembered.
        isRestoringMultiCarets = true
        selectedRanges = [NSValue(range: carets[carets.count - 1])]
        isRestoringMultiCarets = false
        multiCarets = carets
    }

    /// The Edit menu's line items are nil-targeted, so each is offered only
    /// when this editor is the responder that would run it: the moment the
    /// find field, the tab strip or a rendered page has the keyboard they all
    /// grey out, and so do they in every vim mode but insert. ⌘/ needs one
    /// thing more — a format whose lines can be commented at all.
    private func validateLineOperation(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(moveLinesUp(_:)), #selector(moveLinesDown(_:)),
             #selector(duplicateLines(_:)), #selector(indentLines(_:)),
             #selector(outdentLines(_:)):
            return canRunLineOperations
        case #selector(duplicateOrSelectNext(_:)):
            // One key, two jobs: the item says which of them it is about to do.
            (item as? NSMenuItem)?.title = selectedRange().length > 0
                ? "Select Next Occurrence" : "Duplicate Line"
            return canRunLineOperations
        case #selector(toggleLineComment(_:)):
            return canRunLineOperations && lineCommentToken != nil
        default:
            return nil
        }
    }

    // MARK: - The caret

    /// Normal and visual modes draw a block over the character under the
    /// caret; replace draws half of one. Insert keeps AppKit's bar.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vimCursorStyle != .bar else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard flag else {
            // Erasing means redrawing the text the last block was covering —
            // the block that was drawn, not one measured at wherever the
            // caret is now.
            super.setNeedsDisplay(drawnBlockRect, avoidAdditionalLayout: true)
            return
        }
        let block = blockRect(for: rect)
        drawnBlockRect = block
        VimCursorDrawing.fillColor.setFill()
        block.fill()
    }

    /// The cursorline band, under everything: `drawBackground` runs before the
    /// glyphs and before the selection highlight, so the text reads through it
    /// and a selection still draws over the top.
    ///
    /// `labelColor` at 4% rather than a colour of its own — the same
    /// monochrome rule the mode badge keeps.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard showsCursorLine else { return }
        let band = lineBand(for: NSRange(location: selectedRange().location, length: 0), padding: 0)
        guard band.intersects(rect) else { return }
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        band.fill()
    }

    /// AppKit invalidates a caret-shaped sliver, and it does so for the old
    /// caret after the selection has already moved. A block is wider than
    /// that sliver, and the old character may be wider than the new one, so
    /// the invalidation has to cover the block that was actually drawn.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if vimCursorStyle != .bar {
            if !drawnBlockRect.isEmpty, rect.intersects(drawnBlockRect) {
                rect = rect.union(drawnBlockRect)
            } else if !isMeasuringCaret {
                // Measuring asks the layout manager for a glyph's bounds,
                // which can lay text out and ask for another redraw; the
                // flag keeps that from turning into a loop.
                isMeasuringCaret = true
                rect.size.width = max(rect.width, caretCharacterWidth + 1)
                isMeasuringCaret = false
            }
        }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    /// Whatever else AppKit chooses to invalidate, a moved caret always
    /// repaints the block it left behind — and a moved visual selection
    /// repaints every line it touched, edge to edge. A linewise selection
    /// highlights its newline out to the container's edge, and AppKit's own
    /// invalidation of that is a hair short once line spacing is involved,
    /// which leaves a one-point sliver behind on every `j` and `k`.
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        // Any move of the selection that is not the multi-range edit putting
        // its own carets back is the end of them.
        if !isRestoringMultiCarets { multiCarets = nil }
        let previousBlock = drawnBlockRect
        let previousSelection = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The band moves with the caret, so both lines it was and is on have
        // to be repainted whatever shape the caret is.
        if showsCursorLine {
            for range in [previousSelection, selectedRange()] {
                super.setNeedsDisplay(
                    lineBand(for: NSRange(location: range.location, length: 0)),
                    avoidAdditionalLayout: false
                )
            }
        }
        guard vimCursorStyle != .bar else { return }
        if !previousBlock.isEmpty {
            super.setNeedsDisplay(previousBlock, avoidAdditionalLayout: true)
        }
        for range in [previousSelection, selectedRange()] where range.length > 0 {
            super.setNeedsDisplay(lineBand(for: range), avoidAdditionalLayout: false)
        }
    }

    /// The full-width band of the lines a range sits on. Invalidating takes a
    /// couple of points of padding — a highlight spills into the line spacing
    /// below — where drawing takes the band exactly as it is laid out.
    private func lineBand(for range: NSRange, padding: CGFloat = 2) -> NSRect {
        guard let layoutManager else { return bounds }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0, glyphRange.location < glyphCount else { return bounds }

        var band = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let last = min(NSMaxRange(glyphRange), glyphCount - 1)
        band = band.union(layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil))
        if NSMaxRange(glyphRange) >= glyphCount {
            band = band.union(layoutManager.extraLineFragmentRect)
        }
        band.origin.x = 0
        band.size.width = bounds.width
        band.origin.y += textContainerOrigin.y
        return band.insetBy(dx: 0, dy: -padding)
    }

    private var isMeasuringCaret = false
    /// The block most recently painted, in view coordinates.
    private var drawnBlockRect: NSRect = .zero

    private func blockRect(for rect: NSRect) -> NSRect {
        VimCursorDrawing.rect(
            insertionPoint: rect, characterWidth: caretCharacterWidth, style: vimCursorStyle
        )
    }

    /// The width of the character the caret is sitting on — the width of a
    /// space at the end of a line, where there is nothing to sit on.
    private var caretCharacterWidth: CGFloat {
        let font = self.font ?? .systemFont(ofSize: 13)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        guard let layoutManager, let container = textContainer, let storage = textStorage
        else { return spaceWidth }

        let location = selectedRange().location
        guard location < storage.length else { return spaceWidth }
        let string = storage.string as NSString
        guard string.character(at: location) != 0x0A else { return spaceWidth }

        let characterRange = string.rangeOfComposedCharacterSequence(at: location)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange, actualCharacterRange: nil
        )
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        return bounds.width > 0 ? bounds.width : spaceWidth
    }

    // MARK: - Search highlights

    /// `'hlsearch'`: a quiet band behind every match.
    ///
    /// These are the layout manager's *temporary* attributes, which live
    /// beside the text rather than in it — so a highlight can never reach the
    /// text storage, and therefore never the cache, the pasteboard or the
    /// file. Monochrome, like everything else vim draws here.
    /// ⌘F's bar draws with the same mechanism, so the two share one band and
    /// one book of what is lit: whichever searched last owns the highlights,
    /// and closing the find bar hands them back to vim.
    func setSearchHighlights(_ ranges: [NSRange]) {
        setSearchHighlights(ranges, current: nil)
    }

    /// `current` is ⌘F's own — the match the reader is standing on, which
    /// wears the find yellow while the rest stay quiet. Vim has no such
    /// thing and passes nothing.
    ///
    /// The book covers every lit range, the current match included even when
    /// it fell outside a capped list, so a clear puts all of it down — the
    /// black text laid over the yellow with it.
    func setSearchHighlights(_ ranges: [NSRange], current: NSRange?) {
        setFindHighlights(ranges, current: current, alpha: 0.12)
        if let current, !ranges.contains(current) {
            highlightedRanges = ranges + [current]
        } else {
            highlightedRanges = ranges
        }
    }

    func clearSearchHighlights() {
        guard !highlightedRanges.isEmpty else { return }
        setFindHighlights([], current: nil, alpha: 0.12)
        highlightedRanges = []
    }

    /// What is lit up, for the tests and for a tab switch to put down again.
    private(set) var highlightedRanges: [NSRange] = []

    // MARK: - Chip clicks

    /// A single click on an `Image N` chip selects the picture — a real
    /// length-1 selection over the attachment, the way an inline image
    /// selects in Notes — so ⌘C copies it and ⌫ or typing replaces it. A
    /// caret next to the chip would look selected and copy nothing, since
    /// `writeSelection` has no range to write.
    ///
    /// `super` goes first so AppKit's mouse-tracking loop still runs: a drag
    /// out of a chip, a ⇧-click on one to extend a selection over its line,
    /// and double- and triple-clicks all keep the behaviour they have
    /// everywhere else. Only a press that ends with the caret still collapsed
    /// was a plain click on the chip.
    override func mouseDown(with event: NSEvent) {
        let chip = event.clickCount == 1 ? chipCharacterIndex(for: event) : nil
        super.mouseDown(with: event)
        guard let chip else { return }
        selectClickedChip(at: chip)
    }

    /// What a plain click on the chip at `index` leaves behind. Split out from
    /// `mouseDown` because AppKit's tracking loop cannot be driven from a test.
    func selectClickedChip(at index: Int) {
        // A drag or a ⇧-click already made a selection; that one is meant.
        guard selectedRange().length == 0 else { return }
        // Vim's block caret sits *on* a character rather than between two, so
        // there the chip keeps a caret and the block draws over it; plain Nota
        // selects the chip itself, which lights the same one thumbnail.
        let range = vimCursorStyle == .bar
            ? NSRange(location: index, length: 1)
            : NSRange(location: index, length: 0)
        setSelectedRange(range)
        onChipClick?(index)
    }

    /// The character index of a chip under the pointer, if the click really
    /// landed on the glyph and not merely on the same line.
    private func chipCharacterIndex(for event: NSEvent) -> Int? {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0
        else { return nil }

        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

        let glyphIndex = layoutManager.glyphIndex(
            for: inContainer, in: container, fractionOfDistanceThroughGlyph: nil
        )
        let bounds = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container
        )
        guard bounds.contains(inContainer) else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < storage.length,
              storage.attribute(.attachment, at: characterIndex, effectiveRange: nil)
                  is NotaImageAttachment
        else { return nil }
        return characterIndex
    }

    // MARK: - Reading

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.readPriority
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        Self.readPriority
    }

    /// The board a paste is being read from, so the HTML rule below can look
    /// at the bytes: `preferredPasteboardType` is handed a list of type names
    /// and nothing else. A paste always comes from the general pasteboard,
    /// which is what the fallback is.
    private var pasteboardBeingRead: NSPasteboard?

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        pasteboardBeingRead = pboard
        defer { pasteboardBeingRead = nil }
        return super.readSelection(from: pboard)
    }

    /// `NSTextView` asks this which flavour to take; the default picks by the
    /// pasteboard's order, and we want ours.
    override func preferredPasteboardType(
        from availableTypes: [NSPasteboard.PasteboardType],
        restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?
    ) -> NSPasteboard.PasteboardType? {
        let allowed = allowedTypes ?? Self.readPriority
        for type in Self.readPriority
        where allowed.contains(type) && availableTypes.contains(type) {
            // HTML is only worth taking for the pictures in it. Without one,
            // the importer would cost the copy its lists, its code blocks and
            // its whitespace to gain nothing, so the search carries on down
            // to the plain text.
            if HTMLClipboard.types.contains(type), !htmlCarriesImage(type) { continue }
            return type
        }
        return super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
    }

    private func htmlCarriesImage(_ type: NSPasteboard.PasteboardType) -> Bool {
        let pboard = pasteboardBeingRead ?? .general
        guard let data = pboard.data(forType: type),
              let payload = HTMLClipboard.payload(from: data, type: type)
        else { return false }
        return HTMLClipboard.containsImage(payload.html)
    }

    override func readSelection(
        from pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        switch type {
        case .notaNote, .legacyJotNote:
            guard let text = pboard.string(forType: type) else { return false }
            return insert(render(text))

        case .fileURL:
            let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
                .filter(AssetStore.isImageFile)
            let ids = urls.compactMap { assets?.importFile(at: $0) }
            guard !ids.isEmpty else { return super.readSelection(from: pboard, type: type) }
            return insert(render(ids.map(NoteText.token(for:)).joined()))

        case .png, .tiff:
            guard let data = pboard.data(forType: type),
                  let id = assets?.importImageData(
                      data, preferredExtension: type == .png ? "png" : nil
                  )
            else { return false }
            return insert(render(NoteText.token(for: id)))

        case .rtfd, .rtf:
            guard let data = pboard.data(forType: type) else { return false }
            let foreign = type == .rtfd
                ? NSAttributedString(rtfd: data, documentAttributes: nil)
                : NSAttributedString(rtf: data, documentAttributes: nil)
            guard let foreign else { return false }
            return insert(importForeign(foreign))

        case .html, .webArchive, .legacyWebArchive:
            guard let data = pboard.data(forType: type),
                  let payload = HTMLClipboard.payload(from: data, type: type),
                  let foreign = HTMLClipboard.attributedString(from: payload)
            else { return super.readSelection(from: pboard, type: type) }
            return insert(importHTML(foreign, from: payload))

        case .string:
            guard let text = pboard.string(forType: .string) else { return false }
            // Tokens pasted back as text become images again, which is what
            // happens when a Nota file is opened, so the two agree.
            return insert(render(text))

        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    // MARK: - Writing

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.notaNote]
        // Only offer RTFD when there is actually an image to carry, so
        // copying prose into another app stays unstyled.
        if selectionContainsImage { types.append(.rtfd) }
        // A terminal, a browser or Slack reads none of the flavours above —
        // only a bare picture — so one goes on the board too. After RTFD, so
        // Nota and the rich-text apps still take the flavour that keeps the
        // words around the image.
        if soleSelectedImageID != nil { types += [.png, .tiff] }
        types.append(.string)
        return types
    }

    override func writeSelection(
        to pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard let storage = textStorage else { return false }
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let selection = storage.attributedSubstring(from: range)

        switch type {
        case .notaNote:
            return pboard.setString(NoteText.serialize(selection), forType: .notaNote)

        case .rtfd:
            guard let data = rtfdData(for: selection) else { return false }
            return pboard.setData(data, forType: .rtfd)

        case .png, .tiff:
            guard let id = soleSelectedImageID,
                  let data = type == .png ? assets?.pngData(for: id) : assets?.tiffData(for: id)
            else { return false }
            return pboard.setData(data, forType: type)

        case .string:
            let serialized = NoteText.serialize(selection)
            let plain = Preferences.shared.plainTextImageStyle == .marker
                ? NoteText.placeholdingTokens(serialized)
                : NoteText.pathTokens(serialized, assets: assets)
            return pboard.setString(plain, forType: .string)

        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    private var selectionContainsImage: Bool { !selectedImageIDs.isEmpty }

    /// The assets behind the chips in the selection, in document order.
    private var selectedImageIDs: [String] {
        guard let storage = textStorage else { return [] }
        let range = selectedRange()
        guard range.length > 0 else { return [] }
        var ids: [String] = []
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let nota = value as? NotaImageAttachment { ids.append(nota.assetID) }
        }
        return ids
    }

    /// The one picture a `public.png` could mean. Two chips in the selection
    /// leave that ambiguous — a single image flavour can only carry one — so
    /// those copies go out as text and RTFD alone. Words around the chip are
    /// welcome: copying a whole line still pastes the picture into a terminal.
    private var soleSelectedImageID: String? {
        let ids = selectedImageIDs
        guard ids.count == 1, let id = ids.first, assets?.exists(id) == true else { return nil }
        return id
    }

    /// Swaps each Nota attachment for a stock one carrying the asset's bytes,
    /// which is what lets Notes, Mail and Pages show the image.
    private func rtfdData(for selection: NSAttributedString) -> Data? {
        let converted = NSMutableAttributedString(attributedString: selection)
        let full = NSRange(location: 0, length: converted.length)

        var replacements: [(NSRange, NSTextAttachment)] = []
        converted.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let nota = value as? NotaImageAttachment,
                  let data = assets?.data(for: nota.assetID) else { return }
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = nota.assetID
            let attachment = NSTextAttachment()
            attachment.fileWrapper = wrapper
            replacements.append((range, attachment))
        }
        for (range, attachment) in replacements {
            converted.addAttribute(.attachment, value: attachment, range: range)
        }
        return converted.rtfd(from: full, documentAttributes: [:])
    }

    // MARK: - Dragging

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        claimsDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        claimsDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    /// A drag can carry both kinds of file at once: the images come in as
    /// chips where the caret is, the text files open as tabs beside this one.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let openable = Self.openableFiles(on: sender.draggingPasteboard)
        if !openable.isEmpty { onOpenFiles?(openable) }
        guard let type = droppableType(on: sender) else {
            return openable.isEmpty ? super.performDragOperation(sender) : true
        }
        return readSelection(from: sender.draggingPasteboard, type: type) || !openable.isEmpty
    }

    private func claimsDrag(_ sender: NSDraggingInfo) -> Bool {
        droppableType(on: sender) != nil
            || !Self.openableFiles(on: sender.draggingPasteboard).isEmpty
    }

    /// Only claims a drag that actually carries an image; text drags fall
    /// through to `NSTextView`'s own handling.
    private func droppableType(on sender: NSDraggingInfo) -> NSPasteboard.PasteboardType? {
        let pboard = sender.draggingPasteboard
        let available = pboard.types ?? []
        for type in Self.dropPriority where available.contains(type) {
            if type == .fileURL {
                let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
                guard urls.contains(where: AssetStore.isImageFile) else { continue }
            }
            return type
        }
        return nil
    }

    /// The dropped files that open in a tab rather than landing in one as a
    /// picture. Extensions are no use on their own — a `.toml` has no type at
    /// all — so `Note.isOpenable` decides, by the system's type where there is
    /// one and by the bytes where not, and a PDF is openable the way text is.
    ///
    /// A drawing is one of these rather than a picture: an `.svg` is text
    /// that opens in a tab with the drawing beside it, never a chip. That is
    /// `AssetStore.isImageFile`'s word, and it is the same word `Note` gives.
    static func openableFiles(on pboard: NSPasteboard) -> [URL] {
        guard pboard.types?.contains(.fileURL) == true else { return [] }
        let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.filter { !AssetStore.isImageFile($0) && Note.isOpenable($0) }
    }

    // MARK: - Insertion

    private func render(_ plain: String) -> NSAttributedString {
        NoteText.render(plain, attributes: attributes, assets: assets)
    }

    /// What the markup behind a foreign string says one of its pictures is.
    ///
    /// The HTML importer never admits that it failed: an `<img>` it could not
    /// load comes back as an attachment all the same, carrying its own
    /// broken-picture icon. So where the markup is there to be read, it is
    /// the one that decides — and a source that resolves to nothing means no
    /// picture rather than an icon of one.
    private enum ForeignImage {
        /// Nothing is known about it; the attachment's own bytes are all
        /// there is. Every RTF and RTFD paste is this.
        case fromAttachment
        /// The markup names the picture, and these are its bytes.
        case bytes(HTMLClipboard.ImageBytes)
        /// The markup names it and there is no way to get it.
        case unavailable
    }

    /// Turns an attributed string from another app into Nota's own shape:
    /// attachments become assets, everything else becomes unstyled text.
    ///
    /// `imageSource` is asked about each attachment by its position among the
    /// others, which is the only thing the markup and the imported string can
    /// be matched on.
    private func importForeign(
        _ foreign: NSAttributedString,
        imageSource: (Int) -> ForeignImage = { _ in .fromAttachment }
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = foreign.string as NSString
        let full = NSRange(location: 0, length: foreign.length)
        var imageIndex = 0

        foreign.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                let index = imageIndex
                imageIndex += 1
                guard let id = assetID(for: attachment, as: imageSource(index)) else { return }
                result.append(render(NoteText.token(for: id)))
            } else {
                result.append(NSAttributedString(
                    string: source.substring(with: range), attributes: attributes
                ))
            }
        }
        return result
    }

    private func assetID(for attachment: NSTextAttachment, as image: ForeignImage) -> String? {
        switch image {
        case .fromAttachment:
            return assets?.importForeignAttachment(attachment)
        case .bytes(let bytes):
            // The attachment is still the fallback for bytes the store will
            // not take — an SVG, say, which the importer can draw and the
            // asset store cannot read.
            return assets?.importImageData(bytes.data, preferredExtension: bytes.preferredExtension)
                ?? assets?.importForeignAttachment(attachment)
        case .unavailable:
            return nil
        }
    }

    /// A fragment copied off a web page. Each picture comes from the markup's
    /// own `<img src>` list — inline `data:` bytes, a web archive's
    /// subresource, or the URL fetched — and a source that resolves to none
    /// of those drops that one picture and keeps the words around it.
    private func importHTML(
        _ foreign: NSAttributedString, from payload: HTMLClipboard.Payload
    ) -> NSAttributedString {
        let sources = HTMLClipboard.imageSources(in: payload.html)
        let trimmed = HTMLClipboard.trimmingTrailingWhitespace(foreign)
        return importForeign(trimmed) { index in
            // More attachments than sources means the two lists have come
            // apart; the attachment is the better guess there.
            guard index < sources.count else { return .fromAttachment }
            guard let bytes = HTMLClipboard.imageBytes(forSource: sources[index], in: payload)
            else { return .unavailable }
            return .bytes(bytes)
        }
    }

    /// Goes through `shouldChangeText`/`didChangeText` so the edit is undoable
    /// on the current tab's undo manager and the delegate hears about it —
    /// `insertText` would drop the attachment, since the view is plain text.
    @discardableResult
    private func insert(_ attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0, let storage = textStorage else { return false }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return false }
        storage.replaceCharacters(in: range, with: attributed)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
        return true
    }
}
