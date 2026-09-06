import AppKit
import XCTest
@testable import Nota

/// The tree previews: the two parsers written alongside this file (`JSONTree`
/// and `XMLTree`), the view that draws whatever any of the four hands back,
/// and the modes a structured tab has like every other rendered one.
final class StructuredPreviewTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    /// The pane holds its note weakly, the way the column does — so a test
    /// that made one has to keep it alive itself.
    private var heldNotes: [Note] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        heldNotes = []
    }

    // MARK: - JSON into a tree

    func testAnObjectKeepsItsKeysInFileOrder() throws {
        let document = try JSONTree.parse(#"{"b":1,"a":2,"c":3}"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.value, .object)
        XCTAssertEqual(root.children.map(\.key), ["b", "a", "c"])
    }

    func testDuplicateKeysAreBothKept() throws {
        let document = try JSONTree.parse(#"{"a":1,"a":2}"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.count, 2, "a reader shows the file, not a dictionary")
        XCTAssertEqual(root.children.map(\.value), [.number("1"), .number("2")])
    }

    func testAnArraysItemsHaveNoKeys() throws {
        let document = try JSONTree.parse(#"[1,"two",true,null]"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.value, .array)
        XCTAssertEqual(root.children.map(\.key), [nil, nil, nil, nil])
        XCTAssertEqual(root.children.map(\.value),
                       [.number("1"), .string("two"), .bool(true), .null])
    }

    func testNumbersAreKeptExactlyAsSpelled() throws {
        let document = try JSONTree.parse(#"[1.50,-0,1e10,2E-3,0.0]"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.map(\.value),
                       [.number("1.50"), .number("-0"), .number("1e10"),
                        .number("2E-3"), .number("0.0")])
    }

    func testStringsAreUnescapedForDisplay() throws {
        let document = try JSONTree.parse(#"["a\nb","\u00e9","q\"q","\\","\/"]"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.map(\.value), [
            .string("a\nb"), .string("é"), .string("q\"q"), .string("\\"), .string("/"),
        ])
    }

    func testASurrogatePairBecomesOneCharacter() throws {
        let document = try JSONTree.parse(#"["\uD83D\uDE00"]"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.first?.value, .string("😀"))
    }

    func testEmptyContainersAreBranchesWithNothingInThem() throws {
        let document = try JSONTree.parse(#"{"a":{},"b":[]}"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.map(\.value), [.object, .array])
        XCTAssertTrue(root.children.allSatisfy { $0.children.isEmpty })
        XCTAssertTrue(root.children.allSatisfy(\.isBranch))
    }

    func testNestingIsKept() throws {
        let document = try JSONTree.parse(#"{"a":{"b":[{"c":1}]}}"#)
        let a = try XCTUnwrap(document.roots.first?.children.first)
        let b = try XCTUnwrap(a.children.first)
        XCTAssertEqual(b.key, "b")
        XCTAssertEqual(b.value, .array)
        let item = try XCTUnwrap(b.children.first)
        XCTAssertNil(item.key, "an array's items are numbered, not named")
        XCTAssertEqual(item.children.first?.key, "c")
    }

    /// The member is written down at its key: that is where the reader's eye
    /// is, and where a click on its row goes.
    func testEveryNodeCarriesTheLineItStartsOn() throws {
        let source = """
        {
          "a": 1,
          "b": {
            "c": [
              2
            ]
          }
        }
        """
        let root = try XCTUnwrap(try JSONTree.parse(source).roots.first)
        XCTAssertEqual(root.line, 1)
        XCTAssertEqual(root.children[0].line, 2, "\"a\"")
        let b = root.children[1]
        XCTAssertEqual(b.line, 3)
        XCTAssertEqual(b.children[0].line, 4, "\"c\"")
        XCTAssertEqual(b.children[0].children[0].line, 5, "the 2 inside it")
    }

    /// A click on a row selects the node, so a node carries the whole span it
    /// was written on and not only the line it began: a member from its key
    /// through the end of its value, a branch through its closing bracket.
    func testEveryJSONNodeCarriesItsWholeSpan() throws {
        let text = """
        {
          "a": 1,
          "b": [true, null]
        }
        """
        let root = try XCTUnwrap(try JSONTree.parse(text).roots.first)
        XCTAssertEqual(source(text, root.range), text, "the root is its own brackets")
        XCTAssertEqual(source(text, root.children[0].range), #""a": 1"#)
        XCTAssertEqual(source(text, root.children[1].range), #""b": [true, null]"#)
        XCTAssertEqual(source(text, root.children[1].children[0].range), "true")
        XCTAssertEqual(source(text, root.children[1].children[1].range), "null")
    }

    /// The walk counts UTF-8 bytes and the editor counts UTF-16 units, so a
    /// file with a `名` and an emoji in front of a node is the one that proves
    /// the span was converted rather than copied. An emoji is four bytes and
    /// two UTF-16 units; `名` is three bytes and one.
    func testASpanIsCountedTheWayTheEditorCounts() throws {
        let text = #"{"名字": "😀", "after": [1]}"#
        let root = try XCTUnwrap(try JSONTree.parse(text).roots.first)
        XCTAssertEqual(source(text, root.children[0].range), #""名字": "😀""#)
        XCTAssertEqual(source(text, root.children[1].range), #""after": [1]"#)
        XCTAssertEqual(source(text, root.children[1].children[0].range), "1")
    }

    /// The whole point of a span: a compact file is one line, so the line
    /// alone would say nothing about where a node is.
    func testACompactFilesNodesStillHaveTheirOwnSpans() throws {
        let text = #"{"a":{"b":[1,2]},"c":"d"}"#
        let root = try XCTUnwrap(try JSONTree.parse(text).roots.first)
        XCTAssertEqual(source(text, root.children[0].range), #""a":{"b":[1,2]}"#)
        XCTAssertEqual(source(text, root.children[0].children[0].range), #""b":[1,2]"#)
        XCTAssertEqual(source(text, root.children[1].range), #""c":"d""#)
    }

    /// A row says `name  "Nota"`, and `"Nota"` is what the reader points at:
    /// a leaf carries its value's own span beside the whole member's, quotes
    /// and all, because they are the value's characters in the file.
    func testALeafCarriesItsValuesOwnSpan() throws {
        let text = #"{"名字": "😀 Nota", "n": 14, "ok": true, "gone": null, "list": [1]}"#
        let root = try XCTUnwrap(try JSONTree.parse(text).roots.first)
        XCTAssertEqual(value(text, root.children[0]), #""😀 Nota""#)
        XCTAssertEqual(value(text, root.children[1]), "14")
        XCTAssertEqual(value(text, root.children[2]), "true")
        XCTAssertEqual(value(text, root.children[3]), "null")
        XCTAssertEqual(value(text, root.children[4]), "[1]",
                       "a branch's value part is its brackets, which is not what a click on "
                           + "it gives")
        XCTAssertEqual(source(text, root.children[0].range), #""名字": "😀 Nota""#,
                       "the whole member is still there, key and all")
    }

    func testEachKindOfFailureNamesItsLineAndSaysWhy() throws {
        let cases: [(String, Int, String)] = [
            ("", 1, "Empty file"),
            ("{\n  \"a\": 1,\n  \"b\" 2\n}\n", 3, "Expected `:`"),
            ("{\n  \"a\": 1,\n}\n", 3, "Expected a key"),
            ("[1,\n2\n", 3, "Unexpected end of file"),
            ("{\"a\":1}\n{\"b\":2}\n", 2, "Extra content after the document"),
            ("[\n  01\n]\n", 2, "Expected `,` or `]`"),
            ("[\n  \"a\n]\n", 2, "Control character in a string"),
            ("[\n  \"\\q\"\n]\n", 2, "Invalid escape"),
            ("[\n  \"\\u00zz\"\n]\n", 2, "Invalid `\\u` escape"),
            ("[\n  tru\n]\n", 2, "Expected a value"),
        ]
        for (source, line, message) in cases {
            XCTAssertThrowsError(try JSONTree.parse(source), source) { error in
                XCTAssertEqual(error as? StructuredParseError,
                               StructuredParseError(line: line, message: message), source)
            }
        }
    }

    func testNestingPastTheLimitIsRefusedRatherThanCrashing() throws {
        let source = String(repeating: "[", count: 400) + String(repeating: "]", count: 400)
        XCTAssertThrowsError(try JSONTree.parse(source)) { error in
            XCTAssertEqual((error as? StructuredParseError)?.message, "Nested too deeply")
        }
    }

    // MARK: - XML into a tree

    func testAnElementIsAnObjectKeyedByItsName() throws {
        let document = try XMLTree.parse("<root><child/></root>")
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.key, "root")
        XCTAssertEqual(root.value, .object)
        XCTAssertEqual(root.children.first?.key, "child")
    }

    func testAttributesComeFirstSpelledWithAnAtSign() throws {
        let document = try XMLTree.parse(#"<rect x="1" y="2"><inner/></rect>"#)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.map(\.key), ["@x", "@y", "inner"])
        XCTAssertEqual(root.children[0].value, .string("1"))
        XCTAssertEqual(root.children[1].value, .string("2"))
    }

    func testTextRunsAndCDATAAreTextAndWhitespaceIsDropped() throws {
        let document = try XMLTree.parse("""
        <root>
          <a>  hello  </a>
          <b><![CDATA[raw < text]]></b>
          <c>
          </c>
        </root>
        """)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.children.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(root.children[0].children.map(\.value), [.text("hello")],
                       "trimmed at both ends")
        XCTAssertEqual(root.children[1].children.map(\.value), [.text("raw < text")])
        XCTAssertTrue(root.children[2].children.isEmpty,
                      "a pretty-printed file's indentation is layout, not content")
    }

    func testACommentIsItsOwnNodeInsideAndBesideTheRoot() throws {
        let document = try XMLTree.parse("""
        <!-- before -->
        <root>
          <!-- inside -->
          <a/>
        </root>
        """)
        XCTAssertEqual(document.roots.map(\.value),
                       [.comment("before"), .object])
        XCTAssertEqual(document.roots[1].children.map(\.value),
                       [.comment("inside"), .object])
    }

    func testAPrefixIsPartOfTheNameAndTheDeclarationIsAnAttribute() throws {
        let document = try XMLTree.parse(
            #"<svg:svg xmlns:svg="http://www.w3.org/2000/svg"><svg:rect/></svg:svg>"#
        )
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.key, "svg:svg")
        XCTAssertEqual(root.children.map(\.key), ["@xmlns:svg", "svg:rect"])
    }

    func testProcessingInstructionsAndTheDoctypeAreSkipped() throws {
        let document = try XMLTree.parse("""
        <?xml version="1.0"?>
        <root><a/></root>
        """)
        XCTAssertEqual(document.roots.count, 1)
        XCTAssertEqual(document.roots.first?.key, "root")
    }

    func testEveryXMLNodeCarriesItsLine() throws {
        let document = try XMLTree.parse("""
        <root>
          <a/>
          <b>text</b>
        </root>
        """)
        let root = try XCTUnwrap(document.roots.first)
        XCTAssertEqual(root.line, 1)
        XCTAssertEqual(root.children[0].line, 2)
        XCTAssertEqual(root.children[1].line, 3)
        XCTAssertEqual(root.children[1].children[0].line, 3, "the run inside it")
    }

    /// The reader says where an event happened and never how wide it was, so
    /// an element's span is its `<` through its `</name>`, an attribute's is
    /// the `name="value"` read back out of the tag, and a CDATA block is the
    /// whole `<![CDATA[…]]>` rather than the text inside it.
    func testEveryXMLNodeCarriesItsWholeSpan() throws {
        let text = """
        <shop open="yes">
          <!-- a note -->
          <item id="1">Pencil</item>
          <empty/>
          <raw><![CDATA[a < b]]></raw>
        </shop>
        """
        let root = try XCTUnwrap(try XMLTree.parse(text).roots.first)
        XCTAssertEqual(source(text, root.range), text)
        XCTAssertEqual(source(text, root.children[0].range), #"open="yes""#)
        XCTAssertEqual(source(text, root.children[1].range), "<!-- a note -->")
        let item = root.children[2]
        XCTAssertEqual(source(text, item.range), #"<item id="1">Pencil</item>"#)
        XCTAssertEqual(source(text, item.children[0].range), #"id="1""#)
        XCTAssertEqual(source(text, item.children[1].range), "Pencil")
        XCTAssertEqual(source(text, root.children[3].range), "<empty/>")
        XCTAssertEqual(source(text, root.children[4].children[0].range), "<![CDATA[a < b]]>")
    }

    /// `XMLParser` counts its columns in Unicode scalars, and an `NSRange` is
    /// counted in UTF-16 units — an emoji is one column and two of those — so
    /// a file with one in front of a node is what proves the conversion.
    func testAnXMLSpanIsCountedTheWayTheEditorCounts() throws {
        let text = "<r>名字😀<a x=\"y\">hi</a></r>"
        let root = try XCTUnwrap(try XMLTree.parse(text).roots.first)
        XCTAssertEqual(source(text, root.children[0].range), "名字😀")
        let a = root.children[1]
        XCTAssertEqual(source(text, a.range), #"<a x="y">hi</a>"#)
        XCTAssertEqual(source(text, a.children[0].range), #"x="y""#)
        XCTAssertEqual(source(text, a.children[1].range), "hi")
    }

    /// A start tag written across lines: the element begins at its `<`, which
    /// is where its line is too, and not at the `>` the reader reports.
    func testAnElementSpansFromItsOpeningAngleBracket() throws {
        let text = "<r>\n  <a\n    x=\"1\"\n    y=\"2\">t</a>\n</r>"
        let root = try XCTUnwrap(try XMLTree.parse(text).roots.first)
        let a = root.children[0]
        XCTAssertEqual(a.line, 2)
        XCTAssertEqual(source(text, a.range), "<a\n    x=\"1\"\n    y=\"2\">t</a>")
        XCTAssertEqual(source(text, a.children[0].range), #"x="1""#)
        XCTAssertEqual(source(text, a.children[1].range), #"y="2""#)
    }

    func testAnXMLAttributeAndTextCarryTheirValues() throws {
        let text = #"<shop note="😀 名" currency="MYR"><item>Pencil</item><!--n--></shop>"#
        let root = try XCTUnwrap(try XMLTree.parse(text).roots.first)
        XCTAssertEqual(root.children.map(\.key), ["@currency", "@note", "item", nil])
        XCTAssertEqual(value(text, root.children[0]), #""MYR""#, "its quotes part of it")
        XCTAssertEqual(source(text, root.children[0].range), #"currency="MYR""#)
        XCTAssertEqual(value(text, root.children[1]), #""😀 名""#)
        XCTAssertEqual(value(text, root.children[2].children[0]), "Pencil")
        XCTAssertEqual(value(text, root.children[3]), "<!--n-->")
        XCTAssertNil(root.children[2].valueRange,
                     "an element is its tags and its body, with no value part to point at")
    }

    func testAnXMLFailureNamesItsLine() throws {
        XCTAssertThrowsError(try XMLTree.parse("<root>\n  <a>\n</root>\n")) { error in
            let failure = error as? StructuredParseError
            XCTAssertEqual(failure?.line, 3)
            XCTAssertFalse(failure?.message.isEmpty ?? true, "and says something about it")
        }
        XCTAssertThrowsError(try XMLTree.parse("")) { error in
            XCTAssertEqual((error as? StructuredParseError)?.line, 1)
        }
    }

    // MARK: - The four tabs and their modes

    func testTheFourStructuredFilesHaveTheThreeModes() throws {
        for name in ["Settings.json", "config.yaml", "config.yml",
                     "Cargo.toml", "feed.xml"] {
            let note = makeNote(named: name, text: "")
            XCTAssertTrue(note.supportsRenderedPreview, name)
            XCTAssertTrue(note.hasPreviewContent, name)
            note.previewMode = .split
            XCTAssertEqual(note.previewMode, .split, name)
            note.previewMode = .reading
            XCTAssertEqual(note.previewMode, .reading, name)
        }
        XCTAssertEqual(makeNote(named: "a.json", text: "").previewKind, .tree(.json))
        XCTAssertEqual(makeNote(named: "a.yml", text: "").previewKind, .tree(.yaml))
        XCTAssertEqual(makeNote(named: "a.toml", text: "").previewKind, .tree(.toml))
        XCTAssertEqual(makeNote(named: "a.xml", text: "").previewKind, .tree(.xml))

        let untitled = Note(fileURL: nil, untitledName: "Untitled", text: "{}",
                            attributes: [:], assets: nil)
        XCTAssertNil(untitled.previewKind, "Save As to .json is what makes one")
    }

    @MainActor
    func testTheTreeIsTheColumnsTenthContent() throws {
        _ = NSApplication.shared
        for name in ["a.json", "a.yaml", "a.toml", "a.xml"] {
            XCTAssertEqual(PreviewContentKind(makeNote(named: name, text: "")), .tree, name)
        }

        let column = PreviewPaneView(dragBandHeight: 12)
        column.bringForward(makeNote(named: "Settings.json", text: "{}"))
        XCTAssertEqual(column.panes.kind, .tree)
        XCTAssertTrue(column.panes.showsTree)
        XCTAssertFalse(column.panes.showsTable, "a tree is not a table")
        XCTAssertFalse(column.panes.tree.isHidden)
        XCTAssertTrue(column.panes.markdown.isHidden)

        column.bringForward(makeNote(named: "notes.txt", text: ""))
        XCTAssertTrue(column.panes.tree.isHidden, "and it waits behind the render again")
    }

    @MainActor
    func testAWindowBringsAJSONTabBackInTheModeItWasLeftIn() throws {
        _ = NSApplication.shared
        let controller = try makeController(
            showing: #"{"a":[1,2]}"#, named: "Settings.json"
        )
        defer { controller.window?.orderOut(nil) }
        XCTAssertEqual(controller.previewMode, .split)
        XCTAssertTrue(controller.canShowRenderedPreview)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .tree(.json))
        XCTAssertTrue(controller.previewPanes.showsTree)
        XCTAssertFalse(controller.previewPanes.tree.visibleRows.isEmpty)
    }

    // MARK: - The tree on screen

    @MainActor
    func testARowShowsItsKeyThenItsValue() throws {
        let pane = try makePane(showing: """
        {
          "name": "Nota",
          "size": 14,
          "vim": false,
          "theme": null
        }
        """)
        XCTAssertEqual(pane.visibleRows.map(\.title), [
            "{4}", "name  \"Nota\"", "size  14", "vim  false", "theme  null",
        ])
        XCTAssertEqual(pane.visibleRows.map(\.indent), [0, 1, 1, 1, 1])
    }

    @MainActor
    func testAnArraysItemsShowTheirIndex() throws {
        let pane = try makePane(showing: #"{"tags":["a","b"]}"#)
        XCTAssertEqual(pane.visibleRows.map(\.title),
                       ["{1}", "tags", "0  \"a\"", "1  \"b\""])
    }

    @MainActor
    func testAClosedBranchSaysHowMuchIsInsideIt() throws {
        let pane = try makePane(showing: #"{"a":{"x":1,"y":2,"z":3},"b":[1,2]}"#)
        XCTAssertEqual(pane.visibleRows.map(\.title).first, "{2}",
                       "the root has no name, so it says its size either way")

        let a = try XCTUnwrap(pane.outline.item(atRow: 1))
        pane.outline.collapseItem(a)
        XCTAssertEqual(pane.visibleRows.map(\.title).dropFirst().first, "a  {3}")

        pane.outline.expandItem(a)
        XCTAssertEqual(pane.visibleRows.map(\.title).dropFirst().first, "a",
                       "an open branch has its members on screen already")
    }

    /// A small document opens whole; a big one opens showing its shape.
    @MainActor
    func testDefaultExpansionFollowsTheDocumentsSize() throws {
        let small = try makePane(showing: #"{"a":{"b":{"c":1}}}"#)
        XCTAssertEqual(small.visibleRows.map(\.indent), [0, 1, 2, 3],
                       "everything, four rows deep")

        var items: [String] = []
        for index in 0..<200 { items.append("{\"k\(index)\":{\"deep\":\(index)}}") }
        let big = try makePane(showing: "[" + items.joined(separator: ",") + "]")
        XCTAssertGreaterThan(big.visibleRows.count, 200)
        XCTAssertEqual(big.visibleRows.map(\.indent).max(), 2,
                       "two levels: the shape, not the contents")
    }

    /// A click selects the member in the source, and leaves the keyboard where
    /// it was — the tree is being walked with the arrows.
    @MainActor
    func testAClickOnARowSelectsTheNodeInTheEditor() throws {
        let controller = try makeController(showing: """
        {
          "a": 1,
          "b": 2
        }
        """, named: "Settings.json")
        defer { controller.window?.orderOut(nil) }
        let pane = controller.previewPanes.tree
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(descendant(of: window.contentView!, ofType: NotaTextView.self))
        window.makeFirstResponder(pane.outline)

        // Row 2 is `"b"`, on line 3 of the file.
        XCTAssertEqual(pane.visibleRows[2].title, "b  2")
        click(row: 2, in: pane)

        XCTAssertEqual(source(editor.string, editor.selectedRange()), "2",
                       "a leaf gives its value and nothing else")
        XCTAssertTrue(window.firstResponder === pane.outline,
                      "the click reveals rather than jumps")
    }

    /// The whole reason a node carries a span: a compact file is one line, so
    /// a click that only knew the line would select the file.
    @MainActor
    func testAClickOnACompactFilesRowSelectsThatMemberAlone() throws {
        let controller = try makeController(
            showing: #"{"a":1,"b":{"c":2}}"#, named: "Settings.json")
        defer { controller.window?.orderOut(nil) }
        let pane = controller.previewPanes.tree
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(descendant(of: window.contentView!, ofType: NotaTextView.self))
        window.makeFirstResponder(pane.outline)

        XCTAssertEqual(pane.path(atRow: 3), path("b", "c"))
        click(row: 3, in: pane)

        XCTAssertEqual(source(editor.string, editor.selectedRange()), "2")
        XCTAssertTrue(window.firstResponder === pane.outline)

        // And a branch gives the whole of itself, key and body together.
        click(row: 2, in: pane)
        XCTAssertEqual(source(editor.string, editor.selectedRange()), #""b":{"c":2}"#)
    }

    @MainActor
    func testTheCaretsLineLightsTheNodeThatLineBegins() throws {
        let controller = try makeController(showing: """
        {
          "a": {
            "b": 2
          }
        }
        """, named: "Settings.json")
        defer { controller.window?.orderOut(nil) }
        let pane = controller.previewPanes.tree
        let source = try XCTUnwrap(
            descendant(of: controller.window!.contentView!, ofType: NotaTextView.self)
        ).string

        pane.highlightBlock(containingSource: start(ofLine: 3, in: source))
        XCTAssertEqual(pane.selectedPath, path("a", "b"))

        pane.highlightBlock(containingSource: start(ofLine: 2, in: source))
        XCTAssertEqual(pane.selectedPath, path("a"))

        pane.clearHighlight()
        XCTAssertNil(pane.selectedPath)
    }

    /// The caret at the front of a compact file is on the file's own opening
    /// brace, which is the root and nothing deeper.
    @MainActor
    func testACompactFileLightsItsRootRatherThanItsLastLeaf() throws {
        let pane = try makePane(showing: #"{"a":{"b":{"c":1}}}"#)
        pane.highlightBlock(containingSource: 0)
        XCTAssertEqual(pane.selectedPath, "0", "the root, at the top, not the 1 inside it")
    }

    /// And moving on into it walks the tree down, which the line alone could
    /// never do: every node of this file begins on line 1.
    @MainActor
    func testTheCaretWalksAOneLineFileDownToTheDeepestNodeItIsIn() throws {
        let pane = try makePane(showing: #"{"a":{"b":{"c":1}}}"#)
        pane.highlightBlock(containingSource: 2)
        XCTAssertEqual(pane.selectedPath, path("a"), "inside the key `a`")

        pane.highlightBlock(containingSource: 7)
        XCTAssertEqual(pane.selectedPath, path("a", "b"))

        pane.highlightBlock(containingSource: 15)
        XCTAssertEqual(pane.selectedPath, path("a", "b", "c"), "on the 1 itself")
    }

    @MainActor
    func testARowInsideAClosedBranchLightsTheBranchInstead() throws {
        let controller = try makeController(showing: """
        {
          "a": {
            "b": 2
          }
        }
        """, named: "Settings.json")
        defer { controller.window?.orderOut(nil) }
        let pane = controller.previewPanes.tree
        let source = try XCTUnwrap(
            descendant(of: controller.window!.contentView!, ofType: NotaTextView.self)
        ).string
        pane.outline.collapseItem(pane.outline.item(atRow: 1))

        pane.highlightBlock(containingSource: start(ofLine: 3, in: source))
        XCTAssertEqual(pane.selectedPath, path("a"), "the deepest row that is on screen")
    }

    @MainActor
    func testARerenderKeepsWhateverWasOpen() throws {
        let controller = try makeController(
            showing: "{\n  \"a\": {\n    \"b\": 1\n  },\n  \"c\": {\n    \"d\": 2\n  }\n}",
            named: "Settings.json"
        )
        defer { controller.window?.orderOut(nil) }
        let pane = controller.previewPanes.tree
        pane.outline.collapseItem(pane.outline.item(atRow: 1))
        XCTAssertEqual(pane.visibleRows.map(\.title), ["{2}", "a  {1}", "c", "d  2"])

        let editor = try XCTUnwrap(
            descendant(of: controller.window!.contentView!, ofType: NotaTextView.self)
        )
        editor.textStorage?.mutableString.append(" ")
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: editor)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(pane.visibleRows.map(\.title), ["{2}", "a  {1}", "c", "d  2"],
                       "`a` is still closed and `c` is still open")
    }

    @MainActor
    func testAFileThatWillNotParseSaysSoInsteadOfShowingATree() throws {
        let pane = try makePane(showing: "{\n  \"a\": 1,\n  \"b\" 2\n}\n")
        XCTAssertTrue(pane.visibleRows.isEmpty, "the last good tree is not kept")
        XCTAssertEqual(pane.shownErrorMessage, "Not valid JSON: line 3 — Expected `:`")
        XCTAssertEqual(pane.shownParseError,
                       StructuredParseError(line: 3, message: "Expected `:`"))
    }

    @MainActor
    func testTheMessageNamesTheFormatTheFileIsSpelledAs() throws {
        let pane = try makePane(showing: "<root>\n  <a>\n</root>\n", named: "feed.xml")
        XCTAssertEqual(pane.shownErrorMessage?.hasPrefix("Not valid XML: line 3 — "), true,
                       "got \(pane.shownErrorMessage ?? "nothing")")
    }

    @MainActor
    func testAnXMLFileDrawsItsAttributesAndTextAsRows() throws {
        let pane = try makePane(showing: """
        <shop name="Nota">
          <item>Pencil</item>
        </shop>
        """, named: "shop.xml")
        XCTAssertEqual(pane.visibleRows.map(\.title),
                       ["shop", "@name  \"Nota\"", "item", "Pencil"])
    }

    // MARK: - Helpers

    /// The source a node's range points at — the one thing a range test has
    /// to do, since a span is right when the text it cuts out is the node.
    private func source(_ text: String, _ range: NSRange?) -> String? {
        guard let range else { return nil }
        return (text as NSString).substring(with: range)
    }

    /// The source a node's *value* points at — what a click on a leaf gives.
    private func value(_ text: String, _ node: StructuredNode) -> String? {
        source(text, node.valueRange)
    }

    /// The path the tree spells a node with: the document's roots are
    /// numbered, and every step down adds its key or its own index.
    private func path(_ components: String...) -> String {
        (["0"] + components).joined(separator: "\u{1F}")
    }

    /// Where a 1-based line begins, counted the way the editor counts.
    private func start(ofLine line: Int, in text: String) -> Int {
        let string = text as NSString
        var location = 0
        for _ in 1..<max(line, 1) {
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
        }
        return location
    }

    @MainActor
    private func click(row: Int, in pane: TreePreviewView) {
        let rect = pane.outline.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: pane.outline.convert(point, to: nil),
            modifierFlags: [], timestamp: 0,
            windowNumber: pane.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return XCTFail("no event") }
        pane.outline.mouseDown(with: event)
    }

    /// A pane on its own, showing one file — no window, no modes, just the
    /// tree the parser made.
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
        return pane
    }

    private func makeNote(named name: String, text: String) -> Note {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaStructured-\(UUID().uuidString)")
            .appendingPathComponent(name)
        return Note(fileURL: url, untitledName: nil, text: text,
                    attributes: [:], assets: nil)
    }

    @MainActor
    private func makeController(
        showing text: String, named name: String
    ) throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = SessionStore(directory: directory)
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil, isDirty: false,
                selection: 0, format: .default, previewMode: .split
            )],
            selectedTabID: id,
            fontSize: 13
        ))
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 620))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaStructuredTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
