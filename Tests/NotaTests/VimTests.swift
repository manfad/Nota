import AppKit
import XCTest
@testable import Nota

/// Drives a real `NotaTextView` through a real `VimEngine`, one key at a time,
/// the same way `keyDown` does — `type("3dd")` is three calls to
/// `VimEngine.handle(_:)` with the keys `VimKey.parse` produces, which is
/// exactly what the keyboard produces.
@MainActor
final class VimTests: AppKitTestCase {

    // MARK: - Harness

    /// Holds the undo manager: `NSTextView` asks its delegate for one, and a
    /// view with no window has nowhere else to get it.
    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var hosts: [UndoHost] = []
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        hosts = []
    }

    @MainActor
    private struct Harness {
        let view: NotaTextView
        let engine: VimEngine

        var string: String { view.string }
        var caret: Int { view.selectedRange().location }

        func type(_ keys: String) {
            for key in VimKey.parse(keys) { engine.handle(key) }
        }

        /// Insert-mode typing, which the engine deliberately leaves to
        /// `NSTextView` — the harness stands in for AppKit here.
        func insert(_ text: String) {
            view.insertText(text, replacementRange: view.selectedRange())
        }

        /// A key struck on the keyboard, through `NotaTextView.keyDown` — so
        /// what vim declines, AppKit still gets. The only way to test the
        /// keys that are deliberately not the engine's, like ⌘→.
        func press(keyCode: UInt16, flags: NSEvent.ModifierFlags = [], characters: String = "") {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            view.keyDown(with: event)
        }
    }

    /// The key codes the Mac's cursor keys arrive with.
    private enum Cursor {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121

        static let leftCharacter = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        static let rightCharacter = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        static let downCharacter = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        static let upCharacter = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    }

    private func makeHarness(_ text: String = "", enabled: Bool = true) throws -> Harness {
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
        // A private pasteboard: the tests must never touch a real clipboard.
        engine.pasteboard = NSPasteboard(name: NSPasteboard.Name("VimTests-\(UUID().uuidString)"))
        engine.isEnabled = enabled
        view.vimKeyHandler = { engine.handle($0) }
        return Harness(view: view, engine: engine)
    }

    private func makePNGData() -> Data {
        let size = NSSize(width: 6, height: 4)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return representation.representation(using: .png, properties: [:])!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    // MARK: - Keys

    func testKeyNotationParsesTheFormsAVimrcUses() {
        XCTAssertEqual(VimKey.parse("dw"), [.char("d"), .char("w")])
        XCTAssertEqual(VimKey.parse("<Esc>"), [.escape])
        XCTAssertEqual(VimKey.parse("<CR>"), [.enter])
        XCTAssertEqual(VimKey.parse("<Space>"), [.char(" ")])
        XCTAssertEqual(VimKey.parse("<C-r>"), [.char("r", control: true)])
        XCTAssertEqual(VimKey.parse("<A-x>"), [.char("x", option: true)])
        XCTAssertEqual(VimKey.parse("<M-x>"), [.char("x", option: true)])
        XCTAssertEqual(VimKey.parse("<S-a>"), [.char("A")])
        XCTAssertEqual(VimKey.parse("<lt>"), [.char("<")])
        XCTAssertEqual(VimKey.parse("<leader>w", leader: ","), [.char(","), .char("w")])
        // Case is not significant in a key name.
        XCTAssertEqual(VimKey.parse("<esc>"), VimKey.parse("<Esc>"))
        // Something that is not a key name is just text.
        XCTAssertEqual(VimKey.parse("<nope>").first, .char("<"))
        XCTAssertEqual(VimKey.parse("a<C-w>b"),
                       [.char("a"), .char("w", control: true), .char("b")])
    }

    func testCommandKeyEventsAreNeverVimsToTake() throws {
        func event(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            )
        }

        // ⌘S stays ⌘S in every mode — the menus keep working.
        let save = try XCTUnwrap(event("s", .command))
        XCTAssertNil(VimKey(event: save))
        let harness = try makeHarness("text")
        XCTAssertFalse(harness.engine.handle(save))
        harness.type("i")
        XCTAssertFalse(harness.engine.handle(save), "not even in insert mode")

        // A plain key is taken, and ⌃[ arrives as Escape.
        let plain = try XCTUnwrap(event("d", []))
        XCTAssertEqual(VimKey(event: plain), .char("d"))
        let controlBracket = try XCTUnwrap(event("[", .control))
        XCTAssertEqual(VimKey(event: controlBracket), .escape)
    }

    // MARK: - Motions

    func testMotionsMoveTheCaretWithCounts() throws {
        let harness = try makeHarness("alpha beta gamma\nsecond line here\nthird")

        harness.type("l")
        XCTAssertEqual(harness.caret, 1)
        harness.type("3l")
        XCTAssertEqual(harness.caret, 4)
        harness.type("2h")
        XCTAssertEqual(harness.caret, 2)

        harness.type("0")
        XCTAssertEqual(harness.caret, 0)
        harness.type("w")
        XCTAssertEqual(harness.caret, 6)        // beta
        harness.type("2w")
        XCTAssertEqual(harness.caret, 17)       // second, on the next line
        harness.type("b")
        XCTAssertEqual(harness.caret, 11)       // back to gamma
        harness.type("e")
        XCTAssertEqual(harness.caret, 15)       // last letter of gamma

        harness.type("$")
        XCTAssertEqual(harness.caret, 15)
        harness.type("j0")
        XCTAssertEqual(harness.caret, 17)
        harness.type("$")
        XCTAssertEqual(harness.caret, 32)

        harness.type("gg")
        XCTAssertEqual(harness.caret, 0)
        harness.type("G")
        XCTAssertEqual(harness.caret, 34)       // first non-blank of "third"
        harness.type("2gg")
        XCTAssertEqual(harness.caret, 17)

        // `f`, `t` and their repeats stay on the line.
        harness.type("0fl")
        XCTAssertEqual(harness.caret, 24)       // the l of "line"
        harness.type("0tl")
        XCTAssertEqual(harness.caret, 23)       // one short of it
        harness.type("0fz")                     // no z on this line: no move
        XCTAssertEqual(harness.caret, 17)
    }

    func testVerticalMotionKeepsItsColumnOverShortLines() throws {
        let harness = try makeHarness("longest line\nx\nanother long line")

        harness.type("$")
        XCTAssertEqual(harness.caret, 11)
        harness.type("j")
        XCTAssertEqual(harness.caret, 13)       // the short line's only column
        harness.type("j")
        // Back out to the column it set off from, not the short line's.
        XCTAssertEqual(VimMotions.column(harness.string as NSString, at: harness.caret), 11)
    }

    func testMotionsNeverSplitAnEmojiOrAnImage() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = "eeeeeeee-0000-0000-0000-000000000005.png"
        let harness = try makeHarness()
        harness.view.assets = assets
        harness.view.textStorage?.setAttributedString(
            NoteText.render(
                "a👋\(NoteText.token(for: id))b",
                attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
            )
        )
        harness.view.setSelectedRange(NSRange(location: 0, length: 0))

        // a, then the emoji as one glyph, then the image as one, then b.
        harness.type("l")
        XCTAssertEqual(harness.caret, 1)
        harness.type("l")
        XCTAssertEqual(harness.caret, 3)        // past both halves of the emoji
        harness.type("l")
        XCTAssertEqual(harness.caret, 4)        // past the image
        harness.type("h")
        XCTAssertEqual(harness.caret, 3)
        harness.type("h")
        XCTAssertEqual(harness.caret, 1)
    }

    // MARK: - The Mac's cursor keys

    func testKeyNotationNamesTheMacsOwnCursorKeys() {
        XCTAssertEqual(VimKey.parse("<Home>"), [VimKey(base: .home)])
        XCTAssertEqual(VimKey.parse("<End>"), [VimKey(base: .end)])
        XCTAssertEqual(VimKey.parse("<PageUp>"), [VimKey(base: .pageUp)])
        XCTAssertEqual(VimKey.parse("<PageDown>"), [VimKey(base: .pageDown)])
        XCTAssertEqual(VimKey.parse("<home>"), VimKey.parse("<Home>"))
        // A vimrc can put a modifier on one, the way it can on <Tab>.
        XCTAssertEqual(VimKey.parse("<A-Right>"), [VimKey(base: .right, option: true)])
    }

    func testTheCursorKeysArriveFromTheKeyboardAsThemselves() throws {
        func event(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ))
        }

        XCTAssertEqual(VimKey(event: try event(Cursor.home)), VimKey(base: .home))
        XCTAssertEqual(VimKey(event: try event(Cursor.end)), VimKey(base: .end))
        XCTAssertEqual(VimKey(event: try event(Cursor.pageUp)), VimKey(base: .pageUp))
        XCTAssertEqual(VimKey(event: try event(Cursor.pageDown)), VimKey(base: .pageDown))
        XCTAssertEqual(
            VimKey(event: try event(Cursor.right, .option)),
            VimKey(base: .right, option: true)
        )
        // ⌘ still belongs to the Mac, arrows included.
        XCTAssertNil(VimKey(event: try event(Cursor.right, .command)))
    }

    func testOptionArrowsMoveByWordAndParagraphInNormalMode() throws {
        let harness = try makeHarness("alpha beta gamma\nsecond line here\nthird")

        harness.type("<A-Right>")
        XCTAssertEqual(harness.caret, 6)        // beta, exactly as `w` lands
        harness.type("2<A-Right>")
        XCTAssertEqual(harness.caret, 17)       // second, on the next line
        harness.type("<A-Left>")
        XCTAssertEqual(harness.caret, 11)       // back to gamma, as `b` does
        harness.type("2<A-Left>")
        XCTAssertEqual(harness.caret, 0)

        // A plain arrow is still h/j/k/l.
        harness.type("<Right>")
        XCTAssertEqual(harness.caret, 1)
        harness.type("<Down>")
        XCTAssertEqual(harness.caret, 18)
        harness.type("<Up><Left>")
        XCTAssertEqual(harness.caret, 0)
    }

    func testOptionUpAndDownMoveByParagraph() throws {
        let harness = try makeHarness("one\n\ntwo\n\nthree")

        harness.type("<A-Down>")
        XCTAssertEqual(harness.caret, 4)        // the blank line, as `}` lands
        harness.type("<A-Down>")
        XCTAssertEqual(harness.caret, 9)
        harness.type("2<A-Up>")
        XCTAssertEqual(harness.caret, 0)
    }

    func testAnOperatorTakesAnOptionArrowAsItsMotion() throws {
        let harness = try makeHarness("alpha beta gamma")

        harness.type("d<A-Right>")
        XCTAssertEqual(harness.string, "beta gamma")
        harness.type("$d<A-Left>")
        XCTAssertEqual(harness.string, "beta a")
    }

    func testHomeAndEndGoToTheEndsOfTheLine() throws {
        let harness = try makeHarness("    alpha beta\nsecond")

        harness.type("<End>")
        XCTAssertEqual(harness.caret, 13)       // on the last character, as `$`
        harness.type("<Home>")
        XCTAssertEqual(harness.caret, 0)        // the line's start, as `0` — not `^`

        harness.type("j<End>")
        XCTAssertEqual(harness.caret, 20)
        harness.type("<Home>")
        XCTAssertEqual(harness.caret, 15)

        // And an operator takes them: `d<End>` is `d$`.
        harness.type("<Home>d<End>")
        XCTAssertEqual(harness.string, "    alpha beta\n")
    }

    func testThePageKeysMoveTheWayControlFAndControlBDo() throws {
        let lines = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let paged = try makeHarness(lines)
        let control = try makeHarness(lines)

        paged.type("<PageDown>")
        control.type("<C-f>")
        XCTAssertEqual(paged.caret, control.caret)
        XCTAssertGreaterThan(paged.caret, 0)

        paged.type("<PageUp>")
        control.type("<C-b>")
        XCTAssertEqual(paged.caret, control.caret)
        XCTAssertEqual(paged.caret, 0)
    }

    func testTheMacsCursorKeysExtendAVisualSelection() throws {
        let harness = try makeHarness("alpha beta gamma\nsecond line here")

        harness.type("v<A-Right>")
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 0, length: 7))
        harness.type("<End>")
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 0, length: 16))
        harness.type("<Home>")
        XCTAssertEqual(harness.view.selectedRange(), NSRange(location: 0, length: 1))
        harness.type("<Esc>")

        // Linewise visual takes them too: ⌥↓ is `}`.
        let lined = try makeHarness("one\ntwo\n\nthree")
        lined.type("V<A-Down>")
        XCTAssertEqual(lined.view.selectedRange(), NSRange(location: 0, length: 9))
        lined.type("d")
        XCTAssertEqual(lined.string, "three")
    }

    /// ⌘-arrows are never the engine's: it declines them and `NSTextView`
    /// does what it does everywhere else on the Mac. What vim has to add is
    /// only the clamp — normal mode never sits past the last character — and
    /// the column the next `j` aims for.
    func testCommandArrowsStayTheMacsAndLeaveTheCaretWhereVimCanUseIt() throws {
        let harness = try makeHarness("alpha beta\nsecond line here\nthird one")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(harness.view)
        window.makeFirstResponder(harness.view)
        window.makeKeyAndOrderFrontOffscreen()
        defer { window.orderOut(nil) }

        harness.type("j")                       // the middle line, at 11
        harness.press(keyCode: Cursor.right, flags: .command, characters: Cursor.rightCharacter)
        XCTAssertEqual(harness.caret, 26, "⌘→ sits on the line's last character")

        harness.press(keyCode: Cursor.left, flags: .command, characters: Cursor.leftCharacter)
        XCTAssertEqual(harness.caret, 11, "⌘← the line's start")

        // The column the caret was left in is the one `j` and `k` aim for.
        harness.press(keyCode: Cursor.right, flags: .command, characters: Cursor.rightCharacter)
        harness.type("k")
        XCTAssertEqual(harness.caret, 9, "the short line's last column, not its first")
        harness.type("j")
        XCTAssertEqual(harness.caret, 26)

        harness.press(keyCode: Cursor.down, flags: .command, characters: Cursor.downCharacter)
        XCTAssertEqual(harness.caret, 36, "⌘↓ the end of the note")
        harness.press(keyCode: Cursor.up, flags: .command, characters: Cursor.upCharacter)
        XCTAssertEqual(harness.caret, 0, "⌘↑ the start of it")
    }

    // MARK: - Editing

    func testDeleteWithMotionsAndCounts() throws {
        let harness = try makeHarness("alpha beta gamma")

        harness.type("dw")
        XCTAssertEqual(harness.string, "beta gamma")
        harness.type("d$")
        XCTAssertEqual(harness.string, "")

        let second = try makeHarness("one two three four")
        second.type("d2w")
        XCTAssertEqual(second.string, "three four")

        let third = try makeHarness("hello")
        third.type("x")
        XCTAssertEqual(third.string, "ello")
        third.type("3x")
        XCTAssertEqual(third.string, "o")
        // `x` never runs past the end of the line.
        third.type("5x")
        XCTAssertEqual(third.string, "")
    }

    func testLinewiseDeleteAndYankAndPut() throws {
        let harness = try makeHarness("one\ntwo\nthree\nfour")

        harness.type("dd")
        XCTAssertEqual(harness.string, "two\nthree\nfour")
        XCTAssertEqual(harness.caret, 0)

        harness.type("2dd")
        XCTAssertEqual(harness.string, "four")

        // `dd` on the last line takes the newline before it with it.
        let single = try makeHarness("one\ntwo")
        single.type("jdd")
        XCTAssertEqual(single.string, "one")

        // yy then p puts the line below, and the caret lands on it.
        let copier = try makeHarness("first\nsecond")
        copier.type("yyp")
        XCTAssertEqual(copier.string, "first\nfirst\nsecond")
        XCTAssertEqual(copier.caret, 6)

        // P puts it above instead.
        let above = try makeHarness("first\nsecond")
        above.type("jyyP")
        XCTAssertEqual(above.string, "first\nsecond\nsecond")

        // Charwise: `x` then `p` drops the character after the caret.
        let charwise = try makeHarness("abc")
        charwise.type("xp")
        XCTAssertEqual(charwise.string, "bac")
    }

    func testChangeEntersInsertModeAndTypingCarriesOn() throws {
        let harness = try makeHarness("alpha beta")

        harness.type("cw")
        XCTAssertEqual(harness.string, "beta")
        XCTAssertEqual(harness.engine.mode, .insert)
        harness.insert("omega ")
        XCTAssertEqual(harness.string, "omega beta")

        harness.type("<Esc>")
        XCTAssertEqual(harness.engine.mode, .normal)
        // Escape steps back off the character just typed.
        XCTAssertEqual(harness.caret, 5)
    }

    func testInsertEntryPoints() throws {
        let harness = try makeHarness("hello world")

        harness.type("A")
        XCTAssertEqual(harness.caret, 11)
        harness.type("<Esc>")

        harness.type("0i")
        XCTAssertEqual(harness.caret, 0)
        XCTAssertEqual(harness.engine.mode, .insert)
        harness.type("<Esc>")

        harness.type("a")
        XCTAssertEqual(harness.caret, 1)
        harness.type("<Esc>")

        // `o` opens a line below and lands on it in insert mode.
        harness.type("o")
        XCTAssertEqual(harness.string, "hello world\n")
        XCTAssertEqual(harness.engine.mode, .insert)
        harness.insert("second")
        XCTAssertEqual(harness.string, "hello world\nsecond")

        // `O` opens above.
        harness.type("<Esc>O")
        harness.insert("between")
        XCTAssertEqual(harness.string, "hello world\nbetween\nsecond")
    }

    func testUndoTakesAWholeCommandAndRedoPutsItBack() throws {
        let harness = try makeHarness("one\ntwo\nthree")

        harness.type("3dd")
        XCTAssertEqual(harness.string, "")
        harness.type("u")
        XCTAssertEqual(harness.string, "one\ntwo\nthree", "one command is one undo")
        harness.type("<C-r>")
        XCTAssertEqual(harness.string, "")
    }

    func testReplaceCharacterAndReplaceMode() throws {
        let harness = try makeHarness("hello")

        harness.type("rj")
        XCTAssertEqual(harness.string, "jello")
        XCTAssertEqual(harness.caret, 0)

        harness.type("3rx")
        XCTAssertEqual(harness.string, "xxxlo")

        // `R` overwrites as you type, and Escape leaves it.
        let overwrite = try makeHarness("abcdef")
        overwrite.type("R")
        XCTAssertEqual(overwrite.engine.mode, .replace)
        overwrite.type("xy")
        XCTAssertEqual(overwrite.string, "xycdef")
        overwrite.type("<Esc>")
        XCTAssertEqual(overwrite.engine.mode, .normal)
    }

    func testIncrementAndDecrementTheNumberOnTheLine() throws {
        let harness = try makeHarness("item 41 here")

        harness.type("<C-a>")
        XCTAssertEqual(harness.string, "item 42 here")
        harness.type("3<C-x>")
        XCTAssertEqual(harness.string, "item 39 here")

        // Nothing to count: the line is left alone.
        let letters = try makeHarness("no numbers")
        letters.type("<C-a>")
        XCTAssertEqual(letters.string, "no numbers")
    }

    func testInsertModeControlKeys() throws {
        let harness = try makeHarness("alpha beta")

        harness.type("A")
        harness.type("<C-w>")
        XCTAssertEqual(harness.string, "alpha ")
        harness.type("<C-u>")
        XCTAssertEqual(harness.string, "")

        let indented = try makeHarness("line")
        indented.type("A<C-t>")
        XCTAssertEqual(indented.string, "    line")
        indented.type("<C-t>")
        XCTAssertEqual(indented.string, "        line")
        indented.type("<C-d>")
        XCTAssertEqual(indented.string, "    line")
    }

    func testYankAndPutCarryAnInlineImage() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        // A real asset, so the copy really has bytes to carry.
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let harness = try makeHarness()
        harness.view.assets = assets
        harness.view.textStorage?.setAttributedString(
            NoteText.render(
                "before \(NoteText.token(for: id))\nafter",
                attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
            )
        )
        harness.view.setSelectedRange(NSRange(location: 0, length: 0))

        // Yanking the line with the picture and putting it back gives two
        // chips, both pointing at the one asset — no second copy imported.
        harness.type("yyp")
        let storage = try XCTUnwrap(harness.view.textStorage)
        var attachments: [String] = []
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let chip = value as? NotaImageAttachment { attachments.append(chip.assetID) }
        }
        XCTAssertEqual(attachments, [id, id])
        XCTAssertEqual(
            NoteText.serialize(storage),
            "before \(NoteText.token(for: id))\nbefore \(NoteText.token(for: id))\nafter"
        )
    }

    // MARK: - Modes and the badge

    func testModeChangesAreAnnouncedAndDriveTheCaretShape() throws {
        let harness = try makeHarness("text")
        var announced: [VimMode] = []
        harness.engine.onModeChange = { announced.append($0) }

        XCTAssertEqual(harness.engine.cursorStyle, .block)
        harness.type("i")
        XCTAssertEqual(harness.engine.mode, .insert)
        XCTAssertEqual(harness.engine.cursorStyle, .bar)
        XCTAssertEqual(harness.view.vimCursorStyle, .bar)

        harness.type("<Esc>")
        XCTAssertEqual(harness.engine.cursorStyle, .block)
        XCTAssertEqual(harness.view.vimCursorStyle, .block)

        harness.type("R")
        XCTAssertEqual(harness.engine.cursorStyle, .halfBlock)
        harness.type("<Esc>")

        XCTAssertEqual(announced, [.insert, .normal, .replace, .normal])
    }

    func testPendingKeysAreShownWhileACommandIsHalfTyped() throws {
        let harness = try makeHarness("one two three")
        var pending: [String] = []
        harness.engine.onPendingKeysChange = { pending.append($0) }

        harness.type("2")
        XCTAssertEqual(pending.last, "2")
        harness.type("d")
        XCTAssertEqual(pending.last, "2d")
        harness.type("w")
        XCTAssertEqual(pending.last, "", "a finished command shows nothing")
        XCTAssertEqual(harness.string, "three")

        harness.type("f")
        XCTAssertEqual(pending.last, "f")
        harness.type("r")
        XCTAssertEqual(pending.last, "")
    }

    func testEscapeAlternativesLeaveInsertMode() throws {
        for keys in ["<Esc>", "<C-[>", "<C-c>"] {
            let harness = try makeHarness("text")
            harness.type("i")
            XCTAssertEqual(harness.engine.mode, .insert)
            harness.type(keys)
            XCTAssertEqual(harness.engine.mode, .normal, "\(keys) should leave insert mode")
        }
    }

    // MARK: - Off

    func testWithVimModeOffNothingIsIntercepted() throws {
        let harness = try makeHarness("", enabled: false)

        // `dd` is just two letters when the engine is off.
        for key in VimKey.parse("dd") {
            XCTAssertFalse(harness.engine.handle(key), "the engine must not take keys")
        }
        harness.insert("dd")
        XCTAssertEqual(harness.string, "dd")
        XCTAssertEqual(harness.engine.cursorStyle, .bar)
        XCTAssertEqual(harness.view.vimCursorStyle, .bar)
    }

    // MARK: - The window around the engine

    func testTabKeysAndModeResetInARealWindow() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.vimMode
        defer { Preferences.shared.vimMode = previous }
        Preferences.shared.vimMode = true

        let controller = MainWindowController(
            store: SessionStore(directory: try makeTemporaryDirectory())
        )
        _ = try XCTUnwrap(controller.window)
        controller.newTab()
        controller.newTab()
        XCTAssertEqual(controller.vim.mode, .normal)

        func type(_ keys: String) {
            for key in VimKey.parse(keys) { controller.vim.handle(key) }
        }

        // Three tabs, and `gt` walks them, wrapping at the end.
        let start = controller.selectedTabIndex
        type("gt")
        XCTAssertEqual(controller.selectedTabIndex, (start + 1) % 3)
        type("2gt")
        XCTAssertEqual(controller.selectedTabIndex, (start + 3) % 3)
        type("gT")
        XCTAssertEqual(controller.selectedTabIndex, (start + 2) % 3)

        // Switching tabs any other way lands in normal mode too.
        type("i")
        XCTAssertEqual(controller.vim.mode, .insert)
        controller.selectNextTab()
        XCTAssertEqual(controller.vim.mode, .normal)
    }

    func testTurningVimModeOnEntersNormalMode() throws {
        let harness = try makeHarness("hello", enabled: false)
        harness.view.setSelectedRange(NSRange(location: 5, length: 0))

        harness.engine.isEnabled = true
        XCTAssertEqual(harness.engine.mode, .normal)
        // Normal mode never sits past the last character of a line.
        XCTAssertEqual(harness.caret, 4)
        XCTAssertEqual(harness.view.vimCursorStyle, .block)

        harness.type("dw")
        XCTAssertEqual(harness.string, "hell")
    }
}
