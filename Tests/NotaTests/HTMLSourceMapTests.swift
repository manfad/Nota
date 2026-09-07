import Foundation
import XCTest
@testable import Nota

/// Lining a page's DOM up against the tags its file actually writes.
///
/// The map is the honest half of "no block sync": the two sequences agree
/// most of the time, drift for reasons that are all ordinary HTML, and the
/// only answer worth giving when they have drifted past recovery is none.
/// Everything here is text — no WebKit, no window, no page.
final class HTMLSourceMapTests: XCTestCase {

    // MARK: - A page whose DOM is what its source says

    func testEveryElementOfAPlainPageFindsItsOwnTag() throws {
        let source = """
        <!doctype html>
        <html>
        <head><title>T</title></head>
        <body>
        <h1>Hi</h1>
        <div><p>One</p><p>Two</p></div>
        </body>
        </html>
        """
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        let tags = ["html", "head", "title", "body", "h1", "div", "p", "p"]
        XCTAssertEqual(map.count, tags.count)

        XCTAssertEqual(map.range(ofElementAt: 0, tagNames: tags), range(of: "<html>", in: source))
        XCTAssertEqual(map.range(ofElementAt: 2, tagNames: tags),
                       range(of: "<title>T</title>", in: source),
                       "a title is text and nothing else, so the whole of it is revealed")
        XCTAssertEqual(map.range(ofElementAt: 4, tagNames: tags),
                       range(of: "<h1>Hi</h1>", in: source))
        XCTAssertEqual(map.range(ofElementAt: 6, tagNames: tags),
                       range(of: "<p>One</p>", in: source))
        XCTAssertEqual(map.range(ofElementAt: 7, tagNames: tags),
                       range(of: "<p>Two</p>", in: source),
                       "the second `p`, not the first: the walk keeps its place")
    }

    func testTheWholeElementIsRevealedOnlyWhereItHoldsNothingButText() throws {
        let source = "<div><p>Hello <b>there</b></p><img src=\"x.png\"><p>Open</div>"
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        let tags = ["div", "p", "b", "img", "p"]

        XCTAssertEqual(map.range(ofElementAt: 0, tagNames: tags), range(of: "<div>", in: source),
                       "a div around two blocks is a container: the start tag and no more")
        XCTAssertEqual(map.range(ofElementAt: 1, tagNames: tags),
                       range(of: "<p>Hello <b>there</b></p>", in: source),
                       "a paragraph holding text and inline markup is revealed whole")
        XCTAssertEqual(map.range(ofElementAt: 2, tagNames: tags),
                       range(of: "<b>there</b>", in: source))
        XCTAssertEqual(map.range(ofElementAt: 3, tagNames: tags),
                       range(of: "<img src=\"x.png\">", in: source),
                       "a void element has no span to give")
        XCTAssertEqual(map.range(ofElementAt: 4, tagNames: tags),
                       (source as NSString).range(of: "<p>", options: .backwards),
                       "and neither has one whose end tag the author left out")
    }

    func testTheRangesAreCountedTheWayTheEditorCountsThem() throws {
        let source = "<p>😀 four bytes, two units</p><h1>Hi</h1>"
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        XCTAssertEqual(map.range(ofElementAt: 1, tagNames: ["p", "h1"]),
                       range(of: "<h1>Hi</h1>", in: source))
    }

    // MARK: - What the DOM has and the file does not

    func testAnImpliedTableBodyIsSkipped() throws {
        let source = "<table><tr><td>1</td></tr></table>"
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        // WebKit puts a `tbody` between the table and its row; the file has
        // no such tag, and never did.
        let tags = ["table", "tbody", "tr", "td"]
        XCTAssertEqual(map.range(ofElementAt: 0, tagNames: tags),
                       range(of: "<table>", in: source))
        XCTAssertNil(map.range(ofElementAt: 1, tagNames: tags),
                     "the tbody is the parser's, not the author's")
        XCTAssertEqual(map.range(ofElementAt: 2, tagNames: tags), range(of: "<tr>", in: source))
        XCTAssertEqual(map.range(ofElementAt: 3, tagNames: tags),
                       range(of: "<td>1</td>", in: source))
    }

    func testAFragmentWithNoHtmlHeadOrBodyIsStillMapped() throws {
        let source = "<p>One</p><p>Two</p>"
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        let tags = ["html", "head", "body", "p", "p"]
        XCTAssertNil(map.range(ofElementAt: 0, tagNames: tags), "no `html` was ever written")
        XCTAssertNil(map.range(ofElementAt: 2, tagNames: tags))
        XCTAssertEqual(map.range(ofElementAt: 3, tagNames: tags),
                       range(of: "<p>One</p>", in: source))
        XCTAssertEqual(map.range(ofElementAt: 4, tagNames: tags),
                       range(of: "<p>Two</p>", in: source))
    }

    func testAnElementAScriptAddedHasNoSourceToPointAt() throws {
        let source = "<div><p>a</p></div>"
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        // The `b` inside the paragraph was made at run time; the file ends
        // with the two tags it wrote.
        let tags = ["html", "head", "body", "div", "p", "b"]
        XCTAssertEqual(map.range(ofElementAt: 4, tagNames: tags),
                       range(of: "<p>a</p>", in: source))
        XCTAssertNil(map.range(ofElementAt: 5, tagNames: tags))
    }

    // MARK: - Drift

    func testASequenceThatHasDriftedGivesUpRatherThanPointingAtTheWrongTag() throws {
        let source = "<div><span>a</span></div>"
        let map = try XCTUnwrap(HTMLSourceMap(source: source))
        // A page whose whole body a script replaced: nothing on either side
        // can find the other within the window.
        let tags = ["html", "head", "body", "section", "article", "aside", "figure"]
        for index in tags.indices {
            XCTAssertNil(map.range(ofElementAt: index, tagNames: tags),
                         "\(tags[index]) is not the file's, and guessing would be worse")
        }
    }

    func testAskingPastTheEndOfEitherSequenceIsNothing() throws {
        let map = try XCTUnwrap(HTMLSourceMap(source: "<p>a</p>"))
        XCTAssertNil(map.range(ofElementAt: 3, tagNames: ["p"]))
        XCTAssertNil(map.range(ofElementAt: -1, tagNames: ["p"]))
        XCTAssertNil(map.range(ofElementAt: 1, tagNames: ["p", "p"]),
                     "the DOM has a second paragraph and the file has one")
    }

    // MARK: - A page the tokeniser will not read

    func testAPageTheWalkerRefusesHasNoMapAtAll() throws {
        XCTAssertNil(HTMLSourceMap(source: "<p>hi</p><!-- never closed"),
                     "an unterminated comment")
        XCTAssertNil(HTMLSourceMap(source: "<p class=\"never closed>hi</p>"),
                     "an unclosed quote")
        XCTAssertNil(HTMLSourceMap(source: String(repeating: "<div>", count: 300)),
                     "nesting past the depth limit")
        XCTAssertNil(HTMLSourceMap(source: "<p>hi</p><script>never()"),
                     "a raw-text element with no end tag")
    }

    // MARK: - Helpers

    private func range(of text: String, in source: String) -> NSRange {
        (source as NSString).range(of: text)
    }
}
