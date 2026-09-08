import AppKit

/// A render: the styled text, and where every block in it came from.
///
/// The one currency the preview column deals in. Markdown makes one of these
/// out of Foundation's parser and Nota's block styling; LaTeX makes one out of
/// its own parser and the maths engine; the pane that shows either of them
/// knows nothing about which it was handed.
struct RenderedDocument {
    let text: NSAttributedString
    /// In document order. `range` indexes `text`, `source` indexes the note's
    /// own plain text.
    let blocks: [(range: NSRange, source: NSRange)]
    /// Whether anything here was drawn to fit the pane — a picture, the
    /// hairline a rule becomes, an equation number held against the trailing
    /// edge. Everything else is text and reflows on its own, so a render with
    /// none of them is right at any width and the column can widen under it
    /// without being made again.
    var dependsOnWidth = false

    static let empty = RenderedDocument(text: NSAttributedString(), blocks: [])
}

/// The look of the preview column, in one place.
///
/// Both renders wear it: the same heading scales, the same indents, the same
/// box around code, the same table. A `.tex` tab and a `.md` tab beside each
/// other should read as one app rendering two grammars, not as two renderers
/// that happen to share a window — so the measurements live here and neither
/// renderer keeps its own.
enum RenderStyle {

    /// H1 down to H6, as multiples of the editor's size.
    static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.15, 1.05, 1.0]

    /// The air inside a fenced block's box. The paragraph style holds the
    /// code this far off the edges; the pane draws the box that far out
    /// around it. The two halves have to agree, so they are stated once.
    static let codeBoxInset: CGFloat = 8
    static let codeBoxPadding: CGFloat = 6
    static let codeBoxCornerRadius: CGFloat = 6

    /// The text container's own inset on each side of a line, stated so the
    /// render and the pane agree on where the trailing edge is — which is
    /// where an equation number sits.
    static let lineFragmentPadding: CGFloat = 5

    /// The margins the rendered pane holds its text inside — matched to the
    /// editor's own padding, so the two columns of text start the same
    /// distance from their edges. `RenderedPreviewView` insets by these, and
    /// the export takes its page margins from them (`PDFPaginator`).
    static let previewHorizontalInset: CGFloat = 20
    static let previewVerticalInset: CGFloat = 14

    /// One step of list or quote indentation.
    static func indentUnit(for font: NSFont) -> CGFloat {
        (font.pointSize * 1.8).rounded()
    }

    /// A heading keeps the editor's family and takes its weight and size from
    /// the level, so the pane reads as the same typeface throughout.
    static func heading(_ font: NSFont, scale: CGFloat) -> NSFont {
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

    /// The same font with italic, bold or both — whatever the family can
    /// offer. A family with no italic hands its upright face back, which is
    /// better than no text at all.
    static func styled(
        _ font: NSFont, traits: NSFontDescriptor.SymbolicTraits
    ) -> NSFont {
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            NSFontDescriptor.SymbolicTraits(rawValue: font.fontDescriptor.symbolicTraits.rawValue)
                .union(traits)
        )
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// The monospaced face a code span, a code block and unreadable source
    /// are all set in.
    static func monospaced(_ size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// What raw source looks like when it is shown as itself: a code span.
    /// The maths engine's answer to TeX it cannot read, and the LaTeX render's
    /// answer to a command it has never heard of.
    static func codeSpanAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: monospaced(size),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05),
        ]
    }

    /// The pane's width when it has one; before the first layout pass there is
    /// no width to draw to, so a rule falls back to a readable measure.
    static func ruleWidth(_ width: CGFloat, font: NSFont) -> CGFloat {
        width > 1 ? width : font.pointSize * 20
    }

    /// Blocks are laid end to end; the newline between them is what makes
    /// each one its own paragraph.
    ///
    /// It belongs to the block *before* it — a paragraph ends at its newline —
    /// so it is given that block's style, which is where the spacing after a
    /// heading or a list item lives.
    static func appendBreak(to result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let previous = result.attributes(at: result.length - 1, effectiveRange: nil)
            .filter { $0.key == .font || $0.key == .paragraphStyle }
        result.append(NSAttributedString(string: "\n", attributes: previous))
    }

    /// Reserves the box's top and bottom air on a code block's outer lines,
    /// so the drawn box clears the blocks above and below it. Every line
    /// between them keeps the plain style — code reads as code, not as a
    /// column of spaced-out paragraphs.
    static func padEnds(
        of range: NSRange, in result: NSMutableAttributedString,
        style: NSParagraphStyle, gap: CGFloat
    ) {
        guard range.length > 0 else { return }
        let text = result.string as NSString
        let opening = NSIntersectionRange(
            text.lineRange(for: NSRange(location: range.location, length: 0)), range
        )
        let closing = NSIntersectionRange(
            text.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0)), range
        )
        let isOneLine = opening == closing

        if let top = style.mutableCopy() as? NSMutableParagraphStyle {
            top.paragraphSpacingBefore += codeBoxPadding
            if isOneLine { top.paragraphSpacing += codeBoxPadding + gap }
            result.addAttribute(.paragraphStyle, value: top, range: opening)
        }
        if !isOneLine, let bottom = style.mutableCopy() as? NSMutableParagraphStyle {
            bottom.paragraphSpacing += codeBoxPadding + gap
            result.addAttribute(.paragraphStyle, value: bottom, range: closing)
        }
    }

    /// Best effort, as the spec says: the cells are padded out to a common
    /// width and set monospaced, so the columns line up as text. No rules, no
    /// cell backgrounds — a table stays something you read.
    static func tableLines(_ rows: [[String]]) -> [String] {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return [] }
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (column, text) in row.enumerated() {
                widths[column] = max(widths[column], text.count)
            }
        }
        return rows.map { row in
            let padded = (0 ..< columns).map { column -> String in
                let text = column < row.count ? row[column] : ""
                return text + String(repeating: " ", count: max(0, widths[column] - text.count))
            }
            var line = padded.joined(separator: "  ")
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// The aligned rows as one paragraph of monospaced text.
    static func appendTable(
        _ rows: [[String]], to result: NSMutableAttributedString, font: NSFont
    ) {
        let lines = tableLines(rows)
        guard !lines.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = (font.pointSize * 0.5).rounded()
        result.append(NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [
                .font: monospaced(font.pointSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        ))
    }
}
