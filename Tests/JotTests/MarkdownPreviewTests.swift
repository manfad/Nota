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
        MarkdownRenderer.render(
            markdown, font: font ?? editorFont, assets: assets, width: width
        )
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

    func testAFencedBlockIsMonospacedOnAWashWithItsWhitespaceKept() throws {
        let rendered = render("```swift\nlet x = 1\n    indented\n```")
        XCTAssertEqual(rendered.string, "let x = 1\n    indented")
        let code = try attributes(rendered, at: "let x")
        let codeFont = try XCTUnwrap(code[.font] as? NSFont)
        XCTAssertTrue(codeFont.isFixedPitch, "fenced code is monospaced")
        XCTAssertEqual(codeFont.pointSize, 13, "at the editor's size")
        XCTAssertEqual(
            code[.backgroundColor] as? NSColor,
            NSColor.labelColor.withAlphaComponent(0.05)
        )
    }

    func testInlineCodeIsStyledLikeAFencedBlock() throws {
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
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        preview.layoutSubtreeIfNeeded()

        let long = (1 ... 200).map { "Line \($0)" }.joined(separator: "\n\n")
        preview.show(render(long))
        preview.follow(fraction: 0.5)
        XCTAssertEqual(preview.scrollFraction, 0.5, accuracy: 0.05)

        // Re-rendering the same note does not throw the reader back to the top.
        preview.show(render(long))
        XCTAssertEqual(preview.scrollFraction, 0.5, accuracy: 0.05)

        preview.follow(fraction: 1)
        XCTAssertEqual(preview.scrollFraction, 1, accuracy: 0.01)
        preview.follow(fraction: 0)
        XCTAssertEqual(preview.scrollFraction, 0, accuracy: 0.01)
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

    @MainActor
    func testTheViewMenuTogglesThePaneAndTheChoiceIsRemembered() throws {
        _ = NSApplication.shared
        try withPreviewPreference(false) {
            let controller = try makeController()
            XCTAssertFalse(controller.previewState.isVisible, "off until asked for")

            controller.toggleMarkdownPreview()
            XCTAssertTrue(controller.previewState.isVisible)
            XCTAssertTrue(Preferences.shared.showsMarkdownPreview, "written through")

            controller.toggleMarkdownPreview()
            XCTAssertFalse(controller.previewState.isVisible)
            XCTAssertFalse(Preferences.shared.showsMarkdownPreview)
        }
    }

    @MainActor
    func testAWindowOpensWithThePaneWhenTheSettingIsOn() throws {
        _ = NSApplication.shared
        try withPreviewPreference(true) {
            let controller = try makeController()
            XCTAssertTrue(
                controller.previewState.isVisible,
                "the pane comes back the way it was left"
            )
            XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        }
    }

    @MainActor
    func testAHiddenPaneIsCollapsedRatherThanRemoved() throws {
        _ = NSApplication.shared
        try withPreviewPreference(false) {
            let controller = try makeController()
            XCTAssertEqual(previewItem(of: controller)?.isCollapsed, true)
            XCTAssertEqual(previewItem(of: controller)?.minimumThickness, 240)
            XCTAssertEqual(previewItem(of: controller)?.preferredThicknessFraction, 0.5)
        }
    }

    @MainActor
    func testThePaneSitsBetweenTheEditorAndTheImageSidebar() throws {
        _ = NSApplication.shared
        let previousSide = Preferences.shared.sidebarSide
        defer { Preferences.shared.sidebarSide = previousSide }

        try withPreviewPreference(true) {
            for side in [SidebarSide.right, .left] {
                Preferences.shared.sidebarSide = side
                let controller = try makeController()
                let roles = try splitRoles(of: controller)
                XCTAssertEqual(
                    roles,
                    side == .right
                        ? ["editor", "preview", "sidebar"]
                        : ["sidebar", "editor", "preview"],
                    "the images stay outermost on the \(side.title)"
                )
            }
        }
    }

    @MainActor
    func testZenTakesThePaneAwayAndGivesItBack() throws {
        _ = NSApplication.shared
        try withPreviewPreference(true) {
            let controller = try makeController()
            XCTAssertTrue(controller.previewState.isVisible)

            controller.toggleZenMode()
            XCTAssertFalse(controller.previewState.isVisible, "the pane is chrome in zen")
            XCTAssertEqual(previewItem(of: controller)?.isCollapsed, true)

            controller.toggleZenMode()
            XCTAssertTrue(controller.previewState.isVisible, "and comes back after it")
            XCTAssertEqual(previewItem(of: controller)?.isCollapsed, false)
        }
    }

    @MainActor
    func testTogglingThePaneLeavesTheCaretInTheEditor() throws {
        _ = NSApplication.shared
        try withPreviewPreference(false) {
            let controller = try makeController()
            let window = try XCTUnwrap(controller.window)
            controller.focusEditor()

            controller.toggleMarkdownPreview()
            XCTAssertTrue(
                window.firstResponder is JotTextView,
                "the pane is read, not typed in"
            )
            controller.toggleMarkdownPreview()
            XCTAssertTrue(window.firstResponder is JotTextView)
        }
    }

    @MainActor
    func testTypingReRendersThePaneOnceTheKeystrokesStop() throws {
        _ = NSApplication.shared
        try withPreviewPreference(true) {
            let controller = try makeController()
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
    }

    @MainActor
    func testSwitchingTabsRendersTheTabYouLandOn() throws {
        _ = NSApplication.shared
        try withPreviewPreference(true) {
            let controller = try makeController()
            let window = try XCTUnwrap(controller.window)
            let editor = try XCTUnwrap(
                descendant(of: try XCTUnwrap(window.contentView), ofType: JotTextView.self)
            )
            editor.insertText("## First tab", replacementRange: editor.selectedRange())
            waitForDebounce()
            XCTAssertEqual(controller.previewState.renderedText, "First tab")

            controller.newTab()
            XCTAssertEqual(controller.previewState.renderedText, "", "the new tab is empty")

            controller.selectTab(at: 0)
            XCTAssertEqual(
                controller.previewState.renderedText, "First tab",
                "switching back re-renders straight away, without waiting"
            )
        }
    }

    @MainActor
    func testAHiddenPaneIsNotRenderedAtAll() throws {
        _ = NSApplication.shared
        try withPreviewPreference(false) {
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
    }

    // MARK: - Helpers

    @MainActor
    private func makeController() throws -> MainWindowController {
        let controller = MainWindowController(store: SessionStore(
            directory: try makeTemporaryDirectory()
        ))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// The preview lives in `UserDefaults`, so a test that changes it has to
    /// put it back the way it found it.
    private func withPreviewPreference(_ value: Bool, _ body: () throws -> Void) rethrows {
        let previous = Preferences.shared.showsMarkdownPreview
        defer { Preferences.shared.showsMarkdownPreview = previous }
        Preferences.shared.showsMarkdownPreview = value
        try body()
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
    private func previewItem(of controller: MainWindowController) -> NSSplitViewItem? {
        try? splitViewController(of: controller).splitViewItems.first {
            descendant(of: $0.viewController.view, ofType: MarkdownPreviewView.self) != nil
        }
    }

    /// What each split item holds, in order.
    @MainActor
    private func splitRoles(of controller: MainWindowController) throws -> [String] {
        try splitViewController(of: controller).splitViewItems.map { item in
            let view = item.viewController.view
            if descendant(of: view, ofType: MarkdownPreviewView.self) != nil { return "preview" }
            if descendant(of: view, ofType: ImageSidebarView.self) != nil { return "sidebar" }
            if descendant(of: view, ofType: JotTextView.self) != nil { return "editor" }
            return "?"
        }
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
