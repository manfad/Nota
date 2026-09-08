import Foundation
import PDFKit

/// A book exported as a PDF: every chapter printed the way it is read, and
/// the pages bound together in spine order with the book's own contents as
/// the outline (SPEC Todo 1).
///
/// There is no library here and no layout engine of Nota's own. A chapter is
/// XHTML with the book's stylesheets, fonts and pictures beside it, and the
/// thing that draws that is the same web view the book is read in — so the
/// export is the reading, printed. `WebPDF` turns one chapter into one PDF;
/// this puts them end to end, and PDFKit does the binding.
///
/// The chapters are printed one at a time rather than all at once. WebKit's
/// printing is not safe to run two of, and a book that printed itself in
/// parallel would come back with chapters missing — so `WebPDF`'s queue is
/// the whole of the ordering, and the merge happens once the last one lands.
enum EPUBToPDF {

    /// The two ways an export ends badly. A chapter that will not print is
    /// neither of them: it is left out, and the rest of the book is still a
    /// book.
    enum Failure: LocalizedError {
        /// Not one chapter printed. There is nothing to write.
        case nothingPrinted
        /// The pages were made and the file was not — no room, no permission,
        /// a folder that has gone.
        case couldNotWrite

        var errorDescription: String? {
            switch self {
            case .nothingPrinted: L10n.text("Nothing in this book could be printed.")
            case .couldNotWrite: L10n.text("The PDF could not be written.")
            }
        }
    }

    /// Prints every chapter of `book` and writes the lot to `url` as one PDF.
    ///
    /// Asynchronous because printing is: each chapter is a page load and a
    /// print operation, and both come back through the run loop. The
    /// completion arrives on the main thread.
    ///
    /// A chapter that will not print — a file missing from the unpacked
    /// folder, XHTML WebKit refuses, a page that never finishes loading — is
    /// skipped and the book goes on without it. The export fails only when
    /// nothing at all printed, which is the case where there is no PDF to
    /// write.
    static func export(
        book: EPUBBook, to url: URL, completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nota-EPUB-PDF-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true
        )) != nil else {
            completion(.failure(Failure.couldNotWrite))
            return
        }

        printChapters(of: book, into: staging, from: 0, printed: []) { printed in
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try bind(printed, of: book, to: url)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Printing

    /// One chapter, then the next. Written as a recursion through the
    /// completion rather than a loop because there is no loop that waits: the
    /// only thing that says a chapter has printed is its callback.
    private static func printChapters(
        of book: EPUBBook, into staging: URL, from index: Int,
        printed: [(chapter: Int, url: URL)],
        finished: @escaping ([(chapter: Int, url: URL)]) -> Void
    ) {
        guard index < book.chapters.count else {
            finished(printed)
            return
        }
        let sheet = staging.appendingPathComponent(
            String(format: "chapter-%04d.pdf", index)
        )
        WebPDF.export(pageAt: book.chapters[index].url, to: sheet) { result in
            var printed = printed
            if case .success = result { printed.append((index, sheet)) }
            printChapters(of: book, into: staging, from: index + 1, printed: printed,
                          finished: finished)
        }
    }

    // MARK: - Binding

    /// The chapters' PDFs, end to end, with the book's contents as the
    /// outline and its title as the document's own.
    private static func bind(
        _ printed: [(chapter: Int, url: URL)], of book: EPUBBook, to url: URL
    ) throws {
        let bound = PDFDocument()
        /// Which page of the bound document each chapter starts on — what an
        /// outline entry needs, since the contents point at chapters and an
        /// outline points at pages.
        var firstPage: [Int: Int] = [:]

        for sheet in printed {
            guard let chapter = PDFDocument(url: sheet.url), chapter.pageCount > 0 else { continue }
            firstPage[sheet.chapter] = bound.pageCount
            for page in 0 ..< chapter.pageCount {
                guard let page = chapter.page(at: page) else { continue }
                bound.insert(page, at: bound.pageCount)
            }
        }
        guard bound.pageCount > 0 else { throw Failure.nothingPrinted }

        if let title = book.title, !title.isEmpty {
            var attributes = bound.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.titleAttribute] = title
            bound.documentAttributes = attributes
        }
        if let outline = outline(of: book, firstPage: firstPage, in: bound) {
            bound.outlineRoot = outline
        }

        guard bound.write(to: url) else { throw Failure.couldNotWrite }
    }

    /// The book's own table of contents, as the PDF's outline.
    ///
    /// The contents come flattened with the nesting kept as a level, which is
    /// exactly what a stack rebuilds: an entry deeper than the one before it
    /// hangs off it, an entry at the same level or shallower closes as many
    /// as it has to first. An entry pointing at a chapter that did not print
    /// has nowhere to go and is left out, along with anything nested inside
    /// it — a bookmark that lands on the wrong chapter is worse than no
    /// bookmark.
    ///
    /// The destination is the top of the chapter's first page. A contents
    /// entry may name an `#anchor` partway into a chapter; where in a printed
    /// sheet that anchor ended up is not something the PDF knows, so every
    /// entry lands at the chapter it belongs to.
    private static func outline(
        of book: EPUBBook, firstPage: [Int: Int], in document: PDFDocument
    ) -> PDFOutline? {
        let root = PDFOutline()
        var stack: [(level: Int, outline: PDFOutline)] = [(0, root)]

        for entry in book.contentsEntries {
            guard let destination = book.destination(ofContentsLine: entry.line),
                  let index = firstPage[destination.chapter],
                  let page = document.page(at: index)
            else { continue }

            let node = PDFOutline()
            node.label = entry.title
            let top = page.bounds(for: .mediaBox).maxY
            node.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: top))

            while let last = stack.last, last.level >= entry.level, stack.count > 1 {
                stack.removeLast()
            }
            let parent = stack.last?.outline ?? root
            parent.insertChild(node, at: parent.numberOfChildren)
            stack.append((entry.level, node))
        }

        return root.numberOfChildren > 0 ? root : nil
    }
}
