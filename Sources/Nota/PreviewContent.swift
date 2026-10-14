import AppKit

/// Which of the preview column's content views a note is read through. The
/// tab's own kind settles it and nothing else does: a render for text — the
/// Markdown one or the LaTeX one, by what the file is spelled — WebKit's page
/// for HTML and for the drawing an SVG is, a grid for a dump and for a
/// delimited file, a collapsible tree for the four structured grammars, and the
/// document, the picture, the chapter or the rich text for the four kinds
/// Nota views rather than edits. This is the only place in the app that has
/// to be told.
enum PreviewContentKind: Hashable {
    case markdown, latex, html, pdf, image, epub, sql, csv, rtf, tree, docx, video

    /// Every kind there is, in the order the column keeps them.
    static let all: [PreviewContentKind] = [
        .markdown, .latex, .html, .pdf, .image, .epub, .sql, .csv, .rtf, .tree, .docx, .video,
    ]

    init(_ note: Note) {
        switch note.kind {
        case .pdf: self = .pdf
        case .image: self = .image
        case .epub: self = .epub
        case .rtf: self = .rtf
        case .word: self = .docx
        // A workbook's sheet is a table, read in the grid a `.csv` is.
        case .spreadsheet: self = .csv
        case .video: self = .video
        case .text:
            switch note.previewKind {
            case .latex: self = .latex
            // An SVG is a page WebKit draws, the same as an HTML file, and
            // the same pane draws both.
            case .html, .svg: self = .html
            // A dump is neither text to lay out nor a page to draw: it is a
            // database, and a database is read as a grid.
            case .sql: self = .sql
            // And a delimited file is a table without a database under it.
            case .csv: self = .csv
            // Four grammars, one tree. Which of them the file is written in
            // is the parser's business, never the column's.
            case .tree: self = .tree
            case .markdown, nil: self = .markdown
            }
        }
    }
}

/// What the footer says about content the editor's own counts cannot speak
/// for. A PDF is measured in pages rather than words and a picture in pixels,
/// and neither has a caret to report a line and column for. A Markdown render
/// is a view of the note's own text, so it says nothing here and the words and
/// characters stand.
///
/// Both halves are already written out, because only the content knows how it
/// is counted: `"12 pages"` and `"1200 × 800"` are not the same measurement
/// with a different unit.
struct PreviewFooterStatus {
    /// What the middle of the footer says in place of the word counts.
    let summary: String
    /// What the right says in place of the caret's line and column, when the
    /// content has somewhere to be at all. A picture is one page: there is
    /// nowhere in it to be.
    let position: String?
}

/// One line of a document's own table of contents: a chapter of a book, an
/// entry of a PDF's outline.
///
/// Flattened, with the nesting kept as a level rather than as a tree, because
/// that is the shape the sidebar lists — an indent per level. Where the line
/// goes is not written down here: `line` is the entry's own place in the
/// list, and the content view it came from is the only thing that knows what
/// that means. A book turns to a chapter and an anchor; a PDF goes to a
/// destination on a page. The sidebar hands the number back and asks no
/// questions about it.
struct ContentsEntry: Equatable {
    /// 1 for a top-level entry, 2 for one nested inside it, and so on.
    let level: Int
    let title: String
    /// This entry's own index in the list it came in.
    let line: Int
}

/// A document that is read page by page, for the sidebar column to list.
///
/// The other half of `ContentsEntry`: an outline says where the parts of a
/// document begin, and this says what its pages are. A document has pages
/// whether or not its author wrote an outline, which is why every PDF has
/// something in the column and an outline-less one is no longer a blank.
///
/// Class-bound, and held weakly by the column: the source is the content view
/// itself, which the preview pane owns and keeps alive behind whatever is in
/// front of it.
///
/// A thumbnail is asked for rather than read: drawing a page costs real work,
/// so it is done off the main thread and handed back on it, and a page nobody
/// has scrolled to is never drawn at all.
protocol PageListSource: AnyObject {
    var pageCount: Int { get }
    /// What the pages belong to. One content view shows every document of its
    /// kind in turn, so the column cannot tell one from another by the source
    /// alone — two documents of the same length would look like the same list
    /// and keep each other's thumbnails.
    var pageListIdentity: AnyHashable { get }
    /// Which page is in front, counted from zero.
    var currentPageIndex: Int { get }
    /// Goes to a page, and reports the move the way the reader's own scroll
    /// would — the tab is left there.
    func goToPage(_ index: Int)
    /// The page drawn small, handed back on the main thread. `nil` for a page
    /// that could not be drawn.
    func thumbnail(forPage index: Int, completion: @escaping (NSImage?) -> Void)
}

/// What the window hands a content view along with the note: the editor's own
/// font, so a render matches the text beside it, the store its pictures come
/// from, and whether the column is on screen at all — a render nobody can see
/// is not worth making.
struct PreviewContext {
    let font: NSFont
    let assets: AssetStore?
    let isVisible: Bool
}

/// One thing the preview column can hold: the Markdown render, the LaTeX
/// render, an HTML page, a PDF, a picture, a chapter of a book, a database
/// and a rich-text document.
///
/// The window controller has one editor pane and one preview pane. It asks
/// the pane for the content the tab in front needs and says everything else
/// through this, so a new kind of content is a new adopter here and nothing
/// anywhere else.
///
/// Almost all of it is optional. A render answers for blocks, a find bar and
/// a wrap width; a document answers for its pages; neither has any use for
/// the other's half. The extension below gives every member a default that
/// does nothing, so a content view writes down only what it actually has.
protocol PreviewContent: NSView {

    /// Puts the front tab's own content on screen. What that means is the
    /// content's business: the render decides whether the note has moved
    /// enough to be rendered again, the document puts the file in and goes
    /// back to the page the tab was left on.
    func show(_ note: Note, in context: PreviewContext)

    /// Whether the content takes the keyboard. Only in reading mode, where it
    /// is the only thing on screen: in split the caret stays in the editor.
    var takesKeyboard: Bool { get set }

    /// Puts the keyboard in the content — reading mode's answer to
    /// `focusEditor`.
    @discardableResult
    func focus(in window: NSWindow?) -> Bool

    /// Whether the content's own ⌘F bar is up. It takes the top of the
    /// column, which is where the mode control floats.
    var isFindBarVisible: Bool { get }

    /// Run when that bar opens or closes, and when it changes height — the
    /// replace row coming out makes it taller, and the control under it has
    /// to move by the same amount.
    var onFindBarVisibilityChange: ((Bool) -> Void)? { get set }

    /// How tall that bar is standing, for the control below it to clear.
    var findBarHeight: CGFloat { get }

    /// Holds the content still at the width it is being read at, for as long
    /// as the column beside it is moving, and says whether there was anything
    /// to hold.
    func freezeWidth() -> Bool

    /// Lets it take the column's width again.
    func thawWidth()

    /// Run when the column changes width. Anything drawn to fit the pane is
    /// a reason to draw it again.
    var onWidthChange: (() -> Void)? { get set }

    /// The column's left and right margin, matched to the editor's own so the
    /// two bodies of text line up.
    var horizontalInset: CGFloat { get set }

    /// Whether a click on the content jumps to it in the editor. In split the
    /// render is a map into the text beside it, so it does; in reading it is
    /// the page being read, so it does not.
    var sendsBlockClicks: Bool { get set }

    /// Run when a block is clicked, with the source it came from.
    var onBlockClick: ((NSRange) -> Void)? { get set }

    /// Run when a task item's checkbox is clicked, with the source of the
    /// item it belongs to. Unlike a block click this fires in reading mode
    /// too: a checkbox is a control, not a jump.
    var onTaskToggle: ((NSRange) -> Void)? { get set }

    /// Run when what the content has open has changed — the tree's branches,
    /// which is the only thing a reader opens and closes. The corner slot's
    /// own segment offers Expand All or Collapse All by the answer, so it has
    /// to hear a triangle clicked by hand. Every other content view has
    /// nothing that opens and never fires it.
    var onExpansionChange: (() -> Void)? { get set }

    /// Run when the content points at a piece of the source *without* asking
    /// for the keyboard: the editor selects it and brings it into view, and
    /// the content keeps the focus it has. A range with no length is a caret,
    /// which is all a pane with nothing wider to point at can give.
    ///
    /// One range per thing selected; a column of a grid is one range per row.
    /// A whole row, a value, an element's tag: each of those is one span, so
    /// the array holds one entry. A rectangle picked out of a grid over more
    /// than one column is the one case with more than one thing selected —
    /// each row's own fields, spanned on that row alone — because a column is
    /// the column and not the block of lines it happens to sit beside.
    ///
    /// A block click is a jump — the reader is done with the render and wants
    /// to type — so it takes the caret with it. A dump's row click is not: the
    /// grid is being walked cell by cell with the arrows, and a click that
    /// moved the keyboard into the editor would end the walk. Same map, other
    /// half of the gesture, so it is its own callback rather than a flag on
    /// the first one.
    var onSourceReveal: (([NSRange]) -> Void)? { get set }

    /// Lights the block the editor's caret is sitting in and brings it into
    /// view. Returns whether there was one to light.
    @discardableResult
    func highlightBlock(containingSource location: Int) -> Bool

    /// Puts the lit block out without touching the blocks themselves — what
    /// reading mode does on the way in.
    func clearHighlight()

    /// An edit has moved everything: the blocks mean nothing until the
    /// content is made again, so the lit one goes out rather than lying.
    func invalidateBlocks()

    /// Throws the remembered render away, so the next ask makes a fresh one —
    /// for everything a cache key cannot see, such as a picture in the store
    /// redrawn under an unchanged token.
    func invalidateRender()

    /// Whether ⌘+ / ⌘- / ⌘0 zoom this content rather than change the editor's
    /// font size. True where the content is the only thing on screen and its
    /// size is nothing to do with a font: a document, a picture, a page. A
    /// render says no — the font *is* the zoom there.
    var canZoom: Bool { get }

    /// How much bigger than its own default the content is drawn, 1 being
    /// that default: a document fitted to the column, a picture fitted to it,
    /// a page at 100%. Relative rather than absolute so it survives the
    /// column changing width under it, which moves every one of those
    /// defaults.
    ///
    /// Setting it clamps to what the content will actually draw; read it back
    /// for what it settled on.
    var zoom: CGFloat { get set }

    /// Run when the content zooms itself — a pinch on a document — with the
    /// same number `zoom` answers with, so the tab can keep it.
    var onZoomChange: ((CGFloat) -> Void)? { get set }

    /// The zoom as the pill in the column's corner says it: a whole number of
    /// percent of the content's own actual size, so a page fitted to the
    /// column reads 100% whatever scale that actually is. `nil` where there
    /// is nothing to say — a render, a grid, a document that cannot be
    /// zoomed yet — and a `nil` takes the pill away rather than showing a
    /// number nobody can change.
    var zoomPercent: Int? { get }

    /// Where the tab was left, when the content is the only thing that knows:
    /// the page a PDF is open at. `nil` when it is not — a render is read
    /// against the editor's caret, and the window already has that.
    var rememberedPosition: Int? { get }

    /// Run when the reader moves somewhere the content is keeping, with the
    /// same number `rememberedPosition` answers with.
    var onPositionChange: ((Int) -> Void)? { get set }

    /// Run when the content has written something of its own onto the note —
    /// the table a dump is open at, the query being read beside it. It says
    /// nothing about what changed, because the window has nothing to do with
    /// it: the note already holds the answer, and all that is left is to put
    /// the session on the same debounce a keystroke uses.
    var onStateChange: (() -> Void)? { get set }

    /// How far down that place the reader had got, 0 the top and 1 the
    /// bottom. Only content whose position is itself a thing with a length
    /// answers: a chapter of a book is a page of its own, and the chapter
    /// alone would put the reader back at the top of it. A PDF page and a
    /// caret are already exact, so both say nothing here.
    var rememberedScroll: Double? { get }

    /// What the footer says instead of the editor's counts, when the content
    /// has something of its own to say.
    var footerStatus: PreviewFooterStatus? { get }

    /// The content's own table of contents, flattened — a book's chapters, a
    /// PDF's outline. Empty for content that has none, which is every kind
    /// the reader can also edit: a note's outline is its headings, and those
    /// are read off its text rather than out of the file.
    var contentsEntries: [ContentsEntry] { get }

    /// Which of those lines names what is on screen right now, so the sidebar
    /// can ring it and follow along as the reader moves. `nil` when the
    /// contents say nothing about where they are.
    var currentContentsLine: Int? { get }

    /// Goes where a line of those contents points. A line naming somewhere
    /// the content cannot go is not gone to: the reader stays where they are
    /// rather than landing somewhere arbitrary.
    func goToContentsLine(_ line: Int)

    /// The content's own pages, when it is read a page at a time. `nil` for
    /// everything else: a note is one scroll of text and a chapter is one
    /// page of a book, and neither has pages to lay out in a column.
    var pageList: PageListSource? { get }

    /// Files let go on the content from the Finder. Every kind takes them and
    /// every kind does the same thing with them — hands them straight up, to
    /// be opened as tabs — so this is a requirement rather than something a
    /// view may leave out: the whole render column is a tab target, and a new
    /// kind of content that forgot would be a hole in it.
    var onDropFiles: (([URL]) -> Void)? { get set }
}

// MARK: - Files let go on the column

/// What every view in the render column does with a drag from the Finder.
///
/// The column is a tab target the way the strip is: a file let go anywhere
/// over it opens as a tab, whatever is being read underneath. Nothing is
/// filtered — `open(url:)` alone decides what each file becomes — and nothing
/// lands *in* the content: there is no text here to put a picture in.
///
/// It is written once here because the views that have to answer are of five
/// different superclasses — a text view, a web view, a PDF view and two plain
/// ones — and each has to say it in an override of its own. The web view and
/// the PDF view answer for these themselves otherwise, and both would take
/// the file: WebKit by navigating away from the page, PDFKit by swapping the
/// document. Neither may happen, so those two never see the drag at all.
enum PreviewFileDrop {
    /// The types a drop target in the column registers for.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL]

    /// `.copy` for a drag carrying files, and nothing for any other drag —
    /// which leaves the view free to answer for it as it always did.
    static func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.draggedFileURLs.isEmpty ? [] : .copy
    }

    /// Hands the files over, and says whether there were any to hand over.
    static func accept(_ sender: NSDraggingInfo, by handler: (([URL]) -> Void)?) -> Bool {
        let urls = sender.draggingPasteboard.draggedFileURLs
        guard !urls.isEmpty, let handler else { return false }
        handler(urls)
        return true
    }
}

// MARK: - What a content view may leave out

/// Everything a content view has no use for. A PDF has no blocks, no find bar
/// and no wrap width to hold; a render has no page to be on. Rather than each
/// writing down the other's half as an empty method, they leave it here.
extension PreviewContent {
    var takesKeyboard: Bool {
        get { false }
        set { }
    }

    var isFindBarVisible: Bool { false }

    var findBarHeight: CGFloat { 0 }

    var onFindBarVisibilityChange: ((Bool) -> Void)? {
        get { nil }
        set { }
    }

    func freezeWidth() -> Bool { false }

    func thawWidth() { }

    var onWidthChange: (() -> Void)? {
        get { nil }
        set { }
    }

    var horizontalInset: CGFloat {
        get { 0 }
        set { }
    }

    var sendsBlockClicks: Bool {
        get { false }
        set { }
    }

    var onBlockClick: ((NSRange) -> Void)? {
        get { nil }
        set { }
    }

    var onTaskToggle: ((NSRange) -> Void)? {
        get { nil }
        set { }
    }

    var onExpansionChange: (() -> Void)? {
        get { nil }
        set { }
    }

    var onSourceReveal: (([NSRange]) -> Void)? {
        get { nil }
        set { }
    }

    @discardableResult
    func highlightBlock(containingSource location: Int) -> Bool { false }

    func clearHighlight() { }

    func invalidateBlocks() { }

    func invalidateRender() { }

    var canZoom: Bool { false }

    var zoom: CGFloat {
        get { 1 }
        set { }
    }

    var onZoomChange: ((CGFloat) -> Void)? {
        get { nil }
        set { }
    }

    var zoomPercent: Int? { nil }

    var rememberedPosition: Int? { nil }

    var onPositionChange: ((Int) -> Void)? {
        get { nil }
        set { }
    }

    var onStateChange: (() -> Void)? {
        get { nil }
        set { }
    }

    var rememberedScroll: Double? { nil }

    var footerStatus: PreviewFooterStatus? { nil }

    var contentsEntries: [ContentsEntry] { [] }

    var currentContentsLine: Int? { nil }

    func goToContentsLine(_ line: Int) { }

    var pageList: PageListSource? { nil }
}
