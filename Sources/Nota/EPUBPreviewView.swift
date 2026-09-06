import AppKit

/// The preview column holding a book: one chapter of an EPUB at a time, drawn
/// by the same web view a `.html` tab is read through (SPEC Todo 3).
///
/// A book tab has no editor behind it — there is nothing to edit — so this is
/// never a pane beside anything. It is the whole column, in reading mode, the
/// third viewer after a PDF and a picture and for the same reason: Nota opens
/// the file to be read, not to be written to.
///
/// A chapter is XHTML with the book's own stylesheets and pictures beside it,
/// which is exactly what the HTML pane already draws — so the pane is reused
/// rather than copied, and the book's own type, colours and layout are what
/// you read. What this view adds is the part a page cannot know: which
/// chapter of how many, how to get to the next one, and where in the book the
/// tab was left.
final class EPUBPreviewView: NSView, PreviewContent {

    /// The chapter on screen, drawn as the page it is.
    private let page = HTMLPreviewView()
    /// Shown instead of the book when the file has gone, or will not come
    /// apart into one — deleted while the tab was open, truncated, or missing
    /// by the time the session comes back.
    private let missingLabel = NSTextField(labelWithString: "")
    /// The book behind the tab in front, and which tab that is — the page
    /// keeps its scroll under the tab's id, and a book is one tab however
    /// many chapters it has.
    private var book: EPUBBook?
    private var shownNoteID: UUID?
    private var shownPath: String?
    /// The tab's name, for the message when there is no book to draw.
    private var missingName: String?

    /// Which chapter of the spine is on screen.
    private(set) var chapterIndex = 0

    /// Where the next load should land: an anchor the contents jumped to, or
    /// the share of the chapter the session remembers. Both are one-shot —
    /// once the chapter is on screen the reader owns where they are in it.
    private var pendingFragment: String?
    private var pendingScroll: Double = 0

    /// The last context the column handed over, so a chapter turned by hand
    /// is shown the same way a tab switch shows one.
    private var latestContext = PreviewContext(
        font: .systemFont(ofSize: NSFont.systemFontSize), assets: nil, isVisible: false
    )

    var onPositionChange: ((Int) -> Void)?
    var onFindBarVisibilityChange: ((Bool) -> Void)?

    /// Files let go on the chapter. The page below takes most of them, since
    /// it fills the column; this answers for the rest of it — the corners the
    /// find pill leaves clear, and the message where there is no book.
    var onDropFiles: (([URL]) -> Void)? {
        didSet { page.onDropFiles = onDropFiles }
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)

        // A book is read in Nota's light or dark, not on the paper it was
        // typeset for: said before the first chapter, since the page's web
        // view is built once, on that load.
        page.appliesReaderTheme = true
        // Edge to edge, the same as the page it holds: a chapter lays out to
        // the viewport it is given, and its own body margin is already the
        // margin its author asked for.
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)

        // The same quiet voice the rest of the app uses for something that is
        // not there: the editor's own font family, secondary colour, centred
        // in the column with nothing else in it.
        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.alignment = .center
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.isHidden = true
        addSubview(missingLabel)

        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),

            missingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            missingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 20
            ),
        ])

        // The page reports the keys a book is turned by rather than acting on
        // them: only this view knows what a chapter is.
        page.onChapterKey = { [weak self] step in self?.stepChapter(by: step) }
        page.onFindBarVisibilityChange = { [weak self] visible in
            self?.onFindBarVisibilityChange?(visible)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Puts the tab's book in the pane, at the chapter it was left on. A
    /// resize, a tab switch and a settings change all ask again with nothing
    /// moved, and the page underneath answers those by doing nothing at all.
    func show(_ note: Note, in context: PreviewContext) {
        latestContext = context
        let path = note.fileURL?.path
        // A different tab, or the same tab's file replaced under it: where
        // the reader is comes from the note again rather than from whatever
        // the last book left here.
        let isAnotherBook = note.id != shownNoteID || path != shownPath
        shownNoteID = note.id
        shownPath = path
        missingName = note.title
        book = note.epubBook
        if isAnotherBook {
            chapterIndex = clamped(note.selectionLocation)
            pendingScroll = note.scrollFraction
            pendingFragment = nil
        }
        showChapter()
    }

    /// The file behind the book has changed under the tab, so the folder it
    /// was unpacked into is of a book that no longer exists in that shape.
    /// Forgetting which path is showing is what makes the next `show` unpack
    /// it again.
    func invalidateRender() {
        book = nil
        shownPath = nil
        page.invalidateRender()
    }

    private func showChapter() {
        guard let book, book.chapters.indices.contains(chapterIndex) else {
            showMissing()
            return
        }
        let chapter = book.chapters[chapterIndex]
        let opened = page.showPage(
            ofTab: shownNoteID ?? chapterTabFallback, at: chapter.url,
            fragment: pendingFragment, scrollFraction: pendingScroll, in: latestContext
        )
        guard opened else {
            showMissing()
            return
        }
        // Only once the chapter is actually on screen: a column that is away
        // has loaded nothing, and the reader is still owed the place they
        // asked for.
        if latestContext.isVisible {
            pendingFragment = nil
            pendingScroll = 0
        }
        missingLabel.isHidden = true
        page.isHidden = false
    }

    private func showMissing() {
        page.isHidden = true
        missingLabel.isHidden = false
        missingLabel.font = Preferences.shared.font()
        missingLabel.stringValue = missingName.map { "Couldn’t open “\($0)”." } ?? ""
    }

    /// A tab id for a pane that is being shown a book without a note behind
    /// it, which only happens in a test that drives the view directly.
    private let chapterTabFallback = UUID()

    // MARK: - Moving through the book

    /// How many chapters there are, and none at all when there is no book.
    var chapterCount: Int { book?.chapters.count ?? 0 }

    /// What the chapter on screen is called, for the footer and the tests.
    var chapterTitle: String? {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex].title
    }

    /// Goes to a chapter of the spine, and to an anchor inside it when the
    /// contents named one. A chapter that is not there is not gone to: the
    /// reader stays where they are rather than landing somewhere arbitrary.
    func goToChapter(_ index: Int, fragment: String? = nil) {
        guard let book, book.chapters.indices.contains(index) else { return }
        let moved = index != chapterIndex
        chapterIndex = index
        pendingFragment = fragment
        // Somewhere new in the book is the top of it, unless an anchor says
        // otherwise; only a session brings a share of a chapter back.
        if moved || fragment != nil { pendingScroll = 0 }
        showChapter()
        guard moved else { return }
        onPositionChange?(chapterIndex)
    }

    /// The next chapter or the one before it — `→` / `←` and a page key at
    /// the end of a chapter, which the page reports rather than swallows. The
    /// ends of the book are the ends: there is nothing before the first
    /// chapter or after the last.
    func stepChapter(by step: Int) {
        goToChapter(chapterIndex + step)
    }

    // MARK: - The book's own contents

    /// What the sidebar lists for a book: its table of contents, flattened.
    var contentsEntries: [ContentsEntry] { book?.contentsEntries ?? [] }

    /// Which line names the chapter on screen — the chapter's own line rather
    /// than a section inside it.
    var currentContentsLine: Int? { book?.contentsLine(ofChapter: chapterIndex) }

    /// A line of the book's own contents, chosen in the sidebar. A line
    /// pointing at something the spine does not hold has nowhere to go, and
    /// nothing happens.
    func goToContentsLine(_ line: Int) {
        guard let book, let destination = book.destination(ofContentsLine: line) else {
            return
        }
        goToChapter(destination.chapter, fragment: destination.fragment)
    }

    private func clamped(_ index: Int) -> Int {
        guard let book, !book.chapters.isEmpty else { return max(0, index) }
        return min(max(0, index), book.chapters.count - 1)
    }

    // MARK: - Where the tab is left

    /// The chapter being read — what the session keeps, the same one number a
    /// PDF's page is. Answered even when the book would not open, so a tab
    /// whose file has gone is left on the chapter it remembers rather than
    /// having the editor's caret written over it.
    var rememberedPosition: Int? { chapterIndex }

    /// And how far down that chapter, since a chapter has a length of its own
    /// and coming back to the chapter alone would come back to the top of it.
    var rememberedScroll: Double? {
        shownNoteID.flatMap { page.rememberedScrollFraction(ofTab: $0) }
    }

    /// A book has no words or characters to count. How long it is, is how many
    /// chapters — and where you are in it is which of them is on screen.
    var footerStatus: PreviewFooterStatus? {
        PreviewFooterStatus(
            summary: TextStats.chapterCounts(chapterCount),
            position: chapterCount > 0
                ? TextStats.chapterPosition(current: chapterIndex + 1, total: chapterCount)
                : nil
        )
    }

    // MARK: - The page's own chrome

    var takesKeyboard: Bool {
        get { page.takesKeyboard }
        set { page.takesKeyboard = newValue }
    }

    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        page.focus(in: window)
    }

    var isFindBarVisible: Bool { page.isFindBarVisible }

    var findBarHeight: CGFloat { page.findBarHeight }

    /// A chapter zooms rather than changing a font, the same as any other
    /// page: in a book tab it is the only thing on screen.
    var canZoom: Bool { page.canZoom }

    var zoom: CGFloat {
        get { page.zoom }
        set { page.zoom = newValue }
    }

    var zoomPercent: Int? { page.zoomPercent }

    /// The pane the chapter is drawn in — for the tests, which have no other
    /// way to ask a web view what it holds.
    var chapterPage: HTMLPreviewView { page }

    var missingMessage: String? {
        missingLabel.isHidden ? nil : missingLabel.stringValue
    }

    // MARK: - Background

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}
