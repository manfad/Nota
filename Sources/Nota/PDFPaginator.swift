import AppKit
import PDFKit

/// Text and pictures onto pages, and the pages into a PDF file.
///
/// The one place in Nota that makes a PDF. Everything the export offers —
/// a render, a rich-text document, the editor's own listing, a picture on a
/// page of its own — arrives here as an attributed string, a list of plates,
/// or both, and leaves as a file. Nothing here knows which of them it was
/// handed: `Export.swift` decides what goes on the page, this decides where
/// the page ends.
///
/// The pagination is `NSPrintOperation`'s, run silently — no print panel, no
/// progress panel — with `jobDisposition = .save` and the destination in
/// `jobSavingURL`, which is how AppKit writes a print job to a file. A text
/// view laid out at the page's measure hands the operation its own page
/// breaks, so a paragraph that runs off the bottom of a page continues at the
/// top of the next one exactly as it would on paper.
///
/// The plates are drawn by hand instead (`PlatesView`), one to a page, since
/// "one picture per page" is not something a flowing text view can be asked
/// for. Both halves are printed separately and joined with PDFKit, which is
/// also what counts the pages afterwards: a job that produced none is a
/// failure the window says something about rather than a file nobody can
/// open.
///
/// The whole run is made under the light appearance. A window in dark mode
/// would otherwise print white text on a page whose background nothing draws,
/// so the dynamic colours in the text are resolved to their light values
/// first (`lightened`) and every attachment that draws itself — a chip, a
/// formula, a diagram — draws inside `performAsCurrentDrawingAppearance`.
enum PDFPaginator {

    /// One picture on a page of its own, with the line under it that says
    /// which picture it is. A picture tab's export is a single plate with
    /// nothing written under it.
    struct Plate {
        let image: NSImage
        let caption: NSAttributedString?

        init(image: NSImage, caption: NSAttributedString? = nil) {
            self.image = image
            self.caption = caption
        }
    }

    enum Failure: Error {
        /// Nothing was handed in: no text and no plates.
        case nothingToDraw
        /// The print job ran but left no readable PDF behind it.
        case noPages
    }

    // MARK: - The page

    /// The paper the Mac is set up for — Letter in the United States, A4
    /// almost everywhere else. Taken from `NSPrintInfo.shared`, which already
    /// holds the answer the system worked out from the locale, so Nota has no
    /// paper setting of its own to keep.
    static var paperSize: NSSize { NSPrintInfo.shared.paperSize }

    /// The margins a page keeps. The render's own inset is what the exported
    /// column should read at (`RenderStyle.previewHorizontalInset`, 20 across
    /// and 14 down), but a page is not a pane: half an inch is where a
    /// printer's unprintable edge starts eating the text, so neither margin
    /// goes under it.
    static let horizontalMargin = max(RenderStyle.previewHorizontalInset, 36)
    static let verticalMargin = max(RenderStyle.previewVerticalInset, 36)

    /// The measure a render or a listing is laid out to, and the height one
    /// page of it has room for.
    static var contentWidth: CGFloat { paperSize.width - horizontalMargin * 2 }
    static var contentHeight: CGFloat { paperSize.height - verticalMargin * 2 }

    // MARK: - Writing

    /// Text, then plates, into one PDF at `url`.
    ///
    /// Either half may be empty — a note with no pictures is text alone, a
    /// picture tab is one plate alone — but not both.
    static func write(
        text: NSAttributedString, plates: [Plate] = [], to url: URL
    ) throws {
        guard text.length > 0 || !plates.isEmpty else { throw Failure.nothingToDraw }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var parts: [URL] = []
        try light {
            if text.length > 0 {
                let part = scratch.appendingPathComponent("text.pdf")
                try printText(text, to: part)
                parts.append(part)
            }
            if !plates.isEmpty {
                let part = scratch.appendingPathComponent("plates.pdf")
                try printPlates(plates, to: part)
                parts.append(part)
            }
        }
        try join(parts, into: url)
    }

    /// The two halves as one document. One part is moved into place as it
    /// stands; two are read back through PDFKit and written out together,
    /// which is also the check that either half produced anything at all.
    private static func join(_ parts: [URL], into url: URL) throws {
        guard !parts.isEmpty else { throw Failure.noPages }
        try? FileManager.default.removeItem(at: url)

        if parts.count == 1 {
            guard (PDFDocument(url: parts[0])?.pageCount ?? 0) > 0 else {
                throw Failure.noPages
            }
            try FileManager.default.moveItem(at: parts[0], to: url)
            return
        }

        let whole = PDFDocument()
        for part in parts {
            guard let document = PDFDocument(url: part) else { continue }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                whole.insert(page, at: whole.pageCount)
            }
        }
        guard whole.pageCount > 0, whole.write(to: url) else { throw Failure.noPages }
    }

    // MARK: - Text

    /// The flowing half: a text view at the page's measure, printed.
    private static func printText(_ text: NSAttributedString, to url: URL) throws {
        let info = printInfo(savingTo: url)
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = makeTextView(lightened(text), width: width)
        try run(NSPrintOperation(view: view, printInfo: info))
    }

    /// The view the operation paginates. It is never in a window and never on
    /// screen: it exists to be laid out at the page's width and asked for its
    /// height, which is what tells the print system how many pages there are.
    private static func makeTextView(
        _ text: NSAttributedString, width: CGFloat
    ) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        view.textContainerInset = .zero
        // A text view is born with its frame as its floor, and a floor a page
        // tall is a blank second page for every note that does not fill one.
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // The page's margin is the margin. A container that kept its own
        // padding on top of it would print at a measure nobody chose.
        view.textContainer?.lineFragmentPadding = RenderStyle.lineFragmentPadding
        view.textContainer?.containerSize = NSSize(
            width: width, height: .greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        // The page is white already; a text view drawing its own background
        // would lay a second one over it, in whatever colour the app is in.
        view.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
        }
        view.sizeToFit()
        return view
    }

    // MARK: - Plates

    /// The hand-drawn half: one picture per page, fitted inside the margins,
    /// with its caption under it.
    private static func printPlates(_ plates: [Plate], to url: URL) throws {
        let info = printInfo(savingTo: url)
        let size = NSSize(
            width: info.paperSize.width - info.leftMargin - info.rightMargin,
            height: info.paperSize.height - info.topMargin - info.bottomMargin
        )
        let view = PlatesView(plates: plates, pageSize: size)
        try run(NSPrintOperation(view: view, printInfo: info))
    }

    /// The plates, stacked one page-height apart, each drawn into its own
    /// page rect. `knowsPageRange` is what makes the break exact: the print
    /// system asks for the pages rather than working them out from the view's
    /// height, so a short picture cannot pull the next one up beside it.
    private final class PlatesView: NSView {
        private let plates: [Plate]
        private let pageSize: NSSize
        /// The air between a picture and the line naming it.
        private static let captionGap: CGFloat = 12

        init(plates: [Plate], pageSize: NSSize) {
            self.plates = plates
            self.pageSize = pageSize
            super.init(frame: NSRect(
                origin: .zero,
                size: NSSize(
                    width: pageSize.width,
                    height: pageSize.height * CGFloat(max(1, plates.count))
                )
            ))
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// Pages are counted from the top, so the view draws the way it
        /// paginates.
        override var isFlipped: Bool { true }

        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            range.pointee = NSRange(location: 1, length: plates.count)
            return true
        }

        override func rectForPage(_ page: Int) -> NSRect {
            NSRect(
                x: 0, y: CGFloat(page - 1) * pageSize.height,
                width: pageSize.width, height: pageSize.height
            )
        }

        override func draw(_ dirtyRect: NSRect) {
            for (index, plate) in plates.enumerated() {
                let page = rectForPage(index + 1)
                guard page.intersects(dirtyRect) else { continue }
                draw(plate, in: page)
            }
        }

        private func draw(_ plate: Plate, in page: NSRect) {
            var box = page
            if let caption = plate.caption {
                let height = ceil(caption.boundingRect(
                    with: NSSize(width: page.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height)
                box.size.height -= height + Self.captionGap
                let line = NSRect(
                    x: page.minX, y: box.maxY + Self.captionGap,
                    width: page.width, height: height
                )
                caption.draw(with: line, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            let fitted = ImageFitting.aspectFit(plate.image.size, in: box)
            plate.image.draw(in: fitted)
        }
    }

    // MARK: - The print job

    /// A job that writes rather than prints: no panels, no printer, and the
    /// file it lands in named in the print info itself.
    static func printInfo(savingTo url: URL) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.leftMargin = horizontalMargin
        info.rightMargin = horizontalMargin
        info.topMargin = verticalMargin
        info.bottomMargin = verticalMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    static func run(_ operation: NSPrintOperation) throws {
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw Failure.noPages }
    }

    // MARK: - Light

    /// Runs `body` with the light appearance current, so everything that
    /// resolves a colour while it runs — a chip's fill, a formula's ink, a
    /// picture drawn by a handler — resolves it for paper.
    static func light(_ body: () throws -> Void) throws {
        guard let aqua = NSAppearance(named: .aqua) else { return try body() }
        var thrown: Error?
        aqua.performAsCurrentDrawingAppearance {
            do { try body() } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    /// The same text with its dynamic colours pinned to their light values.
    /// `labelColor` in a dark window is very nearly white, and a page has no
    /// background to read it against; resolved here, once, it is the black
    /// the reader sees in a light window.
    ///
    /// Called from inside `light`, so "resolved" means resolved for paper.
    static func lightened(_ text: NSAttributedString) -> NSAttributedString {
        let keys: [NSAttributedString.Key] = [
            .foregroundColor, .backgroundColor, .underlineColor, .strikethroughColor,
        ]
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        for key in keys {
            result.enumerateAttribute(key, in: whole) { value, range, _ in
                guard let colour = value as? NSColor,
                      let resolved = colour.usingColorSpace(.sRGB)
                else { return }
                result.addAttribute(key, value: resolved, range: range)
            }
        }
        return result
    }
}
