import AppKit

/// The left gutter.
///
/// One number per hard line — a line that wraps onto three rows still gets a
/// single number, with the continuation rows left blank. Positions come from
/// the layout manager's own line fragment rects, so the numbers stay welded
/// to the text at any font size or line spacing.
final class LineNumberRulerView: NSRulerView {
    private static let horizontalPadding: CGFloat = 12
    private static let minimumDigits = 3

    private weak var textView: NSTextView?
    private var fontSize: CGFloat = 13

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()

        scrollView.contentView.postsBoundsChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scrollView.contentView as Any),
            (NSText.didChangeNotification, textView as Any),
            (NSTextView.didChangeSelectionNotification, textView as Any),
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refresh), name: name, object: object
            )
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Called directly when something the notifications cannot see changes —
    /// a tab switch swaps the whole text storage, and settings change the font.
    @objc func refresh() {
        updateThickness()
        needsDisplay = true
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        refresh()
    }

    private var numberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(10, fontSize - 2), weight: .regular)
    }

    private func updateThickness() {
        let lines = max(1, hardLineCount)
        let digits = max(Self.minimumDigits, String(lines).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + Self.horizontalPadding)
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    private var hardLineCount: Int {
        guard let text = textView?.string as NSString? else { return 1 }
        var count = 1
        for index in 0..<text.length where text.character(at: index) == 0x0A { count += 1 }
        return count
    }

    // MARK: - Drawing

    /// `NSRulerView.draw` paints a hairline along the ruler's inner edge; we want
    /// a bare gutter, so bypass it and draw only the numbers.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // macOS 14 stopped clipping views to their bounds by default, so the
        // ruler must clip itself or its numbers leak into the footer.
        clipsToBounds = true
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        let offset = convert(NSPoint.zero, from: textView).y + origin.y

        let visible = scrollView?.contentView.bounds ?? .zero
        // Never draw a number outside the band the clip view actually shows;
        // `glyphRange(forBoundingRect:)` also returns fragments that merely
        // intersect it, whose numbers would otherwise land on the footer.
        if let clipView = scrollView?.contentView {
            NSBezierPath(rect: convert(clipView.bounds, from: clipView).intersection(bounds)).addClip()
        }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let visibleChars = layoutManager.characterRange(
            forGlyphRange: visibleGlyphs, actualGlyphRange: nil
        )

        let currentLine = lineIndex(of: textView.selectedRange().location, in: text)
        var lineNumber = lineIndex(of: visibleChars.location, in: text)
        var index = text.lineRange(for: NSRange(location: visibleChars.location, length: 0)).location

        while index <= NSMaxRange(visibleChars), index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            // Only the first fragment of a wrapped line gets a number.
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: nil
            )
            draw(lineNumber, at: fragment.minY + offset, height: fragment.height,
                 isCurrent: lineNumber == currentLine)

            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }

        // A note ending in a newline has one more, empty, line.
        if text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                draw(lineNumber, at: extra.minY + offset, height: extra.height,
                     isCurrent: lineNumber == currentLine)
            }
        }
    }

    private func draw(_ number: Int, at y: CGFloat, height: CGFloat, isCurrent: Bool) {
        let font = numberFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isCurrent ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ]
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        // Right-aligned against the gutter's inner edge, sitting on the same
        // baseline as the first row of the line.
        label.draw(
            at: NSPoint(
                x: ruleThickness - size.width - Self.horizontalPadding / 2,
                y: y + (font.ascender - font.descender < height
                        ? (height - size.height) / 2
                        : 0)
            ),
            withAttributes: attributes
        )
    }

    /// 1-based number of the hard line containing `location`.
    private func lineIndex(of location: Int, in text: NSString) -> Int {
        let clamped = min(max(0, location), text.length)
        var count = 1
        for index in 0..<clamped where text.character(at: index) == 0x0A { count += 1 }
        return count
    }
}
