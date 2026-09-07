import AppKit
import Foundation
import XCTest
@testable import Nota

final class MarkdownPreviewTests: AppKitTestCase {
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
        rendered.enumerateAttribute(.notaCodeBlock, in: whole) { value, range, _ in
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
        XCTAssertNil(try attributes(rendered, at: "render()")[.notaCodeBlock])
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

    /// GitHub's rule: a level-1 or level-2 heading is underlined across the
    /// pane, a level-3 is not. The rule is drawn, not spelled — the rendered
    /// text is the heading's words alone, so nothing a click maps back moves.
    func testALevelOneOrTwoHeadingCarriesTheRuleAttribute() throws {
        XCTAssertEqual(try attributes(render("# Title\n\ntext"), at: "Title")[.notaHeadingRule] as? Bool, true)
        XCTAssertEqual(try attributes(render("## Section\n\ntext"), at: "Section")[.notaHeadingRule] as? Bool, true)
        XCTAssertNil(try attributes(render("### Sub\n\ntext"), at: "Sub")[.notaHeadingRule])
        XCTAssertNil(try attributes(render("# Title\n\ntext"), at: "text")[.notaHeadingRule])
        XCTAssertEqual(render("# Title\n\ntext").string, "Title\ntext", "no character is added for it")
    }

    @MainActor
    func testThePaneDrawsAHairlineUnderALevelOneHeadingAcrossItsFullWidth() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        preview.layoutSubtreeIfNeeded()
        preview.show(result("# Title\n\nBody text.\n\n### Sub\n\nMore.", width: preview.contentWidth))

        let rules = preview.headingRuleRects
        XCTAssertEqual(rules.count, 1, "one rule, under the level-1 heading only")
        let rule = try XCTUnwrap(rules.first)
        let geometry = preview.textGeometry
        let origin = geometry.origin
        XCTAssertEqual(rule.minX, origin.x, accuracy: 0.5, "from the left margin")
        XCTAssertEqual(rule.maxX, geometry.bounds.width - origin.x, accuracy: 0.5, "to the right one")
        XCTAssertEqual(rule.height, 1)

        // Under the heading's line and above the body's.
        let layout = try XCTUnwrap(geometry.layoutManager)
        let title = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        let bodyStart = (geometry.string as NSString).range(of: "Body").location
        let body = layout.lineFragmentUsedRect(forGlyphAt: bodyStart, effectiveRange: nil)
        XCTAssertGreaterThan(rule.minY, title.maxY + origin.y)
        XCTAssertLessThan(rule.maxY, body.minY + origin.y)
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
            sources("before\n\n![](nota://x.png)\n\nafter"),
            ["before", "![](nota://x.png)", "after"]
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

        ![](nota://z.png)

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
            (rendered.text.attribute(.notaSourceRange, at: heading.location, effectiveRange: nil)
                as? NSValue)?.rangeValue,
            NSRange(location: 0, length: 7)
        )
        XCTAssertEqual(
            (rendered.text.attribute(.notaSourceRange, at: body.location, effectiveRange: nil)
                as? NSValue)?.rangeValue,
            NSRange(location: 9, length: 10)
        )
    }

    // MARK: - Images

    func testANotaTokenBecomesTheAssetsOwnPicture() throws {
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

    /// A note saved before the rename still holds `jot://` tokens, and the
    /// preview draws them exactly as it draws the new ones.
    func testALegacyJotTokenStillDrawsItsPicture() throws {
        let store = try makeAssetStore()
        let assetID = try XCTUnwrap(store.importImageData(
            makePNG(width: 200, height: 100), preferredExtension: "png"
        ))

        let rendered = render("![](jot://\(assetID))", assets: store, width: 400)
        let attachment = try XCTUnwrap(
            rendered.attribute(.attachment, at: 0, effectiveRange: nil)
                as? MarkdownImageAttachment
        )
        XCTAssertEqual(attachment.assetID, assetID)
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
        XCTAssertEqual(rendered.string, "nota://gone.png")
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
    /// ⌘P walks it round all three modes.
    @MainActor
    func testTheViewMenuTogglesThePaneForTheTabInFront() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        XCTAssertFalse(controller.previewState.isVisible, "the editor until asked for")
        XCTAssertEqual(controller.previewMode, .off, "and the checkmark is off with it")

        controller.toggleMarkdownPreview()
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .split)

        // Reading is the far end of the walk, and the render is still up.
        controller.toggleMarkdownPreview()
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .reading)

        // And back the way it came: split again, then the editor. The render
        // never goes from the whole window to gone in one press.
        controller.toggleMarkdownPreview()
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .split)
        controller.toggleMarkdownPreview()
        XCTAssertFalse(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewMode, .off)
    }

    /// ⌘P on one tab is about that tab. Opening the pane on a Markdown note
    /// must not follow you into the next one.
    @MainActor
    func testThePaneBelongsToTheTabItWasOpenedOn() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        XCTAssertTrue(controller.previewState.isVisible)

        controller.newTab()
        XCTAssertFalse(controller.previewState.isVisible, "a new tab opens without it")
        XCTAssertFalse(controller.showsMarkdownPreview)
        XCTAssertEqual(try previewWidth(of: controller), 0, "no render column on it")

        controller.selectTab(at: 0)
        XCTAssertTrue(controller.previewState.isVisible, "the first tab still wants it")
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)

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
        XCTAssertTrue(controller.canShowRenderedPreview)

        let directory = try makeTemporaryDirectory()
        let text = directory.appendingPathComponent("notes.txt")
        try "# Plain text".write(to: text, atomically: true, encoding: .utf8)
        controller.open(url: text)

        XCTAssertFalse(controller.canShowRenderedPreview)
        controller.toggleMarkdownPreview()
        XCTAssertFalse(controller.previewState.isVisible)
        XCTAssertFalse(controller.showsMarkdownPreview)

        let uppercase = directory.appendingPathComponent("notes.MD")
        try "# Markdown".write(to: uppercase, atomically: true, encoding: .utf8)
        controller.open(url: uppercase)
        XCTAssertTrue(controller.canShowRenderedPreview)
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
        XCTAssertGreaterThan(try previewWidth(of: relaunched), 0)
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

    /// The render's column is always there. In the editor mode it is closed
    /// to nothing — no width, no floor to grow back to, and no divider drawn
    /// against the window's edge — rather than taken out of the split, which
    /// is what keeps a mode change from ever being a rebuild.
    @MainActor
    func testAHiddenPaneIsClosedRatherThanRemoved() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let preview = try XCTUnwrap(previewItem(of: controller))
        XCTAssertEqual(try previewWidth(of: controller), 0, "closed to nothing")
        XCTAssertEqual(preview.minimumThickness, 0)
        XCTAssertEqual(preview.maximumThickness, 0, "and pinned there — no drag opens it")
        XCTAssertFalse(preview.canCollapse, "nothing about a mode collapses any more")
        XCTAssertFalse(try XCTUnwrap(editorItem(of: controller)).canCollapse)
        XCTAssertTrue(
            try documentDividerRect(of: controller).isEmpty,
            "and no divider answers the mouse against a column of no width"
        )
    }

    /// Toggling the pane must never resize the window. It used to: the pane
    /// asked the split view to grow for it, so opening it widened the window
    /// and closing it took that width off the editor — a zoomed window came
    /// back narrower than it went in.
    ///
    /// Nothing asks the split for a width any more, so the room comes off
    /// the editor and the frame is never in the conversation: the two columns
    /// add up to the width the window gave them, before and after.
    @MainActor
    func testTheEditorGivesUpTheRoomForThePaneRatherThanTheWindow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)

        let frame = NSRect(x: 120, y: 140, width: 1100, height: 620)
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        let editorAlone = try editorWidth(of: controller)
        XCTAssertGreaterThan(editorAlone, 0, "the columns have to be laid out")

        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame, "opening the pane neither moves nor resizes it")
        XCTAssertEqual(
            try editorWidth(of: controller) + previewWidth(of: controller),
            editorAlone, accuracy: 1,
            "the render's half came off the editor, not off the window"
        )
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)

        controller.setPreviewMode(.off)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame, "and closing it leaves the frame exactly as it was")
        XCTAssertEqual(
            try editorWidth(of: controller), editorAlone, accuracy: 1,
            "the editor has its whole column back"
        )
        XCTAssertEqual(try previewWidth(of: controller), 0)
    }

    /// A tab that comes back split gets its columns shared out against the
    /// split's own width — which means the split has to have one. The mode
    /// arrives with the session, before the window has ever been laid out,
    /// and the pane used to open on whatever room the editor's floor left it.
    @MainActor
    func testASplitRestoredWithTheSessionOpensOnHalfTheWindow() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("note.md")
        try "# Hello\n\nbody\n".write(to: file, atomically: true, encoding: .utf8)
        let id = UUID()
        SessionStore(directory: directory).save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil, isDirty: false,
                selection: 0, format: .default, previewMode: .split
            )],
            selectedTabID: id,
            fontSize: 13
        ))

        let controller = try makeController(in: directory)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()

        XCTAssertEqual(controller.previewMode, .split, "the tab came back split")
        XCTAssertEqual(
            try splitFraction(of: controller), 0.5, accuracy: 0.05,
            "and on half the window, not on what the editor's floor left over"
        )
    }

    /// ⌘P cycles through reading, where the preview holds the full column.
    /// Coming back into split must not reopen at that full width — that plus
    /// the editor's minimum is what used to grow the window past the screen,
    /// and each cycle compounded it.
    @MainActor
    func testCyclingThroughReadingDoesNotGrowTheWindow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)

        let frame = NSRect(x: 120, y: 140, width: 1100, height: 620)
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()

        func assertTheWindowHeld(in mode: PreviewMode) throws {
            XCTAssertEqual(
                window.frame.size, frame.size,
                "\(mode.rawValue): the window keeps the frame it had"
            )
            let content = try XCTUnwrap(window.contentView)
            let preview = try previewView(of: controller)
            let previewWidth = preview.convert(preview.bounds, to: content).width
            XCTAssertLessThanOrEqual(
                previewWidth, content.bounds.width + 1,
                "\(mode.rawValue): the preview stays inside the window"
            )
            if mode == .split {
                let split = try documentSplitViewController(of: controller).splitView
                let splitPreviewWidth = preview.convert(preview.bounds, to: split).width
                XCTAssertEqual(
                    splitPreviewWidth, split.bounds.width / 2, accuracy: 50,
                    "split is about half, not the full column reading left behind"
                )
                XCTAssertLessThan(
                    splitPreviewWidth, split.bounds.width - 40,
                    "and it is not the full window"
                )
            }
        }

        for mode in [PreviewMode.split, .reading, .off, .split] {
            controller.setPreviewMode(mode)
            window.layoutIfNeeded()
            try assertTheWindowHeld(in: mode)
        }

        for _ in 0 ..< 12 {
            controller.toggleMarkdownPreview()
            window.layoutIfNeeded()
            try assertTheWindowHeld(in: controller.previewMode)
        }
    }

    /// The mode you ask for slides. On a window somebody is actually looking
    /// at, ⌘P starts a 0.2s animation rather than snapping — and it is over
    /// by the time the run loop has turned for half a second.
    @MainActor
    func testAModeSwitchYouAskForSlides() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        try XCTSkipUnless(window.isVisible, "no window server here — nothing slides")

        controller.setPreviewMode(.split)
        XCTAssertTrue(controller.isSlidingPreviewMode, "⌘P slides the columns over")
        settle(0.5)
        XCTAssertFalse(controller.isSlidingPreviewMode, "and the slide finishes")

        // A tab switch is not a mode switch: it lays out for what is in
        // front of you rather than sliding in behind it.
        controller.newTab()
        window.layoutIfNeeded()
        XCTAssertFalse(controller.isSlidingPreviewMode, "an untitled tab simply appears")
    }

    /// The render freezes its own container width for the length of a slide
    /// (`RenderedPreviewView.freezeWidth()`) so it does not re-wrap on every
    /// frame the divider moves through; the editor plays the same trick with
    /// word wrap on, since its container is just as welded to its width.
    /// Frozen while the divider moves, wrapped once at the width it lands on.
    @MainActor
    func testEditorContainerIsFrozenDuringPreviewModeSlide() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = true

        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        try XCTSkipUnless(window.isVisible, "no window server here — nothing slides")

        let container = try XCTUnwrap(controller.editorScrolling.container)
        XCTAssertTrue(container.widthTracksTextView, "wrapping, before any slide")

        controller.setPreviewMode(.split)
        XCTAssertTrue(controller.isSlidingPreviewMode)
        XCTAssertFalse(
            container.widthTracksTextView,
            "held at the width it is leaving for the length of the slide"
        )

        settle(0.5)
        XCTAssertFalse(controller.isSlidingPreviewMode)
        XCTAssertTrue(container.widthTracksTextView, "thawed once the slide lands")
        // `container.size` only reports the width last written to it — once
        // tracking is back on, AppKit itself reads the text view's frame for
        // layout, which is the live number `editorScrolling.visibleWidth`
        // matches the same way `testWordWrapTogglesHorizontalScrolling` does.
        XCTAssertEqual(
            controller.editorScrolling.textView.frame.width,
            controller.editorScrolling.visibleWidth, accuracy: 1,
            "and wrapped once, to the width it landed at"
        )
    }

    /// Word wrap off leaves the container unbounded already — a slide has
    /// nothing to hold and nothing to disturb, so it is unaffected either way.
    @MainActor
    func testWordWrapOffIsUnaffectedByAPreviewModeSlide() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = false

        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        try XCTSkipUnless(window.isVisible, "no window server here — nothing slides")

        let container = try XCTUnwrap(controller.editorScrolling.container)
        XCTAssertFalse(container.widthTracksTextView, "not wrapping, before any slide")

        controller.setPreviewMode(.split)
        XCTAssertTrue(controller.isSlidingPreviewMode)
        XCTAssertFalse(container.widthTracksTextView, "still unbounded mid-slide")

        settle(0.5)
        XCTAssertFalse(controller.isSlidingPreviewMode)
        XCTAssertFalse(container.widthTracksTextView, "and after it lands")
    }

    /// An editor coming in from a collapsed column — reading mode gives it
    /// nothing — has no width worth holding, the same rule the render's own
    /// `freezeWidth()` applies: its first real width is the one it lands at.
    @MainActor
    func testEditorWithNoWidthYetIsNotFrozenByASlide() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = true

        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        try XCTSkipUnless(window.isVisible, "no window server here — nothing slides")

        controller.setPreviewMode(.reading)
        settle(0.5)
        XCTAssertFalse(controller.isSlidingPreviewMode)

        let container = try XCTUnwrap(controller.editorScrolling.container)
        XCTAssertLessThanOrEqual(container.size.width, 1, "the editor is collapsed to nothing")

        controller.setPreviewMode(.split)
        XCTAssertTrue(controller.isSlidingPreviewMode)
        XCTAssertTrue(
            container.widthTracksTextView,
            "nothing to hold coming in from collapsed, so tracking is left on"
        )

        settle(0.5)
        XCTAssertTrue(controller.editorScrolling.container?.widthTracksTextView ?? false)
    }

    /// ⌘P is a key people hold down. At any cadence — twenty taps inside
    /// one 0.2s slide, or taps spaced just under and just over it — the
    /// window comes out the size it went in, and split comes back at the
    /// divider it was left at rather than the full width reading gave the
    /// render.
    @MainActor
    func testSpammingTheModeCycleMovesNeitherTheWindowNorTheDivider() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 120, y: 140, width: 1100, height: 620), display: false)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()

        controller.setPreviewMode(.split)
        settle(0.5)
        let frame = window.frame
        let fraction = try splitFraction(of: controller)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.1, "split opens on about half")

        func assertNothingMoved(_ cadence: String) throws {
            XCTAssertEqual(
                window.frame.width, frame.width, accuracy: 0.5, "\(cadence): the width held"
            )
            XCTAssertEqual(
                window.frame.height, frame.height, accuracy: 0.5, "\(cadence): the height held"
            )
            XCTAssertEqual(
                window.frame.origin.x, frame.origin.x, accuracy: 0.5, "\(cadence): it stayed put"
            )
        }

        /// Cycles until split is in front again, then measures the divider.
        func returnToSplit(_ cadence: String) throws {
            while controller.previewMode != .split {
                controller.toggleMarkdownPreview()
                settle(0.3)
            }
            settle(0.5)
            try assertNothingMoved(cadence)
            XCTAssertEqual(
                try splitFraction(of: controller), fraction, accuracy: 0.03,
                "\(cadence): split came back at the divider it was left at"
            )
        }

        // Faster than the run loop can turn: twenty taps inside one slide.
        for _ in 0 ..< 20 { controller.toggleMarkdownPreview() }
        settle(0.5)
        try assertNothingMoved("twenty at once")
        try returnToSplit("twenty at once")

        // And with the loop turning between them — inside the 0.2s slide,
        // then just past it, which is where the divider used to drift.
        for pause in [0.05, 0.3] {
            for _ in 0 ..< 9 {
                controller.toggleMarkdownPreview()
                settle(pause)
            }
            settle(0.5)
            try assertNothingMoved("every \(Int(pause * 1000))ms")
            try returnToSplit("every \(Int(pause * 1000))ms")
        }
    }

    /// Reading gives the render the whole column. Coming back out into split
    /// it has to hand the editor its half back — at the fraction the divider
    /// was left at, not at the width reading had it.
    @MainActor
    func testReadingHandsTheDividerBackWhereItFoundIt() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 120, y: 140, width: 1100, height: 620), display: false)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()

        controller.setPreviewMode(.split)
        settle(0.5)

        // A divider nobody would land on by accident.
        let split = try documentSplitViewController(of: controller).splitView
        split.setPosition(split.bounds.width * 0.7, ofDividerAt: 0)
        window.layoutIfNeeded()
        let dragged = try splitFraction(of: controller)
        XCTAssertEqual(dragged, 0.3, accuracy: 0.05, "the drag took")
        let frame = window.frame

        for round in 1 ... 3 {
            controller.setPreviewMode(.reading)
            settle(0.4)
            XCTAssertEqual(
                try splitFraction(of: controller), 1, accuracy: 0.02,
                "round \(round): reading gives the render the whole column"
            )
            controller.setPreviewMode(.split)
            settle(0.4)
            XCTAssertEqual(
                try splitFraction(of: controller), dragged, accuracy: 0.03,
                "round \(round): and split comes back where it was dragged to"
            )
            XCTAssertEqual(
                window.frame.width, frame.width, accuracy: 0.5,
                "round \(round): the window keeps its frame"
            )
        }
    }

    /// ⌘P goes round: split → reading → off → split. The divider has to be
    /// where it was left when the cycle comes back to it — the whole way
    /// round, not only on the short hop out of reading. Going through the
    /// editor mode is the hard part: the preview is collapsed there, holding
    /// the full width reading gave it, and the pane used to reopen on its own
    /// 240pt floor instead of the half it was dragged to.
    @MainActor
    func testTheDividerSurvivesTheWholeModeCycle() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 100, y: 120, width: 1200, height: 700), display: false)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()

        controller.setPreviewMode(.split)
        settle(0.5)
        try setSplitFraction(0.5, of: controller)
        let frame = window.frame
        XCTAssertEqual(try splitFraction(of: controller), 0.5, accuracy: 0.02, "50/50 to start")

        for round in 1 ... 3 {
            // The whole lap, one ⌘P at a time: split is the middle and the
            // key moves on from wherever the tab came, so from split it goes
            // out to reading, back through split, out to the editor and back.
            for mode in [PreviewMode.reading, .split, .off, .split] {
                controller.toggleMarkdownPreview()
                settle(0.4)
                XCTAssertEqual(controller.previewMode, mode, "round \(round): the cycle's order")
            }
            XCTAssertEqual(
                try splitFraction(of: controller), 0.5, accuracy: 0.02,
                "round \(round): split came back at the divider, not at the pane's floor"
            )
            XCTAssertEqual(
                window.frame, frame, "round \(round): and the window kept its frame"
            )
        }

        // The share is a fraction, not a width: the window can change size
        // while the divider is put away and split still comes back at half.
        for (mode, width) in [(PreviewMode.off, 900.0), (.reading, 1400.0)] {
            controller.setPreviewMode(mode)
            settle(0.4)
            window.setFrame(
                NSRect(x: 100, y: 120, width: width, height: 700), display: false
            )
            window.layoutIfNeeded()
            settle(0.3)
            controller.setPreviewMode(.split)
            settle(0.4)
            XCTAssertEqual(
                try splitFraction(of: controller), 0.5, accuracy: 0.02,
                "still half a \(Int(width))pt window after a resize in \(mode.rawValue)"
            )
        }
    }

    /// Opening split pins the preview to the remembered share so it cannot
    /// ask for more room than the split has. The pin is a way of getting
    /// there, not a width to live at: once the columns have landed the
    /// preview is back to its own 240pt floor and no ceiling at all, and the
    /// divider moves through the whole range the editor's minimum leaves.
    @MainActor
    func testThePreviewDividerStaysDraggableInSplit() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 120, y: 140, width: 1100, height: 620), display: false)
        controller.setPreviewMode(.split)
        window.layoutIfNeeded()

        let split = try documentSplitViewController(of: controller).splitView
        let preview = try XCTUnwrap(previewItem(of: controller))
        let editor = try XCTUnwrap(editorItem(of: controller))
        XCTAssertGreaterThan(split.bounds.width, 1, "the split has to be laid out")
        XCTAssertEqual(preview.minimumThickness, 240, "the pin came off")
        XCTAssertEqual(
            preview.maximumThickness, NSSplitViewItem.unspecifiedDimension,
            "no ceiling of its own — the editor's floor is the far end of the drag"
        )

        // Drag it to where the editor hits its minimum, and back.
        split.setPosition(editor.minimumThickness, ofDividerAt: 0)
        window.layoutIfNeeded()
        XCTAssertEqual(
            preview.viewController.view.frame.width,
            split.bounds.width - editor.minimumThickness, accuracy: 2,
            "the preview grows until the editor hits its floor"
        )
        split.setPosition(split.bounds.width - preview.minimumThickness, ofDividerAt: 0)
        window.layoutIfNeeded()
        XCTAssertEqual(
            preview.viewController.view.frame.width, preview.minimumThickness, accuracy: 2,
            "and shrinks until it hits its own"
        )
    }

    /// The divider belongs to the reader in split and to nobody in the other
    /// two: the column that is away is pinned shut at both ends, so there is
    /// nothing to drag it out by and no divider drawn to drag.
    @MainActor
    func testTheDividerIsDraggableOnlyInSplit() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 120, y: 140, width: 1100, height: 620), display: false)
        window.layoutIfNeeded()
        let split = try documentSplitViewController(of: controller).splitView

        for mode in [PreviewMode.off, .reading] {
            controller.setPreviewMode(mode)
            window.layoutIfNeeded()
            let shut = try XCTUnwrap(
                mode == .off ? previewItem(of: controller) : editorItem(of: controller)
            )
            XCTAssertEqual(shut.minimumThickness, 0, "\(mode.rawValue): no floor")
            XCTAssertEqual(shut.maximumThickness, 0, "\(mode.rawValue): and no ceiling above it")
            XCTAssertEqual(
                shut.viewController.view.frame.width, 0,
                "\(mode.rawValue): the closed column is exactly nothing wide"
            )
            XCTAssertTrue(
                try documentDividerRect(of: controller).isEmpty,
                "\(mode.rawValue): and the divider answers nothing beside it"
            )

            // A drag right into the middle of the window changes nothing.
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
            window.layoutIfNeeded()
            XCTAssertEqual(
                shut.viewController.view.frame.width, 0,
                "\(mode.rawValue): the divider does not move for a drag"
            )
        }

        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertFalse(
            try documentDividerRect(of: controller).isEmpty,
            "split is the mode whose divider is the reader's to drag"
        )
    }

    /// The window frame is the one thing a mode change may never touch, and
    /// the case that used to touch it is the narrow one: two floors adding up
    /// to more than the window has is a window that grows to hold them, and a
    /// column pinned to a stale width is a window that shrinks onto it. Both
    /// ends of the range, all the way round the cycle, twice.
    @MainActor
    func testTheWindowKeepsItsFrameAtEveryWidthTheModesCycleAt() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let split = try documentSplitViewController(of: controller).splitView

        // 500pt is under the two floors together, 640pt is just over them,
        // and 1470x919 is the window a real screen gives you.
        for size in [
            NSSize(width: 500, height: 400),
            NSSize(width: 640, height: 400),
            NSSize(width: 1470, height: 919),
        ] {
            let frame = NSRect(origin: NSPoint(x: 60, y: 80), size: size)
            window.setFrame(frame, display: false)
            window.layoutIfNeeded()

            for _ in 0 ..< 6 {
                controller.toggleMarkdownPreview()
                window.layoutIfNeeded()
                let mode = controller.previewMode
                let where_ = "\(mode.rawValue) at \(Int(size.width))pt"
                XCTAssertEqual(window.frame, frame, "\(where_): the window is untouched")
                let room = split.bounds.width - split.dividerThickness
                XCTAssertEqual(
                    try editorWidth(of: controller) + previewWidth(of: controller),
                    room, accuracy: 1,
                    "\(where_): the columns fill the split and no more"
                )
                if mode == .split {
                    XCTAssertGreaterThan(
                        try editorWidth(of: controller), 0, "\(where_): both columns are there"
                    )
                    XCTAssertGreaterThan(try previewWidth(of: controller), 0, where_)
                }
            }
        }
    }

    /// The outer items are rebuilt when the sidebar changes sides. The
    /// document's two are not, so split is still split on the other side —
    /// at its floors, on about half the room, with the window untouched.
    @MainActor
    func testThePaneKeepsItsColumnsWhenTheSidebarChangesSides() throws {
        _ = NSApplication.shared
        let previousSide = Preferences.shared.sidebarSide
        defer { Preferences.shared.sidebarSide = previousSide }

        for side in [SidebarSide.right, .left] {
            Preferences.shared.sidebarSide = side
            let controller = try makeControllerShowingPreview()
            let frame = try XCTUnwrap(controller.window).frame
            let item = try XCTUnwrap(previewItem(of: controller))
            XCTAssertFalse(item.canCollapse, "on the \(side.title)")
            XCTAssertEqual(item.minimumThickness, 240)
            XCTAssertEqual(
                try splitFraction(of: controller), 0.5, accuracy: 0.05,
                "still about half on the \(side.title)"
            )
            XCTAssertEqual(
                try XCTUnwrap(controller.window).frame, frame,
                "and the window never moved for it"
            )
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
                if descendant(of: view, ofType: NotaTextView.self) != nil { return "editor" }
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
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)
        XCTAssertGreaterThan(try editorWidth(of: controller), 0, "both columns stay")
        XCTAssertEqual(preview.frame.width, width, accuracy: 0.5, "at the divider it was left at")

        // The controls over the two columns are chrome, and go with the rest.
        let (editorOverlay, previewOverlay) = controller.modeControlOverlays
        XCTAssertTrue(editorOverlay.isHidden)
        XCTAssertTrue(previewOverlay.isHidden)

        controller.toggleZenMode()
        window.layoutIfNeeded()
        XCTAssertTrue(controller.previewState.isVisible, "and nothing moved on the way out")
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)
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
            window.firstResponder is NotaTextView,
            "the pane is read, not typed in"
        )
        controller.setPreviewMode(.off)
        XCTAssertTrue(window.firstResponder is NotaTextView)
    }

    @MainActor
    func testTypingReRendersThePaneOnceTheKeystrokesStop() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: NotaTextView.self)
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
            descendant(of: try XCTUnwrap(window.contentView), ofType: NotaTextView.self)
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
            descendant(of: try XCTUnwrap(window.contentView), ofType: NotaTextView.self)
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

    /// Safari's pattern: a compact + at the trailing end of the strip, always
    /// there, opens a new tab the way ⌘T does.
    @MainActor
    func testTheTabStripCarriesANewTabButton() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let tabBar = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: TabBarView.self)
        )
        let plus = try XCTUnwrap(descendant(of: tabBar, ofType: NewTabButton.self))

        XCTAssertEqual(plus.accessibilityLabel(), "New Tab")
        XCTAssertEqual(plus.accessibilityRole(), .button)
        XCTAssertEqual(plus.toolTip, "New Tab  ⌘T")
        XCTAssertFalse(plus.isHidden)
        XCTAssertTrue(controller.canShowRenderedPreview, "the window opens on a saved .md")

        plus.performClick(nil)
        XCTAssertFalse(
            controller.canShowRenderedPreview,
            "the + opens an untitled note, which has no render until it is saved"
        )
        controller.selectTab(at: 0)
        XCTAssertTrue(controller.canShowRenderedPreview, "the original .md is still the first tab")
        controller.selectTab(at: 1)
        XCTAssertFalse(controller.canShowRenderedPreview, "and the new one is still the second")
    }

    /// When the strip is full the tabs shrink to fit; the + pins at the
    /// trailing end and is never covered.
    @MainActor
    func testTheNewTabButtonStaysVisibleWhenTabsOverflow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 80, y: 80, width: 520, height: 560), display: false)
        for _ in 0 ..< 12 { controller.newTab() }
        window.layoutIfNeeded()

        let tabBar = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: TabBarView.self)
        )
        tabBar.layoutSubtreeIfNeeded()
        let plus = try XCTUnwrap(descendant(of: tabBar, ofType: NewTabButton.self))

        XCTAssertFalse(plus.isHidden)
        XCTAssertGreaterThanOrEqual(plus.frame.minX, 0)
        XCTAssertLessThanOrEqual(plus.frame.maxX, tabBar.bounds.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(plus.frame.minY, 0)
        XCTAssertLessThanOrEqual(plus.frame.maxY, tabBar.bounds.maxY + 0.5)

        // The two bookmark buttons and the Settings gear are the things that
        // sit *past* the + by design (SPEC Todo 13); everything else in the
        // strip is a tab, and a tab stops short of it.
        for subview in tabBar.subviews
        where subview !== plus && !(subview is BookmarkToggleButton)
            && !(subview is BookmarksButton) && !(subview is SettingsButton)
            && !subview.isHidden {
            XCTAssertFalse(
                subview.frame.intersects(plus.frame),
                "a tab sits on the +"
            )
            XCTAssertLessThanOrEqual(subview.frame.maxX, plus.frame.minX + 0.5)
        }
    }

    /// `moveTab` is what a completed drag calls. The note itself moves, not
    /// just whatever was at that index; selection follows the note that was
    /// selected (the general case — a drag usually selects the tab it moves,
    /// since mouse-down already does that, but the model has to hold either
    /// way); ⌘1–9, ⌃Tab, `gt`/`gT` and `:tabn`/`:tabp` all index `notes`
    /// directly, so they pick up the new order for free; and the order
    /// survives a relaunch.
    @MainActor
    func testMovingATabReordersNotesKeepsSelectionAndPersists() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory) // tab 0: note.md
        controller.open(url: try makeMarkdownFile(named: "second.md")) // tab 1
        controller.open(url: try makeMarkdownFile(named: "third.md")) // tab 2
        controller.selectTab(at: 1) // "second.md" — not the tab about to move

        let window = try XCTUnwrap(controller.window)
        let tabBar = try XCTUnwrap(
            descendant(of: try XCTUnwrap(window.contentView), ofType: TabBarView.self)
        )
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabBar.titlesForTesting, ["note.md", "second.md", "third.md"])

        controller.moveTab(from: 0, to: 2)
        tabBar.layoutSubtreeIfNeeded()

        XCTAssertEqual(tabBar.titlesForTesting, ["second.md", "third.md", "note.md"],
                       "note.md moved, not just index 0's content")
        XCTAssertEqual(controller.selectedTabIndex, 0, "selection followed \"second.md\", now first")
        XCTAssertTrue(tabBar.isSelectedTabFullyVisible(), "the visibility rule holds after a drop too")

        // ⌘1–9 (selectTab(at:)), ⌃Tab/⌃⇧Tab and gt/gT/:tabn/:tabp all read
        // `notes` at the index they are given, so they already follow.
        controller.selectNextTab()
        XCTAssertEqual(controller.selectedTabIndex, 1, "next now means \"third.md\"")

        controller.flushAll()
        let persisted = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(
            persisted.tabs.map { ($0.path as NSString?)?.lastPathComponent },
            ["second.md", "third.md", "note.md"],
            "the reordered session survives a relaunch"
        )
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

    // MARK: - Copying maths out of the render

    /// A selection over both an inline and a display formula copies their
    /// `plainText` in place, not the U+FFFC each is an attachment underneath.
    @MainActor
    func testCopyingASelectionWithFormulasCarriesTheirPlainText() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        preview.layoutSubtreeIfNeeded()
        preview.show(result(
            "The value $x^2$ here and $$\\frac{a}{b}$$ done.", width: preview.contentWidth
        ))

        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        XCTAssertTrue(textView.string.contains("\u{FFFC}"), "the render itself still holds attachments")
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        let board = makePasteboard()
        XCTAssertTrue(textView.writeSelection(to: board, type: .string))
        let copied = try XCTUnwrap(board.string(forType: .string))

        XCTAssertEqual(copied, "The value x² here and a/b done.")
        XCTAssertFalse(copied.contains("\u{FFFC}"), "the formulas should read like words, not placeholders")
    }

    /// A selection with no maths in it is untouched — the same string a plain
    /// `NSTextView` would have copied.
    @MainActor
    func testCopyingASelectionWithNoMathsIsUntouched() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        preview.layoutSubtreeIfNeeded()
        preview.show(result("Just words, no math here.", width: preview.contentWidth))

        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        let board = makePasteboard()
        XCTAssertTrue(textView.writeSelection(to: board, type: .string))
        XCTAssertEqual(board.string(forType: .string), "Just words, no math here.")
    }

    private func makePasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("NotaMarkdownPreviewTests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    // MARK: - Block sync

    @MainActor
    func testClickingABlockSelectsItsSourceInTheEditor() throws {
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
        // "Second paragraph." starts at 27 in the source and is 17 long.
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 27, length: 17))

        try clickPreview(of: controller, on: "Title")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 7),
                       "the whole block, `# Title` and its hash: typing replaces what "
                           + "was clicked, and ⌘Z puts it back")
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
            window.firstResponder is NotaTextView,
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
    func testAPressThatDoesNotMoveIsStillTheBlockClick() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()

        try clickPreview(of: controller, on: "Second paragraph.")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 27, length: 17))

        let preview = try previewView(of: controller)
        let rendered = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        XCTAssertEqual(rendered.selectedRange().length, 0,
                       "a press that swept nothing selects nothing in the render")
        XCTAssertEqual(preview.highlightedSourceRange, NSRange(location: 27, length: 17),
                       "and the band lights under the block it landed in")
    }

    @MainActor
    func testDraggingAcrossTheRenderSelectsTextAndJumpsNowhere() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        let preview = try previewView(of: controller)
        let rendered = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let caret = editor.selectedRange()
        let band = preview.highlightedSourceRange

        try pressPreview(of: controller, on: "First paragraph.",
                         draggingTo: "Second paragraph.")

        let swept = rendered.selectedRange()
        XCTAssertGreaterThan(swept.length, 0, "the sweep selected the text it crossed")
        XCTAssertTrue(
            (rendered.string as NSString).substring(with: swept).hasPrefix("First paragraph."),
            "starting where the press went down"
        )
        XCTAssertEqual(editor.selectedRange(), caret, "a drag is a selection, not a jump")
        XCTAssertEqual(preview.highlightedSourceRange, band, "and the band is left as it was")
    }

    @MainActor
    func testADoubleClickInTheRenderTakesAWordRatherThanJumping() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        let preview = try previewView(of: controller)
        let rendered = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let caret = editor.selectedRange()

        try pressPreview(of: controller, on: "Second paragraph.", clickCount: 2)

        let word = rendered.selectedRange()
        XCTAssertEqual((rendered.string as NSString).substring(with: word), "Second")
        XCTAssertEqual(editor.selectedRange(), caret, "and it jumped nowhere")
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

    /// The band is split's. Reading is the page on its own — there is no
    /// caret on screen for it to be answering to — so whatever split left
    /// lit goes out on the way in.
    @MainActor
    func testEnteringReadingModePutsTheBandOut() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        let preview = try previewView(of: controller)

        editor.setSelectedRange(NSRange(location: 12, length: 0))
        XCTAssertNotNil(preview.highlightedSourceRange, "split lights the caret's block")

        controller.setPreviewMode(.reading)
        XCTAssertNil(preview.highlightedSourceRange, "and reading puts it out")
        XCTAssertNil(preview.highlightedBandRect, "nothing is drawn over the page")
    }

    /// And nothing lights one again while you are in there: the caret still
    /// moves — a restored session, a jump, the editor's own doing — but the
    /// page it is not on stays a page.
    @MainActor
    func testMovingTheCaretInReadingModeLightsNothing() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        let preview = try previewView(of: controller)
        controller.setPreviewMode(.reading)

        for location in [2, 12, 30] {
            editor.setSelectedRange(NSRange(location: location, length: 0))
            XCTAssertNil(
                preview.highlightedSourceRange,
                "the caret at \(location) lights nothing while the editor is away"
            )
        }
    }

    /// Coming back out, the two columns are a pair again and the band with
    /// them: it lights the block the caret was in all along.
    @MainActor
    func testLeavingReadingModeLightsTheCaretsBlockAgain() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        let preview = try previewView(of: controller)

        editor.setSelectedRange(NSRange(location: 12, length: 0))
        controller.setPreviewMode(.reading)
        XCTAssertNil(preview.highlightedSourceRange)

        controller.setPreviewMode(.split)
        XCTAssertEqual(
            preview.highlightedSourceRange, NSRange(location: 9, length: 16),
            "the caret never moved, and its block is lit again"
        )
    }

    // MARK: - Headings outline (Todo 9)

    /// `@` in the ⇧⌘J switcher lists the front tab's headings, in document
    /// order, in place of the tab list.
    @MainActor
    func testAtInThePickerListsTheFrontTabsHeadingsInOrder() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: """
        # Intro

        Some words.

        ## Second

        More words.

        ### Third
        """))
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        XCTAssertFalse(picker.isShowingHeadings, "opens on the tab list, same as ever")

        picker.query = "@"
        XCTAssertTrue(picker.isShowingHeadings)
        XCTAssertEqual(picker.visibleRowTexts, ["Intro", "Second", "Third"])
    }

    /// The rest of the query fuzzy-filters the headings the same way it
    /// fuzzy-filters tab titles.
    @MainActor
    func testAtIntroFiltersTheHeadings() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: "# Intro\n\n## Second\n\n### Third"))
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.query = "@intro"
        XCTAssertEqual(picker.visibleRowTexts, ["Intro"])

        picker.query = "@second"
        XCTAssertEqual(picker.visibleRowTexts, ["Second"])

        picker.query = "@zzz"
        XCTAssertTrue(picker.visibleRowTexts.isEmpty, "no heading matches")

        // Deleting the `@` back out returns to the tab list.
        picker.query = ""
        XCTAssertFalse(picker.isShowingHeadings)
    }

    /// Choosing a heading puts the caret at the start of its line, wherever
    /// in the note that is.
    @MainActor
    func testChoosingAHeadingMovesTheCaretToItsLine() throws {
        _ = NSApplication.shared
        let markdown = "# Intro\n\nSome words.\n\n## Second\n\nMore words."
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: markdown))
        let picker = controller.tabPickerPanel
        let expected = (markdown as NSString).range(of: "## Second").location

        controller.showTabPicker()
        picker.query = "@second"
        picker.chooseSelection()

        XCTAssertFalse(picker.isVisible, "choosing closes the panel")
        XCTAssertEqual(controller.currentTabState.selection, expected)
    }

    /// In split, choosing a heading also walks the render to that block —
    /// the same `highlightBlock(containingSource:)` a caret move already
    /// drives, called by hand since a picker's jump is not a keystroke.
    @MainActor
    func testChoosingAHeadingInSplitLightsTheRendersBlock() throws {
        _ = NSApplication.shared
        let markdown = "# Intro\n\nSome words.\n\n## Second\n\nMore words."
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: markdown))
        controller.setPreviewMode(.split)
        let preview = try previewView(of: controller)
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.query = "@second"
        picker.chooseSelection()

        XCTAssertEqual(
            preview.highlightedSourceRange,
            (markdown as NSString).range(of: "## Second"),
            "the block the heading's own line belongs to"
        )
    }

    /// A front tab that is not `.md` has no headings to offer.
    @MainActor
    func testAtOverATxtTabShowsNoHeadings() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let file = try makeTemporaryDirectory().appendingPathComponent("notes.txt")
        try "# Looks like a heading".write(to: file, atomically: true, encoding: .utf8)
        controller.open(url: file)
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.query = "@"
        XCTAssertTrue(picker.isShowingHeadings)
        XCTAssertTrue(picker.visibleRowTexts.isEmpty, "a .txt tab has no outline")
    }

    // MARK: - The switcher's Add new tab row and file-kind icons (Todo 15)

    /// ↑ from the first list row lands on the fixed "Add new tab" row above
    /// the field, and ↓ goes straight back to the list.
    @MainActor
    func testUpFromTheTopOfTheListSelectsTheAddNewTabRow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.newTab()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        XCTAssertFalse(picker.isTopRowSelected, "the list holds the selection to begin with")

        // The panel opens on the tab in front, which is the second of the
        // two: the first ↑ is still a move inside the list.
        picker.moveSelectionUp()
        XCTAssertFalse(picker.isTopRowSelected)

        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected, "↑ from the top row leaves the list")

        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected, "there is nothing above it")

        picker.moveSelectionDown()
        XCTAssertFalse(picker.isTopRowSelected, "back into the list")
    }

    /// Return on the row closes the panel and opens a tab, the same as ⌘T.
    @MainActor
    func testReturnOnTheAddNewTabRowOpensATab() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let before = controller.openNotes.count
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.moveSelectionUp()
        picker.chooseSelection()

        XCTAssertFalse(picker.isVisible, "choosing closes the panel")
        XCTAssertEqual(controller.openNotes.count, before + 1)
    }

    /// The row is above the field, not in the list, so `@` — which swaps the
    /// whole list for the outline — leaves it exactly where it was.
    @MainActor
    func testTheAddNewTabRowIsThereInHeadingsModeToo() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: "# Intro\n\n## Second"))
        let before = controller.openNotes.count
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.query = "@"
        XCTAssertTrue(picker.isShowingHeadings)

        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected)
        picker.chooseSelection()
        XCTAssertEqual(controller.openNotes.count, before + 1)
    }

    /// Typing is a return to the list: the query re-ranks it and the row
    /// above the field gives the selection back.
    @MainActor
    func testTypingTakesTheSelectionBackToTheList() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected)

        picker.query = "n"
        XCTAssertFalse(picker.isTopRowSelected)
    }

    /// With no tabs to move through at all, ↑ from the field still reaches
    /// the row — and ↓ has nowhere to put the selection, so it stays.
    @MainActor
    func testTheRowIsReachableWithAnEmptyList() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        picker.query = "zzzznothing"
        XCTAssertTrue(picker.visibleRowTexts.isEmpty)

        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected)
        picker.moveSelectionDown()
        XCTAssertTrue(picker.isTopRowSelected, "nothing below to move to")
    }

    /// The row above the field is drawn as a list row, not as something that
    /// only looks like one: its icon and its title stand at exactly the x the
    /// list's own rows do.
    @MainActor
    func testTheTopRowLinesUpWithTheListRows() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        defer { picker.hide() }

        let top = try XCTUnwrap(picker.topRowContentXForTesting)
        let list = try XCTUnwrap(picker.firstListRowContentXForTesting)
        XCTAssertEqual(top.icon, list.icon, accuracy: 0.5, "the icons stand at the same x")
        XCTAssertEqual(top.title, list.title, accuracy: 0.5, "and so do the titles")
    }

    /// The row is drawn, not merely reserved: the inset table style pads its
    /// content above the first row, so the one-row-tall window onto it has to
    /// be pinned to the row itself or the panel shows a blank strip.
    @MainActor
    func testTheTopRowActuallyDrawsItsRow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        defer { picker.hide() }
        settle(0.2)

        let cell = try XCTUnwrap(picker.topRowCellForTesting, "no row view was ever laid out")
        XCTAssertEqual(cell.text, "Add new tab")
        XCTAssertTrue(
            picker.topRowVisibleRectForTesting.contains(cell.frame),
            "\(cell.frame) is outside the \(picker.topRowVisibleRectForTesting) on show"
        )
    }

    /// ⌘P's row is the new-tab row it has always been — the bookmark wording
    /// belongs to the bookmarks panel alone.
    @MainActor
    func testTheTopRowReadsAddNewTabInTheSwitcher() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        defer { picker.hide() }

        XCTAssertEqual(picker.topRowText, "Add new tab")
        XCTAssertEqual(picker.topRowSymbol, "plus")

        picker.query = "@"
        XCTAssertEqual(picker.topRowText, "Add new tab", "the outline does not change it")
    }

    /// Every tab row carries its file's kind, and an untitled tab the plain
    /// `doc` that says it has no file yet.
    @MainActor
    func testPickerRowsCarryTheirFilesKindIcon() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: "# Intro"))
        controller.newTab()
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        let titles = picker.visibleRowTexts
        let symbols = picker.visibleRowSymbolNames
        XCTAssertEqual(symbols.count, titles.count)
        XCTAssertEqual(
            symbols,
            titles.map {
                $0.hasSuffix(".md")
                    ? FileKindIcon.symbolName(forTitle: $0)
                    : FileKindIcon.untitledSymbolName
            },
            "\(titles) drew \(symbols)"
        )
        XCTAssertTrue(
            symbols.contains(FileKindIcon.symbolName(forTitle: "x.md")),
            "the Markdown tab's own kind"
        )
        XCTAssertTrue(
            symbols.contains(FileKindIcon.untitledSymbolName),
            "the untitled tab has no file to have a kind"
        )
    }

    /// Headings keep the bare indented look they had — an outline is not a
    /// second list of files.
    @MainActor
    func testHeadingRowsShowNoIcon() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        controller.open(url: try markdownFile(contents: "# Intro\n\n## Second"))
        let picker = controller.tabPickerPanel

        controller.showTabPicker()
        XCTAssertFalse(picker.visibleRowSymbolNames.isEmpty)

        picker.query = "@"
        XCTAssertEqual(picker.visibleRowTexts, ["Intro", "Second"])
        XCTAssertTrue(picker.visibleRowSymbolNames.isEmpty)
    }

    // MARK: - Search all tabs

    /// ⇧⌘F is the same panel as ⌘P, in a mode of its own: no fixed row above
    /// the field, and nothing listed until something is typed.
    @MainActor
    func testSearchAllNotesOpensThePickerInSearchMode() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let picker = controller.tabPickerPanel
        defer { picker.hide() }

        controller.beginSearchAllNotes()

        XCTAssertTrue(picker.isVisible)
        XCTAssertTrue(picker.isShowingSearch)
        XCTAssertFalse(picker.isShowingHeadings)
        XCTAssertFalse(picker.isShowingBookmarks)
        XCTAssertTrue(picker.visibleRowTexts.isEmpty, "an empty query lists nothing")
        XCTAssertFalse(picker.topRowIsEnabled, "there is no fixed row to land on")

        // ↑ from the field therefore has nowhere to go.
        picker.moveSelectionUp()
        XCTAssertFalse(picker.isTopRowSelected)
    }

    /// Typing lists the hits from every open tab, each row the line the hit
    /// sits on under the tab it came from, with that tab's kind icon.
    @MainActor
    func testTypingListsMatchesFromEveryOpenTab() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let directory = try makeTemporaryDirectory()
        let alpha = directory.appendingPathComponent("alpha.md")
        try "first line\nneedle in alpha\n".write(to: alpha, atomically: true, encoding: .utf8)
        let beta = directory.appendingPathComponent("beta.md")
        try "another needle here\n".write(to: beta, atomically: true, encoding: .utf8)
        controller.open(url: alpha)
        controller.open(url: beta)

        let picker = controller.tabPickerPanel
        defer { picker.hide() }
        controller.beginSearchAllNotes()
        picker.query = "needle"

        XCTAssertEqual(picker.visibleRowTexts, ["needle in alpha", "another needle here"])
        XCTAssertEqual(picker.visibleSearchMatches.map(\.tabTitle), ["alpha.md", "beta.md"])
        XCTAssertEqual(picker.visibleSearchMatches.map(\.tabIndex), [1, 2])
        XCTAssertEqual(
            picker.visibleRowSymbolNames,
            [FileKindIcon.symbolName(forTitle: "alpha.md"),
             FileKindIcon.symbolName(forTitle: "beta.md")],
            "each row carries its own tab's kind icon"
        )

        // The bolded characters are the match itself, in the row's own text.
        for match in picker.visibleSearchMatches {
            XCTAssertEqual(
                (match.snippet as NSString).substring(with: match.rangeInSnippet).lowercased(),
                "needle"
            )
        }

        picker.query = "absent"
        XCTAssertTrue(picker.visibleRowTexts.isEmpty)
    }

    /// Return on a row switches to that tab, selects the match and leaves the
    /// query on the find pasteboard so ⌘G carries on from there.
    @MainActor
    func testReturnOnASearchRowSwitchesTabAndSelectsTheMatch() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let directory = try makeTemporaryDirectory()
        let alpha = directory.appendingPathComponent("alpha.md")
        try "nothing here\n".write(to: alpha, atomically: true, encoding: .utf8)
        let beta = directory.appendingPathComponent("beta.md")
        let text = "one\nthe needle line\n"
        try text.write(to: beta, atomically: true, encoding: .utf8)
        controller.open(url: alpha)
        controller.open(url: beta)
        controller.selectTab(at: 0)

        let picker = controller.tabPickerPanel
        controller.beginSearchAllNotes()
        picker.query = "needle"
        XCTAssertEqual(picker.visibleSearchMatches.count, 1)

        send(#selector(NSResponder.insertNewline(_:)), to: picker)

        XCTAssertFalse(picker.isVisible, "choosing closes the panel")
        XCTAssertEqual(controller.selectedTabIndex, 2, "the hit's tab came forward")
        XCTAssertEqual(
            controller.editorScrolling.textView.selectedRange(),
            (text as NSString).range(of: "needle"),
            "the match itself is selected"
        )
        XCTAssertEqual(NSPasteboard(name: .find).string(forType: .string), "needle")
    }

    /// ↓ walks the list, and Esc closes without choosing anything.
    @MainActor
    func testArrowsWalkTheSearchListAndEscCloses() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("hits.md")
        try "needle one\nneedle two\n".write(to: file, atomically: true, encoding: .utf8)
        controller.open(url: file)

        let picker = controller.tabPickerPanel
        controller.beginSearchAllNotes()
        picker.query = "needle"
        XCTAssertEqual(picker.visibleRowTexts, ["needle one", "needle two"])

        picker.moveSelectionDown()
        send(#selector(NSResponder.cancelOperation(_:)), to: picker)

        XCTAssertFalse(picker.isVisible, "Esc closes it")
        XCTAssertEqual(controller.selectedTabIndex, 1, "and chose nothing")
    }

    /// The key the panel's field would hand its delegate — the tests have no
    /// window server to press one with.
    @MainActor
    private func send(_ command: Selector, to picker: TabPickerPanel) {
        _ = picker.control(NSTextField(), textView: NSTextView(), doCommandBy: command)
    }

    // MARK: - Reading mode

    /// ⇧⌘P is the shortcut for the render on its own: straight to it from
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

    /// Reading closes the editor's column rather than the window: the render
    /// takes the column the text had, and the frame is the frame it was.
    @MainActor
    func testReadingModeClosesTheEditorColumnAndNeverTheWindow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)

        let frame = NSRect(x: 120, y: 140, width: 1100, height: 620)
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        let room = try editorWidth(of: controller)

        controller.setPreviewMode(.reading)
        window.layoutIfNeeded()
        XCTAssertEqual(try editorWidth(of: controller), 0, "the text is not on screen here")
        XCTAssertEqual(
            try previewWidth(of: controller), room, accuracy: 1,
            "the render has the whole column the editor had"
        )
        XCTAssertEqual(window.frame, frame, "going in neither moves nor resizes the window")

        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(
            try editorWidth(of: controller), 0, "and the editor is back beside the render"
        )
        XCTAssertEqual(window.frame, frame)

        controller.setPreviewMode(.off)
        window.layoutIfNeeded()
        XCTAssertEqual(try editorWidth(of: controller), room, accuracy: 1)
        XCTAssertEqual(try previewWidth(of: controller), 0)
        XCTAssertEqual(window.frame, frame, "and coming all the way out leaves it where it was")
    }

    /// The two columns are never both shut, not even for the instant a mode
    /// change takes — that would leave the window showing nothing.
    @MainActor
    func testSomethingIsAlwaysOnScreenAsTheModesChange() throws {
        _ = NSApplication.shared
        let controller = try makeController()

        for mode in [PreviewMode.reading, .off, .reading, .split, .off] {
            controller.setPreviewMode(mode)
            XCTAssertGreaterThan(
                try editorWidth(of: controller) + previewWidth(of: controller), 1,
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
            window.firstResponder is NotaTextView,
            "the editor is collapsed; it cannot be where the keys go"
        )

        controller.setPreviewMode(.split)
        XCTAssertTrue(window.firstResponder is NotaTextView, "the caret is back in the text")
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
        XCTAssertEqual(try editorWidth(of: controller), 0)
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
    /// fetching the editor back to search that. Nota's own bar opens over the
    /// page, in the corner the render's mode control floats in, and takes it
    /// while it is up.
    @MainActor
    func testCommandFInReadingModeSearchesTheRender() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()

        let editor = try editorTextView(of: controller)
        editor.insertText("alpha beta alpha", replacementRange: editor.selectedRange())
        waitForDebounce()

        controller.setPreviewMode(.reading)
        // On a window somebody can see, the mode slides in — ⌘F is asked for
        // once it has landed.
        settle(0.4)
        window.layoutIfNeeded()

        let preview = try previewView(of: controller)
        let rendered = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let bar = try XCTUnwrap(descendant(of: preview, ofType: FindBarView.self))
        XCTAssertTrue(bar.field.placeholderString?.isEmpty ?? true)
        XCTAssertFalse(bar.isShown)

        let find = NSMenuItem(title: "Find…", action: nil, keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        XCTAssertTrue(
            rendered.validateUserInterfaceItem(find),
            "the menu item has to stay enabled or ⌘F never arrives here"
        )
        rendered.performTextFinderAction(find)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.previewMode, .reading, "the search happens where you are")
        XCTAssertEqual(try editorWidth(of: controller), 0, "no editor came back")

        XCTAssertTrue(bar.isShown)
        XCTAssertTrue(preview.isFindBarVisible)

        // The render's control drops under the pill rather than leaving, and
        // the pill keeps every click inside its own frame: the overlay hands
        // back everything but the control it carries.
        let overlay = controller.modeControlOverlays.preview
        XCTAssertFalse(overlay.isHidden, "the control stays; it moves")
        XCTAssertEqual(overlay.findBarClearance, ModeControlOverlay.findBarDrop)
        let barFrame = bar.convert(bar.bounds, to: nil)
        let controlFrame = overlay.modeControl.convert(overlay.modeControl.bounds, to: nil)
        XCTAssertLessThanOrEqual(controlFrame.maxY, barFrame.minY)

        try hover(overlay, entering: true)
        XCTAssertEqual(overlay.modeControl.alphaValue, 1, accuracy: 0.01, "still one hover away")
        let column = try XCTUnwrap(overlay.superview)
        let host = try XCTUnwrap(column.superview)
        let inThePill = host.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), from: bar)
        XCTAssertTrue(
            column.hitTest(inThePill)?.isDescendant(of: bar) ?? false,
            "the pill answers for its own corner"
        )
        try hover(overlay, entering: false)

        // Typing searches the page itself, and the bands are the layout
        // manager's rather than anything written into the render.
        bar.query = "alpha"
        bar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: bar.field)
        )
        XCTAssertEqual(
            rendered.selectedRange(), NSRange(location: 0, length: 0),
            "a caret: the match is shown by its band, not by a selection"
        )
        XCTAssertEqual(rendered.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: 0, effectiveRange: nil
        ) as? NSColor, .findHighlightColor)
        XCTAssertEqual(bar.status, "1 of 2")
        XCTAssertNotNil(rendered.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: 12, effectiveRange: nil
        ))

        let hideFind = NSMenuItem()
        hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
        rendered.performTextFinderAction(hideFind)
        window.layoutIfNeeded()
        XCTAssertFalse(bar.isShown)
        XCTAssertNil(rendered.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: 12, effectiveRange: nil
        ))
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.findBarClearance, 0, "and comes back up when the bar goes")
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
        XCTAssertEqual(try editorWidth(of: controller), 0, "no editor came back")
        XCTAssertEqual(editor.selectedRange(), caret, "and the editor's caret never moved")
        XCTAssertEqual(preview.highlightedSourceRange, litBefore, "no band under the click")
        let pane = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let clicked = (pane.string as NSString).range(of: "Second paragraph.")
        XCTAssertEqual(
            pane.selectedRange(), NSRange(location: clicked.location, length: 0),
            "the caret went into the page you clicked, and nowhere else"
        )
    }

    /// In split the same click is a jump: the render is a map into the text
    /// beside it, and clicking a block selects that block in it.
    @MainActor
    func testClickingABlockInSplitSelectsIt() throws {
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
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 27, length: 17))
    }

    /// Split still gives up nothing to the click: the render itself is never
    /// where a caret lands, only where the jump comes from. The press now
    /// runs through `NSTextView`'s own tracking so that a drag can select
    /// (2026-09-07), and the caret that loop leaves behind is put back.
    @MainActor
    func testClickingABlockInSplitLeavesThePaneUnselected() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()

        try clickPreview(of: controller, on: "Second paragraph.")

        XCTAssertEqual(controller.previewMode, .split, "the block click still fired")
        let preview = try previewView(of: controller)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0),
                       "no text was swept, so the render holds none")
        XCTAssertFalse(textView.acceptsFirstResponder, "and the keyboard never came here")
        XCTAssertTrue(
            controller.window?.firstResponder is NotaTextView,
            "it is still the editor's"
        )
    }

    /// Reading gives up nothing a plain read-only text view has: a click
    /// places the caret in the render itself, the way it would in any
    /// selectable text view, so a drag after it can select and ⌘C can copy.
    @MainActor
    func testClickingInReadingModeSelectsInThePane() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let editor = try editorTextView(of: controller)
        editor.insertText(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.",
            replacementRange: editor.selectedRange()
        )
        waitForDebounce()
        controller.setPreviewMode(.reading)

        try clickPreview(of: controller, on: "Second paragraph.")

        let preview = try previewView(of: controller)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let clicked = (textView.string as NSString).range(of: "Second paragraph.")
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: clicked.location, length: 0),
            "a click places the caret; it does not select on its own"
        )
        XCTAssertEqual(controller.previewMode, .reading, "and the page is where you still are")
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
        XCTAssertEqual(try editorWidth(of: controller), 0)
        XCTAssertEqual(controller.previewModeControl.selectedSegment, 2)

        controller.selectTab(at: 0)
        XCTAssertEqual(controller.previewMode, .split)
        XCTAssertGreaterThan(try editorWidth(of: controller), 0)
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)
        XCTAssertEqual(controller.previewModeControl.selectedSegment, 1)

        controller.selectTab(at: 2)
        XCTAssertEqual(try previewWidth(of: controller), 0)
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
        XCTAssertEqual(try editorWidth(of: relaunched), 0)
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
    /// edge is the window's own. It runs right up to it, as the editor
    /// beside it does — nothing is held back for the traffic lights, which
    /// zen takes away — and it gets a thin drag band of its own over its
    /// padding so the window can still be moved by that edge.
    @MainActor
    func testZenGivesTheRenderColumnTheSameTopBandAsTheEditor() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let pane = try XCTUnwrap(previewItem(of: controller)?.viewController.view)
        window.layoutIfNeeded()

        // 12pt is the drag band; nothing else in the column is that short.
        let bands = pane.subviews.filter {
            abs($0.frame.height - 12) < 0.5 && $0.mouseDownCanMoveWindow
        }
        XCTAssertEqual(bands.count, 1, "one drag band over the render column")
        let band = try XCTUnwrap(bands.first)
        XCTAssertTrue(band.isHidden, "away while there is a tab strip to drag by")

        controller.toggleZenMode()
        window.layoutIfNeeded()

        let editorScroll = try XCTUnwrap(try editorTextView(of: controller).enclosingScrollView)
        let preview = try previewView(of: controller)
        let editorTop = editorScroll.convert(editorScroll.bounds, to: content).maxY
        let previewTop = preview.convert(preview.bounds, to: content).maxY
        XCTAssertEqual(previewTop, editorTop, accuracy: 0.5,
                       "both columns start on the same line in zen")
        XCTAssertEqual(content.bounds.maxY - previewTop, 0, accuracy: 0.5,
                       "hard against the frame: the document takes the whole window")
        XCTAssertFalse(band.isHidden, "the window still drags by the render's top edge")
        XCTAssertEqual(controller.previewHorizontalInset, controller.horizontalTextInset,
                       "the margins match, so the two bodies of text line up")

        controller.toggleZenMode()
        window.layoutIfNeeded()
        let strip = try XCTUnwrap(descendant(of: content, ofType: TabBarView.self))
        XCTAssertEqual(preview.convert(preview.bounds, to: content).maxY,
                       strip.convert(strip.bounds, to: content).minY, accuracy: 0.5,
                       "and back under the strip when the chrome returns")
        XCTAssertTrue(band.isHidden)
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
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)
        XCTAssertEqual(try editorWidth(of: controller), 0)

        controller.toggleZenMode()
        XCTAssertGreaterThan(try previewWidth(of: controller), 0)
        XCTAssertEqual(try editorWidth(of: controller), 0)
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

        // One layer: the capsule is the whole of what stands in the slot,
        // with no plate behind it and nothing beside it. A file with an
        // action of its own grows the same control by a segment.
        XCTAssertEqual(overlay.subviews, [overlay.modeControl])
        XCTAssertEqual(overlay.modeControl.segmentCount, 3, "not over a Markdown tab")
    }

    /// The unselected segments' bezel is drawn with some translucency, so
    /// without an opaque fill directly behind it the text under the band
    /// would show through the control. The fill is a layer, not a subview —
    /// the view hierarchy above stays just the control — sized to the
    /// bezel's own alignment rect, in the editor's background colour, and
    /// faded in step with the control.
    @MainActor
    func testTheModeControlHasAnOpaqueFillBehindItsBezel() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let overlay = controller.visibleModeControlOverlay
        try hover(overlay, entering: true)
        window.layoutIfNeeded()

        guard let overlayLayer = overlay.layer else {
            XCTFail("the overlay needs a layer to host the fill")
            return
        }
        let fill = try XCTUnwrap(
            overlayLayer.sublayers?.first { $0 !== overlay.modeControl.layer },
            "a fill layer behind the control"
        )
        XCTAssertEqual(
            fill.backgroundColor, NSColor.textBackgroundColor.cgColor,
            "the editor's own background, so it reads as filled rather than as a shape of its own"
        )
        let bezel = overlay.modeControl.alignmentRect(forFrame: overlay.modeControl.frame)
        XCTAssertEqual(fill.frame, bezel, "no padding: it fills exactly behind the bezel")
        XCTAssertGreaterThanOrEqual(fill.cornerRadius, 5)
        XCTAssertLessThanOrEqual(fill.cornerRadius, 6)
        XCTAssertEqual(fill.opacity, 1, "revealed together with the control")

        try hover(overlay, entering: false)
        XCTAssertEqual(fill.opacity, 0, "and gone again together with it")
    }

    /// The fill is stored as a concrete CGColor, so it must be resolved again
    /// in the overlay's own appearance when the Mac switches light or dark.
    @MainActor
    func testTheModeControlFillFollowsItsEffectiveAppearance() throws {
        _ = NSApplication.shared
        let overlay = ModeControlOverlay(target: nil, action: #selector(NSObject.description))
        let fill = try XCTUnwrap(overlay.layer?.sublayers?.first)

        overlay.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        overlay.viewDidChangeEffectiveAppearance()
        let light = try XCTUnwrap(fill.backgroundColor)

        overlay.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        overlay.viewDidChangeEffectiveAppearance()
        let dark = try XCTUnwrap(fill.backgroundColor)

        XCTAssertNotEqual(light, dark, "the fill must not keep the light-mode colour")
    }

    /// The rule is the file: a saved `.md` gets the control, and nothing else
    /// does — not a `.txt`, not an untitled note; `.markdown` is a spelling of
    /// `.md` and gets it too. ⌘P and ⇧⌘P do nothing where there is no control.
    @MainActor
    func testOnlyMarkdownTabsGetTheModeControl() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let directory = try makeTemporaryDirectory()
        let overlay = controller.modeControlOverlays.editor

        for (name, hasControl) in [("notes.md", true), ("NOTES.MD", true),
                                   ("notes.markdown", true), ("notes.txt", false)] {
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
                XCTAssertEqual(controller.previewMode, .off, "\(name): ⌘P has nothing to do")
                controller.toggleReadingMode()
                XCTAssertEqual(controller.previewMode, .off, "\(name): nor has ⇧⌘P")
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

    /// ⌘F's pill floats in the corner the editor's control floats in, over
    /// the text rather than in a row above it. The control does not leave for
    /// it: it drops the height of the pill and goes on working underneath,
    /// so the mode stays one hover away while a search is up. The preview's
    /// control is untouched.
    @MainActor
    func testTheModeControlDropsBelowTheFindBar() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        controller.setPreviewMode(.split)
        settle(0.4)
        window.layoutIfNeeded()

        let (editorOverlay, previewOverlay) = controller.modeControlOverlays
        XCTAssertFalse(editorOverlay.isHidden)
        XCTAssertEqual(editorOverlay.findBarClearance, 0)
        let restingControl = editorOverlay.modeControl.frame
        let restingBand = editorOverlay.frame.height

        let editor = try editorTextView(of: controller)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let column = try XCTUnwrap(scrollView.superview)
        let bar = try XCTUnwrap(descendant(of: column, ofType: FindBarView.self))
        let textFrame = scrollView.frame

        let showFind = NSMenuItem()
        showFind.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.performTextFinderAction(showFind)
        window.layoutIfNeeded()

        XCTAssertTrue(bar.isShown)
        XCTAssertFalse(editorOverlay.isHidden, "the control stays; it moves")
        XCTAssertEqual(editorOverlay.findBarClearance, ModeControlOverlay.findBarDrop)
        XCTAssertEqual(previewOverlay.findBarClearance, 0, "the render's corner is not the bar's")

        // Nothing is pushed down for the pill: the text keeps the frame it
        // had, the pill takes the corner, and the control is below it.
        XCTAssertEqual(scrollView.frame, textFrame, "the bar floats; the text does not move")
        XCTAssertEqual(
            bar.frame.maxY, scrollView.frame.maxY - ModeControlOverlay.controlTopInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            bar.frame.maxX, column.bounds.width - ModeControlOverlay.controlInset, accuracy: 0.5
        )
        let barFrame = bar.convert(bar.bounds, to: nil)
        let controlFrame = editorOverlay.modeControl.convert(
            editorOverlay.modeControl.bounds, to: nil
        )
        XCTAssertLessThanOrEqual(
            controlFrame.maxY, barFrame.minY, "the control sits under the pill, not behind it"
        )
        XCTAssertEqual(
            editorOverlay.frame.height, restingBand + ModeControlOverlay.findBarDrop,
            accuracy: 0.5, "and the hover band grew with it"
        )

        // The whole point of moving rather than leaving: it still comes up.
        try hover(editorOverlay, entering: true)
        XCTAssertEqual(editorOverlay.modeControl.alphaValue, 1, accuracy: 0.01)
        try hover(editorOverlay, entering: false)

        let hideFind = NSMenuItem()
        hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
        editor.performTextFinderAction(hideFind)
        window.layoutIfNeeded()
        XCTAssertEqual(editorOverlay.findBarClearance, 0)
        XCTAssertEqual(
            editorOverlay.modeControl.frame, restingControl, "and comes back up to the corner"
        )
    }

    /// Clicking the glass fades a second pill in under the first, 6pt below
    /// it and sharing its trailing edge, and the control under the stack drops
    /// by that pill's height rather than being covered. Clicking again takes
    /// it away and the control comes back up behind it.
    @MainActor
    func testTheMagnifierBringsOutTheReplacePillAndTheControlDropsFurther() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        controller.setPreviewMode(.split)
        settle(0.4)
        window.layoutIfNeeded()

        let (editorOverlay, _) = controller.modeControlOverlays
        let editor = try editorTextView(of: controller)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let column = try XCTUnwrap(scrollView.superview)
        let bar = try XCTUnwrap(descendant(of: column, ofType: FindBarView.self))

        let showFind = NSMenuItem()
        showFind.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.performTextFinderAction(showFind)
        window.layoutIfNeeded()
        XCTAssertFalse(bar.isExpanded, "⌘F opens the query pill alone")
        XCTAssertFalse(bar.replacePill.isShown)
        XCTAssertEqual(editorOverlay.findBarClearance, ModeControlOverlay.findBarDrop)
        let textFrame = scrollView.frame
        let queryFrame = bar.frame

        bar.findWord.performClick(nil)
        window.layoutIfNeeded()

        XCTAssertTrue(bar.isExpanded)
        XCTAssertTrue(bar.replacePill.isShown)
        XCTAssertEqual(bar.frame, queryFrame, "the query pill neither grows nor moves")
        XCTAssertEqual(bar.replacePill.frame.width, bar.frame.width)
        XCTAssertEqual(bar.replacePill.frame.maxX, bar.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(
            bar.frame.minY - bar.replacePill.frame.maxY, PillView.gap, accuracy: 0.5,
            "6pt under the first"
        )
        XCTAssertEqual(
            bar.stackHeight, PillView.height + PillView.gap + PillView.height
        )
        XCTAssertEqual(
            editorOverlay.findBarClearance,
            ModeControlOverlay.drop(forFindBarOfHeight: bar.stackHeight)
        )
        XCTAssertEqual(scrollView.frame, textFrame, "a second pill still pushes nothing down")
        let stackFrame = bar.replacePill.convert(bar.replacePill.bounds, to: nil)
        let controlFrame = editorOverlay.modeControl.convert(
            editorOverlay.modeControl.bounds, to: nil
        )
        XCTAssertLessThanOrEqual(
            controlFrame.maxY, stackFrame.minY, "still clear of the whole stack"
        )

        bar.findWord.performClick(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(bar.isExpanded)
        XCTAssertFalse(bar.replacePill.isShown)
        XCTAssertEqual(editorOverlay.findBarClearance, ModeControlOverlay.findBarDrop)
    }

    /// There is nothing to replace on a page you are reading: ⌘R there is
    /// ⌘F, and the glass is only a glass.
    @MainActor
    func testTheRenderedPageHasNoReplacePill() throws {
        _ = NSApplication.shared
        let controller = try makeControllerShowingPreview()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        controller.setPreviewMode(.reading)
        settle(0.4)
        window.layoutIfNeeded()

        let preview = try previewView(of: controller)
        let rendered = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let bar = try XCTUnwrap(descendant(of: preview, ofType: FindBarView.self))

        let showReplace = NSMenuItem()
        showReplace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        rendered.performTextFinderAction(showReplace)
        window.layoutIfNeeded()

        XCTAssertTrue(bar.isShown, "⌘R over the page is ⌘F")
        XCTAssertFalse(bar.canReplace)
        XCTAssertFalse(bar.isExpanded)
        XCTAssertFalse(bar.replacePill.isShown)
        XCTAssertEqual(bar.stackHeight, PillView.height)

        bar.findWord.performClick(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(bar.isExpanded, "the word is only a word here")
        XCTAssertFalse(bar.replacePill.isShown)
        XCTAssertEqual(
            controller.modeControlOverlays.preview.findBarClearance,
            ModeControlOverlay.findBarDrop
        )
    }

    /// ⌘J's pill takes the same corner, and the mode control drops below it
    /// exactly as it does for ⌘F's.
    @MainActor
    func testTheModeControlDropsForTheGoToLinePill() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        controller.setPreviewMode(.split)
        settle(0.4)
        window.layoutIfNeeded()

        let (editorOverlay, _) = controller.modeControlOverlays
        let editor = try editorTextView(of: controller)
        let column = try XCTUnwrap(editor.enclosingScrollView?.superview)
        let pill = try XCTUnwrap(descendant(of: column, ofType: GoToLinePill.self))
        XCTAssertEqual(editorOverlay.findBarClearance, 0)

        controller.showGoToLine()
        window.layoutIfNeeded()
        XCTAssertTrue(pill.isShown)
        XCTAssertFalse(editorOverlay.isHidden, "the control stays; it moves")
        XCTAssertEqual(editorOverlay.findBarClearance, ModeControlOverlay.findBarDrop)
        let pillFrame = pill.convert(pill.bounds, to: nil)
        let controlFrame = editorOverlay.modeControl.convert(
            editorOverlay.modeControl.bounds, to: nil
        )
        XCTAssertLessThanOrEqual(controlFrame.maxY, pillFrame.minY)

        // Return closes it and the corner is the control's again.
        let fieldEditor = try XCTUnwrap(pill.field.currentEditor() as? NSTextView)
        _ = pill.control(
            pill.field, textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        window.layoutIfNeeded()
        XCTAssertEqual(editorOverlay.findBarClearance, 0)
    }

    /// Reading mode has no editor on screen to jump about in, so ⌘J is not
    /// offered there and does nothing if it is asked for anyway.
    @MainActor
    func testReadingModeIgnoresGoToLine() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        XCTAssertTrue(controller.canGoToLine, "the editor is on screen here")

        controller.setPreviewMode(.reading)
        settle(0.4)
        window.layoutIfNeeded()
        XCTAssertFalse(controller.canGoToLine)

        let editor = try editorTextView(of: controller)
        let column = try XCTUnwrap(editor.enclosingScrollView?.superview)
        let pill = try XCTUnwrap(descendant(of: column, ofType: GoToLinePill.self))
        controller.showGoToLine()
        window.layoutIfNeeded()
        XCTAssertFalse(pill.isShown)
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
        XCTAssertEqual(control.selectedSegment, 1, "⌘P moves the control with it")
        controller.toggleMarkdownPreview()
        XCTAssertEqual(control.selectedSegment, 2)

        control.selectedSegment = 0
        control.performClick(nil)
        XCTAssertEqual(controller.previewMode, .off)
        XCTAssertTrue(window.firstResponder is NotaTextView, "and the keys go back to the text")

        control.selectedSegment = 2
        control.performClick(nil)
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertFalse(window.firstResponder is NotaTextView, "the render has the keys now")
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
        XCTAssertEqual(try editorWidth(of: on), 0)

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

    // MARK: - The contents column's hover

    /// A row used to track the pointer itself, and kept its wash after the
    /// list scrolled under a still pointer: every row that passed under it
    /// was "entered" and none was ever "exited". The column owns the pointer
    /// now, so after a scroll exactly the row under it is washed, and none
    /// once the pointer leaves.
    @MainActor
    func testScrollingUnderAStillPointerWashesOnlyTheRowUnderIt() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let sidebar = ContentsSidebarView(topInset: 8)
        sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        window.contentView?.addSubview(sidebar)
        sidebar.setEntries((1 ... 12).map { ContentsEntry(level: 1, title: "Row \($0)", line: $0) })
        window.makeKeyAndOrderFrontOffscreen()
        sidebar.layoutSubtreeIfNeeded()

        let pointer = sidebar.rowCentreInWindowForTesting(1)
        sidebar.hoverForTesting(at: pointer)
        XCTAssertEqual(sidebar.hoveredRowTitles, ["Row 2"])

        // Three rows scroll by under the pointer, which does not move.
        sidebar.scrollForTesting(toTop: ContentsSidebarView.rowHeight * 3)
        XCTAssertEqual(sidebar.hoveredRowTitles, ["Row 5"], "the row under the pointer now, and only it")

        sidebar.hoverForTesting(at: nil)
        XCTAssertEqual(sidebar.hoveredRowTitles, [])
    }

    // MARK: - The gallery's own title

    /// Every list in the sidebar column stands under one word saying what it
    /// is listing, in the shape Finder gives its own sections, at the top of
    /// the column rather than in the list — so it is still there when the
    /// list has been scrolled, and still there when there is no list.
    @MainActor
    func testTheGalleryStandsUnderItsOwnTitle() throws {
        let sidebar = ImageSidebarView(topInset: 8)

        sidebar.setAssetIDs(["a.png", "b.png"])
        XCTAssertEqual(sidebar.headerTitle, "Images")
        XCTAssertEqual(sidebar.headerCount, 2, "the badge after the title counts the pictures")

        sidebar.setAssetIDs([])
        XCTAssertEqual(sidebar.headerTitle, "Images", "the column still says what it is for")
        XCTAssertEqual(sidebar.headerCount, 0, "and the badge reads 0 rather than going away")
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

    /// Turns the run loop for a while. A 0.2s slide only advances when the
    /// loop does, so this is how a test waits one out.
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Puts the divider where a drag would have left it, as a share of the
    /// room the two columns have between them.
    @MainActor
    private func setSplitFraction(
        _ fraction: CGFloat, of controller: MainWindowController
    ) throws {
        let split = try documentSplitViewController(of: controller).splitView
        let room = split.bounds.width - split.dividerThickness
        XCTAssertGreaterThan(room, 1, "the split has to be laid out")
        split.setPosition(room * (1 - fraction), ofDividerAt: 0)
        controller.window?.layoutIfNeeded()
    }

    /// The area the document split's divider answers the mouse in. A column
    /// closed to nothing leaves none of it: no drag, and no resize cursor
    /// over the text beside it.
    @MainActor
    private func documentDividerRect(of controller: MainWindowController) throws -> NSRect {
        let document = try documentSplitViewController(of: controller)
        let split = document.splitView
        let drawn = NSRect(
            x: split.subviews.first?.frame.width ?? 0, y: 0,
            width: split.dividerThickness, height: split.bounds.height
        )
        return document.splitView(
            split, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0
        )
    }

    /// A column's width inside the document split. A mode that has closed a
    /// column closes it to exactly nothing — there is no collapsed item to
    /// ask any more, only a column of no width.
    @MainActor
    private func editorWidth(of controller: MainWindowController) throws -> CGFloat {
        try XCTUnwrap(editorItem(of: controller)).viewController.view.frame.width
    }

    @MainActor
    private func previewWidth(of controller: MainWindowController) throws -> CGFloat {
        try XCTUnwrap(previewItem(of: controller)).viewController.view.frame.width
    }

    /// The preview's share of the document split: 0.5 in an even split, 1 in
    /// reading, 0 with the render away.
    @MainActor
    private func splitFraction(of controller: MainWindowController) throws -> CGFloat {
        let split = try documentSplitViewController(of: controller).splitView
        let preview = try XCTUnwrap(previewItem(of: controller)).viewController.view
        let room = split.bounds.width - split.dividerThickness
        XCTAssertGreaterThan(room, 1, "the split has to be laid out")
        return preview.frame.width / room
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
            descendant(of: $0.viewController.view, ofType: NotaTextView.self) != nil
        }
    }

    /// A second Markdown file to open in a tab of its own — ⌘T makes an
    /// untitled note, which has no render until it is saved.
    private func makeMarkdownFile(named name: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A `.md` file holding real text — for the `@` headings-outline tests,
    /// which need something in the note to find headings in.
    private func markdownFile(contents: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("note.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
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
            if descendant(of: view, ofType: NotaTextView.self) != nil { return "workspace" }
            return "?"
        }
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

        let location = textView.convert(NSPoint(x: rect.minX + 2, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        // In reading mode the click goes through `NSTextView`, which tracks
        // the mouse in a loop of its own until the button comes back up: the
        // release is queued before the press so that loop has something to
        // end on. In split the click never reaches AppKit's tracking, so the
        // release is still sitting in the queue afterwards — it is taken back
        // out, or the next test's click would read it as a drag from here.
        window.postEvent(try event(.leftMouseUp), atStart: false)
        textView.mouseDown(with: try event(.leftMouseDown))
        while NSApp.nextEvent(
            matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true
        ) != nil {}
    }

    /// Where in the pane a piece of the rendered text is drawn: just inside
    /// its first glyph, or just past its last.
    @MainActor
    private func previewPoint(
        in textView: NSTextView, of text: String, atEnd: Bool = false
    ) throws -> NSPoint {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let range = (textView.string as NSString).range(of: text)
        try XCTSkipIf(range.location == NSNotFound, "\(text.debugDescription) is not in the pane")
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return NSPoint(x: atEnd ? rect.maxX - 2 : rect.minX + 2, y: rect.midY)
    }

    /// A press in the render that is not the plain single click above: a
    /// sweep across to another piece of text, or a double click.
    ///
    /// The drag and the release are queued before the press, since
    /// `NSTextView` answers a press by running its own tracking loop until
    /// the button comes back up — the reader's events are already in the
    /// queue when that loop starts looking, and a test's have to be too.
    @MainActor
    private func pressPreview(
        of controller: MainWindowController, on text: String,
        draggingTo target: String? = nil, clickCount: Int = 1
    ) throws {
        let window = try XCTUnwrap(controller.window)
        let preview = try previewView(of: controller)
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let down = textView.convert(try previewPoint(in: textView, of: text), to: nil)
        let up = try target.map {
            textView.convert(try previewPoint(in: textView, of: $0, atEnd: true), to: nil)
        } ?? down

        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            ))
        }

        if target != nil { window.postEvent(try event(.leftMouseDragged, at: up), atStart: false) }
        window.postEvent(try event(.leftMouseUp, at: up), atStart: false)
        textView.mouseDown(with: try event(.leftMouseDown, at: down))
        // Anything the tracking loop did not take is taken back out, or the
        // next press in this suite would read it as a drag from here.
        while NSApp.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged], until: nil,
            inMode: .default, dequeue: true
        ) != nil {}
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
            .appendingPathComponent("NotaPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
