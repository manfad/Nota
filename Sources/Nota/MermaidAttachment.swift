import AppKit

/// One diagram as one character in the render.
///
/// The same mechanism the maths, the rule and the pictures use: an image the
/// size of the box, with the drawing handler run at draw time, which is where
/// `MermaidPalette.standard` resolves its colours — so a diagram follows light
/// and dark without being laid out again.
///
/// Unlike a formula it is a block, not a letter in a line: `bounds` sit on the
/// baseline with nothing below it, and the paragraph around it is centred, the
/// way a display formula's is. A diagram wider than the column is scaled down
/// to fit with its aspect kept, which is the one thing about it that depends
/// on the pane's width.
final class MermaidAttachment: NSTextAttachment {
    let diagram: MermaidDiagram
    /// The font the diagram was measured against — the render's own, so a
    /// diagram grows with Settings the way the maths does.
    let font: NSFont
    /// The size it is drawn at: the natural one, or the column's width with
    /// the aspect ratio kept.
    let displaySize: NSSize
    /// What the natural size was scaled by, `1` when it fitted.
    let scale: CGFloat

    init(diagram: MermaidDiagram, font: NSFont, maximumWidth: CGFloat) {
        self.diagram = diagram
        self.font = font
        let natural = diagram.size
        let fitted: CGFloat
        if natural.width > 0, maximumWidth > 0, natural.width > maximumWidth {
            fitted = maximumWidth / natural.width
        } else {
            fitted = 1
        }
        scale = fitted
        displaySize = NSSize(
            width: max(1, (natural.width * fitted).rounded()),
            height: max(1, (natural.height * fitted).rounded())
        )
        super.init(data: nil, ofType: nil)

        let size = displaySize
        image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            if fitted != 1 { context.scaleBy(x: fitted, y: fitted) }
            diagram.draw(in: context, palette: .standard)
            context.restoreGState()
            return true
        }
        bounds = NSRect(origin: .zero, size: displaySize)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
