import AppKit
import WebKit

/// A page turned into paper: WebKit's own print operation, run headless, to a
/// PDF file (SPEC Todo 1).
///
/// `WKWebView.createPDF` is the obvious call and the wrong one — it renders
/// the viewport, once, as a single page of whatever size the view happens to
/// be, so a long page comes back as one enormous sheet. Printing is the only
/// path in WebKit that paginates, and it paginates the way a browser's ⌘P
/// does: the page laid out to the paper's printable width, broken at the page
/// boundaries the CSS asks for. So the operation is the printer's, with the
/// panels turned off and the job saved to a file instead of sent to a queue.
///
/// The web view has to be in a window with a real frame or WebKit prints
/// nothing at all: the print view's layout comes from the view it was made
/// from, and a view of zero size lays nothing out. The window is transparent
/// and parked far off every display, so a print never reaches the screen.
///
/// Everything here happens on the main thread — WebKit is a main-thread API —
/// and one job at a time. Two print operations in flight at once is where
/// WebKit stops being reliable: the second one comes back empty, or not at
/// all. So jobs queue, and the queue is the whole of the concurrency story.
enum WebPDF {

    // MARK: - What can go wrong

    /// Every way a print can fail, in the reader's own language. There is
    /// nothing to retry and nothing to fix in the file, so each one is a
    /// sentence rather than a code.
    enum Failure: LocalizedError {
        /// The page never finished loading — a script that does not return,
        /// a subresource that never arrives.
        case timedOut
        /// WebKit refused the page itself: a file that is not there, an XHTML
        /// document that will not parse.
        case couldNotLoad
        /// The load was fine and the print was not, or it wrote no file.
        case couldNotPrint

        var errorDescription: String? {
            switch self {
            case .timedOut: L10n.text("The page took too long to print.")
            case .couldNotLoad: L10n.text("The page could not be opened.")
            case .couldNotPrint: L10n.text("The page could not be printed.")
            }
        }
    }

    // MARK: - Paper

    /// How long a page gets before it is given up on. A minute is long past
    /// the point where a page that is going to load has loaded; it is there
    /// so a page that never will fails with a sentence rather than hanging
    /// the app. The tests hand in their own, which is the only reason it is
    /// an argument at all.
    static let defaultTimeout: TimeInterval = 60

    /// The margin a printed page keeps on every side.
    ///
    /// The render's own inset is 20pt (`EditorPaddingOption.normal`), which is
    /// the right air between a column of text and the edge of a window and far
    /// too little between it and the edge of a sheet — half an inch is what a
    /// printer can actually reach, and what every other document on the desk
    /// has. So it is the render's inset rounded out to that.
    static let margin: CGFloat = 36

    /// The paper this Mac prints on — Letter or A4, whichever the region
    /// says — with Nota's margins on it and the job pointed at a file rather
    /// than a printer.
    ///
    /// A copy, never `NSPrintInfo.shared` itself: the shared one belongs to
    /// the app and to whatever the reader prints next.
    static func printInfo(savingTo url: URL) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = .portrait
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        // Saved, not printed: the disposition says where the job goes and the
        // URL says which file, and between them no printer is ever asked for.
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        return info
    }

    /// The rectangle a page is laid out in: the sheet less its margins. The
    /// web view is made this wide, so the page wraps to the paper rather than
    /// to a window nobody can see.
    static func printableRect(of info: NSPrintInfo) -> NSRect {
        NSRect(
            x: 0, y: 0,
            width: max(1, info.paperSize.width - info.leftMargin - info.rightMargin),
            height: max(1, info.paperSize.height - info.topMargin - info.bottomMargin)
        )
    }

    // MARK: - Printing one

    /// Prints the file at `fileURL` — an `.html` page, an EPUB chapter — to a
    /// PDF at `url`.
    ///
    /// The file is loaded under `nota-file://` through the same
    /// `PageFiles` handler the preview column uses, so a stylesheet, a font
    /// and a picture beside it resolve exactly as they do on screen. A
    /// `file://` base URL would not: WebKit's page process is given
    /// permission to read a folder only by `loadFileURL`, and everything
    /// relative in the page would silently go missing.
    ///
    /// The print is always the light page. A book is *read* in Nota's dark
    /// (see `HTMLPreviewView.readerThemeCSS`), but paper has no appearance to
    /// follow, and white type on a black sheet is not what anybody exporting
    /// a book asked for. So the window and the view are pinned to Aqua and
    /// the reader theme is not injected here at all.
    static func export(
        pageAt fileURL: URL, to url: URL, timeout: TimeInterval = defaultTimeout,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let pageURL = PageFiles.pageURL(fileURL) else {
            completion(.failure(Failure.couldNotLoad))
            return
        }
        enqueue(PrintJob(source: .page(pageURL), destination: url,
                         limit: timeout, completion: completion))
    }

    /// The same, for a page held as text rather than read off the disk — an
    /// `.html` tab with edits in it, which is the page the reader is looking
    /// at and the one they mean by "export this".
    ///
    /// `baseURL` is the file the text belongs to, so its own stylesheet and
    /// pictures resolve; `nil` for a page that stands alone.
    static func export(
        html: String, baseURL: URL?, to url: URL, timeout: TimeInterval = defaultTimeout,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        enqueue(PrintJob(source: .html(html, baseURL.flatMap(PageFiles.pageURL)),
                         destination: url, limit: timeout, completion: completion))
    }

    /// Prints a web view that already holds the page — the one on screen.
    ///
    /// Its appearance, its zoom and whatever its scripts have done to the DOM
    /// are the caller's: this prints what is there. It is not moved into a
    /// window of ours either, since it is already in one; a view with no
    /// window and no size prints nothing, and that is `couldNotPrint`.
    static func export(
        page webView: WKWebView, to url: URL, timeout: TimeInterval = defaultTimeout,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        enqueue(PrintJob(source: .loaded(webView), destination: url,
                         limit: timeout, completion: completion))
    }

    // MARK: - One at a time

    /// Jobs waiting their turn, and the one having it. WebKit's printing is
    /// not something to run two of at once, and a book is a queue of chapters
    /// by its nature — so there is one line, and it is this.
    private static var waiting: [PrintJob] = []
    private static var running: PrintJob?

    private static func enqueue(_ job: PrintJob) {
        // Every step of a job is WebKit's, so the whole of it belongs on the
        // main thread whatever thread asked for it.
        if Thread.isMainThread {
            waiting.append(job)
            startNextIfIdle()
        } else {
            DispatchQueue.main.async {
                waiting.append(job)
                startNextIfIdle()
            }
        }
    }

    private static func startNextIfIdle() {
        guard running == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        running = job
        job.start { result in
            running = nil
            job.report(result)
            // The next one after this one's caller has been told, and through
            // the run loop rather than down the stack: a book of two hundred
            // chapters must not print itself in one recursion.
            DispatchQueue.main.async { startNextIfIdle() }
        }
    }
}

// MARK: - The job

/// One page, loaded and printed. Lives only as long as its print does — the
/// queue holds it, since a navigation delegate is weak and nothing else would.
private final class PrintJob: NSObject, WKNavigationDelegate {

    enum Source {
        /// A file, read through `PageFiles` under Nota's own scheme.
        case page(URL)
        /// Text, with the page URL it resolves against.
        case html(String, URL?)
        /// A view that already holds the page.
        case loaded(WKWebView)
    }

    private let source: Source
    private let destination: URL
    private let limit: TimeInterval
    private let completion: (Result<Void, Error>) -> Void

    /// Ours when we made one, so it is closed on the way out. `nil` when the
    /// caller handed over a view that was already in a window.
    private var window: NSWindow?
    private var webView: WKWebView?
    private var finished = false
    private var timeout: DispatchWorkItem?
    /// Told to the queue rather than to the caller, so the next job starts
    /// before anybody's completion handler runs.
    private var done: ((Result<Void, Error>) -> Void)?

    init(source: Source, destination: URL, limit: TimeInterval,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.source = source
        self.destination = destination
        self.limit = limit
        self.completion = completion
    }

    func report(_ result: Result<Void, Error>) {
        completion(result)
    }

    // MARK: - Loading

    func start(_ done: @escaping (Result<Void, Error>) -> Void) {
        self.done = done

        let clock = DispatchWorkItem { [weak self] in self?.finish(.failure(WebPDF.Failure.timedOut)) }
        timeout = clock
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: clock)

        switch source {
        case .loaded(let view):
            webView = view
            // Already the page; nothing to wait for but the print itself.
            printPage()
        case .page(let url):
            let view = makeWebView()
            view.load(URLRequest(url: url))
        case .html(let text, let base):
            let view = makeWebView()
            view.loadHTMLString(text, baseURL: base)
        }
    }

    /// A web view of our own, in a window of our own, at the width of the
    /// paper it is going to be printed on.
    private func makeWebView() -> WKWebView {
        let info = WebPDF.printInfo(savingTo: destination)
        let frame = WebPDF.printableRect(of: info)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PageFiles(), forURLScheme: PageFiles.scheme)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        // Paper is light, whatever the Mac is set to. `prefers-color-scheme`
        // in the page follows the view's appearance, so this is what keeps a
        // book's dark stylesheet — or Nota's own reader theme, which is not
        // injected here — off the printed sheet.
        view.appearance = NSAppearance(named: .aqua)

        let host = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        host.appearance = NSAppearance(named: .aqua)
        host.contentView = view
        // Two belts, the same pair the test suite's offscreen window uses: a
        // frame well outside every display and no opacity at all. The window
        // has to be ordered in — WebKit lays out and paints for a window that
        // is on screen — and `orderBack` is the way in that disturbs nothing
        // the reader is looking at.
        host.alphaValue = 0
        host.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.orderBack(nil)

        window = host
        webView = view
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // `didFinish` is the main resource, not the page: pictures and fonts
        // are still arriving. So the document is asked when it is ready, and
        // then given a moment to draw what it has.
        waitForReadyState()
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        finish(.failure(WebPDF.Failure.couldNotLoad))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(WebPDF.Failure.couldNotLoad))
    }

    /// Polls `document.readyState` until the page says `complete`. The
    /// timeout is what ends this if it never does — a page that blocks the
    /// main thread of its own process answers nothing at all, and there is no
    /// callback for that.
    private func waitForReadyState() {
        guard !finished, let webView else { return }
        webView.evaluateJavaScript("document.readyState") { [weak self] value, _ in
            guard let self, !self.finished else { return }
            if (value as? String) == "complete" {
                self.settleThenPrint()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.waitForReadyState()
                }
            }
        }
    }

    /// A short breath after `complete` for the pictures that decode after the
    /// document is done and for the fonts the page swapped in. There is no
    /// event that says "everything is drawn"; a tenth of a second is what the
    /// difference between a picture and a grey box costs.
    private func settleThenPrint() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.printPage()
        }
    }

    // MARK: - Printing

    private func printPage() {
        guard !finished, let webView, let window = webView.window else {
            finish(.failure(WebPDF.Failure.couldNotPrint))
            return
        }
        let info = WebPDF.printInfo(savingTo: destination)
        let frame = WebPDF.printableRect(of: info)

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // The print view's frame is the width the page is laid out to, and
        // the height of one sheet's worth of it; the operation breaks the
        // document across as many of those as it takes.
        operation.view?.frame = frame

        // The modal form is the one with a callback. With both panels off
        // there is no sheet to show, so nothing is put in front of anybody —
        // it is only how the operation says it has finished.
        operation.runModal(
            for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        // A job that reported success and wrote nothing is a failure: the
        // file is the whole of what was asked for.
        let wrote = FileManager.default.fileExists(atPath: destination.path)
        finish(success && wrote ? .success(()) : .failure(WebPDF.Failure.couldNotPrint))
    }

    // MARK: - Ending

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil

        // The window and the view go, so the pair of processes behind the web
        // view go with them: a page that timed out is a page still spinning,
        // and letting go of the view is what ends it.
        //
        // On the next turn of the run loop rather than here. This is called
        // from inside the print operation's own callback, and taking a view
        // out of its window while WebKit is still unwinding through it is
        // where WebKit stops being reassuring. The view hierarchy is never
        // taken apart by hand either — the window is let go whole, and the
        // view goes with it.
        if let window, let webView {
            webView.navigationDelegate = nil
            DispatchQueue.main.async {
                webView.stopLoading()
                window.orderOut(nil)
            }
        }
        // A view the caller handed over is theirs and is only let go of, never
        // taken apart: there is no window of ours to close around it.
        window = nil
        webView = nil

        let done = self.done
        self.done = nil
        done?(result)
    }
}
