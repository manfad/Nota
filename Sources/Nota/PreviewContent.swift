import AppKit

/// Which of the preview column's content views a note is read through. The
/// tab's own kind settles it and nothing else does: a render for text — the
/// Markdown one or the LaTeX one, by what the file is spelled — WebKit's page
/// for HTML and for the drawing an SVG is, and the document or the picture
/// for the two binaries. This is the only place in the app that has to be
/// told.
enum PreviewContentKind: Hashable {
    case markdown, latex, html, pdf, image

    /// Every kind there is, in the order the column keeps them.
    static let all: [PreviewContentKind] = [.markdown, .latex, .html, .pdf, .image]

    init(_ note: Note) {
        switch note.kind {
        case .pdf: self = .pdf
        case .image: self = .image
        case .text:
            switch note.previewKind {
            case .latex: self = .latex
            // An SVG is a page WebKit draws, the same as an HTML file, and
            // the same pane draws both.
            case .html, .svg: self = .html
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
/// render, an HTML page, a PDF, and in time a picture.
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

    /// Where the tab was left, when the content is the only thing that knows:
    /// the page a PDF is open at. `nil` when it is not — a render is read
    /// against the editor's caret, and the window already has that.
    var rememberedPosition: Int? { get }

    /// Run when the reader moves somewhere the content is keeping, with the
    /// same number `rememberedPosition` answers with.
    var onPositionChange: ((Int) -> Void)? { get set }

    /// What the footer says instead of the editor's counts, when the content
    /// has something of its own to say.
    var footerStatus: PreviewFooterStatus? { get }
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

    @discardableResult
    func highlightBlock(containingSource location: Int) -> Bool { false }

    func clearHighlight() { }

    func invalidateBlocks() { }

    func invalidateRender() { }

    var rememberedPosition: Int? { nil }

    var onPositionChange: ((Int) -> Void)? {
        get { nil }
        set { }
    }

    var footerStatus: PreviewFooterStatus? { nil }
}
