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
final class PDFPreviewView: NSView, PreviewContent, PageListSource {

    private let pdfView = NotaPDFView()
    /// Shown instead of the document when the file has gone — deleted while
    /// the tab was open, or missing by the time the session comes back.
    private let missingLabel = NSTextField(labelWithString: "")

    /// The document's own ⌘F bar, floating in the top-trailing corner of the
    /// column — the same pill the editor and the render use, over PDFKit's
    /// selections instead of a text storage.
    private let findBar = FindBarView()
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
        documentURL = note.fileURL
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

    // MARK: - The document's own pages

    /// The file the document in the pane was read from, which is what its
    /// thumbnails are drawn from — see `PDFPageThumbnails`.
    private var documentURL: URL?

    /// The thumbnails already drawn, per document rather than per pane: one
    /// pane serves every PDF tab in the window, so a trip through another tab
    /// and back must not throw a document's pages away and draw them again.
    /// Weak keys, so they go when the tab that held the document closes.
    private let thumbnailCaches
        = NSMapTable<PDFDocument, PDFPageThumbnails>.weakToStrongObjects()

    /// What the sidebar lists a document's pages from. A pane with no
    /// document in it has none, which is what keeps the column away from a
    /// file that has gone.
    var pageList: PageListSource? { pageCount > 0 ? self : nil }

    /// The document in the pane, as something a column can compare.
    var pageListIdentity: AnyHashable {
        ObjectIdentifier(pdfView.document ?? PDFDocument())
    }

    /// A page chosen in the column: the top of it, which is what was asked
    /// for.
    func goToPage(_ index: Int) {
        guard let document = pdfView.document, document.pageCount > 0,
              let page = document.page(at: min(max(index, 0), document.pageCount - 1))
        else { return }
        installedPage = max(index, 0)
        isInstalling = true
        pdfView.go(to: page)
        isInstalling = false
        // `go(to:)` does not always carry a `PDFViewPageChanged` of its own,
        // and the one it does carry is swallowed above, so where the tab is
        // left is reported by hand.
        onPositionChange?(currentPageIndex)
    }

    /// A hit chosen in the ⇧⌘F dialog (SPEC Done 37): the page it is printed
    /// on comes up and the match itself is selected on it. The range is into
    /// that page's own `string` — the text the search read — so PDFKit maps it
    /// straight back to the marks it was taken from.
    func reveal(page index: Int, range: NSRange, query: String) {
        guard let document = pdfView.document, index >= 0, index < document.pageCount,
              let page = document.page(at: index)
        else { return }
        goToPage(index)
        guard let selection = page.selection(for: range) else { return }
        findSession.reveal(selection, for: query)
    }

    func thumbnail(forPage index: Int, completion: @escaping (NSImage?) -> Void) {
        guard let thumbnails else { return completion(nil) }
        thumbnails.thumbnail(forPage: index, completion: completion)
    }

    /// The cache for the document in the pane, made the first time it is
    /// asked for.
    private var thumbnails: PDFPageThumbnails? {
        guard let document = pdfView.document, let url = documentURL else { return nil }
        if let existing = thumbnailCaches.object(forKey: document) { return existing }
        let made = PDFPageThumbnails(url: url)
        thumbnailCaches.setObject(made, forKey: document)
        return made
    }

    /// Runs once every thumbnail asked for so far has landed — the tests'
    /// only way to wait for a background queue without a sleep.
    func whenThumbnailsSettleForTesting(_ body: @escaping () -> Void) {
        guard let thumbnails else { return body() }
        thumbnails.whenSettled(body)
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

// MARK: - The pages, drawn small

/// A document's pages as thumbnails: drawn off the main thread, handed back on
/// it, and kept for as long as the document is open.
///
/// It reads the file again rather than borrowing the `PDFDocument` the pane is
/// drawing from. PDFKit's objects are not safe to touch from two threads at
/// once, and the pane's document is being drawn, searched and scrolled on the
/// main one the whole time a page list is filling in; a copy of its own, only
/// ever touched on this one serial queue, is the cheap way to be sure. A
/// `PDFDocument` parses lazily, so the second copy costs a file handle and the
/// pages actually asked for.
///
/// Nothing is drawn until somebody asks for it, and the column asks only for
/// the cards being looked at. A five-hundred-page document therefore opens at
/// the cost of a screenful, and the rest arrive as it is scrolled.
final class PDFPageThumbnails {
    /// Drawn at twice the card's size, so the picture is a Retina one.
    private static let renderScale: CGFloat = 2

    private let url: URL
    private let queue = DispatchQueue(
        label: "app.nota.pdf-thumbnails", qos: .userInitiated
    )

    /// Only ever touched on `queue`.
    private lazy var document: PDFDocument? = PDFDocument(url: url)

    /// Only ever touched on the main thread.
    private var cache: [Int: NSImage] = [:]
    private var inFlight: Set<Int> = []

    init(url: URL) { self.url = url }

    /// The page drawn small. A page already drawn answers at once, on the
    /// caller's own thread; anything else is queued and answered on the main
    /// one. Asking again for a page already being drawn is not a second
    /// render and gets no second answer — the first one is on its way.
    func thumbnail(forPage index: Int, completion: @escaping (NSImage?) -> Void) {
        if let image = cache[index] { return completion(image) }
        guard !inFlight.contains(index) else { return }
        inFlight.insert(index)
        let box = NSSize(
            width: SidebarCard.squareSize * Self.renderScale,
            height: SidebarCard.squareSize * Self.renderScale
        )
        queue.async { [weak self] in
            guard let self else { return }
            let image = Self.render(page: index, of: self.document, fitting: box)
            DispatchQueue.main.async {
                self.inFlight.remove(index)
                if let image { self.cache[index] = image }
                completion(image)
            }
        }
    }

    /// Runs once everything asked for so far has been drawn and handed over.
    /// The queue is serial and every answer is posted to the main thread from
    /// it, so a block put on the back of both queues in turn is behind all of
    /// them.
    func whenSettled(_ body: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: body) }
    }

    private static func render(
        page index: Int, of document: PDFDocument?, fitting box: NSSize
    ) -> NSImage? {
        guard let document, index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return nil }
        let image = page.thumbnail(of: box, for: .cropBox)
        guard image.size.width > 1, image.size.height > 1 else { return nil }
        // Half the size it was drawn at, so it is a 2× picture on the card
        // rather than one twice as big.
        image.size = NSSize(
            width: image.size.width / Self.renderScale,
            height: image.size.height / Self.renderScale
        )
        return image
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

    // MARK: - Selecting text

    /// Where the drag that made the current selection began, so a ⇧-click
    /// carries on from it.
    private var selectionAnchor: (page: PDFPage, point: CGPoint)?
    private var isSelectingText = false

    /// A plain drag selects the characters between where it began and where
    /// the pointer is, in reading order — the way a text view does.
    ///
    /// PDFKit's own drag, begun anywhere off a glyph, picks a rectangle out of
    /// its guess at the page's blocks instead: a box with handles that runs
    /// into the margin and cuts lines in half. So a single click is taken here,
    /// unless it lands on an annotation — a link to follow, a field to fill,
    /// both PDFKit's — or carries ⌘/⌥/⌃ (its
    /// own gestures). A double or triple click is still PDFKit's word and line.
    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard event.clickCount == 1, modifiers.isEmpty,
              let (page, point) = pagePoint(of: event),
              page.annotation(at: point) == nil
        else {
            isSelectingText = false
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        isSelectingText = true
        if event.modifierFlags.contains(.shift), let anchor = selectionAnchor {
            select(from: anchor, to: (page, point))
        } else {
            selectionAnchor = (page, point)
            clearSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelectingText else { return super.mouseDragged(with: event) }
        autoscroll(with: event)
        guard let anchor = selectionAnchor, let current = pagePoint(of: event) else { return }
        select(from: anchor, to: current)
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelectingText else { return super.mouseUp(with: event) }
        isSelectingText = false
    }

    private func pagePoint(of event: NSEvent) -> (PDFPage, CGPoint)? {
        let inView = convert(event.locationInWindow, from: nil)
        guard let page = page(for: inView, nearest: true) else { return nil }
        return (page, convert(inView, to: page))
    }

    private func select(from start: (page: PDFPage, point: CGPoint), to end: (page: PDFPage, point: CGPoint)) {
        let selection: PDFSelection?
        if start.page === end.page {
            selection = start.page.selection(from: start.point, to: end.point)
        } else {
            selection = document?.selection(from: start.page, at: start.point, to: end.page, at: end.point)
        }
        if let selection, !(selection.string ?? "").isEmpty {
            setCurrentSelection(selection, animate: false)
        } else {
            clearSelection()
        }
    }

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
