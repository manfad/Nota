import AppKit
import XCTest
@testable import Nota

/// `- [ ]` and `- [x]` in the Markdown render: drawn as boxes rather than
/// bullets, ticked with one press that rewrites one character of the note,
/// and counted `3 / 7 done` in the footer.
final class TaskListTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private let editorFont = NSFont.systemFont(ofSize: 13)

    // MARK: - The render

    func testATaskItemDrawsACheckboxInTheBulletsPlace() {
        let rendered = render("- [ ] alpha\n- [x] beta\n")

        // The box takes the marker's slot, and the `[ ]` never reaches the page.
        XCTAssertEqual(rendered.string, "\u{FFFC}\talpha\n\u{FFFC}\tbeta")
        XCTAssertFalse(rendered.string.contains("•"), "a task item shows no bullet")
        XCTAssertEqual(boxes(in: rendered).map(\.isDone), [false, true])
    }

    func testATaskInAnOrderedListLosesItsNumberToTheBox() {
        let rendered = render("1. [ ] one\n2. [X] two\n")
        XCTAssertEqual(rendered.string, "\u{FFFC}\tone\n\u{FFFC}\ttwo")
        XCTAssertEqual(boxes(in: rendered).map(\.isDone), [false, true],
                       "an upper-case X is ticked too")
    }

    func testAnOrdinaryListItemKeepsItsBulletAndItsBrackets() {
        // Everything that only looks like a task: the wrong letter between
        // the brackets, no space after them, and a paragraph that is not in
        // a list at all.
        for markdown in ["- [y] no", "- []x no", "[ ] not a list item"] {
            let rendered = render(markdown)
            XCTAssertTrue(
                boxes(in: rendered).isEmpty, "\(markdown.debugDescription) is not a task"
            )
            XCTAssertTrue(rendered.string.contains("["), "its brackets stay in the words")
        }
        XCTAssertEqual(render("- [y] no").string, "•\t[y] no")
    }

    func testATaskItemsWordsLineUpTheWayAnyListItemsDo() throws {
        let rendered = render("- [ ] alpha\n- plain\n")
        let task = try XCTUnwrap(paragraphStyle(rendered, at: "alpha"))
        let plain = try XCTUnwrap(paragraphStyle(rendered, at: "plain"))
        XCTAssertEqual(task.headIndent, plain.headIndent)
        XCTAssertEqual(task.firstLineHeadIndent, plain.firstLineHeadIndent)
    }

    func testTheBoxIsMeasuredAgainstTheFontRatherThanThePane() {
        // Nothing here is fitted to the column, so widening it is not a
        // reason to render the note again.
        XCTAssertFalse(result("- [ ] alpha").dependsOnWidth)
        let small = boxes(in: render("- [ ] alpha", font: NSFont.systemFont(ofSize: 11)))
        let large = boxes(in: render("- [ ] alpha", font: NSFont.systemFont(ofSize: 22)))
        XCTAssertGreaterThan(
            large.first?.bounds.height ?? 0, small.first?.bounds.height ?? 0,
            "the box grows with the render's font"
        )
    }

    // MARK: - Finding the box in the source

    func testANestedTaskMapsToItsOwnLine() {
        let markdown = "- outer\n  - [ ] nested\n  - [x] also nested\n"
        XCTAssertEqual(
            sources(markdown), ["- outer", "  - [ ] nested", "  - [x] also nested"]
        )
        let source = markdown as NSString
        let found = result(markdown).blocks.map { TaskList.box(in: source, within: $0.source) }
        XCTAssertNil(found[0], "the plain item has no box")
        XCTAssertEqual(found[1]?.location, (markdown as NSString).range(of: "[ ]").location + 1)
        XCTAssertEqual(found[2]?.location, (markdown as NSString).range(of: "[x]").location + 1)
        XCTAssertEqual(found[2]?.isDone, true)
    }

    func testAnOrderedTaskFindsItsOwnBox() {
        let markdown = "1. [ ] one\n2. [X] two\n"
        let source = markdown as NSString
        let found = result(markdown).blocks.compactMap { TaskList.box(in: source, within: $0.source) }
        XCTAssertEqual(found.map(\.location), [4, 15])
        XCTAssertEqual(found.map(\.isDone), [false, true])
    }

    func testABoxIsOnlyEverALineThatOpensAsATaskItem() {
        // An `[x]` inside an item's prose is prose; the item's own box is the
        // one at the head of the line.
        let markdown = "- [ ] see [x] over there\n"
        let box = TaskList.box(
            in: markdown as NSString,
            within: NSRange(location: 0, length: (markdown as NSString).length)
        )
        XCTAssertEqual(box?.location, 3)
    }

    func testCountingTasksSkipsWhatOnlyLooksLikeOne() {
        XCTAssertEqual(TaskList.counts(in: "").total, 0)
        XCTAssertEqual(TaskList.counts(in: "nothing here at all").total, 0)
        let mixed = """
        # Notes

        - [x] done
        - [ ] open
          - [x] nested and done
        1. [ ] ordered
        * [X] starred
        + [ ] plussed
        - [y] not a box
        - []x not a box
        [ ] not a list item
        """
        XCTAssertEqual(TaskList.counts(in: mixed).done, 3)
        XCTAssertEqual(TaskList.counts(in: mixed).total, 6)
    }

    // MARK: - Ticking one

    @MainActor
    func testClickingACheckboxRewritesTheOneSourceCharacter() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("- [ ] alpha\n- [x] beta", replacementRange: editor.selectedRange())
        waitForDebounce()

        try clickCheckbox(of: controller, at: 0)
        XCTAssertEqual(editor.string, "- [x] alpha\n- [x] beta",
                       "one character, and only that one")

        waitForDebounce()
        try clickCheckbox(of: controller, at: 1)
        XCTAssertEqual(editor.string, "- [x] alpha\n- [ ] beta")
    }

    @MainActor
    func testTickingACheckboxIsUndoable() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("- [ ] alpha\n- [x] beta", replacementRange: editor.selectedRange())
        waitForDebounce()

        try clickCheckbox(of: controller, at: 0)
        XCTAssertEqual(editor.string, "- [x] alpha\n- [x] beta")

        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, "- [ ] alpha\n- [x] beta", "⌘Z puts the tick back")
        undo.redo()
        XCTAssertEqual(editor.string, "- [x] alpha\n- [x] beta")
    }

    @MainActor
    func testTickingLeavesTheCaretAndTheBandAlone() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "Some words first.\n\n- [ ] alpha\n- [x] beta",
            replacementRange: editor.selectedRange()
        )
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        waitForDebounce()

        let preview = try previewView(of: controller)
        let paneBefore = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
            .selectedRange()

        try clickCheckbox(of: controller, at: 0)

        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0),
                       "the caret is where the reader left it")
        // A tick lights nothing: the band that was on the caret's own block
        // goes out the way it does after any edit, and none comes up under
        // the item that was pressed.
        XCTAssertNil(preview.highlightedSourceRange)
        let pane = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        XCTAssertEqual(pane.selectedRange(), paneBefore, "and nothing was selected in the page")
        // The render comes back lit on the caret's own block, the way it is
        // after any edit — never on the item that was ticked.
        waitForDebounce()
        let ticked = (editor.string as NSString).range(of: "- [x] alpha").location
        XCTAssertFalse(
            preview.highlightedSourceRange.map { NSLocationInRange(ticked, $0) } ?? false
        )
    }

    /// A checkbox is a control, not a jump, so reading mode takes it too —
    /// the one press in the render that changes the note.
    @MainActor
    func testACheckboxTicksInReadingModeAsWell() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("- [ ] alpha\n- [x] beta", replacementRange: editor.selectedRange())
        waitForDebounce()
        controller.setPreviewMode(.reading)
        let caret = editor.selectedRange()

        try clickCheckbox(of: controller, at: 0)

        XCTAssertEqual(editor.string, "- [x] alpha\n- [x] beta")
        XCTAssertEqual(controller.previewMode, .reading, "the page is where you still are")
        XCTAssertEqual(editor.selectedRange(), caret, "and no editor came back for it")
    }

    @MainActor
    func testTheRenderComesBackWithTheBoxTicked() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("- [ ] alpha\n- [x] beta", replacementRange: editor.selectedRange())
        waitForDebounce()

        try clickCheckbox(of: controller, at: 0)
        waitForDebounce()

        let preview = try previewView(of: controller)
        XCTAssertEqual(boxes(in: preview.renderedContent).map(\.isDone), [true, true])
    }

    // MARK: - The footer

    @MainActor
    func testTheFooterCountsTickedOverTotal() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("- [ ] alpha\n- [x] beta", replacementRange: editor.selectedRange())

        XCTAssertTrue(
            controller.footerRegions.counts.stringValue.hasSuffix(" · 1 / 2 done"),
            "the footer said \(controller.footerRegions.counts.stringValue)"
        )

        // Ticking the other one moves the count with it.
        waitForDebounce()
        try clickCheckbox(of: controller, at: 0)
        XCTAssertTrue(controller.footerRegions.counts.stringValue.hasSuffix(" · 2 / 2 done"))
    }

    @MainActor
    func testAMarkdownWithNoTasksSaysNothingAboutThem() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("- a plain list\n- with no boxes", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.footerRegions.counts.stringValue, "8 words · 30 characters")
    }

    @MainActor
    func testAPlainTextTabNeverCountsTasks() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()

        controller.addTab(
            fileURL: directory.appendingPathComponent("notes.txt"),
            text: "- [ ] alpha\n- [x] beta"
        )
        XCTAssertFalse(
            controller.footerRegions.counts.stringValue.contains("done"),
            "`- [ ]` is Markdown's own; a .txt is dashes and brackets"
        )

        // The same text under a `.md` name does count.
        controller.addTab(
            fileURL: directory.appendingPathComponent("notes.md"),
            text: "- [ ] alpha\n- [x] beta"
        )
        XCTAssertTrue(controller.footerRegions.counts.stringValue.hasSuffix(" · 1 / 2 done"))
    }

    /// A big note's tasks ride the background word-count pass. Nothing about
    /// them may touch the main thread: the footer is right about the lines
    /// and the caret at once, and says how many are done a moment later.
    @MainActor
    func testABigMarkdownsTaskCountsArriveOffTheMainThread() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let block = String(repeating: "a line of prose with several words in it\n", count: 20)
            + "- [x] done one\n- [ ] still open\n"
        let repeats = 1_300
        let url = directory.appendingPathComponent("big.md")
        try String(repeating: block, count: repeats)
            .write(to: url, atomically: true, encoding: .utf8)

        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()

        controller.open(url: url)
        XCTAssertTrue(
            BigFile.isBig(length: block.count * repeats), "the fixture is a big one"
        )
        // The line table answers on the spot; the scan of the file has not
        // happened yet, and cannot have — it needs the run loop back.
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Ln 1, Col 1")
        XCTAssertFalse(
            controller.footerRegions.counts.stringValue.contains("done"),
            "nothing counted the tasks on the main thread"
        )

        let expected = " · \(repeats) / \(repeats * 2) done"
        let landed = expectation(description: "the task counts land")
        var waited = 0.0
        func poll() {
            if controller.footerRegions.counts.stringValue.hasSuffix(expected) {
                return landed.fulfill()
            }
            waited += 0.05
            guard waited < 10 else { return landed.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
        wait(for: [landed], timeout: 12)
        XCTAssertTrue(controller.footerRegions.counts.stringValue.hasSuffix(expected))
    }

    // MARK: - Where a tick leaves the page

    /// A tick is not a jump, so the page it was pressed on does not move: the
    /// note is rewritten, the render comes back changed, and the reader is
    /// still looking at the box they pressed rather than at whatever the
    /// caret is sitting in eighty paragraphs up.
    @MainActor
    func testTickingABoxLeavesTheSplitPaneWhereItWas() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(longNoteEndingInTasks, replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        waitForDebounce()

        XCTAssertEqual(controller.previewMode, .split)
        let preview = try previewView(of: controller)
        // Read to the bottom, where the boxes are.
        preview.scroll(toFraction: 1)
        let before = preview.scrollOffset
        XCTAssertGreaterThan(before, 0, "the page is long enough to be scrolled")

        try clickCheckbox(of: controller, at: 1)

        XCTAssertEqual(preview.scrollOffset, before, accuracy: 2,
                       "the press itself moved nothing")
        waitForDebounce()
        XCTAssertEqual(preview.scrollOffset, before, accuracy: 2,
                       "and neither did the render that answered it")
        XCTAssertTrue(editor.string.contains("- [x] the last box"))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0),
                       "the caret is where the reader left it")
    }

    @MainActor
    func testTickingABoxLeavesTheReadingPageWhereItWas() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(longNoteEndingInTasks, replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        waitForDebounce()
        controller.setPreviewMode(.reading)
        waitForDebounce()

        let preview = try previewView(of: controller)
        preview.scroll(toFraction: 1)
        let before = preview.scrollOffset
        XCTAssertGreaterThan(before, 0, "the page is long enough to be scrolled")

        try clickCheckbox(of: controller, at: 1)

        XCTAssertEqual(preview.scrollOffset, before, accuracy: 2)
        waitForDebounce()
        XCTAssertEqual(preview.scrollOffset, before, accuracy: 2)
        XCTAssertTrue(editor.string.contains("- [x] the last box"))
        XCTAssertEqual(controller.previewMode, .reading, "the page is where you still are")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    /// The band still follows the caret. A tick holds the page still, and the
    /// next caret the reader moves themselves takes it along again.
    @MainActor
    func testACaretMoveAfterATickTakesThePaneToItsBlock() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(longNoteEndingInTasks, replacementRange: editor.selectedRange())
        let middle = (editor.string as NSString).range(of: "Paragraph 40")
        editor.setSelectedRange(NSRange(location: middle.location, length: 0))
        waitForDebounce()

        let preview = try previewView(of: controller)
        preview.scroll(toFraction: 1)
        let bottom = preview.scrollOffset

        try clickCheckbox(of: controller, at: 1)
        waitForDebounce()
        XCTAssertEqual(preview.scrollOffset, bottom, accuracy: 2, "the tick held it still")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(preview.scrollOffset, 0, accuracy: 1,
                       "and the caret walking to the top walked the page with it")
    }

    // MARK: - Rendering helpers

    private func result(
        _ markdown: String, font: NSFont? = nil, width: CGFloat = 400
    ) -> MarkdownRenderer.Result {
        MarkdownRenderer.render(
            markdown, font: font ?? editorFont, assets: nil, width: width
        )
    }

    private func render(
        _ markdown: String, font: NSFont? = nil, width: CGFloat = 400
    ) -> NSAttributedString {
        result(markdown, font: font, width: width).text
    }

    private func sources(_ markdown: String) -> [String] {
        let source = markdown as NSString
        return result(markdown).blocks.map { source.substring(with: $0.source) }
    }

    /// Every checkbox in a render, in the order it is drawn.
    private func boxes(in rendered: NSAttributedString) -> [TaskCheckboxAttachment] {
        var found: [TaskCheckboxAttachment] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let box = value as? TaskCheckboxAttachment { found.append(box) }
        }
        return found
    }

    private func paragraphStyle(
        _ rendered: NSAttributedString, at text: String
    ) -> NSParagraphStyle? {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return rendered.attribute(
            .paragraphStyle, at: range.location, effectiveRange: nil
        ) as? NSParagraphStyle
    }

    // MARK: - Window helpers

    /// Eighty paragraphs and then a task list: the boxes are several screens
    /// down, so a caret at the top of the note is nowhere near them.
    private var longNoteEndingInTasks: String {
        (1 ... 80).map { "Paragraph \($0) with a few words in it." }
            .joined(separator: "\n\n")
            + "\n\n- [ ] the first box\n- [ ] the last box\n"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    @MainActor
    private func makeControllerShowingPreview() throws -> MainWindowController {
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let file = directory.appendingPathComponent("note.md")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil,
                isDirty: false, selection: 0, format: .default, previewMode: .off
            )],
            selectedTabID: id,
            fontSize: 13
        ))
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        controller.toggleMarkdownPreview()
        window.layoutIfNeeded()
        return controller
    }

    private func waitForDebounce() {
        let fired = expectation(description: "the preview re-rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
    }

    @MainActor
    private func editorTextView(of controller: MainWindowController) throws -> NotaTextView {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
    }

    @MainActor
    private func previewView(of controller: MainWindowController) throws -> MarkdownPreviewView {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: MarkdownPreviewView.self))
    }

    /// Presses the nth checkbox in the render, through a real mouse event at
    /// the middle of the box, so the press travels the path a reader's does.
    @MainActor
    private func clickCheckbox(of controller: MainWindowController, at index: Int) throws {
        let window = try XCTUnwrap(controller.window)
        let preview = try previewView(of: controller)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let storage = try XCTUnwrap(textView.textStorage)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        var found: [Int] = []
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value is TaskCheckboxAttachment { found.append(range.location) }
        }
        try XCTSkipIf(index >= found.count, "there is no checkbox \(index) in the render")

        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: found[index], length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let location = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        textView.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )))
    }

    @MainActor
    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }
}
