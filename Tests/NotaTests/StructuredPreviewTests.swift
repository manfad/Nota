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

    /// A click walks the editor to the line, and leaves the keyboard where it
    /// was — the tree is being walked with the arrows.
    @MainActor
    func testAClickOnARowMovesTheEditorsCaretToItsLine() throws {
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

        XCTAssertEqual(line(of: editor.selectedRange().location, in: editor.string), 3)
        XCTAssertTrue(window.firstResponder === pane.outline,
                      "the click reveals rather than jumps")
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

    /// A line that begins several nodes — every line of a compact file — is a
    /// run of the document rather than one node's, so the outermost of them
    /// is what the caret is in.
    @MainActor
    func testACompactFileLightsItsRootRatherThanItsLastLeaf() throws {
        let pane = try makePane(showing: #"{"a":{"b":{"c":1}}}"#)
        pane.highlightBlock(containingSource: 0)
        XCTAssertEqual(pane.selectedPath, "0", "the root, at the top, not the 1 inside it")
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

    private func line(of location: Int, in text: String) -> Int {
        let head = (text as NSString).substring(to: location)
        return head.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
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
