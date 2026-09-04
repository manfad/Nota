import Foundation
import XCTest
@testable import Nota

/// Todo 9's extractor: headings read straight from a note's own text, the
/// same way `@` in the ⌘P switcher reads them — never from the render, so a
/// note nobody has opened the preview for still has an outline.
final class MarkdownHeadingsTests: XCTestCase {

    func testAllSixATXLevels() {
        let markdown = (1 ... 6)
            .map { String(repeating: "#", count: $0) + " Level \($0)" }
            .joined(separator: "\n\n")
        let headings = MarkdownHeadings.extract(from: markdown)

        XCTAssertEqual(headings.map(\.level), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(headings.map(\.text), (1 ... 6).map { "Level \($0)" })
    }

    func testATrailingHashRunIsStrippedAsDecoration() {
        let headings = MarkdownHeadings.extract(from: "## Trailing hashes ##")
        XCTAssertEqual(headings.map(\.text), ["Trailing hashes"])
        XCTAssertEqual(headings.map(\.level), [2])
    }

    func testALeadingHashWithNoSpaceIsProseNotAHeading() {
        XCTAssertTrue(MarkdownHeadings.extract(from: "#tag not a heading").isEmpty)
    }

    /// A `#` inside a fence is a comment or a shell prompt, never a heading —
    /// the same fence detection `MarkdownSourceMap` already scans code with.
    func testAHeadingInsideAFencedCodeBlockIsIgnored() {
        let markdown = """
        # Real heading

        ```
        # not a heading
        ```

        ## Also real
        """
        let headings = MarkdownHeadings.extract(from: markdown)
        XCTAssertEqual(headings.map(\.text), ["Real heading", "Also real"])
        XCTAssertEqual(headings.map(\.level), [1, 2])
    }

    /// A fence marked with `~~~` closes only on another `~~~`, so a `#` fence
    /// nested inside would not fool it either — the marker has to match.
    func testATildeFenceIsSkippedTheSameWay() {
        let markdown = "~~~\n# not a heading\n~~~\n\n# Real"
        XCTAssertEqual(MarkdownHeadings.extract(from: markdown).map(\.text), ["Real"])
    }

    func testASetextHeadingUnderAParagraph() {
        let markdown = "Title\n=====\n\nSubtitle\n-----\n\nbody text"
        let headings = MarkdownHeadings.extract(from: markdown)
        XCTAssertEqual(headings.map(\.text), ["Title", "Subtitle"])
        XCTAssertEqual(headings.map(\.level), [1, 2])
    }

    /// The heading's own location is the paragraph's line, not the
    /// underline's — that is where a caret jumping to it should land.
    func testASetextHeadingsLocationIsTheParagraphsLineNotTheUnderline() {
        let markdown = "before\n\nTitle\n=====\n\nafter"
        let headings = MarkdownHeadings.extract(from: markdown)
        let expected = (markdown as NSString).range(of: "Title").location
        XCTAssertEqual(headings.first?.location, expected)
    }

    /// A blank line between the paragraph and the dashes rules out a setext
    /// heading — the dashes are read as what they usually are instead.
    func testADashLineNotDirectlyUnderAParagraphIsNotASetextHeading() {
        let markdown = "Title\n\n-----\n\nafter"
        XCTAssertTrue(MarkdownHeadings.extract(from: markdown).isEmpty)
    }

    func testLocationsPointAtTheStartOfEachHeadingsOwnLine() {
        let markdown = "intro\n\n# First\n\nmore\n\n## Second"
        let headings = MarkdownHeadings.extract(from: markdown)
        let ns = markdown as NSString
        XCTAssertEqual(headings.map(\.location), [
            ns.range(of: "# First").location,
            ns.range(of: "## Second").location,
        ])
    }

    func testEmptyOrPlainTextHasNoHeadings() {
        XCTAssertTrue(MarkdownHeadings.extract(from: "").isEmpty)
        XCTAssertTrue(MarkdownHeadings.extract(from: "just a paragraph\nover two lines").isEmpty)
    }

    /// Headings land in document order, whatever order their levels are in.
    func testHeadingsComeBackInDocumentOrder() {
        let markdown = "### Three\n\n# One\n\n## Two"
        XCTAssertEqual(
            MarkdownHeadings.extract(from: markdown).map(\.text), ["Three", "One", "Two"]
        )
    }
}
