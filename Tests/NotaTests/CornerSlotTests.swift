import AppKit
import PDFKit
import XCTest
@testable import Nota

/// The corner slot: one band per column, and the front tab saying what stands
/// in it. A tab with a render gets the mode control, a `.json` tab gets its
/// Beautify / Compact button, and everything else gets nothing at all.
final class CornerSlotTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What the slot holds

    @MainActor
    func testARenderedTabGetsTheModeControl() throws {
        let controller = try makeController()
        try open("notes.md", holding: "# Title", in: controller)

        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControl)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.modeControl.isHidden)
        XCTAssertTrue(overlay.jsonButton.isHidden, "one slot, one thing in it")
    }

    @MainActor
    func testAJSONTabGetsTheFormatButton() throws {
        let controller = try makeController()
        try open("data.json", holding: #"{"a":1}"#, in: controller)

        XCTAssertEqual(controller.cornerSlotContents.editor, .jsonFormat)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(overlay.modeControl.isHidden, "there is no render behind JSON")
        XCTAssertFalse(overlay.jsonButton.isHidden)
        XCTAssertEqual(
            controller.cornerSlotContents.preview, ModeControlOverlay.Content.none,
            "and no second column for it to stand in"
        )
    }

    @MainActor
    func testAPlainTextTabGetsNothingAndTheBandTakesNoClicks() throws {
        let controller = try makeController()
        try open("notes.txt", holding: "just text", in: controller)

        XCTAssertEqual(controller.cornerSlotContents.editor, ModeControlOverlay.Content.none)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.modeControl.isHidden)
        XCTAssertTrue(overlay.jsonButton.isHidden)
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
        XCTAssertTrue(controller.modeControlOverlays.preview.jsonButton.isHidden)
    }

    /// A `.json` extension is not enough on its own: the tab has to be text.
    /// Nothing here is spelled by a list of extensions kept in the overlay —
    /// the note is asked what it is.
    @MainActor
    func testTheSlotFollowsTheTabInFront() throws {
        let controller = try makeController()
        try open("data.json", holding: #"{"a":1}"#, in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, .jsonFormat)

        try open("notes.md", holding: "# Title", in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControl)

        try open("notes.txt", holding: "text", in: controller)
        XCTAssertEqual(controller.cornerSlotContents.editor, ModeControlOverlay.Content.none)
    }

    // MARK: - The button itself

    @MainActor
    func testACompactFileIsOfferedTheLayoutAndALaidOutFileTheOtherWay() throws {
        let controller = try makeController()
        try open("compact.json", holding: #"{"a":1}"#, in: controller)
        XCTAssertEqual(controller.modeControlOverlays.editor.jsonState, .action(.beautify))
        XCTAssertEqual(controller.modeControlOverlays.editor.jsonButton.toolTip, "Beautify JSON")

        try open("pretty.json", holding: "{\n  \"a\": 1\n}\n", in: controller)
        XCTAssertEqual(controller.modeControlOverlays.editor.jsonState, .action(.compact))
        XCTAssertEqual(controller.modeControlOverlays.editor.jsonButton.toolTip, "Compact JSON")
    }

    @MainActor
    func testInvalidJSONDisablesTheButtonAndNamesTheLine() throws {
        let controller = try makeController()
        try open("broken.json", holding: "{\n  \"a\": 1,\n  \"b\" 2\n}\n", in: controller)

        let button = controller.modeControlOverlays.editor.jsonButton
        XCTAssertEqual(controller.cornerSlotContents.editor, .jsonFormat, "the slot stays")
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.toolTip, "Not valid JSON: line 3")
    }

    @MainActor
    func testBeautifyingDirtiesTheTabAndUndoPutsTheFileBack() throws {
        let controller = try makeController()
        let source = #"{"b":1,"a":[2,3]}"#
        let textView = try open("data.json", holding: source, in: controller)
        XCTAssertFalse(controller.currentTabState.isDirty, "as it came off disk")

        let overlay = controller.modeControlOverlays.editor
        XCTAssertTrue(overlay.jsonButton.isEnabled)
        overlay.jsonButton.performClick(nil)

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
        XCTAssertEqual(overlay.jsonState, .action(.compact), "and the button flips")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source, "one edit, one undo")
    }

    @MainActor
    func testCompactingIsTheSameButtonTheOtherWayRound() throws {
        let controller = try makeController()
        let textView = try open(
            "data.json", holding: "{\n  \"a\": [\n    1\n  ]\n}\n", in: controller
        )
        let overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.jsonState, .action(.compact))

        overlay.jsonButton.performClick(nil)
        XCTAssertEqual(textView.string, "{\"a\":[1]}\n", "the file keeps its last line ending")
        XCTAssertEqual(overlay.jsonState, .action(.beautify))
    }

    /// The state is re-read from the text, not remembered: typing the file
    /// into something that will not parse disables the button.
    @MainActor
    func testTypingIsPickedUpOnTheDebounce() throws {
        let controller = try makeController()
        let textView = try open("data.json", holding: #"{"a":1}"#, in: controller)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertEqual(overlay.jsonState, .action(.beautify))

        textView.string = #"{"a":1"#
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(overlay.jsonState, .action(.beautify), "not on the keystroke")

        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(overlay.jsonState, .invalid(line: 1), "on the beat after it")
        XCTAssertFalse(overlay.jsonButton.isEnabled)
    }

    // MARK: - Helpers

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
