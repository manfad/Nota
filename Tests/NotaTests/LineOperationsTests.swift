import AppKit
import XCTest
@testable import Nota

/// The Notepad++ line hands, driven through a real `NotaTextView` — the same
/// calls the Edit menu makes when a key arrives, so what the tests exercise is
/// what a keypress does: the edit, the selection it leaves, and the single
/// undo step behind it.
@MainActor
final class LineOperationsTests: XCTestCase {

    // MARK: - Harness

    /// Holds the undo manager: `NSTextView` asks its delegate for one, and a
    /// view with no window has nowhere else to get it.
    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var hosts: [UndoHost] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows = []
        hosts = []
    }

    @MainActor
    private struct Harness {
        let view: NotaTextView
        let undo: UndoManager
        /// How many times an operation has asked for the line table — the
        /// lines come from there and never from a scan of the text.
        let lineIndexReads: () -> Int

        var string: String { view.string }
        var caret: Int { view.selectedRange().location }
        var selection: NSRange { view.selectedRange() }
        var ranges: [NSRange] { view.selectedRanges.map(\.rangeValue) }

        func select(_ location: Int, _ length: Int = 0) {
            view.setSelectedRange(NSRange(location: location, length: length))
        }
    }

    private func makeHarness(
        _ text: String, fileExtension: String? = nil, width: CGFloat = 400
    ) -> Harness {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = NotaTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 400), textContainer: container
        )
        view.isRichText = false
        view.isEditable = true
        view.allowsUndo = true
        view.attributesProvider = { [.font: NSFont.systemFont(ofSize: 13)] }

        let host = UndoHost()
        hosts.append(host)
        view.delegate = host

        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))

        // The note's own table is folded forward by `Note`; a bare view in a
        // test hands over a freshly built one, which says the same thing.
        let reads = Counter()
        view.lineIndexProvider = { [weak view] in
            reads.value += 1
            guard let string = view?.textStorage?.mutableString else { return nil }
            return LineIndex(string)
        }
        view.fileExtensionProvider = { fileExtension }
        return Harness(view: view, undo: host.manager, lineIndexReads: { reads.value })
    }

    private final class Counter { var value = 0 }

    /// A window the editor can really hold the keyboard in — menu validation
    /// asks who the first responder is, and a view with no window has none.
    private func giveKeyboard(to view: NotaTextView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFrontOffscreen()
        window.makeFirstResponder(view)
        windows.append(window)
        return window
    }

    private func menuItem(_ action: Selector, title: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    // MARK: - ⌥↑ / ⌥↓

    func testMovingALineUpSwapsItWithTheOneAbove() {
        let harness = makeHarness("one\ntwo\nthree")
        harness.select(4)
        harness.view.moveLinesUp(nil)
        XCTAssertEqual(harness.string, "two\none\nthree")
        // The caret rides with the line it was on.
        XCTAssertEqual(harness.caret, 0)
        XCTAssertGreaterThan(harness.lineIndexReads(), 0)
    }

    func testMovingTheFirstLineUpIsNothingAtAll() {
        let harness = makeHarness("one\ntwo\nthree")
        harness.select(1)
        harness.view.moveLinesUp(nil)
        XCTAssertEqual(harness.string, "one\ntwo\nthree")
        XCTAssertEqual(harness.caret, 1)
        XCTAssertFalse(harness.undo.canUndo)
    }

    func testMovingALineDownSwapsItWithTheOneBelow() {
        let harness = makeHarness("one\ntwo\nthree")
        harness.select(4)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "one\nthree\ntwo")
        XCTAssertEqual(harness.caret, 10)
    }

    func testMovingTheLastLineDownLeavesNoStrayNewline() {
        let harness = makeHarness("one\ntwo")
        harness.select(6)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "one\ntwo")
        XCTAssertFalse(harness.undo.canUndo)

        // And the line above it moving down does not grow one either.
        harness.select(1)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "two\none")
    }

    func testMovingASelectionOfLinesTakesTheSelectionWithIt() {
        let harness = makeHarness("a\nb\nc\nd")
        // "b\nc", the two middle lines.
        harness.select(2, 3)
        harness.view.moveLinesUp(nil)
        XCTAssertEqual(harness.string, "b\nc\na\nd")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 3))

        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "a\nb\nc\nd")
        XCTAssertEqual(harness.selection, NSRange(location: 2, length: 3))
    }

    func testASelectionEndingOnALineStartLeavesThatLineAlone() {
        let harness = makeHarness("a\nb\nc")
        // Dragged down to the start of "b" — line 2 has not been touched.
        harness.select(0, 2)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "b\na\nc")
    }

    func testMovingALineIsOneUndoStep() {
        let harness = makeHarness("one\ntwo\nthree")
        harness.select(4)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "one\nthree\ntwo")
        harness.undo.undo()
        XCTAssertEqual(harness.string, "one\ntwo\nthree")
        XCTAssertFalse(harness.undo.canUndo)
    }

    func testMovingALineIsAboutHardLinesNotWrappedOnes() {
        // Narrow enough that the first line wraps over several rows.
        let harness = makeHarness(
            "aaaa bbbb cccc dddd eeee ffff gggg\nsecond", width: 60
        )
        harness.select(2)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "second\naaaa bbbb cccc dddd eeee ffff gggg")
    }

    // MARK: - ⇧⌥↓ and ⌘D

    func testDuplicatingALinePutsTheCaretOnTheCopy() {
        let harness = makeHarness("one\ntwo")
        harness.select(1)
        harness.view.duplicateLines(nil)
        XCTAssertEqual(harness.string, "one\none\ntwo")
        XCTAssertEqual(harness.caret, 5)
    }

    func testDuplicatingTheLastLine() {
        let harness = makeHarness("one\ntwo")
        harness.select(5)
        harness.view.duplicateLines(nil)
        XCTAssertEqual(harness.string, "one\ntwo\ntwo")
        XCTAssertEqual(harness.caret, 9)
    }

    func testDuplicatingASelectionOfLinesSelectsTheCopy() {
        let harness = makeHarness("a\nb\nc")
        harness.select(0, 3)
        harness.view.duplicateLines(nil)
        XCTAssertEqual(harness.string, "a\nb\na\nb\nc")
        XCTAssertEqual(harness.selection, NSRange(location: 4, length: 3))
    }

    func testDuplicatingIsOneUndoStep() {
        let harness = makeHarness("one\ntwo")
        harness.select(1)
        harness.view.duplicateLines(nil)
        harness.undo.undo()
        XCTAssertEqual(harness.string, "one\ntwo")
        XCTAssertFalse(harness.undo.canUndo)
    }

    func testCommandDWithNothingInHandDuplicatesTheLine() {
        let harness = makeHarness("one\ntwo")
        harness.select(1)
        harness.view.duplicateOrSelectNext(nil)
        XCTAssertEqual(harness.string, "one\none\ntwo")
        XCTAssertEqual(harness.caret, 5)
    }

    func testCommandDWithASelectionAddsTheNextOccurrence() {
        let harness = makeHarness("foo bar foo baz foo")
        harness.select(0, 3)
        harness.view.duplicateOrSelectNext(nil)
        XCTAssertEqual(harness.ranges, [
            NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
        ])
        harness.view.duplicateOrSelectNext(nil)
        XCTAssertEqual(harness.ranges, [
            NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
            NSRange(location: 16, length: 3),
        ])
        // Every one of them is in hand; there is nothing left to add.
        harness.view.duplicateOrSelectNext(nil)
        XCTAssertEqual(harness.ranges.count, 3)
        XCTAssertEqual(harness.string, "foo bar foo baz foo")
    }

    func testCommandDWrapsRoundTheEndOfTheNote() {
        let harness = makeHarness("foo bar foo")
        harness.select(8, 3)
        harness.view.duplicateOrSelectNext(nil)
        XCTAssertEqual(harness.ranges, [
            NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
        ])
    }

    func testCommandDIsCaseSensitive() {
        let harness = makeHarness("Foo bar foo")
        harness.select(0, 3)
        harness.view.duplicateOrSelectNext(nil)
        XCTAssertEqual(harness.ranges, [NSRange(location: 0, length: 3)])
    }

    func testTypingEditsEveryRangeInOneUndoStep() {
        let harness = makeHarness("foo bar foo")
        harness.select(0, 3)
        harness.view.duplicateOrSelectNext(nil)
        let typed = NSRange(location: NSNotFound, length: 0)
        harness.view.insertText("zz", replacementRange: typed)
        XCTAssertEqual(harness.string, "zz bar zz")
        // A caret after what each range took, the last of them the one on
        // screen — AppKit keeps only one empty range, so the editor holds the
        // rest itself and the next character still reaches them.
        XCTAssertEqual(harness.caret, 9)
        harness.view.insertText("!", replacementRange: typed)
        XCTAssertEqual(harness.string, "zz! bar zz!")
        XCTAssertEqual(harness.caret, 11)

        // Clicking somewhere else is the end of the second caret.
        harness.select(0)
        harness.view.insertText("x", replacementRange: typed)
        XCTAssertEqual(harness.string, "xzz! bar zz!")

        // Typing is typing: AppKit coalesces the lot into the one step it
        // always does, and undo puts every range back at once.
        harness.undo.undo()
        XCTAssertEqual(harness.string, "foo bar foo")
    }

    // MARK: - ⌘/

    func testTogglingAPythonComment() {
        let harness = makeHarness("x = 1\ny = 2", fileExtension: "py")
        harness.select(0, 11)
        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "# x = 1\n# y = 2")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 15))

        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "x = 1\ny = 2")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 11))
    }

    func testTogglingASwiftCommentOnTheCaretsLineAlone() {
        let harness = makeHarness("let a = 1\nlet b = 2", fileExtension: "swift")
        harness.select(3)
        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "// let a = 1\nlet b = 2")
        // The caret keeps its place in the line it was on.
        XCTAssertEqual(harness.caret, 6)

        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "let a = 1\nlet b = 2")
        XCTAssertEqual(harness.caret, 3)
    }

    func testTheTokenGoesInAtTheSmallestCommonIndent() {
        let harness = makeHarness("    a\n        b", fileExtension: "py")
        harness.select(0, 15)
        harness.view.toggleLineComment(nil)
        // Both tokens stand at column 4, the indent the block shares, so the
        // block keeps its shape under the comment.
        XCTAssertEqual(harness.string, "    # a\n    #     b")
        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "    a\n        b")
    }

    func testASelectionWhereOnlySomeLinesAreCommentedCommentsTheRest() {
        let harness = makeHarness("# a\nb\n\nc", fileExtension: "py")
        harness.select(0, 8)
        harness.view.toggleLineComment(nil)
        // The blank line in the middle is left as it is.
        XCTAssertEqual(harness.string, "# # a\n# b\n\n# c")

        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "# a\nb\n\nc")
    }

    func testUncommentingTakesTheSpaceWithTheTokenAndCopesWithout() {
        let harness = makeHarness("#a\n# b", fileExtension: "py")
        harness.select(0, 6)
        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "a\nb")
    }

    func testCommentingIsOneUndoStep() {
        let harness = makeHarness("x = 1\ny = 2", fileExtension: "py")
        harness.select(0, 11)
        harness.view.toggleLineComment(nil)
        harness.undo.undo()
        XCTAssertEqual(harness.string, "x = 1\ny = 2")
        XCTAssertFalse(harness.undo.canUndo)
    }

    func testMarkdownHasNoLineCommentSoTheItemIsOff() {
        let harness = makeHarness("# heading\ntext", fileExtension: "md")
        _ = giveKeyboard(to: harness.view)
        harness.select(0, 14)
        harness.view.toggleLineComment(nil)
        XCTAssertEqual(harness.string, "# heading\ntext")
        XCTAssertFalse(harness.view.validateUserInterfaceItem(
            menuItem(#selector(NotaTextView.toggleLineComment(_:)))
        ))
        // The rest of the line keys are offered on a `.md` note as ever.
        XCTAssertTrue(harness.view.validateUserInterfaceItem(
            menuItem(#selector(NotaTextView.moveLinesUp(_:)))
        ))
    }

    func testEveryTokenIsSpelledForTheExtensionsThatUseIt() {
        for spelling in ["py", "sh", "bash", "zsh", "rb", "yaml", "yml", "toml", "ini", "cfg", "conf"] {
            XCTAssertEqual(LineOperations.commentToken(forExtension: spelling), "#", spelling)
        }
        for spelling in ["js", "ts", "jsx", "tsx", "swift", "c", "h", "cpp", "hpp",
                         "java", "kt", "go", "rs", "cs", "scala", "php"] {
            XCTAssertEqual(LineOperations.commentToken(forExtension: spelling), "//", spelling)
        }
        for spelling in ["sql", "lua", "hs"] {
            XCTAssertEqual(LineOperations.commentToken(forExtension: spelling), "--", spelling)
        }
        for spelling in ["tex", "latex"] {
            XCTAssertEqual(LineOperations.commentToken(forExtension: spelling), "%", spelling)
        }
        for spelling in ["lisp", "clj", "el"] {
            XCTAssertEqual(LineOperations.commentToken(forExtension: spelling), ";", spelling)
        }
        for spelling in ["md", "txt", "html", "css", "json", "", "wat"] {
            XCTAssertNil(LineOperations.commentToken(forExtension: spelling), spelling)
        }
        // The extension is the author's word for the file however it is typed.
        XCTAssertEqual(LineOperations.commentToken(forExtension: "PY"), "#")
    }

    // MARK: - Tab / ⇧Tab and ⌘] / ⌘[

    func testTabWithSeveralLinesInHandIndentsThemAll() {
        let harness = makeHarness("a\nb")
        harness.select(0, 3)
        harness.view.insertTab(nil)
        XCTAssertEqual(harness.string, "\ta\n\tb")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 5))

        harness.view.insertBacktab(nil)
        XCTAssertEqual(harness.string, "a\nb")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 3))
    }

    func testTabOnASingleLineStillInsertsATab() {
        let harness = makeHarness("abc")
        harness.select(1)
        harness.view.insertTab(nil)
        XCTAssertEqual(harness.string, "a\tbc")
        XCTAssertEqual(harness.caret, 2)

        // And so it does with part of one line selected.
        harness.select(2, 1)
        harness.view.insertTab(nil)
        XCTAssertEqual(harness.string, "a\t\tc")
    }

    func testCommandBracketIndentsAndOutdentsASingleLine() {
        let harness = makeHarness("abc\ndef")
        harness.select(1)
        harness.view.indentLines(nil)
        XCTAssertEqual(harness.string, "\tabc\ndef")
        XCTAssertEqual(harness.caret, 2)

        harness.view.outdentLines(nil)
        XCTAssertEqual(harness.string, "abc\ndef")
        XCTAssertEqual(harness.caret, 1)
    }

    func testOutdentTakesATabOrUpToATabsWorthOfSpaces() {
        let harness = makeHarness("\ta\n        b\n  c\nd")
        harness.select(0, 18)
        harness.view.outdentLines(nil)
        XCTAssertEqual(harness.string, "a\n    b\nc\nd")
        // A line with nothing to give back was left alone rather than eaten.
        XCTAssertFalse(harness.string.hasSuffix("\n"))
    }

    func testOutdentWithNoIndentAnywhereChangesNothing() {
        let harness = makeHarness("a\nb")
        harness.select(0, 3)
        harness.view.outdentLines(nil)
        XCTAssertEqual(harness.string, "a\nb")
        XCTAssertFalse(harness.undo.canUndo)
    }

    func testIndentingLeavesTheBlankLinesOfABlockEmpty() {
        let harness = makeHarness("a\n\nb")
        harness.select(0, 4)
        harness.view.indentLines(nil)
        XCTAssertEqual(harness.string, "\ta\n\n\tb")
    }

    func testIndentingIsOneUndoStep() {
        let harness = makeHarness("a\nb")
        harness.select(0, 3)
        harness.view.insertTab(nil)
        harness.undo.undo()
        XCTAssertEqual(harness.string, "a\nb")
        XCTAssertFalse(harness.undo.canUndo)
    }

    // MARK: - When the keys are the editor's at all

    func testTheItemsAreOffWhenTheEditorHasNotGotTheKeyboard() {
        let harness = makeHarness("a\nb", fileExtension: "swift")
        let window = giveKeyboard(to: harness.view)
        let items = [
            menuItem(#selector(NotaTextView.moveLinesUp(_:))),
            menuItem(#selector(NotaTextView.moveLinesDown(_:))),
            menuItem(#selector(NotaTextView.duplicateLines(_:))),
            menuItem(#selector(NotaTextView.duplicateOrSelectNext(_:))),
            menuItem(#selector(NotaTextView.toggleLineComment(_:))),
            menuItem(#selector(NotaTextView.indentLines(_:))),
            menuItem(#selector(NotaTextView.outdentLines(_:))),
        ]
        for item in items {
            XCTAssertTrue(harness.view.validateUserInterfaceItem(item), item.action!.description)
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        for item in items {
            XCTAssertFalse(harness.view.validateUserInterfaceItem(item), item.action!.description)
        }
    }

    func testTheItemsStandAsideForVimUnlessItIsInserting() {
        let harness = makeHarness("a\nb", fileExtension: "swift")
        _ = giveKeyboard(to: harness.view)
        let engine = VimEngine(textView: harness.view)
        engine.pasteboard = NSPasteboard(name: NSPasteboard.Name("LineOps-\(UUID().uuidString)"))
        // The wiring `MainWindowController` puts in.
        harness.view.lineOperationsAllowed = { !engine.isEnabled || engine.mode == .insert }
        let item = menuItem(#selector(NotaTextView.moveLinesDown(_:)))

        XCTAssertTrue(harness.view.validateUserInterfaceItem(item))
        engine.isEnabled = true
        XCTAssertFalse(harness.view.validateUserInterfaceItem(item))
        // And the action itself refuses, not only the item.
        harness.select(0)
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "a\nb")

        for key in VimKey.parse("i") { _ = engine.handle(key) }
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertTrue(harness.view.validateUserInterfaceItem(item))
        harness.view.moveLinesDown(nil)
        XCTAssertEqual(harness.string, "b\na")
    }

    func testTheDuplicateItemSaysWhichOfItsTwoJobsItIsAbout() {
        let harness = makeHarness("foo foo")
        _ = giveKeyboard(to: harness.view)
        let item = menuItem(#selector(NotaTextView.duplicateOrSelectNext(_:)), title: "Duplicate Line")

        harness.select(1)
        XCTAssertTrue(harness.view.validateUserInterfaceItem(item))
        XCTAssertEqual(item.title, "Duplicate Line")

        harness.select(0, 3)
        XCTAssertTrue(harness.view.validateUserInterfaceItem(item))
        XCTAssertEqual(item.title, "Select Next Occurrence")
    }

    func testAReadOnlyTabIsOfferedNoneOfThem() {
        let harness = makeHarness("a\nb")
        _ = giveKeyboard(to: harness.view)
        harness.view.isEditable = false
        XCTAssertFalse(harness.view.validateUserInterfaceItem(
            menuItem(#selector(NotaTextView.duplicateLines(_:)))
        ))
        harness.select(0)
        harness.view.duplicateLines(nil)
        XCTAssertEqual(harness.string, "a\nb")
    }
}
