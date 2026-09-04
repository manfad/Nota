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

    private let pdfView = PDFView()
    /// Shown instead of the document when the file has gone — deleted while
    /// the tab was open, or missing by the time the session comes back.
    private let missingLabel = NSTextField(labelWithString: "")

    /// Run when the reader moves to another page, with its 0-based index.
    var onPositionChange: ((Int) -> Void)?
    /// The page the pane was last told to be on. A document that would not
    /// open has no page to be asked for, and reporting the first one would
    /// send a tab whose file has gone back to the top of a PDF that is not
    /// there; it is left where the session remembers instead.
    private var installedPage = 0
    /// True while a document or a page is being put in by hand, so the
    /// notification that follows is not read back as the reader turning a
    /// page — restoring page 4 must not be the same thing as leaving page 4.
    private var isInstalling = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Pinned edge to edge, unlike the Markdown render's own margins.
        // PDFView scales and centres each page inside the room it is given,
        // so an inset would not be a margin around the text — it would be a
        // second margin outside the page's own, with the paper shrinking to
        // pay for it.
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(pageDidChange),
            name: .PDFViewPageChanged, object: pdfView
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
        if pdfView.document !== document { pdfView.document = document }
        pdfView.isHidden = document == nil
        missingLabel.isHidden = document != nil
        guard document == nil else { return }
        missingLabel.font = Preferences.shared.font()
        missingLabel.stringValue = missingName.map { "Couldn’t open “\($0)”." } ?? ""
    }

    /// How many pages there are, and none at all when there is no document.
    var pageCount: Int { pdfView.document?.pageCount ?? 0 }

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
