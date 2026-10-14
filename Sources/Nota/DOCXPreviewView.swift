import AppKit

/// The preview column holding a Word document (SPEC "## Office documents and
/// video"): the page `DOCXDocument` writes, drawn by the same web view a book
/// chapter is.
///
/// A `.docx` tab has no editor behind it, so this is the whole column, in
/// reading mode, like a book. What it adds over the page underneath is the
/// tab's own bookkeeping — which document, where the reader had got to — and
/// the quiet message for a file that would not open.
final class DOCXPreviewView: NSView, PreviewContent {

    private let page = HTMLPreviewView()
    private let missingLabel = NSTextField(labelWithString: "")
    private var document: DOCXDocument?
    private var shownNoteID: UUID?
    private var shownPath: String?
    private var pendingScroll: Double = 0

    var onFindBarVisibilityChange: ((Bool) -> Void)?

    var onDropFiles: (([URL]) -> Void)? {
        didSet { page.onDropFiles = onDropFiles }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)

        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)

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
            missingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])

        page.onFindBarVisibilityChange = { [weak self] visible in
            self?.onFindBarVisibilityChange?(visible)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    func show(_ note: Note, in context: PreviewContext) {
        let path = note.fileURL?.path
        if note.id != shownNoteID || path != shownPath {
            pendingScroll = note.scrollFraction
        }
        shownNoteID = note.id
        shownPath = path
        document = note.wordDocument
        guard let document,
              page.showPage(ofTab: note.id, at: document.pageURL, fragment: nil,
                            scrollFraction: pendingScroll, in: context)
        else {
            page.isHidden = true
            missingLabel.font = Preferences.shared.font()
            missingLabel.stringValue = "Couldn’t open “\(note.title)”."
            missingLabel.isHidden = false
            return
        }
        if context.isVisible { pendingScroll = 0 }
        missingLabel.isHidden = true
        page.isHidden = false
    }

    func invalidateRender() {
        document = nil
        shownPath = nil
        page.invalidateRender()
    }

    /// A ⇧⌘F hit: the query put to the page with the pill up on it.
    func reveal(query: String) {
        page.find(query)
    }

    // MARK: - Where the tab is left

    var rememberedPosition: Int? { 0 }

    var rememberedScroll: Double? {
        shownNoteID.flatMap { page.rememberedScrollFraction(ofTab: $0) }
    }

    /// A Word document is words, so it is counted as a note is.
    var footerStatus: PreviewFooterStatus? {
        guard let document else { return nil }
        return PreviewFooterStatus(summary: TextStats.counts(document.plainText), position: nil)
    }

    // MARK: - The page's own chrome

    var takesKeyboard: Bool {
        get { page.takesKeyboard }
        set { page.takesKeyboard = newValue }
    }

    @discardableResult
    func focus(in window: NSWindow?) -> Bool { page.focus(in: window) }

    var isFindBarVisible: Bool { page.isFindBarVisible }

    var findBarHeight: CGFloat { page.findBarHeight }

    var canZoom: Bool { page.canZoom }

    var zoom: CGFloat {
        get { page.zoom }
        set { page.zoom = newValue }
    }

    var zoomPercent: Int? { page.zoomPercent }

    // MARK: - Files let go on the page

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    // MARK: - Background

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    // MARK: - Tests

    var documentPage: HTMLPreviewView { page }

    var missingMessage: String? { missingLabel.isHidden ? nil : missingLabel.stringValue }
}
