import AppKit

/// The preview column holding a rich-text document: an `.rtf` file or an
/// `.rtfd` package, laid out by AppKit's own reader, where a Markdown tab
/// would have its render (SPEC "## RTF").
///
/// An RTF tab has no editor behind it — Nota does not edit rich text — so this
/// is never a pane beside anything. It is the whole column, in reading mode,
/// the fourth viewer after a PDF, a picture and a book, and for the same
/// reason: Nota opens the file to be read, not to be written to.
///
/// The document is read once with `NSAttributedString(url:options:
/// documentAttributes:)`, which takes both flavours by the same URL and brings
/// an RTFD's pictures along as attachments. What arrives is the author's own
/// type, colours and layout, and it is shown as it stands — this is a view of
/// a document, not a re-rendering of one. Two things are done to it on the way
/// in, and nothing else is: black body text is swapped for `labelColor` so the
/// page is legible on a dark ground (see `legible(_:)`), and every attachment
/// is given the explicit bounds a zoom then scales.
final class RTFPreviewView: NSView, PreviewContent {

    private let scrollView = NSScrollView()
    private let textView: RichTextView
    /// Shown instead of the document when the file has gone — deleted while
    /// the tab was open, or missing by the time the session comes back — or
    /// when it holds nothing AppKit can read as rich text.
    private let missingLabel = NSTextField(labelWithString: "")

    /// The document's own ⌘F bar, floating in the top-trailing corner of the
    /// column — the same pill the editor, the render and the PDF use, over
    /// this view's own text storage.
    private let findBar = FindBarView(placeholder: "Find in document")
    private lazy var findSession = TextFindSession(bar: findBar, textView: textView)

    /// The document as it was read, before a zoom was applied to it. Every
    /// zoom is measured from here rather than from the last one, so pressing
    /// ⌘+ and ⌘- back to where you started puts the type back exactly.
    private var document: NSAttributedString?
    /// The tab and the file on screen. A show that would lay out the same
    /// document again does nothing: showing is asked on every resize and every
    /// tab switch, and reading the file again would be reading it for nothing.
    private var shownNoteID: UUID?
    private var shownPath: String?

    /// Where the next lay-out should land, as a share of the document's own
    /// height: what the session remembers. One-shot — once the document is on
    /// screen the reader owns where they are in it.
    private var pendingScroll: Double = 0

    var onFindBarVisibilityChange: ((Bool) -> Void)?

    var isFindBarVisible: Bool { findSession.isVisible }

    var findBarHeight: CGFloat { findBar.stackHeight }

    /// Files let go on the document. There is no text here to put one in —
    /// this is a view of a file, not a note — so a file dropped here opens as
    /// a tab, the same thing the strip does with it.
    var onDropFiles: (([URL]) -> Void)? {
        get { textView.onDropFiles }
        set { textView.onDropFiles = newValue }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    /// The same top and bottom air the rendered pane gives its text, so the
    /// two columns of type start the same distance down.
    private static let verticalInset: CGFloat = 14

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = RenderStyle.lineFragmentPadding
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = RichTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)

        // Read, never written — but selectable, so ⌘C takes the words out of
        // it the way it takes them out of any other page.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        // Nota brings its own bar, so AppKit's never installs itself above the
        // document: ⌘F opens the pill in the corner instead.
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
        textView.registerForDraggedTypes(PreviewFileDrop.types)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        // The same quiet voice the rest of the app uses for something that is
        // not there: the editor's own font family, secondary colour, centred
        // in the column with nothing else in it.
        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.alignment = .center
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.isHidden = true
        addSubview(missingLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            missingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            missingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 20
            ),
        ])

        // Added after the document, so the pill floats over it, and in the
        // same corner every other column keeps its bars in.
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

    // MARK: - Content

    /// Puts the tab's document in the pane, at the place it was left. Nothing
    /// here asks whether the column is on screen: a document already read
    /// costs nothing to hold, and the pane has to be right the moment it comes
    /// forward.
    func show(_ note: Note, in context: PreviewContext) {
        let path = note.fileURL?.path
        // A different tab, or the same tab's file rewritten under it: read it,
        // and take where the reader is from the note again rather than from
        // whatever the last document left here.
        guard note.id != shownNoteID || path != shownPath else { return }
        shownNoteID = note.id
        shownPath = path
        pendingScroll = note.scrollFraction
        document = note.richText.map(Self.prepared)
        missingLabel.font = Preferences.shared.font()
        missingLabel.stringValue = document == nil ? "Couldn’t open “\(note.title)”." : ""
        missingLabel.isHidden = document != nil
        scrollView.isHidden = document == nil
        install()
    }

    /// The file behind the document has changed under the tab, so what is on
    /// screen is of a file that no longer exists in that shape. Forgetting
    /// which path is showing is what makes the next `show` read it again.
    func invalidateRender() {
        shownPath = nil
    }

    /// Lays the document into the text view at the zoom it is being read at,
    /// and puts the reader back where they were — the share the session
    /// remembers on the way in, and their own place on every zoom after that.
    private func install() {
        let fraction = pendingScroll > 0 ? pendingScroll : Double(scrollFraction)
        let text = document.map { Self.scaled($0, by: zoomStorage) } ?? NSAttributedString()
        textView.textStorage?.setAttributedString(text)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        layoutSubtreeIfNeeded()
        scroll(to: CGFloat(fraction))
        pendingScroll = 0
        // Replacing the storage leaves AppKit's own caret at the end of what
        // it put in. A page starts unselected; only a click puts a caret in it.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // The bar's bands are temporary attributes on a storage that has just
        // been swapped out from under them.
        findSession.refresh()
    }

    // MARK: - The document, made legible and made scalable

    /// What is actually shown: the author's document with two things settled
    /// on the way in, and nothing else touched.
    private static func prepared(_ document: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: document)
        legible(text)
        normalizeAttachments(text)
        return text
    }

    /// Text the author left black on nothing is drawn in `labelColor`, which
    /// is black in a light window and near-white in a dark one. An RTF is
    /// written for paper: `\cf0` and a plain black `\cf` are both "the body
    /// text", not a colour anybody chose, and taking them at their word would
    /// print a page of black type onto Nota's dark ground.
    ///
    /// A run that says anything else keeps it. A red word stays red, and so
    /// does a black word the author put a highlight behind — a colour laid
    /// against a background of its own is a pair, and changing half of a pair
    /// is worse than leaving both alone.
    private static func legible(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole) { attributes, range, _ in
            guard attributes[.backgroundColor] == nil else { return }
            guard let colour = attributes[.foregroundColor] as? NSColor else {
                text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                return
            }
            guard isBlack(colour) else { return }
            text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
    }

    /// Whether a colour is the black an author writes body text in — near
    /// enough to it that no reader would call it a colour of its own, and
    /// opaque, since a faded grey is a choice.
    private static func isBlack(_ colour: NSColor) -> Bool {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return false }
        guard rgb.alphaComponent > 0.99 else { return false }
        return rgb.redComponent <= 0.15 && rgb.greenComponent <= 0.15
            && rgb.blueComponent <= 0.15
    }

    /// Every attachment is given the size it would have drawn at, written
    /// down as explicit bounds. An RTFD's pictures arrive with bounds of zero,
    /// which the layout reads as "the image's own size" — true at a zoom of 1
    /// and a lie at any other, since a zoom scales the bounds and zero times
    /// anything is still zero.
    private static func normalizeAttachments(_ text: NSMutableAttributedString) {
        text.forEachAttachmentRun { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                  attachment.bounds.size.width < 1 || attachment.bounds.size.height < 1,
                  let size = attachment.image?.size ?? attachment.attachmentCell?.cellSize(),
                  size.width > 0, size.height > 0
            else { return }
            attachment.bounds = NSRect(origin: .zero, size: size)
        }
    }

    /// The document at a zoom: every font, every measurement in a paragraph
    /// style and every attachment multiplied by it. This is what "zoom" means
    /// for text that is already laid out as text — the type grows and the
    /// lines re-wrap to the column, the way ⌘+ grows a Markdown render,
    /// rather than the page being magnified as a picture of itself.
    private static func scaled(
        _ document: NSAttributedString, by zoom: CGFloat
    ) -> NSAttributedString {
        guard abs(zoom - 1) > 0.0001 else { return document }
        let text = NSMutableAttributedString(attributedString: document)
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let scaled = NSFontManager.shared.convert(font, toSize: font.pointSize * zoom)
            text.addAttribute(.font, value: scaled, range: range)
        }
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            text.addAttribute(.paragraphStyle, value: scaled(style, by: zoom), range: range)
        }
        // The attachments are shared with the document this copy was made
        // from, so each is replaced rather than resized in place — resizing
        // would grow the unzoomed original along with it.
        text.forEachAttachmentRun { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  attachment.bounds.width > 0, attachment.bounds.height > 0
            else { return }
            let copy = NSTextAttachment()
            copy.image = attachment.image
            copy.attachmentCell = attachment.attachmentCell
            copy.bounds = NSRect(
                x: attachment.bounds.origin.x * zoom, y: attachment.bounds.origin.y * zoom,
                width: attachment.bounds.width * zoom, height: attachment.bounds.height * zoom
            )
            text.addAttribute(.attachment, value: copy, range: range)
        }
        return text
    }

    private static func scaled(_ style: NSParagraphStyle, by zoom: CGFloat) -> NSParagraphStyle {
        // swiftlint:disable:next force_cast
        let scaled = style.mutableCopy() as! NSMutableParagraphStyle
        scaled.firstLineHeadIndent *= zoom
        scaled.headIndent *= zoom
        scaled.tailIndent *= zoom
        scaled.lineSpacing *= zoom
        scaled.paragraphSpacing *= zoom
        scaled.paragraphSpacingBefore *= zoom
        scaled.minimumLineHeight *= zoom
        scaled.maximumLineHeight *= zoom
        scaled.defaultTabInterval *= zoom
        scaled.tabStops = style.tabStops.map {
            NSTextTab(textAlignment: $0.alignment, location: $0.location * zoom,
                      options: $0.options)
        }
        return scaled
    }

    // MARK: - Zoom

    private var zoomStorage: CGFloat = 1

    /// A document zooms rather than changing a font: it is the only thing on
    /// screen in its tab, and the editor's font is a font nobody can see.
    var canZoom: Bool { document != nil }

    /// Quarter size to eight times it — the range a PDF and a picture zoom in,
    /// and the same range a page of type is still a page of type in.
    private static let zoomRange: ClosedRange<CGFloat> = 0.25 ... 8

    var zoom: CGFloat {
        get { zoomStorage }
        set {
            let clamped = min(max(newValue, Self.zoomRange.lowerBound),
                              Self.zoomRange.upperBound)
            guard clamped != zoomStorage else { return }
            zoomStorage = clamped
            install()
        }
    }

    var onZoomChange: ((CGFloat) -> Void)?

    // MARK: - Where the tab is left

    /// A document has one place to be — itself — so the number the session
    /// keeps beside a PDF's page is always zero here, and how far down the
    /// document the reader had got is the whole of it. Answered rather than
    /// left `nil` so the scroll below is asked for at all.
    var rememberedPosition: Int? { 0 }

    var rememberedScroll: Double? { Double(scrollFraction) }

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

    // MARK: - The footer

    /// Rich text is words on a page, so it is counted the way a note is:
    /// the middle of the footer says how many words and characters the
    /// document holds. There is no caret behind it and no page to be on, so
    /// the right stays empty, exactly as it does over a picture.
    var footerStatus: PreviewFooterStatus? {
        guard let document else { return nil }
        return PreviewFooterStatus(summary: TextStats.counts(document.string), position: nil)
    }

    // MARK: - The column's own asks

    var takesKeyboard: Bool {
        get { textView.takesKeyboard }
        set { textView.takesKeyboard = newValue }
    }

    /// Puts the keyboard in the document — reading mode's answer to
    /// `focusEditor`, so the arrow and page keys scroll it and ⌘F opens over
    /// it.
    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

    /// Matched to the editor's own padding, so the document's margin is the
    /// one the rest of the app uses.
    var horizontalInset: CGFloat = 20 {
        didSet {
            guard horizontalInset != oldValue else { return }
            textView.textContainerInset = NSSize(
                width: horizontalInset, height: Self.verticalInset
            )
        }
    }

    // MARK: - Tests

    /// What the pane is showing, and the message standing in for a document
    /// that could not be read — for the tests, which have no other way to ask
    /// a text view what is in it.
    var shownContent: NSAttributedString? { document }

    var shownText: String { textView.string }

    /// What is actually laid out in the text view — the document with the
    /// zoom applied to it, which is the thing a zoom test measures.
    var laidOutContentForTesting: NSAttributedString { textView.attributedString() }

    /// `prepared` on its own, so the legibility pass can be tested against a
    /// document built by hand rather than against a file.
    func preparedForTesting(_ document: NSAttributedString) -> NSAttributedString {
        Self.prepared(document)
    }

    /// Scrolls the document to a share of its height, the way a reader would
    /// — a test has no wheel to turn.
    func scrollForTesting(to fraction: Double) {
        layoutSubtreeIfNeeded()
        scroll(to: CGFloat(fraction))
    }

    var missingMessage: String? {
        missingLabel.isHidden ? nil : missingLabel.stringValue
    }

    /// The document's find session, for the tests.
    var findSessionForTesting: TextFindSession { findSession }

    // MARK: - Background

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The scroll view keeps the colour it was handed rather than resolving
        // it again, so light and dark are swapped by handing it over afresh.
        scrollView.backgroundColor = .textBackgroundColor
        textView.backgroundColor = .textBackgroundColor
        needsDisplay = true
    }
}

// MARK: - The text view

/// The view a rich-text document is read in.
///
/// It is an ordinary read-only text view — click to put a caret in it, drag to
/// select, ⌘C to copy — with the two things every view in the render column
/// has to answer for written down: ⌘F goes to Nota's own pill rather than
/// AppKit's bar, and a file let go on it opens as a tab rather than landing in
/// the text. There is no text here to land in: this is a view of a file, and
/// Nota does not edit rich text.
private final class RichTextView: NSTextView {
    var takesKeyboard = false
    /// The document's find bar. ⌘F, ⌘G, ⇧⌘G and ⌘E are nil-targeted
    /// `performTextFinderAction:` items, so they land here whenever this view
    /// has the keyboard — which is reading mode, and an RTF tab is only ever
    /// in reading mode.
    weak var findSession: TextFindSession?
    var onDropFiles: (([URL]) -> Void)?

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

    // MARK: - Dropped files

    /// A drag carrying files is the column's, whatever the text view would
    /// otherwise make of it; anything else is still the text view's own.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = PreviewFileDrop.operation(for: sender)
        return operation.isEmpty ? super.draggingEntered(sender) : operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = PreviewFileDrop.operation(for: sender)
        return operation.isEmpty ? super.draggingUpdated(sender) : operation
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.operation(for: sender).isEmpty
            ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles) || super.performDragOperation(sender)
    }
}
