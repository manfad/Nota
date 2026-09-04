import AppKit

/// A rendered pane beside the editor: a read-only text view showing what one
/// of Nota's renderers made of the note. The document's shared tab strip lives
/// above the editor/preview split, outside this view.
///
/// It is a view of the note, never a second place to type in it. Clicking a
/// block does not put a caret here — it sends you to that block in the editor,
/// which is the only place a note is ever edited.
///
/// Everything a rendered pane does is here: the blocks and their source
/// ranges, the band under the one being pointed at, the find bar, the frozen
/// wrap width, the scroll position kept across renders, and the key that says
/// whether a fresh render is worth making at all. What is *not* here is the
/// one thing that differs between a `.md` tab and a `.tex` one — which
/// renderer the note goes through. A subclass answers that in `render(_:in:)`
/// and writes down nothing else.
class RenderedPreviewView: NSView, PreviewContent {

    private let scrollView = NSScrollView()
    private let textView: PreviewTextView

    /// The page's own ⌘F bar, floating in the top-trailing corner of the
    /// column — reading mode searches what is on screen rather than fetching
    /// the editor back to search that.
    private let findBar = FindBarView(placeholder: "Find in page")
    private lazy var findSession = TextFindSession(bar: findBar, textView: textView)

    /// The block the reader last pointed at, or the one the caret is in.
    private var blocks: [(range: NSRange, source: NSRange)] = []
    /// An edit has moved the text under the bands; they mean nothing again
    /// until the next render arrives.
    private var blocksAreStale = false
    private(set) var highlightedSourceRange: NSRange?
    /// Whether the render is being held at a fixed wrap width — see
    /// `freezeWidth()`.
    private var widthIsFrozen = false
    /// What the render on screen was made from — see `RenderKey`.
    private var renderedKey: RenderKey?

    /// Run when a block is clicked, with the source it came from.
    var onBlockClick: ((NSRange) -> Void)?

    /// Run when a task item's checkbox is clicked, with the source of the
    /// item it belongs to. A checkbox is a control rather than a jump, so it
    /// works in reading mode as well as split — and it is neither a block
    /// click nor the start of a selection.
    var onTaskToggle: ((NSRange) -> Void)?

    /// Run when the pane changes width. Pictures and rules are drawn to fit
    /// the pane, so a resize is a reason to render again.
    var onWidthChange: (() -> Void)?
    private var renderedWidth: CGFloat = 0

    /// Run when the render's own ⌘F bar opens or closes. It takes the top of
    /// the column, which is where the mode control floats.
    var onFindBarVisibilityChange: ((Bool) -> Void)?

    /// Whether that bar is up, and how tall it is standing. The page cannot
    /// be typed into, so its bar never grows a replace row — but the column
    /// asks all the same.
    var isFindBarVisible: Bool { findSession.isVisible }

    var findBarHeight: CGFloat { findBar.stackHeight }

    /// Whether a click on a block jumps to it in the editor. In split the
    /// render is a map into the text beside it, so it does. In reading it is
    /// the page being read and there is no editor on screen to jump to, so a
    /// click there is just a click: no jump, and no band lit under it. A link
    /// still opens either way — that is settled before this is asked.
    var sendsBlockClicks = true {
        didSet {
            guard sendsBlockClicks != oldValue else { return }
            textView.sendsBlockClicks = sendsBlockClicks
        }
    }

    /// Whether the pane takes the keyboard. Only in reading mode, where it is
    /// the only thing on screen: in split the caret stays in the editor.
    var takesKeyboard: Bool {
        get { textView.takesKeyboard }
        set { textView.takesKeyboard = newValue }
    }

    /// Holds the render still at the width it is being read at, for as long as
    /// the column beside it is moving. A text view re-wraps its whole document
    /// every time its width changes, so a column animating across two hundred
    /// milliseconds otherwise re-wraps the note on every frame — that is the
    /// jank a mode switch used to have. The page slides at the width it had
    /// and re-wraps once, when the column has landed.
    ///
    /// A pane with no width yet has nothing to hold: it is coming in from
    /// collapsed, and its first real width is the one it lands at.
    func freezeWidth() -> Bool {
        guard !widthIsFrozen, let container = textView.textContainer,
              container.size.width > 1
        else { return false }
        widthIsFrozen = true
        container.widthTracksTextView = false
        return true
    }

    /// Lets the render take the column's width again and wrap to it.
    func thawWidth() {
        guard widthIsFrozen, let container = textView.textContainer else { return }
        widthIsFrozen = false
        container.widthTracksTextView = true
        container.size = NSSize(
            width: max(0, textView.bounds.width - textView.textContainerInset.width * 2),
            height: container.size.height
        )
    }

    /// Puts the keyboard in the pane — reading mode's answer to `focusEditor`.
    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

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
        // Stated rather than left to the default, since a render that holds
        // something against the trailing edge has to know where it is.
        container.lineFragmentPadding = RenderStyle.lineFragmentPadding
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = PreviewTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        // Nota brings its own bar, so AppKit's never installs itself above
        // the page: reading mode's ⌘F opens the pill in the corner instead.
        textView.usesFindBar = false
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
        textView.onCheckboxClick = { [weak self] index in self?.tickedTask(at: index) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Added after the page, so the pill floats over it, and pinned to the
        // mode control's own corner — the two share it, and the control gets
        // out of the way while the bar is up.
        textView.findSession = findSession
        findSession.onVisibilityChange = { [weak self] visible in
            self?.onFindBarVisibilityChange?(visible)
        }
        findBar.onHeightChange = { [weak self] in
            guard let self else { return }
            onFindBarVisibilityChange?(isFindBarVisible)
        }
        findBar.floatStack(
            in: self, under: topAnchor, gap: ModeControlOverlay.controlTopInset,
            trailingInset: ModeControlOverlay.controlInset
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let width = contentWidth
        // Only a real change, and never while re-rendering at the width that
        // is already in the text: the render must not ask for another one.
        // A frozen render is not wrapped to the column at all, so the column
        // moving under it is not news either.
        guard !widthIsFrozen, width > 0, abs(width - renderedWidth) >= 1 else { return }
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

    /// One rectangle per fenced code block, in the text view's coordinates.
    var codeBoxRects: [NSRect] { textView.codeBoxRects }

    /// The lit block's band, if one is lit.
    var highlightedBandRect: NSRect? { textView.bandRect }

    /// What this pane makes of a note. The one thing a subclass has to say,
    /// and the only place a `.md` tab and a `.tex` one part company.
    func render(_ note: Note, in context: PreviewContext, width: CGFloat) -> RenderedDocument {
        .empty
    }

    /// Renders the note, unless the pane is already showing what it would
    /// make. A mode switch, a tab switch, a resize and a settings change all
    /// ask for a render; most of the time nothing the render is made from has
    /// moved, and the answer is on screen already.
    ///
    /// A render nobody can see is not worth making at all — the column is
    /// away, and the mode that brings it back asks again on the way in.
    func show(_ note: Note, in context: PreviewContext) {
        guard context.isVisible else { return }
        let text = note.text
        let width = contentWidth
        if let renderedKey, renderedKey.matches(
            note: note, text: text, font: context.font, width: width
        ) { return }
        let rendered = render(note, in: context, width: width)
        renderedKey = RenderKey(
            noteID: note.id, text: text, filePath: note.fileURL?.path,
            fontName: context.font.fontName, fontSize: context.font.pointSize,
            // A render with no picture and no rule in it is right at any
            // width, so widening the column is not a reason to make it again.
            width: rendered.dependsOnWidth ? width : nil
        )
        show(rendered)
    }

    /// Throws the remembered render away, so the next ask makes a fresh one —
    /// for everything the key cannot see, such as a picture in the store
    /// redrawn under an unchanged token.
    func invalidateRender() {
        renderedKey = nil
    }

    /// What the render on screen was made from. Nothing here is about the
    /// look of it: the colours are the system's own and follow light and dark
    /// without a fresh render.
    ///
    /// The file's path is in it because a LaTeX render resolves its pictures
    /// beside the note — the same source in another folder is another page.
    private struct RenderKey {
        let noteID: UUID
        let text: String
        let filePath: String?
        let fontName: String
        let fontSize: CGFloat
        /// The width it was fitted to, when it was fitted to one at all.
        let width: CGFloat?

        func matches(note: Note, text: String, font: NSFont, width: CGFloat) -> Bool {
            noteID == note.id && self.text == text && filePath == note.fileURL?.path
                && fontName == font.fontName && fontSize == font.pointSize
                && (self.width == nil || self.width == width)
        }
    }

    /// Swaps in a fresh render. The pane is re-rendered on every keystroke
    /// once typing stops, so it stays where the reader left it rather than
    /// jumping back to the top each time.
    func show(_ render: RenderedDocument) {
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
        // Replacing the storage leaves AppKit's own caret at the end of what
        // it put in. The render is not a place a caret lives — in split it is
        // never selected at all — so a fresh page starts unselected, and only
        // a click in reading mode puts a caret in it.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // The band is drawn from ranges that have just been replaced.
        setHighlight(nil)
        // So are the find bar's: temporary attributes belong to the layout
        // manager, and the storage under them has just been swapped out.
        findSession.refresh()
    }

    // MARK: - Blocks

    /// An edit has moved everything: the bands mean nothing until the pane is
    /// rendered again, so the lit one goes out rather than lying.
    func invalidateBlocks() {
        blocksAreStale = true
        setHighlight(nil)
    }

    /// Puts the lit block out without touching the blocks themselves — what
    /// reading mode does on the way in. The page is read on its own there;
    /// there is no caret on screen for a band to be answering to.
    func clearHighlight() {
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
        guard sendsBlockClicks, !blocksAreStale,
              let block = blockIndex(forRendered: index)
        else { return }
        setHighlight(block)
        onBlockClick?(blocks[block].source)
    }

    /// A checkbox was pressed. Nothing is lit and nothing is jumped to: the
    /// item's source goes out to be rewritten, and the render comes back
    /// changed the way it does after any other edit.
    private func tickedTask(at index: Int) {
        guard !blocksAreStale, let block = blockIndex(forRendered: index) else { return }
        onTaskToggle?(blocks[block].source)
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
    }
}

// MARK: - The text view

/// The pane's text view.
///
/// In Split a click here is a jump to a block, not a place to type: the caret
/// stays in the editor, and everything that is not a link reports the block it
/// landed in. In Reading there is no editor on screen to jump to, so it is an
/// ordinary read-only text view again — a click puts the caret in the render,
/// drag to select, double-click a word, ⌘C to copy — and a link still opens
/// the same way it does in Split.
///
/// It takes the keyboard in reading mode only, where the editor is collapsed
/// and something has to answer the arrow and page keys — and ⌘F, which opens
/// a find bar over the render itself. Nothing here reaches back to the editor:
/// reading mode is left through the mode control, ⇧⌘P / ⌥⇧⌘P or the View menu,
/// and by nothing else.
private final class PreviewTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    /// A press that landed on a task item's checkbox, with the character it
    /// is. It comes before everything else a press does here — a checkbox is
    /// a control, so it is not a jump in split, not a caret in reading, and
    /// never the start of a drag.
    var onCheckboxClick: ((Int) -> Void)?
    var takesKeyboard = false
    /// The page's find bar. ⌘F, ⌘G, ⇧⌘G and ⌘E are nil-targeted
    /// `performTextFinderAction:` items, so they land here whenever this view
    /// has the keyboard — which is reading mode, and only there.
    weak var findSession: TextFindSession?
    /// Mirrors `RenderedPreviewView.sendsBlockClicks`: true in Split, where a
    /// click is a jump to source, false in Reading, where it is an ordinary
    /// click in an ordinary text view.
    var sendsBlockClicks = true

    /// The rendered range of the block being pointed at, if any.
    var highlightedRange: NSRange? {
        didSet {
            guard highlightedRange != oldValue else { return }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { takesKeyboard }

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession?.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(NSTextView.performTextFinderAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return TextFindSession.handles(action)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // In both modes, and before anything else: the box is the one thing
        // in the render you press rather than read.
        if let checkbox = checkboxIndex(at: point) {
            onCheckboxClick?(checkbox)
            return
        }

        // Reading has no block sync to report to: every click behaves like
        // an ordinary text view's, including a link opening under it exactly
        // as `super` already handles for Split below.
        guard sendsBlockClicks else {
            super.mouseDown(with: event)
            return
        }

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

    /// The task item's box under a point, if the point is on one. The nearest
    /// glyph is not the same question as the glyph pressed — the insertion
    /// point at the end of a line is the whole rest of the line away — so the
    /// box's own rectangle has to hold the point as well.
    private func checkboxIndex(at point: NSPoint) -> Int? {
        guard let storage = textStorage, let layoutManager, let textContainer,
              storage.length > 0
        else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              storage.attribute(.attachment, at: index, effectiveRange: nil)
                  is TaskCheckboxAttachment
        else { return nil }
        let box = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
        )
        return box.contains(inContainer) ? index : nil
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        // The wash under a fenced block is one box behind the whole thing,
        // drawn to the pane's own margins rather than around each line's
        // glyphs — code is a slab, and ragged lines should not show as one.
        let boxes = codeBoxRects
        if !boxes.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            for box in boxes {
                NSBezierPath(
                    roundedRect: box,
                    xRadius: RenderStyle.codeBoxCornerRadius,
                    yRadius: RenderStyle.codeBoxCornerRadius
                ).fill()
            }
        }

        // Over the top of them, so a lit code block darkens evenly instead of
        // showing two shapes competing.
        guard let band = bandRect else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        band.fill()
    }

    /// A box for each fenced block: its lines' used rects run out to the
    /// pane's margins and given air on every side.
    var codeBoxRects: [NSRect] {
        guard let storage = textStorage, let layoutManager, let textContainer,
              storage.length > 0
        else { return [] }

        // A block below the laid-out region has no fragments to measure yet.
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        var boxes: [NSRect] = []
        storage.enumerateAttribute(
            .notaCodeBlock, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil
            )
            guard glyphs.length > 0 else { return }

            var used = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
                used = used.union(usedRect)
            }
            guard !used.isNull else { return }

            // A fenced block inside a list is indented with it; everything
            // else starts at the margin.
            let paragraph = storage.attribute(
                .paragraphStyle, at: range.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let outerIndent = max(0, (paragraph?.headIndent ?? 0) - RenderStyle.codeBoxInset)
            let left = origin.x + outerIndent
            let right = bounds.width - origin.x
            boxes.append(NSRect(
                x: left,
                y: used.minY + origin.y - RenderStyle.codeBoxPadding,
                width: max(0, right - left),
                height: used.height + RenderStyle.codeBoxPadding * 2
            ))
        }
        return boxes
    }

    private static let bandPadding: CGFloat = 2

    /// The lit block's line fragments, run out to both edges of the pane: the
    /// band marks a place in the document, not a piece of text.
    var bandRect: NSRect? {
        guard let range = highlightedRange, range.length > 0,
              let storage = textStorage, let layoutManager, let textContainer,
              NSMaxRange(range) <= storage.length
        else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y

        // A lit fenced block takes the box's own air, so the two shapes land
        // on each other and it darkens as one rather than showing an edge.
        let isCodeBlock = storage.attribute(
            .notaCodeBlock, at: range.location, effectiveRange: nil
        ) != nil
        let padding = isCodeBlock ? RenderStyle.codeBoxPadding : Self.bandPadding
        return NSRect(
            x: 0, y: rect.minY - padding,
            width: bounds.width, height: rect.height + padding * 2
        )
    }
}
