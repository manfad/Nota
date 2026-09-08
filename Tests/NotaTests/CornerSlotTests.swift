import AppKit
import PDFKit
import XCTest
@testable import Nota

/// The corner slot: one band per column, and the front tab saying what stands
/// in it. A tab with a render gets the mode control; a `.json` or `.html`
/// tab's *editor* slot gets that same control with its format's Beautify /
/// Compact action ahead of it; a tree's or a page's *preview* slot gets the
/// view's own action — Expand All / Collapse All, or Reload — in the same
/// place; everything else gets nothing at all.
final class CornerSlotTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What the slot holds

    @MainActor
    func testARenderedTabGetsTheThreeModeSegmentsAndNoMore() throws {
        let controller = try makeController()
        try open("notes.md", holding: "# Title", in: controller)

        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControl)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.modeControl.isHidden)
        XCTAssertEqual(overlay.modeControl.segmentCount, 3,
                       "Markdown has no second shape to be laid out in")
    }

    /// Both columns of a `.json` tab carry a fourth segment, and it is not the
    /// same segment: the editor's acts on the source, the preview's on the
    /// tree beside it.
    @MainActor
    func testAJSONTabGetsAFourthSegmentInEachColumnAndTheyDiffer() throws {
        let controller = try makeController()
        try open("data.json", holding: #"{"a":1}"#, in: controller)
        controller.setPreviewMode(.split)
        controller.window?.layoutIfNeeded()

        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControlWithFormat(.json))
        XCTAssertEqual(controller.cornerSlotContents.preview,
                       .modeControlWithPreviewAction(.tree),
                       "the preview's action is the tree's own, not the source's")
        for overlay in [controller.modeControlOverlays.editor,
                        controller.modeControlOverlays.preview] {
            XCTAssertFalse(overlay.isHidden)
            XCTAssertEqual(overlay.modeControl.segmentCount, 4,
                           "the three modes, and that column's own action ahead of them")
            XCTAssertTrue(overlay.modeControl.isEnabled(forSegment: 0))
        }
        XCTAssertEqual(controller.modeControlOverlays.editor.modeControl.toolTip(forSegment: 0),
                       "Beautify JSON")
        XCTAssertEqual(controller.modeControlOverlays.preview.modeControl.toolTip(forSegment: 0),
                       "Collapse All", "a small file opens with every branch already open")
    }

    /// A page is laid out two ways too, and says so in the word its own tools
    /// use: Minify, not Compact. That is the editor column's segment; the
    /// preview's is the page's own Reload.
    @MainActor
    func testAnHTMLTabsEditorSegmentUsesItsOwnWords() throws {
        let controller = try makeController()
        try open("page.html", holding: Self.minifiedPage, in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControlWithFormat(.html))
        var overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.modeControl.segmentCount, 4)
        XCTAssertEqual(overlay.formatState, .action(.beautify))
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Beautify HTML")

        try open("laid-out.html", holding: Self.prettyPage, in: controller)
        overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.formatState, .action(.compact))
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Minify HTML",
                       "a page is minified, not compacted")
    }

    /// A `.yaml` has a tree preview like the other three structured files, and
    /// no formatter behind it — so three segments and no fourth.
    @MainActor
    func testAYAMLTabGetsTheModesAndNoAction() throws {
        let controller = try makeController()
        try open("config.yaml", holding: "a: 1\n", in: controller)

        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControl)
        XCTAssertEqual(controller.modeControlOverlays.editor.modeControl.segmentCount, 3)
    }

    @MainActor
    func testAPlainTextTabGetsNothingAndTheBandTakesNoClicks() throws {
        let controller = try makeController()
        try open("notes.txt", holding: "just text", in: controller)

        XCTAssertEqual(controller.cornerSlotContents.editor, ModeControlOverlay.Content.none)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.modeControl.isHidden)
        XCTAssertNil(
            overlay.hitTest(NSPoint(x: overlay.frame.maxX - 20, y: overlay.frame.midY)),
            "the text under an empty band stays as clickable as any other"
        )
    }

    @MainActor
    func testAPDFTabGetsNothingInEitherColumn() throws {
        let controller = try makeController()
        let directory = try makeTemporaryDirectory()
        controller.open(url: try makePDF(named: "paper.pdf", in: directory))
        controller.window?.layoutIfNeeded()

        XCTAssertEqual(controller.cornerSlotContents.editor, ModeControlOverlay.Content.none)
        XCTAssertEqual(controller.cornerSlotContents.preview, ModeControlOverlay.Content.none)
    }

    /// A `.json` extension is not enough on its own: the tab has to be text.
    /// Nothing here is spelled by a list of extensions kept in the overlay —
    /// the note is asked what it is.
    @MainActor
    func testTheSlotFollowsTheTabInFront() throws {
        let controller = try makeController()
        try open("data.json", holding: #"{"a":1}"#, in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControlWithFormat(.json))

        try open("notes.md", holding: "# Title", in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControl)
        XCTAssertEqual(controller.modeControlOverlays.editor.modeControl.segmentCount, 3,
                       "the capsule shrinks back to the three modes")

        try open("notes.txt", holding: "text", in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, ModeControlOverlay.Content.none)
    }

    // MARK: - The action segment itself

    @MainActor
    func testACompactFileIsOfferedTheLayoutAndALaidOutFileTheOtherWay() throws {
        let controller = try makeController()
        try open("compact.json", holding: #"{"a":1}"#, in: controller)
        var overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.formatState, .action(.beautify))
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Beautify JSON")

        try open("pretty.json", holding: "{\n  \"a\": 1\n}\n", in: controller)
        overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.formatState, .action(.compact))
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Compact JSON")
    }

    @MainActor
    func testInvalidJSONDisablesTheSegmentAndNamesTheLine() throws {
        let controller = try makeController()
        try open("broken.json", holding: "{\n  \"a\": 1,\n  \"b\" 2\n}\n", in: controller)

        let overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControlWithFormat(.json),
                       "the slot stays")
        XCTAssertEqual(overlay.modeControl.segmentCount, 4)
        XCTAssertFalse(overlay.modeControl.isEnabled(forSegment: 0))
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Not valid JSON: line 3")
        XCTAssertTrue(overlay.modeControl.isEnabled(forSegment: 1),
                      "and the modes beside it go on working")
    }

    @MainActor
    func testBeautifyingDirtiesTheTabAndUndoPutsTheFileBack() throws {
        let controller = try makeController()
        let source = #"{"b":1,"a":[2,3]}"#
        let textView = try open("data.json", holding: source, in: controller)
        XCTAssertFalse(controller.currentTabState.isDirty, "as it came off disk")

        let overlay = controller.modeControlOverlays.editor
        XCTAssertTrue(overlay.modeControl.isEnabled(forSegment: 0))
        clickFormatSegment(of: overlay)

        XCTAssertEqual(
            textView.string,
            """
            {
              "b": 1,
              "a": [
                2,
                3
              ]
            }
            """
        )
        XCTAssertTrue(controller.currentTabState.isDirty, "the file on disk is not this")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0),
                       "every line moved, so the caret goes to the top")
        XCTAssertEqual(overlay.formatState, .action(.compact), "and the segment flips")
        XCTAssertEqual(overlay.modeControl.selectedSegment, 1,
                       "the selection goes back to the mode it was on, now one segment along")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source, "one edit, one undo")
    }

    @MainActor
    func testCompactingIsTheSameSegmentTheOtherWayRound() throws {
        let controller = try makeController()
        let textView = try open(
            "data.json", holding: "{\n  \"a\": [\n    1\n  ]\n}\n", in: controller
        )
        let overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.formatState, .action(.compact))

        clickFormatSegment(of: overlay)
        XCTAssertEqual(textView.string, "{\"a\":[1]}\n", "the file keeps its last line ending")
        XCTAssertEqual(overlay.formatState, .action(.beautify))
    }

    /// The click routes through one path for both formats: the segment hands
    /// its kind and its action to the window, and the window asks whichever
    /// formatter that kind names — `HTMLFormat` here, for real.
    @MainActor
    func testBeautifyingAPageLaysItOutAndMinifyingGivesItBackWordForWord() throws {
        let controller = try makeController()
        let textView = try open("page.html", holding: Self.minifiedPage, in: controller)
        XCTAssertFalse(controller.currentTabState.isDirty, "as it came off disk")

        let overlay = controller.modeControlOverlays.editor
        XCTAssertTrue(overlay.modeControl.isEnabled(forSegment: 0))
        clickFormatSegment(of: overlay)

        XCTAssertEqual(textView.string, Self.prettyPage)
        XCTAssertTrue(textView.string.contains("\n  <"), "one element to a line, indented")
        XCTAssertTrue(controller.currentTabState.isDirty, "the file on disk is not this")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0),
                       "every line moved, so the caret goes to the top")
        XCTAssertEqual(overlay.formatState, .action(.compact), "and the segment flips")
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Minify HTML")
        XCTAssertEqual(overlay.modeControl.selectedSegment, 1,
                       "the selection goes back to the mode it was on, now one segment along")

        clickFormatSegment(of: overlay)
        XCTAssertEqual(textView.string, Self.minifiedPage,
                       "the page comes back the bytes it was, its last newline included")
        XCTAssertEqual(overlay.formatState, .action(.beautify))
    }

    @MainActor
    func testUndoPutsAWholePageBackInOneStep() throws {
        let controller = try makeController()
        let textView = try open("page.html", holding: Self.minifiedPage, in: controller)
        clickFormatSegment(of: controller.modeControlOverlays.editor)
        XCTAssertNotEqual(textView.string, Self.minifiedPage)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, Self.minifiedPage, "one edit, one undo")
    }

    /// An unterminated comment swallows the rest of the file, so the line the
    /// reader has to look at is the one it opened on.
    @MainActor
    func testAnUnreadablePageDisablesTheSegmentAndNamesTheLine() throws {
        let controller = try makeController()
        try open("broken.html", holding: "<p>a</p>\n<!-- open\nstill open\n", in: controller)

        let overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControlWithFormat(.html),
                       "the slot stays")
        XCTAssertEqual(overlay.modeControl.segmentCount, 4)
        XCTAssertFalse(overlay.modeControl.isEnabled(forSegment: 0))
        XCTAssertEqual(overlay.modeControl.toolTip(forSegment: 0), "Not valid HTML: line 2")
        XCTAssertTrue(overlay.modeControl.isEnabled(forSegment: 1),
                      "and the modes beside it go on working")
    }

    /// A mode segment is still a mode: the fourth one has not made the other
    /// three into anything else.
    @MainActor
    func testTheModeSegmentsStillChangeTheModeOnAJSONTab() throws {
        let controller = try makeController()
        try open("data.json", holding: #"{"a":1}"#, in: controller)
        let overlay = controller.modeControlOverlays.editor

        // Split is second of the three modes, and the action ahead of them
        // on this tab shifts every mode's segment one along.
        overlay.modeControl.selectedSegment = overlay.segmentIndex(of: .split)
        overlay.modeControl.sendAction(overlay.modeControl.action, to: overlay.modeControl.target)
        XCTAssertEqual(controller.previewMode, .split)
    }

    /// The state is re-read from the text, not remembered: typing the file
    /// into something that will not parse disables the button.
    @MainActor
    func testTypingIsPickedUpOnTheDebounce() throws {
        let controller = try makeController()
        let textView = try open("data.json", holding: #"{"a":1}"#, in: controller)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.formatState, .action(.beautify))

        textView.string = #"{"a":1"#
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(overlay.formatState, .action(.beautify), "not on the keystroke")

        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(overlay.formatState, .invalid(line: 1), "on the beat after it")
        XCTAssertFalse(overlay.modeControl.isEnabled(forSegment: 0))
    }

    // MARK: - The Editor segment's drawing

    /// The Editor segment is a page with a pencil on it, one drawing in the
    /// light and in the dark alike; the other two are one shape each too.
    func testTheEditorSegmentIsAPageAndAPencil() {
        XCTAssertEqual(PreviewMode.off.symbolName, "long.text.page.and.pencil")
        XCTAssertEqual(PreviewMode.split.symbolName, "rectangle.split.2x1")
        XCTAssertEqual(PreviewMode.reading.symbolName, "book")
        for name in [PreviewMode.off, .split, .reading].map(\.symbolName) {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "\(name) is a symbol this Mac has")
        }
    }


    // MARK: - Helpers

    /// The same page in its two shapes. `HTMLFormat` maps each onto the other
    /// exactly, trailing newline included, so a test can press the segment
    /// twice and ask for the bytes it started with.
    private static let minifiedPage =
        "<div class=\"row\"><p>Hello</p><p>World</p></div>\n"
    private static let prettyPage =
        "<div class=\"row\">\n  <p>Hello</p>\n  <p>World</p>\n</div>\n"

    /// A click on the action segment: the selection lands on it, and the
    /// control's own action goes out, exactly as AppKit sends it.
    @MainActor
    private func clickFormatSegment(of overlay: ModeControlOverlay) {
        overlay.modeControl.selectedSegment = ModeControlOverlay.formatSegmentIndex
        overlay.modeControl.sendAction(overlay.modeControl.action, to: overlay.modeControl.target)
    }

    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(
            store: SessionStore(directory: try makeTemporaryDirectory())
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    /// A file written out, opened as a tab, and the editor it landed in.
    @MainActor
    @discardableResult
    private func open(
        _ name: String, holding text: String, in controller: MainWindowController
    ) throws -> NotaTextView {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        controller.open(url: url)
        controller.window?.layoutIfNeeded()
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
    }

    private func makePDF(named name: String, in directory: URL) throws -> URL {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        document.insert(page, at: 0)
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url), "the fixture has to be a real PDF")
        return url
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
            .appendingPathComponent("NotaCornerSlotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
