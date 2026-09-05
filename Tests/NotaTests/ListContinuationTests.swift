import AppKit
import XCTest
@testable import Nota

/// Return at the end of a list item. The marker arithmetic is pure, so most
/// of this reads a line and asks what the next one opens with; the last test
/// drives a real `NotaTextView` through the key itself.
@MainActor
final class ListContinuationTests: XCTestCase {

    // MARK: - The next marker

    /// What a new line under `line` opens with, or nil where the line is not
    /// a list item at all.
    private func next(_ line: String, above: String? = nil) -> String? {
        ListMarker.parse(line: line, above: above)?.next().prefix
    }

    func testArabicNumbersStepOnKeepingTheirDelimiter() {
        XCTAssertEqual(next("1. hello"), "2. ")
        XCTAssertEqual(next("9) hello"), "10) ")
        XCTAssertEqual(next("42. hello"), "43. ")
    }

    func testLettersStepOnAndCarryPast() {
        XCTAssertEqual(next("a. one"), "b. ")
        XCTAssertEqual(next("a) one"), "b) ")
        XCTAssertEqual(next("z. one"), "aa. ")
        XCTAssertEqual(next("aa. one"), "ab. ")
    }

    func testUpperCaseLettersStayUpperCase() {
        XCTAssertEqual(next("A. one"), "B. ")
        XCTAssertEqual(next("Z) one"), "AA) ")
    }

    /// A lone `i` with nothing above it is the numeral, not the letter.
    func testALoneRomanOneWithNothingAboveItIsANumeral() {
        XCTAssertEqual(next("i. one"), "ii. ")
        XCTAssertEqual(next("I. one"), "II. ")
    }

    /// …but `h.` above it settles it as the letter.
    func testALetterAboveMakesALoneRomanOneALetter() {
        XCTAssertEqual(next("i. one", above: "h. eight"), "j. ")
        XCTAssertEqual(next("I. one", above: "H. eight"), "J. ")
        // The case has to match too: a lower-case list above says nothing
        // about an upper-case item.
        XCTAssertEqual(next("I. one", above: "viii. eight"), "II. ")
    }

    func testARomanAboveKeepsALoneRomanOneANumeral() {
        XCTAssertEqual(next("i. one", above: "viii. eight"), "ii. ")
    }

    func testNumeralsThatCanOnlyBeNumeralsNeverAsk() {
        XCTAssertEqual(next("viii. eight"), "ix. ")
        XCTAssertEqual(next("IV. four"), "V. ")
        XCTAssertEqual(next("X) ten"), "XI) ")
        XCTAssertEqual(next("xii. twelve"), "xiii. ")
        // And letters that can only be letters do not either.
        XCTAssertEqual(next("b. two", above: "iv. four"), "c. ")
        XCTAssertEqual(next("k. eleven"), "l. ")
    }

    func testBulletsAreHandedOnUnchanged() {
        XCTAssertEqual(next("- one"), "- ")
        XCTAssertEqual(next("* one"), "* ")
        XCTAssertEqual(next("+ one"), "+ ")
    }

    func testATaskBoxComesBackFreshAndUnticked() {
        XCTAssertEqual(next("- [ ] milk"), "- [ ] ")
        XCTAssertEqual(next("- [x] milk"), "- [ ] ")
        XCTAssertEqual(next("2. [x] milk"), "3. [ ] ")
    }

    func testTheIndentIsKept() {
        XCTAssertEqual(next("   2. x"), "   3. ")
        XCTAssertEqual(next("\t\ta. x"), "\t\tb. ")
        XCTAssertEqual(next("  - [ ] x"), "  - [ ] ")
    }

    func testAPlainLineIsNotAListItem() {
        XCTAssertNil(next("hello"))
        XCTAssertNil(next(""))
        // A marker needs a space after it, or it is a word.
        XCTAssertNil(next("1.hello"))
        XCTAssertNil(next("Note. a sentence"))
        XCTAssertNil(next("2024.was a year"))
    }

    // MARK: - The whole edit

    private func edit(_ text: String, at caret: Int) -> ListContinuation.Edit? {
        ListContinuation.edit(
            forReturnIn: text as NSString, at: NSRange(location: caret, length: 0)
        )
    }

    /// The edit applied to the text, and where the caret ends up — what the
    /// editor would show.
    private func typed(_ text: String, at caret: Int) -> (String, Int)? {
        guard let edit = edit(text, at: caret) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        return (result, edit.caret)
    }

    func testReturnAtTheEndOfAnItemOpensTheNextOne() {
        let result = typed("1. hello", at: 8)
        XCTAssertEqual(result?.0, "1. hello\n2. ")
        XCTAssertEqual(result?.1, 12)
    }

    func testReturnInTheMiddleOfAnItemTakesTheRestWithIt() {
        let result = typed("1. hello", at: 6)
        XCTAssertEqual(result?.0, "1. hel\n2. lo")
        XCTAssertEqual(result?.1, 10)
    }

    func testReturnInsideTheMarkerIsAPlainNewline() {
        XCTAssertNil(edit("1. hello", at: 1))
        XCTAssertNil(edit("1. hello", at: 2))
    }

    func testAnItemWithNothingOnItEndsTheList() {
        let result = typed("1. one\n2. ", at: 10)
        XCTAssertEqual(result?.0, "1. one\n")
        XCTAssertEqual(result?.1, 7)
    }

    func testAnEmptyTaskBoxEndsTheListToo() {
        let result = typed("- [x] milk\n- [ ] ", at: 17)
        XCTAssertEqual(result?.0, "- [x] milk\n")
        XCTAssertEqual(result?.1, 11)
    }

    func testTheLineAboveIsReadThroughBlankLinesAndDeeperIndents() {
        // `h.` two lines up, with a blank one between, still settles the `i.`.
        let result = typed("h. eight\n\ni. nine", at: 17)
        XCTAssertEqual(result?.0, "h. eight\n\ni. nine\nj. ")
    }

    func testALineAboveAtADifferentIndentSaysNothing() {
        // The `h.` is a list of its own, so the indented `i.` is a numeral.
        let result = typed("h. eight\n   i. nine", at: 19)
        XCTAssertEqual(result?.0, "h. eight\n   i. nine\n   ii. ")
    }

    func testASelectionWithAnythingInItIsLeftAlone() {
        XCTAssertNil(ListContinuation.edit(
            forReturnIn: "1. hello" as NSString, at: NSRange(location: 3, length: 5)
        ))
    }

    // MARK: - Through the editor

    func testTheEditorContinuesTheListInOneUndoStep() {
        let harness = makeHarness("1. hello")
        harness.view.setSelectedRange(NSRange(location: 8, length: 0))
        harness.view.insertNewline(nil)

        XCTAssertEqual(harness.view.string, "1. hello\n2. ")
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 12, length: 0))

        harness.undo.undo()
        XCTAssertEqual(harness.view.string, "1. hello")
    }

    func testTheEditorStillPutsAPlainNewlineInOnAPlainLine() {
        let harness = makeHarness("hello")
        harness.view.setSelectedRange(NSRange(location: 5, length: 0))
        harness.view.insertNewline(nil)
        XCTAssertEqual(harness.view.string, "hello\n")
    }

    func testTheEditorEndsTheListOnAnEmptyItem() {
        let harness = makeHarness("- one\n- ")
        harness.view.setSelectedRange(NSRange(location: 8, length: 0))
        harness.view.insertNewline(nil)
        XCTAssertEqual(harness.view.string, "- one\n")
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 6, length: 0))
    }

    /// Vim owns the keys everywhere but insert mode, and the list hand stands
    /// aside with the rest of them.
    func testVimOutsideInsertModeGetsAPlainNewline() {
        let harness = makeHarness("1. hello")
        harness.view.lineOperationsAllowed = { false }
        harness.view.setSelectedRange(NSRange(location: 8, length: 0))
        harness.view.insertNewline(nil)
        XCTAssertEqual(harness.view.string, "1. hello\n")
    }

    // MARK: - Harness

    /// Holds the undo manager: `NSTextView` asks its delegate for one, and a
    /// view with no window has nowhere else to get it.
    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var hosts: [UndoHost] = []

    override func tearDownWithError() throws { hosts = [] }

    @MainActor
    private struct Harness {
        let view: NotaTextView
        let undo: UndoManager
    }

    private func makeHarness(_ text: String) -> Harness {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = NotaTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container
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
        return Harness(view: view, undo: host.manager)
    }
}
