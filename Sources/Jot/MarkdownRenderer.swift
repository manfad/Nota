import AppKit

/// A picture in the preview pane. The editor keeps its `Image N` chips; here
/// the real thing is drawn, scaled down to the pane if it is wider than it.
final class MarkdownImageAttachment: NSTextAttachment {
    let assetID: String
    /// The size the picture is drawn at — the natural one, or the pane's
    /// width with the aspect ratio kept.
    let displaySize: NSSize

    init(image: NSImage, assetID: String, maximumWidth: CGFloat) {
        self.assetID = assetID
        let natural = image.size
        let scale: CGFloat
        if natural.width > 0, maximumWidth > 0, natural.width > maximumWidth {
            scale = maximumWidth / natural.width
        } else {
            scale = 1
        }
        displaySize = NSSize(
            width: (natural.width * scale).rounded(),
            height: (natural.height * scale).rounded()
        )
        super.init(data: nil, ofType: nil)
        self.image = image
        bounds = NSRect(origin: .zero, size: displaySize)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The hairline a `---` becomes. Drawn through a handler so `separatorColor`
/// resolves at draw time and follows light and dark mode.
final class MarkdownRuleAttachment: NSTextAttachment {
    let ruleWidth: CGFloat

    init(width: CGFloat, font: NSFont) {
        ruleWidth = max(1, width)
        super.init(data: nil, ofType: nil)
        let height = max(1, font.pointSize)
        image = NSImage(size: NSSize(width: ruleWidth, height: height), flipped: false) { rect in
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: rect.midY.rounded(), width: rect.width, height: 1).fill()
            return true
        }
        bounds = NSRect(x: 0, y: font.descender.rounded(),
                        width: ruleWidth, height: height)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Markdown as an attributed string, for the preview pane.
///
/// Foundation does the parsing — `AttributedString(markdown:)` with full
/// interpretation — and hands back a flat run of text carrying
/// `presentationIntent` (which block each character belongs to) and
/// `inlinePresentationIntent` (emphasis, code, breaks). All the shape is put
/// back here: the runs are gathered into blocks, and each block gets the
/// paragraph style, font and markers that make it read as a heading, a list
/// item, a quote or a fenced block.
///
/// Monochrome throughout: nothing but the system's label and separator
/// colours, so the pane matches the editor beside it in either appearance.
enum MarkdownRenderer {

    /// H1 down to H6, as multiples of the editor's size.
    static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.15, 1.05, 1.0]

    /// One step of list or quote indentation.
    private static func indentUnit(for font: NSFont) -> CGFloat {
        (font.pointSize * 1.8).rounded()
    }

    static func render(
        _ markdown: String, font: NSFont, assets: AssetStore?, width: CGFloat
    ) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        // Partial parsing already covers malformed input; this is the last
        // resort, where the note comes through as the plain text it is.
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
        }

        let blocks = split(parsed)
        let result = NSMutableAttributedString()
        // A list item's marker belongs to its first paragraph only; the rest
        // of the item lines up under it.
        var markedItems: Set<Int> = []
        var index = 0

        while index < blocks.count {
            if blocks[index].isTableCell {
                let end = tableEnd(of: blocks, from: index)
                appendBreak(to: result)
                appendTable(Array(blocks[index ..< end]), to: result, font: font)
                index = end
                continue
            }
            let block = blocks[index]
            let wantsMarker = block.listItemIdentity.map { markedItems.insert($0).inserted } ?? false
            appendBreak(to: result)
            append(block, to: result, font: font, assets: assets,
                   width: width, wantsMarker: wantsMarker)
            index += 1
        }
        return result
    }

    // MARK: - Blocks

    /// One run of text as Foundation handed it over, with the block intent
    /// stripped off — that lives on the `Block` around it.
    private struct Piece {
        let text: String
        let inline: InlinePresentationIntent?
        let link: URL?
        let imageURL: URL?
    }

    /// Every character sharing one innermost presentation intent: a heading,
    /// a paragraph, a fenced block, one table cell.
    private struct Block {
        /// Innermost first — `[paragraph, listItem 2, unorderedList]`.
        let components: [PresentationIntent.IntentType]
        var pieces: [Piece]

        var identity: Int? { components.first?.identity }
        var kind: PresentationIntent.Kind? { components.first?.kind }
        var plainText: String { pieces.map(\.text).joined() }

        var isTableCell: Bool {
            if case .tableCell = kind { return true }
            return false
        }

        /// The table this cell belongs to, so consecutive cells can be
        /// gathered into one grid.
        var tableIdentity: Int? {
            components.first { component in
                if case .table = component.kind { return true }
                return false
            }?.identity
        }

        /// The row this cell belongs to — header rows count too.
        var rowIdentity: Int? {
            components.first { component in
                switch component.kind {
                case .tableHeaderRow, .tableRow: return true
                default: return false
                }
            }?.identity
        }

        var listItemIdentity: Int? {
            components.first { component in
                if case .listItem = component.kind { return true }
                return false
            }?.identity
        }

        var listDepth: Int {
            components.filter { component in
                switch component.kind {
                case .orderedList, .unorderedList: return true
                default: return false
                }
            }.count
        }

        var quoteDepth: Int {
            components.filter { component in
                if case .blockQuote = component.kind { return true }
                return false
            }.count
        }

        /// `•` or `3.`, taken from the nearest list item and the list holding
        /// it. `nil` when the block is not in a list at all.
        var listMarker: String? {
            guard let itemIndex = components.firstIndex(where: { component in
                if case .listItem = component.kind { return true }
                return false
            }) else { return nil }
            guard case .listItem(let ordinal) = components[itemIndex].kind else { return nil }
            let parent = components[(itemIndex + 1)...].first
            if let parent, case .orderedList = parent.kind { return "\(ordinal)." }
            return "•"
        }
    }

    private static func split(_ parsed: AttributedString) -> [Block] {
        var blocks: [Block] = []
        for run in parsed.runs {
            let piece = Piece(
                text: String(parsed[run.range].characters),
                inline: run.inlinePresentationIntent,
                link: run.link,
                imageURL: run.imageURL
            )
            let components = run.presentationIntent?.components ?? []
            if let last = blocks.last, last.identity != nil,
               last.identity == components.first?.identity {
                blocks[blocks.count - 1].pieces.append(piece)
            } else {
                blocks.append(Block(components: components, pieces: [piece]))
            }
        }
        return blocks
    }

    /// Blocks are laid end to end; the newline between them is what makes
    /// each one its own paragraph.
    ///
    /// It belongs to the block *before* it — a paragraph ends at its newline —
    /// so it is given that block's style, which is where the spacing after a
    /// heading or a list item lives.
    private static func appendBreak(to result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let previous = result.attributes(at: result.length - 1, effectiveRange: nil)
            .filter { $0.key == .font || $0.key == .paragraphStyle }
        result.append(NSAttributedString(string: "\n", attributes: previous))
    }

    // MARK: - Styling one block

    private static func append(
        _ block: Block, to result: NSMutableAttributedString, font: NSFont,
        assets: AssetStore?, width: CGFloat, wantsMarker: Bool
    ) {
        let start = result.length
        let unit = indentUnit(for: font)
        let style = NSMutableParagraphStyle()
        var blockFont = font
        var isCodeBlock = false

        switch block.kind {
        case .header(let level):
            let scale = Self.headingScales[min(max(level, 1), 6) - 1]
            blockFont = heading(font, scale: scale)
            style.paragraphSpacingBefore = (font.pointSize * 0.9).rounded()
            style.paragraphSpacing = (font.pointSize * 0.3).rounded()
        case .codeBlock:
            isCodeBlock = true
            blockFont = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            style.paragraphSpacing = (font.pointSize * 0.6).rounded()
        case .thematicBreak:
            style.paragraphSpacingBefore = (font.pointSize * 0.6).rounded()
            style.paragraphSpacing = (font.pointSize * 0.6).rounded()
            result.append(NSAttributedString(
                attachment: MarkdownRuleAttachment(width: ruleWidth(width, font: font), font: font)
            ))
            result.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: start, length: result.length - start))
            return
        default:
            // A paragraph inside a list sits close to its neighbours; a
            // free-standing one gets a full gap after it.
            style.paragraphSpacing = (font.pointSize * (block.listDepth > 0 ? 0.15 : 0.5)).rounded()
        }

        // The prefix cells — one leading bar per quote level, then the list
        // marker — each start at a tab stop, and the text after them lines up
        // at `headIndent` however the paragraph wraps.
        let marker = wantsMarker ? block.listMarker : nil
        let quoteDepth = block.quoteDepth
        let indentLevels = quoteDepth + block.listDepth
        let cells = quoteDepth + (marker == nil ? 0 : 1)
        style.headIndent = CGFloat(indentLevels) * unit
        style.firstLineHeadIndent = CGFloat(max(0, indentLevels - cells)) * unit
        style.defaultTabInterval = unit
        if indentLevels > 0 {
            style.tabStops = (1 ... indentLevels).map {
                NSTextTab(textAlignment: .left, location: CGFloat($0) * unit)
            }
        }
        if isCodeBlock {
            style.headIndent += unit / 2
            style.firstLineHeadIndent += unit / 2
        }

        for _ in 0 ..< quoteDepth {
            result.append(NSAttributedString(string: "▏\t", attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if let marker {
            result.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: blockFont,
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        if isCodeBlock {
            // The fence's own trailing newline would open an empty line the
            // block break is already providing.
            var code = block.plainText
            while code.hasSuffix("\n") { code.removeLast() }
            result.append(NSAttributedString(string: code, attributes: [
                .font: blockFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05),
            ]))
        } else {
            for piece in block.pieces {
                append(piece, to: result, font: blockFont, base: font,
                       assets: assets, width: width)
            }
        }

        result.addAttribute(.paragraphStyle, value: style,
                            range: NSRange(location: start, length: result.length - start))
    }

    // MARK: - Styling one run

    private static func append(
        _ piece: Piece, to result: NSMutableAttributedString, font: NSFont,
        base: NSFont, assets: AssetStore?, width: CGFloat
    ) {
        if let imageURL = piece.imageURL {
            appendImage(imageURL, alt: piece.text, to: result,
                        font: font, assets: assets, width: width)
            return
        }
        guard !piece.text.isEmpty else { return }

        let inline = piece.inline ?? []
        var attributes: [NSAttributedString.Key: Any] = [
            .font: styled(font, inline: inline),
            .foregroundColor: NSColor.labelColor,
        ]
        if inline.contains(.code) {
            attributes[.font] = NSFont.monospacedSystemFont(
                ofSize: base.pointSize, weight: .regular
            )
            attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.05)
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = piece.link {
            attributes[.link] = link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        result.append(NSAttributedString(string: piece.text, attributes: attributes))
    }

    /// A `jot://` token draws the picture it points at. Anything else — a
    /// remote URL, an asset that has gone missing — shows its alt text
    /// instead: Jot never reaches out to the network for a preview.
    private static func appendImage(
        _ url: URL, alt: String, to result: NSMutableAttributedString,
        font: NSFont, assets: AssetStore?, width: CGFloat
    ) {
        if let assetID = assetID(from: url), let image = assets?.image(for: assetID) {
            let attachment = MarkdownImageAttachment(
                image: image, assetID: assetID, maximumWidth: max(0, width)
            )
            result.append(NSAttributedString(attachment: attachment))
            return
        }
        // Foundation stands an image with no alt text on a U+FFFC; there is
        // nothing to read in that, so the address is shown instead.
        let text = alt.replacingOccurrences(of: "\u{FFFC}", with: "")
        result.append(NSAttributedString(
            string: text.isEmpty ? url.absoluteString : text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
    }

    private static func assetID(from url: URL) -> String? {
        let text = url.absoluteString
        guard text.hasPrefix(NoteText.scheme) else { return nil }
        let id = String(text.dropFirst(NoteText.scheme.count))
        return id.isEmpty ? nil : id
    }

    // MARK: - Tables

    /// How far the run of cells starting at `index` goes — one table's worth.
    private static func tableEnd(of blocks: [Block], from index: Int) -> Int {
        let table = blocks[index].tableIdentity
        var end = index
        while end < blocks.count, blocks[end].isTableCell,
              blocks[end].tableIdentity == table {
            end += 1
        }
        return end
    }

    /// Best effort, as the spec says: the cells are padded out to a common
    /// width and set monospaced, so the columns line up as text. No rules, no
    /// cell backgrounds — a table stays something you read.
    private static func appendTable(
        _ cells: [Block], to result: NSMutableAttributedString, font: NSFont
    ) {
        var rows: [[String]] = []
        var currentRow: Int?
        for cell in cells {
            if cell.rowIdentity != currentRow || rows.isEmpty {
                rows.append([])
                currentRow = cell.rowIdentity
            }
            rows[rows.count - 1].append(cell.plainText)
        }

        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (column, text) in row.enumerated() {
                widths[column] = max(widths[column], text.count)
            }
        }

        let lines = rows.map { row -> String in
            let padded = (0 ..< columns).map { column -> String in
                let text = column < row.count ? row[column] : ""
                return text + String(repeating: " ", count: max(0, widths[column] - text.count))
            }
            var line = padded.joined(separator: "  ")
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = (font.pointSize * 0.5).rounded()
        result.append(NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        ))
    }

    // MARK: - Fonts

    /// A heading keeps the editor's family and takes its weight and size from
    /// the level, so the pane reads as the same typeface throughout.
    private static func heading(_ font: NSFont, scale: CGFloat) -> NSFont {
        let size = (font.pointSize * scale).rounded()
        let semibold = font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue],
        ])
        // The system font has a real semibold face. A family that has none
        // hands back its regular weight unchanged, and gets its bold face
        // instead — the nearest thing it has to offer.
        if let heavier = NSFont(descriptor: semibold, size: size),
           heavier.fontDescriptor.symbolicTraits.contains(.bold) {
            return heavier
        }
        let bold = font.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: bold, size: size)
            ?? NSFont(descriptor: font.fontDescriptor, size: size)
            ?? font
    }

    private static func styled(_ font: NSFont, inline: InlinePresentationIntent) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if inline.contains(.emphasized) { traits.insert(.italic) }
        if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            NSFontDescriptor.SymbolicTraits(rawValue: font.fontDescriptor.symbolicTraits.rawValue)
                .union(traits)
        )
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// The pane's width when it has one; before the first layout pass there is
    /// no width to draw to, so the rule falls back to a readable measure.
    private static func ruleWidth(_ width: CGFloat, font: NSFont) -> CGFloat {
        width > 1 ? width : font.pointSize * 20
    }
}
