import AppKit
import XCTest
@testable import Nota

/// Everything the window would do for the engine, written down instead.
///
/// Shared with the stage-two tests, which need it for the one host call they
/// make; here it is what proves that `:w`, `:q`, `/` and `:help` reach the
/// outside world with the right arguments without a window ever existing.
final class VimHostSpy: VimEngineHost {
    var tabOffsets: [Int] = []
    var messages: [String] = []
    var commandLines: [String?] = []
    var saved: [String?] = []
    var closed: [Bool] = []
    var opened: [String] = []
    var newTabs = 0
    var scratchTabs: [(title: String, text: String)] = []
    /// How many times the pane's message was taken away by the next key.
    var messagesCleared = 0
    /// What `:w` reports back, which is what `:wq` waits for.
    var saveSucceeds = true

    func vimSelectTab(offset: Int) { tabOffsets.append(offset) }
    func vimShow(message: String) { messages.append(message) }
    func vimCommandLineChanged(_ text: String?) { commandLines.append(text) }
    func vimSave(name: String?) -> Bool {
        saved.append(name)
        return saveSucceeds
    }
    func vimClose(force: Bool) { closed.append(force) }
    func vimOpen(path: String) { opened.append(path) }
    func vimNewTab() { newTabs += 1 }
    func vimOpenScratchTab(title: String, text: String) {
        scratchTabs.append((title, text))
    }
    func vimClearMessage() { messagesCleared += 1 }
}

/// Stage three: the `:` line, the ex commands and their ranges, the searching
/// the native find bar does, and the read-only scratch tabs.
///
/// Same harness as stage two — keys go through the door `keyDown` uses and the
/// run loop turns once a key, so the undo manager groups a test's commands the
/// way it groups a person's.
@MainActor
final class VimStage3Tests: XCTestCase {

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
        let view: NotaTextView
        let engine: VimEngine
        let host: VimHostSpy

        var string: String { view.string }
        var caret: Int { engine.caret }

        func type(_ keys: String) {
            for key in VimKey.parse(keys) { send(key) }
        }

        /// A whole `:` command, without typing it — what most of the ex tests
        /// want, since the typing has tests of its own.
        func run(_ command: String) {
            engine.run(command)
            RunLoop.current.run(until: Date())
        }

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

        let engine = VimEngine(textView: view)
        // Private boards throughout: a test run must never touch the real
        // clipboard, and `*` must never disturb a real find bar.
        engine.pasteboard = NSPasteboard(name: NSPasteboard.Name("VimStage3-\(UUID().uuidString)"))
        engine.isEnabled = true
        view.vimKeyHandler = { engine.handle($0) }

        let spy = VimHostSpy()
        engine.host = spy
        return Harness(view: view, engine: engine, host: spy)
    }

    // MARK: - The command line

    func testColonOpensTheCommandLineInTheFooter() throws {
        let harness = try makeHarness("alpha")
        harness.type(":")
        XCTAssertEqual(harness.engine.mode, .commandLine)
        XCTAssertEqual(harness.host.commandLines.last, ":")

        harness.type("wq")
        XCTAssertEqual(harness.engine.commandLine, "wq")
        XCTAssertEqual(harness.host.commandLines.last, ":wq")
        // The note keeps its caret: the command line is not a text field.
        XCTAssertEqual(harness.view.selectedRange().location, 0)
    }

    func testShowcmdDoesNotStealTheCommandLinesSlot() throws {
        let harness = try makeHarness("alpha")
        harness.type(":")
        var pending: [String] = []
        harness.engine.onPendingKeysChange = { pending.append($0) }
        harness.type("s/a/b/")
        XCTAssertTrue(pending.isEmpty, "nothing publishes showcmd while `:` is up")

        // Closing it hands the slot back.
        harness.type("<Esc>")
        XCTAssertEqual(pending, [""])
    }

    func testBackspaceEditsTheCommandLineAndAnEmptyOneCancels() throws {
        let harness = try makeHarness("alpha")
        harness.type(":se")
        harness.type("<BS>")
        XCTAssertEqual(harness.engine.commandLine, "s")
        harness.type("<BS>")
        XCTAssertEqual(harness.engine.commandLine, "")
        harness.type("<BS>")
        XCTAssertNil(harness.engine.commandLine)
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertNil(harness.host.commandLines.last ?? "still open")
    }

    func testEscapeAndControlCCancelTheCommandLine() throws {
        let harness = try makeHarness("alpha")
        harness.type(":sort")
        harness.type("<Esc>")
        XCTAssertNil(harness.engine.commandLine)
        XCTAssertEqual(harness.engine.mode, .normal)

        harness.type(":sort")
        harness.type("<C-c>")
        XCTAssertNil(harness.engine.commandLine)
        XCTAssertEqual(harness.engine.mode, .normal)

        harness.type(":sort")
        harness.type("<C-[>")
        XCTAssertNil(harness.engine.commandLine)
    }

    func testControlWAndControlUEditTheCommandLine() throws {
        let harness = try makeHarness("alpha")
        harness.type(":e one two")
        harness.type("<C-w>")
        XCTAssertEqual(harness.engine.commandLine, "e one ")
        harness.type("<C-u>")
        XCTAssertEqual(harness.engine.commandLine, "")
        XCTAssertEqual(harness.engine.mode, .commandLine, "⌃U empties it rather than closing it")
    }

    func testDroppingTheLastWordTakesItsTrailingSpaces() {
        XCTAssertEqual(VimEngine.droppingLastWord("e one two"), "e one ")
        XCTAssertEqual(VimEngine.droppingLastWord("e one   "), "e ")
        XCTAssertEqual(VimEngine.droppingLastWord("word"), "")
        XCTAssertEqual(VimEngine.droppingLastWord(""), "")
    }

    func testEnterRunsTheCommandAndClosesTheLine() throws {
        let harness = try makeHarness("alpha\nbeta\ngamma")
        harness.type(":2<CR>")
        XCTAssertNil(harness.engine.commandLine)
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertEqual(harness.caret, 6, "the caret went to line two")
        XCTAssertNil(harness.host.commandLines.last ?? "still open")
    }

    func testTheHistoryWalksWithTheArrowKeys() throws {
        let harness = try makeHarness("alpha")
        harness.type(":noh<CR>")
        harness.type(":set cursorline<CR>")

        harness.type(":dr")
        harness.type("<Up>")
        XCTAssertEqual(harness.engine.commandLine, "set cursorline")
        harness.type("<Up>")
        XCTAssertEqual(harness.engine.commandLine, "noh")
        harness.type("<Up>")
        XCTAssertEqual(harness.engine.commandLine, "noh", "the oldest one stays")
        harness.type("<Down>")
        XCTAssertEqual(harness.engine.commandLine, "set cursorline")
        harness.type("<Down>")
        XCTAssertEqual(harness.engine.commandLine, "dr", "and back to what was being typed")
    }

    func testTheHistoryKeepsOneCopyOfARepeatedCommand() throws {
        let harness = try makeHarness("alpha")
        harness.type(":noh<CR>")
        harness.type(":set cursorline<CR>")
        harness.type(":noh<CR>")
        XCTAssertEqual(harness.engine.history(for: ":"), ["set cursorline", "noh"])
    }

    /// The line itself knows nothing about the colon: `:` and `/` are the
    /// same typing, the same history and the same pane.
    func testThePromptIsTheSameWhicheverCharacterOpenedIt() throws {
        let harness = try makeHarness("alpha")
        harness.type("/")
        harness.type("lph")
        XCTAssertEqual(harness.engine.prompt, VimPrompt(prefix: "/", text: "lph"))
        XCTAssertEqual(harness.host.commandLines.last, "/lph")

        harness.type("<C-w>a<CR>")
        XCTAssertNil(harness.engine.prompt)
        XCTAssertEqual(harness.string, "alpha", "and nothing reaches the note")

        // Each prompt keeps its own history, the way vim keeps `:` and `/`
        // apart.
        harness.run("noh")
        XCTAssertEqual(harness.engine.history(for: "/"), ["a"])
        XCTAssertEqual(harness.engine.history(for: ":"), ["noh"])

        harness.type("/<Up>")
        XCTAssertEqual(harness.engine.commandLine, "a")
        harness.type("<Esc>")
    }

    func testVisualColonPrefillsTheSelectionsRange() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("Vj:")
        XCTAssertEqual(harness.engine.commandLine, "'<,'>")
        XCTAssertEqual(harness.engine.mode, .commandLine)
        XCTAssertEqual(harness.host.commandLines.last, ":'<,'>")

        harness.type("d<CR>")
        XCTAssertEqual(harness.string, "three")
    }

    func testAMacroCanRecordAndReplayAnExCommand() throws {
        let harness = try makeHarness("aa\naa\naa")
        harness.type("qc:s/aa/bb/<CR>q")
        XCTAssertEqual(harness.string, "bb\naa\naa")
        XCTAssertEqual(harness.engine.registers.read("c")?.text, ":s/aa/bb/<CR>")

        harness.type("j@c")
        XCTAssertEqual(harness.string, "bb\nbb\naa")
    }

    func testCommandShortcutsStillWorkWithTheCommandLineOpen() throws {
        let harness = try makeHarness("alpha")
        harness.type(":w")

        let save = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "s",
            charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 0
        ))
        XCTAssertFalse(harness.engine.handle(save), "⌘S belongs to the menus")
        XCTAssertEqual(harness.engine.commandLine, "w", "and it does not reach the line")
        XCTAssertEqual(harness.engine.mode, .commandLine)
    }

    // MARK: - Parsing: names

    func testTheNamesVimAcceptsResolve() {
        XCTAssertEqual(VimEx.resolve("s"), .substitute)
        XCTAssertEqual(VimEx.resolve("su"), .substitute)
        XCTAssertEqual(VimEx.resolve("substitute"), .substitute)
        XCTAssertEqual(VimEx.resolve("d"), .delete)
        XCTAssertEqual(VimEx.resolve("delete"), .delete)
        XCTAssertEqual(VimEx.resolve("y"), .yank)
        XCTAssertEqual(VimEx.resolve("j"), .join)
        XCTAssertEqual(VimEx.resolve("m"), .move)
        XCTAssertEqual(VimEx.resolve("t"), .copy)
        XCTAssertEqual(VimEx.resolve("co"), .copy)
        XCTAssertEqual(VimEx.resolve("copy"), .copy)
        XCTAssertEqual(VimEx.resolve("sor"), .sort)
        XCTAssertEqual(VimEx.resolve("sort"), .sort)
        XCTAssertEqual(VimEx.resolve("w"), .write)
        XCTAssertEqual(VimEx.resolve("wq"), .writeQuit)
        XCTAssertEqual(VimEx.resolve("x"), .exit)
        XCTAssertEqual(VimEx.resolve("q"), .quit)
        XCTAssertEqual(VimEx.resolve("e"), .edit)
        XCTAssertEqual(VimEx.resolve("noh"), .noHighlight)
        XCTAssertEqual(VimEx.resolve("nohlsearch"), .noHighlight)
        XCTAssertEqual(VimEx.resolve("tabnew"), .tabNew)
        XCTAssertEqual(VimEx.resolve("tabn"), .tabNext)
        XCTAssertEqual(VimEx.resolve("tabp"), .tabPrevious)
        XCTAssertEqual(VimEx.resolve("bn"), .tabNext)
        XCTAssertEqual(VimEx.resolve("bp"), .tabPrevious)
        XCTAssertEqual(VimEx.resolve("h"), .help)
        XCTAssertEqual(VimEx.resolve("help"), .help)
        XCTAssertEqual(VimEx.resolve("reg"), .registers)
        XCTAssertEqual(VimEx.resolve("registers"), .registers)
        XCTAssertEqual(VimEx.resolve("marks"), .marks)
        XCTAssertEqual(VimEx.resolve("se"), .set)
        XCTAssertEqual(VimEx.resolve("set"), .set)
        XCTAssertEqual(VimEx.resolve("zzz"), .unknown("zzz"))
    }

    func testACommandIsItsNameBangAndArgument() {
        XCTAssertEqual(VimEx.parse("q!")?.name, .quit)
        XCTAssertEqual(VimEx.parse("q!")?.bang, true)
        XCTAssertEqual(VimEx.parse("w notes.md")?.argument, "notes.md")
        XCTAssertEqual(VimEx.parse(":w  notes.md ")?.argument, "notes.md")
        XCTAssertEqual(VimEx.parse("sort!")?.bang, true)
        XCTAssertNil(VimEx.parse(""))
        XCTAssertNil(VimEx.parse("   "))
    }

    // MARK: - Parsing: ranges

    func testEveryRangeFormParses() {
        XCTAssertEqual(
            VimEx.parse("10,20d")?.range,
            VimExRange(start: .line(10), end: .line(20))
        )
        XCTAssertEqual(VimEx.parse("%s/a/b/")?.range, .whole)
        XCTAssertEqual(VimEx.parse("'<,'>d")?.range, .visual)
        XCTAssertEqual(
            VimEx.parse(".,$d")?.range, VimExRange(start: .current, end: .last)
        )
        XCTAssertEqual(
            VimEx.parse("'a,'bd")?.range,
            VimExRange(start: .mark("a"), end: .mark("b"))
        )
        XCTAssertEqual(
            VimEx.parse(".,+3>")?.range,
            VimExRange(start: .current, end: VimExAddress(base: .current, offset: 3))
        )
        XCTAssertEqual(
            VimEx.parse("-2,.d")?.range,
            VimExRange(start: VimExAddress(base: .current, offset: -2), end: .current)
        )
        XCTAssertEqual(
            VimEx.parse("$-1d")?.range,
            VimExRange(
                start: VimExAddress(base: .last, offset: -1),
                end: VimExAddress(base: .last, offset: -1)
            )
        )
        // An offset with no number is one line.
        XCTAssertEqual(
            VimEx.parse(".+d")?.range?.start, VimExAddress(base: .current, offset: 1)
        )
    }

    func testABareRangeIsACommandOfItsOwn() {
        let command = VimEx.parse("15")
        XCTAssertEqual(command?.name, .goToLine)
        XCTAssertEqual(command?.range, VimExRange(start: .line(15), end: .line(15)))
        XCTAssertEqual(VimEx.parse("$")?.name, .goToLine)
        XCTAssertEqual(VimEx.parse("%")?.name, .goToLine)
    }

    func testTheShiftCommandsCountTheirOwnKeys() {
        XCTAssertEqual(VimEx.parse(">")?.name, .shiftRight)
        XCTAssertEqual(VimEx.parse(">")?.repetitions, 1)
        XCTAssertEqual(VimEx.parse(">>>")?.repetitions, 3)
        XCTAssertEqual(VimEx.parse("<<")?.name, .shiftLeft)
        XCTAssertEqual(VimEx.parse("2,4>>")?.range, VimExRange(start: .line(2), end: .line(4)))
    }

    func testAnAddressOnItsOwnParsesForMoveAndCopy() {
        XCTAssertEqual(VimEx.address("0"), .line(0))
        XCTAssertEqual(VimEx.address("$"), .last)
        XCTAssertEqual(VimEx.address(" 3 "), .line(3))
        XCTAssertEqual(VimEx.address("'a"), .mark("a"))
        XCTAssertEqual(VimEx.address(".+2"), VimExAddress(base: .current, offset: 2))
        XCTAssertNil(VimEx.address(""))
    }

    // MARK: - Parsing: :s

    func testSubstitutionParsing() {
        let plain = VimSubstitution.parse("/one/two/")
        XCTAssertEqual(plain?.pattern, "one")
        XCTAssertEqual(plain?.replacement, "two")
        XCTAssertEqual(plain?.global, false)
        XCTAssertEqual(plain?.ignoreCase, false)

        let flagged = VimSubstitution.parse("/one/two/gi")
        XCTAssertEqual(flagged?.global, true)
        XCTAssertEqual(flagged?.ignoreCase, true)

        // The last separator may be left off.
        XCTAssertEqual(VimSubstitution.parse("/one/two")?.replacement, "two")
        XCTAssertEqual(VimSubstitution.parse("/one")?.pattern, "one")
        XCTAssertEqual(VimSubstitution.parse("/one")?.replacement, "")

        // Any punctuation will do as the separator, and it can be escaped.
        XCTAssertEqual(VimSubstitution.parse("#a/b#c#")?.pattern, "a/b")
        XCTAssertEqual(VimSubstitution.parse("/a\\/b/c/")?.pattern, "a/b")
        // A backslash that is not the separator's keeps it, so `\d` survives.
        XCTAssertEqual(VimSubstitution.parse("/\\d+/n/")?.pattern, "\\d+")

        // An empty pattern is "the last one", which the engine fills in.
        XCTAssertEqual(VimSubstitution.parse("//new/")?.pattern, "")
        XCTAssertNil(VimSubstitution.parse(" foo"), "a blank is not a separator")
        XCTAssertNil(VimSubstitution.parse(""))
    }

    func testTheReplacementBecomesARegularExpressionTemplate() {
        XCTAssertEqual(VimEngine.template(from: "plain"), "plain")
        XCTAssertEqual(VimEngine.template(from: "&!"), "$0!")
        XCTAssertEqual(VimEngine.template(from: "\\&"), "&")
        XCTAssertEqual(VimEngine.template(from: "\\1-\\2"), "$1-$2")
        XCTAssertEqual(VimEngine.template(from: "$5"), "\\$5")
        XCTAssertEqual(VimEngine.template(from: "a\\rb"), "a\nb")
    }

    // MARK: - Ranges against a note

    func testABareRangeMovesTheCaret() throws {
        let harness = try makeHarness("alpha\nbeta\ngamma")
        harness.run("3")
        XCTAssertEqual(harness.caret, 11)
        harness.run("1")
        XCTAssertEqual(harness.caret, 0)
        harness.run("$")
        XCTAssertEqual(harness.caret, 11)
        // Past the end is the end, the way `G` clamps.
        harness.run("99")
        XCTAssertEqual(harness.caret, 11)
    }

    func testRelativeAndMarkAddressesResolve() throws {
        let harness = try makeHarness("one\ntwo\nthree\nfour")
        harness.type("jj")
        harness.run(".-1")
        XCTAssertEqual(harness.caret, 4, "one line up from the third")

        harness.type("ma")
        harness.run("1")
        harness.run("'a")
        XCTAssertEqual(harness.caret, 4)

        harness.run("'z")
        XCTAssertEqual(harness.host.messages.last, "Mark not set")
    }

    // MARK: - :s

    func testSubstituteOnTheCurrentLine() throws {
        let harness = try makeHarness("aa bb aa\ncc aa")
        harness.run("s/aa/xx/")
        XCTAssertEqual(harness.string, "xx bb aa\ncc aa", "the first match only")
        XCTAssertEqual(harness.host.messages.last, "1 substitution on 1 line")
    }

    func testSubstituteWithTheGlobalFlag() throws {
        let harness = try makeHarness("aa bb aa\ncc aa")
        harness.run("s/aa/xx/g")
        XCTAssertEqual(harness.string, "xx bb xx\ncc aa")
        XCTAssertEqual(harness.host.messages.last, "2 substitutions on 1 line")
    }

    func testSubstituteOverTheWholeNote() throws {
        let harness = try makeHarness("alpha\nbeta\ngamma")
        harness.run("%s/a/b/g")
        XCTAssertEqual(harness.string, "blphb\nbetb\ngbmmb")
        XCTAssertEqual(harness.host.messages.last, "5 substitutions on 3 lines")
    }

    func testSubstituteOverARange() throws {
        let harness = try makeHarness("a\na\na\na")
        harness.run("2,3s/a/b/")
        XCTAssertEqual(harness.string, "a\nb\nb\na")
    }

    func testSubstituteIgnoringCase() throws {
        let harness = try makeHarness("Alpha alpha")
        harness.run("s/alpha/x/gi")
        XCTAssertEqual(harness.string, "x x")
    }

    func testSubstituteReportsWhenThePatternIsNotFound() throws {
        let harness = try makeHarness("alpha")
        harness.run("s/zebra/x/")
        XCTAssertEqual(harness.string, "alpha")
        XCTAssertEqual(harness.host.messages.last, "E486: Pattern not found: zebra")
    }

    func testSubstituteKeepsTheMatchAndItsGroups() throws {
        let harness = try makeHarness("one two")
        harness.run("s/one/[&]/")
        XCTAssertEqual(harness.string, "[one] two")

        let groups = try makeHarness("2026-09-01")
        groups.run("s/(\\d+)-(\\d+)-(\\d+)/\\3\\/\\2/")
        XCTAssertEqual(groups.string, "01/09")
    }

    func testSubstituteLeavesTheCaretOnTheLastChangedLine() throws {
        let harness = try makeHarness("aa\nbb\naa")
        harness.run("%s/aa/cc/")
        XCTAssertEqual(VimMotions.lineNumber(harness.view.string as NSString, at: harness.caret), 3)
    }

    func testABareSubstituteRunsTheLastOneAgain() throws {
        let harness = try makeHarness("aa\naa")
        harness.run("s/aa/bb/")
        harness.run("2")
        harness.run("s")
        XCTAssertEqual(harness.string, "bb\nbb")
    }

    func testAnEmptyPatternUsesTheLastSearch() throws {
        let harness = try makeHarness("alpha beta\nalpha")
        harness.type("/beta<CR>")
        harness.run("%s//x/g")
        XCTAssertEqual(harness.string, "alpha x\nalpha")
    }

    func testSubstituteWithNothingToRepeatSaysSo() throws {
        let harness = try makeHarness("alpha")
        harness.run("s")
        XCTAssertEqual(
            harness.host.messages.last, "E33: No previous substitute regular expression"
        )
    }

    func testAnEntireSubstituteIsOneUndo() throws {
        let harness = try makeHarness("aa\naa\naa")
        harness.run("%s/aa/bb/g")
        XCTAssertEqual(harness.string, "bb\nbb\nbb")
        harness.type("u")
        XCTAssertEqual(harness.string, "aa\naa\naa")
    }

    // MARK: - :d and :y

    func testDeleteTakesWholeLines() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.run("2d")
        XCTAssertEqual(harness.string, "one\nthree")

        let range = try makeHarness("a\nb\nc\nd")
        range.run("2,3d")
        XCTAssertEqual(range.string, "a\nd")
    }

    func testDeleteIntoARegisterAndWithACount() throws {
        let harness = try makeHarness("one\ntwo\nthree\nfour")
        harness.run("2d a")
        XCTAssertEqual(harness.string, "one\nthree\nfour")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "two\n")

        let counted = try makeHarness("a\nb\nc\nd")
        counted.run("2d 2")
        XCTAssertEqual(counted.string, "a\nd", "the count is lines from the range's end")
    }

    func testYankLeavesTheCaretWhereItWas() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.type("jl")
        let before = harness.caret
        harness.run("3y a")
        XCTAssertEqual(harness.caret, before)
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "three")
        XCTAssertEqual(harness.string, "one\ntwo\nthree")
    }

    // MARK: - :j

    func testJoinOverARange() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.run("j")
        XCTAssertEqual(harness.string, "one two\nthree", "a single line joins the next")

        let range = try makeHarness("one\ntwo\nthree")
        range.run("1,3j")
        XCTAssertEqual(range.string, "one two three")
    }

    // MARK: - :m and :t

    func testMoveLines() throws {
        let harness = try makeHarness("one\ntwo\nthree")
        harness.run("1m$")
        XCTAssertEqual(harness.string, "two\nthree\none")

        let up = try makeHarness("a\nb\nc\nd")
        up.run("3,4m0")
        XCTAssertEqual(up.string, "c\nd\na\nb")

        let middle = try makeHarness("a\nb\nc\nd")
        middle.run("1m2")
        XCTAssertEqual(middle.string, "b\na\nc\nd")
    }

    func testMovingLinesIntoThemselvesIsRefused() throws {
        let harness = try makeHarness("a\nb\nc\nd")
        harness.run("2,4m3")
        XCTAssertEqual(harness.string, "a\nb\nc\nd")
        XCTAssertEqual(
            harness.host.messages.last, "E134: Cannot move a range of lines into itself"
        )
    }

    func testCopyLines() throws {
        let harness = try makeHarness("one\ntwo")
        harness.run("1t$")
        XCTAssertEqual(harness.string, "one\ntwo\none")

        let top = try makeHarness("one\ntwo")
        top.run("2t0")
        XCTAssertEqual(top.string, "two\none\ntwo")

        let abbreviated = try makeHarness("one\ntwo")
        abbreviated.run("1copy 2")
        XCTAssertEqual(abbreviated.string, "one\ntwo\none")
    }

    func testMoveWithoutAnAddressSaysSo() throws {
        let harness = try makeHarness("one\ntwo")
        harness.run("1m")
        XCTAssertEqual(harness.string, "one\ntwo")
        XCTAssertEqual(harness.host.messages.last, "E14: Invalid address")
    }

    // MARK: - :sort

    func testSortTakesTheWholeNoteWithoutARange() throws {
        let harness = try makeHarness("beta\nalpha\ngamma")
        harness.run("sort")
        XCTAssertEqual(harness.string, "alpha\nbeta\ngamma")
    }

    func testSortFlags() throws {
        let reversed = try makeHarness("a\nc\nb")
        reversed.run("sort!")
        XCTAssertEqual(reversed.string, "c\nb\na")

        let cased = try makeHarness("b\nA\na\nB")
        cased.run("sort i")
        XCTAssertEqual(cased.string, "A\na\nb\nB", "equal lines keep their order")

        let unique = try makeHarness("b\na\nb\na")
        unique.run("sort u")
        XCTAssertEqual(unique.string, "a\nb")

        let numeric = try makeHarness("item 10\nitem 9\nitem 100")
        numeric.run("sort n")
        XCTAssertEqual(numeric.string, "item 9\nitem 10\nitem 100")
    }

    func testSortOverARangeLeavesTheRestAlone() throws {
        let harness = try makeHarness("header\nc\na\nb\nfooter")
        harness.run("2,4sort")
        XCTAssertEqual(harness.string, "header\na\nb\nc\nfooter")
    }

    func testSortNumbersLinesWithoutANumberFirst() {
        XCTAssertEqual(VimSort.number(in: "item 42"), 42)
        XCTAssertEqual(VimSort.number(in: "-7 below"), -7)
        XCTAssertNil(VimSort.number(in: "none"))
        XCTAssertEqual(
            VimSort.sort(["b 2", "a", "c 1"], ignoringCase: false, numeric: true, unique: false),
            ["a", "c 1", "b 2"]
        )
    }

    // MARK: - :> and :<

    func testShiftCommands() throws {
        let harness = try makeHarness("a\nb\nc")
        harness.run(">")
        XCTAssertEqual(harness.string, "    a\nb\nc")
        harness.run("<")
        XCTAssertEqual(harness.string, "a\nb\nc")

        harness.run(">>")
        XCTAssertEqual(harness.string, "        a\nb\nc", "a doubled key shifts twice")

        let range = try makeHarness("a\nb\nc")
        range.run("2,3>")
        XCTAssertEqual(range.string, "a\n    b\n    c")

        // A doubled key over a range shifts every line of it twice.
        let doubled = try makeHarness("a\nb\nc")
        doubled.run("1,3>>")
        XCTAssertEqual(doubled.string, "        a\n        b\n        c")

        // `:> 2` counts lines from the range's end, the way `:d 2` does.
        let counted = try makeHarness("a\nb\nc")
        counted.run("2> 2")
        XCTAssertEqual(counted.string, "a\n    b\n    c")
    }

    // MARK: - The window's commands

    func testWriteAndQuit() throws {
        let harness = try makeHarness("alpha")
        harness.run("w")
        XCTAssertEqual(harness.host.saved, [nil])
        harness.run("w notes.md")
        XCTAssertEqual(harness.host.saved.last, "notes.md")

        harness.run("q")
        XCTAssertEqual(harness.host.closed, [false])
        harness.run("q!")
        XCTAssertEqual(harness.host.closed, [false, true])
    }

    func testWriteQuitOnlyClosesOnceTheWriteWorked() throws {
        let harness = try makeHarness("alpha")
        harness.run("wq")
        XCTAssertEqual(harness.host.saved.count, 1)
        XCTAssertEqual(harness.host.closed, [false])

        harness.host.saveSucceeds = false
        harness.run("x")
        XCTAssertEqual(harness.host.closed.count, 1, "a failed write leaves the tab open")
    }

    func testTabCommands() throws {
        let harness = try makeHarness("alpha")
        harness.run("tabnew")
        XCTAssertEqual(harness.host.newTabs, 1)
        harness.run("tabn")
        harness.run("bn")
        harness.run("tabp")
        harness.run("bp")
        XCTAssertEqual(harness.host.tabOffsets, [1, 1, -1, -1])
        harness.run("tabn 2")
        XCTAssertEqual(harness.host.tabOffsets.last, 2)
    }

    func testEditOpensAPath() throws {
        let harness = try makeHarness("alpha")
        harness.run("e ~/notes.md")
        XCTAssertEqual(harness.host.opened, ["~/notes.md"])
        harness.run("e")
        XCTAssertEqual(harness.host.messages.last, "E32: No file name")
    }

    func testAnUnknownCommandSaysSo() throws {
        let harness = try makeHarness("alpha")
        harness.run("zebra")
        XCTAssertEqual(harness.host.messages.last, "Not an editor command: zebra")
        XCTAssertEqual(harness.string, "alpha")
    }

    func testSetCursorline() throws {
        let harness = try makeHarness("alpha")
        XCTAssertFalse(harness.engine.cursorLine)
        harness.run("set cursorline")
        XCTAssertTrue(harness.engine.cursorLine)
        XCTAssertTrue(harness.view.showsCursorLine, "the text view draws it")
        harness.run("set nocursorline")
        XCTAssertFalse(harness.engine.cursorLine)
        XCTAssertFalse(harness.view.showsCursorLine)
        harness.run("set cursorline!")
        XCTAssertTrue(harness.engine.cursorLine)

        harness.run("set zebra")
        XCTAssertEqual(harness.host.messages.last, "E518: Unknown option: zebra")
    }

    /// The Settings preference and vim's `cursorline` are two separate inputs
    /// to the same band, so neither can switch off what the other asked for.
    func testCursorlinePreferenceAndVimDoNotFightOverTheBand() throws {
        let harness = try makeHarness("alpha")

        // The preference on: vim turning its own half off leaves the band lit.
        harness.view.highlightsCurrentLine = true
        XCTAssertTrue(harness.view.showsCursorLine)
        harness.run("set nocursorline")
        XCTAssertFalse(harness.engine.cursorLine)
        XCTAssertTrue(harness.view.showsCursorLine, "the preference keeps the band on")
        harness.run("set cursorline")
        XCTAssertTrue(harness.view.showsCursorLine)

        // The preference off: vim's on/off still works exactly as before.
        harness.view.highlightsCurrentLine = false
        harness.run("set nocursorline")
        XCTAssertFalse(harness.view.showsCursorLine)
        harness.run("set cursorline")
        XCTAssertTrue(harness.view.showsCursorLine)
        harness.run("set nocursorline")
        XCTAssertFalse(harness.view.showsCursorLine)
    }

    // MARK: - The scratch tabs

    func testHelpRegistersAndMarksOpenScratchTabs() throws {
        let harness = try makeHarness("alpha\nbeta")
        harness.run("help")
        XCTAssertEqual(harness.host.scratchTabs.last?.title, "Help")
        XCTAssertEqual(harness.host.scratchTabs.last?.text, VimHelp.text)

        harness.type("\"ayy")
        harness.run("reg")
        XCTAssertEqual(harness.host.scratchTabs.last?.title, "Registers")
        XCTAssertTrue(harness.host.scratchTabs.last?.text.contains("\"a") == true)

        harness.type("jma")
        harness.run("marks")
        XCTAssertEqual(harness.host.scratchTabs.last?.title, "Marks")
        XCTAssertTrue(harness.host.scratchTabs.last?.text.contains("beta") == true)
    }

    func testTheHelpTextListsEverySectionAndCommand() {
        let text = VimHelp.text
        for section in VimHelp.sections {
            XCTAssertTrue(
                text.contains(section.name.uppercased()), "\(section.name) is missing"
            )
            for entry in section.entries {
                XCTAssertTrue(text.contains(entry.keys), "\(entry.keys) is missing")
                XCTAssertTrue(text.contains(entry.summary), "\(entry.summary) is missing")
            }
        }
        XCTAssertTrue(text.hasPrefix("Nota — vim mode"))
    }

    func testTheRegisterTableReadsLikeVims() {
        let registers = VimRegisters()
        registers.write(VimRegisters.Entry(text: "hello", isLinewise: false), to: "a")
        registers.write(VimRegisters.Entry(text: "one\ntwo\n", isLinewise: true), to: "b")
        let text = VimScratch.registers(
            registers, unnamed: VimRegisters.Entry(text: "board", isLinewise: false)
        )
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Type Name Content")
        XCTAssertEqual(lines[1], "  c  \"\"   board")
        XCTAssertEqual(lines[2], "  c  \"a   hello")
        XCTAssertEqual(lines[3], "  l  \"b   one^Jtwo^J")
        XCTAssertTrue(
            VimScratch.registers(VimRegisters(), unnamed: nil).contains("(no registers set)")
        )
    }

    func testTheMarkTableReadsLikeVims() {
        var marks = VimMarks()
        marks.set("a", to: 6)
        marks.set(".", to: 0)
        let text = VimScratch.marks(marks, in: "alpha\nbeta" as NSString)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "mark line  col text")
        XCTAssertEqual(lines[1], " a      2    0 beta")
        XCTAssertEqual(lines[2], " .      1    0 alpha")
        XCTAssertTrue(VimScratch.marks(VimMarks(), in: "" as NSString).contains("(no marks set)"))
    }

    // MARK: - Read-only tabs

    func testAScratchTabRefusesEveryChange() throws {
        let harness = try makeHarness("alpha\nbeta")
        harness.engine.isModifiable = false

        for keys in ["x", "dd", "p", "J", "~", "rz", ">>"] {
            harness.type(keys)
            XCTAssertEqual(harness.string, "alpha\nbeta", "\(keys) changed the text")
        }
        XCTAssertEqual(harness.host.messages.last, VimEngine.notModifiableMessage)

        harness.type("i")
        XCTAssertEqual(harness.engine.mode, .normal, "insert mode never opens")
        XCTAssertEqual(harness.host.messages.last, VimEngine.notModifiableMessage)

        harness.type("A")
        XCTAssertEqual(harness.engine.mode, .normal)
        harness.type("o")
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertEqual(harness.string, "alpha\nbeta")
    }

    func testAScratchTabStillMovesAndYanks() throws {
        let harness = try makeHarness("alpha\nbeta")
        harness.engine.isModifiable = false

        harness.type("jl")
        XCTAssertEqual(harness.caret, 7, "the motions are untouched")
        harness.type("\"ayy")
        XCTAssertEqual(harness.engine.registers.read("a")?.text, "beta")
        XCTAssertEqual(harness.string, "alpha\nbeta")
    }

    func testAScratchTabRefusesAnExCommandToo() throws {
        let harness = try makeHarness("beta\nalpha")
        harness.engine.isModifiable = false
        harness.run("%s/a/x/g")
        XCTAssertEqual(harness.string, "beta\nalpha")
        XCTAssertEqual(harness.host.messages.last, VimEngine.notModifiableMessage)
    }

    // MARK: - Searching: the pieces

    func testACaseFlagComesOutOfThePattern() {
        XCTAssertEqual(VimSearch.caseFlag(in: "foo").pattern, "foo")
        XCTAssertNil(VimSearch.caseFlag(in: "foo").ignoreCase)

        let insensitive = VimSearch.caseFlag(in: "\\cFoo")
        XCTAssertEqual(insensitive.pattern, "Foo")
        XCTAssertEqual(insensitive.ignoreCase, true)

        let sensitive = VimSearch.caseFlag(in: "foo\\C")
        XCTAssertEqual(sensitive.pattern, "foo")
        XCTAssertEqual(sensitive.ignoreCase, false)

        // Every other escape is the regex's own and stays whole.
        XCTAssertEqual(VimSearch.caseFlag(in: "\\d+\\.\\d").pattern, "\\d+\\.\\d")
    }

    func testSmartcaseOnlyMattersWithIgnorecase() {
        XCTAssertFalse(
            VimSearch.isCaseInsensitive(pattern: "foo", ignoreCase: false, smartCase: false)
        )
        XCTAssertTrue(
            VimSearch.isCaseInsensitive(pattern: "Foo", ignoreCase: true, smartCase: false)
        )
        XCTAssertTrue(
            VimSearch.isCaseInsensitive(pattern: "foo", ignoreCase: true, smartCase: true)
        )
        XCTAssertFalse(
            VimSearch.isCaseInsensitive(pattern: "Foo", ignoreCase: true, smartCase: true),
            "an uppercase letter means you meant it"
        )
    }

    func testTheStarPatternTakesWholeWordsOnly() {
        XCTAssertEqual(VimSearch.wordPattern("foo"), "\\bfoo\\b")
        // A word with regex punctuation in it is escaped, not interpreted.
        XCTAssertEqual(VimSearch.wordPattern("a.b"), "\\ba\\.b\\b")

        let text = "foo food foo" as NSString
        let matches = VimSearch.matches(
            of: VimSearch.wordPattern("foo"), in: text, ignoringCase: false
        )
        XCTAssertEqual(matches.map(\.location), [0, 9], "`food` is not `foo`")
    }

    func testSteppingThroughMatchesWrapsRoundTheEnds() {
        let matches = [
            NSRange(location: 0, length: 1),
            NSRange(location: 4, length: 1),
            NSRange(location: 8, length: 1),
        ]
        XCTAssertEqual(
            VimSearch.step(matches, from: 0, forward: true, count: 1),
            VimSearchMatch(range: matches[1], wrapped: false)
        )
        XCTAssertEqual(
            VimSearch.step(matches, from: 0, forward: true, count: 2),
            VimSearchMatch(range: matches[2], wrapped: false)
        )
        XCTAssertEqual(
            VimSearch.step(matches, from: 8, forward: true, count: 1),
            VimSearchMatch(range: matches[0], wrapped: true),
            "past the last one is round to the first"
        )
        XCTAssertEqual(
            VimSearch.step(matches, from: 4, forward: false, count: 1),
            VimSearchMatch(range: matches[0], wrapped: false)
        )
        XCTAssertEqual(
            VimSearch.step(matches, from: 0, forward: false, count: 1),
            VimSearchMatch(range: matches[2], wrapped: true)
        )
        XCTAssertNil(VimSearch.step([], from: 0, forward: true, count: 1))
    }

    // MARK: - Searching: the prompt

    func testSlashOpensASearchPromptInThePane() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("/")
        XCTAssertEqual(harness.engine.mode, .commandLine)
        XCTAssertTrue(harness.engine.isSearchPrompt)
        XCTAssertEqual(harness.host.commandLines.last, "/")

        harness.type("?")
        XCTAssertEqual(harness.engine.commandLine, "?", "only the first one is the prompt")
    }

    func testTheCaretFollowsTheSearchAsItIsTyped() throws {
        let harness = try makeHarness("alpha beta alpha")
        harness.type("/bet")
        XCTAssertEqual(harness.caret, 6, "incremental: the caret is already there")
        XCTAssertEqual(harness.string, "alpha beta alpha", "and nothing is typed into the note")

        // A pattern that matches nothing leaves the caret where it started.
        harness.type("z")
        XCTAssertEqual(harness.caret, 0)
    }

    func testEscapeFromASearchPutsTheCaretBack() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("l")
        harness.type("/beta")
        XCTAssertEqual(harness.caret, 6)
        harness.type("<Esc>")
        XCTAssertEqual(harness.caret, 1, "back to where the search started")
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertTrue(harness.view.highlightedRanges.isEmpty)
    }

    func testEnterCommitsTheSearch() throws {
        let harness = try makeHarness("alpha beta alpha")
        harness.type("/beta<CR>")
        XCTAssertEqual(harness.caret, 6)
        XCTAssertEqual(harness.engine.lastSearchPattern, "beta")
        XCTAssertTrue(harness.engine.searchIsForward)
        XCTAssertEqual(harness.engine.history(for: "/"), ["beta"])
        XCTAssertNil(harness.engine.prompt)
    }

    func testQuestionMarkSearchesBackward() throws {
        let harness = try makeHarness("one two one")
        harness.type("$")
        harness.type("?one<CR>")
        XCTAssertEqual(harness.caret, 8, "the match behind the caret")
        XCTAssertFalse(harness.engine.searchIsForward)
        harness.type("n")
        XCTAssertEqual(harness.caret, 0, "and `n` keeps going back")
    }

    func testAnEmptySearchRepeatsTheLastPattern() throws {
        let harness = try makeHarness("a foo b foo")
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.caret, 2)
        harness.type("/<CR>")
        XCTAssertEqual(harness.caret, 8, "an empty pattern is the last one again")

        let fresh = try makeHarness("alpha")
        fresh.type("/<CR>")
        XCTAssertEqual(fresh.host.messages.last, "E35: No previous regular expression")
    }

    func testASearchThatFindsNothingSaysSoAndStaysPut() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("l")
        harness.type("/zebra<CR>")
        XCTAssertEqual(harness.caret, 1)
        XCTAssertEqual(harness.host.messages.last, "E486: Pattern not found: zebra")
        XCTAssertTrue(harness.view.highlightedRanges.isEmpty)
    }

    func testASearchWrapsWithAWordAboutIt() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("/beta<CR>")
        harness.type("/alpha<CR>")
        XCTAssertEqual(harness.caret, 0)
        XCTAssertEqual(harness.host.messages.last, VimEngine.hitBottomMessage)

        let backward = try makeHarness("alpha beta")
        backward.type("?beta<CR>")
        XCTAssertEqual(backward.caret, 6)
        XCTAssertEqual(backward.host.messages.last, VimEngine.hitTopMessage)
    }

    func testACountOnASearchTakesThatManyMatches() throws {
        let harness = try makeHarness("a a a a")
        harness.type("3/a<CR>")
        XCTAssertEqual(harness.caret, 6)
    }

    func testASearchIsAJumpSoTheBacktickComesBack() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("/beta<CR>")
        XCTAssertEqual(harness.caret, 6)
        harness.type("``")
        XCTAssertEqual(harness.caret, 0, "back to where the search set off from")
    }

    // MARK: - Searching: n, N, * and #

    func testNextAndPreviousRepeatTheSearch() throws {
        let harness = try makeHarness("a foo b foo c foo")
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.caret, 2)
        harness.type("n")
        XCTAssertEqual(harness.caret, 8)
        harness.type("n")
        XCTAssertEqual(harness.caret, 14)
        harness.type("N")
        XCTAssertEqual(harness.caret, 8, "`N` goes back")
        harness.type("2n")
        XCTAssertEqual(harness.caret, 2, "a count, and round the end")
    }

    func testNextFollowsTheDirectionTheSearchWasStartedIn() throws {
        let harness = try makeHarness("a foo b foo c foo")
        harness.type("$")
        harness.type("?foo<CR>")
        XCTAssertEqual(harness.caret, 14)
        harness.type("n")
        XCTAssertEqual(harness.caret, 8, "`n` after `?` keeps going backward")
        harness.type("N")
        XCTAssertEqual(harness.caret, 14, "and `N` turns round")
    }

    func testRepeatingWithNothingToRepeatSaysSo() throws {
        let harness = try makeHarness("alpha")
        harness.type("n")
        XCTAssertEqual(harness.host.messages.last, "E35: No previous regular expression")
    }

    func testStarAndHashSearchTheWordUnderTheCaret() throws {
        let harness = try makeHarness("foo food foo")
        harness.type("*")
        XCTAssertEqual(harness.caret, 9, "`food` is not the word `foo`")
        XCTAssertEqual(harness.engine.lastSearchPattern, "\\bfoo\\b")
        XCTAssertTrue(harness.engine.searchIsForward)

        harness.type("#")
        XCTAssertEqual(harness.caret, 0)
        XCTAssertFalse(harness.engine.searchIsForward)
    }

    func testStarFromABlankTakesTheNextWordOnTheLine() throws {
        let harness = try makeHarness("  alpha beta alpha")
        harness.type("*")
        XCTAssertEqual(harness.engine.lastSearchPattern, "\\balpha\\b")
        XCTAssertEqual(harness.caret, 13, "on from the word, not to it")

        let empty = try makeHarness("   \nalpha")
        empty.type("*")
        XCTAssertEqual(empty.host.messages.last, "E348: No string under cursor")
    }

    func testACountOnStarTakesThatManyMatches() throws {
        let harness = try makeHarness("x a x a x a x")
        harness.type("2*")
        XCTAssertEqual(harness.caret, 8)
    }

    // MARK: - Searching: as a motion

    func testAnOperatorTakesASearchAsAnExclusiveMotion() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("d/beta<CR>")
        XCTAssertEqual(harness.string, "beta", "up to the match, not through it")
        XCTAssertEqual(harness.caret, 0)
    }

    func testAnOperatorTakesABackwardSearchToo() throws {
        let harness = try makeHarness("bar alpha")
        harness.type("w")
        harness.type("y?bar<CR>")
        XCTAssertEqual(harness.string, "bar alpha", "a yank changes nothing")
        XCTAssertEqual(harness.caret, 0)
        XCTAssertEqual(harness.engine.registers.read("0")?.text, "bar ")
    }

    func testACancelledSearchAbandonsTheOperator() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("d/beta<Esc>")
        XCTAssertEqual(harness.string, "alpha beta")
        XCTAssertEqual(harness.caret, 0)
        XCTAssertEqual(harness.engine.mode, .normal)
    }

    func testNextRepeatsUnderAnOperator() throws {
        let harness = try makeHarness("a foo b foo c")
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.caret, 2)
        harness.type("dn")
        XCTAssertEqual(harness.string, "a foo c")
    }

    func testASearchInVisualModeExtendsTheSelection() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("v/beta<CR>")
        XCTAssertEqual(harness.engine.mode, .visual)
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 0, length: 7))
        harness.type("d")
        XCTAssertEqual(harness.string, "eta")
    }

    func testACancelledSearchInVisualModeKeepsTheSelection() throws {
        let harness = try makeHarness("alpha beta")
        harness.type("vll")
        harness.type("/beta<Esc>")
        XCTAssertEqual(harness.engine.mode, .visual)
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 0, length: 3))
    }

    // MARK: - Searching: highlights

    func testHlsearchLightsEveryMatchWithoutTouchingTheText() throws {
        let harness = try makeHarness("a foo b foo")
        harness.type("/foo<CR>")
        XCTAssertEqual(
            harness.view.highlightedRanges,
            [NSRange(location: 2, length: 3), NSRange(location: 8, length: 3)]
        )

        // Temporary attributes: the layout manager has them, the storage —
        // and so the cache, and so the file — never does.
        let storage = try XCTUnwrap(harness.view.textStorage)
        XCTAssertNil(storage.attribute(.backgroundColor, at: 2, effectiveRange: nil))
        let temporary = harness.view.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: 2, effectiveRange: nil
        )
        XCTAssertNotNil(temporary)
    }

    func testNoHighlightPutsTheHighlightsDownUntilTheNextSearch() throws {
        let harness = try makeHarness("a foo b foo")
        harness.type("/foo<CR>")
        XCTAssertFalse(harness.view.highlightedRanges.isEmpty)

        harness.run("noh")
        XCTAssertTrue(harness.view.highlightedRanges.isEmpty)
        XCTAssertEqual(harness.engine.lastSearchPattern, "foo", "the pattern is remembered")

        harness.type("n")
        XCTAssertFalse(harness.view.highlightedRanges.isEmpty, "`n` brings them back")
    }

    func testHlsearchOffMeansNoHighlightsAtAll() throws {
        let harness = try makeHarness("a foo b foo")
        harness.engine.hlsearch = false
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.caret, 2, "the search still works")
        XCTAssertTrue(harness.view.highlightedRanges.isEmpty)
    }

    func testTheHighlightsFollowAnEdit() throws {
        let harness = try makeHarness("foo foo")
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.view.highlightedRanges.count, 2)
        harness.engine.refreshSearchHighlights()
        XCTAssertEqual(harness.view.highlightedRanges.count, 2)

        // The caret is on the second match; breaking it puts its light out.
        harness.type("x")
        harness.engine.refreshSearchHighlights()
        XCTAssertEqual(
            harness.view.highlightedRanges, [NSRange(location: 0, length: 3)],
            "the match that was broken is not lit any more"
        )
    }

    // MARK: - Searching: case

    func testIgnorecaseAndSmartcase() throws {
        let harness = try makeHarness("bar Foo")
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.caret, 0, "case-sensitive by default, so nothing")
        XCTAssertEqual(harness.host.messages.last, "E486: Pattern not found: foo")

        harness.engine.ignoreCase = true
        harness.type("/foo<CR>")
        XCTAssertEqual(harness.caret, 4, "and now the capital matches")

        harness.engine.smartCase = true
        harness.type("gg")
        harness.type("/Bar<CR>")
        XCTAssertEqual(
            harness.host.messages.last, "E486: Pattern not found: Bar",
            "an uppercase letter in the pattern means you meant it"
        )
        harness.type("/bar<CR>")
        XCTAssertEqual(harness.caret, 0, "all lowercase is still insensitive")
    }

    func testABackslashCForcesIgnorecase() throws {
        let harness = try makeHarness("FOO bar")
        harness.type("/\\cfoo<CR>")
        XCTAssertEqual(harness.caret, 0)
        XCTAssertEqual(harness.host.messages.last, VimEngine.hitBottomMessage)
    }

    func testSubstituteHonoursABackslashCToo() throws {
        let harness = try makeHarness("FOO foo")
        harness.run("s/\\cfoo/x/g")
        XCTAssertEqual(harness.string, "x x")
    }

    func testTheSearchOptionsAreSettable() throws {
        let harness = try makeHarness("alpha")
        harness.type("/alpha<CR>")
        XCTAssertFalse(harness.view.highlightedRanges.isEmpty)
        harness.run("set nohlsearch")
        XCTAssertFalse(harness.engine.hlsearch)
        XCTAssertTrue(
            harness.view.highlightedRanges.isEmpty, "the highlights go out at once"
        )
        harness.run("set hlsearch")
        XCTAssertTrue(harness.engine.hlsearch)
        harness.run("set ic")
        XCTAssertTrue(harness.engine.ignoreCase)
        harness.run("set smartcase")
        XCTAssertTrue(harness.engine.smartCase)
        harness.run("set ignorecase!")
        XCTAssertFalse(harness.engine.ignoreCase)
        harness.run("set hlsearch?")
        XCTAssertEqual(harness.host.messages.last, "hlsearch")
    }

    // MARK: - Searching: what it does not touch

    func testASearchWorksInAReadOnlyTab() throws {
        let harness = try makeHarness("alpha beta")
        harness.engine.isModifiable = false
        harness.type("/beta<CR>")
        XCTAssertEqual(harness.caret, 6, "reading is not changing")
        XCTAssertEqual(harness.string, "alpha beta")
    }

    func testAMessageStaysUntilTheNextKey() throws {
        let harness = try makeHarness("alpha")
        harness.type(":zebra<CR>")
        XCTAssertEqual(harness.host.messages.last, "Not an editor command: zebra")
        XCTAssertEqual(harness.host.messagesCleared, 0)

        harness.type("l")
        XCTAssertEqual(harness.host.messagesCleared, 1, "the next key takes it away")
        harness.type("l")
        XCTAssertEqual(harness.host.messagesCleared, 1, "and only the first one does")
    }


    func testTheWordUnderTheCaretIsFoundFromAnywhereInIt() {
        let text = "alpha beta-gamma" as NSString
        XCTAssertEqual(VimSearch.wordUnderCaret(text, at: 0), "alpha")
        XCTAssertEqual(VimSearch.wordUnderCaret(text, at: 3), "alpha")
        XCTAssertEqual(VimSearch.wordUnderCaret(text, at: 5), "beta", "a blank looks forward")
        XCTAssertEqual(VimSearch.wordUnderCaret(text, at: 10), "gamma", "so does punctuation")
        XCTAssertNil(VimSearch.wordUnderCaret("" as NSString, at: 0))
    }




    // MARK: - Linewise put at the end of the note

    func testLinewisePutBelowTheLastLineLeavesNoTrailingNewline() throws {
        let harness = try makeHarness("one\ntwo")
        harness.type("yyjp")
        XCTAssertEqual(harness.string, "one\ntwo\none")
        XCTAssertEqual(harness.caret, 8)

        // And a note that already ended with one keeps it.
        let trailing = try makeHarness("one\n")
        trailing.type("yyp")
        XCTAssertEqual(trailing.string, "one\none\n")
    }

    func testLinewisePutFromANamedRegisterAlsoLeavesNoTrailingNewline() throws {
        let harness = try makeHarness("one\ntwo")
        harness.type("\"ayyj\"ap")
        XCTAssertEqual(harness.string, "one\ntwo\none")
    }

    func testLinewisePutAboveIsUnchanged() throws {
        let harness = try makeHarness("one\ntwo")
        harness.type("yyjP")
        XCTAssertEqual(harness.string, "one\none\ntwo")
    }

    // MARK: - Cursorline

    func testTheCursorlineFlagReachesTheTextView() throws {
        let harness = try makeHarness("alpha")
        XCTAssertFalse(harness.view.showsCursorLine)
        harness.engine.cursorLine = true
        XCTAssertTrue(harness.view.showsCursorLine)
        harness.engine.cursorLine = false
        XCTAssertFalse(harness.view.showsCursorLine)
    }

    func testTurningVimOffTakesTheBandAndTheCommandLineWithIt() throws {
        let harness = try makeHarness("alpha")
        harness.engine.cursorLine = true
        harness.type(":sort")

        harness.engine.isEnabled = false
        XCTAssertFalse(harness.view.showsCursorLine)
        XCTAssertNil(harness.engine.commandLine)
        XCTAssertNil(harness.host.commandLines.last ?? "still open")

        harness.engine.isEnabled = true
        XCTAssertTrue(harness.view.showsCursorLine, "and it comes back with vim")
    }
}
