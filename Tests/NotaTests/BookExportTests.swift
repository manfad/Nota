import AppKit
import Foundation
import PDFKit
import WebKit
import XCTest
@testable import Nota

/// The three conversions between the things Nota reads and does not edit: a
/// book printed as a PDF, a PDF read back as a book, and a page printed as a
/// PDF (SPEC Todo 1).
///
/// Every fixture here is a real file out of `Examples/` — a book WebKit has to
/// lay out, a document with a text layer and an outline, a page with a
/// stylesheet beside it — because the whole of what these three do is survive
/// real files. A hand-built one would prove the plumbing and nothing else.
final class BookExportTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - A book, printed

    /// The chapters go on the paper in spine order, the contents become the
    /// PDF's outline, and the first page is the first chapter.
    @MainActor
    func testABookIsPrintedChapterByChapterIntoOneDocument() throws {
        let book = try XCTUnwrap(EPUBBook.open(exampleURL("Book.epub")))
        let pdf = try makeTemporaryDirectory().appendingPathComponent("Book.pdf")

        try printBook(book, to: pdf)

        let document = try XCTUnwrap(PDFDocument(url: pdf), "the export is a readable PDF")
        XCTAssertGreaterThanOrEqual(
            document.pageCount, book.chapters.count,
            "every chapter is at least one sheet, so there are at least as many sheets as chapters"
        )
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                       book.title, "the book's own title is the document's")

        let outline = try XCTUnwrap(document.outlineRoot, "the contents become the outline")
        let tops = book.contentsEntries.filter { $0.level == 1 }
        XCTAssertEqual(outline.numberOfChildren, tops.count)
        XCTAssertEqual((0 ..< outline.numberOfChildren).map { outline.child(at: $0)?.label },
                       tops.map { $0.title })

        let first = try XCTUnwrap(document.page(at: 0)?.string)
        let opening = String(squeezed(book.words(ofChapter: 0)).prefix(40))
        XCTAssertTrue(squeezed(first).contains(opening),
                      "page one is chapter one: expected \(opening)")
    }

    /// A book that is not in English is the same book on paper. WebKit picks
    /// the font, and nothing along the way turns 燈籠 into boxes.
    @MainActor
    func testABookInChineseKeepsItsCharactersOnPaper() throws {
        let book = try XCTUnwrap(EPUBBook.open(exampleURL("燈籠.epub")))
        let pdf = try makeTemporaryDirectory().appendingPathComponent("Lantern.pdf")

        try printBook(book, to: pdf)

        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThanOrEqual(document.pageCount, book.chapters.count)
        XCTAssertTrue(squeezed(document.string ?? "").contains("燈籠"),
                      "the word the whole book is named for is on the paper")
    }

    // MARK: - A document, read back as a book

    /// `Examples/Demo.pdf` has an outline and a text layer, which is the whole
    /// of what a reflowable book needs. What comes back opens in Nota as a
    /// book, with a chapter per outline entry and the document's own words in
    /// it.
    func testADocumentComesBackAsABookNotaCanOpen() throws {
        let source = exampleURL("Demo.pdf")
        let document = try XCTUnwrap(PDFDocument(url: source))
        let epub = try makeTemporaryDirectory().appendingPathComponent("Demo.epub")

        try PDFToEPUB.export(document: document, title: "Demo", to: epub)

        XCTAssertEqual(FileSniff.classify(at: epub), .epub,
                       "the archive's first entry is a stored mimetype, or it is not a book")
        let book = try XCTUnwrap(EPUBBook.open(epub), "Nota's own reader opens it")
        XCTAssertEqual(book.title, "Demo")
        XCTAssertEqual(book.chapters.count, topLevelOutlineCount(of: document),
                       "one chapter per top-level bookmark")
        XCTAssertFalse(book.contentsEntries.isEmpty, "the contents come back too")

        let words = squeezed((0 ..< book.chapters.count)
            .map { book.words(ofChapter: $0) }.joined(separator: " "))
        for token in probeTokens(in: document) {
            XCTAssertTrue(words.contains(token), "the document's own “\(token)” is in the book")
        }
    }

    func testAChineseDocumentComesBackAsABookToo() throws {
        let source = exampleURL("Demo-zh.pdf")
        let document = try XCTUnwrap(PDFDocument(url: source))
        let epub = try makeTemporaryDirectory().appendingPathComponent("Demo-zh.epub")

        try PDFToEPUB.export(document: document, title: "示範", to: epub)

        let book = try XCTUnwrap(EPUBBook.open(epub))
        XCTAssertEqual(book.title, "示範")
        XCTAssertFalse(book.chapters.isEmpty)

        let words = squeezed((0 ..< book.chapters.count)
            .map { book.words(ofChapter: $0) }.joined(separator: " "))
        for token in probeTokens(in: document) {
            XCTAssertTrue(words.contains(token), "the document's own “\(token)” is in the book")
        }
    }

    // MARK: - What is refused

    /// `Examples/fake.pdf` is a text file somebody named `.pdf`. PDFKit will
    /// not open it, and the file-shaped door says so in the reader's own
    /// language rather than writing an empty book.
    func testAFileThatIsNotADocumentIsRefused() throws {
        let epub = try makeTemporaryDirectory().appendingPathComponent("fake.epub")
        XCTAssertNil(PDFDocument(url: exampleURL("fake.pdf")), "it is not a PDF at all")

        XCTAssertThrowsError(
            try PDFToEPUB.export(pdfAt: exampleURL("fake.pdf"), title: "fake", to: epub)
        ) { error in
            XCTAssertEqual(error as? PDFToEPUB.Failure, .notADocument)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           L10n.text("This file is not a PDF."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: epub.path),
                       "a refusal writes nothing")
    }

    /// A document whose pages hold no text is a scan, and there is no
    /// reflowable book in a stack of pictures.
    func testADocumentWithNoTextIsRefusedAsAScan() throws {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let epub = try makeTemporaryDirectory().appendingPathComponent("scan.epub")

        XCTAssertThrowsError(
            try PDFToEPUB.export(document: document, title: "Scan", to: epub)
        ) { error in
            XCTAssertEqual(error as? PDFToEPUB.Failure, .noText)
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                L10n.text("This PDF has no text to read — it is probably a scan.")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: epub.path))
    }

    // MARK: - A page, printed

    /// `Examples/HTML.html` with its stylesheet beside it, printed. And a page
    /// far taller than a sheet, which is what says the print paginates rather
    /// than rendering one enormous page the way `createPDF` does.
    @MainActor
    func testAPageIsPrintedAndATallOneIsPaginated() throws {
        let directory = try makeTemporaryDirectory()
        let short = directory.appendingPathComponent("HTML.pdf")
        try printPage(at: exampleURL("HTML.html"), to: short)

        let page = try XCTUnwrap(PDFDocument(url: short))
        XCTAssertGreaterThanOrEqual(page.pageCount, 1)
        XCTAssertTrue(squeezed(page.string ?? "").contains(squeezed("The page is the page")),
                      "the page's own words are on the paper")

        let paragraphs = (1 ... 200)
            .map { "<p>Paragraph number \($0) of a page that is far taller than a sheet.</p>" }
            .joined(separator: "\n")
        let tall = directory.appendingPathComponent("tall.html")
        try Data("<!doctype html><meta charset=\"utf-8\"><body>\(paragraphs)</body>".utf8)
            .write(to: tall)

        let tallPDF = directory.appendingPathComponent("tall.pdf")
        try printPage(at: tall, to: tallPDF)
        let paginated = try XCTUnwrap(PDFDocument(url: tallPDF))
        XCTAssertGreaterThan(paginated.pageCount, 1,
                             "a page taller than a sheet is broken across sheets")
    }

    /// A page whose script never returns never finishes loading, and there is
    /// no callback for that — only the clock. The limit is an argument so the
    /// test does not have to wait a minute for it.
    @MainActor
    func testAPageThatNeverFinishesFailsWithinTheLimit() throws {
        let directory = try makeTemporaryDirectory()
        let stuck = directory.appendingPathComponent("stuck.html")
        // Twenty seconds of a blocked main thread in the web content process
        // — long past the limit below, and short enough that the process it
        // burns lets go by itself.
        try Data("""
        <!doctype html><meta charset="utf-8"><body><p>hi</p>
        <script>var end = Date.now() + 20000; while (Date.now() < end) {}</script>
        """.utf8).write(to: stuck)

        let pdf = directory.appendingPathComponent("stuck.pdf")
        let done = expectation(description: "the clock ran out")
        var outcome: Result<Void, Error>?
        WebPDF.export(pageAt: stuck, to: pdf, timeout: 1.5) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 15)

        guard case .failure(let error)? = outcome else {
            return XCTFail("a page that never loads must not come back as a PDF")
        }
        XCTAssertEqual(error as? WebPDF.Failure, .timedOut)
        XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                       L10n.text("The page took too long to print."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
    }

    // MARK: - Helpers

    @MainActor
    private func printBook(_ book: EPUBBook, to url: URL) throws {
        let done = expectation(description: "the book printed")
        var outcome: Result<Void, Error>?
        var answeredOnMain = false
        EPUBToPDF.export(book: book, to: url) { result in
            outcome = result
            answeredOnMain = Thread.isMainThread
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        // The print operation answers from a thread of its own; the caller
        // updates the footer, which is layout, and layout off the main thread
        // is an abort. So the completion must arrive on main, every time.
        XCTAssertTrue(answeredOnMain, "the export answered on the main thread")
        if case .failure(let error)? = outcome { throw error }
        XCTAssertNotNil(outcome, "the export answered")
    }

    @MainActor
    private func printPage(at fileURL: URL, to url: URL) throws {
        let done = expectation(description: "the page printed")
        var outcome: Result<Void, Error>?
        var answeredOnMain = false
        WebPDF.export(pageAt: fileURL, to: url) { result in
            outcome = result
            answeredOnMain = Thread.isMainThread
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        // The print operation answers from a thread of its own; the caller
        // updates the footer, which is layout, and layout off the main thread
        // is an abort. So the completion must arrive on main, every time.
        XCTAssertTrue(answeredOnMain, "the export answered on the main thread")
        if case .failure(let error)? = outcome { throw error }
        XCTAssertNotNil(outcome, "the export answered")
    }

    /// The text with every space taken out, which is how two extracts of the
    /// same words are compared: a printed page wraps where the column ran out
    /// and a book wraps where the reader's screen does, so the line breaks
    /// are the one thing that cannot match.
    private func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// A handful of the document's own words, long enough to be distinctive
    /// and free of the hyphens the paragraph rebuilder heals — so what they
    /// prove is that the text came through, not how it was rewrapped.
    private func probeTokens(in document: PDFDocument, limit: Int = 5) -> [String] {
        var tokens: [String] = []
        for index in 0 ..< document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            for run in text.split(whereSeparator: { $0.isWhitespace }) {
                guard run.count >= 6, !run.contains("-") else { continue }
                tokens.append(String(run.prefix(8)))
                break
            }
            if tokens.count >= limit { break }
        }
        return tokens
    }

    /// How many top-level bookmarks the document has that actually point at a
    /// page — which is how many chapters the book should come back with.
    private func topLevelOutlineCount(of document: PDFDocument) -> Int {
        guard let root = document.outlineRoot else { return 0 }
        return (0 ..< root.numberOfChildren).filter { index in
            let child = root.child(at: index)
            let destination = child?.destination ?? (child?.action as? PDFActionGoTo)?.destination
            return destination?.page != nil
        }.count
    }

    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaBookExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
