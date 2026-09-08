import AppKit
import PDFKit
import XCTest
@testable import Nota

/// `TablePDF` — a grid drawn onto pages, which is what a `.sql` or `.csv`
/// tab's `Preview as PDF` is. See SPEC.md "## Export", "Preview as PDF of a
/// grid".
///
/// Every PDF here is read back with PDFKit rather than looked at: the page
/// count, the words on a page and the paper's own width are the whole of what
/// the layout promises. The print operation behind it asks the window server
/// for a job, so the suite runs with the other AppKit ones.
final class TablePDFTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The table on the page

    /// The small case: one page, and every word of it on that page.
    @MainActor
    func testASmallTableIsOnePageHoldingEveryHeaderAndCell() throws {
        let document = try write(
            header: ["name", "city"],
            rows: [["Ada", "London"], ["Grace", "Paris"]]
        )
        XCTAssertEqual(document.pageCount, 1)
        let text = try string(ofPage: 0, in: document)
        for word in ["name", "city", "Ada", "London", "Grace", "Paris"] {
            XCTAssertTrue(text.contains(word), "“\(word)” is missing from the page")
        }
    }

    /// More rows than one page holds: the break falls between rows and the
    /// header is drawn again at the top of every page, the last one included.
    @MainActor
    func testALongTableRunsOverPagesAndRepeatsItsHeader() throws {
        let rows: [[String?]] = (1...400).map { ["\($0)", "row \($0)"] }
        let document = try write(header: ["id", "label"], rows: rows)
        XCTAssertGreaterThan(document.pageCount, 1, "400 rows do not fit on one page")

        let first = try string(ofPage: 0, in: document)
        XCTAssertTrue(first.contains("row 1"))
        let last = try string(ofPage: document.pageCount - 1, in: document)
        XCTAssertTrue(last.contains("id"), "the header is drawn on the last page too")
        XCTAssertTrue(last.contains("label"))
        XCTAssertTrue(last.contains("row 400"), "the last row is on the last page")
    }

    /// A `nil` cell — a SQL `NULL`, or a ragged CSV row's own field it never
    /// wrote that far into — is nothing on the page, not a word.
    @MainActor
    func testANilCellDrawsNothingAtAll() throws {
        let document = try write(
            header: ["a", "b"],
            rows: [["kept", nil], [nil, "also kept"]]
        )
        let text = try string(ofPage: 0, in: document)
        XCTAssertTrue(text.contains("kept"))
        XCTAssertTrue(text.contains("also kept"))
        XCTAssertFalse(text.contains("nil"))
        XCTAssertFalse(text.contains("NULL"))
    }

    /// Twelve columns of long values: the paper turns on its side, the widths
    /// are cut to what is left, and every column is still there.
    @MainActor
    func testAWideTableIsFittedOntoThePaperRatherThanRunningOffIt() throws {
        let headers = (1...12).map { "c\($0)" }
        let long = String(repeating: "a rather long value ", count: 3)
        let rows: [[String?]] = [headers.indices.map { _ in long }]
        let document = try write(header: headers, rows: rows)

        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(
            bounds.width, max(paper.width, paper.height),
            accuracy: 1, "the page is the paper, turned"
        )
        let text = try string(ofPage: 0, in: document)
        for header in headers {
            XCTAssertTrue(text.contains(header), "column “\(header)” never made the page")
        }
    }

    // MARK: - The columns, the paper and the size

    /// The squeeze comes off the widest columns and nowhere else. A narrow
    /// column — an `id`, a `balance`, a city — is left exactly as wide as it
    /// asked to be and reads on one line; the long notes beside it are the
    /// ones cut to the threshold, and they are the ones that wrap.
    ///
    /// A wrapped cell is broken across lines in the page's own text, so a
    /// value that comes back whole was never wrapped.
    @MainActor
    func testTheSqueezeComesOffTheWidestColumnsAndLeavesTheNarrowOnesAlone() throws {
        let note = String(repeating: "a sentence about this row, at some length. ", count: 8)
        let remark = String(repeating: "a second long remark about the same row. ", count: 8)
        let document = try write(
            header: ["id", "balance", "city", "note", "remark"],
            rows: [["1", "12.50", "Kuala Lumpur", note, remark]]
        )
        let text = try string(ofPage: 0, in: document)

        for whole in ["balance", "12.50", "Kuala Lumpur"] {
            XCTAssertTrue(text.contains(whole),
                          "“\(whole)” was broken across lines by a column that should not have been cut")
        }
        XCTAssertFalse(text.contains(note), "the long column is the one that wraps")
        XCTAssertFalse(text.contains(remark))
    }

    /// Fourteen columns want more than a portrait page: the paper turns
    /// rather than the columns being cut to one character each.
    @MainActor
    func testAWideTableTurnsThePaperOnItsSide() throws {
        let headers = (1...14).map { "column \($0)" }
        let rows: [[String?]] = (1...3).map { row in headers.indices.map { "r\(row)c\($0)" } }
        let document = try write(header: headers, rows: rows)

        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(bounds.width, bounds.height, "the page is on its side")
        XCTAssertEqual(bounds.width, max(paper.width, paper.height), accuracy: 1)
        XCTAssertEqual(NSPrintInfo.shared.orientation, orientation,
                       "the shared print info is left as it was found")
    }

    /// A table that fits stays on the paper the Mac is set up for.
    @MainActor
    func testANarrowTableStaysOnThePaperAsItIs() throws {
        let document = try write(
            header: ["id", "name", "city"],
            rows: [["1", "Ada", "London"], ["2", "Grace", "Paris"]]
        )
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, paper.width, accuracy: 1)
        XCTAssertEqual(bounds.height, paper.height, accuracy: 1)
    }

    /// A row taller than a whole page is clipped to one. What matters is that
    /// it ends: an unclipped row would never fit the page it was being broken
    /// onto, and the break would ask for pages for ever.
    @MainActor
    func testARowTallerThanThePageIsClippedRatherThanLooping() throws {
        let huge = String(repeating: "word ", count: 6000)
        let document = try write(header: ["essay"], rows: [[huge]])
        XCTAssertEqual(document.pageCount, 1)
    }

    /// A table of short values is never laid out cell by cell: each was
    /// measured on one line when the columns were sized, and one that fits
    /// its column is one line tall without being asked again. The bound is
    /// loose on purpose — what it catches is a return to a `boundingRect`
    /// per cell, which is seconds rather than a fraction of one.
    @MainActor
    func testAThousandsOfRowsTableIsMeasuredWithoutLayingOutEveryCell() throws {
        let rows: [[String?]] = (1...5_000).map { row in
            (1...6).map { "r\(row)c\($0)" }
        }
        let started = Date()
        let document = try write(header: (1...6).map { "c\($0)" }, rows: rows)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertLessThan(elapsed, 5, "5,000 short rows took \(elapsed)s to draw")
    }

    // MARK: - The edges

    /// No columns is nothing to draw, and nothing is written.
    @MainActor
    func testATableWithNoColumnsRefuses() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("empty.pdf")
        XCTAssertThrowsError(
            try TablePDF.write(header: [], rows: [], font: font, to: url)
        ) { error in
            XCTAssertEqual(error as? PDFPaginator.Failure, .nothingToDraw)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A header with no rows under it is a page all the same: an empty table
    /// still says what its columns are.
    @MainActor
    func testAHeaderWithNoRowsIsOnePage() throws {
        let document = try write(header: ["one", "two"], rows: [])
        XCTAssertEqual(document.pageCount, 1)
        let text = try string(ofPage: 0, in: document)
        XCTAssertTrue(text.contains("one"))
        XCTAssertTrue(text.contains("two"))
    }

    // MARK: - Helpers

    /// The grid's own font, which is bigger than a page is set in: the
    /// export caps the size and keeps the family.
    private var font: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    /// The paper the Mac is set up for, as the export finds it.
    private var paper: NSSize { NSPrintInfo.shared.paperSize }
    private var orientation: NSPrintInfo.PaperOrientation { NSPrintInfo.shared.orientation }

    @MainActor
    private func write(header: [String], rows: [[String?]]) throws -> PDFDocument {
        let url = try makeTemporaryDirectory().appendingPathComponent("table.pdf")
        try TablePDF.write(header: header, rows: rows, font: font, to: url)
        return try XCTUnwrap(PDFDocument(url: url), "the export wrote no readable PDF")
    }

    private func string(ofPage index: Int, in document: PDFDocument) throws -> String {
        try XCTUnwrap(XCTUnwrap(document.page(at: index)).string)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaTablePDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
