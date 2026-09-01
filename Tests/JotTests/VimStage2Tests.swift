import AppKit
import XCTest
@testable import Jot

/// Stage two: the operators beyond `d c y`, text objects, visual mode,
/// dot-repeat, named registers, marks and macros.
///
/// The harness types the way `keyDown` does — the engine gets first refusal,
/// and whatever it declines is inserted by the text view, exactly as AppKit
/// would. That matters here: an insert-mode session is part of the change `.`
/// repeats, and part of the keys a macro records, so the tests have to type
/// through the same door the keyboard does.
@MainActor
final class VimStage2Tests: XCTestCase {

    // MARK: - Harness

    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var hosts: [UndoHost] = []

    override func tearDownWithError() throws {
        hosts = []
    }

    @MainActor
    private struct Harness {
        let view: JotTextView
        let engine: VimEngine

        var string: String { view.string }
        var caret: Int { engine.caret }
        var selection: NSRange { view.selectedRange() }

        func type(_ keys: String) {
            for key in VimKey.parse(keys) { send(key) }
        }

        /// What `JotTextView.keyDown` does: vim first, AppKit after — and
        /// then one turn of the run loop, because that is what closes the
        /// undo manager's per-event group. Without it every key in a test
        /// would pile into one group and `u` would undo the whole test.
        private func send(_ key: VimKey) {
            defer { RunLoop.current.run(until: Date()) }
            guard !engine.handle(key) else { return }
            if let character = key.plainCharacter {
                view.insertText(String(character), replacementRange: view.selectedRange())
            } else if key.base == .enter {
                view.insertText("\n", replacementRange: view.selectedRange())
            }
        }
    }

    private func makeHarness(_ text: String = "") throws -> Harness {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = JotTextView(
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

        let engine = VimEngine(textView: view)
        engine.pasteboard = NSPasteboard(name: NSPasteboard.Name("VimStage2-\(UUID().uuidString)"))
        engine.isEnabled = true
        view.vimKeyHandler = { engine.handle($0) }
        return Harness(view: view, engine: engine)
    }

    // MARK: - Indent, dedent, re-indent

    func testShiftOperatorsIndentWholeLinesByTheShiftWidth() throws {
        let harness = try makeHarness("alpha\nbeta\ngamma")

        harness.type(">>")
        XCTAssertEqual(harness.string, "    alpha\nbeta\ngamma")
        XCTAssertEqual(harness.caret, 4, "the caret lands on the first non-blank")

        harness.type("<<")
        XCTAssertEqual(harness.string, "alpha\nbeta\ngamma")

        // A count takes that many lines, not that many shifts.
        harness.type("3>>")
        XCTAssertEqual(harness.string, "    alpha\n    beta\n    gamma")
        harness.type("2<<")
        XCTAssertEqual(harness.string, "alpha\nbeta\n    gamma")
    }

    func testShiftWithAMotionIsAlwaysLinewise() throws {
        let harness = try makeHarness("alpha\nbeta\ngamma")

        // `>j` shifts the two lines the motion touches, not the characters.
        harness.type(">j")
        XCTAssertEqual(harness.string, "    alpha\n    beta\ngamma")

        // Even a charwise motion rounds out to whole lines.
        let word = try makeHarness("alpha beta")
        word.type(">w")
        XCTAssertEqual(word.string, "    alpha beta")
    }

    func testShiftOverAParagraphTextObject() throws {
        let harness = try makeHarness("one\ntwo\n\nthree")
        harness.type(">ip")
        XCTAssertEqual(harness.string, "    one\n    two\n\nthree")
    }

    func testBlankLinesAreLeftAloneByAShift() throws {
        let harness = try makeHarness("one\n\ntwo")
        harness.type("3>>")
        XCTAssertEqual(harness.string, "    one\n\n    two")
    }

    func testReindentMatchesThePreviousNonBlankLine() throws {
        let harness = try makeHarness("    alpha\nbeta\ngamma")

        harness.type("j==")
        XCTAssertEqual(harness.string, "    alpha\n    beta\ngamma")

        // With nothing above it, `=` goes to column zero.
        let top = try makeHarness("        alpha\nbeta")
        top.type("==")
        XCTAssertEqual(top.string, "alpha\nbeta")
    }

    func testReindentOverAMotionTakesEveryLine() throws {
        let harness = try makeHarness("  head\n      one\ntwo\n        three")
        harness.type("j=2j")
        XCTAssertEqual(harness.string, "  head\n  one\n  two\n  three")
    }

    // MARK: - Case

    func testTildeTogglesTheCharacterUnderTheCaretAndMovesOn() throws {
        let harness = try makeHarness("abc def")

        harness.type("~")
        XCTAssertEqual(harness.string, "Abc def")
        XCTAssertEqual(harness.caret, 1)

        harness.type("2~")
        XCTAssertEqual(harness.string, "ABC def")
        XCTAssertEqual(harness.caret, 3)

        // Never past the end of the line.
        harness.type("$20~")
        XCTAssertEqual(harness.string, "ABC deF")
    }

    func testCaseOperatorsWithMotions() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("gUw")
        XCTAssertEqual(harness.string, "ALPHA beta")

        harness.type("guw")
        XCTAssertEqual(harness.string, "alpha beta")

        harness.type("g~$")
        XCTAssertEqual(harness.string, "ALPHA BETA")
    }

    func testDoubledCaseOperatorsTakeWholeLines() throws {
        let harness = try makeHarness("Alpha Beta\nsecond")

        harness.type("gUU")
        XCTAssertEqual(harness.string, "ALPHA BETA\nsecond")
        harness.type("guu")
        XCTAssertEqual(harness.string, "alpha beta\nsecond")
        harness.type("g~~")
        XCTAssertEqual(harness.string, "ALPHA BETA\nsecond")

        // A count takes that many lines.
        let counted = try makeHarness("one\ntwo\nthree")
        counted.type("2gUU")
        XCTAssertEqual(counted.string, "ONE\nTWO\nthree")
    }

    func testCaseOperatorsWithTextObjects() throws {
        let harness = try makeHarness("say (hello there) now")
        harness.type("fhgUi(")
        XCTAssertEqual(harness.string, "say (HELLO THERE) now")
    }

    // MARK: - Join

    func testJoinPutsOneSpaceWhereTheBreakWas() throws {
        let harness = try makeHarness("one\ntwo\nthree")

        harness.type("J")
        XCTAssertEqual(harness.string, "one two\nthree")
        XCTAssertEqual(harness.caret, 3, "the caret sits on the join")

        let counted = try makeHarness("a\nb\nc\nd")
        counted.type("3J")
        XCTAssertEqual(counted.string, "a b c\nd")
    }

    func testJoinTrimsTheIndentOfTheLineItPullsUp() throws {
        let harness = try makeHarness("one\n      two")
        harness.type("J")
        XCTAssertEqual(harness.string, "one two")

        // Nothing is added in front of a closing bracket.
        let bracket = try makeHarness("call(\n)")
        bracket.type("J")
        XCTAssertEqual(bracket.string, "call()")
    }

    // MARK: - Text objects: words

    func testInnerAndOuterWordObjects() throws {
        let inner = try makeHarness("alpha beta gamma")
        inner.type("diw")
        XCTAssertEqual(inner.string, " beta gamma")

        let outer = try makeHarness("alpha beta gamma")
        outer.type("daw")
        XCTAssertEqual(outer.string, "beta gamma")

        // From the middle of a word, still the whole word.
        let middle = try makeHarness("alpha beta gamma")
        middle.type("3ldaw")
        XCTAssertEqual(middle.string, "beta gamma")

        // The last word takes the white space in front of it instead.
        let last = try makeHarness("alpha beta")
        last.type("$daw")
        XCTAssertEqual(last.string, "alpha")
    }

    func testWordObjectsWithCounts() throws {
        let inner = try makeHarness("alpha beta gamma")
        inner.type("d2iw")
        XCTAssertEqual(inner.string, "beta gamma", "a word and the blanks after it")

        let outer = try makeHarness("alpha beta gamma")
        outer.type("d2aw")
        XCTAssertEqual(outer.string, "gamma")
    }

    func testBigWordObjectsIgnorePunctuation() throws {
        let inner = try makeHarness("one.two three")
        inner.type("diW")
        XCTAssertEqual(inner.string, " three")

        let small = try makeHarness("one.two three")
        small.type("diw")
        XCTAssertEqual(small.string, ".two three")

        let outer = try makeHarness("one.two three")
        outer.type("daW")
        XCTAssertEqual(outer.string, "three")
    }

    func testChangeInnerWordLeavesTheCaretInInsertMode() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("ciw")
        XCTAssertEqual(harness.string, " beta")
        XCTAssertEqual(harness.engine.mode, .insert)
        harness.type("omega")
        XCTAssertEqual(harness.string, "omega beta")
    }

    // MARK: - Text objects: sentences and paragraphs

    func testSentenceObjects() throws {
        let inner = try makeHarness("One two. Three four. Five.")
        inner.type("dis")
        XCTAssertEqual(inner.string, " Three four. Five.")

        let outer = try makeHarness("One two. Three four. Five.")
        outer.type("das")
        XCTAssertEqual(outer.string, "Three four. Five.")

        let counted = try makeHarness("One two. Three four. Five.")
        counted.type("d2as")
        XCTAssertEqual(counted.string, "Five.")
    }

    func testParagraphObjectsAreLinewise() throws {
        let inner = try makeHarness("one\ntwo\n\nthree")
        inner.type("dip")
        XCTAssertEqual(inner.string, "\nthree")

        let outer = try makeHarness("one\ntwo\n\nthree")
        outer.type("dap")
        XCTAssertEqual(outer.string, "three")

        // From inside the second paragraph.
        let second = try makeHarness("one\n\ntwo\nthree")
        second.type("3jdip")
        // Taking the last lines takes the newline in front of them too.
        XCTAssertEqual(second.string, "one\n")
    }

    // MARK: - Text objects: quotes

    func testQuoteObjects() throws {
        let inner = try makeHarness("say \"hello\" now")
        inner.type("di\"")
        XCTAssertEqual(inner.string, "say \"\" now")

        let outer = try makeHarness("say \"hello\" now")
        outer.type("da\"")
        XCTAssertEqual(outer.string, "say now")

        // The caret need not be inside: vim finds the next pair on the line.
        let ahead = try makeHarness("say 'hello' now")
        ahead.type("di'")
        XCTAssertEqual(ahead.string, "say '' now")

        let backtick = try makeHarness("a `code` b")
        backtick.type("di`")
        XCTAssertEqual(backtick.string, "a `` b")
    }

    // MARK: - Text objects: pairs

    func testBracketPairObjects() throws {
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")] {
            let inner = try makeHarness("x\(open)abc\(close)y")
            inner.type("lli\(open)".replacingOccurrences(of: "li", with: "ldi"))
            XCTAssertEqual(inner.string, "x\(open)\(close)y", "i\(open)")

            let outer = try makeHarness("x\(open)abc\(close)y")
            outer.type("lllda\(close)")
            XCTAssertEqual(outer.string, "xy", "a\(close)")
        }
    }

    func testBracketAliases() throws {
        let round = try makeHarness("x(abc)y")
        round.type("lldib")
        XCTAssertEqual(round.string, "x()y")

        let curly = try makeHarness("x{abc}y")
        curly.type("lldaB")
        XCTAssertEqual(curly.string, "xy")
    }

    func testBracketObjectsFromTheBracketItself() throws {
        let onOpen = try makeHarness("foo(bar)baz")
        onOpen.type("3ldi(")
        XCTAssertEqual(onOpen.string, "foo()baz")

        let onClose = try makeHarness("foo(bar)baz")
        onClose.type("7ldi(")
        XCTAssertEqual(onClose.string, "foo()baz")
    }

    func testNestedBracketsWithACount() throws {
        let harness = try makeHarness("a(b(c)d)e")
        harness.type("4ld2i(")
        XCTAssertEqual(harness.string, "a()e")
    }

    func testTagObjects() throws {
        let inner = try makeHarness("<a><b>x</b></a>")
        inner.type("6ldit")
        XCTAssertEqual(inner.string, "<a><b></b></a>")

        let outer = try makeHarness("<a><b>x</b></a>")
        outer.type("6ldat")
        XCTAssertEqual(outer.string, "<a></a>")

        let counted = try makeHarness("<a><b>x</b></a>")
        counted.type("6ld2it")
        XCTAssertEqual(counted.string, "<a></a>")
    }

    // MARK: - Visual mode

    func testCharacterwiseVisualSelectsAndDeletes() throws {
        let harness = try makeHarness("abcdef")

        harness.type("v")
        XCTAssertEqual(harness.engine.mode, .visual)
        XCTAssertEqual(harness.engine.cursorStyle, .block)
        harness.type("ll")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 3),
                       "the text view holds the real selection")
        harness.type("d")
        XCTAssertEqual(harness.string, "def")
        XCTAssertEqual(harness.engine.mode, .normal)
    }

    func testLinewiseVisualTakesWholeLines() throws {
        let harness = try makeHarness("one\ntwo\nthree")

        harness.type("V")
        XCTAssertEqual(harness.engine.mode, .visualLine)
        harness.type("j")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 8))
        harness.type("d")
        XCTAssertEqual(harness.string, "three")
    }

    func testVisualSwapsBetweenItsTwoShapes() throws {
        let harness = try makeHarness("one\ntwo")
        harness.type("vl")
        XCTAssertEqual(harness.engine.mode, .visual)
        harness.type("V")
        XCTAssertEqual(harness.engine.mode, .visualLine)
        harness.type("v")
        XCTAssertEqual(harness.engine.mode, .visual)
        harness.type("v")
        XCTAssertEqual(harness.engine.mode, .normal, "the same key again leaves")
    }

    func testVisualOSwapsTheEnds() throws {
        let harness = try makeHarness("abcdef")
        harness.type("vll")
        XCTAssertEqual(harness.caret, 2)
        harness.type("o")
        XCTAssertEqual(harness.caret, 0)
        harness.type("h")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 3),
                       "the head is at the start now, so it cannot go further")
        harness.type("od")
        XCTAssertEqual(harness.string, "def")
    }

    func testVisualWithATextObject() throws {
        let harness = try makeHarness("alpha beta gamma")
        harness.type("viw")
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 5))
        harness.type("d")
        XCTAssertEqual(harness.string, " beta gamma")

        let counted = try makeHarness("alpha beta gamma")
        counted.type("v2awd")
        XCTAssertEqual(counted.string, "gamma")
    }

    func testVisualYankThenPut() throws {
        let harness = try makeHarness("abc")
        harness.type("vly")
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertEqual(harness.caret, 0, "yank leaves the caret at the start")
        harness.type("p")
        XCTAssertEqual(harness.string, "aabbc")
    }

    func testVisualChangeAndCase() throws {
        let change = try makeHarness("alpha beta")
        change.type("vllllc")
        XCTAssertEqual(change.string, " beta")
        XCTAssertEqual(change.engine.mode, .insert)
        change.type("omega")
        XCTAssertEqual(change.string, "omega beta")

        let upper = try makeHarness("alpha beta")
        upper.type("vllllU")
        XCTAssertEqual(upper.string, "ALPHA beta")

        let toggle = try makeHarness("Alpha")
        toggle.type("v$~")
        XCTAssertEqual(toggle.string, "aLPHA")

        let lower = try makeHarness("ALPHA beta")
        lower.type("Vu")
        XCTAssertEqual(lower.string, "alpha beta")
    }

    func testVisualShiftUsesTheCountAsAMultiplier() throws {
        let harness = try makeHarness("one\ntwo")
        harness.type("Vj>")
        XCTAssertEqual(harness.string, "    one\n    two")

        let twice = try makeHarness("one")
        twice.type("V2>")
        XCTAssertEqual(twice.string, "        one")
    }

    func testVisualJoinAndReplace() throws {
        let join = try makeHarness("one\ntwo\nthree")
        join.type("Vjj J")
        XCTAssertEqual(join.string, "one two three")

        let replace = try makeHarness("abcdef")
        replace.type("vllrx")
        XCTAssertEqual(replace.string, "xxxdef")

        // Line breaks inside a selection survive `r`.
        let lines = try makeHarness("ab\ncd")
        lines.type("Vjrz")
        XCTAssertEqual(lines.string, "zz\nzz")
    }

    func testVisualPutReplacesTheSelection() throws {
        let harness = try makeHarness("one two")
        harness.type("yiw")
        harness.type("wviwp")
        XCTAssertEqual(harness.string, "one one")
    }

    func testGvReselectsTheLastSelection() throws {
        let harness = try makeHarness("abcdef")
        harness.type("vll")
        harness.type("<Esc>")
        XCTAssertEqual(harness.engine.mode, .normal)
        harness.type("gg0")
        harness.type("gv")
        XCTAssertEqual(harness.engine.mode, .visual)
        XCTAssertEqual(harness.selection, NSRange(location: 0, length: 3))
        harness.type("d")
        XCTAssertEqual(harness.string, "def")
    }

    func testLeavingVisualSetsTheSelectionMarks() throws {
        let harness = try makeHarness("abcdef")
        harness.type("lvll")
        harness.type("<Esc>")
        XCTAssertEqual(harness.caret, 3, "the caret stays where the head was")
        XCTAssertEqual(harness.engine.marks.location("<"), 1)
        XCTAssertEqual(harness.engine.marks.location(">"), 3)

        harness.type("gg0d'>")
        XCTAssertEqual(harness.string, "", "`'>` is a linewise motion to the mark")
    }

    func testEscapeAlternativesLeaveVisualMode() throws {
        for keys in ["<Esc>", "<C-[>", "<C-c>"] {
            let harness = try makeHarness("abc")
            harness.type("vl")
            XCTAssertEqual(harness.engine.mode, .visual)
            harness.type(keys)
            XCTAssertEqual(harness.engine.mode, .normal, "\(keys) should leave visual mode")
            XCTAssertEqual(harness.selection.length, 0)
        }
    }

    // MARK: - Dot repeat

    func testDotRepeatsAnOperatorAndMotion() throws {
        let harness = try makeHarness("one two three four")
        harness.type("dw")
        XCTAssertEqual(harness.string, "two three four")
        harness.type(".")
        XCTAssertEqual(harness.string, "three four")
        harness.type(".")
        XCTAssertEqual(harness.string, "four")
    }

    func testDotRepeatsATextObjectChange() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("ciwfoo<Esc>")
        XCTAssertEqual(harness.string, "foo beta")
        XCTAssertEqual(harness.engine.mode, .normal)

        harness.type("w.")
        XCTAssertEqual(harness.string, "foo foo", "`.` redoes the typing too")
    }

    func testDotRepeatsAnInsertSession() throws {
        let harness = try makeHarness("ab")
        harness.type("ix<Esc>")
        XCTAssertEqual(harness.string, "xab")
        harness.type("$.")
        XCTAssertEqual(harness.string, "xaxb")
    }

    func testDotRepeatsTheSmallEdits() throws {
        let deleted = try makeHarness("abcdef")
        deleted.type("x.")
        XCTAssertEqual(deleted.string, "cdef")

        let toggled = try makeHarness("abc")
        toggled.type("~.")
        XCTAssertEqual(toggled.string, "ABc")

        let replaced = try makeHarness("abc")
        replaced.type("rx")
        XCTAssertEqual(replaced.string, "xbc")
        replaced.type("l.")
        XCTAssertEqual(replaced.string, "xxc")

        let joined = try makeHarness("a\nb\nc")
        joined.type("J.")
        XCTAssertEqual(joined.string, "a b c")

        let shifted = try makeHarness("one\ntwo")
        shifted.type(">>j.")
        XCTAssertEqual(shifted.string, "    one\n    two")
    }

    func testDotRepeatsAPut() throws {
        let harness = try makeHarness("abc")
        harness.type("yy")
        harness.type("p")
        // Vim leaves no trailing newline behind a put below the last line.
        XCTAssertEqual(harness.string, "abc\nabc")
        harness.type(".")
        XCTAssertEqual(harness.string, "abc\nabc\nabc")
    }

    func testACountOnDotReplacesTheOriginalCount() throws {
        let harness = try makeHarness("1\n2\n3\n4\n5")
        harness.type("dd")
        XCTAssertEqual(harness.string, "2\n3\n4\n5")
        harness.type("3.")
        XCTAssertEqual(harness.string, "5")
    }

    func testUndoTakesAWholeDotRepeatAtOnce() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("ciwfoo<Esc>")
        harness.type("w.")
        XCTAssertEqual(harness.string, "foo foo")
        harness.type("u")
        XCTAssertEqual(harness.string, "foo beta", "one `.` is one undo")
    }

    func testYankIsNotAChangeAndDotIgnoresIt() throws {
        let harness = try makeHarness("one two three")
        harness.type("dw")
        XCTAssertEqual(harness.string, "two three")
        harness.type("yw")
        harness.type(".")
        XCTAssertEqual(harness.string, "three", "`.` still repeats the delete")
    }

    // MARK: - Registers

    func testNamedRegistersHoldYanksAndPutThemBack() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("\"ayy")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "one\n")
        XCTAssertTrue(harness.engine.registers.read("a")?.isLinewise == true)

        harness.type("j\"ap")
        XCTAssertEqual(harness.string, "one\ntwo\none\nthree")
    }

    func testAnUppercaseRegisterAppends() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("\"ayy")
        harness.type("j\"Ayy")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "one\ntwo\n")

        harness.type("G\"ap")
        XCTAssertEqual(harness.string, "one\ntwo\nthree\none\ntwo")
    }

    func testCharacterwiseAndLinewiseRegistersStaySeparate() throws {
        let harness = try makeHarness("abc\ndef")
        harness.type("\"ayy")
        harness.type("\"byiw")
        XCTAssertEqual(harness.engine.registers.read("b")?.isLinewise, false)

        harness.type("j$\"bp")
        XCTAssertEqual(harness.string, "abc\ndefabc", "charwise lands beside the caret")

        harness.type("\"aP")
        XCTAssertEqual(harness.string, "abc\nabc\ndefabc", "linewise lands on its own line")
    }

    func testTheYankRegisterSurvivesADelete() throws {
        let harness = try makeHarness("keep\ndrop\nrest")
        harness.type("yy")
        harness.type("jdd")
        XCTAssertEqual(harness.string, "keep\nrest")
        XCTAssertEqual(harness.engine.registers.read("0")?.text, "keep\n")
        harness.type("\"0p")
        XCTAssertEqual(harness.string, "keep\nrest\nkeep")
    }

    func testDeletesShiftAlongTheNumberedRegisters() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("dd")
        harness.type("dd")
        XCTAssertEqual(harness.engine.registers.read("1")?.text, "two\n")
        XCTAssertEqual(harness.engine.registers.read("2")?.text, "one\n")
    }

    func testASmallDeleteGoesToTheDashRegister() throws {
        let harness = try makeHarness("abc\ndef")
        harness.type("x")
        XCTAssertEqual(harness.engine.registers.read("-")?.text, "a")
        // A whole line is not small, so it leaves `"-` alone.
        harness.type("dd")
        XCTAssertEqual(harness.engine.registers.read("-")?.text, "a")
    }

    func testTheBlackHoleRegisterSwallowsEverything() throws {
        let harness = try makeHarness("keep\ndrop\nrest")
        harness.type("yy")
        harness.type("j\"_dd")
        XCTAssertEqual(harness.string, "keep\nrest")
        XCTAssertNil(harness.engine.registers.read("_"))
        harness.type("p")
        XCTAssertEqual(harness.string, "keep\nrest\nkeep", "the yank is still there")
    }

    func testThePlusRegisterIsThePasteboard() throws {
        let harness = try makeHarness("abc\ndef")
        harness.type("\"+yy")
        harness.type("j\"+p")
        XCTAssertEqual(harness.string, "abc\ndef\nabc")
    }

    // MARK: - Marks

    func testMarksRememberAPlaceAndJumpBackToIt() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("jlma")
        XCTAssertEqual(harness.engine.marks.location("a"), 5)

        harness.type("gg")
        XCTAssertEqual(harness.caret, 0)
        harness.type("`a")
        XCTAssertEqual(harness.caret, 5, "backtick is exact")

        harness.type("gg'a")
        XCTAssertEqual(harness.caret, 4, "a straight quote is the first non-blank")
    }

    func testMarksMoveWithTheTextAroundThem() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("2jma")
        XCTAssertEqual(harness.engine.marks.location("a"), 8)

        harness.type("ggdd")
        XCTAssertEqual(harness.string, "two\nthree")
        XCTAssertEqual(harness.engine.marks.location("a"), 4)
        harness.type("`a")
        XCTAssertEqual(harness.caret, 4)

        // Typing in front of a mark pushes it along too.
        harness.type("ggixx<Esc>")
        XCTAssertEqual(harness.engine.marks.location("a"), 6)
    }

    func testMarksAsOperatorMotions() throws {
        let linewise = try makeHarness("one\ntwo\nthree")
        linewise.type("2jma")
        linewise.type("ggd'a")
        XCTAssertEqual(linewise.string, "", "a quote mark is linewise")

        let charwise = try makeHarness("one\ntwo\nthree")
        charwise.type("2jma")
        charwise.type("ggd`a")
        XCTAssertEqual(charwise.string, "three", "a backtick mark is charwise")
    }

    func testTheMarksVimKeepsForYou() throws {
        let harness = try makeHarness("one\ntwo\nthree")

        // `'^` is where insert mode was left.
        harness.type("jA!<Esc>")
        XCTAssertEqual(harness.string, "one\ntwo!\nthree")
        XCTAssertEqual(harness.engine.marks.location("^"), 8)

        // `'.` is the last change.
        harness.type("ggx")
        XCTAssertEqual(harness.engine.marks.location("."), 0)

        // A jump leaves a backtick behind at where it set off from.
        harness.type("2jma")
        harness.type("gg")
        harness.type("`a")
        XCTAssertEqual(harness.caret, 8)
        harness.type("``")
        XCTAssertEqual(harness.caret, 0, "back to where the jump started")
    }

    func testAnUnsetMarkSaysSoRatherThanMoving() throws {
        let harness = try makeHarness("one\ntwo")
        // The spy the stage-three tests use; the message is all this one wants.
        let host = VimHostSpy()
        harness.engine.host = host

        harness.type("j`z")
        XCTAssertEqual(harness.caret, 4, "no move")
        XCTAssertEqual(host.messages, ["Mark not set"])
    }

    // MARK: - Macros

    func testRecordingAndPlayingAMacro() throws {
        let harness = try makeHarness("abcdefgh")
        harness.type("qaxq")
        XCTAssertEqual(harness.string, "bcdefgh")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "x")

        harness.type("@a")
        XCTAssertEqual(harness.string, "cdefgh")
        harness.type("3@a")
        XCTAssertEqual(harness.string, "fgh")
    }

    func testAtAtRepeatsTheLastMacro() throws {
        let harness = try makeHarness("abcdefgh")
        harness.type("qaxq@a")
        XCTAssertEqual(harness.string, "cdefgh")
        harness.type("@@")
        XCTAssertEqual(harness.string, "defgh")
        harness.type("2@@")
        XCTAssertEqual(harness.string, "fgh")
    }

    func testAMacroRecordsInsertModeTypingToo() throws {
        let harness = try makeHarness("one\ntwo")
        harness.type("qbA!<Esc>q")
        XCTAssertEqual(harness.string, "one!\ntwo")
        XCTAssertEqual(harness.engine.registers.read("b")?.text, "A!<Esc>")

        harness.type("j@b")
        XCTAssertEqual(harness.string, "one!\ntwo!")
    }

    func testAYankedLineRunsAsAMacro() throws {
        let harness = try makeHarness("3x\nabcdefgh")
        harness.type("\"ayy")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "3x\n")
        harness.type("j@a")
        XCTAssertEqual(harness.string, "3x\ndefgh")
    }

    func testTheFooterSaysWhichMacroIsRecording() throws {
        let harness = try makeHarness("abc")
        var pending: [String] = []
        harness.engine.onPendingKeysChange = { pending.append($0) }

        harness.type("qa")
        XCTAssertEqual(pending.last, "recording @a")
        harness.type("d")
        XCTAssertEqual(pending.last, "d recording @a", "showcmd sits beside it")
        harness.type("w")
        harness.type("q")
        XCTAssertEqual(pending.last, "", "the badge goes quiet again")
    }

    func testAnUppercaseMacroRegisterAppends() throws {
        let harness = try makeHarness("abcdef")
        harness.type("qaxq")
        harness.type("qAxq")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "xx")
        XCTAssertEqual(harness.string, "cdef")
        harness.type("@a")
        XCTAssertEqual(harness.string, "ef")
    }

    func testInsertFromVisualLeavesVisualModeProperly() throws {
        let harness = try makeHarness("abcdef")
        harness.type("vll")
        harness.type("A")
        XCTAssertEqual(harness.engine.mode, .insert)
        XCTAssertEqual(harness.selection.length, 0, "no selection is left behind")
        XCTAssertEqual(harness.engine.marks.location("<"), 0)
        XCTAssertEqual(harness.engine.marks.location(">"), 2)
        harness.type("x")
        XCTAssertEqual(harness.string, "abcdefx", "`A` still appends to the line")
    }

    func testCommandShortcutsStillWorkInVisualMode() throws {
        let harness = try makeHarness("abc")
        harness.type("vl")
        XCTAssertEqual(harness.engine.mode, .visual)

        let save = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "s",
            charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 0
        ))
        XCTAssertFalse(harness.engine.handle(save), "⌘S belongs to the menus")
        XCTAssertEqual(harness.engine.mode, .visual)
    }

    func testAVisualChangeLeavesTheDotCommandAlone() throws {
        let harness = try makeHarness("one two three four")
        harness.type("dw")
        XCTAssertEqual(harness.string, "two three four")

        // A visual delete cannot be replayed — the keys that made the
        // selection are gone — so `.` keeps the command it already had.
        harness.type("vld")
        XCTAssertEqual(harness.string, "o three four")
        harness.type("0.")
        XCTAssertEqual(harness.string, "three four")
        XCTAssertEqual(harness.engine.mode, .normal)
    }

    func testReindentOverATextObject() throws {
        let harness = try makeHarness("  head\n\n    one\n        two")
        harness.type("2j=ip")
        XCTAssertEqual(harness.string, "  head\n\n  one\n  two",
                       "the nearest non-blank line above sets the indent")
    }

    // MARK: - Showcmd

    func testShowcmdCarriesTheRegisterAndTheTextObject() throws {
        let harness = try makeHarness("alpha beta")
        var pending: [String] = []
        harness.engine.onPendingKeysChange = { pending.append($0) }

        harness.type("\"")
        XCTAssertEqual(pending.last, "\"")
        harness.type("a")
        XCTAssertEqual(pending.last, "\"a")
        harness.type("d")
        XCTAssertEqual(pending.last, "\"ad")
        harness.type("i")
        XCTAssertEqual(pending.last, "\"adi")
        harness.type("w")
        XCTAssertEqual(pending.last, "")
        XCTAssertEqual(harness.string, " beta")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "alpha")
    }
}
