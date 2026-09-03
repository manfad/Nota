import AppKit
import CoreText

/// LaTeX as an attributed string, for the preview pane.
///
/// `LaTeXParser` does the reading and hands over blocks that already know
/// where in the note they came from; everything here is the look. And the look
/// is `RenderStyle`'s — the same heading scales, the same indents, the same
/// box around code and the same table the Markdown render wears — so a `.tex`
/// tab and a `.md` tab beside each other read as one app.
///
/// Not TeX's pixels. Nota is not typesetting the document; it is laying it out
/// to be read, which is why a `figure` is its picture and its caption rather
/// than a float, and why an unknown command shows as itself rather than as an
/// error on a page of its own.
enum LaTeXRenderer {

    /// How far inside the pane's trailing edge an equation number sits: the
    /// text container's own padding, so `(1)` lands exactly where the last
    /// word of a paragraph would.
    static let equationNumberInset = RenderStyle.lineFragmentPadding

    static func render(
        _ tex: String, font: NSFont, baseURL: URL?, width: CGFloat
    ) -> RenderedDocument {
        guard !tex.isEmpty else { return .empty }

        let document = LaTeXParser.parse(tex)
        let result = NSMutableAttributedString()
        var sources: [(range: NSRange, source: NSRange)] = []
        var fitsThePane = false

        for block in document.blocks {
            RenderStyle.appendBreak(to: result)
            let start = result.length
            let usedWidth = append(block, to: result, font: font, baseURL: baseURL, width: width)
            fitsThePane = fitsThePane || usedWidth
            let range = NSRange(location: start, length: result.length - start)
            guard range.length > 0 else { continue }
            result.addAttribute(
                .notaSourceRange, value: NSValue(range: block.source), range: range
            )
            sources.append((range: range, source: block.source))
        }

        var render = RenderedDocument(text: result, blocks: sources)
        render.dependsOnWidth = fitsThePane || holdsAPicture(result)
        return render
    }

    /// Whether the render holds anything that was sized to the column it was
    /// made for. A formula is not: it is measured against the font, so the
    /// column can widen under one without the note being rendered again — but
    /// the number beside a numbered one is held against the trailing edge,
    /// and that does move.
    private static func holdsAPicture(_ text: NSAttributedString) -> Bool {
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

    // MARK: - One block

    /// Lays one block down and says whether it was drawn to the pane's width.
    private static func append(
        _ block: LaTeXBlock, to result: NSMutableAttributedString,
        font: NSFont, baseURL: URL?, width: CGFloat
    ) -> Bool {
        let start = result.length
        let unit = RenderStyle.indentUnit(for: font)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = (font.pointSize * 0.5).rounded()
        var fitsThePane = false
        var isCodeBlock = false

        // The quote bars and the list marker each take a tab stop, and the
        // text after them lines up at `headIndent` however it wraps — the
        // same arrangement the Markdown render uses.
        let listDepth: Int
        if case .listItem(let depth, _, _, _) = block.kind { listDepth = depth } else { listDepth = 0 }
        var marker: String?
        if case .listItem(_, let itemMarker, _, _) = block.kind { marker = itemMarker }
        let indentLevels = block.quoteDepth + listDepth
        let cells = block.quoteDepth + (marker == nil ? 0 : 1)
        style.headIndent = CGFloat(indentLevels) * unit
        style.firstLineHeadIndent = CGFloat(max(0, indentLevels - cells)) * unit
        style.defaultTabInterval = unit
        if indentLevels > 0 {
            style.tabStops = (1 ... indentLevels).map {
                NSTextTab(textAlignment: .left, location: CGFloat($0) * unit)
            }
        }
        if block.isCentred { style.alignment = .center }

        for _ in 0 ..< block.quoteDepth {
            result.append(NSAttributedString(string: "▏\t", attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        switch block.kind {
        case .title(let title, let author, let date):
            appendTitle(title, author: author, date: date,
                        to: result, font: font, baseURL: baseURL, width: width)

        case .abstractTitle:
            let heading = RenderStyle.heading(font, scale: RenderStyle.headingScales[3])
            style.alignment = .center
            style.paragraphSpacingBefore = (font.pointSize * 0.9).rounded()
            style.paragraphSpacing = (font.pointSize * 0.3).rounded()
            result.append(NSAttributedString(string: "Abstract", attributes: [
                .font: heading,
                .foregroundColor: NSColor.labelColor,
            ]))

        case .heading(let level, let number, let content):
            let scale = RenderStyle.headingScales[min(max(level, 1), 6) - 1]
            let heading = RenderStyle.heading(font, scale: scale)
            style.paragraphSpacingBefore = (font.pointSize * 0.9).rounded()
            style.paragraphSpacing = (font.pointSize * 0.3).rounded()
            if let number {
                result.append(NSAttributedString(string: number + " ", attributes: [
                    .font: heading,
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
            fitsThePane = append(content, to: result, font: heading, base: font,
                                 baseURL: baseURL, width: width)

        case .paragraph(let content):
            fitsThePane = append(content, to: result, font: font, base: font,
                                 baseURL: baseURL, width: width)

        case .listItem(_, let itemMarker, let term, let content):
            style.paragraphSpacing = (font.pointSize * 0.15).rounded()
            if let itemMarker {
                result.append(NSAttributedString(string: itemMarker + "\t", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
            if !term.isEmpty {
                _ = append(term, to: result, font: font, base: font,
                           face: .bold, baseURL: baseURL, width: width)
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            fitsThePane = append(content, to: result, font: font, base: font,
                                 baseURL: baseURL, width: width)

        case .math(let tex, let number):
            fitsThePane = appendDisplayMath(
                tex, number: number, to: result, style: style, font: font, width: width
            )

        case .code(let code), .unknown(let code):
            isCodeBlock = true
            style.headIndent += RenderStyle.codeBoxInset
            style.firstLineHeadIndent += RenderStyle.codeBoxInset
            style.tailIndent = -RenderStyle.codeBoxInset
            result.append(NSAttributedString(string: code, attributes: [
                .font: RenderStyle.monospaced(font.pointSize),
                .foregroundColor: NSColor.labelColor,
                .notaCodeBlock: true,
            ]))

        case .table(let rows):
            RenderStyle.appendTable(
                rows.map { row in
                    row.map { plainText($0).trimmingCharacters(in: .whitespaces) }
                },
                to: result, font: font
            )

        case .caption(let label, let content):
            result.append(NSAttributedString(string: label + " ", attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            fitsThePane = append(content, to: result, font: font, base: font,
                                 colour: .secondaryLabelColor, baseURL: baseURL, width: width)
        }

        let blockRange = NSRange(location: start, length: result.length - start)
        guard blockRange.length > 0 else { return fitsThePane }
        // A table lays its own paragraph style down; everything else takes
        // the block's.
        if case .table = block.kind {} else {
            result.addAttribute(.paragraphStyle, value: style, range: blockRange)
        }
        if isCodeBlock {
            RenderStyle.padEnds(of: blockRange, in: result, style: style,
                                gap: (font.pointSize * 0.6).rounded())
        }
        return fitsThePane
    }

    /// `\maketitle`: the title at heading size over the author and the date,
    /// centred, the way the first page of an article reads.
    private static func appendTitle(
        _ title: [LaTeXInline], author: [LaTeXInline], date: [LaTeXInline],
        to result: NSMutableAttributedString,
        font: NSFont, baseURL: URL?, width: CGFloat
    ) {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = (font.pointSize * 0.3).rounded()

        var lines = 0
        func line(_ content: [LaTeXInline], font lineFont: NSFont, colour: NSColor) {
            guard !content.isEmpty else { return }
            if lines > 0 {
                result.append(NSAttributedString(
                    string: "\n", attributes: [.font: lineFont, .paragraphStyle: centred]
                ))
            }
            lines += 1
            let start = result.length
            _ = append(content, to: result, font: lineFont, base: font,
                       colour: colour, baseURL: baseURL, width: width)
            result.addAttribute(
                .paragraphStyle, value: centred,
                range: NSRange(location: start, length: result.length - start)
            )
        }

        line(title, font: RenderStyle.heading(font, scale: RenderStyle.headingScales[0]),
             colour: .labelColor)
        line(author, font: font, colour: .secondaryLabelColor)
        line(date, font: font, colour: .secondaryLabelColor)

        let bottom = NSMutableParagraphStyle()
        bottom.alignment = .center
        bottom.paragraphSpacing = (font.pointSize * 0.9).rounded()
        if result.length > 0 {
            result.addAttribute(
                .paragraphStyle, value: bottom,
                range: NSRange(location: result.length - 1, length: 1)
            )
        }
    }

    /// A display formula, centred, with its number held against the trailing
    /// edge on the same line.
    ///
    /// The number is the one thing in the render that has to know how wide the
    /// pane is: it is a right tab stop at the edge, with a centre tab at the
    /// half way point holding the formula in the middle. Before the first
    /// layout pass there is no width to hold it against, so it follows the
    /// formula instead and the next pass puts it where it belongs.
    private static func appendDisplayMath(
        _ tex: String, number: Int?, to result: NSMutableAttributedString,
        style: NSMutableParagraphStyle, font: NSFont, width: CGFloat
    ) -> Bool {
        style.paragraphSpacingBefore = RenderStyle.codeBoxPadding
        style.paragraphSpacing = RenderStyle.codeBoxPadding + (font.pointSize * 0.6).rounded()

        let usable = width - equationNumberInset * 2
        let holdsTheEdge = number != nil && usable > font.pointSize * 4
        if holdsTheEdge {
            style.alignment = .natural
            style.tabStops = [
                NSTextTab(textAlignment: .center, location: usable / 2),
                NSTextTab(textAlignment: .right, location: usable),
            ]
            style.defaultTabInterval = usable
            result.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        } else {
            style.alignment = .center
        }

        appendFormula(tex, to: result, font: font, display: true)

        if let number {
            result.append(NSAttributedString(
                string: (holdsTheEdge ? "\t" : "  ") + "(\(number))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
        return holdsTheEdge
    }

    /// One formula, laid out against whatever font it stands in. TeX that
    /// cannot be read at all comes back as the source it was, set as a code
    /// span — never a blank, and never a broken page.
    private static func appendFormula(
        _ tex: String, to result: NSMutableAttributedString, font: NSFont, display: Bool
    ) {
        if let formula = MathRenderer.layout(tex, font: font, display: display) {
            result.append(NSAttributedString(
                attachment: MathAttachment(formula: formula, font: font)
            ))
            return
        }
        let raw = display ? "\\[" + tex + "\\]" : "$" + tex + "$"
        result.append(NSAttributedString(
            string: raw, attributes: RenderStyle.codeSpanAttributes(size: font.pointSize)
        ))
    }

    // MARK: - Running text

    @discardableResult
    private static func append(
        _ nodes: [LaTeXInline], to result: NSMutableAttributedString,
        font: NSFont, base: NSFont, face: LaTeXFace = [],
        colour: NSColor = .labelColor, baseURL: URL?, width: CGFloat
    ) -> Bool {
        var fitsThePane = false
        for node in nodes {
            switch node {
            case .text(let string, _):
                guard !string.isEmpty else { continue }
                result.append(NSAttributedString(
                    string: string, attributes: attributes(face, font: font, colour: colour)
                ))

            case .face(let added, let children, _):
                fitsThePane = append(children, to: result, font: font, base: base,
                                     face: face.union(added), colour: colour,
                                     baseURL: baseURL, width: width) || fitsThePane

            case .math(let tex, let display, _):
                appendFormula(tex, to: result, font: faced(font, face), display: display)

            case .placeholder(let placeholder, _):
                let text: String
                switch placeholder {
                case .citation(let key): text = "[\(key)]"
                case .reference(let key): text = "(\(key))"
                }
                result.append(NSAttributedString(
                    string: text,
                    attributes: attributes(face, font: font, colour: .secondaryLabelColor)
                ))

            case .link(let url, let children, _):
                var attributes = attributes(face, font: font, colour: colour)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let destination = URL(string: url) { attributes[.link] = destination }
                let shown = children.isEmpty ? url : plainText(children)
                result.append(NSAttributedString(string: shown, attributes: attributes))

            case .footnote(let children, _):
                result.append(NSAttributedString(
                    string: " [", attributes: attributes(face, font: font,
                                                         colour: .secondaryLabelColor)
                ))
                _ = append(children, to: result, font: font, base: base, face: face,
                           colour: .secondaryLabelColor, baseURL: baseURL, width: width)
                result.append(NSAttributedString(
                    string: "]", attributes: attributes(face, font: font,
                                                        colour: .secondaryLabelColor)
                ))

            case .image(let path, _):
                if let image = picture(at: path, near: baseURL) {
                    result.append(NSAttributedString(attachment: MarkdownImageAttachment(
                        image: image, assetID: path, maximumWidth: max(0, width)
                    )))
                    fitsThePane = true
                } else {
                    result.append(NSAttributedString(
                        string: path,
                        attributes: attributes(face, font: font, colour: .secondaryLabelColor)
                    ))
                }

            case .lineBreak:
                // A break inside a paragraph rather than between two, so the
                // block stays one block and its spacing is not repeated.
                result.append(NSAttributedString(
                    string: "\u{2028}", attributes: attributes(face, font: font, colour: colour)
                ))

            case .unknown(let raw, _):
                result.append(NSAttributedString(
                    string: raw, attributes: RenderStyle.codeSpanAttributes(size: base.pointSize)
                ))
            }
        }
        return fitsThePane
    }

    private static func attributes(
        _ face: LaTeXFace, font: NSFont, colour: NSColor
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: faced(font, face),
            .foregroundColor: colour,
        ]
        if face.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// The font a face asks for. A family with no italic or no small caps
    /// hands back what it has, which is better than no text at all.
    private static func faced(_ font: NSFont, _ face: LaTeXFace) -> NSFont {
        var result = font
        if face.contains(.monospaced) {
            result = RenderStyle.monospaced(font.pointSize)
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if face.contains(.bold) { traits.insert(.bold) }
        if face.contains(.italic) { traits.insert(.italic) }
        result = RenderStyle.styled(result, traits: traits)
        if face.contains(.smallCaps) { result = smallCaps(result) }
        return result
    }

    private static func smallCaps(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// What a run of nodes says, with none of the styling — a table cell, a
    /// link's label.
    static func plainText(_ nodes: [LaTeXInline]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let string, _): return string
            case .face(_, let children, _): return plainText(children)
            case .math(let tex, let display, _):
                return MathRenderer.layout(
                    tex, font: .systemFont(ofSize: 13), display: display
                )?.plainText ?? tex
            case .placeholder(.citation(let key), _): return "[\(key)]"
            case .placeholder(.reference(let key), _): return "(\(key))"
            case .link(let url, let children, _):
                return children.isEmpty ? url : plainText(children)
            case .footnote(let children, _): return " [" + plainText(children) + "]"
            case .image(let path, _): return path
            case .lineBreak: return " "
            case .unknown(let raw, _): return raw
            }
        }.joined()
    }

    // MARK: - Pictures

    /// `\includegraphics{plot}` beside the note. LaTeX's own rule: a path
    /// with no extension is tried against the ones the engine knows, and one
    /// that resolves to nothing shows as the path it was.
    ///
    /// Nota never reaches out to the network for a preview, so a URL is a
    /// path that does not exist.
    static func picture(at path: String, near baseURL: URL?) -> NSImage? {
        guard !path.isEmpty else { return nil }
        let directory = baseURL?.deletingLastPathComponent()
        var candidates: [URL] = []
        let given = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        if given.pathExtension.isEmpty {
            for extensionName in ["png", "jpg", "jpeg", "pdf", "tiff", "gif"] {
                candidates.append(given.appendingPathExtension(extensionName))
            }
        } else {
            candidates.append(given)
        }
        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) { return image }
        }
        return nil
    }
}
