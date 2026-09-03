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

extension NSAttributedString.Key {
    /// The range in the note's own text that a rendered block came from, laid
    /// on every character of that block. It is what a click in the preview
    /// turns back into a place in the editor.
    static let notaSourceRange = NSAttributedString.Key("notaSourceRange")

    /// Laid on every character of a fenced code block. The wash under one is
    /// a single box drawn behind the whole block, not a colour on the
    /// characters — a background attribute hugs each line's glyphs and comes
    /// out as a stack of loose rectangles.
    static let notaCodeBlock = NSAttributedString.Key("notaCodeBlock")
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

    /// What a render is — the same thing every content view in the column
    /// deals in, whichever grammar made it.
    typealias Result = RenderedDocument

    /// The look, which is `RenderStyle`'s: named here too so the render and
    /// the tests that pin it read the way they always have.
    static var headingScales: [CGFloat] { RenderStyle.headingScales }
    static var codeBoxInset: CGFloat { RenderStyle.codeBoxInset }
    static var codeBoxPadding: CGFloat { RenderStyle.codeBoxPadding }
    static var codeBoxCornerRadius: CGFloat { RenderStyle.codeBoxCornerRadius }

    static func render(
        _ markdown: String, font: NSFont, assets: AssetStore?, width: CGFloat
    ) -> Result {
        guard !markdown.isEmpty else { return .empty }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        // The maths comes out before the parser goes in: left in, a `$a_1$`
        // would lose its underscore to an emphasis and never be a formula
        // again. What the parser reads is the note with each formula standing
        // as an image token.
        let maths = MarkdownMath.extract(from: markdown)
        // Partial parsing already covers malformed input; this is the last
        // resort, where the note comes through as the plain text it is.
        guard let parsed = try? AttributedString(markdown: maths.markdown, options: options) else {
            let whole = NSRange(location: 0, length: (markdown as NSString).length)
            return Result(
                text: NSAttributedString(string: markdown, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .notaSourceRange: NSValue(range: whole),
                ]),
                blocks: [(range: NSRange(location: 0, length: markdown.utf16.count),
                          source: whole)]
            )
        }

        let blocks = split(parsed)
        let result = NSMutableAttributedString()
        var map = MarkdownSourceMap(markdown)
        var sources: [(range: NSRange, source: NSRange)] = []
        // A list item's marker belongs to its first paragraph only; the rest
        // of the item lines up under it.
        var markedItems: Set<Int> = []
        var index = 0

        while index < blocks.count {
            RenderStyle.appendBreak(to: result)
            let start = result.length
            let source: NSRange

            if blocks[index].isTableCell {
                let end = tableEnd(of: blocks, from: index)
                let cells = Array(blocks[index ..< end])
                source = map.next(text: cells.first?.plainText ?? "", shape: .table)
                appendTable(cells, to: result, font: font)
                index = end
            } else {
                let block = blocks[index]
                let wantsMarker = block.listItemIdentity
                    .map { markedItems.insert($0).inserted } ?? false
                // A paragraph that is nothing but a display formula is found
                // in the source by its `$$` or its fence, not by its words —
                // it renders none.
                let shape = isDisplayMath(block, in: maths.spans)
                    ? MarkdownSourceMap.Shape.displayMath : block.shape
                source = map.next(text: block.plainText, shape: shape)
                append(block, to: result, font: font, assets: assets,
                       maths: maths.spans, width: width, wantsMarker: wantsMarker)
                index += 1
            }

            let range = NSRange(location: start, length: result.length - start)
            guard range.length > 0 else { continue }
            result.addAttribute(.notaSourceRange, value: NSValue(range: source), range: range)
            sources.append((range: range, source: source))
        }
        var render = Result(text: result, blocks: sources)
        render.dependsOnWidth = fitsThePane(result)
        return render
    }

    /// Whether a block is a display formula standing on its own — the shape
    /// a `$$…$$` paragraph and a ```` ```math ```` fence both come back as.
    private static func isDisplayMath(_ block: Block, in spans: [MarkdownMath.Span]) -> Bool {
        guard let index = block.soleMathIndex, spans.indices.contains(index) else { return false }
        return spans[index].isOwnBlock
    }

    /// Whether the render holds anything that was sized to the column it was
    /// made for. Only pictures and rules are. A formula is not: it is measured
    /// against the font, so the column can widen under one without the note
    /// being rendered again.
    private static func fitsThePane(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            guard value is MarkdownImageAttachment || value is MarkdownRuleAttachment
            else { return }
            found = true
            stop.pointee = true
        }
        return found
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

        /// How this block is found again in the source. Most blocks are found
        /// by their words; a fence, a rule and an image with no alt text have
        /// none to be found by, so they are found by their punctuation.
        var shape: MarkdownSourceMap.Shape {
            switch kind {
            case .codeBlock: return .codeFence
            case .thematicBreak: return .thematicBreak
            default: break
            }
            let hasImage = pieces.contains { piece in
                piece.imageURL.map { MarkdownMath.spanIndex(from: $0) == nil } ?? false
            }
            let hasWords = plainText.contains { $0.isLetter || $0.isNumber }
            return hasImage && !hasWords ? .image : .prose
        }

        /// The one maths token this block holds, when a token is all it
        /// holds. A `$$…$$` paragraph comes back as one of these, and that is
        /// what makes it a display block rather than a formula in a sentence.
        var soleMathIndex: Int? {
            var found: Int?
            for piece in pieces {
                if let url = piece.imageURL, let index = MarkdownMath.spanIndex(from: url) {
                    guard found == nil else { return nil }
                    found = index
                } else if piece.text.contains(where: { !$0.isWhitespace && $0 != "\u{FFFC}" }) {
                    return nil
                }
            }
            return found
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

    // MARK: - Styling one block

    private static func append(
        _ block: Block, to result: NSMutableAttributedString, font: NSFont,
        assets: AssetStore?, maths: [MarkdownMath.Span], width: CGFloat, wantsMarker: Bool
    ) {
        let start = result.length
        let unit = RenderStyle.indentUnit(for: font)
        let style = NSMutableParagraphStyle()
        var blockFont = font
        var isCodeBlock = false
        let isFormulaBlock = isDisplayMath(block, in: maths)

        switch block.kind {
        case .header(let level):
            let scale = Self.headingScales[min(max(level, 1), 6) - 1]
            blockFont = RenderStyle.heading(font, scale: scale)
            style.paragraphSpacingBefore = (font.pointSize * 0.9).rounded()
            style.paragraphSpacing = (font.pointSize * 0.3).rounded()
        case .codeBlock:
            isCodeBlock = true
            blockFont = RenderStyle.monospaced(font.pointSize)
            // Spacing goes on the block's outer lines only (see `padEnds`):
            // on every line it would space the code itself out.
        case .thematicBreak:
            style.paragraphSpacingBefore = (font.pointSize * 0.6).rounded()
            style.paragraphSpacing = (font.pointSize * 0.6).rounded()
            result.append(NSAttributedString(
                attachment: MarkdownRuleAttachment(
                    width: RenderStyle.ruleWidth(width, font: font), font: font
                )
            ))
            result.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: start, length: result.length - start))
            return
        case _ where isFormulaBlock:
            // A formula on its own stands in the middle of the pane, with the
            // same air above and below that a fenced block is given.
            style.alignment = .center
            style.paragraphSpacingBefore = Self.codeBoxPadding
            style.paragraphSpacing = Self.codeBoxPadding + (font.pointSize * 0.6).rounded()
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
            style.headIndent += Self.codeBoxInset
            style.firstLineHeadIndent += Self.codeBoxInset
            // Negative is measured from the trailing edge: the code clears
            // the box on the right the same way it does on the left.
            style.tailIndent = -Self.codeBoxInset
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
                .notaCodeBlock: true,
            ]))
        } else {
            for piece in block.pieces {
                append(piece, to: result, font: blockFont, base: font,
                       assets: assets, maths: maths, width: width)
            }
        }

        let blockRange = NSRange(location: start, length: result.length - start)
        result.addAttribute(.paragraphStyle, value: style, range: blockRange)
        if isCodeBlock {
            RenderStyle.padEnds(of: blockRange, in: result, style: style,
                                gap: (font.pointSize * 0.6).rounded())
        }
    }

    // MARK: - Styling one run

    private static func append(
        _ piece: Piece, to result: NSMutableAttributedString, font: NSFont,
        base: NSFont, assets: AssetStore?, maths: [MarkdownMath.Span], width: CGFloat
    ) {
        if let imageURL = piece.imageURL {
            if let index = MarkdownMath.spanIndex(from: imageURL), maths.indices.contains(index) {
                appendMath(maths[index], to: result, font: font, base: base)
                return
            }
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

    /// A formula, laid out against whatever font the block is set in — the
    /// heading's in a heading, the editor's size everywhere else, so the maths
    /// grows with Settings the way the rest of the render does.
    ///
    /// TeX that cannot be read at all comes back as the source it was, set as
    /// a code span. Never a blank, and never a crash: a note half way through
    /// a formula still reads as a note.
    private static func appendMath(
        _ span: MarkdownMath.Span, to result: NSMutableAttributedString,
        font: NSFont, base: NSFont
    ) {
        if let formula = MathRenderer.layout(span.tex, font: font, display: span.isDisplay) {
            result.append(NSAttributedString(
                attachment: MathAttachment(formula: formula, font: font)
            ))
            return
        }
        result.append(NSAttributedString(string: span.raw, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05),
        ]))
    }

    /// A `nota://` token — or a `jot://` one written before the rename —
    /// draws the picture it points at. Anything else — a remote URL, an asset
    /// that has gone missing — shows its alt text instead: Nota never reaches
    /// out to the network for a preview.
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
        NoteText.assetID(fromTokenURL: url.absoluteString)
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

    /// Best effort, as the spec says — `RenderStyle` lays the rows out; the
    /// only work here is gathering the cells into them.
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
        RenderStyle.appendTable(rows, to: result, font: font)
    }

    // MARK: - Fonts

    private static func styled(_ font: NSFont, inline: InlinePresentationIntent) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if inline.contains(.emphasized) { traits.insert(.italic) }
        if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
        return RenderStyle.styled(font, traits: traits)
    }
}
