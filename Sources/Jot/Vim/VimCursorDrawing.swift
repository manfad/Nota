import AppKit

/// The shape of the caret. In a monochrome footer this is what actually tells
/// you which mode you are in, so it matters more than the badge does.
enum VimCursorStyle: Equatable {
    /// AppKit's own thin caret — insert mode, and every mode when vim is off.
    case bar
    /// Normal and visual: a translucent block over the character under it.
    case block
    /// Replace: half as tall, so overwriting never looks like inserting.
    case halfBlock
}

enum VimCursorDrawing {
    /// Translucent rather than inverted, so the character underneath still
    /// reads through the block.
    static var fillColor: NSColor { NSColor.labelColor.withAlphaComponent(0.35) }

    /// The block for a caret rect and the width of the character it sits on.
    ///
    /// `NSTextView` is flipped, so the half-height block is pushed down to sit
    /// on the baseline rather than floating at the cap height.
    static func rect(
        insertionPoint: NSRect, characterWidth: CGFloat, style: VimCursorStyle
    ) -> NSRect {
        var rect = insertionPoint
        switch style {
        case .bar:
            return rect
        case .block:
            rect.size.width = max(characterWidth, insertionPoint.width)
            return rect
        case .halfBlock:
            rect.size.width = max(characterWidth, insertionPoint.width)
            rect.size.height = insertionPoint.height / 2
            rect.origin.y = insertionPoint.origin.y + insertionPoint.height / 2
            return rect
        }
    }
}
