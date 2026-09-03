import AppKit
import Foundation
import XCTest
@testable import Nota

/// Maths where the reader meets it: in the render, between the words.
///
/// The engine is `MathTests`' subject; this is the seam around it — which
/// dollars are maths and which are money, what a `$$` block does to the
/// paragraph it stands in, and the promise that a note being typed into never
/// disappears behind a delimiter that has not been closed yet.
final class MarkdownMathTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private let editorFont = NSFont.systemFont(ofSize: 13)

    private func render(
        _ markdown: String, font: NSFont? = nil, width: CGFloat = 400
    ) -> NSAttributedString {
        result(markdown, font: font, width: width).text
    }

    private func result(
        _ markdown: String, font: NSFont? = nil, width: CGFloat = 400
    ) -> MarkdownRenderer.Result {
        MarkdownRenderer.render(
            markdown, font: font ?? editorFont, assets: nil, width: width
        )
    }

    /// Every formula in a render, in the order it is read in.
    private func formulas(_ rendered: NSAttributedString) -> [MathAttachment] {
        attachments(rendered).compactMap { $0 as? MathAttachment }
    }

    private func pictures(_ rendered: NSAttributedString) -> [MarkdownImageAttachment] {
        attachments(rendered).compactMap { $0 as? MarkdownImageAttachment }
    }

    private func attachments(_ rendered: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }
        return found
    }

    private func attributes(
        _ rendered: NSAttributedString, at text: String
    ) throws -> [NSAttributedString.Key: Any] {
        let range = (rendered.string as NSString).range(of: text)
        try XCTSkipIf(range.location == NSNotFound, "\(text.debugDescription) is not there")
        return rendered.attributes(at: range.location, effectiveRange: nil)
    }

    /// The source text each rendered block came from, in order.
    private func sources(_ markdown: String) -> [String] {
        let source = markdown as NSString
        return result(markdown).blocks.map { source.substring(with: $0.source) }
    }

    // MARK: - Inline maths

    func testAnInlineFormulaBecomesOneAttachmentBetweenItsWords() throws {
        let rendered = render("The area is $x^2$ exactly.")

        let maths = formulas(rendered)
        XCTAssertEqual(maths.count, 1)
        XCTAssertEqual(maths.first?.formula.tex, "x^2")
        XCTAssertEqual(maths.first?.formula.isDisplay, false, "in a sentence it is text style")
        XCTAssertTrue(pictures(rendered).isEmpty, "the token is not a picture in the end")
        XCTAssertEqual(rendered.string, "The area is \u{FFFC} exactly.")
    }

    /// The whole reason the maths comes out before Foundation goes in: left
    /// in, these two underscores would have paired up into an emphasis and
    /// eaten the word between them.
    func testTwoFormulasKeepTheirUnderscoresOffTheWordsBetweenThem() throws {
        let rendered = render("$a_1$ and $b_2$")

        let maths = formulas(rendered)
        XCTAssertEqual(maths.map(\.formula.tex), ["a_1", "b_2"])
        XCTAssertEqual(rendered.string, "\u{FFFC} and \u{FFFC}")

        let font = try XCTUnwrap(try attributes(rendered, at: "and")[.font] as? NSFont)
        XCTAssertFalse(
            font.fontDescriptor.symbolicTraits.contains(.italic),
            "the underscores belonged to the formulas, not to the prose"
        )
    }

    func testMathsInAHeadingIsSetAgainstTheHeadingsOwnFont() throws {
        let rendered = render("# Energy $E=mc^2$")
        let formula = try XCTUnwrap(formulas(rendered).first)
        let heading = try XCTUnwrap(try attributes(rendered, at: "Energy")[.font] as? NSFont)
        XCTAssertEqual(formula.font.pointSize, heading.pointSize)
        XCTAssertGreaterThan(formula.font.pointSize, editorFont.pointSize)
    }

    func testAFormulaGrowsWithTheEditorsFontSize() throws {
        let small = try XCTUnwrap(formulas(render("$\\frac{a}{b}$", font: editorFont)).first)
        let large = try XCTUnwrap(formulas(
            render("$\\frac{a}{b}$", font: NSFont.systemFont(ofSize: 20))
        ).first)
        XCTAssertGreaterThan(large.formula.size.height, small.formula.size.height)
        XCTAssertGreaterThan(large.formula.size.width, small.formula.size.width)
    }

    /// A formula is measured against the font, never against the column, so
    /// widening the pane is no reason to render the note again.
    func testAFormulaDoesNotTieTheRenderToThePanesWidth() {
        XCTAssertFalse(result("Some $x^2$ maths.").dependsOnWidth)
    }

    // MARK: - Dollars that are not maths

    func testAnUnclosedDollarStaysTheTextItIs() {
        let rendered = render("Half way through $x and still typing.")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertEqual(rendered.string, "Half way through $x and still typing.")
    }

    func testAnInlineDollarDoesNotCloseOnAnotherLine() {
        let rendered = render("Opened $here\nand closed$ on the line below.")
        XCTAssertTrue(formulas(rendered).isEmpty, "a `$` closes on its own line or not at all")
        XCTAssertTrue(rendered.string.contains("$here"))
        XCTAssertTrue(rendered.string.contains("closed$"))
    }

    func testPricesAreNotFormulas() {
        let rendered = render("It costs $5 and $10 more.")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertEqual(rendered.string, "It costs $5 and $10 more.")
    }

    func testADollarWithSpaceAgainstItOpensNothing() {
        let rendered = render("Between $ x $ there is nothing to read.")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertEqual(rendered.string, "Between $ x $ there is nothing to read.")
    }

    func testAnEscapedDollarIsADollar() {
        let rendered = render("Pay \\$5 for $x^2$ of it.")
        XCTAssertEqual(formulas(rendered).count, 1)
        XCTAssertEqual(rendered.string, "Pay $5 for \u{FFFC} of it.")
    }

    // MARK: - Code wins

    func testADollarInACodeSpanIsCode() throws {
        let rendered = render("Type `$x$` to open maths.")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertEqual(rendered.string, "Type $x$ to open maths.")
        let attributes = try attributes(rendered, at: "$x$")
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertTrue(font.isFixedPitch, "it is a code span, dollars and all")
    }

    func testADollarInAFencedBlockIsCode() {
        let rendered = render("```\nlet price = $x$\n```")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertTrue(rendered.string.contains("let price = $x$"))
    }

    func testADollarInAnIndentedBlockIsCode() {
        let rendered = render("Before.\n\n    let price = $x$\n\nAfter.")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertTrue(rendered.string.contains("let price = $x$"))
    }

    /// A code span is a wall the dollar scan never crosses. A `$` that fails
    /// to close in the prose used to go on looking and find the one inside the
    /// backticks, taking the sentence between them with it.
    func testADollarThatCannotCloseDoesNotReachIntoACodeSpanForOne() throws {
        let rendered = render("Costs $5 and $10 stay prose; `$x$` in code too.")

        XCTAssertTrue(formulas(rendered).isEmpty, "there is no formula in that sentence")
        XCTAssertEqual(rendered.string, "Costs $5 and $10 stay prose; $x$ in code too.")

        for word in ["and", "stay", "prose"] {
            let font = try XCTUnwrap(try attributes(rendered, at: word)[.font] as? NSFont)
            XCTAssertFalse(
                font.fontDescriptor.symbolicTraits.contains(.italic),
                "\(word) is prose, not the inside of a formula"
            )
            XCTAssertFalse(font.isFixedPitch, "\(word) is prose, not code")
        }
        let code = try XCTUnwrap(try attributes(rendered, at: "$x$")[.font] as? NSFont)
        XCTAssertTrue(code.isFixedPitch, "the code span is literal, dollars and all")
    }

    func testACodeSpanBetweenTwoFormulasBelongsToNeither() throws {
        let rendered = render("$a$ `$` $b$")
        XCTAssertEqual(formulas(rendered).map(\.formula.tex), ["a", "b"])
        XCTAssertEqual(rendered.string, "\u{FFFC} $ \u{FFFC}")

        let font = try XCTUnwrap(try attributes(rendered, at: "$")[.font] as? NSFont)
        XCTAssertTrue(font.isFixedPitch, "the dollar between them is a code span")
    }

    func testADisplayDollarDoesNotCloseInsideACodeSpan() {
        let rendered = render("Open $$ then `$$` after.")
        XCTAssertTrue(formulas(rendered).isEmpty)
        XCTAssertEqual(rendered.string, "Open $$ then $$ after.")
    }

    // MARK: - The fallback

    func testTexThatCannotBeReadComesBackAsACodeSpan() throws {
        let rendered = render("Broken ${x$ here.")
        XCTAssertTrue(formulas(rendered).isEmpty, "never a blank, never a crash")
        XCTAssertEqual(rendered.string, "Broken ${x$ here.")

        let attributes = try attributes(rendered, at: "${x$")
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertTrue(font.isFixedPitch, "the raw TeX is shown in the code-span style")
        XCTAssertNotNil(attributes[.backgroundColor], "wash and all")
    }

    // MARK: - Display maths

    func testADisplayFormulaOnItsOwnLinesIsACentredBlock() throws {
        let markdown = "Before.\n\n$$\n\\frac{a}{b}\n$$\n\nAfter."
        let rendered = render(markdown)

        let formula = try XCTUnwrap(formulas(rendered).first)
        XCTAssertEqual(formulas(rendered).count, 1)
        XCTAssertEqual(formula.formula.tex, "\\frac{a}{b}")
        XCTAssertTrue(formula.formula.isDisplay, "on its own it is set in display style")

        let range = (rendered.string as NSString).range(of: "\u{FFFC}")
        let style = try XCTUnwrap(
            rendered.attributes(at: range.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        XCTAssertEqual(style.alignment, .center)
        XCTAssertGreaterThan(style.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(style.paragraphSpacing, 0)
    }

    func testADisplayBlockIsItsOwnBlockCoveringItsDollars() {
        XCTAssertEqual(
            sources("Before.\n\n$$\n\\frac{a}{b}\n$$\n\nAfter."),
            ["Before.", "$$\n\\frac{a}{b}\n$$", "After."]
        )
        XCTAssertEqual(
            sources("Before.\n\n$$x^2$$\n\nAfter."),
            ["Before.", "$$x^2$$", "After."]
        )
    }

    func testAMathFenceIsADisplayBlockCoveringItsFence() throws {
        let markdown = "Before.\n\n```math\n\\sum_{i=1}^n i\n```\n\nAfter."
        let rendered = render(markdown)

        let formula = try XCTUnwrap(formulas(rendered).first)
        XCTAssertEqual(formula.formula.tex, "\\sum_{i=1}^n i")
        XCTAssertTrue(formula.formula.isDisplay)
        XCTAssertFalse(rendered.string.contains("sum"), "a fence of maths is not a fence of code")

        XCTAssertEqual(
            sources(markdown),
            ["Before.", "```math\n\\sum_{i=1}^n i\n```", "After."]
        )
    }

    func testLatexAndTexOpenAFormulaFenceToo() {
        for language in ["latex", "tex", "MATH"] {
            let rendered = render("```\(language)\nx^2\n```")
            XCTAssertEqual(
                formulas(rendered).count, 1, "```\(language) should be a formula"
            )
        }
        XCTAssertTrue(
            formulas(render("```swift\nx^2\n```")).isEmpty,
            "an ordinary fence is still code"
        )
    }

    /// `$$` inside a sentence is display-style maths where it stands, not a
    /// block of its own — the paragraph around it keeps its shape.
    func testDisplayMathsInsideAParagraphStaysInTheParagraph() throws {
        let rendered = render("The identity $$e^{i\\pi}+1=0$$ closes the argument.")
        let formula = try XCTUnwrap(formulas(rendered).first)
        XCTAssertTrue(formula.formula.isDisplay)
        XCTAssertEqual(rendered.string, "The identity \u{FFFC} closes the argument.")

        let style = try XCTUnwrap(
            try attributes(rendered, at: "The identity")[.paragraphStyle] as? NSParagraphStyle
        )
        XCTAssertEqual(style.alignment, .natural, "the sentence is not centred around it")
    }

    func testAnUnclosedDisplayDollarStopsAtItsParagraph() {
        let rendered = render("Opened $$ and never closed.\n\nA new paragraph $x^2$ here.")
        XCTAssertEqual(
            formulas(rendered).map(\.formula.tex), ["x^2"],
            "the blank line ends the paragraph and the `$$` with it"
        )
        XCTAssertTrue(rendered.string.contains("Opened $$ and never closed."))
    }

    /// Every prefix of a note full of maths is a note someone is half way
    /// through typing, and every one of them has to render.
    func testEveryPrefixOfANoteFullOfMathsRenders() {
        let markdown = """
        # $E=mc^2$

        Costs $5, `$x$`.

        $$
        \\frac{1}{i^2}
        $$

        ```math
        \\left(a\\right)
        ```

        End $\\alpha$.
        """
        for length in 0 ... markdown.count {
            let prefix = String(markdown.prefix(length))
            let rendered = render(prefix)
            XCTAssertFalse(
                rendered.string.contains("math://"),
                "a token got out at \(length): \(rendered.string.debugDescription)"
            )
        }
    }

    // MARK: - Block sync

    @MainActor
    func testTheCaretInADisplayBlockLightsIt() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        let markdown = "Before.\n\n$$\nx^2\n$$\n\nAfter."
        editor.insertText(markdown, replacementRange: editor.selectedRange())
        waitForDebounce()

        let blocks = result(markdown).blocks
        XCTAssertEqual(blocks.count, 3, "prose, formula, prose — in order")
        let display = blocks[1].source
        XCTAssertEqual((markdown as NSString).substring(with: display), "$$\nx^2\n$$")

        let preview = try previewView(of: controller)
        editor.setSelectedRange(NSRange(location: display.location + 3, length: 0))
        XCTAssertEqual(
            preview.highlightedSourceRange, display,
            "the caret inside the dollars lights the formula"
        )

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, blocks[0].source)
    }

    @MainActor
    func testClickingADisplayBlockPutsTheCaretOnItsDollars() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "Before.\n\n$$\nx^2\n$$\n\nAfter.", replacementRange: editor.selectedRange()
        )
        waitForDebounce()

        try clickPreview(of: controller, on: "\u{FFFC}")
        XCTAssertEqual(
            editor.selectedRange(), NSRange(location: 9, length: 0),
            "the caret lands on the block's opening `$$`"
        )
    }

    // MARK: - Helpers

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
                isDirty: false, selection: 0, format: .default,
                previewMode: .off
            )],
            selectedTabID: id,
            fontSize: 13
        ))
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
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

    /// Clicks the pane where a piece of the render is drawn, through a real
    /// mouse event, so the click travels the path a reader's does.
    @MainActor
    private func clickPreview(of controller: MainWindowController, on text: String) throws {
        let window = try XCTUnwrap(controller.window)
        let preview = try previewView(of: controller)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        let range = (textView.string as NSString).range(of: text)
        try XCTSkipIf(range.location == NSNotFound, "\(text.debugDescription) is not in the pane")
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let location = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        textView.mouseDown(with: event)
    }

    @MainActor
    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaMathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
