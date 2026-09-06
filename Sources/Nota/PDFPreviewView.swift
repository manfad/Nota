import AppKit
import PDFKit

/// The preview column's other half: a PDF, drawn by PDFKit, where a Markdown
/// tab would have its render.
///
/// A PDF tab has no editor behind it — there is nothing to edit — so this is
/// never a pane beside anything. It is the whole column, in reading mode, and
/// the keyboard is its own: arrow and page keys scroll the document the way
/// they scroll the render next door.
///
/// Nothing here is a view of a note. There are no blocks to click, no source
/// to jump back to and no band to light; the only thing it tells the window
/// about is which page is in front, which is the one thing worth keeping.
final class PDFPreviewView: NSView, PreviewContent {

    private let pdfView = NotaPDFView()
    /// Shown instead of the document when the file has gone — deleted while
    /// the tab was open, or missing by the time the session comes back.
    private let missingLabel = NSTextField(labelWithString: "")

    /// The document's own ⌘F bar, floating in the top-trailing corner of the
    /// column — the same pill the editor and the render use, over PDFKit's
    /// selections instead of a text storage.
    private let findBar = FindBarView(placeholder: "Find in document")
    private lazy var findSession = PDFFindSession(bar: findBar, pdfView: pdfView)

    /// Run when the reader moves to another page, with its 0-based index.
    var onPositionChange: ((Int) -> Void)?

    /// Run when that bar opens or closes. A PDF column carries no mode
    /// control for it to push out of the corner, but the column asks all the
    /// same and the window keeps its own book on which bar is up.
    var onFindBarVisibilityChange: ((Bool) -> Void)?

    var isFindBarVisible: Bool { findSession.isVisible }

    var findBarHeight: CGFloat { findBar.stackHeight }

    /// The page the pane was last told to be on. A document that would not
    /// open has no page to be asked for, and reporting the first one would
    /// send a tab whose file has gone back to the top of a PDF that is not
    /// there; it is left where the session remembers instead.
    private var installedPage = 0
    /// True while a document or a page is being put in by hand, so the
    /// notification that follows is not read back as the reader turning a
    /// page — restoring page 4 must not be the same thing as leaving page 4.
    private var isInstalling = false

    /// Files let go on the document. PDFKit would take a dropped PDF itself
    /// and swap the document under the reader, so the view never sees the
    /// drag — see `NotaPDFView`.
    var onDropFiles: (([URL]) -> Void)? {
        didSet { pdfView.onDropFiles = onDropFiles }
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

        // Pinned edge to edge, unlike the Markdown render's own margins.
        // PDFView scales and centres each page inside the room it is given,
        // so an inset would not be a margin around the text — it would be a
        // second margin outside the page's own, with the paper shrinking to
        // pay for it.
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        // Not `autoScales`: that fits the page to the column whatever the
        // column's width is, so a portrait page in a wide window is drawn
        // half again past actual size and the type is enormous. The fit is
        // done here instead, capped at 1.0 — see `fitPage`.
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .textBackgroundColor
        addSubview(pdfView)

        // The same quiet voice the rest of the app uses for something that is
        // not there: the editor's own font family, secondary colour, centred
        // in the column with nothing else in it.
        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.alignment = .center
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.isHidden = true
        addSubview(missingLabel)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),

            missingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            missingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 20
            ),
        ])

        // Added after the page, so the pill floats over it, and in the same
        // corner every other column keeps its bars in.
        pdfView.findSession = findSession
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(pageDidChange),
            name: .PDFViewPageChanged, object: pdfView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleDidChange),
            name: .PDFViewScaleChanged, object: pdfView
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Puts the tab's document in the pane and goes back to the page it was
    /// left on. Nothing here asks whether the column is on screen: a document
    /// costs nothing to hold, and the page has to be right before it is.
    func show(_ note: Note, in context: PreviewContext) {
        let document = note.pdfDocument
        // Read before the document goes in: installing one lands on its first
        // page, and the page we are about to restore must not be that.
        let page = note.selectionLocation
        show(document, missingName: document == nil ? note.title : nil)
        // Only when it is not already there: this is asked again on a resize
        // and a settings change, and going to the page you are on would jump
        // a half-read page back to its top.
        if currentPageIndex != page { currentPageIndex = page }
    }

    /// Puts a document in the pane, or says why there is none. `missingName`
    /// is the file's name, and naming it is the whole message: a PDF that is
    /// not there is not an error to be dismissed, only a page that cannot be
    /// drawn.
    private func show(_ document: PDFDocument?, missingName: String?) {
        isInstalling = true
        defer { isInstalling = false }

        // Only on a real change: handing PDFView the document it is already
        // showing throws away the page the reader is on.
        if pdfView.document !== document {
            // Every selection the bar is holding points into the document
            // being taken out, so the search goes with it.
            findSession.close()
            pdfView.document = document
            // And a fresh outline, walked once here rather than on every
            // question the sidebar asks.
            outline = PDFOutlineContents(of: document)
            // A fresh document is a fresh page size: the fit the last one
            // was drawn at says nothing about this one.
            fittedSize = .zero
            fitPage()
        }
        pdfView.isHidden = document == nil
        missingLabel.isHidden = document != nil
        guard document == nil else { return }
        missingLabel.font = Preferences.shared.font()
        missingLabel.stringValue = missingName.map { "Couldn’t open “\($0)”." } ?? ""
    }

    /// How many pages there are, and none at all when there is no document.
    var pageCount: Int { pdfView.document?.pageCount ?? 0 }

    // MARK: - The document's own outline

    /// The outline of the document in the pane, read once when the document
    /// goes in. Walking `outlineRoot` costs a traversal of the whole tree and
    /// nothing about it changes while the tab is open, so it is not walked
    /// again on every scroll.
    private var outline = PDFOutlineContents()

    /// What the sidebar lists for a PDF: its outline, flattened. A document
    /// with none lists nothing, which is what keeps the column away.
    var contentsEntries: [ContentsEntry] { outline.entries }

    /// Which line names the page in front — the last entry landing on or
    /// before it, since an outline names where a section starts and the
    /// reader is inside the one they have most recently passed.
    var currentContentsLine: Int? { outline.line(forPage: currentPageIndex) }

    /// A line of the outline, chosen in the sidebar: the document goes to the
    /// destination the entry names, which is a point on a page rather than
    /// the top of it. An entry with no destination has nowhere to go.
    func goToContentsLine(_ line: Int) {
        guard let destination = outline.destination(ofLine: line) else { return }
        pdfView.go(to: destination)
        // `go(to:)` moves the page without a `PDFViewPageChanged` of its own
        // in every case, so where the tab is left is reported by hand.
        onPositionChange?(currentPageIndex)
    }

    // MARK: - How big the page is drawn

    /// The column's size the page was last fitted to. A fit is worth doing
    /// again when the column changes size and at no other time — in
    /// particular not on every layout pass.
    private var fittedSize = NSSize.zero

    /// True while the scale is being set from here, so PDFKit's own
    /// notification about it is not read back as the reader pinching.
    private var isScaling = false

    private var zoomStorage: CGFloat = 1

    /// A document zooms rather than changing a font: it is the only thing on
    /// screen in its tab, and its size has nothing to do with the editor's.
    var canZoom: Bool { pdfView.document != nil }

    /// Quarter size to eight times it, which is the range a page is still
    /// something to look at in.
    private static let zoomRange: ClosedRange<CGFloat> = 0.25 ... 8

    /// How much bigger than the fitted page it is drawn. 1 is the fit itself,
    /// which is what "Actual Size" goes back to.
    var zoom: CGFloat {
        get { zoomStorage }
        set {
            let clamped = min(max(newValue, Self.zoomRange.lowerBound),
                              Self.zoomRange.upperBound)
            guard clamped != zoomStorage else { return }
            zoomStorage = clamped
            fitPage(force: true)
        }
    }

    var onZoomChange: ((CGFloat) -> Void)?

    /// The zoom as the pill in the corner says it: a whole number of percent
    /// of the fit, so a page fitted to the column reads 100%.
    var zoomPercent: Int? { canZoom ? Int((zoom * 100).rounded()) : nil }

    /// Fits the page to the column's width, never larger than actual size,
    /// and then applies whatever zoom the reader has asked for on top.
    ///
    /// `autoScales` would fill the column with one page whatever that costs:
    /// a 300pt-wide page in a 900pt column is drawn at 3×, which is a page of
    /// 36pt type. Paper has a size of its own, and past 100% a PDF is being
    /// magnified rather than read. Below it there is no choice — a page wider
    /// than the column has to shrink or be cut off — so the cap is one-sided.
    private func fitPage(force: Bool = false) {
        guard pdfView.document != nil else { return }
        let size = pdfView.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        guard force || size != fittedSize else { return }
        fittedSize = size
        guard let scale = scaleForZoom else { return }
        // PDFView clamps what it is handed, and neither of its own bounds
        // knows about the fit this one is measured from.
        if scale < pdfView.minScaleFactor { pdfView.minScaleFactor = scale }
        if scale > pdfView.maxScaleFactor { pdfView.maxScaleFactor = scale }
        isScaling = true
        pdfView.scaleFactor = scale
        isScaling = false
    }

    /// What the page should be drawn at: the fit, capped at actual size, times
    /// the zoom.
    private var scaleForZoom: CGFloat? {
        let fit = fittedScale
        return fit > 0 ? fit * zoomStorage : nil
    }

    /// The scale a zoom of 1 means — the page fitted to the column, and never
    /// past actual size.
    private var fittedScale: CGFloat { min(pdfView.scaleFactorForSizeToFit, 1) }

    /// A pinch on the trackpad, which PDFKit handles itself. The zoom is read
    /// back off the scale it landed on rather than being fought over, so the
    /// next resize keeps it and the tab remembers it.
    @objc private func scaleDidChange(_ notification: Notification) {
        guard !isScaling, pdfView.document != nil else { return }
        let fit = fittedScale
        guard fit > 0 else { return }
        let zoom = pdfView.scaleFactor / fit
        guard abs(zoom - zoomStorage) > 0.0001 else { return }
        zoomStorage = zoom
        onZoomChange?(zoom)
    }

    /// The column changed size, so the page is fitted to it again — at the
    /// zoom the reader left it at, since that is measured against the fit
    /// rather than against the paper.
    override func layout() {
        super.layout()
        fitPage()
    }

    /// What the page is drawn at, and what `autoScales` would have drawn it
    /// at — for the tests, which have to be able to say the cap did something.
    var scaleFactor: CGFloat { pdfView.scaleFactor }
    var scaleFactorToFit: CGFloat { pdfView.scaleFactorForSizeToFit }

    /// The page in front, counted from zero — what the footer says and what
    /// the session keeps. Setting it goes to that page; a page number past
    /// the end of the document lands on the last one there is.
    var currentPageIndex: Int {
        get {
            guard let document = pdfView.document, let page = pdfView.currentPage
            else { return installedPage }
            let index = document.index(for: page)
            return index == NSNotFound ? 0 : index
        }
        set {
            installedPage = max(newValue, 0)
            guard let document = pdfView.document, document.pageCount > 0,
                  let page = document.page(at: min(max(newValue, 0), document.pageCount - 1))
            else { return }
            isInstalling = true
            defer { isInstalling = false }
            pdfView.go(to: page)
        }
    }

    @objc private func pageDidChange(_ notification: Notification) {
        guard !isInstalling else { return }
        onPositionChange?(currentPageIndex)
    }

    /// Where a PDF tab is left, for the session to bring it back to. It is
    /// the one thing this pane knows that the window does not: there is no
    /// caret behind a document for the editor to answer with.
    var rememberedPosition: Int? { currentPageIndex }

    /// A PDF has no words or characters to count. How long it is, is how many
    /// pages — and where you are in it is which of them is in front. A
    /// document that would not open has no page to be on.
    var footerStatus: PreviewFooterStatus? {
        PreviewFooterStatus(
            summary: TextStats.pageCounts(pageCount),
            position: pageCount > 0
                ? TextStats.pagePosition(current: currentPageIndex + 1, total: pageCount)
                : nil
        )
    }

    /// Puts the keyboard in the document — reading mode's answer to
    /// `focusEditor`, so the arrow and page keys scroll it.
    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(pdfView) ?? false
    }

    /// What the pane is showing, for the tests: the document itself and the
    /// message standing in for one that could not be opened.
    var shownDocument: PDFDocument? { pdfView.document }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // PDFView keeps the colour it was handed rather than resolving it
        // again, so light and dark are swapped by handing it over afresh.
        pdfView.backgroundColor = .textBackgroundColor
        needsDisplay = true
    }
}

// MARK: - The outline, flattened

/// A PDF's own outline — its bookmarks, the thing every other reader puts in a
/// drawer down the side — read into the shape the contents column lists.
///
/// PDFKit hands it over as a tree hanging off `PDFDocument.outlineRoot`, whose
/// own node is a holder rather than an entry: its children are the top level.
/// Walking it depth first is what makes the flattened list read in the order
/// the document does, and the depth of the walk is the level the sidebar
/// indents by — the same shape a book's chapters arrive in, so one column
/// lists both without knowing which it has.
///
/// Everything is read once, when the document goes into the pane. A
/// `PDFDestination` holds a page, and asking a page for its index means asking
/// the document; doing that per scroll for every entry of a long outline is a
/// traversal a scroll cannot afford.
struct PDFOutlineContents {
    /// The lines, in the order the document reads.
    private(set) var entries: [ContentsEntry] = []
    /// Where each of them goes, in the same order.
    private var destinations: [PDFDestination?] = []
    /// And which page that is, so the line naming the page in front is found
    /// by comparing numbers rather than by asking PDFKit again.
    private var pages: [Int?] = []

    /// An empty outline, which is what a pane with no document in it has.
    init() { }

    init(of document: PDFDocument?) {
        guard let document, let root = document.outlineRoot else { return }
        walk(root, level: 0, in: document)
    }

    /// Depth first, the root itself skipped: `outlineRoot` is a holder with no
    /// label of its own, so level 1 is its children.
    private mutating func walk(_ node: PDFOutline, level: Int, in document: PDFDocument) {
        for index in 0 ..< node.numberOfChildren {
            guard let child = node.child(at: index) else { continue }
            // An entry with no label is one the document did not name; there
            // is nothing to list, but its children may still be worth
            // listing, so the walk goes on through it at the same level.
            let label = child.label ?? ""
            if !label.isEmpty {
                entries.append(
                    ContentsEntry(level: level + 1, title: label, line: entries.count)
                )
                destinations.append(child.destination)
                pages.append(child.destination?.page.map { document.index(for: $0) })
            }
            walk(child, level: label.isEmpty ? level : level + 1, in: document)
        }
    }

    func destination(ofLine line: Int) -> PDFDestination? {
        destinations.indices.contains(line) ? destinations[line] : nil
    }

    /// The last entry landing on or before a page. An outline names where a
    /// section begins, so the reader is inside the one they most recently
    /// passed — and inside nothing at all until they have passed the first.
    func line(forPage page: Int) -> Int? {
        var found: Int?
        for (line, entryPage) in pages.enumerated() {
            guard let entryPage, entryPage != NSNotFound, entryPage <= page else { continue }
            found = line
        }
        return found
    }
}

// MARK: - The view the Find menu reaches

/// The `PDFView` a PDF tab is read in, and the one thing it is here for: ⌘F.
///
/// Find…, Find Next, Find Previous and Use Selection for Find are nil-targeted
/// `performTextFinderAction:` items, so they land on whatever has the keyboard
/// — and in reading mode over a PDF that is this view. It hands them to the
/// document's own session, exactly as the render's text view hands them to
/// its one, so Nota's pill is the only find UI a PDF tab ever shows.
///
/// `performTextFinderAction:` is an override: `PDFView` answers for it itself
/// with PDFKit's own find bar, and that bar is exactly what must never appear
/// in a Nota window. `validateUserInterfaceItem` is not — `PDFView` is an
/// `NSView` rather than an `NSTextView`, so the conformance is written down
/// here, and Find and Replace… is the item it says no to: a page cannot be
/// typed into.
final class NotaPDFView: PDFView, NSUserInterfaceValidations {

    /// The document's find bar. Weak, the way the render's is: the session
    /// belongs to the pane, and the pane owns this view.
    weak var findSession: PDFFindSession?

    /// Files let go on the document, which open as tabs the way they do
    /// anywhere else over the column.
    ///
    /// `PDFView` answers for a file drop itself, by opening the file in
    /// place: a PDF dropped on a PDF replaces it, and the tab that was being
    /// read is showing another document with no way back. So the drag never
    /// reaches PDFKit — the types it registered for are taken off this view
    /// and only `public.file-url` is put back, and the methods below answer
    /// without ever calling `super`.
    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        unregisterDraggedTypes()
        registerForDraggedTypes(PreviewFileDrop.types)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Dropped files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { }

    // MARK: - Find

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession?.perform(action)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else { return true }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return PDFFindSession.handles(action)
    }
}
