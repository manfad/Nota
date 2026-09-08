import AppKit

/// What the tab in front can be exported to — SPEC "## Export", Todo 1.
///
/// A target is a *shape*, not a file type: `.previewPDF` is "what the reader
/// is looking at, on pages", `.editorPDF` is "the source, as the editor has
/// it". Which of them a tab offers is `Exporter.targets(for:)`, and the sheet
/// lists them in that order with the first one selected.
enum ExportTarget: String, CaseIterable {
    /// The render, the document or the picture as the tab shows it.
    case previewPDF
    /// The source listing: the editor's own text, gutter and all.
    case editorPDF
    /// A book laid out as pages.
    case bookPDF
    /// A document taken apart into a book.
    case epub
    /// A dump's or a table's rows, written out as CSV.
    case csv
    /// A `.tex` through a real TeX engine, rather than through Nota's own
    /// reading of it.
    case texPDF

    /// The word the popup wears — also the `L10n` key it is looked up under,
    /// so the sheet and the tables can never drift apart.
    var titleKey: String {
        switch self {
        case .previewPDF: "Preview as PDF"
        case .editorPDF: "Editor as PDF"
        case .bookPDF: "Book as PDF"
        case .epub: "Book (EPUB)"
        case .csv: "Table (CSV)"
        case .texPDF: "PDF through TeX"
        }
    }

    var title: String { L10n.text(titleKey) }

    /// What the written file is called, once the reader has named it: the
    /// extension the save dialog opens on and cannot be talked out of.
    var fileExtension: String {
        switch self {
        case .previewPDF, .editorPDF, .bookPDF, .texPDF: "pdf"
        case .epub: "epub"
        case .csv: "csv"
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
        case .plates: "Plates at the end"
        }
    }

    var title: String { L10n.text(titleKey) }
}

/// Making the file the reader asked for.
///
/// The one seam every export goes through. What each target *is* is decided
/// here; how a page ends is `PDFPaginator`'s; the sheet and the save dialog
/// are the window's. Four of the six targets are somebody else's work —
/// a book onto pages, a document into a book, rows as CSV, a `.tex` through
/// a TeX engine — so each of those is a hook standing empty until it is
/// plugged in, and a target whose hook is empty is not offered at all.
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
        /// The view this tab is being read through, where there is one. The
        /// two PDFs Nota writes itself never look at it — a render is made
        /// from the note, not read off the screen — but an exporter that
        /// writes out *what a pane is showing* has nowhere else to get it:
        /// a dump's rows are the query the reader typed and the sort they
        /// clicked, and neither is on the note. Handed in by the window, so
        /// with two windows open each export is that window's own.
        var previewContent: (any PreviewContent)?
    }

    enum Failure: Error {
        /// The target's own exporter has not been plugged in. Not something a
        /// reader can reach — a target with no hook is never listed — but the
        /// switch has to answer for it.
        case noExporter(ExportTarget)
        /// The tab had nothing this target could be made from: an unreadable
        /// picture, a document that would not parse.
        case nothingToExport
    }

    // MARK: - The hooks

    /// What an exporter written elsewhere looks like from here: the tab, the
    /// file to write, and everything the window knows about how the tab is
    /// being read — including the pane in front of it, for an exporter whose
    /// answer is on screen rather than in the note.
    typealias Hook = (Note, URL, Context) throws -> Void

    /// A book onto pages. `EPUBBook` already has the chapters; laying them
    /// out is the other half.
    static var bookPDF: Hook?

    /// A document into a book — the way back from `.pdf` to `.epub`.
    static var pdfToEPUB: Hook?

    /// A `.sql` or `.csv` tab's rows written out as CSV. It is handed the
    /// pane along with the note, since what a grid is showing — the query in
    /// the box, the column a header click sorted by — lives on the pane.
    static var csv: Hook?

    /// A `.tex` typeset by whichever engine is installed. With none, the tab
    /// still exports through Nota's own render, which is `.previewPDF`.
    static var texPDF: Hook?

    /// An `.html` tab's page as WebKit draws it. Without it, the page exports
    /// as the source listing it is in the editor.
    static var htmlPagePDF: Hook?

    /// The hook a target waits on, or `nil` for the two that are written
    /// here and always available.
    static func hook(for target: ExportTarget) -> Hook? {
        switch target {
        case .previewPDF, .editorPDF: nil
        case .bookPDF: bookPDF
        case .epub: pdfToEPUB
        case .csv: csv
        case .texPDF: texPDF
        }
    }

    /// Whether the sheet lists this target at all. The two PDFs Nota writes
    /// itself always; every other target only once somebody has plugged its
    /// exporter in.
    private static func isAvailable(_ target: ExportTarget) -> Bool {
        switch target {
        case .previewPDF, .editorPDF: true
        default: hook(for: target) != nil
        }
    }

    // MARK: - What a tab offers

    /// The targets this tab can be exported to, in the order the sheet lists
    /// them — what the reader is looking at first, the source after it, and
    /// the tab's own speciality last.
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
            switch note.previewKind {
            case .latex: targets.append(.texPDF)
            case .sql, .csv: targets.append(.csv)
            default: break
            }
        case .rtf, .image:
            // The document as the viewer shows it, and the picture on a page.
            // Neither has a source to list.
            targets = [.previewPDF]
        case .epub:
            targets = [.bookPDF]
        case .pdf:
            // The one export that is not a PDF: a document already is one.
            targets = [.epub]
        }
        return targets.filter(isAvailable)
    }

    // MARK: - Making the file

    static func export(
        _ note: Note, to target: ExportTarget, at url: URL, context: Context
    ) throws {
        switch target {
        case .previewPDF: try writePreviewPDF(note, to: url, context: context)
        case .editorPDF: try writeListingPDF(note, to: url, context: context)
        case .bookPDF, .epub, .csv, .texPDF:
            guard let hook = hook(for: target) else { throw Failure.noExporter(target) }
            try hook(note, url, context)
        }
    }

    /// The reader's own view of the tab, on pages.
    private static func writePreviewPDF(
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
        case .text:
            switch note.previewKind {
            case .markdown:
                try PDFPaginator.write(
                    text: MarkdownRenderer.render(
                        note.text, font: context.font,
                        assets: context.assets, width: context.width
                    ).text,
                    to: url
                )
            case .latex:
                try PDFPaginator.write(
                    text: LaTeXRenderer.render(
                        note.text, font: context.font,
                        baseURL: note.fileURL, width: context.width
                    ).text,
                    to: url
                )
            case .html:
                // The page as WebKit draws it where that exporter is plugged
                // in; the source listing where it is not, which is what the
                // tab's other half shows anyway.
                if let hook = htmlPagePDF {
                    try hook(note, url, context)
                } else {
                    try writeListingPDF(note, to: url, context: context)
                }
            default:
                // A tree, a grid and a drawing all print badly as what they
                // are — a table of rows is not a page — and the beautified
                // source is the thing the reader agreed to. So the listing
                // stands in, for those and for plain text.
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
        var spots: [(range: NSRange, assetID: String)] = []
        listing.forEachAttachmentRun { value, range, _ in
            guard let chip = value as? NotaImageAttachment else { return }
            spots.append((range: range, assetID: chip.assetID))
        }

        // Backwards, so a replacement never moves the spot before it.
        for (offset, spot) in spots.enumerated().reversed() {
            let number = offset + 1
            let name = name(ofAsset: spot.assetID, in: note, assets: context.assets)
            let image = context.assets?.image(for: spot.assetID)
            let replacement: NSAttributedString
            switch context.images {
            case .inline:
                // The picture itself, fitted to the column: the line grows
                // around it, and stays one line in the gutter.
                guard let image else { continue }
                replacement = NSAttributedString(
                    attachment: fitted(image, to: context.width)
                )
            case .plates:
                // The tag the editor draws, now saying which plate to turn to.
                replacement = NSAttributedString(
                    attachment: NotaImageAttachment.chipAttachment(
                        text: "[\(number)] \(name)", font: context.font
                    )
                )
            }
            listing.replaceCharacters(in: spot.range, with: replacement)
        }

        if context.images == .plates {
            for (offset, spot) in spots.enumerated() {
                guard let image = context.assets?.image(for: spot.assetID) else { continue }
                plates.append(PDFPaginator.Plate(
                    image: image,
                    caption: caption(
                        figure: offset + 1,
                        name: name(ofAsset: spot.assetID, in: note, assets: context.assets),
                        line: note.lineIndex.lineNumber(at: spot.range.location),
                        font: context.font
                    )
                ))
            }
        }

        guard context.showsLineNumbers else { return (listing, plates) }
        return (numbered(listing, context: context), plates)
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
