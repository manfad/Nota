import AppKit
import UniformTypeIdentifiers
import WebKit

/// The preview column's third content view: an HTML page, drawn by WebKit,
/// where a Markdown tab would have its render.
///
/// HTML is the one format Nota does not read for you. A `.md` and a `.tex`
/// are source Nota renders into its own reading layout; a `.html` file is
/// already a page, with its own type, colours, stylesheets and scripts, and
/// the only honest preview of it is the page itself. So this is a `WKWebView`
/// and nothing more — the same argument PDFKit wins for a PDF.
///
/// An `.svg` is the same arrangement: text you edit, a drawing beside it, and
/// WebKit is what draws it. The only difference is the type it is handed over
/// as, so that the root `<svg>` is the document rather than a tag inside a
/// page it never asked for.
///
/// It is a view of the note beside it, not of the file on disk: the editor's
/// text is what is loaded, so unsaved edits are the page. Relative URLs
/// resolve beside the file, which is why the page is loaded against the
/// file's own path as its base — under a scheme of Nota's own, for the reason
/// `PageFiles` gives.
///
/// A DOM is still not a list of source ranges, so there are no blocks and no
/// band — but a press on an element does its best: the page reports where in
/// its own document order the element sits, and `HTMLSourceMap` lines that up
/// against the tags the file actually writes to reveal the start tag in the
/// editor (done 2026-09-07). It reveals rather than jumps, the way a tree row
/// and a grid cell do: the caret moves and the page keeps the keyboard. There
/// is a find bar, in the same corner every other column keeps one — but the
/// search
/// itself is a script in the page, since a page is the one thing Nota reads
/// without ever holding. The other thing it keeps is where the reader had
/// scrolled to, so a keystroke in the editor does not throw the page back to
/// the top.
final class HTMLPreviewView: NSView, PreviewContent {

    /// The page, once there has been one. Nothing here is built until a
    /// `.html` tab is actually being read: a web view is a content process,
    /// and a window whose tabs are all Markdown should not be paying for one.
    /// Internal rather than private so the tests can put JavaScript questions
    /// to whatever is on screen — there is no other way to ask a web view
    /// what it is showing.
    private(set) var webView: HTMLPageView?

    /// What the page on screen was made from. A show that would load the same
    /// text against the same file is answered by what is already there:
    /// showing is asked again on a resize, a tab switch and a settings change,
    /// and a reload would flash the page and lose the scroll.
    private var loadedKey: LoadKey?

    /// How many times a page has actually been loaded, and the file it was
    /// loaded against — for the tests, which have no other way to tell a
    /// reload from a show that did nothing.
    private(set) var loadCount = 0
    private(set) var shownBaseURL: URL?

    /// Where a link that leaves the page goes. The browser, in the app; the
    /// tests put their own in, so a suite run never opens one.
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Run when a page has finished loading and been put back where it was —
    /// for the tests, since a load is asynchronous and nothing else says when
    /// it has landed.
    var onLoadFinished: (() -> Void)?

    /// Whether the page is drawn in Nota's own colours when the Mac is dark.
    /// Set by the book pane before its first chapter loads; a script cannot
    /// be added to a page already started, so it is read once, when the web
    /// view is made.
    var appliesReaderTheme = false

    /// Where the reader is in each tab's page, kept up to date by the page
    /// itself, so a reload can put them back. Read before a load rather than
    /// asked for: asking is asynchronous, and the load cannot wait on an
    /// answer.
    ///
    /// Per tab, because the pane is one view every `.html` tab is read
    /// through: one number for all of them would land a tab you have just
    /// switched to at the depth of the one you left.
    private var scrollOffsets: [UUID: CGPoint] = [:]

    /// The same, as a share of the page's own scrollable height. A book is
    /// read a chapter at a time and every chapter is a different length, so
    /// where the reader was is only meaningful relative to the page they were
    /// in — and a session brings the tab back into a column of another width,
    /// where the pixels would mean somewhere else.
    private var scrollFractions: [UUID: Double] = [:]

    /// Where the page being loaded should land when it arrives, when it is
    /// somewhere other than where the tab was left: an anchor a chapter was
    /// jumped to by, or the share of a chapter a session remembers. One shot
    /// — the next load has its own answer.
    private var pendingLanding: Landing?

    /// Where a page is put once it has loaded.
    fileprivate enum Landing {
        /// An `#anchor` inside it, scrolled to by name.
        case fragment(String)
        /// A share of the way down it, 0 the top and 1 the bottom.
        case fraction(Double)
    }

    /// Whose page is on screen — which tab a scroll report belongs to, and
    /// whose offset a finished load puts back.
    private var showingNoteID: UUID?

    /// Which load is the current one. A page still arriving when the next
    /// load is asked for must not restore a scroll position or report itself
    /// finished on top of the one that replaced it.
    private var generation = 0

    private var takesKeyboardStorage = false

    /// The page's own ⌘F bar, floating in the top-trailing corner of the
    /// column — the same pill the editor, the render and a document use.
    private let findBar = FindBarView(placeholder: "Find in page")
    private lazy var findSession = HTMLFindSession(bar: findBar) { [weak self] in
        self?.webView
    }

    /// Run when that bar opens or closes, and whether it is up — the column's
    /// mode control drops below it, the same as over a render.
    var onFindBarVisibilityChange: ((Bool) -> Void)?

    /// Run when the reader asks the page to move on or back — `→` and `←`,
    /// and a page key at the end of the page — with `1` forward and `-1`
    /// back. A page has nowhere to go on its own, so this is nil for a
    /// `.html` tab and set only by the book that reads its chapters through
    /// here. The script that reports it never swallows the key, so a page
    /// with nobody listening scrolls exactly as it always did.
    var onChapterKey: ((Int) -> Void)?

    /// Run when the reader presses an element in the page and the source map
    /// can say where that element is written: the editor selects the tag and
    /// brings it into view, and the page keeps the keyboard it had. Never a
    /// block click — the page is not a render, and nobody asked to leave it.
    var onSourceReveal: ((NSRange) -> Void)?

    /// Where the page on screen is written in the note beside it, when the
    /// page *is* the note beside it. Built once per load, from the same text
    /// the page was loaded from, and `nil` for everything that is not that: a
    /// book's chapter, the message a broken drawing gets, and a page the
    /// tokeniser will not read.
    private var sourceMap: HTMLSourceMap?

    /// The map the pane is holding, for the tests.
    var sourceMapForTesting: HTMLSourceMap? { sourceMap }

    /// Whether something in the page is being typed into — a field, a text
    /// area, a `contenteditable` — which is the one thing that takes the
    /// keyboard away from the editor in split (done 2026-09-07). See
    /// `editableFocusReporter`.
    private var pageHoldsEditableFocus = false

    /// Run when that changes, with whether the page now holds a field. For
    /// the tests: the page's answer crosses a process boundary, and nothing
    /// else says when it has landed.
    var onEditableFocusChange: ((Bool) -> Void)?

    var isFindBarVisible: Bool { findSession.isVisible }

    var findBarHeight: CGFloat { findBar.stackHeight }

    /// How many matches the bar is counting, for the tests.
    var findMatchCount: Int? { findSession.matchCount }

    /// The query the page is being searched for. It outlives the bar, the way
    /// ⌘G does.
    var findQuery: String { findSession.query }

    /// A hit chosen in the ⇧⌘F dialog: the query is put to this page with the
    /// pill up on it (SPEC Done 37).
    func find(_ query: String) { findSession.find(query) }

    /// Run when the page has answered the find bar — for the tests, since
    /// every one of those answers crosses a process boundary and nothing else
    /// says when one has landed.
    var onFindAnswered: (() -> Void)? {
        get { findSession.onPageAnswered }
        set { findSession.onPageAnswered = newValue }
    }

    /// Files let go on the page. WebKit would take them itself and navigate
    /// away from what is being read, so the page view never sees the drag —
    /// see `HTMLPageView`. Kept here as well as handed on, since the pane is
    /// an empty rectangle until the first tab is read through it and a drop
    /// on that is still a drop on the column.
    var onDropFiles: (([URL]) -> Void)? {
        didSet { webView?.onDropFiles = onDropFiles }
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

    /// Builds the page's view, the first time there is a page to put in it.
    ///
    /// Every window has one of these panes whether or not it ever opens a
    /// `.html` file, and a `WKWebView` is not a view — it is a pair of
    /// processes. So the pane is an empty rectangle until the first tab is
    /// actually read through it, and a window of Markdown notes never starts
    /// WebKit at all.
    @discardableResult
    private func makeWebView() -> HTMLPageView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PageFiles(), forURLScheme: PageFiles.scheme)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.scrollReporter, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
        // The find bar's other half. It goes into every page whether or not
        // ⌘F is ever pressed there: a script cannot be injected into a page
        // that has already loaded, and the reader does not announce a search
        // before making one.
        controller.addUserScript(WKUserScript(
            source: HTMLFindSession.script(
                quietBand: NSColor.systemGray.withAlphaComponent(0.4),
                currentBand: .findHighlightColor
            ),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        // The reporter talks to us rather than to the page: a separate world,
        // so nothing here is a global the page can see, shadow or trip over.
        // The other half of the keys a book is turned by. It goes into every
        // page for the same reason the find script does — a script cannot be
        // injected into a page that has already loaded — and does nothing at
        // all unless somebody is listening.
        controller.addUserScript(WKUserScript(
            source: Self.chapterKeys, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
        // And the half of the source reveal that lives in the page, in the
        // same world and for the same reason as the other two.
        controller.addUserScript(WKUserScript(
            source: Self.elementReporter, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
        // And the one that says a field in the page is being typed into.
        controller.addUserScript(WKUserScript(
            source: Self.editableFocusReporter, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
        // A book is read in Nota's own light or dark, the way a note is (see
        // `readerTheme`); a `.html` file is the author's page and keeps its
        // own colours.
        if appliesReaderTheme {
            controller.addUserScript(WKUserScript(
                source: Self.readerThemeScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .defaultClient
            ))
        }
        controller.add(ScrollReporter(view: self), contentWorld: .defaultClient,
                       name: Self.scrollHandlerName)
        controller.add(ChapterKeyReporter(view: self), contentWorld: .defaultClient,
                       name: Self.chapterHandlerName)
        controller.add(ElementReporter(view: self), contentWorld: .defaultClient,
                       name: Self.elementHandlerName)
        controller.add(EditableFocusReporter(view: self), contentWorld: .defaultClient,
                       name: Self.editableHandlerName)

        let page = HTMLPageView(frame: bounds, configuration: configuration)
        page.findSession = findSession
        page.onDropFiles = onDropFiles
        // The keyboard going back to the editor ends the field's exception,
        // whatever the DOM still believes is focused: the next click in the
        // page must not take the caret again.
        page.onKeyboardResigned = { [weak self] in self?.pageLostTheKeyboard() }
        // Pinned edge to edge, unlike the Markdown render's own margins, and
        // for the same reason a PDF is: a page lays out to the viewport it is
        // given, and its own body margin is already the margin its author
        // asked for. An inset here would be a second one outside that.
        page.translatesAutoresizingMaskIntoConstraints = false
        page.navigationDelegate = self
        page.takesKeyboard = takesKeyboardStorage
        // The column's background is the editor's until the page paints over
        // it, so an empty pane and a page still arriving both match the text
        // beside them rather than flashing white into a dark window.
        page.setValue(false, forKey: "drawsBackground")
        page.underPageBackgroundColor = .textBackgroundColor
        // A zoom asked for before WebKit was ever started — a tab reopened at
        // one — belongs to the page the moment there is one.
        page.pageZoom = zoomStorage
        // Below the pill, which has been standing in this corner since the
        // pane was built: a bar the page is drawn over is not a bar.
        addSubview(page, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        webView = page
        return page
    }

    // MARK: - Zoom

    private var zoomStorage: CGFloat = 1

    /// A page zooms rather than changing a font. In reading mode it is the
    /// only thing on screen and the editor's font is a font nobody can see;
    /// in the other two the editor is right there, and the keys mean what
    /// they have always meant — which the window settles, not this.
    var canZoom: Bool { webView != nil }

    /// Half size to five times it. `pageZoom` is the page's own zoom, the one
    /// a browser's ⌘+ turns: the layout is done again at the new size, so text
    /// re-wraps to the column rather than being magnified as a picture of
    /// itself.
    private static let zoomRange: ClosedRange<CGFloat> = 0.5 ... 5

    var zoom: CGFloat {
        get { zoomStorage }
        set {
            let clamped = min(max(newValue, Self.zoomRange.lowerBound),
                              Self.zoomRange.upperBound)
            guard clamped != zoomStorage else { return }
            zoomStorage = clamped
            webView?.pageZoom = clamped
        }
    }

    /// The zoom as the pill in the corner says it: a whole number of percent
    /// of the page's own size, so an unzoomed page reads 100%.
    var zoomPercent: Int? { canZoom ? Int((zoom * 100).rounded()) : nil }

    // MARK: - Content

    /// Puts the tab's text in the pane as a page, unless the page already
    /// there was made from it — a resize, a tab switch and a settings change
    /// all ask again with nothing moved, and a reload would flash the page
    /// and lose the scroll.
    ///
    /// A page nobody can see is not worth loading at all: in the editor mode
    /// the column is away, and every keystroke would otherwise reload a page
    /// off screen. The key is left alone on the way out, so the mode that
    /// brings the column back loads on the way in.
    func show(_ note: Note, in context: PreviewContext) {
        guard context.isVisible else { return }
        let key = LoadKey(noteID: note.id, text: note.text, filePath: note.fileURL?.path,
                          isSVG: note.previewKind == .svg)
        guard loadedKey != key else { return }
        loadedKey = key
        // The page is the note's own text, so a press in it can be answered
        // with a range in the editor.
        load(key, mapsToSource: true)
    }

    /// Puts a file on screen as the page, rather than the text of the note in
    /// front — one chapter of an EPUB, which is XHTML in a folder with the
    /// book's own stylesheets and pictures beside it (SPEC Todo 3).
    ///
    /// A note's page is its text; a chapter's page is a file, and the tab
    /// holding it is the book rather than the chapter. So the tab's id is
    /// passed in — it is what the scroll is kept under — and where the reader
    /// lands is the caller's to say: the top of a chapter turned to, an
    /// anchor jumped to from the contents, or the share of the chapter a
    /// session remembers.
    ///
    /// `false` when the file could not be read, which is what a book with a
    /// chapter missing from its own folder looks like.
    @discardableResult
    func showPage(
        ofTab id: UUID, at fileURL: URL, fragment: String?, scrollFraction: Double,
        in context: PreviewContext
    ) -> Bool {
        guard context.isVisible else { return true }
        guard let opened = TextFile.read(at: fileURL) else { return false }
        let key = LoadKey(noteID: id, text: opened.text, filePath: fileURL.path, isSVG: false)
        // Already the page on screen. An anchor inside it is still somewhere
        // to go — jumping from the contents to a place in the chapter you are
        // reading must not be nothing at all — so it is scrolled to on the
        // spot rather than through a reload.
        guard loadedKey != key else {
            if let fragment, let webView {
                land(.fragment(fragment), in: webView, generation: generation)
            }
            return true
        }
        loadedKey = key
        if let fragment {
            pendingLanding = .fragment(fragment)
        } else if scrollFraction > 0 {
            pendingLanding = .fraction(scrollFraction)
        } else {
            pendingLanding = .fraction(0)
        }
        // A chapter is a file in the book's own folder and the tab holding it
        // is the book: there is no source beside it for a press to reveal.
        load(key, mapsToSource: false)
        return true
    }

    /// Throws the remembered page away, so the next ask loads a fresh one.
    func invalidateRender() {
        loadedKey = nil
    }

    private func load(_ key: LoadKey, mapsToSource: Bool) {
        generation += 1
        loadCount += 1
        // The ranges the bands are painted on belong to the document being
        // replaced. A page of the same note comes back to the same query on
        // `didFinish`; a different tab's page comes back to nothing.
        if key.noteID != showingNoteID { findSession.close() }
        showingNoteID = key.noteID
        shownBaseURL = key.fileURL.flatMap(PageFiles.pageURL)
        // Against the file's own path rather than its folder's, so `style.css`
        // beside it resolves and an in-page `#` is the same document.
        //
        // A drawing is handed over as what it is. Loaded as HTML, an `.svg`
        // would be parsed by the HTML rules — the root `<svg>` becomes an
        // element inside a `<body>` the file never had — and half of what the
        // file says would be read as something else. Given its own type, the
        // drawing is the document.
        let page = makeWebView()
        // Rebuilt with the page, and only with the page: the "same text, no
        // reload" check above is what keeps it in step with what is on screen.
        sourceMap = mapsToSource ? HTMLSourceMap(source: key.text) : nil
        // A page still arriving has nothing focused in it yet.
        pageHoldsEditableFocus = false
        page.editableFocus = false
        guard key.isSVG else {
            page.loadHTMLString(key.text, baseURL: shownBaseURL)
            return
        }
        // A drawing that will not parse gets Nota's own page rather than
        // WebKit's: that one is black type in a pink box whatever the
        // appearance, unreadable over a dark column, and it prints the find
        // bar's injected stylesheet as text under the box.
        if let problem = SVGCheck.problem(in: key.text) {
            // Nota's own page, not the reader's file: nothing in it is
            // written anywhere the editor could go.
            sourceMap = nil
            page.loadHTMLString(Self.svgProblemPage(problem), baseURL: nil)
            return
        }
        page.load(Data(key.text.utf8), mimeType: "image/svg+xml",
                  characterEncodingName: "utf-8",
                  baseURL: shownBaseURL ?? URL(fileURLWithPath: "/"))
    }

    /// The page shown for a drawing that will not parse: the message in the
    /// column's own colours, light or dark.
    static func svgProblemPage(_ problem: String) -> String {
        let title = L10n.text("This drawing cannot be shown")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, system-ui, sans-serif; color: CanvasText; margin: 24px; }
        .box { background: rgba(220, 60, 60, 0.10); border-radius: 6px; padding: 12px 16px; }
        h1 { font-size: 15px; font-weight: 600; margin: 0 0 6px; }
        p { margin: 0; font: 12px ui-monospace, Menlo, monospace; opacity: 0.8; }
        </style></head><body><div class="box"><h1>\(escaped(title))</h1><p>\(escaped(problem))</p></div></body></html>
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// What the page on screen was made from. The file's path is in it
    /// because the page resolves everything it draws beside the file — the
    /// same source in another folder is another page.
    private struct LoadKey: Equatable {
        let noteID: UUID
        let text: String
        let filePath: String?
        /// Whether the text is a drawing rather than a page — which changes
        /// the type it is handed over as, and so what it parses into.
        let isSVG: Bool

        /// The file the page is read against — its base URL, and the folder
        /// everything relative in it resolves from.
        var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
    }

    // MARK: - Keyboard

    /// Whether the page takes the keyboard. Only in reading mode, where it is
    /// the only thing on screen: in split the caret stays in the editor, so a
    /// click in the page — following a link, selecting a word — must not take
    /// it away.
    var takesKeyboard: Bool {
        get { takesKeyboardStorage }
        set {
            takesKeyboardStorage = newValue
            webView?.takesKeyboard = newValue
        }
    }

    /// Puts the keyboard in the page — reading mode's answer to `focusEditor`,
    /// so the arrow and page keys scroll it and its own links take the tab
    /// key.
    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        guard let window, let webView else { return false }
        return window.makeFirstResponder(webView)
    }

    // MARK: - Where the reader is

    private static let scrollHandlerName = "notaScroll"

    /// Injected into every page: the page tells us where it has been scrolled
    /// to, rather than us asking for it. Asking is asynchronous, and the one
    /// moment the answer is wanted — just before a reload — is the one moment
    /// there is no time to wait for it.
    /// The reader theme, for a book: in dark mode every run of text is drawn
    /// in the label colour, links in the system blue, rules and table borders
    /// in the separator grey, and the paper the book asked for is taken away
    /// so Nota's own ground shows through. A book's stylesheet is written for
    /// paper — `color: #000` on the body is "the text", not a colour anybody
    /// chose — and taking it at its word prints black type onto a dark ground.
    /// Light mode is left exactly as the author styled it. The sheet goes in
    /// at document start, before the book's own, and wins by `!important`.
    static let readerThemeCSS = """
    @media (prefers-color-scheme: dark) {
      html { color-scheme: dark; }
      html, body { background: transparent !important; }
      body, body * { color: rgba(255, 255, 255, 0.85) !important; }
      a, a * { color: #409cff !important; }
      hr, table, th, td, blockquote { border-color: rgba(255, 255, 255, 0.25) !important; }
    }
    """

    private static let readerThemeScript = """
    (function () {
        function install() {
            var style = document.createElement("style");
            style.setAttribute("data-nota", "reader-theme");
            style.textContent = `\(readerThemeCSS)`;
            document.documentElement.appendChild(style);
        }
        // An XHTML chapter may have no root element yet at document start.
        if (document.documentElement) { install(); }
        else { document.addEventListener("DOMContentLoaded", install); }
    })();
    """

    private static let scrollReporter = """
    (function () {
        var pending = false;
        function report() {
            pending = false;
            var room = Math.max(
                0,
                document.documentElement.scrollHeight - window.innerHeight
            );
            window.webkit.messageHandlers.\(scrollHandlerName).postMessage(
                { x: window.scrollX, y: window.scrollY, room: room }
            );
        }
        window.addEventListener('scroll', function () {
            if (pending) { return; }
            pending = true;
            window.requestAnimationFrame(report);
        }, { passive: true });
    })();
    """

    fileprivate func readerScrolled(to point: CGPoint, room: Double) {
        guard let showingNoteID else { return }
        scrollOffsets[showingNoteID] = point
        scrollFractions[showingNoteID] = room > 0
            ? min(1, max(0, Double(point.y) / room))
            : 0
    }

    /// How far down its page a tab was left, as a share of the room there was
    /// to scroll — what a book keeps in the session, since the pixels would
    /// mean somewhere else in a column of another width.
    ///
    /// `nil` until the page has actually said, which is not the same as the
    /// top: a tab restored and not yet read is still owed the place the
    /// session remembers, and answering 0 would write over it.
    func rememberedScrollFraction(ofTab id: UUID) -> Double? {
        scrollFractions[id]
    }

    /// The keys a book is turned by, reported rather than acted on: the page
    /// says nothing about what a chapter is. Never swallowed — a page with
    /// nobody listening scrolls the way it always did.
    private static let chapterKeys = """
    (function () {
        function typing(target) {
            if (!target) { return false; }
            var name = (target.tagName || '').toLowerCase();
            return name === 'input' || name === 'textarea' || target.isContentEditable;
        }
        function send(step) {
            window.webkit.messageHandlers.\(chapterHandlerName).postMessage({ step: step });
        }
        function atBottom() {
            return window.scrollY + window.innerHeight
                >= document.documentElement.scrollHeight - 2;
        }
        document.addEventListener('keydown', function (event) {
            if (event.metaKey || event.ctrlKey || event.altKey) { return; }
            if (typing(event.target)) { return; }
            if (event.key === 'ArrowRight') { send(1); }
            else if (event.key === 'ArrowLeft') { send(-1); }
            else if (event.key === 'PageDown' && atBottom()) { send(1); }
            else if (event.key === 'PageUp' && window.scrollY <= 2) { send(-1); }
        });
    })();
    """

    private static let chapterHandlerName = "notaChapter"

    fileprivate func readerTurnedPage(_ step: Int) {
        onChapterKey?(step)
    }

    // MARK: - Which element was pressed

    private static let elementHandlerName = "notaElement"

    /// The page's half of the source reveal: which element was pressed, and
    /// what every element up to it is called.
    ///
    /// Document order — `querySelectorAll('*')` — is the one ruler both sides
    /// can count by. The names ride along because a DOM holds elements no
    /// file ever wrote (an implied `html`, `head`, `body` or `tbody`, and
    /// anything a script added) and `HTMLSourceMap` cannot skip what it
    /// cannot see. Only the names up to the pressed element are sent; nothing
    /// after it is ever looked at.
    ///
    /// It listens and never acts: capture phase, no `preventDefault`, so a
    /// link still opens, a control still takes the press, and a page with
    /// handlers of its own behaves exactly as it did. A press inside a link
    /// is left alone altogether — following it is what the reader asked for.
    private static let elementReporter = """
    (function () {
        document.addEventListener('mousedown', function (event) {
            if (event.button !== 0) { return; }
            var target = event.target;
            while (target && target.nodeType !== 1) { target = target.parentNode; }
            if (!target) { return; }
            if (target.closest && target.closest('a[href]')) { return; }
            var all = document.querySelectorAll('*');
            var names = [];
            for (var i = 0; i < all.length; i++) {
                names.push((all[i].tagName || '').toLowerCase());
                if (all[i] === target) {
                    window.webkit.messageHandlers.\(elementHandlerName).postMessage(
                        { index: i, tags: names }
                    );
                    return;
                }
            }
        }, true);
    })();
    """

    /// A press landed on an element. Best effort by design: a page whose DOM
    /// the map cannot line up against its own source says nothing at all,
    /// rather than sending the caret to the wrong tag.
    fileprivate func readerPressed(elementAt index: Int, tagNames: [String]) {
        guard let onSourceReveal, let sourceMap,
              let range = sourceMap.range(ofElementAt: index, tagNames: tagNames)
        else { return }
        onSourceReveal(range)
    }

    // MARK: - A field in the page

    private static let editableHandlerName = "notaEditable"

    /// The one exception to "a click in split must not steal the caret".
    ///
    /// A page is not always something to read. It can carry a field, a text
    /// area or a `contenteditable`, and clicking one of those focused it in
    /// the DOM while the keystrokes went on landing in the editor beside it —
    /// the page looked as though it were taking typing and took none. So the
    /// page says when something in it is being typed into, and for as long as
    /// that is true the view accepts first responder and is given it.
    ///
    /// Only a *field* is the exception; a click anywhere else in the page
    /// still leaves the caret where it was. And the keyboard is never thrown
    /// back: losing the field ends the exception, and the reader's next click
    /// decides where the keys go, exactly as it does everywhere else.
    private static let editableFocusReporter = """
    (function () {
        function editable(node) {
            if (!node || node.nodeType !== 1) { return false; }
            var name = (node.tagName || '').toLowerCase();
            return name === 'input' || name === 'textarea' || name === 'select'
                || node.isContentEditable === true;
        }
        function report(state) {
            window.webkit.messageHandlers.\(editableHandlerName).postMessage(
                { editable: state }
            );
        }
        document.addEventListener('focusin', function (event) {
            if (editable(event.target)) { report(true); }
        }, true);
        document.addEventListener('focusout', function (event) {
            if (editable(event.target)) { report(false); }
        }, true);
    })();
    """

    /// Something in the page took the focus, or gave it up.
    fileprivate func pageEditableFocusChanged(_ focused: Bool) {
        guard pageHoldsEditableFocus != focused else { return }
        pageHoldsEditableFocus = focused
        webView?.editableFocus = focused
        // Focus in: the page is given the keyboard, since WebKit delivers key
        // events only to a first responder. Focus out: it is left exactly
        // where it is — snatching it back to the editor mid-sentence would be
        // the same rudeness in the other direction.
        if focused, let webView, let window = webView.window,
           window.firstResponder !== webView {
            window.makeFirstResponder(webView)
        }
        onEditableFocusChange?(focused)
    }

    /// The keyboard has gone somewhere else — a click in the editor beside
    /// the page. Whatever the DOM still thinks is focused, the exception is
    /// over.
    fileprivate func pageLostTheKeyboard() {
        guard pageHoldsEditableFocus else { return }
        pageHoldsEditableFocus = false
        webView?.editableFocus = false
        onEditableFocusChange?(false)
    }

    /// Where a tab was left in its page. The one number a reload puts back,
    /// and what the tests read to say it was put back.
    func rememberedScroll(ofTab id: UUID) -> CGPoint {
        scrollOffsets[id] ?? .zero
    }

    /// Held on the user content controller, which holds it for as long as the
    /// configuration lives; a strong reference back to the pane would be a
    /// cycle the pane never gets out of.
    private final class ScrollReporter: NSObject, WKScriptMessageHandler {
        private weak var view: HTMLPreviewView?

        init(view: HTMLPreviewView) { self.view = view }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let x = body["x"] as? Double, let y = body["y"] as? Double
            else { return }
            view?.readerScrolled(to: CGPoint(x: x, y: y), room: body["room"] as? Double ?? 0)
        }
    }

    /// The same arrangement for the keys a book is turned by.
    private final class ChapterKeyReporter: NSObject, WKScriptMessageHandler {
        private weak var view: HTMLPreviewView?

        init(view: HTMLPreviewView) { self.view = view }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let step = body["step"] as? Double
            else { return }
            view?.readerTurnedPage(Int(step))
        }
    }

    /// And for a field in the page taking the focus or giving it up.
    private final class EditableFocusReporter: NSObject, WKScriptMessageHandler {
        private weak var view: HTMLPreviewView?

        init(view: HTMLPreviewView) { self.view = view }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let focused = body["editable"] as? Bool
            else { return }
            view?.pageEditableFocusChanged(focused)
        }
    }

    /// And for the element a press landed on.
    private final class ElementReporter: NSObject, WKScriptMessageHandler {
        private weak var view: HTMLPreviewView?

        init(view: HTMLPreviewView) { self.view = view }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let index = body["index"] as? Double,
                  let tags = body["tags"] as? [String]
            else { return }
            view?.readerPressed(elementAt: Int(index), tagNames: tags)
        }
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
        // The web view keeps the colour it was handed rather than resolving it
        // again, so light and dark are swapped by handing it over afresh.
        webView?.underPageBackgroundColor = .textBackgroundColor
        needsDisplay = true
    }
}

extension HTMLPreviewView {

    /// Puts a page that has just arrived where the caller asked for: at an
    /// anchor by name, or a share of the way down it. A fraction is worked
    /// out in the page rather than here, since only the page knows how tall
    /// it turned out to be at this width.
    fileprivate func land(_ landing: Landing, in webView: WKWebView, generation: Int) {
        let script: String
        switch landing {
        case .fragment(let name):
            let quoted = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            (function () {
                var target = document.getElementById("\(quoted)")
                    || document.getElementsByName("\(quoted)")[0];
                if (target) { target.scrollIntoView(true); } else { window.scrollTo(0, 0); }
            })();
            """
        case .fraction(let fraction):
            script = """
            (function () {
                var room = Math.max(
                    0, document.documentElement.scrollHeight - window.innerHeight
                );
                window.scrollTo(0, room * \(min(1, max(0, fraction))));
            })();
            """
        }
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] _ in
            guard let self, generation == self.generation else { return }
            onLoadFinished?()
        }
    }
}

// MARK: - Where a link goes

extension HTMLPreviewView: WKNavigationDelegate {

    /// What a link in the page does: stay, or leave.
    enum LinkPolicy: Equatable {
        /// Followed in the pane — an in-page `#`, and every load the pane
        /// itself asks for.
        case stays
        /// Handed to the browser and not followed here.
        case leaves
    }

    /// Whether a navigation is still this page. Only a link the reader
    /// clicked is ever in question: the loads the pane issues are its own,
    /// and a page's scripts and frames are its own business.
    ///
    /// An in-page `#` is the same document with a different anchor, so it
    /// stays. Everything else — another file, `http(s)`, `mailto` — is
    /// somewhere else, and somewhere else is the browser's, not a preview
    /// pane's: Nota is not one, and a tab that quietly became one would have
    /// no way back.
    static func policy(
        for url: URL?, navigationType: WKNavigationType, currentURL: URL?
    ) -> LinkPolicy {
        guard navigationType == .linkActivated, let url else { return .stays }
        guard url.fragment != nil, let currentURL else { return .leaves }
        return sameDocument(url, currentURL) ? .stays : .leaves
    }

    /// The same page but for the anchor on the end of it.
    private static func sameDocument(_ one: URL, _ other: URL) -> Bool {
        var left = URLComponents(url: one, resolvingAgainstBaseURL: false)
        var right = URLComponents(url: other, resolvingAgainstBaseURL: false)
        left?.fragment = nil
        right?.fragment = nil
        return left != nil && left == right
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = action.request.url
        switch Self.policy(for: url, navigationType: action.navigationType,
                           currentURL: webView.url) {
        case .stays:
            decisionHandler(.allow)
        case .leaves:
            decisionHandler(.cancel)
            // The browser is handed the link the page actually points at. A
            // relative one resolves under Nota's own scheme, which means
            // nothing outside this pane, so it goes back to being a file.
            if let url { openExternal(PageFiles.linkDestination(of: url)) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page arriving after the one that replaced it has nothing to say:
        // it is not what is on screen, and putting its scroll back would move
        // the page that is.
        let generation = generation
        // A fresh document has none of the old one's ranges, so an open bar
        // puts its query to it again — an edit in the editor beside the page
        // must not leave the reader with a count of a page that has gone.
        findSession.refresh()
        if let landing = pendingLanding {
            pendingLanding = nil
            land(landing, in: webView, generation: generation)
            return
        }
        let offset = showingNoteID.flatMap { scrollOffsets[$0] } ?? .zero
        guard offset != .zero else {
            onLoadFinished?()
            return
        }
        webView.evaluateJavaScript(
            "window.scrollTo(\(offset.x), \(offset.y));", in: nil, in: .defaultClient
        ) { [weak self] _ in
            guard let self, generation == self.generation else { return }
            onLoadFinished?()
        }
    }
}

// MARK: - The files beside the page

/// Serves the page and everything it draws from disk, under a scheme of
/// Nota's own.
///
/// The obvious way to do this is to load the editor's text against the file's
/// own `file://` URL, and it does not work. WebKit draws every page in a
/// separate, sandboxed process, and that process is handed permission to read
/// a folder only by `loadFileURL(_:allowingReadAccessTo:)` — the call that
/// loads a file rather than a string. Text loaded against a `file://` base
/// gets the origin but not the permission, so the page renders and every
/// stylesheet and picture beside it silently does not. (It appears to work
/// under a temporary folder, which that process may read anyway. That is what
/// made the first version of this look right in tests and wrong in the app.)
///
/// So the page is loaded under `nota-file://` and this hands WebKit the bytes
/// itself. The file's path is the URL's path, so everything relative in the
/// page resolves exactly as it would in a browser, and nothing depends on
/// what a sandbox will allow. Only this pane understands the scheme, so a
/// link the reader clicks is turned back into a file on the way out.
final class PageFiles: NSObject, WKURLSchemeHandler {

    /// Nota's own scheme for a local page. Not `file`, which WebKit reserves,
    /// and not a name anything else answers to.
    static let scheme = "nota-file"

    /// The URL a file is read under. Its path is the file's own, so a
    /// relative URL in the page lands on the file beside it.
    static func pageURL(_ fileURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = fileURL.standardizedFileURL.path
        return components.url
    }

    /// The file a page URL stands for, and any other URL unchanged.
    static func fileURL(_ pageURL: URL) -> URL? {
        guard pageURL.scheme == scheme else { return nil }
        return URL(fileURLWithPath: pageURL.path).standardizedFileURL
    }

    /// Where a link the reader clicked really goes. Inside the pane a
    /// relative link resolves under Nota's scheme; outside it, that scheme is
    /// meaningless, so the browser is handed the file it stands for.
    static func linkDestination(of url: URL) -> URL {
        fileURL(url) ?? url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.fileURL(url),
              let data = try? Data(contentsOf: file)
        else {
            // A picture that is not there is a broken picture, the same as it
            // would be in a browser — not an error the reader has to dismiss.
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)
        task.didReceive(URLResponse(
            url: url, mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            expectedContentLength: data.count,
            textEncodingName: type?.conforms(to: .text) == true ? "utf-8" : nil
        ))
        task.didReceive(data)
        task.didFinish()
    }

    /// Every file is read and handed over before `start` returns, so there is
    /// never a load still in flight to stop.
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { }
}

// MARK: - The page's view

/// The pane's web view.
///
/// The one thing it says that a plain `WKWebView` does not is whether it will
/// take the keyboard. In reading mode it is the only thing on screen and the
/// arrow and page keys are its own; in split and the editor mode the caret
/// belongs to the text beside it, and a click in the page — on a link, on a
/// word — must leave the caret where it was. Refusing first responder is what
/// says so; the click itself still reaches the page, because a mouse event
/// does not need the keyboard.
///
/// The exception is a field: `editableFocus` is true for as long as the page
/// holds a focused `input`, `textarea`, `select` or `contenteditable`, and a
/// page that is being typed into has to have the keys (done 2026-09-07).
/// Losing the field ends it, and losing the keyboard ends it too — the pane
/// is told, so the next click in the page is an ordinary click again.
final class HTMLPageView: WKWebView {
    var takesKeyboard = false

    /// Whether something in the page is being typed into. The one thing
    /// besides reading mode that makes this view take the keyboard: a field
    /// the reader has clicked into gets the keys, or the page is a form
    /// nobody can fill in (done 2026-09-07). Set by the pane, from the page's
    /// own `focusin` / `focusout`.
    var editableFocus = false

    /// Run when the keyboard leaves this view for something else. The pane
    /// takes the field's exception down on it, so the next click in the page
    /// is an ordinary click again.
    var onKeyboardResigned: (() -> Void)?

    /// Files let go on the page, which open as tabs the way they do anywhere
    /// else over the column.
    ///
    /// WebKit answers for a file drop itself, by loading the file — a page
    /// dropped on a page replaces it, and the tab that was being read is gone
    /// with no way back. So the drag never reaches WebKit: the types it
    /// registered for are taken off this view and only `public.file-url` is
    /// put back, and the three methods below answer without ever calling
    /// `super`. A page in the column is read, not navigated.
    var onDropFiles: (([URL]) -> Void)?

    /// The page's find bar. Find…, Find Next, Find Previous and Use Selection
    /// for Find are nil-targeted `performTextFinderAction:` items, so they
    /// land here whenever this view has the keyboard — which is reading mode,
    /// and only there. In split the editor has it and ⌘F is the editor's,
    /// which is settled by `acceptsFirstResponder` above and by nothing here.
    ///
    /// Taking the selector is also what keeps WebKit's own find bar out of a
    /// Nota window: `WKWebView` answers for it itself, and that bar is exactly
    /// what must never appear here.
    weak var findSession: HTMLFindSession?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // Everything WebKit registered for goes, and the one drag the column
        // answers for is put back in its place.
        unregisterDraggedTypes()
        registerForDraggedTypes(PreviewFileDrop.types)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { takesKeyboard || editableFocus }

    override func becomeFirstResponder() -> Bool {
        (takesKeyboard || editableFocus) && super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onKeyboardResigned?() }
        return resigned
    }

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

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession?.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return HTMLFindSession.handles(action)
    }
}


/// Whether a drawing's text is XML WebKit could draw, answered before it is
/// handed over, so a broken one gets a readable page instead of WebKit's.
enum SVGCheck {
    /// `nil` for a drawing that parses; otherwise one line saying what is
    /// wrong and where.
    static func problem(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.text("The document is empty.") }
        let parser = XMLParser(data: Data(text.utf8))
        guard !parser.parse() else { return nil }
        let code = (parser.parserError as NSError?)?.code ?? 0
        return String(
            format: L10n.text("Line %d, column %d: the drawing could not be parsed (XML error %d)."),
            parser.lineNumber, parser.columnNumber, code
        )
    }
}
