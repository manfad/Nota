import AppKit
import Foundation
import XCTest
@testable import Jot

final class MarkdownPreviewTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private let editorFont = NSFont.systemFont(ofSize: 13)

    private func render(
        _ markdown: String, font: NSFont? = nil,
        assets: AssetStore? = nil, width: CGFloat = 400
    ) -> NSAttributedString {
        result(markdown, font: font, assets: assets, width: width).text
    }

    private func result(
        _ markdown: String, font: NSFont? = nil,
        assets: AssetStore? = nil, width: CGFloat = 400
    ) -> MarkdownRenderer.Result {
        MarkdownRenderer.render(
            markdown, font: font ?? editorFont, assets: assets, width: width
        )
    }

    /// The source text each rendered block came from, in order.
    private func sources(_ markdown: String) -> [String] {
        let source = markdown as NSString
        return result(markdown).blocks.map { source.substring(with: $0.source) }
    }

    /// The attributes on the first character of a piece of the render.
    private func attributes(
        _ rendered: NSAttributedString, at text: String
    ) throws -> [NSAttributedString.Key: Any] {
        let range = (rendered.string as NSString).range(of: text)
        try XCTSkipIf(range.location == NSNotFound, "\(text.debugDescription) is not there")
        return rendered.attributes(at: range.location, effectiveRange: nil)
    }

    private func font(
        _ rendered: NSAttributedString, at text: String
    ) throws -> NSFont {
        try XCTUnwrap(try attributes(rendered, at: text)[.font] as? NSFont)
    }

    private func paragraphStyle(
        _ rendered: NSAttributedString, at text: String
    ) throws -> NSParagraphStyle {
        try XCTUnwrap(try attributes(rendered, at: text)[.paragraphStyle] as? NSParagraphStyle)
    }

    // MARK: - The renderer

    func testEmptyMarkdownRendersNothing() {
        XCTAssertEqual(render("").length, 0)
        XCTAssertEqual(render("").string, "")
        XCTAssertTrue(result("").blocks.isEmpty)
    }

    func testHeadingsScaleFromTheEditorsSizeAndTurnSemibold() throws {
        let markdown = (1 ... 6)
            .map { String(repeating: "#", count: $0) + " Level \($0)" }
            .joined(separator: "\n\n")
        let rendered = render(markdown)

        for level in 1 ... 6 {
            let heading = try font(rendered, at: "Level \(level)")
            let scale = MarkdownRenderer.headingScales[level - 1]
            XCTAssertEqual(
                heading.pointSize, (13 * scale).rounded(),
                "H\(level) should be ×\(scale) of the editor's size"
            )
            XCTAssertTrue(
                heading.fontDescriptor.symbolicTraits.contains(.bold),
                "H\(level) should carry weight"
            )
        }
        // H6 is the editor's own size — the weight is what marks it.
        XCTAssertEqual(try font(rendered, at: "Level 6").pointSize, 13)
    }

    func testAHeadingKeepsTheEditorsFamily() throws {
        let menlo = try XCTUnwrap(NSFont(name: "Menlo", size: 13))
        let rendered = render("# Title", font: menlo)
        let heading = try font(rendered, at: "Title")
        XCTAssertEqual(heading.familyName, menlo.familyName)
        // Menlo has no semibold face, so it gets the bold one it does have.
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testAHeadingIsGivenAirAboveAndBelowIt() throws {
        let rendered = render("Before\n\n# Title\n\nAfter")
        let style = try paragraphStyle(rendered, at: "Title")
        XCTAssertGreaterThan(style.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(style.paragraphSpacing, 0)
    }

    func testParagraphsBecomeSeparateLinesWithSpacingAfterThem() throws {
        let rendered = render("First one.\n\nSecond one.")
        XCTAssertEqual(rendered.string, "First one.\nSecond one.")
        XCTAssertGreaterThan(try paragraphStyle(rendered, at: "First one.").paragraphSpacing, 0)
    }

    /// The newline closing a block belongs to that block, so its spacing is
    /// the spacing that actually shows.
    func testTheNewlineAfterABlockCarriesThatBlocksStyle() throws {
        let rendered = render("# Title\n\nBody")
        let newline = (rendered.string as NSString).range(of: "\n").location
        let style = try XCTUnwrap(
            rendered.attribute(.paragraphStyle, at: newline, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertGreaterThan(style.paragraphSpacingBefore, 0, "still the heading's style")
    }

    func testAnUnorderedListGetsBulletsAndAHeadIndent() throws {
        let rendered = render("- one\n- two")
        XCTAssertEqual(rendered.string, "•\tone\n•\ttwo")
        let style = try paragraphStyle(rendered, at: "one")
        XCTAssertGreaterThan(style.headIndent, 0, "wrapped lines line up under the text")
        XCTAssertEqual(style.firstLineHeadIndent, 0, "the bullet starts at the margin")
        XCTAssertEqual(style.tabStops.first?.location, style.headIndent)
    }

    func testAnOrderedListGetsItsOwnNumbers() {
        XCTAssertEqual(render("1. first\n2. second").string, "1.\tfirst\n2.\tsecond")
        // The numbers come from the document, not from counting rows.
        XCTAssertEqual(render("3. three\n4. four").string, "3.\tthree\n4.\tfour")
    }

    func testNestedListsIndentDeeper() throws {
        let rendered = render("- outer\n  - inner\n")
        let outer = try paragraphStyle(rendered, at: "outer")
        let inner = try paragraphStyle(rendered, at: "inner")
        XCTAssertGreaterThan(inner.headIndent, outer.headIndent)
        XCTAssertGreaterThan(inner.firstLineHeadIndent, outer.firstLineHeadIndent)
        XCTAssertEqual(inner.headIndent, outer.headIndent * 2, accuracy: 0.5)
    }

    func testAListItemsSecondParagraphLinesUpUnderTheMarker() throws {
        let rendered = render("- first line\n\n  second paragraph\n")
        XCTAssertTrue(rendered.string.contains("•\tfirst line"))
        XCTAssertFalse(
            rendered.string.contains("•\tsecond paragraph"),
            "only the item's opening paragraph carries the marker"
        )
        let continuation = try paragraphStyle(rendered, at: "second paragraph")
        XCTAssertEqual(continuation.firstLineHeadIndent, continuation.headIndent)
    }

    func testABlockQuoteGetsAQuietLeadingBar() throws {
        let rendered = render("> quoted")
        XCTAssertEqual(rendered.string, "▏\tquoted")
        XCTAssertEqual(
            try attributes(rendered, at: "▏")[.foregroundColor] as? NSColor,
            .secondaryLabelColor,
            "the bar is quieter than the words"
        )
        XCTAssertEqual(
            try attributes(rendered, at: "quoted")[.foregroundColor] as? NSColor,
            .labelColor
        )
        XCTAssertGreaterThan(try paragraphStyle(rendered, at: "quoted").headIndent, 0)
    }

    func testNestedBlockQuotesGetABarEachAndIndentDeeper() throws {
        let rendered = render("> outer\n>\n> > inner\n")
        XCTAssertTrue(rendered.string.contains("▏\t▏\tinner"), rendered.string.debugDescription)
        XCTAssertGreaterThan(
            try paragraphStyle(rendered, at: "inner").headIndent,
            try paragraphStyle(rendered, at: "outer").headIndent
        )
    }

    func testAFencedBlockIsMonospacedWithItsWhitespaceKept() throws {
        let rendered = render("```swift\nlet x = 1\n    indented\n```")
        XCTAssertEqual(rendered.string, "let x = 1\n    indented")
        let code = try attributes(rendered, at: "let x")
        let codeFont = try XCTUnwrap(code[.font] as? NSFont)
        XCTAssertTrue(codeFont.isFixedPitch, "fenced code is monospaced")
        XCTAssertEqual(codeFont.pointSize, 13, "at the editor's size")
    }

    /// The wash under a fenced block is a box the pane draws, not a colour on
    /// the characters — that hugged each line and came out as a stack of
    /// loose rectangles.
    func testAFencedBlockIsMarkedRatherThanColouredCharacterByCharacter() throws {
        let rendered = render("```\nlet x = 1\n    indented\nlast\n```")
        let whole = NSRange(location: 0, length: rendered.length)

        rendered.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            XCTAssertNil(
                value,
                "no per-character wash at \(range): the box is drawn behind the block"
            )
        }

        var marked = NSRange(location: NSNotFound, length: 0)
        rendered.enumerateAttribute(.jotCodeBlock, in: whole) { value, range, _ in
            guard value != nil else { return }
            marked = marked.location == NSNotFound ? range : NSUnionRange(marked, range)
        }
        XCTAssertEqual(marked, whole, "the mark covers the whole block, in one run")
    }

    /// Only the outer lines carry spacing; between them the code stays a
    /// block rather than a column of spaced-out paragraphs.
    func testAFencedBlocksAirSitsOnItsOuterLinesOnly() throws {
        let rendered = render("```\nfirst\nmiddle\nlast\n```")
        let first = try paragraphStyle(rendered, at: "first")
        let middle = try paragraphStyle(rendered, at: "middle")
        let last = try paragraphStyle(rendered, at: "last")

        XCTAssertEqual(first.paragraphSpacingBefore, MarkdownRenderer.codeBoxPadding)
        XCTAssertEqual(middle.paragraphSpacingBefore, 0)
        XCTAssertEqual(middle.paragraphSpacing, 0)
        XCTAssertGreaterThanOrEqual(last.paragraphSpacing, MarkdownRenderer.codeBoxPadding)

        // And the code is held off the box's left and right edges.
        for style in [first, middle, last] {
            XCTAssertEqual(style.headIndent, MarkdownRenderer.codeBoxInset)
            XCTAssertEqual(style.tailIndent, -MarkdownRenderer.codeBoxInset)
        }
    }

    func testInlineCodeKeepsItsOwnBackground() throws {
        // A span inside a sentence is exactly the case a per-character wash
        // is right for.
        let rendered = render("Call `render()` first.")
        XCTAssertEqual(
            try attributes(rendered, at: "render()")[.backgroundColor] as? NSColor,
            NSColor.labelColor.withAlphaComponent(0.05)
        )
        XCTAssertNil(try attributes(rendered, at: "render()")[.jotCodeBlock])
    }

    func testInlineCodeIsMonospacedOnAWash() throws {
        let rendered = render("Call `render()` first.")
        let code = try attributes(rendered, at: "render()")
        XCTAssertTrue(try XCTUnwrap(code[.font] as? NSFont).isFixedPitch)
        XCTAssertEqual(
            code[.backgroundColor] as? NSColor,
            NSColor.labelColor.withAlphaComponent(0.05)
        )
        // The prose around it is untouched.
        XCTAssertNil(try attributes(rendered, at: "Call")[.backgroundColor])
    }

    func testEmphasisAndStrongBecomeItalicAndBold() throws {
        let rendered = render("plain *slanted* and **heavy**")
        XCTAssertEqual(rendered.string, "plain slanted and heavy")
        XCTAssertTrue(
            try font(rendered, at: "slanted").fontDescriptor.symbolicTraits.contains(.italic)
        )
        XCTAssertTrue(
            try font(rendered, at: "heavy").fontDescriptor.symbolicTraits.contains(.bold)
        )
        let plain = try font(rendered, at: "plain").fontDescriptor.symbolicTraits
        XCTAssertFalse(plain.contains(.italic))
        XCTAssertFalse(plain.contains(.bold))
    }

    func testStrikethroughIsStruckThrough() throws {
        let rendered = render("keep ~~drop~~")
        XCTAssertEqual(
            try attributes(rendered, at: "drop")[.strikethroughStyle] as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNil(try attributes(rendered, at: "keep")[.strikethroughStyle])
    }

    func testLinksAreUnderlinedAndCarryTheirURL() throws {
        let rendered = render("Read [the spec](https://example.com/spec).")
        let link = try attributes(rendered, at: "the spec")
        XCTAssertEqual(link[.link] as? URL, URL(string: "https://example.com/spec"))
        XCTAssertEqual(link[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        // Monochrome: underlined, never tinted.
        XCTAssertEqual(link[.foregroundColor] as? NSColor, .labelColor)
    }

    func testAThematicBreakBecomesAHairlineAcrossThePane() throws {
        let rendered = render("above\n\n---\n\nbelow", width: 320)
        let placeholder = (rendered.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(placeholder.location, NSNotFound, "the rule takes a character")
        let rule = try XCTUnwrap(
            rendered.attribute(.attachment, at: placeholder.location, effectiveRange: nil)
                as? MarkdownRuleAttachment
        )
        XCTAssertEqual(rule.ruleWidth, 320, "it runs the width of the pane")
        XCTAssertTrue(rendered.string.contains("above"))
        XCTAssertTrue(rendered.string.contains("below"))
    }

    func testATableBecomesAlignedMonospacedRows() throws {
        let rendered = render("""
        | name | n |
        | --- | --- |
        | alpha | 1 |
        | b | 22 |
        """)
        XCTAssertEqual(rendered.string, "name   n\nalpha  1\nb      22")
        XCTAssertTrue(try font(rendered, at: "alpha").isFixedPitch)
    }

    func testSoftAndHardBreaksSurvive() {
        // A soft break joins the lines; a hard one keeps them apart.
        XCTAssertEqual(render("one\ntwo").string, "one two")
        XCTAssertEqual(render("one\\\ntwo").string, "one\ntwo")
    }

    func testMalformedMarkdownStillRenders() {
        let rendered = render("# unclosed [link(foo\n\n```\nno end")
        XCTAssertTrue(rendered.string.contains("unclosed"), rendered.string.debugDescription)
        XCTAssertTrue(rendered.string.contains("no end"), rendered.string.debugDescription)
    }

    // MARK: - Source ranges

    func testEveryBlockKnowsWhereItCameFrom() {
        let markdown = """
        # Title

        A plain paragraph.

        - one
        - two
        """
        XCTAssertEqual(
            sources(markdown),
            ["# Title", "A plain paragraph.", "- one", "- two"]
        )
    }

    func testAHeadingsSourceIsItsWholeLineTrailingHashesAndAll() {
        XCTAssertEqual(sources("## Trailing hashes ##"), ["## Trailing hashes ##"])
        XCTAssertEqual(sources("###### Deep\n\nafter"), ["###### Deep", "after"])
    }

    /// `**bold** start` renders as `bold start`, which is nowhere in the
    /// source — the first word alone is what finds the line.
    func testAParagraphOpeningWithMarkupIsStillFound() {
        XCTAssertEqual(
            sources("first\n\n**bold** start of another."),
            ["first", "**bold** start of another."]
        )
        XCTAssertEqual(
            sources("Read [the spec](https://example.com/spec)."),
            ["Read [the spec](https://example.com/spec)."]
        )
    }

    func testNestedListItemsMapToTheirOwnLines() {
        XCTAssertEqual(
            sources("- one\n- two\n  - nested\n"),
            ["- one", "- two", "  - nested"]
        )
        XCTAssertEqual(sources("3. three\n4. four"), ["3. three", "4. four"])
    }

    func testABlockQuoteCoversEveryLineItWasWrittenOn() {
        XCTAssertEqual(
            sources("> quoted line\n> and more\n\nafter"),
            ["> quoted line\n> and more", "after"]
        )
    }

    /// The fence is followed to its close, which is also what keeps code that
    /// happens to repeat later prose from stealing the next block's line.
    func testAFencedBlockCoversBothFencesAndSwallowsWhatIsBetweenThem() {
        let markdown = """
        ```swift
        let x = 1
        after the fence
        ```

        after the fence
        """
        XCTAssertEqual(
            sources(markdown),
            ["```swift\nlet x = 1\nafter the fence\n```", "after the fence"]
        )
    }

    func testAnUnclosedFenceRunsToTheEndOfTheNote() {
        let markdown = "start\n\n```\nno end"
        XCTAssertEqual(sources(markdown), ["start", "```\nno end"])
    }

    func testAThematicBreakMapsToItsRuleLine() {
        XCTAssertEqual(sources("above\n\n---\n\nbelow"), ["above", "---", "below"])
        XCTAssertEqual(sources("above\n\n***\n\nbelow")[1], "***")
    }

    func testAnImageWithNoAltTextIsFoundByItsToken() {
        XCTAssertEqual(
            sources("before\n\n![](jot://x.png)\n\nafter"),
            ["before", "![](jot://x.png)", "after"]
        )
    }

    func testATableCoversAllItsRows() {
        let markdown = "| a | b |\n| - | - |\n| 1 | 2 |\n\nafter"
        XCTAssertEqual(sources(markdown), ["| a | b |\n| - | - |\n| 1 | 2 |", "after"])
    }

    /// A paragraph the writer hard-wrapped renders as one line; its source is
    /// still every line it was typed on.
    func testAHardWrappedParagraphCoversEveryLineOfIt() {
        XCTAssertEqual(
            sources("hard\nwrapped paragraph\n\nafter"),
            ["hard\nwrapped paragraph", "after"]
        )
    }

    /// The search only ever runs forward, so the second copy of a line is
    /// found where it is rather than where the first one was.
    func testTheSameWordsTwiceMapToTheRightOneEachTime() {
        let blocks = result("same words\n\nsame words").blocks
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].source, NSRange(location: 0, length: 10))
        XCTAssertEqual(blocks[1].source, NSRange(location: 12, length: 10))
    }

    func testSourcesRunForwardsAndNeverOverlap() throws {
        let markdown = """
        # Title

        One paragraph.

        - a
        - b

        > quoted

        ```
        code
        ```

        ---

        | x | y |
        | - | - |

        ![](jot://z.png)

        Last one.
        """
        let blocks = result(markdown).blocks
        XCTAssertEqual(blocks.count, 10, "a block each, in document order")
        for (earlier, later) in zip(blocks, blocks.dropFirst()) {
            XCTAssertLessThanOrEqual(
                NSMaxRange(earlier.source), later.source.location,
                "blocks come in document order and never share a character"
            )
            XCTAssertLessThan(earlier.range.location, later.range.location)
        }
        XCTAssertLessThanOrEqual(
            NSMaxRange(try XCTUnwrap(blocks.last).source), (markdown as NSString).length
        )
    }

    func testEveryBlockCarriesItsSourceRangeAsAnAttribute() throws {
        let markdown = "# Title\n\nBody text."
        let rendered = result(markdown)
        let heading = (rendered.text.string as NSString).range(of: "Title")
        let body = (rendered.text.string as NSString).range(of: "Body")

        XCTAssertEqual(
            (rendered.text.attribute(.jotSourceRange, at: heading.location, effectiveRange: nil)
                as? NSValue)?.rangeValue,
            NSRange(location: 0, length: 7)
        )
        XCTAssertEqual(
            (rendered.text.attribute(.jotSourceRange, at: body.location, effectiveRange: nil)
                as? NSValue)?.rangeValue,
            NSRange(location: 9, length: 10)
        )
    }

    // MARK: - Images

    func testAJotTokenBecomesTheAssetsOwnPicture() throws {
        let store = try makeAssetStore()
        let assetID = try XCTUnwrap(store.importImageData(
            makePNG(width: 200, height: 100), preferredExtension: "png"
        ))

        let rendered = render(
            "before\n\n\(NoteText.token(for: assetID))\n\nafter",
            assets: store, width: 400
        )
        let placeholder = (rendered.string as NSString).range(of: "\u{FFFC}")
        let attachment = try XCTUnwrap(
            rendered.attribute(.attachment, at: placeholder.location, effectiveRange: nil)
                as? MarkdownImageAttachment
        )
        XCTAssertEqual(attachment.assetID, assetID)
        XCTAssertNotNil(attachment.image)
        // Narrower than the pane, so it is drawn at its own size.
        XCTAssertEqual(attachment.displaySize, NSSize(width: 200, height: 100))
    }

    func testAPictureWiderThanThePaneIsScaledDownKeepingItsAspect() throws {
        let store = try makeAssetStore()
        let assetID = try XCTUnwrap(store.importImageData(
            makePNG(width: 400, height: 200), preferredExtension: "png"
        ))
        let rendered = render(NoteText.token(for: assetID), assets: store, width: 120)
        let attachment = try XCTUnwrap(
            rendered.attribute(.attachment, at: 0, effectiveRange: nil)
                as? MarkdownImageAttachment
        )
        XCTAssertEqual(attachment.displaySize, NSSize(width: 120, height: 60))
        XCTAssertEqual(attachment.bounds.size, attachment.displaySize)
    }

    func testARemoteImageShowsItsAltTextRatherThanBeingFetched() throws {
        let rendered = render("![a diagram](https://example.com/diagram.png)")
        XCTAssertEqual(rendered.string, "a diagram")
        XCTAssertNil(rendered.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            try attributes(rendered, at: "a diagram")[.foregroundColor] as? NSColor,
            .secondaryLabelColor
        )
    }

    func testAnImageWithNoAltTextShowsItsAddressInstead() throws {
        let rendered = render("![](https://example.com/x.png)", assets: try makeAssetStore())
        XCTAssertEqual(rendered.string, "https://example.com/x.png")
    }

    func testAMissingAssetShowsItsTokenRatherThanVanishing() throws {
        let store = try makeAssetStore()
        let rendered = render(NoteText.token(for: "gone.png"), assets: store)
        XCTAssertEqual(rendered.string, "jot://gone.png")
        XCTAssertNil(rendered.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    // MARK: - The pane

    @MainActor
    func testThePaneKeepsItsPlaceAcrossARender() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        preview.layoutSubtreeIfNeeded()

        let long = (1 ... 200).map { "Line \($0)" }.joined(separator: "\n\n")
        let rendered = result(long)
        preview.show(rendered)
        XCTAssertEqual(preview.scrollFraction, 0, accuracy: 0.01, "a fresh render opens at the top")

        // Lighting a block far down the note scrolls the pane to it.
        let late = try XCTUnwrap(rendered.blocks.last).source.location
        preview.highlightBlock(containingSource: late)
        let reached = preview.scrollFraction
        XCTAssertGreaterThan(reached, 0.5)

        // Re-rendering the same note does not throw the reader back to the top.
        preview.show(result(long))
        XCTAssertEqual(preview.scrollFraction, reached, accuracy: 0.05)
    }

    @MainActor
    func testThePaneIsReadOnlyAndSelectable() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        XCTAssertFalse(textView.isEditable, "the pane is never a second place to type")
        XCTAssertTrue(textView.isSelectable, "but its text can be copied out")
    }

    @MainActor
    func testThePaneAsksForAFreshRenderWhenItChangesWidth() {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var renders = 0
        preview.onWidthChange = { renders += 1 }

        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        XCTAssertEqual(renders, 1, "the first layout is a width nothing has been drawn to")

        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        XCTAssertEqual(renders, 1, "laying out again at the same width asks for nothing")

        preview.setFrameSize(NSSize(width: 520, height: 200))
        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        XCTAssertEqual(renders, 2, "pictures fitted to 300pt have to be fitted again")
    }

    // MARK: - The window

    /// The menu's checkmark is the front tab's answer, not the app's, and
    /// ⇧⌘P walks it round all three modes.
    @MainActor
    func testTheViewMenuTogglesThePaneForTheTabInFront() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        XCTAssertFalse(controller.previewState.isVisible, "the editor until asked for")
        XCTAssertEqual(controller.previewMode, .off, "and the checkmark is off with it")

        controller.toggleMarkdownPreview()
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .split)

        // Reading is the third stop of the cycle, and the render is still up.
        controller.toggleMarkdownPreview()
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .reading)

        controller.toggleMarkdownPreview()
        XCTAssertFalse(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .off)
    }

    /// ⇧⌘P on one tab is about that tab. Opening the pane on a Markdown note
    /// must not follow you into the next one.
    @MainActor
    func testThePaneBelongsToTheTabItWasOpenedOn() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        XCTAssertTrue(controller.previewState.isVisible)

        controller.newTab()
        XCTAssertFalse(controller.previewState.isVisible, "a new tab opens without it")
        XCTAssertFalse(controller.showsMarkdownPreview)
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, true)

        controller.selectTab(at: 0)
        XCTAssertTrue(controller.previewState.isVisible, "the first tab still wants it")
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)

        // And the other way round: turning it on in a second Markdown tab
        // leaves the first one alone. The untitled tab itself is ineligible.
        let second = try makeTemporaryDirectory().appendingPathComponent("second.md")
        try "".write(to: second, atomically: true, encoding: .utf8)
        controller.open(url: second)
        controller.setPreviewMode(.split)
        XCTAssertTrue(controller.previewState.isVisible)
        controller.selectTab(at: 0)
        controller.setPreviewMode(.off)
        XCTAssertFalse(controller.previewState.isVisible)
        controller.selectTab(at: 1)
        XCTAssertTrue(controller.previewState.isVisible, "the second tab kept its own answer")
    }

    @MainActor
    func testPreviewIsAvailableOnlyForDotMdFiles() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        XCTAssertTrue(controller.canShowMarkdownPreview)

        let directory = try makeTemporaryDirectory()
        let text = directory.appendingPathComponent("notes.txt")
        try "# Plain text".write(to: text, atomically: true, encoding: .utf8)
        controller.open(url: text)

        XCTAssertFalse(controller.canShowMarkdownPreview)
        controller.toggleMarkdownPreview()
        XCTAssertFalse(controller.previewState.isVisible)
        XCTAssertFalse(controller.showsMarkdownPreview)

        let uppercase = directory.appendingPathComponent("notes.MD")
        try "# Markdown".write(to: uppercase, atomically: true, encoding: .utf8)
        controller.open(url: uppercase)
        XCTAssertTrue(controller.canShowMarkdownPreview)
    }

    /// A file dropped on the window is a fresh tab like any other: it opens
    /// as it was asked for, not as the tab beside it happens to be.
    @MainActor
    func testAFreshlyOpenedFileOpensWithoutThePane() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let file = try makeTemporaryDirectory().appendingPathComponent("notes.md")
        try "# Heading".write(to: file, atomically: true, encoding: .utf8)

        controller.open(url: file)
        XCTAssertFalse(controller.previewState.isVisible, "the opened file has no pane")

        controller.selectTab(at: 0)
        XCTAssertTrue(controller.previewState.isVisible)
    }

    /// The flag rides in `session.json`, so each tab comes back the way it was
    /// left rather than every tab sharing one answer.
    @MainActor
    func testEachTabComesBackFromTheSessionWithItsOwnPane() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()

        do {
            let controller = try makeController(in: directory)
            controller.toggleMarkdownPreview()
            controller.newTab()
            XCTAssertFalse(controller.previewState.isVisible)
            controller.flushAll()
        }

        let relaunched = try makeController(in: directory)
        XCTAssertFalse(relaunched.previewState.isVisible, "the tab it opens on had none")
        relaunched.selectTab(at: 0)
        XCTAssertTrue(
            relaunched.previewState.isVisible,
            "and the one that did gets it back"
        )
        XCTAssertEqual(previewItem(of: relaunched)?.isCollapsed, false)
    }

    /// A session.json written before the pane was per-tab says nothing about
    /// it; those tabs still decode, and come back without one.
    func testASessionWrittenBeforeThePaneWasPerTabStillDecodes() throws {
        let directory = try makeTemporaryDirectory()
        let id = UUID()
        let json = """
        {"fontSize":13,"selectedTabID":"\(id.uuidString)",\
        "tabs":[{"id":"\(id.uuidString)","isDirty":false,"selection":0}]}
        """
        try json.write(
            to: directory.appendingPathComponent("session.json"),
            atomically: true, encoding: .utf8
        )

        let state = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertNil(state.tabs.first?.previewMode)
    }

    @MainActor
    func testAHiddenPaneIsCollapsedRatherThanRemoved() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, true)
        XCTAssertEqual(previewItem(of: controller)?.minimumThickness, 240)
        XCTAssertEqual(previewItem(of: controller)?.preferredThicknessFraction, 0.5)
    }

    /// Toggling the pane must never resize the window. It used to: the pane
    /// asked the split view to grow for it, so opening it widened the window
    /// and closing it took that width off the editor — a zoomed window came
    /// back narrower than it went in.
    ///
    /// The guard is on the collapse behaviour itself rather than on the panes'
    /// widths, because AppKit does not arrange a split view in a window that
    /// was never on screen: under test the panes keep their pre-layout frames
    /// and measure identically whichever behaviour is set, so a width
    /// assertion would pass for the wrong reason. The window's frame is
    /// checked too — that much the controller does own.
    @MainActor
    func testTheEditorGivesUpTheRoomForThePaneRatherThanTheWindow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let item = try XCTUnwrap(previewItem(of: controller))

        XCTAssertEqual(
            item.collapseBehavior, .preferResizingSiblingsWithFixedSplitView,
            "the split view keeps its size; its siblings share the room out"
        )
        XCTAssertEqual(item.preferredThicknessFraction, 0.5, "half the width on opening")

        let frame = NSRect(x: 120, y: 140, width: 1100, height: 620)
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()

        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame, "opening the pane neither moves nor resizes it")

        controller.setPreviewMode(.off)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame, "and closing it leaves the frame exactly as it was")
    }

    /// The items are rebuilt when the sidebar changes sides, so the behaviour
    /// has to be set there too rather than only on the first build.
    @MainActor
    func testThePaneKeepsItsCollapseBehaviourWhenTheSidebarChangesSides() throws {
        _ = NSApplication.shared
        let previousSide = Preferences.shared.sidebarSide
        defer { Preferences.shared.sidebarSide = previousSide }

        for side in [SidebarSide.right, .left] {
            Preferences.shared.sidebarSide = side
            let controller = try makeControllerShowingPreview()
            let item = try XCTUnwrap(previewItem(of: controller))
            XCTAssertEqual(
                item.collapseBehavior, .preferResizingSiblingsWithFixedSplitView,
                "on the \(side.title)"
            )
            XCTAssertEqual(item.preferredThicknessFraction, 0.5)
        }
    }

    @MainActor
    func testThePaneSitsBetweenTheEditorAndTheImageSidebar() throws {
        _ = NSApplication.shared
        let previousSide = Preferences.shared.sidebarSide
        defer { Preferences.shared.sidebarSide = previousSide }

        for side in [SidebarSide.right, .left] {
            Preferences.shared.sidebarSide = side
            let controller = try makeControllerShowingPreview()
            let roles = try splitRoles(of: controller)
            XCTAssertEqual(
                roles,
                side == .right
                    ? ["workspace", "sidebar"]
                    : ["sidebar", "workspace"],
                "the images stay outermost on the \(side.title)"
            )
            let documentRoles = try documentSplitViewController(of: controller).splitViewItems.map {
                let view = $0.viewController.view
                if descendant(of: view, ofType: JotTextView.self) != nil { return "editor" }
                if descendant(of: view, ofType: MarkdownPreviewView.self) != nil { return "preview" }
                return "?"
            }
            XCTAssertEqual(documentRoles, ["editor", "preview"])
        }
    }

    /// Zen strips the chrome, not the note. In split the render is half of
    /// what is being read, so it stays — at the width it was left at — while
    /// the strip, the footer and both mode controls go.
    @MainActor
    func testZenKeepsTheSplitAndTakesOnlyTheChrome() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertTrue(controller.previewState.isVisible)
        let preview = try previewView(of: controller)
        let width = preview.frame.width
        XCTAssertGreaterThan(width, 0, "the panes have to be laid out for the divider to mean anything")

        controller.toggleZenMode()
        window.layoutIfNeeded()
        XCTAssertTrue(controller.previewState.isVisible, "the render is half the note, not chrome")
        XCTAssertEqual(controller.previewMode, .split, "and the mode is untouched")
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, false, "both columns stay")
        XCTAssertEqual(preview.frame.width, width, accuracy: 0.5, "at the divider it was left at")

        // The controls over the two columns are chrome, and go with the rest.
        let (editorOverlay, previewOverlay) = controller.modeControlOverlays
        XCTAssertTrue(editorOverlay.isHidden)
        XCTAssertTrue(previewOverlay.isHidden)

        controller.toggleZenMode()
        window.layoutIfNeeded()
        XCTAssertTrue(controller.previewState.isVisible, "and nothing moved on the way out")
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(preview.frame.width, width, accuracy: 0.5)
        XCTAssertFalse(editorOverlay.isHidden, "the controls come back with the chrome")
        XCTAssertFalse(previewOverlay.isHidden)
    }

    /// Opening the pane beside the editor is not asking to type in it. Only
    /// reading mode, where the editor is not on screen at all, moves the keys.
    @MainActor
    func testTogglingThePaneLeavesTheCaretInTheEditor() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        controller.focusEditor()

        controller.setPreviewMode(.split)
        XCTAssertTrue(
            window.firstResponder is JotTextView,
            "the pane is read, not typed in"
        )
        controller.setPreviewMode(.off)
        XCTAssertTrue(window.firstResponder is JotTextView)
    }

    @MainActor
    func testTypingReRendersThePaneOnceTheKeystrokesStop() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: JotTextView.self)
        )
        XCTAssertEqual(controller.previewState.renderedText, "", "an empty note")

        editor.insertText("# Hello", replacementRange: editor.selectedRange())
        XCTAssertEqual(
            controller.previewState.renderedText, "",
            "nothing re-renders while the keys are still coming"
        )

        waitForDebounce()
        XCTAssertEqual(controller.previewState.renderedText, "Hello")

        editor.insertText("\n\n- item", replacementRange: editor.selectedRange())
        waitForDebounce()
        XCTAssertEqual(controller.previewState.renderedText, "Hello\n•\titem")
    }

    @MainActor
    func testSwitchingTabsRendersTheTabYouLandOn() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: JotTextView.self)
        )
        editor.insertText("## First tab", replacementRange: editor.selectedRange())
        waitForDebounce()
        XCTAssertEqual(controller.previewState.renderedText, "First tab")

        // The pane is per tab, so the second Markdown file asks for it too.
        let second = try makeTemporaryDirectory().appendingPathComponent("second.md")
        try "".write(to: second, atomically: true, encoding: .utf8)
        controller.open(url: second)
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewState.renderedText, "", "the new tab is empty")

        controller.selectTab(at: 0)
        XCTAssertEqual(
            controller.previewState.renderedText, "First tab",
            "switching back re-renders straight away, without waiting"
        )
    }

    @MainActor
    func testAHiddenPaneIsNotRenderedAtAll() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: JotTextView.self)
        )
        editor.insertText("# Unseen", replacementRange: editor.selectedRange())
        waitForDebounce()
        XCTAssertEqual(controller.previewState.renderedText, "")

        // Turning it on renders what is already there.
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewState.renderedText, "Unseen")
    }

    // MARK: - Shared tab strip

    @MainActor
    func testThePreviewContentStartsAtTheTopOfItsPane() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        preview.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(descendant(of: preview, ofType: NSScrollView.self))
        XCTAssertEqual(scrollView.frame, preview.bounds)
    }

    @MainActor
    func testSharedChromeSpansTheEditorAndPreviewAroundTheirDivider() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        controller.window?.layoutIfNeeded()
        let content = try XCTUnwrap(controller.window?.contentView)
        let tabBar = try XCTUnwrap(descendant(of: content, ofType: TabBarView.self))
        let editor = try editorTextView(of: controller)
        let preview = try previewView(of: controller)
        let footer = controller.footerRegions

        let tabs = tabBar.convert(tabBar.bounds, to: content)
        let editorFrame = editor.convert(editor.bounds, to: content)
        let previewFrame = preview.convert(preview.bounds, to: content)
        let badge = footer.badge.convert(footer.badge.bounds, to: content)
        let cursor = footer.cursor.convert(footer.cursor.bounds, to: content)
        let dividerX = (editorFrame.maxX + previewFrame.minX) / 2
        XCTAssertLessThan(tabs.minX, dividerX)
        XCTAssertGreaterThan(tabs.maxX, dividerX)
        XCTAssertLessThanOrEqual(editorFrame.maxY, tabs.minY + 0.5)
        XCTAssertLessThanOrEqual(previewFrame.maxY, tabs.minY + 0.5)
        XCTAssertLessThan(badge.minX, dividerX)
        XCTAssertGreaterThan(cursor.maxX, dividerX)
        XCTAssertGreaterThanOrEqual(editorFrame.minY, badge.maxY - 0.5)
        XCTAssertGreaterThanOrEqual(previewFrame.minY, cursor.maxY - 0.5)
    }

    // MARK: - Code boxes

    @MainActor
    func testThePaneDrawsOneBoxPerCodeBlockAcrossItsFullWidth() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        preview.layoutSubtreeIfNeeded()
        preview.show(result("""
        Before.

        ```
        one
        two
        three
        ```

        Between.

        ```
        second block
        ```

        After.
        """, width: preview.contentWidth))

        let boxes = preview.codeBoxRects
        XCTAssertEqual(boxes.count, 2, "one box per fenced block, not one per line")

        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let inset = textView.textContainerOrigin.x
        for box in boxes {
            XCTAssertEqual(box.minX, inset, accuracy: 0.5, "boxes start at the pane's margin")
            XCTAssertEqual(
                box.width, textView.bounds.width - inset * 2, accuracy: 0.5,
                "and run the content width, not the width of the code in them"
            )
        }

        // The three-line block is the taller of the two, and neither is a
        // sliver hugging one line.
        XCTAssertGreaterThan(boxes[0].height, boxes[1].height)
        XCTAssertGreaterThan(boxes[1].height, MarkdownRenderer.codeBoxPadding * 2)
    }

    @MainActor
    func testACodeBoxCoversEveryLineOfItsBlockWithAirAround() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        preview.layoutSubtreeIfNeeded()
        preview.show(result("```\nfirst\nsecond\nthird\n```", width: preview.contentWidth))

        let box = try XCTUnwrap(preview.codeBoxRects.first)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        // Every line of the block sits inside the one box, with the padding
        // clear above the first and below the last.
        for line in ["first", "second", "third"] {
            let range = (textView.string as NSString).range(of: line)
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            XCTAssertTrue(box.contains(NSPoint(x: box.midX, y: rect.midY)), "\(line) is in the box")
            XCTAssertLessThanOrEqual(box.minY, rect.minY - MarkdownRenderer.codeBoxPadding + 0.5)
            XCTAssertGreaterThanOrEqual(
                box.maxY, rect.maxY + MarkdownRenderer.codeBoxPadding - 0.5
            )
        }
    }

    /// The band goes on over the box, and takes its air, so a lit fenced
    /// block darkens as one shape rather than showing the box's edge.
    @MainActor
    func testALitCodeBlocksBandCoversItsBox() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        preview.layoutSubtreeIfNeeded()
        let markdown = "Before.\n\n```\none\ntwo\n```"
        let rendered = result(markdown, width: preview.contentWidth)
        preview.show(rendered)

        let code = try XCTUnwrap(rendered.blocks.last)
        preview.highlightBlock(containingSource: code.source.location)
        XCTAssertEqual(preview.highlightedSourceRange, code.source)

        let box = try XCTUnwrap(preview.codeBoxRects.first)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let band = try XCTUnwrap(preview.highlightedBandRect)
        XCTAssertLessThanOrEqual(band.minY, box.minY + 0.5)
        XCTAssertGreaterThanOrEqual(band.maxY, box.maxY - 0.5)
        XCTAssertEqual(band.width, textView.bounds.width, accuracy: 0.5)
    }

    @MainActor
    func testANoteWithoutFencedCodeDrawsNoBoxes() {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        preview.layoutSubtreeIfNeeded()
        preview.show(result("# Title\n\nJust prose with `inline code` in it."))
        XCTAssertTrue(preview.codeBoxRects.isEmpty, "an inline span is not a block")
    }

    // MARK: - Block sync

    @MainActor
    func testClickingABlockPutsTheCaretOnItsSourceInTheEditor() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        XCTAssertEqual(
            controller.previewState.renderedText,
            "Title\nFirst paragraph.\nSecond paragraph."
        )

        try clickPreview(of: controller, on: "Second paragraph.")
        // "Second paragraph." starts at 27 in the source.
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 27, length: 0))

        try clickPreview(of: controller, on: "Title")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0),
                       "the caret lands on the block's first character")
    }

    @MainActor
    func testClickingABlockLeavesFocusInTheEditor() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        let editor = try editorTextView(of: controller)
        editor.insertText("# Title\n\nBody.", replacementRange: editor.selectedRange())
        waitForDebounce()
        controller.focusEditor()

        try clickPreview(of: controller, on: "Body.")
        XCTAssertTrue(
            window.firstResponder is JotTextView,
            "a click in the pane is a jump, not a place to type"
        )
        let preview = try previewView(of: controller)
        let previewText = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        XCTAssertFalse(previewText.acceptsFirstResponder)
    }

    @MainActor
    func testClickingABlockOffScreenScrollsTheEditorToIt() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        let long = (1 ... 120).map { "Paragraph \($0) of the note." }
            .joined(separator: "\n\n")
        editor.insertText(long, replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        waitForDebounce()

        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)

        try clickPreview(of: controller, on: "Paragraph 100 of the note.")
        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y, 0,
            "the editor comes to the block that was clicked"
        )
        let caret = editor.selectedRange().location
        XCTAssertEqual(
            (editor.string as NSString).substring(
                with: NSRange(location: caret, length: 13)
            ),
            "Paragraph 100"
        )
    }

    @MainActor
    func testClickingABlockInVimModeComesBackToNormalMode() throws {
        _ = NSApplication.shared
        let previousVim = Preferences.shared.vimMode
        defer { Preferences.shared.vimMode = previousVim }

        Preferences.shared.vimMode = true
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("# Title\n\nBody.", replacementRange: editor.selectedRange())
        waitForDebounce()

        controller.vim.enterInsertMode()
        XCTAssertEqual(controller.vim.mode, .insert)
        try clickPreview(of: controller, on: "Body.")
        XCTAssertEqual(controller.vim.mode, .normal, "a jump is a move, not a typing session")
    }

    @MainActor
    func testMovingTheCaretLightsTheBlockItIsIn() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        let preview = try previewView(of: controller)

        editor.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 0, length: 7))

        editor.setSelectedRange(NSRange(location: 12, length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 9, length: 16))

        editor.setSelectedRange(NSRange(location: 30, length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 27, length: 17))

        // A caret on the blank line between two blocks belongs to the one
        // above it rather than to nothing.
        editor.setSelectedRange(NSRange(location: 26, length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 9, length: 16))
    }

    @MainActor
    func testEditingPutsTheBandOutAndTheReRenderBringsItBack() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText("# Title\n\nBody.", replacementRange: editor.selectedRange())
        waitForDebounce()
        let preview = try previewView(of: controller)

        editor.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNotNil(preview.highlightedSourceRange)

        // The blocks have moved under the band; it means nothing until the
        // pane is rendered again.
        editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(preview.highlightedSourceRange, "the band goes out on an edit")

        waitForDebounce()
        XCTAssertNotNil(
            preview.highlightedSourceRange,
            "and comes back for the caret once the render lands"
        )
    }

    @MainActor
    func testTheBandIsOnlyEverOnOneBlock() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        preview.layoutSubtreeIfNeeded()
        preview.show(result("# One\n\nTwo\n\nThree"))

        preview.highlightBlock(containingSource: 0)
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 0, length: 5))
        preview.highlightBlock(containingSource: 8)
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 7, length: 3))

        preview.invalidateBlocks()
        XCTAssertNil(preview.highlightedSourceRange)
        XCTAssertFalse(
            preview.highlightBlock(containingSource: 0),
            "nothing lights up while the blocks are stale"
        )
    }

    // MARK: - Reading mode

    /// ⌥⇧⌘P is the shortcut for the render on its own: straight to it from
    /// wherever the tab was, and straight back out of it.
    @MainActor
    func testReadingModeJumpsStraightThereAndBackAgain() throws {
        _ = NSApplication.shared
        let controller = try makeController()

        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertTrue(controller.previewState.isVisible)

        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .off, "and back to the text, not to the split")

        // From the split it is one step in, one step out.
        controller.setPreviewMode(.split)
        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .reading)
    }

    /// Reading mode collapses the editor rather than the window: the render
    /// takes the column the text had, and the frame is the frame it was.
    @MainActor
    func testReadingModeCollapsesTheEditorAndNeverTheWindow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(editorItem(of: controller))

        XCTAssertTrue(editor.canCollapse, "the editor has to be collapsible to get out of the way")
        XCTAssertEqual(
            editor.collapseBehavior, .preferResizingSiblingsWithFixedSplitView,
            "the render takes the room the editor gives up; the window keeps its size"
        )

        let frame = NSRect(x: 120, y: 140, width: 1100, height: 620)
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()

        controller.setPreviewMode(.reading)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.isCollapsed, true, "the text is not on screen in reading mode")
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(window.frame, frame, "going in neither moves nor resizes the window")

        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.isCollapsed, false, "and the editor is back beside the render")
        XCTAssertEqual(window.frame, frame)

        controller.setPreviewMode(.off)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.isCollapsed, false)
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, true)
        XCTAssertEqual(window.frame, frame, "and coming all the way out leaves it where it was")
    }

    /// The two panes are never both collapsed, not even for the instant a
    /// mode change takes — that would leave the window showing nothing.
    @MainActor
    func testSomethingIsAlwaysOnScreenAsTheModesChange() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let editor = try XCTUnwrap(editorItem(of: controller))
        let preview = try XCTUnwrap(previewItem(of: controller))

        for mode in [PreviewMode.reading, .off, .reading, .split, .off] {
            controller.setPreviewMode(mode)
            XCTAssertFalse(
                editor.isCollapsed && preview.isCollapsed,
                "nothing to look at in \(mode.rawValue)"
            )
        }
    }

    /// In reading mode the keyboard belongs to the render — the editor is not
    /// on screen to hold it — and it goes back the moment the editor is.
    @MainActor
    func testTheRenderTakesTheKeyboardOnlyInReadingMode() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)

        controller.setPreviewMode(.reading)
        XCTAssertFalse(
            window.firstResponder is JotTextView,
            "the editor is collapsed; it cannot be where the keys go"
        )

        controller.setPreviewMode(.split)
        XCTAssertTrue(window.firstResponder is JotTextView, "the caret is back in the text")
    }

    /// Reading has no way out but the mode control and its shortcuts. Typing
    /// is not one: there is no editor on screen for the key to land in, so
    /// the key goes nowhere and the page stays where it is.
    @MainActor
    func testAPrintableKeyInReadingModeDoesNothing() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let editor = try editorTextView(of: controller)
        editor.insertText("note", replacementRange: editor.selectedRange())

        controller.setPreviewMode(.reading)
        try type("x", into: controller)

        XCTAssertEqual(controller.previewMode, .reading, "no way out through the keyboard")
        XCTAssertEqual(editor.string, "note", "and nothing landed in the text")
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, true)
    }

    /// An arrow key is the render's own — it walks the page rather than
    /// asking for the editor back.
    @MainActor
    func testAnArrowKeyInReadingModeStaysInTheRender() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.setPreviewMode(.reading)

        // 0xF701 is NSDownArrowFunctionKey — a private-use code point, not a
        // character any note could hold.
        try type("\u{F701}", into: controller, modifiers: .function)
        XCTAssertEqual(controller.previewMode, .reading, "the render scrolls; the editor stays away")
    }

    /// ⌘F in reading searches what is on screen — the render — rather than
    /// fetching the editor back to search that. The bar opens over the page,
    /// and takes the corner from the render's own mode control while it is up.
    @MainActor
    func testCommandFInReadingModeSearchesTheRender() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        controller.setPreviewMode(.reading)
        window.layoutIfNeeded()

        let preview = try previewView(of: controller)
        let rendered = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let scrollView = try XCTUnwrap(rendered.enclosingScrollView)
        XCTAssertEqual(scrollView.findBarPosition, .aboveContent, "above the page, not under it")

        let find = NSMenuItem(title: "Find…", action: nil, keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        XCTAssertTrue(
            rendered.validateUserInterfaceItem(find),
            "the menu item has to stay enabled or ⌘F never arrives here"
        )
        rendered.performTextFinderAction(find)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.previewMode, .reading, "the search happens where you are")
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, true, "no editor came back")

        try XCTSkipUnless(scrollView.isFindBarVisible, "no find bar headlessly")
        XCTAssertTrue(preview.isFindBarVisible)
        XCTAssertTrue(
            controller.modeControlOverlays.preview.isHidden,
            "the control gets out of the bar's way"
        )

        let hideFind = NSMenuItem()
        hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
        rendered.performTextFinderAction(hideFind)
        window.layoutIfNeeded()
        XCTAssertFalse(
            controller.modeControlOverlays.preview.isHidden, "and comes back when the bar goes"
        )
    }

    /// Reading is for reading. A click on the page is just a click: it does
    /// not fetch the editor back, does not move the caret, and lights no
    /// block — there is no editor on screen for any of that to point at.
    @MainActor
    func testClickingABlockInReadingModeStaysInReading() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()

        // The caret is at the end of the note, where the typing left it.
        controller.setPreviewMode(.reading)
        let caret = editor.selectedRange()
        let preview = try previewView(of: controller)
        let litBefore = preview.highlightedSourceRange

        try clickPreview(of: controller, on: "Second paragraph.")

        XCTAssertEqual(controller.previewMode, .reading, "the page is where you still are")
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, true, "no editor came back")
        XCTAssertEqual(editor.selectedRange(), caret, "and the caret never moved")
        XCTAssertEqual(preview.highlightedSourceRange, litBefore, "no band under the click")
    }

    /// In split the same click is a jump: the render is a map into the text
    /// beside it, and clicking a block puts the caret on that block.
    @MainActor
    func testClickingABlockInSplitPutsTheCaretOnIt() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()

        try clickPreview(of: controller, on: "Second paragraph.")

        XCTAssertEqual(controller.previewMode, .split)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 27, length: 0))
    }

    /// The mode is the tab's, all three of them: switching tabs lays out for
    /// the tab you land on, un-animated, the way its text simply appears.
    @MainActor
    func testSwitchingTabsAppliesTheModeOfTheTabYouLandOn() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.setPreviewMode(.split)
        controller.open(url: try makeMarkdownFile(named: "second.md"))
        controller.setPreviewMode(.reading)
        controller.open(url: try makeMarkdownFile(named: "third.md"))
        XCTAssertEqual(controller.previewMode, .off, "a freshly opened file starts in the editor")

        controller.selectTab(at: 1)
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, true)
        XCTAssertEqual(controller.previewModeControl.selectedSegment, 2)

        controller.selectTab(at: 0)
        XCTAssertEqual(controller.previewMode, .split)
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(controller.previewModeControl.selectedSegment, 1)

        controller.selectTab(at: 2)
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, true)
        XCTAssertEqual(controller.previewModeControl.selectedSegment, 0)
    }

    /// The mode rides in `session.json`, so a tab comes back reading if that
    /// is how it was left.
    @MainActor
    func testEachTabComesBackFromTheSessionInItsOwnMode() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let second = try makeMarkdownFile(named: "second.md")

        do {
            let controller = try makeController(in: directory)
            controller.setPreviewMode(.reading)
            controller.open(url: second)
            controller.setPreviewMode(.split)
            controller.flushAll()
        }

        let relaunched = try makeController(in: directory)
        XCTAssertEqual(relaunched.previewMode, .split, "the tab it opens on")
        relaunched.selectTab(at: 0)
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertEqual(editorItem(of: relaunched)?.isCollapsed, true)
        XCTAssertEqual(relaunched.previewModeControl.selectedSegment, 2)
    }

    /// The pane used to be a yes/no. Those sessions still decode, and a tab
    /// that had the pane open comes back split rather than losing it.
    func testASessionWrittenWhenThePaneWasAYesOrNoComesBackSplit() throws {
        let directory = try makeTemporaryDirectory()
        let open = UUID()
        let closed = UUID()
        let json = """
        {"fontSize":13,"selectedTabID":"\(open.uuidString)","tabs":[\
        {"id":"\(open.uuidString)","isDirty":false,"selection":0,"showsPreview":true},\
        {"id":"\(closed.uuidString)","isDirty":false,"selection":0,"showsPreview":false}]}
        """
        try json.write(
            to: directory.appendingPathComponent("session.json"),
            atomically: true, encoding: .utf8
        )

        let state = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(state.tabs.map(\.previewMode), [.split, .off])
    }

    /// Round trip: what is written is the new key, and it reads back the same.
    func testTheModeRoundTripsThroughTheSessionFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let tab = SessionTab(
            id: UUID(), path: nil, untitledName: "Untitled", isDirty: false,
            selection: 0, format: nil, previewMode: .reading
        )
        store.save(SessionState(tabs: [tab], selectedTabID: tab.id, fontSize: 13))

        let written = try String(
            contentsOf: directory.appendingPathComponent("session.json"), encoding: .utf8
        )
        XCTAssertTrue(written.contains("\"previewMode\" : \"reading\""))
        XCTAssertFalse(written.contains("showsPreview"), "the old key is not written back")
        XCTAssertEqual(try XCTUnwrap(store.load()).tabs, [tab])
    }

    /// Zen keeps the split, so the render column is now a column whose top
    /// edge is the window's own. It takes the same drop the editor takes, so
    /// the page does not start under the traffic-light zone and the two
    /// columns' text lines up, and it gets a drag band of its own so the
    /// window can still be moved by that edge.
    @MainActor
    func testZenGivesTheRenderColumnTheSameTopBandAsTheEditor() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let pane = try XCTUnwrap(previewItem(of: controller)?.viewController.view)
        window.layoutIfNeeded()

        // 28pt is the zen top inset; nothing else in the column is that tall.
        let bands = pane.subviews.filter {
            abs($0.frame.height - 28) < 0.5 && $0.mouseDownCanMoveWindow
        }
        XCTAssertEqual(bands.count, 1, "one drag band over the render column")
        XCTAssertTrue(bands[0].isHidden, "away while there is a tab strip to drag by")

        controller.toggleZenMode()
        window.layoutIfNeeded()

        let editorScroll = try XCTUnwrap(try editorTextView(of: controller).enclosingScrollView)
        let preview = try previewView(of: controller)
        let editorTop = editorScroll.convert(editorScroll.bounds, to: content).maxY
        let previewTop = preview.convert(preview.bounds, to: content).maxY
        XCTAssertEqual(previewTop, editorTop, accuracy: 0.5,
                       "both columns start on the same line in zen")
        XCTAssertEqual(content.bounds.maxY - previewTop, 28, accuracy: 0.5,
                       "and clear of the traffic-light zone, not hard against the frame")
        XCTAssertFalse(bands[0].isHidden, "the window still drags by the render's top edge")
        XCTAssertEqual(controller.previewHorizontalInset, controller.horizontalTextInset,
                       "the margins match, so the two bodies of text line up")

        controller.toggleZenMode()
        window.layoutIfNeeded()
        let strip = try XCTUnwrap(descendant(of: content, ofType: TabBarView.self))
        XCTAssertEqual(preview.convert(preview.bounds, to: content).maxY,
                       strip.convert(strip.bounds, to: content).minY, accuracy: 0.5,
                       "and back under the strip when the chrome returns")
        XCTAssertTrue(bands[0].isHidden)
    }

    /// Zen in reading mode is the render on its own — the chrome goes, the
    /// editor stays away, and the page is all that is left.
    @MainActor
    func testZenInReadingModeLeavesOnlyTheRender() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.setPreviewMode(.reading)

        controller.toggleZenMode()
        XCTAssertTrue(controller.previewState.isVisible, "the render is the note here, not chrome")
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, true)

        controller.toggleZenMode()
        XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        XCTAssertEqual(editorItem(of: controller)?.isCollapsed, true)
    }

    // MARK: - The mode control

    /// One control per column on screen: the editor's alone in the editor
    /// mode, both in split — each in its own column's top-trailing corner —
    /// and only the preview's in reading, where the editor column is gone.
    @MainActor
    func testEachColumnOnScreenCarriesItsOwnModeControl() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let (editorOverlay, previewOverlay) = controller.modeControlOverlays

        // Each lives in the column it belongs to, whatever the mode.
        let editorPaneView = try XCTUnwrap(editorItem(of: controller)?.viewController.view)
        let previewPaneView = try XCTUnwrap(previewItem(of: controller)?.viewController.view)
        XCTAssertTrue(editorOverlay.isDescendant(of: editorPaneView))
        XCTAssertTrue(previewOverlay.isDescendant(of: previewPaneView))

        window.layoutIfNeeded()
        XCTAssertFalse(editorOverlay.isHidden, "the editor mode: the text's own corner")
        XCTAssertTrue(previewOverlay.isHidden, "there is no render column to hold one")

        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertFalse(editorOverlay.isHidden, "split: one control in each column")
        XCTAssertFalse(previewOverlay.isHidden)
        let editorControl = editorOverlay.modeControl
        let previewControl = previewOverlay.modeControl
        XCTAssertLessThan(
            editorControl.convert(editorControl.bounds, to: content).maxX,
            previewControl.convert(previewControl.bounds, to: content).minX,
            "one per column, in the columns' own order"
        )

        controller.setPreviewMode(.reading)
        window.layoutIfNeeded()
        XCTAssertTrue(editorOverlay.isHidden, "reading: the editor column is collapsed")
        XCTAssertFalse(previewOverlay.isHidden)

        // Both drive the one mode the tab is in, so both show it.
        for overlay in [editorOverlay, previewOverlay] {
            XCTAssertEqual(overlay.modeControl.selectedSegment, 2)
        }
    }

    /// The control is only there while the pointer is near it: away by
    /// default, faded in on entering the band across the top of the column,
    /// and gone again on leaving.
    ///
    /// The pointer cannot be moved headlessly, so the tracking area's own
    /// handlers are called with synthetic enter and exit events — the same
    /// path a real hover takes once AppKit has done the geometry.
    @MainActor
    func testTheModeControlIsHiddenUntilThePointerIsNearIt() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()

        let overlay = controller.visibleModeControlOverlay
        XCTAssertFalse(overlay.isHidden, "the tab is a .md file, so it has one")
        XCTAssertFalse(overlay.isRevealed, "but not until the pointer comes near")
        XCTAssertEqual(overlay.modeControl.alphaValue, 0)

        // Hidden, it takes no clicks: the text under the band stays reachable.
        let control = overlay.modeControl.frame
        let onControl = overlay.convert(
            NSPoint(x: control.midX, y: control.midY), to: overlay.superview
        )
        XCTAssertNil(overlay.hitTest(onControl), "nothing to click while it is away")

        try hover(overlay, entering: true)
        XCTAssertTrue(overlay.isRevealed)
        XCTAssertEqual(overlay.modeControl.alphaValue, 1)
        XCTAssertEqual(overlay.hitTest(onControl), controller.previewModeControl)
        // Only the control answers; the rest of the band is still the text's.
        let besideControl = overlay.convert(
            NSPoint(x: control.minX - 40, y: control.midY), to: overlay.superview
        )
        XCTAssertNil(overlay.hitTest(besideControl))

        try hover(overlay, entering: false)
        XCTAssertFalse(overlay.isRevealed)
        XCTAssertEqual(overlay.modeControl.alphaValue, 0)

        // Top-trailing corner of the column, just under the strip.
        let strip = try XCTUnwrap(descendant(of: content, ofType: TabBarView.self))
        XCTAssertEqual(overlay.convert(overlay.bounds, to: content).maxY,
                       strip.convert(strip.bounds, to: content).minY, accuracy: 0.5)
        // A segmented control's frame is a little larger than the bezel it
        // draws, so the insets are the alignment rect's — the edges layout
        // and the eye both use.
        let bezel = overlay.modeControl.alignmentRect(forFrame: control)
        XCTAssertEqual(bezel.maxX, overlay.bounds.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(overlay.bounds.maxY - bezel.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.height, ModeControlOverlay.hoverBandHeight)

        // One layer: the control is the whole of it, with nothing behind it.
        XCTAssertEqual(overlay.subviews, [overlay.modeControl])
    }

    /// The ⇧⌘F field is in the strip and the control is under it, so the two
    /// have nothing to argue about.
    @MainActor
    func testTheSearchFieldAndTheModeControlNeverOverlap() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        controller.beginSearchAllNotes()
        window.layoutIfNeeded()

        let overlay = controller.visibleModeControlOverlay
        try hover(overlay, entering: true)
        let search = try XCTUnwrap(descendant(of: content, ofType: NSSearchField.self))
        XCTAssertFalse(search.isHidden)
        let control = overlay.modeControl.convert(overlay.modeControl.bounds, to: content)
        let field = search.convert(search.bounds, to: content)
        XCTAssertFalse(control.intersects(field))
        XCTAssertLessThanOrEqual(control.maxY, field.minY)
    }

    /// The rule is the file: a saved `.md` gets the control, and nothing else
    /// does — not a `.txt`, not `.markdown`, not an untitled note. ⇧⌘P and
    /// ⌥⇧⌘P do nothing where there is no control.
    @MainActor
    func testOnlyMarkdownTabsGetTheModeControl() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let directory = try makeTemporaryDirectory()
        let overlay = controller.modeControlOverlays.editor

        for (name, hasControl) in [("notes.md", true), ("NOTES.MD", true),
                                   ("notes.markdown", false), ("notes.txt", false)] {
            let url = directory.appendingPathComponent(name)
            try "text".write(to: url, atomically: true, encoding: .utf8)
            controller.open(url: url)
            window.layoutIfNeeded()

            XCTAssertEqual(overlay.isHidden, !hasControl, "\(name)")
            XCTAssertEqual(overlay.modeControl.isHidden, !hasControl, "\(name)")
            if !hasControl {
                try hover(overlay, entering: true)
                XCTAssertFalse(overlay.isRevealed, "\(name): hovering brings back nothing")
                controller.toggleMarkdownPreview()
                XCTAssertEqual(controller.previewMode, .off, "\(name): ⇧⌘P has nothing to do")
                controller.toggleReadingMode()
                XCTAssertEqual(controller.previewMode, .off, "\(name): nor has ⌥⇧⌘P")
            }
        }

        controller.newTab()
        window.layoutIfNeeded()
        XCTAssertTrue(overlay.isHidden, "an untitled note has no file to render yet")
    }

    /// ⌘S is where an untitled note gets its name — and where a `.txt` name
    /// takes its control away.
    @MainActor
    func testSavingUnderANonMarkdownNameTakesTheControlAway() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let overlay = controller.modeControlOverlays.editor
        XCTAssertFalse(overlay.isHidden, "the tab opens on a .md file")

        // `:w <path>` is the same write ⌘S does, without a panel to click.
        let url = try makeTemporaryDirectory().appendingPathComponent("notes.txt")
        XCTAssertTrue(controller.vimSave(name: url.path))
        window.layoutIfNeeded()
        XCTAssertTrue(overlay.isHidden, "a .txt has no mode control")
    }

    /// ⌘F's bar opens above the text, in the corner the editor's control
    /// floats over. The bar wins for as long as it is up — its own buttons
    /// have to stay clickable — and the preview's control is untouched.
    @MainActor
    func testTheFindBarTakesTheCornerFromTheModeControl() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        controller.setPreviewMode(.split)
        window.layoutIfNeeded()

        let (editorOverlay, previewOverlay) = controller.modeControlOverlays
        XCTAssertFalse(editorOverlay.isHidden)

        let editor = try editorTextView(of: controller)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scrollView.findBarPosition, .aboveContent)
        let showFind = NSMenuItem()
        showFind.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.performTextFinderAction(showFind)
        window.layoutIfNeeded()

        try XCTSkipUnless(scrollView.isFindBarVisible, "no find bar headlessly")
        XCTAssertTrue(editorOverlay.isHidden, "the control gets out of the bar's way")
        XCTAssertFalse(previewOverlay.isHidden, "the render's own corner is not the bar's")

        let hideFind = NSMenuItem()
        hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
        editor.performTextFinderAction(hideFind)
        window.layoutIfNeeded()
        XCTAssertFalse(editorOverlay.isHidden, "and comes back when the bar goes")
    }

    /// The selected segment is the tab's mode, and clicking one sets it.
    @MainActor
    func testTheModeControlTracksTheModeAndSetsIt() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let control = controller.previewModeControl
        XCTAssertEqual(control.selectedSegment, 0)

        controller.toggleMarkdownPreview()
        XCTAssertEqual(control.selectedSegment, 1, "⇧⌘P moves the control with it")
        controller.toggleMarkdownPreview()
        XCTAssertEqual(control.selectedSegment, 2)

        control.selectedSegment = 0
        control.performClick(nil)
        XCTAssertEqual(controller.previewMode, .off)
        XCTAssertTrue(window.firstResponder is JotTextView, "and the keys go back to the text")

        control.selectedSegment = 2
        control.performClick(nil)
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertFalse(window.firstResponder is JotTextView, "the render has the keys now")
    }

    /// It is chrome: it goes away with the tab strip in zen.
    @MainActor
    func testTheModeControlHidesWithTheTabStripInZen() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let strip = try XCTUnwrap(
            descendant(of: try XCTUnwrap(controller.window?.contentView), ofType: TabBarView.self)
        )

        controller.toggleZenMode()
        waitForDebounce()
        XCTAssertTrue(strip.isHidden)
        XCTAssertTrue(controller.previewModeControl.isHidden, "it goes with the strip")

        controller.toggleZenMode()
        XCTAssertFalse(controller.previewModeControl.isHidden, "and comes back with it")
    }

    // MARK: - Opening Markdown files

    /// The Settings switch is about Markdown, and about opening: a `.txt` is
    /// text, and a restored tab keeps whatever mode it was left in.
    @MainActor
    func testTheSettingOpensMarkdownFilesInReadingMode() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.opensMarkdownInReadingMode
        defer { Preferences.shared.opensMarkdownInReadingMode = previous }

        let directory = try makeTemporaryDirectory()
        let markdown = directory.appendingPathComponent("notes.md")
        let text = directory.appendingPathComponent("notes.txt")
        try "# Heading".write(to: markdown, atomically: true, encoding: .utf8)
        try "plain".write(to: text, atomically: true, encoding: .utf8)

        Preferences.shared.opensMarkdownInReadingMode = false
        let off = try makeController()
        off.open(url: markdown)
        XCTAssertEqual(off.previewMode, .off, "off by default: a file opens to be edited")

        Preferences.shared.opensMarkdownInReadingMode = true
        let on = try makeController()
        on.open(url: markdown)
        XCTAssertEqual(on.previewMode, .reading)
        XCTAssertEqual(editorItem(of: on)?.isCollapsed, true)

        on.open(url: text)
        XCTAssertEqual(on.previewMode, .off, "a .txt is not Markdown")

        on.newTab()
        XCTAssertEqual(on.previewMode, .off, "and ⌘T is not opening a file at all")
    }

    /// Session restore is not opening a file: the tab's own mode wins over
    /// the setting, however the file is spelled.
    @MainActor
    func testRestoringASessionIgnoresTheOpenInReadingModeSetting() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.opensMarkdownInReadingMode
        defer { Preferences.shared.opensMarkdownInReadingMode = previous }
        Preferences.shared.opensMarkdownInReadingMode = true

        let directory = try makeTemporaryDirectory()
        let markdown = try makeMarkdownFile(named: "notes.md")

        do {
            let controller = try makeController(in: directory)
            controller.open(url: markdown)
            XCTAssertEqual(controller.previewMode, .reading)
            controller.setPreviewMode(.off)
            controller.flushAll()
        }

        let relaunched = try makeController(in: directory)
        XCTAssertEqual(relaunched.previewMode, .off, "closed is how it was left")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController() throws -> MainWindowController {
        try makeController(in: try makeTemporaryDirectory())
    }

    /// The same window over a given cache dir — how a relaunch is played out.
    @MainActor
    private func makeController(in directory: URL) throws -> MainWindowController {
        let store = SessionStore(directory: directory)
        if store.load() == nil {
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
        }
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// The pane is the tab's, so a test that wants it open asks the tab in
    /// front for it — there is no preference to set any more.
    @MainActor
    private func makeControllerShowingPreview() throws -> MainWindowController {
        let controller = try makeController()
        controller.toggleMarkdownPreview()
        controller.window?.layoutIfNeeded()
        return controller
    }

    /// Long enough for the 150 ms render to have fired.
    @MainActor
    private func waitForDebounce() {
        let fired = expectation(description: "the preview re-rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
    }

    @MainActor
    private func splitViewController(
        of controller: MainWindowController
    ) throws -> NSSplitViewController {
        try XCTUnwrap(controller.window?.contentViewController as? NSSplitViewController)
    }

    @MainActor
    private func documentSplitViewController(
        of controller: MainWindowController
    ) throws -> NSSplitViewController {
        let outer = try splitViewController(of: controller)
        return try XCTUnwrap(
            outer.children.lazy
                .flatMap(\.children)
                .compactMap { $0 as? NSSplitViewController }
                .first
        )
    }

    /// The item holding the editor — the one reading mode collapses.
    @MainActor
    private func editorItem(of controller: MainWindowController) -> NSSplitViewItem? {
        try? documentSplitViewController(of: controller).splitViewItems.first {
            descendant(of: $0.viewController.view, ofType: JotTextView.self) != nil
        }
    }

    /// A second Markdown file to open in a tab of its own — ⌘T makes an
    /// untitled note, which has no render until it is saved.
    private func makeMarkdownFile(named name: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A real key press aimed at whatever the window has focused — how a
    /// keystroke reaches the render in reading mode.
    @MainActor
    private func type(
        _ characters: String, into controller: MainWindowController,
        modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let window = try XCTUnwrap(controller.window)
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0
        ))
        responder.keyDown(with: event)
    }

    /// A hover, the only way one can be had headlessly: the tracking area's
    /// own handler, called with the enter or exit event AppKit would have
    /// delivered once it had done the geometry.
    @MainActor
    private func hover(_ overlay: ModeControlOverlay, entering: Bool) throws {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: entering ? .mouseEntered : .mouseExited,
            location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        if entering {
            overlay.mouseEntered(with: event)
        } else {
            overlay.mouseExited(with: event)
        }
    }

    @MainActor
    private func previewItem(of controller: MainWindowController) -> NSSplitViewItem? {
        try? documentSplitViewController(of: controller).splitViewItems.first {
            descendant(of: $0.viewController.view, ofType: MarkdownPreviewView.self) != nil
        }
    }

    /// What the outer split holds, with the document workspace kept whole.
    @MainActor
    private func splitRoles(of controller: MainWindowController) throws -> [String] {
        try splitViewController(of: controller).splitViewItems.map { item in
            let view = item.viewController.view
            if descendant(of: view, ofType: ImageSidebarView.self) != nil { return "sidebar" }
            if descendant(of: view, ofType: JotTextView.self) != nil { return "workspace" }
            return "?"
        }
    }

    @MainActor
    private func editorTextView(of controller: MainWindowController) throws -> JotTextView {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: JotTextView.self))
    }

    @MainActor
    private func previewView(of controller: MainWindowController) throws -> MarkdownPreviewView {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: MarkdownPreviewView.self))
    }

    /// Clicks the pane where a piece of the rendered text is drawn, through a
    /// real mouse event, so the click travels the path a reader's does.
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

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: textView.convert(NSPoint(x: rect.minX + 2, y: rect.midY), to: nil),
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

    private func makeAssetStore() throws -> AssetStore {
        AssetStore(directory: try makeTemporaryDirectory().appendingPathComponent("assets"))
    }

    private func makePNG(width: Int, height: Int) -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JotPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
