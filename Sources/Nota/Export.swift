import AppKit

/// What the tab in front can be exported to — SPEC "## Export", Todo 1.
///
/// A target is a *shape*, not a file type: `.previewPDF` is "what the reader
/// is looking at, on pages", `.editorPDF` is "the source, as the editor has
/// it", and the two PNGs are those same two on the screen rather than on
/// paper. Which of them a tab offers is `Exporter.targets(for:)`, and the
/// sheet lists them in that order with the first one selected.
enum ExportTarget: String, CaseIterable {
    /// The render, the document or the picture as the tab shows it.
    case previewPDF
    /// The source listing: the editor's own text, gutter and all.
    case editorPDF
    /// A book laid out as pages.
    case bookPDF
    /// A document taken apart into a book.
    case epub
    /// A `.tex` through a real TeX engine, rather than through Nota's own
    /// reading of it.
    case texPDF
    /// The render as the screen has it, in one tall picture.
    case previewPNG
    /// The source listing as the screen has it, in one tall picture.
    case editorPNG

    /// The word the popup wears — also the `L10n` key it is looked up under,
    /// so the sheet and the tables can never drift apart.
    var titleKey: String {
        switch self {
        case .previewPDF: "Preview as PDF"
        case .editorPDF: "Editor as PDF"
        case .bookPDF: "Book as PDF"
        case .epub: "Book (EPUB)"
        case .texPDF: "PDF through TeX"
        case .previewPNG: "PNG of the preview"
        case .editorPNG: "PNG of the editor"
        }
    }

    var title: String { L10n.text(titleKey) }

    /// What the written file is called, once the reader has named it: the
    /// extension the save dialog opens on and cannot be talked out of.
    var fileExtension: String {
        switch self {
        case .previewPDF, .editorPDF, .bookPDF, .texPDF: "pdf"
        case .epub: "epub"
        case .previewPNG, .editorPNG: "png"
        }
    }
}

/// Where an exported listing's pictures go. A note's chips are a picture each
/// and a page is not a scroll, so the reader is asked: in the text where they
/// were written, or gathered at the end where a paper puts its figures.
enum ExportImagePlacement: String, CaseIterable {
    case inline, plates

    var titleKey: String {
        switch self {
        case .inline: "Inline"
        case .plates: "End"
        }
    }

    var title: String { L10n.text(titleKey) }
}

/// Making the file the reader asked for.
///
/// The one seam every export goes through. What each target *is* is decided
/// here; how a page ends is `PDFPaginator`'s, how a picture is drawn is
/// `SnapshotPNG`'s; the sheet and the save dialog are the window's. Three of
/// the seven targets are somebody else's work — a book onto pages, a
/// document into a book, a `.tex` through a TeX engine — so each of those is
/// a hook standing empty until it is plugged in, and a target whose hook is
/// empty is not offered at all.
///
/// A grid's rows as CSV is not among them: that is the `Export CSV` button on
/// the pane itself, which asks which columns are going out — a question this
/// sheet has no row for (`CSVExportDialog`).
enum Exporter {

    /// What the window knows and the export needs: the editor's font and
    /// paragraph shape, the asset store behind the chips, whether the gutter
    /// is on, and where this export's pictures go.
    struct Context {
        var font: NSFont
        var paragraphStyle: NSParagraphStyle
        var assets: AssetStore?
        var showsLineNumbers: Bool
        var images: ExportImagePlacement
        /// The measure a render is laid out to. The page's, unless a test
        /// asks for another.
        var width: CGFloat = PDFPaginator.contentWidth
        /// The measure the *screen* is reading at, for the one export that is
        /// a photograph of it rather than a page: the preview column's own
        /// content width for a render, the editor's text width for a listing.
        /// The window fills it in; `nil` in a test, where the picture is
        /// taken at `width` like everything else.
        var screenWidth: CGFloat?
        /// What a picture is laid out to: the screen's measure where the
        /// window said what it was, the page's otherwise.
        var pictureWidth: CGFloat { screenWidth ?? width }
        /// What a picture's colours resolve under. The window the export was
        /// started from, so a reader in dark mode gets the dark page they are
        /// looking at, and the app's own appearance where there is no window
        /// — a test, a `nil` `NSApp`.
        var pictureAppearance: NSAppearance? {
            window?.effectiveAppearance ?? NSApp?.effectiveAppearance
        }
        /// The view this tab is being read through, where there is one. The
        /// two PDFs Nota writes itself never look at it — a render is made
        /// from the note, not read off the screen — but an exporter that
        /// writes out *what a pane is showing* has nowhere else to get it:
        /// a dump's rows are the query the reader typed and the sort they
        /// clicked, and neither is on the note. Handed in by the window, so
        /// with two windows open each export is that window's own.
        var previewContent: (any PreviewContent)?
        /// The window the export was started from, for an exporter that has
        /// a question to ask before it can work — the only one today is the
        /// TeX export, whose install prompt is a sheet on this window. `nil`
        /// in a test, where the prompt is a fake and no sheet is raised.
        var window: NSWindow?
        /// What a long export says while it is running: a book's chapters
        /// going by, a download's megabytes, "Typesetting…". The window puts
        /// each line in the footer and clears it when the export finishes.
        /// Called on the main thread. The two PDFs Nota writes itself never
        /// say anything — they are done before a footer could be read.
        var progress: (String) -> Void = { _ in }
    }

    /// Equatable so a test — and the window, which has one of them to tell
    /// apart from the rest — can name the failure rather than match on its
    /// text.
    enum Failure: Error, Equatable {
        /// The target's own exporter has not been plugged in. Not something a
        /// reader can reach — a target with no hook is never listed — but the
        /// switch has to answer for it.
        case noExporter(ExportTarget)
        /// The tab had nothing this target could be made from: an unreadable
        /// picture, a document that would not parse.
        case nothingToExport
        /// The note is taller than any one picture may be
        /// (`SnapshotPNG.maximumHeight`). The two PDFs would have paginated
        /// it; a PNG has nowhere to break, so the export says so rather than
        /// writing a file nothing can open.
        case tooLongForAnImage
    }

    // MARK: - The hooks

    /// What an exporter written elsewhere looks like from here: the tab, the
    /// file to write, and everything the window knows about how the tab is
    /// being read — including the pane in front of it, for an exporter whose
    /// answer is on screen rather than in the note.
    ///
    /// Asynchronous, because three of them are: a page and a book go
    /// through WebKit, and a `.tex` may have a download and a prompt in front
    /// of it. None of them can be waited on with a semaphore either — WebKit
    /// wants the main run loop, and a semaphore held on the main thread is
    /// exactly the deadlock that would take it away. So the seam is a
    /// completion the whole way down, and the two PDFs Nota writes itself
    /// call it before they return.
    ///
    /// The completion arrives on the main thread.
    typealias Hook = (Note, URL, Context, @escaping (Result<Void, Error>) -> Void) -> Void

    /// A book onto pages. `EPUBBook` already has the chapters; laying them
    /// out is the other half.
    static var bookPDF: Hook?

    /// A document into a book — the way back from `.pdf` to `.epub`.
    static var pdfToEPUB: Hook?

    /// A `.tex` typeset by whichever engine is installed. With none, the tab
    /// still exports through Nota's own render, which is `.previewPDF`.
    static var texPDF: Hook?

    /// An `.html` tab's page as WebKit draws it. Without it, the page exports
    /// as the source listing it is in the editor.
    static var htmlPagePDF: Hook?

    /// A `.sql` or `.csv` tab's grid on pages: the table itself, ruled,
    /// rather than the source that spells it out. It is handed the pane
    /// along with the note, since what the grid is showing — the query in the
    /// box, the
    /// column a header click sorted by — lives there and nowhere else.
    /// Without it, and without a pane to read, a grid exports as the source
    /// listing it is in the editor.
    static var tablePDF: Hook?

    /// The hook a target waits on, or `nil` for the two that are written
    /// here and always available.
    static func hook(for target: ExportTarget) -> Hook? {
        switch target {
        case .previewPDF, .editorPDF, .previewPNG, .editorPNG: nil
        case .bookPDF: bookPDF
        case .epub: pdfToEPUB
        case .texPDF: texPDF
        }
    }

    /// Whether the sheet lists this target at all. The two PDFs and the two
    /// pictures Nota writes itself always; every other target only once
    /// somebody has plugged its exporter in.
    private static func isAvailable(_ target: ExportTarget) -> Bool {
        switch target {
        case .previewPDF, .editorPDF, .previewPNG, .editorPNG: true
        default: hook(for: target) != nil
        }
    }

    // MARK: - What a tab offers

    /// The targets this tab can be exported to, in the order the sheet lists
    /// them — what the reader is looking at first, the source after it, the
    /// same two as pictures, and the tab's own speciality last.
    static func targets(for note: Note) -> [ExportTarget] {
        var targets: [ExportTarget]
        switch note.kind {
        case .text:
            // Every text tab has both: a render, a page, a tree or a table to
            // look at, and the source it was all written in. A tab with no
            // preview of its own — a `.txt`, an untitled note — reads the
            // same listing twice over, which is the honest answer: there is
            // nothing else to show.
            targets = [.previewPDF, .editorPDF]
            // The pictures after the pages. Every text tab can be
            // photographed as its editor; only a tab that draws a render of
            // its own has a preview worth a picture — a page, a grid and a
            // tree are drawn by views the snapshot cannot lay out, and their
            // "preview" here would only be the listing again.
            if snapshotsRender(note) { targets.append(.previewPNG) }
            targets.append(.editorPNG)
            switch note.previewKind {
            case .latex: targets.append(.texPDF)
            default: break
            }
        case .rtf:
            // The document as the viewer shows it, on a page and as a
            // picture. It has no source to list.
            targets = [.previewPDF, .previewPNG]
        case .image:
            // The picture on a page. It is a picture already, so there is
            // nothing to photograph and nothing to list.
            targets = [.previewPDF]
        case .epub:
            targets = [.bookPDF]
        case .pdf:
            // The one export that is not a PDF: a document already is one.
            targets = [.epub]
        case .word, .presentation:
            // The pages the tab shows, through the page exporter.
            targets = note.printedDocument == nil ? [] : [.previewPDF]
        case .spreadsheet:
            // The sheet in front, as the grid, through the table exporter.
            targets = [.previewPDF]
        case .video:
            targets = []
        }
        return targets.filter(isAvailable)
    }

    /// Whether this tab's preview is a render Nota lays out itself — the two
    /// grammars it renders and the rich text it reads — rather than a view
    /// somebody else draws.
    ///
    /// The one question `.previewPNG` turns on, asked in two places: here, to
    /// decide whether the target is offered, and by the window, to decide
    /// which column's width the picture is taken at.
    static func snapshotsRender(_ note: Note) -> Bool {
        switch note.kind {
        case .rtf: true
        case .text: note.previewKind == .markdown || note.previewKind == .latex
        case .image, .pdf, .epub, .word, .spreadsheet, .presentation, .video: false
        }
    }

    // MARK: - Making the file

    /// Writes `target` for `note` into `url` and answers on the main thread.
    ///
    /// One shape for all seven, however long each takes: the four Nota writes
    /// itself — two PDFs and two pictures — answer before the call returns,
    /// and the three that are hooks answer whenever their own work is done.
    static func export(
        _ note: Note, to target: ExportTarget, at url: URL, context: Context,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch target {
        case .previewPDF: writePreviewPDF(note, to: url, context: context, completion: completion)
        case .editorPDF: completion(Result { try writeListingPDF(note, to: url, context: context) })
        case .previewPNG: completion(Result { try writePreviewPNG(note, to: url, context: context) })
        case .editorPNG: completion(Result { try writeListingPNG(note, to: url, context: context) })
        case .bookPDF, .epub, .texPDF:
            guard let hook = hook(for: target) else {
                completion(.failure(Failure.noExporter(target)))
                return
            }
            hook(note, url, context, completion)
        }
    }

    /// The reader's own view of the tab, on pages.
    ///
    /// One case of it is asynchronous — an `.html` tab with the page exporter
    /// plugged in goes through WebKit — so the whole of it answers through a
    /// completion, and everything else answers before the call returns.
    private static func writePreviewPDF(
        _ note: Note, to url: URL, context: Context,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // The page as WebKit draws it where that exporter is plugged in; the
        // source listing where it is not, which is what the tab's other half
        // shows anyway.
        if note.kind == .text && note.previewKind == .html || note.printedDocument != nil,
           let hook = htmlPagePDF {
            hook(note, url, context, completion)
            return
        }
        // A grid as the grid, where the table exporter is plugged in and
        // there is a pane to read the rows off. Without one — a test with no
        // window, an exporter taken out — the source listing stands in.
        //
        // A pane in front of the tab is not the same as a pane that has read
        // it: both grids' `show` returns without reading while the preview
        // column is hidden, and a big file is not read until the button asks
        // for it, so a tab exported or printed from editor mode has a pane
        // with no table behind it. That answers `nothingToExport`, and the
        // listing stands in for it exactly as it does for a tab with no pane
        // at all — SPEC "## Export" promises the listing, not a failure.
        if note.kind == .spreadsheet
            || note.kind == .text && (note.previewKind == .sql || note.previewKind == .csv),
           let hook = tablePDF, context.previewContent != nil {
            hook(note, url, context) { result in
                guard case let .failure(error) = result, isNothingToExport(error) else {
                    completion(result)
                    return
                }
                completion(Result { try writeListingPDF(note, to: url, context: context) })
            }
            return
        }
        completion(Result { try writePreviewPDFSynchronously(note, to: url, context: context) })
    }

    /// Whether an exporter's failure means "there was nothing on screen to
    /// export", which is the one failure the listing stands in for. Both
    /// spellings of it: the grids' own (`CSVExportError`) and the one this
    /// file raises when there is no pane at all.
    private static func isNothingToExport(_ error: Error) -> Bool {
        switch error {
        case CSVExportError.nothingToExport, Failure.nothingToExport: true
        default: false
        }
    }

    private static func writePreviewPDFSynchronously(
        _ note: Note, to url: URL, context: Context
    ) throws {
        switch note.kind {
        case .image:
            // One page, the picture fitted inside the margins and nothing
            // written under it: a picture tab is the picture.
            guard let image = note.image else { throw Failure.nothingToExport }
            try PDFPaginator.write(
                text: NSAttributedString(), plates: [PDFPaginator.Plate(image: image)], to: url
            )
        case .rtf:
            guard let rich = note.richText else { throw Failure.nothingToExport }
            try PDFPaginator.write(text: rich, to: url)
        case .word, .spreadsheet, .presentation, .video:
            throw Failure.nothingToExport
        case .text:
            switch note.previewKind {
            case .markdown:
                // The render places its own pictures, so `.inline` is simply
                // the render. Asked for plates, the note's pictures come out
                // of the text the same way the listing's do — the tag stays
                // on the line, the picture goes to the back.
                let render = NSMutableAttributedString(attributedString: MarkdownRenderer.render(
                    note.text, font: context.font,
                    assets: context.assets, width: context.width
                ).text)
                let plates = context.images == .plates
                    ? gatherPlates(in: render, of: note, context: context)
                    : []
                try PDFPaginator.write(text: render, plates: plates, to: url)
            case .latex:
                try PDFPaginator.write(
                    text: LaTeXRenderer.render(
                        note.text, font: context.font,
                        baseURL: note.fileURL, width: context.width
                    ).text,
                    to: url
                )
            case .html:
                // Only reached with no page exporter plugged in — the hook
                // was taken above — so the source listing stands in.
                try writeListingPDF(note, to: url, context: context)
            default:
                // A tree and a drawing print badly as what they are, and the
                // beautified source is the thing the reader agreed to. So the
                // listing stands in, for those and for plain text — and for a
                // grid with no pane to read, since a grid drawn onto pages is
                // the table on screen and there is no table without one.
                try writeListingPDF(note, to: url, context: context)
            }
        case .pdf, .epub:
            // Neither is offered `.previewPDF`; a document is a PDF already
            // and a book has `.bookPDF`.
            throw Failure.nothingToExport
        }
    }

    /// The source listing, and the plates that follow it.
    private static func writeListingPDF(
        _ note: Note, to url: URL, context: Context
    ) throws {
        let listing = listing(for: note, context: context)
        try PDFPaginator.write(text: listing.text, plates: listing.plates, to: url)
    }

    // MARK: - The screen, as a picture

    /// The render, photographed: the same text the preview column is showing,
    /// laid out at the column's own measure and drawn under the window's own
    /// appearance (SPEC "## Export", Snapshots).
    ///
    /// Only offered where `snapshotsRender` says there is a render to take;
    /// anything else falls through to the listing, exactly as `.previewPDF`
    /// does, so the two halves of the export can never disagree about what a
    /// tab's "preview" is.
    private static func writePreviewPNG(
        _ note: Note, to url: URL, context: Context
    ) throws {
        try SnapshotPNG.write(
            text: try previewSnapshot(note, context: context),
            width: context.pictureWidth,
            appearance: context.pictureAppearance,
            background: .textBackgroundColor,
            to: url
        )
    }

    /// The editor, photographed: the same listing `.editorPDF` builds, at the
    /// editor's own measure.
    ///
    /// One difference, and it is the reader's Images row: a picture has no
    /// pages, so there is nowhere to gather plates onto and nothing to turn
    /// to. Every chip is drawn where it was written, whatever the sheet says
    /// — which is why the sheet only offers the row for `.editorPDF`.
    private static func writeListingPNG(
        _ note: Note, to url: URL, context: Context
    ) throws {
        try SnapshotPNG.write(
            text: listingSnapshot(note, context: context),
            width: context.pictureWidth,
            appearance: context.pictureAppearance,
            background: .textBackgroundColor,
            to: url
        )
    }

    private static func previewSnapshot(
        _ note: Note, context: Context
    ) throws -> NSAttributedString {
        switch note.kind {
        case .rtf:
            guard let rich = note.richText else { throw Failure.nothingToExport }
            return rich
        case .word, .spreadsheet, .presentation, .video:
            throw Failure.nothingToExport
        case .text:
            switch note.previewKind {
            case .markdown:
                return MarkdownRenderer.render(
                    note.text, font: context.font,
                    assets: context.assets, width: context.pictureWidth
                ).text
            case .latex:
                return LaTeXRenderer.render(
                    note.text, font: context.font,
                    baseURL: note.fileURL, width: context.pictureWidth
                ).text
            default:
                return listingSnapshot(note, context: context)
            }
        case .pdf, .epub, .image:
            // None of the three is offered a picture: two are documents with
            // pages of their own, and the third is a picture already.
            throw Failure.nothingToExport
        }
    }

    private static func listingSnapshot(
        _ note: Note, context: Context
    ) -> NSAttributedString {
        var context = context
        context.images = .inline
        return listing(for: note, context: context).text
    }

    // MARK: - The source listing

    /// The editor's own text on pages: its font, its size, its wrapping, its
    /// tabs, and its line numbers where the gutter is on. What happens to the
    /// pictures is the reader's choice — drawn where they were written, or
    /// gathered into plates at the end with a tag left behind on the line.
    ///
    /// Built from the note's *storage* rather than its text, because that is
    /// where the pictures are: an `![](nota://id)` token is one attachment in
    /// the editor, and every range in the listing lines up with the editor's
    /// own the way the gutter needs it to.
    static func listing(
        for note: Note, context: Context
    ) -> (text: NSAttributedString, plates: [PDFPaginator.Plate]) {
        let listing = NSMutableAttributedString(attributedString: note.storage)
        let whole = NSRange(location: 0, length: listing.length)
        listing.addAttributes([
            .font: context.font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: context.paragraphStyle,
        ], range: whole)

        var plates: [PDFPaginator.Plate] = []
        switch context.images {
        case .inline:
            // The picture itself, fitted to the column: the line grows
            // around it, and stays one line in the gutter. Backwards, so a
            // replacement never moves the spot before it.
            for spot in pictureSpots(in: listing).reversed() {
                guard let image = context.assets?.image(for: spot.assetID) else { continue }
                listing.replaceCharacters(in: spot.range, with: NSAttributedString(
                    attachment: fitted(image, to: context.width)
                ))
            }
        case .plates:
            plates = gatherPlates(in: listing, of: note, context: context)
        }

        guard context.showsLineNumbers else { return (listing, plates) }
        return (numbered(listing, context: context), plates)
    }

    /// One of the note's pictures on its way onto a page: where it stands in
    /// the text being written, and which asset it is.
    private struct PictureSpot {
        let range: NSRange
        let assetID: String
    }

    /// The note's own pictures in a piece of text, in the order they were
    /// written. Two kinds of attachment are the same picture seen from
    /// either half of the tab — the editor's chip in a listing, the
    /// renderer's picture in a render — and nothing else in either (a
    /// formula, a diagram) is a picture of the note's.
    private static func pictureSpots(in text: NSAttributedString) -> [PictureSpot] {
        var spots: [PictureSpot] = []
        text.forEachAttachmentRun { value, range, _ in
            switch value {
            case let chip as NotaImageAttachment:
                spots.append(PictureSpot(range: range, assetID: chip.assetID))
            case let picture as MarkdownImageAttachment:
                spots.append(PictureSpot(range: range, assetID: picture.assetID))
            default:
                break
            }
        }
        return spots
    }

    /// Gathering the pictures at the end, the one way it is ever done: every
    /// picture in `text` becomes the `[n] name` tag the reader turns by, and
    /// the pictures themselves come back as the plates to follow the text.
    ///
    /// The listing and the render both come through here, which is why the
    /// two of them tag a picture the same way and caption it the same way.
    /// A line number is the note's, not the text's: a render's pictures are
    /// laid out by the renderer and know nothing of the lines they were
    /// written on, so they are looked up on the note itself.
    private static func gatherPlates(
        in text: NSMutableAttributedString, of note: Note, context: Context
    ) -> [PDFPaginator.Plate] {
        let spots = pictureSpots(in: text)
        var lines = chipLines(of: note)

        // Backwards, so a replacement never moves the spot before it.
        for (offset, spot) in spots.enumerated().reversed() {
            let name = name(ofAsset: spot.assetID, in: note, assets: context.assets)
            text.replaceCharacters(in: spot.range, with: NSAttributedString(
                attachment: NotaImageAttachment.chipAttachment(
                    text: "[\(offset + 1)] \(name)", font: context.font
                )
            ))
        }

        var plates: [PDFPaginator.Plate] = []
        for (offset, spot) in spots.enumerated() {
            let line: Int
            if let index = lines.firstIndex(where: { $0.assetID == spot.assetID }) {
                line = lines.remove(at: index).line
            } else {
                line = 1
            }
            guard let image = context.assets?.image(for: spot.assetID) else { continue }
            plates.append(PDFPaginator.Plate(
                image: image,
                caption: caption(
                    figure: offset + 1,
                    name: name(ofAsset: spot.assetID, in: note, assets: context.assets),
                    line: line,
                    font: context.font
                )
            ))
        }
        return plates
    }

    /// Where each of the note's pictures was written, in order: the one place
    /// a plate's caption can get a line number from.
    private static func chipLines(of note: Note) -> [(assetID: String, line: Int)] {
        var lines: [(assetID: String, line: Int)] = []
        note.storage.forEachAttachmentRun { value, range, _ in
            guard let chip = value as? NotaImageAttachment else { return }
            lines.append((chip.assetID, note.lineIndex.lineNumber(at: range.location)))
        }
        return lines
    }

    /// What a picture is called: the name the file itself links it by where
    /// the note came from a file, and the asset's own name where it did not.
    private static func name(
        ofAsset assetID: String, in note: Note, assets: AssetStore?
    ) -> String {
        if let path = note.sidecarPaths[assetID] {
            return (path as NSString).lastPathComponent
        }
        return assets.map { ($0.url(for: assetID).lastPathComponent) } ?? assetID
    }

    /// The line under a plate: which figure it is, what it is called, and
    /// where in the note it was written.
    private static func caption(
        figure: Int, name: String, line: Int, font: NSFont
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(
            string: String(
                format: L10n.text("Figure %d · %@ · line %d"), figure, name, line
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]
        )
    }

    /// A picture on a listing's line: as wide as the column at most, and
    /// never taller than the page it has to fit on.
    private static func fitted(_ image: NSImage, to width: CGFloat) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return attachment }
        let scale = min(1, width / size.width, PDFPaginator.contentHeight / size.height)
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        return attachment
    }

    /// The gutter, as text. A printed page has no ruler beside it, so the
    /// numbers are part of the listing: each hard line starts with its own,
    /// right-aligned into a column of its own, and everything after it is
    /// indented past that column so a wrapped line lines up under its first
    /// word rather than under its number.
    private static func numbered(
        _ listing: NSAttributedString, context: Context
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: listing)
        let starts = lineStarts(in: result.mutableString)
        let font = context.font
        let width = ceil(
            ("\(starts.count)" as NSString).size(withAttributes: [.font: font]).width
        )
        // The number's own column, then the air between it and the text.
        let gutter = width + Self.gutterGap

        let style = (context.paragraphStyle.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        style.headIndent = gutter
        style.firstLineHeadIndent = 0
        // Two stops: the number ends where its column does, and the line
        // starts after it. A tab in the text itself lands on the interval
        // past them, which is the editor's own tab width.
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: gutter - Self.gutterGap / 2),
            NSTextTab(textAlignment: .left, location: gutter),
        ]
        style.defaultTabInterval = ceil(
            (" " as NSString).size(withAttributes: [.font: font]).width * 4
        )

        for (offset, start) in starts.enumerated().reversed() {
            result.insert(NSAttributedString(
                string: "\t\(offset + 1)\t",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            ), at: start)
        }
        result.addAttribute(
            .paragraphStyle, value: style,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// The air between the numbers and the text, the gutter's own gap in the
    /// editor doubled: a number is read against the page's edge here rather
    /// than against a ruler.
    private static let gutterGap: CGFloat = 16

    /// Where every hard line of the listing begins. The listing is not the
    /// note — the pictures have been replaced in it — so the note's own line
    /// table cannot answer, and it is walked once here by searching for the
    /// newlines rather than character by character.
    private static func lineStarts(in text: NSMutableString) -> [Int] {
        var starts = [0]
        var searched = 0
        while searched < text.length {
            let found = text.range(
                of: "\n", options: [],
                range: NSRange(location: searched, length: text.length - searched)
            )
            guard found.location != NSNotFound else { break }
            searched = NSMaxRange(found)
            // The empty line after a trailing newline is a line, the way the
            // editor's own gutter counts it (`LineIndex.lineCount`).
            starts.append(searched)
        }
        return starts
    }
}
