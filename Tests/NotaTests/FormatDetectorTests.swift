import XCTest
@testable import Nota

/// The second opinion about what a note is holding: one positive per format,
/// and — the half that matters more — the negatives, since an offer that is
/// wrong is worse than no offer at all.
final class FormatDetectorTests: XCTestCase {

    // MARK: - One positive per format

    func testJSONIsDetectedWhenItParses() {
        let text = """
        {
          "name": "nota",
          "version": "1.1.1",
          "tags": ["editor", "macos"]
        }
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.json))
    }

    func testAnArrayIsJSONToo() {
        let text = """
        [
          {"id": 1, "name": "Ada"},
          {"id": 2, "name": "Grace"}
        ]
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.json))
    }

    func testBracesThatDoNotParseAreNotJSON() {
        let text = """
        {
          this is a note about the shape of a config file,
          not a config file: there are no quotes anywhere
        }
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    func testXMLIsDetectedByItsProlog() {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <catalog>
          <book id="1"><title>Nota</title></book>
        </catalog>
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.xml))
    }

    func testAnXMLDocumentWithNoPrologIsStillXML() {
        let text = """
        <catalog>
          <book id="1"><title>Nota</title></book>
          <book id="2"><title>Notes</title></book>
        </catalog>
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.xml))
    }

    func testSVGIsDetectedByItsRootTag() {
        let text = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <circle cx="50" cy="50" r="40" fill="tomato" />
        </svg>
        """
        XCTAssertEqual(FormatDetector.detect(text), .svg)
    }

    /// A drawing written by a real editor opens with an XML prolog, and the
    /// prolog is not the answer: the root element is.
    func testADrawingWithAnXMLPrologIsStillSVG() {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <rect width="100" height="100" fill="black" />
        </svg>
        """
        XCTAssertEqual(FormatDetector.detect(text), .svg)
    }

    func testHTMLIsDetectedByItsDoctype() {
        let text = """
        <!DOCTYPE html>
        <html>
          <body><p>Hello from a page.</p></body>
        </html>
        """
        XCTAssertEqual(FormatDetector.detect(text), .html)
    }

    func testAFragmentOfThreeDifferentPageTagsIsHTML() {
        let text = """
        <div class="card">
          <h1>Nota</h1>
          <p>A small editor.</p>
        </div>
        """
        XCTAssertEqual(FormatDetector.detect(text), .html)
    }

    func testLaTeXIsDetectedByItsDocumentClass() {
        let text = """
        \\documentclass{article}
        \\begin{document}
        Hello, paper.
        \\end{document}
        """
        XCTAssertEqual(FormatDetector.detect(text), .latex)
    }

    func testThreeBackslashCommandsAreLaTeXWithNoPreamble() {
        let text = """
        \\section{Results}
        \\emph{Nothing} conclusive yet.
        \\textbf{But} the shape is right.
        \\label{sec:results}
        """
        XCTAssertEqual(FormatDetector.detect(text), .latex)
    }

    func testADumpIsDetectedByItsStatements() {
        let text = """
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO users VALUES (1, 'Ada');
        INSERT INTO users VALUES (2, 'Grace');
        """
        XCTAssertEqual(FormatDetector.detect(text), .sql)
    }

    func testTOMLNeedsASectionAndItsKeys() {
        let text = """
        [package]
        name = "nota"
        version = "1.1.1"
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.toml))
    }

    func testYAMLIsDetectedByItsMappingLines() {
        let text = """
        name: nota
        version: 1.1.1
        tags:
          - editor
          - macos
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.yaml))
    }

    func testADocumentMarkerIsEnoughForYAML() {
        let text = """
        ---
        one thing after another, written out at enough length to be worth
        looking at in the first place
        """
        XCTAssertEqual(FormatDetector.detect(text), .tree(.yaml))
    }

    func testCSVNeedsThreeEvenRecords() {
        let text = """
        name,role,city
        Ada,engineer,London
        Grace,admiral,Arlington
        """
        XCTAssertEqual(FormatDetector.detect(text), .csv)
    }

    func testTabsAreATableToo() {
        let text = "name\trole\ncity\tLondon\nname\tAda\n"
        XCTAssertEqual(FormatDetector.detect(text), .csv)
    }

    func testMarkdownNeedsTwoDifferentSignals() {
        let text = """
        # Nota

        A small editor, and this is what it does.

        - it opens
        - it closes
        """
        XCTAssertEqual(FormatDetector.detect(text), .markdown)
    }

    func testAFenceAndALinkAreMarkdownToo() {
        let text = """
        Read the [notes](https://example.com/notes) first.

        ```
        swift build
        ```
        """
        XCTAssertEqual(FormatDetector.detect(text), .markdown)
    }

    func testTaskBoxesAndAQuoteAreMarkdown() {
        let text = """
        > What is left to do, in the order it matters.

        - [ ] the badge
        - [x] the detector
        """
        XCTAssertEqual(FormatDetector.detect(text), .markdown)
    }

    // MARK: - The negatives

    /// The one every "smart" detector gets wrong: a sentence with a colon in
    /// it is not a YAML file.
    func testProseWithAColonIsNotYAML() {
        let text = """
        Note: the meeting moved to Thursday.

        I told Ada about it and she said she would bring the slides
        along with the printed agenda for everybody else.
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    /// One signal is never enough. A shopping list is dashes and nothing
    /// else, and it is a note, not a document.
    func testAShoppingListIsNotMarkdown() {
        let text = """
        - milk
        - bread
        - a jar of the good olives from the corner shop
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    func testHeadingsAloneAreNotEnough() {
        let text = """
        # Monday

        # Tuesday

        # Wednesday
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    /// Under the minimum nothing is looked at, however plainly it reads —
    /// the first characters of a note are not a document yet.
    func testAShortSnippetIsNotLookedAt() {
        XCTAssertNil(FormatDetector.detect("{\"a\": 1}"))
        XCTAssertNil(FormatDetector.detect("# hi"))
        XCTAssertNil(FormatDetector.detect(""))
        XCTAssertNil(FormatDetector.detect("   \n\n  "))
    }

    /// The same JSON, once it is long enough to be worth a look.
    func testTheSameSnippetIsJSONOnceItIsLongEnough() {
        let text = "{\"a\": 1, \"b\": 2, \"c\": 3, \"d\": 4, \"e\": 5, \"f\": 6, \"g\": 7, \"h\": 8}"
        XCTAssertGreaterThanOrEqual(text.count, FormatDetector.minimumCharacters)
        XCTAssertEqual(FormatDetector.detect(text), .tree(.json))
    }

    func testPlainParagraphsAreNothing() {
        let text = """
        The window opens on the note you were last reading. Everything else
        is where you left it and nothing asks you a question on the way in.
        That is the whole of it.
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    /// One comma in one sentence is not a table: a table has the same number
    /// of fields on every line of it.
    func testRaggedCommasAreNotATable() {
        let text = """
        We met on Tuesday, which was later than planned.
        Nothing was decided.
        Ada is writing it up.
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    /// A single `SELECT` in a sentence about a query is a sentence.
    func testOneSQLKeywordIsNotADump() {
        let text = """
        SELECT is the only statement worth remembering here, and even that
        one has more spellings than anybody needs on a Tuesday afternoon.
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    /// A single `<div>` in a paragraph of prose is prose.
    func testOnePageTagIsNotAPage() {
        let text = """
        Wrap the whole thing in a <div> and the layout stops arguing with
        itself, which is the only reason anybody ever does it.
        """
        XCTAssertNil(FormatDetector.detect(text))
    }

    /// Keys with no table over them are an ini file, or a note, or anything
    /// at all — not TOML.
    func testKeysWithNoSectionAreNotTOML() {
        let text = """
        width = 80
        height = 24
        """
        XCTAssertNil(FormatDetector.detect(text))
    }
}
