import AppKit

/// One formula as one character in the render.
///
/// The same mechanism the rule and the pictures use: an image the size of the
/// box, and `bounds` that put it on the text's own baseline — origin below the
/// baseline by the formula's descent, so an inline `$x^2$` sits in the line
/// rather than on top of it. The drawing handler runs at draw time, which is
/// where `labelColor` is resolved, so light and dark follow without the
/// formula being laid out again.
final class MathAttachment: NSTextAttachment {
    let formula: MathFormula
    /// The font the formula was measured against — the render's own, so the
    /// maths scales with Settings' font size.
    let font: NSFont

    init(formula: MathFormula, font: NSFont) {
        self.formula = formula
        self.font = font
        super.init(data: nil, ofType: nil)
        let size = NSSize(width: max(1, formula.size.width), height: max(1, formula.size.height))
        let ascent = formula.ascent
        image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            formula.draw(
                at: NSPoint(x: rect.minX, y: rect.minY + ascent),
                in: context,
                color: .labelColor
            )
            return true
        }
        bounds = NSRect(
            x: 0, y: -formula.descent, width: size.width, height: size.height
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
