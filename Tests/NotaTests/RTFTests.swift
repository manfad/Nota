import AppKit
import XCTest
@testable import Nota

/// The fourth viewer. An `.rtf` file or an `.rtfd` package opens in a tab of
/// its own and is read there, the way a PDF is: locked in reading, never
/// dirty, never cached and never written to — and, unlike the other three,
/// counted in words, because rich text is words on a page. See SPEC.md
/// "## RTF".
final class RTFTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What counts as rich text

    /// The bytes decide, not the name. `{\rtf` at the front is an RTF tab
    /// whatever the file is called, and a `.rtf` holding no such thing is
    /// plain text like any other file of prose.
    func testRichTextIsKnownByItsBytesAndNotByItsName() throws {
        let directory = try makeTemporaryDirectory()
        let rich = try write(rtfData(for: "hello"), named: "letter.rtf", in: directory)
        let disguised = try write(rtfData(for: "hello"), named: "letter.txt", in: directory)
        let impostor = try write(Data("just plain text, not rtf".utf8),
                                 named: "fake.rtf", in: directory)

        XCTAssertEqual(FileSniff.classify(at: rich), .rtf)
        XCTAssertEqual(FileSniff.classify(at: disguised), .rtf,
                       "a `.txt` whose bytes are RTF is rich text all the same")
        XCTAssertEqual(FileSniff.classify(at: impostor), .text,
                       "a `.rtf` that is not really RTF is the text it actually holds")
    }

    func testAnRTFDPackageIsRichTextByBeingOne() throws {
        let directory = try makeTemporaryDirectory()
        let package = try writeRTFD(for: "packaged", named: "doc.rtfd", in: directory)

        XCTAssertEqual(FileSniff.classify(at: package), .rtf)
        XCTAssertTrue(Note.isOpenable(package))
    }

    /// The drop path filters through `Note.isOpenable`, so a real RTF has to
    /// pass it for a dropped one to reach `open(url:)` at all.
    func testARealRTFIsOpenableAndTheExampleIsOne() throws {
        let directory = try makeTemporaryDirectory()
        let rich = try write(rtfData(for: "hello"), named: "letter.rtf", in: directory)

        XCTAssertTrue(Note.isOpenable(rich))
        XCTAssertTrue(Note.isOpenable(try example()),
                      "Examples/Rich.rtf is the checked-in example and must open")

        // And a `.rtf` that is really prose is openable too, as the prose it
        // is: the name is not a reason to refuse a file whose bytes read as
        // text. It is still not text to *edit*, so `isTextFile` says no —
        // that question is about the flat file, not about the drop.
        let impostor = try write(Data("not rtf at all".utf8), named: "fake.rtf", in: directory)
        XCTAssertTrue(Note.isOpenable(impostor))
        XCTAssertFalse(TextFile.isTextFile(at: rich), "a real RTF is not a note to edit")
    }

    // MARK: - Opening one

    @MainActor
    func testTheExampleOpensAsAReadingRTFTabThatIsNeverDirty() throws {
        let controller = try makeController(store: try makeStore())

        controller.open(url: try example())

        XCTAssertEqual(controller.openNotes.last?.title, "Rich.rtf")
        XCTAssertEqual(controller.currentTabState.kind, .rtf)
        XCTAssertEqual(controller.previewMode, .reading, "an RTF is the document and nothing else")
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertTrue(controller.previewPanes.showsRichText, "the document, not the render")
        XCTAssertFalse(controller.currentTabState.isDirty, "there is nothing to save")
        XCTAssertFalse(controller.currentTabIsSavable, "⌘S is not offered over rich text")
        XCTAssertFalse(controller.canShowRenderedPreview,
                       "there is no Markdown render behind a rich-text document")
    }

    /// A `.txt` whose bytes are RTF opens as rich text; a `.rtf` whose bytes
    /// are prose opens as an ordinary editable text tab. The same pair of
    /// files, decided by content in both directions.
    @MainActor
    func testTheNameOnlySaysHowAFileIsDrawnAndTheBytesSayWhatItIs() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(store: try makeStore())
        let disguised = try write(rtfData(for: "rich under a plain name"),
                                  named: "letter.txt", in: directory)
        let impostor = try write(Data("not rtf at all".utf8), named: "fake.rtf", in: directory)

        controller.open(url: disguised)
        XCTAssertEqual(controller.currentTabState.kind, .rtf)
        XCTAssertTrue(controller.previewPanes.showsRichText)

        controller.open(url: impostor)
        XCTAssertEqual(controller.currentTabState.kind, .text)
        XCTAssertEqual(controller.openNotes.last?.text, "not rtf at all")
        XCTAssertEqual(controller.openNotes.last?.fileURL?.standardizedFileURL,
                       impostor.standardizedFileURL,
                       "an ordinary text tab, bound to its own file")
    }

    @MainActor
    func testOpeningTheSameRTFAgainComesBackToTheTabItIsAlreadyIn() throws {
        let controller = try makeController(store: try makeStore())
        let rich = try example()

        controller.open(url: rich)
        let tabs = controller.openNotes.count
        let index = controller.selectedTabIndex
        controller.newTab()
        controller.open(url: rich)

        XCTAssertEqual(controller.openNotes.count, tabs + 1, "the ⌘T tab, and no second document")
        XCTAssertEqual(controller.selectedTabIndex, index)
        XCTAssertTrue(controller.previewPanes.showsRichText)
    }

    // MARK: - What is on screen

    /// The document's own formatting survives: this is a view of the file, not
    /// a re-rendering of its words. The example's first line is bold, so a
    /// bold run has to be in what the pane holds.
    @MainActor
    func testThePaneShowsTheAttributedDocumentWithItsBoldRunIntact() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try example())

        let pane = controller.previewPanes.rtf
        let shown = try XCTUnwrap(pane.shownContent)
        XCTAssertTrue(shown.string.contains("A rich text document"))
        XCTAssertTrue(pane.shownText.contains("A rich text document"),
                      "and it is in the text view, not only in the pane's copy")

        var isBold = false
        shown.enumerateAttribute(.font, in: NSRange(location: 0, length: shown.length)) {
            value, _, _ in
            guard let font = value as? NSFont else { return }
            if font.fontDescriptor.symbolicTraits.contains(.bold) { isBold = true }
        }
        XCTAssertTrue(isBold, "the document's own bold run is kept")
    }

    /// Black body text is drawn in `labelColor`, which is black in a light
    /// window and near-white in a dark one — an RTF is written for paper, and
    /// taking `\cf0` at its word would print black type onto a dark ground.
    /// A colour the author actually chose is left exactly as it was.
    func testBlackBodyTextBecomesLabelColourAndAChosenColourStands() throws {
        let red = NSColor(srgbRed: 0.8, green: 0.15, blue: 0.15, alpha: 1)
        let document = NSMutableAttributedString(
            string: "black ", attributes: [.foregroundColor: NSColor.black]
        )
        document.append(NSAttributedString(string: "red", attributes: [.foregroundColor: red]))

        let pane = RTFPreviewView()
        let shown = try XCTUnwrap(pane.preparedForTesting(document))

        XCTAssertEqual(shown.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.labelColor)
        XCTAssertEqual(
            shown.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor, red,
            "a word the author coloured keeps its colour in both appearances"
        )
    }

    /// ⌘+ scales the whole document — the type grows and the lines re-wrap to
    /// the column, the way ⌘+ grows a Markdown render, rather than the page
    /// being magnified as a picture of itself. ⌘- puts it back exactly.
    @MainActor
    func testZoomingScalesTheTypeAndComesBackToWhereItStarted() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try example())
        let pane = controller.previewPanes.rtf

        let plain = try firstFontSize(in: pane)
        pane.zoom = 2
        let doubled = try firstFontSize(in: pane)
        XCTAssertEqual(doubled, plain * 2, accuracy: 0.01)

        pane.zoom = 1
        XCTAssertEqual(try firstFontSize(in: pane), plain, accuracy: 0.01)
    }

    /// A file that has gone keeps its tab and says so, the same way a PDF's
    /// does — never a crash and never a tab of gibberish.
    @MainActor
    func testAnRTFWhoseFileHasGoneKeepsItsTabAndSaysSo() throws {
        let directory = try makeTemporaryDirectory()
        let store = try makeStore()
        let rich = try write(rtfData(for: "here for now"), named: "letter.rtf", in: directory)

        let opened = try makeController(store: store)
        opened.open(url: rich)
        opened.flushAll()

        try FileManager.default.removeItem(at: rich)

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: rich, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .rtf, "the tab is still there")
        XCTAssertFalse(relaunched.currentTabState.isDirty,
                       "a file that has gone is not an unsaved edit")
        XCTAssertTrue(relaunched.previewPanes.showsRichText)
        XCTAssertNil(relaunched.previewPanes.rtf.shownContent)
        XCTAssertEqual(relaunched.previewPanes.rtf.missingMessage,
                       "Couldn’t open “letter.rtf”.")
    }

    // MARK: - The session

    @MainActor
    func testAnRTFTabComesBackAsOneAtTheShareOfTheDocumentItWasLeftAt() throws {
        let store = try makeStore()
        // Long enough to have somewhere to be: a document that fits the column
        // has no scroll to remember.
        let rich = try write(
            rtfData(for: (1 ... 400).map { "Paragraph \($0)." }.joined(separator: "\n")),
            named: "long.rtf", in: try makeTemporaryDirectory()
        )

        let opened = try makeController(store: store)
        opened.open(url: rich)
        opened.previewPanes.rtf.scrollForTesting(to: 0.5)
        opened.flushAll()

        let state = try XCTUnwrap(store.load())
        let tab = try XCTUnwrap(state.tabs.first { $0.path == rich.path })
        XCTAssertEqual(tab.previewMode, .reading)
        XCTAssertNil(tab.format, "rich text has no encoding or line endings of Nota's choosing")
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(try XCTUnwrap(tab.scroll), 0.5, accuracy: 0.05,
                       "how far down the document the reader had got")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.cacheURL(for: tab.id).path),
            "nothing about a rich-text document belongs in the cache"
        )

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: rich, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .rtf)
        XCTAssertFalse(relaunched.currentTabState.isDirty)
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertTrue(relaunched.previewPanes.showsRichText)
        XCTAssertNotNil(relaunched.previewPanes.rtf.shownContent, "the file is read again")
        XCTAssertEqual(relaunched.currentTabScroll, 0.5, accuracy: 0.05)
    }

    // MARK: - The footer

    @MainActor
    func testTheFooterCountsTheDocumentsWordsAndHasNowhereToBe() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(store: try makeStore())
        let rich = try write(rtfData(for: "one two three four"),
                             named: "letter.rtf", in: directory)

        controller.open(url: rich)

        XCTAssertEqual(controller.footerRegions.counts.stringValue,
                       "4 words · 18 characters")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "",
                       "there is no caret in a document Nota does not edit")
        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "")
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "")

        // And back to the note's own counts the moment a text tab is in front.
        controller.newTab()
        XCTAssertEqual(controller.footerRegions.counts.stringValue, "0 words · 0 characters")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Ln 1, Col 1")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(store: SessionStore) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    private func makeStore() throws -> SessionStore {
        SessionStore(directory: try makeTemporaryDirectory())
    }

    @MainActor
    private func tabIndex(
        of url: URL, in controller: MainWindowController
    ) throws -> Int {
        try XCTUnwrap(
            controller.openNotes.firstIndex { $0.fileURL?.standardizedFileURL
                == url.standardizedFileURL },
            "\(url.lastPathComponent) is not open"
        )
    }

    /// The point size of the first run of type in the pane, which is what a
    /// zoom multiplies.
    @MainActor
    private func firstFontSize(in pane: RTFPreviewView) throws -> CGFloat {
        let shown = pane.laidOutContentForTesting
        var size: CGFloat?
        shown.enumerateAttribute(.font, in: NSRange(location: 0, length: shown.length)) {
            value, _, stop in
            guard let font = value as? NSFont else { return }
            size = font.pointSize
            stop.pointee = true
        }
        return try XCTUnwrap(size, "the document has type in it")
    }

    /// The checked-in example, beside the sources rather than written out by
    /// the test: it is what the reader opens to see the feature.
    private func example() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // NotaTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("Examples/Rich.rtf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Examples/Rich.rtf is checked in")
        return url
    }

    private func rtfData(for text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        return try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]
        ))
    }

    private func writeRTFD(for text: String, named name: String, in directory: URL) throws -> URL {
        let attributed = NSAttributedString(string: text)
        let wrapper = try XCTUnwrap(attributed.rtfdFileWrapper(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]
        ))
        let url = directory.appendingPathComponent(name)
        try wrapper.write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
