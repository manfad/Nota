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

    // MARK: - Chip clicks

    /// A single click on an `[Image N]` chip selects the picture rather than
    /// just dropping a caret somewhere inside the line.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let index = chipCharacterIndex(for: event) else {
            super.mouseDown(with: event)
            return
        }
        // Caret goes just after the chip, which is also what makes the
        // sidebar's caret-adjacent highlight agree with the selection.
        setSelectedRange(NSRange(location: index + 1, length: 0))
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
        droppableType(on: sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppableType(on: sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let type = droppableType(on: sender) else {
            return super.performDragOperation(sender)
        }
        return readSelection(from: sender.draggingPasteboard, type: type)
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
