import AppKit

/// The preview column: whatever the tab in front is read through, and the
/// arrangement around it.
///
/// It holds one content view at a time and keeps the others alive behind it
/// rather than throwing them away, so a trip through a PDF tab and back does
/// not cost the render that was already made — the render view still has it,
/// and its own cache says so. Which one is in front is settled by the
/// note, once, in `PreviewContentKind`.
///
/// Everything the window controller wants of the content it asks the column
/// for; the column passes it on to whichever view is in it, or to all of them
/// where the answer has to be true of the column rather than of one view. That
/// is the whole arrangement: the controller has one preview pane and knows
/// nothing of what is inside it.
final class PreviewPaneView: NSView {

    /// The column's content views and which of them is in front — for the
    /// tests, which are the one thing that still reaches past the column into
    /// what it is holding.
    struct Panes {
        let markdown: MarkdownPreviewView
        let latex: LaTeXPreviewView
        let html: HTMLPreviewView
        let pdf: PDFPreviewView
        let image: ImagePreviewView
        let kind: PreviewContentKind
        var showsPDF: Bool { kind == .pdf }
    }

    private let markdownContent = MarkdownPreviewView()
    private let latexContent = LaTeXPreviewView()
    private let htmlContent = HTMLPreviewView()
    private let pdfContent = PDFPreviewView()
    private let imageContent = ImagePreviewView()
    private var currentKind: PreviewContentKind = .markdown

    /// The content on screen.
    var current: any PreviewContent { content(of: currentKind) }

    /// Where the content sits inside the column: against its edges, less
    /// zen's drop clear of the traffic-light zone at the top. One pair of
    /// constraints, whatever the column happens to be holding.
    private let contentContainer = NSView()
    private let zenDragRegion = DragRegionView()
    private let zenTopInset: CGFloat
    private var contentTopToPane: NSLayoutConstraint?
    private var contentTopToZenInset: NSLayoutConstraint?

    // MARK: - What the column reports

    /// Run when the column changes width, when a block in it is clicked, when
    /// a checkbox in it is ticked, when its own ⌘F bar opens or closes, and
    /// when the reader moves to somewhere the content is keeping. Each comes
    /// from the view in front and from no other: a hidden view's news is not
    /// the column's.
    var onWidthChange: (() -> Void)?
    var onBlockClick: ((NSRange) -> Void)?
    var onTaskToggle: ((NSRange) -> Void)?
    var onFindBarVisibilityChange: ((Bool) -> Void)?
    var onPositionChange: ((Int) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?

    // MARK: - What is true of the column

    /// Laid on every content view rather than the one in front, so a view
    /// that has been waiting behind another is already right when it comes
    /// forward.
    var horizontalInset: CGFloat = 20 {
        didSet {
            guard horizontalInset != oldValue else { return }
            forEachContent { $0.horizontalInset = horizontalInset }
        }
    }

    var takesKeyboard = false {
        didSet {
            guard takesKeyboard != oldValue else { return }
            forEachContent { $0.takesKeyboard = takesKeyboard }
        }
    }

    var sendsBlockClicks = true {
        didSet {
            guard sendsBlockClicks != oldValue else { return }
            forEachContent { $0.sendsBlockClicks = sendsBlockClicks }
        }
    }

    /// Zen keeps the split, so in zen the column's top edge is the window's
    /// own: it takes the same drop clear of the traffic lights the editor
    /// beside it takes, and carries a drag strip there.
    var isZenMode = false {
        didSet {
            guard isZenMode != oldValue else { return }
            contentTopToPane?.isActive = !isZenMode
            contentTopToZenInset?.isActive = isZenMode
            zenDragRegion.isHidden = !isZenMode
        }
    }

    // MARK: - Building

    init(zenTopInset: CGFloat) {
        self.zenTopInset = zenTopInset
        super.init(frame: .zero)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        forEachContent { install($0) }

        zenDragRegion.translatesAutoresizingMaskIntoConstraints = false
        zenDragRegion.isHidden = true
        addSubview(zenDragRegion)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            zenDragRegion.topAnchor.constraint(equalTo: topAnchor),
            zenDragRegion.leadingAnchor.constraint(equalTo: leadingAnchor),
            zenDragRegion.trailingAnchor.constraint(equalTo: trailingAnchor),
            zenDragRegion.heightAnchor.constraint(equalToConstant: zenTopInset),
        ])

        // Under the tab strip normally; clear of the traffic-light zone in
        // zen, where there is no strip and the column runs to the frame.
        contentTopToPane = contentContainer.topAnchor.constraint(equalTo: topAnchor)
        contentTopToZenInset = contentContainer.topAnchor.constraint(
            equalTo: topAnchor, constant: zenTopInset
        )
        contentTopToPane?.isActive = true

        forEachContent { $0.isHidden = $0 !== markdownContent }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Every content view is pinned the same way — the column's whole room,
    /// less zen's inset — so which one is in front is a matter of who is
    /// hidden and of nothing else.
    private func install(_ content: any PreviewContent) {
        content.translatesAutoresizingMaskIntoConstraints = false
        content.horizontalInset = horizontalInset
        content.takesKeyboard = takesKeyboard
        content.sendsBlockClicks = sendsBlockClicks
        // A view behind the one in front has nothing to report: it is not on
        // screen, so nothing that happens to it happened to the column.
        content.onWidthChange = { [weak self, weak content] in
            guard let self, isInFront(content) else { return }
            onWidthChange?()
        }
        content.onBlockClick = { [weak self, weak content] source in
            guard let self, isInFront(content) else { return }
            onBlockClick?(source)
        }
        content.onTaskToggle = { [weak self, weak content] source in
            guard let self, isInFront(content) else { return }
            onTaskToggle?(source)
        }
        content.onFindBarVisibilityChange = { [weak self, weak content] isVisible in
            guard let self, isInFront(content) else { return }
            onFindBarVisibilityChange?(isVisible)
        }
        content.onPositionChange = { [weak self, weak content] position in
            guard let self, isInFront(content) else { return }
            onPositionChange?(position)
        }
        content.onZoomChange = { [weak self, weak content] zoom in
            guard let self, isInFront(content) else { return }
            onZoomChange?(zoom)
        }
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func isInFront(_ content: (any PreviewContent)?) -> Bool {
        guard let content else { return false }
        return content === current
    }

    /// Every content view there is. A new kind of content is a case in
    /// `PreviewContentKind` and a line here, and the column asks for nothing
    /// else.
    private func content(of kind: PreviewContentKind) -> any PreviewContent {
        switch kind {
        case .markdown: markdownContent
        case .latex: latexContent
        case .html: htmlContent
        case .pdf: pdfContent
        case .image: imageContent
        }
    }

    private func forEachContent(_ body: (any PreviewContent) -> Void) {
        for kind in PreviewContentKind.all { body(content(of: kind)) }
    }

    // MARK: - Which content is in front

    /// The view this note is read through, whether or not it is the one in
    /// front. Asking does not bring it forward: where a tab was left, and how
    /// long it is, are the tab's business whether or not you are looking at
    /// it.
    func content(for note: Note) -> any PreviewContent {
        content(of: PreviewContentKind(note))
    }

    /// Brings the view this note is read through to the front, and hands it
    /// back. Exactly one is ever on screen; the rest wait behind it with
    /// whatever they were last showing.
    @discardableResult
    func bringForward(_ note: Note) -> any PreviewContent {
        let kind = PreviewContentKind(note)
        currentKind = kind
        forEachContent { $0.isHidden = $0 !== content(of: kind) }
        return current
    }

    // MARK: - What the column is asked to do

    /// Puts the front tab's content on screen, making the view it is read
    /// through the one in front on the way.
    func show(_ note: Note, in context: PreviewContext) {
        bringForward(note).show(note, in: context)
    }

    /// The band goes out everywhere, not only in front: a view that comes
    /// forward later must not arrive with a block still lit from last time.
    func clearHighlight() {
        forEachContent { $0.clearHighlight() }
    }

    /// Held at the width it is being read at, so a column sliding across does
    /// not re-wrap the page on every frame. Only the view on screen is
    /// sliding, so only that one is held.
    @discardableResult
    func freezeWidth() -> Bool {
        current.freezeWidth()
    }

    /// Thawed everywhere. A view left frozen behind another would still be
    /// frozen when it came forward, and would never wrap to the column again.
    func thawWidth() {
        forEachContent { $0.thawWidth() }
    }

    /// Every remembered render goes, wherever it is being held: what made it
    /// stale — a picture redrawn under an unchanged token, a settings change
    /// — is no more true of the view in front than of the ones behind it.
    func invalidateRenders() {
        forEachContent { $0.invalidateRender() }
    }

    // MARK: - Tests

    var panes: Panes {
        Panes(markdown: markdownContent, latex: latexContent, html: htmlContent,
              pdf: pdfContent, image: imageContent, kind: currentKind)
    }
}
