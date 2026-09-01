import AppKit

extension NSPasteboard.PasteboardType {
    /// Jot's own flavour: the note's plain text, tokens and all. Copying
    /// inside Jot uses this, so an image moves between tabs by reference and
    /// no second copy of the file is ever made.
    static let jotNote = NSPasteboard.PasteboardType("com.manfad.jot.note")
}

/// A plain-text view that also understands images.
///
/// Formatting stays off — no bold, no font changes, `isRichText` is still
/// false — but attachments are allowed through, and every paste, drop and
/// copy is routed so that what lands in the storage is an attachment and what
/// lands on disk is a token.
final class JotTextView: NSTextView {

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

    /// The caret's shape. `.bar` is AppKit's own, and what plain Jot uses.
    var vimCursorStyle: VimCursorStyle = .bar {
        didSet {
            guard oldValue != vimCursorStyle else { return }
            needsDisplay = true
        }
    }

    /// `set cursorline`: a quiet full-width band under the caret's line.
    var showsCursorLine = false {
        didSet {
            guard oldValue != showsCursorLine else { return }
            needsDisplay = true
        }
    }

    /// Read order. The first type the pasteboard also carries wins, so a copy
    /// from Jot never degrades to RTF or bare text.
    private static let readPriority: [NSPasteboard.PasteboardType] = [
        .jotNote, .fileURL, .png, .tiff, .rtfd, .rtf, .string,
    ]

    private static let dropPriority: [NSPasteboard.PasteboardType] = [
        .jotNote, .fileURL, .png, .tiff, .rtfd,
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
    func setSearchHighlights(_ ranges: [NSRange]) {
        guard let layoutManager, let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let colour = NSColor.labelColor.withAlphaComponent(0.12)
        for range in ranges {
            let clamped = NSIntersectionRange(range, full)
            guard clamped.length > 0 else { continue }
            layoutManager.addTemporaryAttributes([.backgroundColor: colour], forCharacterRange: clamped)
        }
        highlightedRanges = ranges
    }

    func clearSearchHighlights() {
        guard !highlightedRanges.isEmpty, let layoutManager, let storage = textStorage else {
            highlightedRanges = []
            return
        }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length)
        )
        highlightedRanges = []
    }

    /// What is lit up, for the tests and for a tab switch to put down again.
    private(set) var highlightedRanges: [NSRange] = []

    // MARK: - Chip clicks

    /// A single click on an `Image N` chip selects the picture rather than
    /// just dropping a caret somewhere inside the line.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let index = chipCharacterIndex(for: event) else {
            super.mouseDown(with: event)
            return
        }
        // Caret goes just after the chip, which is also what makes the
        // sidebar's caret-adjacent highlight agree with the selection — or,
        // when vim's block caret is up, onto the chip, where the block sits.
        let location = vimCursorStyle == .bar ? index + 1 : index
        setSelectedRange(NSRange(location: location, length: 0))
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
                  is JotImageAttachment
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

    /// `NSTextView` asks this which flavour to take; the default picks by the
    /// pasteboard's order, and we want ours.
    override func preferredPasteboardType(
        from availableTypes: [NSPasteboard.PasteboardType],
        restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?
    ) -> NSPasteboard.PasteboardType? {
        let allowed = allowedTypes ?? Self.readPriority
        for type in Self.readPriority
        where allowed.contains(type) && availableTypes.contains(type) {
            return type
        }
        return super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
    }

    override func readSelection(
        from pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        switch type {
        case .jotNote:
            guard let text = pboard.string(forType: .jotNote) else { return false }
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

        case .string:
            guard let text = pboard.string(forType: .string) else { return false }
            // Tokens pasted back as text become images again, which is what
            // happens when a Jot file is opened, so the two agree.
            return insert(render(text))

        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    // MARK: - Writing

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.jotNote]
        // Only offer RTFD when there is actually an image to carry, so
        // copying prose into another app stays unstyled.
        if selectionContainsImage { types.append(.rtfd) }
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
        case .jotNote:
            return pboard.setString(NoteText.serialize(selection), forType: .jotNote)

        case .rtfd:
            guard let data = rtfdData(for: selection) else { return false }
            return pboard.setData(data, forType: .rtfd)

        case .string:
            let plain = NoteText.strippingTokens(NoteText.serialize(selection))
            return pboard.setString(plain, forType: .string)

        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    private var selectionContainsImage: Bool {
        guard let storage = textStorage else { return false }
        let range = selectedRange()
        guard range.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value is JotImageAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Swaps each Jot attachment for a stock one carrying the asset's bytes,
    /// which is what lets Notes, Mail and Pages show the image.
    private func rtfdData(for selection: NSAttributedString) -> Data? {
        let converted = NSMutableAttributedString(attributedString: selection)
        let full = NSRange(location: 0, length: converted.length)

        var replacements: [(NSRange, NSTextAttachment)] = []
        converted.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let jot = value as? JotImageAttachment,
                  let data = assets?.data(for: jot.assetID) else { return }
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = jot.assetID
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
        let openable = Self.textFiles(on: sender.draggingPasteboard)
        if !openable.isEmpty { onOpenFiles?(openable) }
        guard let type = droppableType(on: sender) else {
            return openable.isEmpty ? super.performDragOperation(sender) : true
        }
        return readSelection(from: sender.draggingPasteboard, type: type) || !openable.isEmpty
    }

    private func claimsDrag(_ sender: NSDraggingInfo) -> Bool {
        droppableType(on: sender) != nil
            || !Self.textFiles(on: sender.draggingPasteboard).isEmpty
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

    /// The dropped files that are notes rather than images. Extensions are no
    /// use on their own — a `.toml` has no type at all — so `TextFile` decides,
    /// by the system's type where there is one and by the bytes where not.
    static func textFiles(on pboard: NSPasteboard) -> [URL] {
        guard pboard.types?.contains(.fileURL) == true else { return [] }
        let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.filter { !AssetStore.isImageFile($0) && TextFile.isTextFile(at: $0) }
    }

    // MARK: - Insertion

    private func render(_ plain: String) -> NSAttributedString {
        NoteText.render(plain, attributes: attributes, assets: assets)
    }

    /// Turns an attributed string from another app into Jot's own shape:
    /// attachments become assets, everything else becomes unstyled text.
    private func importForeign(_ foreign: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = foreign.string as NSString
        let full = NSRange(location: 0, length: foreign.length)

        foreign.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                guard let id = assets?.importForeignAttachment(attachment) else { return }
                result.append(render(NoteText.token(for: id)))
            } else {
                result.append(NSAttributedString(
                    string: source.substring(with: range), attributes: attributes
                ))
            }
        }
        return result
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
