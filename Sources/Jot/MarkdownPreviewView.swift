import AppKit

/// The rendered pane beside the editor: a header band matching the tab strip,
/// and under it a read-only text view showing what `MarkdownRenderer` made of
/// the note.
///
/// It is a view of the note, never a second place to type in it. Clicking a
/// block does not put a caret here — it sends you to that block in the editor,
/// which is the only place a note is ever edited.
final class MarkdownPreviewView: NSView {

    static let title = "Markdown Preview"

    private let header = PreviewHeaderView()
    private let scrollView = NSScrollView()
    private let textView: PreviewTextView

    /// The block the reader last pointed at, or the one the caret is in.
    private var blocks: [(range: NSRange, source: NSRange)] = []
    /// An edit has moved the text under the bands; they mean nothing again
    /// until the next render arrives.
    private var blocksAreStale = false
    private(set) var highlightedSourceRange: NSRange?

    /// Run when a block is clicked, with the source it came from.
    var onBlockClick: ((NSRange) -> Void)?

    /// Run when the pane changes width. Pictures and rules are drawn to fit
    /// the pane, so a resize is a reason to render again.
    var onWidthChange: (() -> Void)?
    private var renderedWidth: CGFloat = 0

    /// Matched to the editor's own padding, so the two columns of text start
    /// the same distance from their edges.
    var horizontalInset: CGFloat = 20 {
        didSet {
            guard horizontalInset != oldValue else { return }
            applyInsets()
        }
    }

    private static let verticalInset: CGFloat = 14

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = PreviewTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(
            width: horizontalInset, height: Self.verticalInset
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Monochrome, like everything else in the pane: a link is underlined,
        // not tinted.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.onClick = { [weak self] index in self?.clicked(at: index) }

        header.translatesAutoresizingMaskIntoConstraints = false
        header.title = Self.title
        header.leadingInset = horizontalInset
        addSubview(header)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Pinned to the very top, not the safe area: the band has to line
            // up with the tab strip across the divider, title bar and all.
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: TabBarView.height),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let width = contentWidth
        // Only a real change, and never while re-rendering at the width that
        // is already in the text: the render must not ask for another one.
        guard width > 0, abs(width - renderedWidth) >= 1 else { return }
        renderedWidth = width
        onWidthChange?()
    }

    // MARK: - Content

    /// The width a picture or a rule can be drawn to: the pane less the two
    /// margins. Zero before the first layout pass, which the renderer reads
    /// as "no width to fit to yet".
    var contentWidth: CGFloat {
        let width = scrollView.contentSize.width - horizontalInset * 2
        return width > 1 ? width : 0
    }

    /// What the pane is showing, for the tests.
    var renderedText: String { textView.string }

    var renderedContent: NSAttributedString { textView.attributedString() }

    var headerTitle: String { header.title }

    /// Swaps in a fresh render. The pane is re-rendered on every keystroke
    /// once typing stops, so it stays where the reader left it rather than
    /// jumping back to the top each time.
    func show(_ render: MarkdownRenderer.Result) {
        let previous = scrollFraction
        renderedWidth = contentWidth
        blocks = render.blocks
        blocksAreStale = false
        textView.textStorage?.setAttributedString(render.text)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        layoutSubtreeIfNeeded()
        scroll(to: previous)
        // The band is drawn from ranges that have just been replaced.
        setHighlight(nil)
    }

    // MARK: - Blocks

    /// An edit has moved everything: the bands mean nothing until the pane is
    /// rendered again, so the lit one goes out rather than lying.
    func invalidateBlocks() {
        blocksAreStale = true
        setHighlight(nil)
    }

    /// Lights the block the editor's caret is sitting in and brings it into
    /// view. Returns whether there was one to light.
    @discardableResult
    func highlightBlock(containingSource location: Int) -> Bool {
        guard !blocksAreStale, let index = blockIndex(forSource: location) else {
            setHighlight(nil)
            return false
        }
        setHighlight(index)
        textView.scrollRangeToVisible(blocks[index].range)
        return true
    }

    private func clicked(at index: Int) {
        guard !blocksAreStale, let block = blockIndex(forRendered: index) else { return }
        setHighlight(block)
        onBlockClick?(blocks[block].source)
    }

    private func setHighlight(_ index: Int?) {
        highlightedSourceRange = index.map { blocks[$0].source }
        textView.highlightedRange = index.map { blocks[$0].range }
    }

    /// The block holding this place in the source, or the last one to start
    /// before it — a caret on the blank line between two paragraphs belongs
    /// to the one above it.
    private func blockIndex(forSource location: Int) -> Int? {
        var candidate: Int?
        for (index, block) in blocks.enumerated() {
            if NSLocationInRange(location, block.source) { return index }
            if block.source.location <= location { candidate = index }
        }
        return candidate
    }

    private func blockIndex(forRendered location: Int) -> Int? {
        var candidate: Int?
        for (index, block) in blocks.enumerated() {
            if NSLocationInRange(location, block.range) { return index }
            if block.range.location <= location { candidate = index }
        }
        return candidate
    }

    // MARK: - Scrolling

    /// How far down the pane is, 0 at the top and 1 at the bottom.
    var scrollFraction: CGFloat {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return 0 }
        let scrollable = document.bounds.height - clip.bounds.height
        guard scrollable > 0 else { return 0 }
        return min(1, max(0, clip.bounds.origin.y / scrollable))
    }

    private func scroll(to fraction: CGFloat) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return }
        let scrollable = document.bounds.height - clip.bounds.height
        guard scrollable > 0 else { return }
        let y = (scrollable * min(1, max(0, fraction))).rounded()
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func applyInsets() {
        textView.textContainerInset = NSSize(
            width: horizontalInset, height: Self.verticalInset
        )
        header.leadingInset = horizontalInset
    }
}

// MARK: - The header band

/// The pane's top band. It is the tab strip's opposite number across the
/// divider, so it takes the same height and the same paper the strip sits on,
/// and says what the pane is rather than sitting there empty.
private final class PreviewHeaderView: NSView {
    var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            needsDisplay = true
        }
    }

    var leadingInset: CGFloat = 20 {
        didSet {
            guard leadingInset != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The band is chrome, so dragging it moves the window the way the strip
    /// beside it does.
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: leadingInset, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - The text view

/// The pane's text view.
///
/// It never becomes first responder: a click here is a jump to a block, not a
/// place to type, and the caret must stay in the editor. Dragging to select
/// is given up for that — a link still opens, and everything else reports the
/// block it landed in.
private final class PreviewTextView: NSTextView {
    var onClick: ((Int) -> Void)?

    /// The rendered range of the block being pointed at, if any.
    var highlightedRange: NSRange? {
        didSet {
            guard highlightedRange != oldValue else { return }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // A link is the one thing in the pane that does something of its own
        // with a click; everything else is a block to be sent to.
        if let storage = textStorage, index < storage.length,
           storage.attribute(.link, at: index, effectiveRange: nil) != nil {
            super.mouseDown(with: event)
            return
        }
        onClick?(index)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let band = bandRect else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        band.fill()
    }

    /// The lit block's line fragments, run out to both edges of the pane: the
    /// band marks a place in the document, not a piece of text.
    private var bandRect: NSRect? {
        guard let range = highlightedRange, range.length > 0,
              let layoutManager, let textContainer,
              NSMaxRange(range) <= (textStorage?.length ?? 0)
        else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y
        return NSRect(
            x: 0, y: rect.minY - 2, width: bounds.width, height: rect.height + 4
        )
    }
}
