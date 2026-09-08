import AppKit

/// A whole document as one tall picture — SPEC "## Export", Done 63.
///
/// `PDFPaginator`'s opposite number, and deliberately its opposite in every
/// way that matters. A PDF is paper: white, cut into pages, and every dynamic
/// colour resolved back to its light value first, because a page has no
/// background to read white text against. A PNG is the *screen*: one image as
/// tall as the document is, in the appearance the reader is looking at it in,
/// standing on the ground their pane is drawing. Nothing is lightened here
/// and nothing is paginated.
///
/// Nothing in this file knows what it was handed. `Export.swift` decides
/// whether the picture is a render or the editor's own listing and hands over
/// the text, the measure it is to be laid out at, the appearance to resolve
/// under and the colour behind it; this lays it out, draws it, and writes the
/// file. Synchronously, the way the two PDFs Nota writes itself are.
enum SnapshotPNG {

    /// The margins the picture keeps: the preview pane's own, so the text
    /// starts as far from the edge as it does on screen. `width` is the
    /// text's measure — the same measure a render is made at — and the image
    /// is that plus a margin on each side.
    static let horizontalInset = RenderStyle.previewHorizontalInset
    static let verticalInset = RenderStyle.previewVerticalInset

    /// How tall a document may be and still be one picture, in points. Past
    /// this there is no scale that helps: 30,000 points is already some four
    /// hundred pages of prose, and a file that size is neither drawable in
    /// one pass nor openable by anything the reader has. `Export.swift`
    /// refuses rather than writing something nobody can look at.
    static let maximumHeight: CGFloat = 30_000

    /// The longest side a picture may have in *pixels* and still be drawn at
    /// Retina scale. Metal and every image reader on the Mac agree on 16,384
    /// as the ceiling, so a document that would pass it at 2x is drawn at 1x
    /// instead — smaller ink, but a file that opens.
    static let maximumPixels: CGFloat = 16_384

    /// Lays `text` out at `width` and writes it to `url` as one PNG.
    ///
    /// - Parameters:
    ///   - width: the text's own measure, not the picture's: the image comes
    ///     out `width` plus a margin on each side.
    ///   - appearance: what the dynamic colours, the formulas and the
    ///     diagrams resolve under — the window's, so a reader in dark mode
    ///     gets the dark page they are looking at.
    ///   - background: the pane's own ground, drawn behind the whole height.
    ///     A PNG has an alpha channel and would otherwise be a picture of ink
    ///     floating on nothing.
    static func write(
        text: NSAttributedString, width: CGFloat, appearance: NSAppearance?,
        background: NSColor, to url: URL
    ) throws {
        guard text.length > 0 else { throw Exporter.Failure.nothingToExport }

        let view = makeTextView(
            text, width: max(1, width), appearance: appearance, background: background
        )
        let size = view.frame.size
        guard size.height > 0, size.height <= maximumHeight else {
            throw Exporter.Failure.tooLongForAnImage
        }

        let bitmap = try draw(view, size: size, at: scale(for: size), appearance: appearance)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Exporter.Failure.nothingToExport
        }
        try data.write(to: url, options: .atomic)
    }

    /// Retina where the picture will still open, one to one where it would
    /// not. Read off the long side, since a wide short picture and a narrow
    /// tall one hit the same ceiling.
    static func scale(for size: NSSize) -> CGFloat {
        max(size.width, size.height) * 2 <= maximumPixels ? 2 : 1
    }

    // MARK: - The view

    /// The view the picture is taken of. It is never in a window and never on
    /// screen: it exists to be laid out at the measure and asked how tall
    /// that made it, which is the picture's height.
    ///
    /// Built the way `PDFPaginator.makeTextView` builds its own — the same
    /// floor of nothing, the same unbounded ceiling, the same line-fragment
    /// padding — with the two differences that make it a screen rather than a
    /// page: it draws its own background, and it wears the reader's
    /// appearance.
    private static func makeTextView(
        _ text: NSAttributedString, width: CGFloat,
        appearance: NSAppearance?, background: NSColor
    ) -> NSTextView {
        let view = NSTextView(frame: NSRect(
            x: 0, y: 0, width: width + horizontalInset * 2, height: 0
        ))
        view.appearance = appearance
        view.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        // A text view is born with its frame as its floor, and a floor is a
        // band of empty ground under every note that does not fill one.
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.lineFragmentPadding = RenderStyle.lineFragmentPadding
        // Tracking the view means the container is the frame less the two
        // insets, which is the measure asked for.
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: width, height: .greatestFiniteMagnitude
        )
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        // Unlike the PDF, this one paints its ground: there is no white paper
        // under a PNG, only whatever the pane itself was drawing.
        view.drawsBackground = true
        view.backgroundColor = background
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
        }
        view.sizeToFit()
        return view
    }

    // MARK: - The picture

    /// The view into pixels. `cacheDisplay` draws through the real drawing
    /// path — every attachment that paints itself, a chip, a formula, a
    /// diagram, runs its own handler — and the appearance is made current
    /// around it so each of them resolves for the reader's window rather than
    /// for whatever the process happens to be in.
    private static func draw(
        _ view: NSView, size: NSSize, at scale: CGFloat, appearance: NSAppearance?
    ) throws -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let bitmap else { throw Exporter.Failure.tooLongForAnImage }
        // The rep is asked for more pixels than points, which is the whole of
        // what "2x" means to `cacheDisplay`.
        bitmap.size = size

        let paint = { view.cacheDisplay(in: view.bounds, to: bitmap) }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(paint)
        } else {
            paint()
        }
        return bitmap
    }
}
