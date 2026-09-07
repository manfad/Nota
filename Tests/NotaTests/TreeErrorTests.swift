import AppKit
import XCTest
@testable import Nota

/// What a tree pane says when there is no tree to draw: a file that will not
/// parse, a file that is one plain value, and a file that is plainly some
/// other format — and the row that is too long for the column it is in.
final class TreeErrorTests: AppKitTestCase {
    /// The pane holds its note weakly, the way the column does.
    private var heldNotes: [Note] = []

    override func tearDownWithError() throws {
        heldNotes = []
    }

    /// One line of a page, as it arrives from a paste: longer than the pane
    /// is wide, and read by YAML as a single plain scalar.
    private static let page =
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        + "<title>A page that was pasted into the wrong tab</title></head>"
        + "<body><p>Hello</p></body></html>"

    // MARK: - The column

    /// A row is a line of the tree, not a line of the file: the one column is
    /// the width of the pane, so a leaf holding a whole page is cut off with
    /// an ellipsis instead of running off the edge.
    @MainActor
    func testALongValueIsTruncatedAtThePanesEdge() throws {
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 12)
        let pane = try makePane(showing: "{\n  \"page\": \"\(long)\"\n}\n")
        pane.layoutSubtreeIfNeeded()

        let column = try XCTUnwrap(pane.outline.tableColumns.first)
        XCTAssertLessThanOrEqual(column.width, pane.bounds.width,
                                 "the column never grows past the pane")
        XCTAssertGreaterThan(column.width, 0)

        let field = try XCTUnwrap(
            pane.outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField
        )
        XCTAssertEqual(field.lineBreakMode, .byTruncatingTail)
        XCTAssertLessThanOrEqual(field.frame.width, column.width)
        XCTAssertFalse(pane.outline.enclosingScrollView?.hasHorizontalScroller ?? true,
                       "there is nothing to scroll sideways to")
    }

    // MARK: - The message

    @MainActor
    func testAFileThatIsOnePlainValueSaysSoInsteadOfShowingOneRow() throws {
        let pane = try makePane(showing: "Just a sentence somebody typed.\n", named: "notes.yaml")

        XCTAssertTrue(pane.visibleRows.isEmpty, "one row holding the whole file is not a tree")
        XCTAssertNil(pane.shownParseError, "it parsed — it is simply not a document")
        let message = try XCTUnwrap(pane.shownErrorMessage)
        XCTAssertEqual(message.split(separator: "\n").first.map(String.init), "Not valid YAML")
        XCTAssertTrue(
            message.contains("The whole file is one plain value, not a YAML document."),
            "got \(message)"
        )
    }

    @MainActor
    func testTheMessageNamesWhatTheTextReadsAs() throws {
        let pane = try makePane(showing: Self.page + "\n", named: "config.yaml")

        let message = try XCTUnwrap(pane.shownErrorMessage)
        XCTAssertTrue(
            message.contains("It reads as HTML — choose that in the footer's format badge."),
            "got \(message)"
        )
    }

    /// The way out is only offered where there is one: a file the detector
    /// has nothing to say about gets the headline and the detail alone.
    @MainActor
    func testNothingIsOfferedWhenTheTextReadsAsNothingElse() throws {
        let pane = try makePane(showing: "Just a sentence somebody typed.\n", named: "notes.yaml")
        let message = try XCTUnwrap(pane.shownErrorMessage)
        XCTAssertFalse(message.contains("It reads as"), "got \(message)")
    }

    @MainActor
    func testAParseFailureKeepsItsLineAndItsReason() throws {
        let pane = try makePane(showing: "{\n  \"a\": 1,\n  \"b\" 2\n}\n")

        XCTAssertEqual(pane.shownParseError,
                       StructuredParseError(line: 3, message: "Expected `:`"))
        let message = try XCTUnwrap(pane.shownErrorMessage)
        XCTAssertEqual(message.split(separator: "\n").map(String.init),
                       ["Not valid JSON", "Line 3 — Expected `:`"])
    }

    /// The headline reads as a headline and the lines under it are quieter.
    @MainActor
    func testTheHeadlineIsLouderThanTheDetail() throws {
        let pane = try makePane(showing: Self.page + "\n", named: "config.yaml")
        let message = try XCTUnwrap(pane.shownMessage)
        XCTAssertEqual(
            message.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .labelColor
        )
        let detail = message.string.distance(
            from: message.string.startIndex,
            to: try XCTUnwrap(message.string.firstIndex(of: "\n"))
        ) + 1
        XCTAssertEqual(
            message.attribute(.foregroundColor, at: detail, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makePane(
        showing text: String, named name: String = "Settings.json"
    ) throws -> TreePreviewView {
        _ = NSApplication.shared
        let pane = TreePreviewView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        pane.layoutSubtreeIfNeeded()
        let note = makeNote(named: name, text: text)
        heldNotes.append(note)
        pane.show(note, in: PreviewContext(
            font: .systemFont(ofSize: 13), assets: nil, isVisible: true
        ))
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    private func makeNote(named name: String, text: String) -> Note {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaTreeError-\(UUID().uuidString)")
            .appendingPathComponent(name)
        return Note(fileURL: url, untitledName: nil, text: text,
                    attributes: [:], assets: nil)
    }
}
