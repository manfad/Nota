import AppKit
import PDFKit

/// A document Nota writes out as one HTML page and reads as that page
/// printed: a Word document onto its section's paper, a deck a slide to a
/// sheet. The pane knows nothing else about it.
protocol PrintedDocument: AnyObject {
    /// The page, beside whatever it refers to.
    var pageURL: URL { get }
    /// Where its printout goes — a file the document clears away with itself.
    var pagesURL: URL { get }
    /// The sheet the page is printed onto.
    var paper: WebPDF.Paper { get }
    /// Every word in it, for the footer's count.
    var plainText: String { get }
}

/// The preview column holding a printed document (SPEC "## Office documents
/// and video"): a Word document or a deck, its page printed onto its own
/// paper and read a page at a time, the way a PDF is.
///
/// Neither has an editor behind it, so this is the whole column, in reading
/// mode. The pages are WebKit's print of the page — the one path in WebKit
/// that paginates, so a document breaks where it runs out of sheet as well as
/// where its author put a break — and once they exist they are a PDF, so the
/// pane holding them is the PDF pane: the same grey desk, the same page
/// column, zoom and ⌘F. What this adds is the tab's bookkeeping — which
/// document, which page — and the wait while the pages are made.
final class PrintedPagesView: NSView, PreviewContent {

    private let pages = PDFPreviewView()
    private var document: (any PrintedDocument)?
    private var shownNoteID: UUID?
    private var shownTitle = ""

    /// Each document's pages, once printed. Per document rather than per
    /// pane: one pane serves every Word tab in the window, and a trip through
    /// another tab and back must not print a document again. Weak keys, so
    /// the pages go when the tab that held the document closes.
    private let printed = NSMapTable<AnyObject, PDFDocument>.weakToStrongObjects()
    /// Documents whose print is under way, so a second `show` waits for the
    /// first rather than starting another.
    private let printing = NSHashTable<AnyObject>.weakObjects()
    /// Documents that would not print, so they are not tried on every show.
    private let failed = NSHashTable<AnyObject>.weakObjects()

    var onFindBarVisibilityChange: ((Bool) -> Void)? {
        get { pages.onFindBarVisibilityChange }
        set { pages.onFindBarVisibilityChange = newValue }
    }

    var onPositionChange: ((Int) -> Void)? {
        get { pages.onPositionChange }
        set { pages.onPositionChange = newValue }
    }

    var onZoomChange: ((CGFloat) -> Void)? {
        get { pages.onZoomChange }
        set { pages.onZoomChange = newValue }
    }

    var onPagesChange: (() -> Void)?

    var onDropFiles: (([URL]) -> Void)? {
        didSet { pages.onDropFiles = onDropFiles }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(PreviewFileDrop.types)

        pages.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pages)
        NSLayoutConstraint.activate([
            pages.topAnchor.constraint(equalTo: topAnchor),
            pages.leadingAnchor.constraint(equalTo: leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: trailingAnchor),
            pages.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    func show(_ note: Note, in context: PreviewContext) {
        shownNoteID = note.id
        shownTitle = note.title
        document = note.printedDocument
        install(atPage: note.selectionLocation)
    }

    /// Puts the document's pages in the pane when they exist, and sets them
    /// printing when they do not: an empty desk until they land, then the
    /// page the tab was left on.
    private func install(atPage page: Int) {
        guard let document, !failed.contains(document) else {
            pages.show(nil, readFrom: nil, atPage: page, missingName: shownTitle)
            return
        }
        if let pdf = printed.object(forKey: document) {
            pages.show(pdf, readFrom: document.pagesURL, atPage: page, missingName: nil)
            return
        }
        pages.show(nil, readFrom: nil, atPage: page, missingName: nil)
        printPages(of: document)
    }

    private func printPages(of document: any PrintedDocument) {
        guard !printing.contains(document) else { return }
        printing.add(document)
        let url = document.pagesURL
        WebPDF.export(pageAt: document.pageURL, to: url, paper: document.paper) { [weak self, weak document] result in
            guard let self, let document else { return }
            printing.remove(document)
            if case .success = result, let pdf = PDFDocument(url: url), pdf.pageCount > 0 {
                printed.setObject(pdf, forKey: document)
            } else {
                failed.add(document)
            }
            // Only the document still in the pane is put in it; another tab's
            // pages wait in the cache for that tab to come back.
            guard document === self.document else { return }
            install(atPage: pages.currentPageIndex)
            onPagesChange?()
        }
    }

    func invalidateRender() {
        document = nil
    }

    /// A ⇧⌘F hit: the first place the query is printed, selected, with the
    /// pill up on it.
    func reveal(query: String) {
        pages.reveal(query: query)
    }

    // MARK: - Where the tab is left

    var rememberedPosition: Int? { pages.currentPageIndex }

    var pageList: PageListSource? { pages.pageList }

    /// A document of words is counted as a note is; once its pages are made
    /// the footer says which of them is in front, too.
    var footerStatus: PreviewFooterStatus? {
        guard let document else { return nil }
        let count = pages.pageCount
        return PreviewFooterStatus(
            summary: TextStats.counts(document.plainText),
            position: count > 0
                ? TextStats.pagePosition(current: pages.currentPageIndex + 1, total: count)
                : nil
        )
    }

    // MARK: - The pages' own chrome

    @discardableResult
    func focus(in window: NSWindow?) -> Bool { pages.focus(in: window) }

    var isFindBarVisible: Bool { pages.isFindBarVisible }

    var findBarHeight: CGFloat { pages.findBarHeight }

    var canZoom: Bool { pages.canZoom }

    var zoom: CGFloat {
        get { pages.zoom }
        set { pages.zoom = newValue }
    }

    var zoomPercent: Int? { pages.zoomPercent }

    // MARK: - Files let go on the desk

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    // MARK: - Tests

    var documentPages: PDFPreviewView { pages }

    var missingMessage: String? { pages.missingMessage }
}

extension DOCXDocument: PrintedDocument {
    /// The section's sheet as a print takes it.
    var paper: WebPDF.Paper { WebPDF.Paper(size: pageSize, margins: pageMargins) }
}

extension PPTXDocument: PrintedDocument {
    /// A slide to a sheet, edge to edge: the deck's own margins are the slide.
    var paper: WebPDF.Paper { WebPDF.Paper(size: slideSize, margins: NSEdgeInsets()) }
}
