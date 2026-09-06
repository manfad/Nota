import XCTest

@testable import Nota

/// The walker behind the `.html` tab's corner button. Everything here is the
/// text and nothing but the text: no WebKit and no XML parser, so what the
/// author wrote comes back spelled the way they wrote it, down to the order of
/// the attributes and the quotes around them.
///
/// Every literal in this file is ASCII on purpose — the characters outside it
/// are spelled `\u{...}`, which is Swift's escape and not HTML's, so what
/// reaches the walker is the real character and not an entity.
final class HTMLFormatTests: XCTestCase {

    // MARK: - Every token kind

    func testTheDoctypeIsWrittenBackExactlyAsItWasSpelled() throws {
        let source = "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\"><p>hi</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN">
            <p>hi</p>
            """
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testCommentsAreKeptWhole() throws {
        // A comment may be a conditional or a licence, and which is which is
        // not the formatter's call.
        let source = "<div><!-- [if IE]> <b>x</b> <![endif] --><p>a</p></div>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <div>
              <!-- [if IE]> <b>x</b> <![endif] -->
              <p>a</p>
            </div>
            """,
            "the markup inside a comment is text, and the comment gets its own line"
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testABogusCommentAndAProcessingInstructionSurvive() throws {
        let source = "<!foo><?php echo 1; ?><p>a</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <!foo>
            <?php echo 1; ?>
            <p>a</p>
            """
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testEveryAttributeFormIsLeftAlone() throws {
        // Double-quoted, single-quoted, unquoted, valueless, and a `>` living
        // inside a quoted value.
        let source = "<input type=\"text\" name='n' value=raw disabled data-q=\"a>b\">"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source)
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testAttributeOrderAndSpellingAreNeverRewritten() throws {
        let source = "<a CLASS=\"b\" id='x' href=/docs data-n=1>go</a>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .minified), source,
            "sorting the attributes or normalising the quotes would be a different page"
        )
    }

    func testATagBrokenOverSeveralLinesKeepsItsOwnWhitespace() throws {
        // Whitespace *inside* a tag is the author's way of keeping a long tag
        // readable, and is not whitespace between tags.
        let source = "<div\n  class=\"a\"\n  id=\"b\"><p>x</p></div>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            "<div\n  class=\"a\"\n  id=\"b\">\n  <p>x</p>\n</div>"
        )
    }

    func testASelfClosingTagStaysSelfClosing() throws {
        let source = "<div><svg viewBox=\"0 0 8 8\"/><span/>t</div>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <div>
              <svg viewBox="0 0 8 8"/>
              <span/>t
            </div>
            """,
            "a self-closing tag is a leaf: nothing after it is inside it"
        )
    }

    func testALoneLessThanIsText() throws {
        let source = "<p>a < b and 3<4</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty), source,
            "a browser reads those as text, and so does the walker"
        )
    }

    func testEntitiesAreNeverResolved() throws {
        let source = "<p>&amp; &nbsp; &#169; &lt;div&gt; &notanentity;</p>"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source)
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testTagNamesKeepTheirCase() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<DIV><P>Hi</P></DIV>", as: .pretty),
            """
            <DIV>
              <P>Hi</P>
            </DIV>
            """,
            "the walker folds case to decide what a tag is; the page keeps its spelling"
        )
    }

    // MARK: - Void elements

    func testVoidElementsNeverNest() throws {
        let source = "<div><hr><img src=\"a.png\" alt=\"a\"><br><input value=\"x\"></div>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <div>
              <hr>
              <img src="a.png" alt="a"><br><input value="x">
            </div>
            """,
            "hr is a block of its own; img, br and input stay in the line with their text"
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testBrIsALineBreakInTheTextAndNotABlock() throws {
        let source = "<p>one<br>two</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty), source,
            "pulling br onto its own line would put a space where the page had none"
        )
    }

    func testAnEndTagForAVoidElementIsStray() throws {
        let source = "<p>a<br></br>b</p>"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source)
    }

    // MARK: - Raw-text elements

    func testAScriptKeepsEverythingIncludingATagInsideAString() throws {
        let source = "<body><script>if (a < b) { write(\"</div>\") }</script></body>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <body>
              <script>if (a < b) { write("</div>") }</script>
            </body>
            """,
            "a </div> inside a script is a string in a program, not a tag"
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testAScriptsOwnIndentationIsNeverTouched() throws {
        let source = "<head>\n<script>\n  var a = 1;\n\n  var b = 2;\n</script>\n</head>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            "<head>\n  <script>\n  var a = 1;\n\n  var b = 2;\n</script>\n</head>",
            "the content is bytes: the tags move to their line, the program does not"
        )
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .minified),
            "<head><script>\n  var a = 1;\n\n  var b = 2;\n</script></head>",
            "minified is one line unless a raw-text element carries newlines"
        )
    }

    func testAStyleBlockIsKeptByteForByte() throws {
        let source = "<head><style>\nbody { color: #eee }\na > b { margin: 0 }\n</style></head>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            "<head>\n  <style>\nbody { color: #eee }\na > b { margin: 0 }\n</style>\n</head>",
            "a `>` in a selector is CSS, not a tag"
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testPreKeepsItsLeadingSpaces() throws {
        let source = "<div>\n  <pre>   indented\n     further  </pre>\n</div>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            "<div>\n  <pre>   indented\n     further  </pre>\n</div>",
            "a newline added after <pre> changes what the page shows"
        )
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .minified),
            "<div><pre>   indented\n     further  </pre></div>"
        )
    }

    func testTextareaAndTitleKeepTheirContentAndStayInTheLine() throws {
        let source = "<head><title>  Nota  </title></head><body><label>Name"
            + " <textarea rows=\"2\">  keep\n  me </textarea></label></body>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            "<head><title>  Nota  </title></head>\n"
                + "<body><label>Name <textarea rows=\"2\">  keep\n  me </textarea></label></body>"
        )
    }

    func testABlockWhoseContentIsAllInlineStaysOnOneLine() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<body><p>Hello <b>there</b></p></body>", as: .pretty),
            """
            <body>
              <p>Hello <b>there</b></p>
            </body>
            """,
            "the p starts a line of its own, and its text has no reason to leave it"
        )
        XCTAssertEqual(
            try HTMLFormat.reformat("<head><title>t</title></head>", as: .pretty),
            "<head><title>t</title></head>",
            "with nothing but inline content inside, the head is that one line"
        )
    }

    func testARawElementThatIsSelfClosingIsALeaf() throws {
        // `<style/>` swallowing the rest of the file would be a worse answer
        // than treating the slash the author wrote as the end of the element.
        XCTAssertEqual(
            try HTMLFormat.reformat("<head><style/></head><body><p>a</p></body>", as: .minified),
            "<head><style/></head><body><p>a</p></body>"
        )
    }

    // MARK: - Blocks, inline runs and text

    func testInlineElementsStayInTheLineWithTheirText() throws {
        let source = "<p>The <b>quick</b> <i>brown</i> <a href=\"#\">fox</a> jumps.</p>"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source)
    }

    func testRunsOfWhitespaceCollapseButWordsAreNeverJoinedOrSplit() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<p>one\n   two\tthree    four</p>", as: .pretty),
            "<p>one two three four</p>"
        )
    }

    func testWhitespaceInsideAnInlineElementIsLeftWhereItIs() throws {
        // `<span>a </span><span>b</span>` renders with a space between the
        // words and `<span>a</span><span>b</span>` does not, so the space is
        // text and stays.
        let source = "<div><span>a </span><span>b</span></div>"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source)
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testANoBreakSpaceIsACharacterAndNotLayout() throws {
        let source = "<p>\u{a0}a\u{a0}b\u{a0}</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .minified), source,
            "trimming the run must not eat a space the author typed as a character"
        )
    }

    func testTextIsTrimmedWhereItMeetsABlockTag() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<div>  \n  <p>  hi  </p>  \n  </div>", as: .pretty),
            """
            <div>
              <p>hi</p>
            </div>
            """
        )
    }

    func testAnEmptyBlockElementStaysOnOneLine() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<div></div><section>   </section>", as: .pretty),
            """
            <div></div>
            <section></section>
            """,
            "a pair of tags opened and closed over three lines is noise"
        )
    }

    func testABlockInsideAnInlineElementDoesNotBreakTheLine() throws {
        let source = "<p>see <a href=\"#\"><div class=\"card\">x</div></a> now</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty), source,
            "inside an inline run everything is inline, however the tag is classified"
        )
    }

    func testTheHeadReadsAsOneThingPerLine() throws {
        let source = "<head><meta charset=\"utf-8\"><link rel=\"icon\" href=\"i.png\">"
            + "<title>Nota</title></head>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <head>
              <meta charset="utf-8">
              <link rel="icon" href="i.png">
              <title>Nota</title>
            </head>
            """
        )
    }

    func testATableNestsByItsRowsAndCells() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<table><tr><td>1</td><td>2</td></tr></table>", as: .pretty),
            """
            <table>
              <tr>
                <td>1</td>
                <td>2</td>
              </tr>
            </table>
            """
        )
    }

    // MARK: - What HTML forgives

    func testAStrayEndTagIsEmittedWhereItStands() throws {
        let source = "<div>a</div></section><p>b</p>"
        XCTAssertEqual(
            try HTMLFormat.reformat(source, as: .pretty),
            """
            <div>a</div>
            </section>
            <p>b</p>
            """,
            "HTML is forgiving; a tag nobody opened is not an error"
        )
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testAMismatchedEndTagClosesWhatItCanAndAddsNothing() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<div><b>bold</div>", as: .minified), "<div><b>bold</div>",
            "the b closes with the div, silently, without gaining an end tag it never had"
        )
    }

    func testAnElementLeftOpenAtTheEndOfTheFileIsWrittenBackOpen() throws {
        XCTAssertEqual(
            try HTMLFormat.reformat("<div><p>a", as: .pretty),
            """
            <div>
              <p>a
            """
        )
    }

    func testNestingUpToTheDepthLimitIsAPage() throws {
        let deep = String(repeating: "<div>", count: 256) + "x"
        XCTAssertNil(HTMLFormat.errorLine(in: deep))
    }

    // MARK: - The two shapes agree

    func testBeautifyingThenMinifyingGivesWhatMinifyingAloneGives() throws {
        let sources = [
            "<div>  <p>Hello   <b>there</b> friend</p>  </div>",
            "<!DOCTYPE html><html><head><title>t</title></head><body><p>a</p></body></html>",
            "<ul>\n  <li>one</li>\n  <li>two</li>\n</ul>\n",
            "<div><span>a </span><p>x</p></div>",
            "<div>a</div></section><p>b</p>",
            "<p>text<br>more</p><pre>  raw\n  raw </pre>",
            "text <b>bold</b> tail",
        ]
        for source in sources {
            let pretty = try HTMLFormat.reformat(source, as: .pretty)
            XCTAssertEqual(
                try HTMLFormat.reformat(pretty, as: .minified),
                try HTMLFormat.reformat(source, as: .minified),
                source
            )
        }
    }

    func testBeautifyingAPrettyPageChangesNothing() throws {
        let sources = [
            "<div>\n  <p>Hello <b>there</b></p>\n</div>",
            "<!DOCTYPE html>\n<html>\n  <head>\n    <meta charset=\"utf-8\">\n"
                + "    <title>t</title>\n  </head>\n</html>",
            "<table>\n  <tr>\n    <td>1</td>\n  </tr>\n</table>",
        ]
        for source in sources {
            XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source, source)
        }
    }

    func testMinifyingAMinifiedPageChangesNothing() throws {
        let source = "<div><p>a <b>b</b></p><hr><p>c</p></div>"
        let minified = try HTMLFormat.reformat(source, as: .minified)
        XCTAssertEqual(minified, source)
        XCTAssertEqual(try HTMLFormat.reformat(minified, as: .minified), minified)
    }

    func testTheFilesTrailingNewlineIsKept() throws {
        XCTAssertEqual(try HTMLFormat.reformat("<p>a</p>\n", as: .minified), "<p>a</p>\n")
        XCTAssertTrue(
            try HTMLFormat.reformat("<div><p>a</p></div>\n", as: .pretty).hasSuffix("</div>\n"),
            "reformatting is not the moment to take the last line ending off a file"
        )
        XCTAssertFalse(try HTMLFormat.reformat("<p>a</p>", as: .minified).hasSuffix("\n"))
    }

    func testAnEmptyFileIsAPage() throws {
        XCTAssertEqual(try HTMLFormat.reformat("", as: .pretty), "")
        XCTAssertEqual(try HTMLFormat.reformat("  \n", as: .minified), "\n")
        XCTAssertNil(HTMLFormat.errorLine(in: ""))
    }

    // MARK: - Text outside ASCII

    func testTextOutsideASCIIIsUntouched() throws {
        // Three CJK characters, an emoji, an em dash and a lightning bolt.
        let source = "<p>\u{65e5}\u{672c}\u{8a9e} \u{1f389} \u{2014} \u{26a1}"
            + " <b>\u{e9}t\u{e9}</b></p>"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .pretty), source)
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    func testAnAttributeValueOutsideASCIISurvives() throws {
        let source = "<img src=\"\u{1f389}.png\" alt=\"\u{7b46}\u{8a18}\">"
        XCTAssertEqual(try HTMLFormat.reformat(source, as: .minified), source)
    }

    // MARK: - Which way the button points

    func testAMinifiedPageIsNotPretty() {
        XCTAssertFalse(HTMLFormat.isPretty("<div><p>a</p><p>b</p></div>"))
    }

    func testALaidOutPageIsPretty() {
        XCTAssertTrue(HTMLFormat.isPretty("<div>\n  <p>a</p>\n</div>"))
    }

    func testTheFilesTrailingNewlineIsNotALayout() {
        XCTAssertFalse(
            HTMLFormat.isPretty("<div><p>a</p></div>\n"),
            "every well-kept text file ends in one; it says nothing about the shape"
        )
        XCTAssertFalse(HTMLFormat.isPretty("<div><p>a</p></div>\n\n"))
    }

    func testANewlineInsideATagIsNotALayout() {
        XCTAssertFalse(
            HTMLFormat.isPretty("<div\n  class=\"a\"\n  id=\"b\"><p>x</p></div>"),
            "that is a long tag kept readable, not a page laid out in lines"
        )
    }

    func testANewlineInsideACommentIsNotALayout() {
        XCTAssertFalse(HTMLFormat.isPretty("<!--\n  a note\n--><p>a</p>"))
    }

    func testANewlineInsideARawTextElementIsNotALayout() {
        XCTAssertFalse(
            HTMLFormat.isPretty("<script>\nvar a = 1\n</script>"),
            "that newline belongs to the program, not to the page's shape"
        )
        XCTAssertFalse(HTMLFormat.isPretty("<pre>\na\n</pre>"))
        XCTAssertFalse(HTMLFormat.isPretty("<style>\na { }\n</style>"))
    }

    func testWhatTheButtonSaysAboutItsOwnAnswers() throws {
        let source = "<!DOCTYPE html><html><body><p>a</p><p>b</p></body></html>"
        XCTAssertFalse(HTMLFormat.isPretty(source))
        XCTAssertTrue(try HTMLFormat.isPretty(HTMLFormat.reformat(source, as: .pretty)))
        XCTAssertFalse(try HTMLFormat.isPretty(HTMLFormat.reformat(source, as: .minified)))
    }

    // MARK: - Where the walk gives up

    func testAnUnterminatedCommentNamesTheLineItOpenedOn() {
        XCTAssertEqual(HTMLFormat.errorLine(in: "<p>a</p>\n<!-- open\nstill open\n"), 2)
    }

    func testAnUnterminatedTagNamesTheLineItOpenedOn() {
        XCTAssertEqual(HTMLFormat.errorLine(in: "<body>\n<div class=x\n"), 2)
    }

    func testAnUnterminatedQuotedAttributeNamesTheLineItOpenedOn() {
        XCTAssertEqual(
            HTMLFormat.errorLine(in: "<p>hi</p>\n<div class=\"x>\n<p>y</p>\n"), 2,
            "the value swallows the rest of the file looking for its closing quote"
        )
    }

    func testARawTextElementThatNeverClosesNamesTheLineItOpenedOn() {
        XCTAssertEqual(HTMLFormat.errorLine(in: "<body>\n<script>\nvar a = 1\n"), 2)
        XCTAssertEqual(HTMLFormat.errorLine(in: "<p>a</p>\n\n<style>\nb { }\n"), 3)
    }

    func testAnUnterminatedEndTagIsAnError() {
        XCTAssertEqual(HTMLFormat.errorLine(in: "<div>a\n</div"), 2)
    }

    func testNestingPastTheDepthLimitIsAnError() {
        let tooDeep = "<body>\n" + String(repeating: "<div>", count: 257)
        XCTAssertEqual(
            HTMLFormat.errorLine(in: tooDeep), 2,
            "a file made of ten thousand open divs is a crash rather than a page"
        )
    }

    func testAPageThatReadsHasNoErrorLine() {
        XCTAssertNil(HTMLFormat.errorLine(in: "<!DOCTYPE html>\n<p>a < b</p>\n</stray>\n<div>"))
    }

    func testReformattingRefusesWhatWillNotParse() {
        XCTAssertThrowsError(try HTMLFormat.reformat("<p>a</p>\n<!-- open\n", as: .pretty)) {
            error in
            XCTAssertEqual(error as? HTMLFormat.ParseError, HTMLFormat.ParseError(line: 2))
        }
    }

    // MARK: - A whole page

    /// A page with everything on it, shipped as one minified line: the first
    /// click in the corner is Beautify, and the second has to give the bytes
    /// back.
    func testARealisticPageGoesBothWays() throws {
        let source = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            + "<title>Nota</title><style>body { color: #eee }</style></head><body>"
            + "<!-- the chrome --><nav><ul><li><a href=\"/\">Home</a></li>"
            + "<li><a href=\"/docs\" class=\"active\">Docs &amp; more</a></li></ul></nav>"
            + "<main><h1>Notes</h1><p>Open a file and it <b>just</b> opens.</p>"
            + "<table><thead><tr><th>Key</th><th>Does</th></tr></thead>"
            + "<tbody><tr><td>\u{2318}T</td><td>New tab</td></tr></tbody></table></main>"
            + "<script>if (a < b) { write(\"</p>\") }</script></body></html>\n"

        XCTAssertNil(HTMLFormat.errorLine(in: source))
        XCTAssertFalse(HTMLFormat.isPretty(source), "the page ships as one line")

        let pretty = try HTMLFormat.reformat(source, as: .pretty)
        XCTAssertEqual(
            pretty,
            """
            <!DOCTYPE html>
            <html lang="en">
              <head>
                <meta charset="utf-8">
                <title>Nota</title>
                <style>body { color: #eee }</style>
              </head>
              <body>
                <!-- the chrome -->
                <nav>
                  <ul>
                    <li><a href="/">Home</a></li>
                    <li><a href="/docs" class="active">Docs &amp; more</a></li>
                  </ul>
                </nav>
                <main>
                  <h1>Notes</h1>
                  <p>Open a file and it <b>just</b> opens.</p>
                  <table>
                    <thead>
                      <tr>
                        <th>Key</th>
                        <th>Does</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr>
                        <td>\u{2318}T</td>
                        <td>New tab</td>
                      </tr>
                    </tbody>
                  </table>
                </main>
                <script>if (a < b) { write("</p>") }</script>
              </body>
            </html>

            """
        )
        XCTAssertTrue(HTMLFormat.isPretty(pretty))
        XCTAssertEqual(
            try HTMLFormat.reformat(pretty, as: .minified), source,
            "one line and the file's own trailing newline, as it shipped"
        )
        XCTAssertEqual(try HTMLFormat.reformat(pretty, as: .pretty), pretty)
    }
}
