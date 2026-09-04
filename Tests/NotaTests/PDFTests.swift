import AppKit
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import Nota

/// The one binary Nota opens. A PDF is a tab like any other — it is in the
/// strip, ⌘W closes it, the session brings it back — and unlike any other it
/// is read rather than edited: locked in reading, never dirty, never cached
/// and never written to.
final class PDFTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What counts as a PDF

    func testAPDFIsKnownByItsSpellingWhateverCaseItIsIn() throws {
        XCTAssertTrue(Note.isPDFFile(URL(fileURLWithPath: "/tmp/paper.pdf")))
        XCTAssertTrue(Note.isPDFFile(URL(fileURLWithPath: "/tmp/PAPER.PDF")))
        XCTAssertTrue(Note.isPDFFile(URL(fileURLWithPath: "/tmp/Mixed.Pdf")))
        XCTAssertFalse(Note.isPDFFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(Note.isPDFFile(URL(fileURLWithPath: "/tmp/notes.md")))
        XCTAssertFalse(Note.isPDFFile(URL(fileURLWithPath: "/tmp/pdf")))
    }

    /// Text, a document and a picture all open in a tab; a file that is none
    /// of the three does not.
    func testWhatOpensInATabIsTextADocumentOrAPicture() throws {
        let directory = try makeTemporaryDirectory()
        let pdf = try makePDF(pages: 1, named: "paper.pdf", in: directory)
        let text = directory.appendingPathComponent("notes.md")
        let image = directory.appendingPathComponent("photo.png")
        let archive = directory.appendingPathComponent("bundle.zip")
        try Data("# hi".utf8).write(to: text)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: archive)

        XCTAssertTrue(Note.isOpenable(pdf))
        XCTAssertTrue(Note.isOpenable(text))
        XCTAssertTrue(Note.isOpenable(image), "a picture is a tab of its own")
        XCTAssertFalse(Note.isOpenable(archive))
        // And the PDF is not text: reading it as one is what used to come
        // back as an empty dirty tab.
        XCTAssertFalse(TextFile.isTextFile(at: pdf))
    }

    func testAPDFDroppedOnTheWindowIsOneOfTheFilesToOpen() throws {
        let directory = try makeTemporaryDirectory()
        let pdf = try makePDF(pages: 1, named: "paper.pdf", in: directory)
        let image = directory.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: image)

        let pasteboard = NSPasteboard(name: .init("NotaPDFTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf, image].map { $0 as NSURL })

        XCTAssertEqual(
            NotaTextView.openableFiles(on: pasteboard).map(\.lastPathComponent),
            ["paper.pdf"],
            "dropped into the text the PDF opens as a tab and the picture is "
                + "still the asset store's, whatever either would do elsewhere"
        )
    }

    // MARK: - Opening one

    @MainActor
    func testOpeningAPDFAddsAReadingTabShowingTheDocument() throws {
        let store = try makeStore()
        let controller = try makeController(store: store)
        let pdf = try makePDF(pages: 3, named: "paper.pdf", in: try makeTemporaryDirectory())

        controller.open(url: pdf)

        XCTAssertEqual(controller.openNotes.last?.title, "paper.pdf")
        XCTAssertEqual(controller.selectedTabIndex, controller.openNotes.count - 1)
        XCTAssertEqual(controller.previewMode, .reading, "a PDF is the page and nothing else")
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertTrue(controller.previewPanes.showsPDF, "the document, not the render")
        XCTAssertEqual(controller.previewPanes.pdf.pageCount, 3)
        XCTAssertFalse(controller.currentTabState.isDirty, "there is nothing to save")
        XCTAssertEqual(controller.currentTabState.kind, .pdf)
    }

    @MainActor
    func testAPDFTabHasNoModeControlAndNeitherViewMenuItem() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makePDF(pages: 1, named: "paper.pdf",
                                         in: try makeTemporaryDirectory()))

        XCTAssertFalse(controller.canShowRenderedPreview,
                       "there is no Markdown render behind a PDF")
        let (editor, preview) = controller.modeControlOverlays
        XCTAssertTrue(editor.isHidden, "no control in the collapsed editor column")
        XCTAssertTrue(preview.isHidden, "and none over the page either")
    }

    @MainActor
    func testAskingAPDFTabForAnotherModeDoesNothing() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makePDF(pages: 2, named: "paper.pdf",
                                         in: try makeTemporaryDirectory()))

        controller.setPreviewMode(.off)
        XCTAssertEqual(controller.previewMode, .reading)
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .reading)
        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertTrue(controller.previewPanes.showsPDF)
    }

    @MainActor
    func testOpeningTheSamePDFAgainComesBackToTheTabItIsAlreadyIn() throws {
        let controller = try makeController(store: try makeStore())
        let pdf = try makePDF(pages: 1, named: "paper.pdf", in: try makeTemporaryDirectory())

        controller.open(url: pdf)
        let tabs = controller.openNotes.count
        let index = controller.selectedTabIndex
        controller.newTab()
        controller.open(url: pdf)

        XCTAssertEqual(controller.openNotes.count, tabs + 1, "the ⌘T tab, and no second PDF")
        XCTAssertEqual(controller.selectedTabIndex, index)
        XCTAssertTrue(controller.previewPanes.showsPDF)
    }

    // MARK: - Beside a Markdown tab

    @MainActor
    func testSwitchingBetweenAReadingMarkdownTabAndAPDFSwapsThePane() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(store: try makeStore())
        let markdown = directory.appendingPathComponent("notes.md")
        try "# Heading\n\nA paragraph.".write(to: markdown, atomically: true, encoding: .utf8)
        let pdf = try makePDF(pages: 2, named: "paper.pdf", in: directory)

        controller.open(url: markdown)
        controller.setPreviewMode(.reading)
        let markdownTab = controller.selectedTabIndex
        XCTAssertFalse(controller.previewPanes.showsPDF)
        XCTAssertTrue(controller.previewState.renderedText.contains("Heading"))

        controller.open(url: pdf)
        let pdfTab = controller.selectedTabIndex
        // The mode never moved — both tabs are in reading — so the swap
        // cannot be something only a mode change does.
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertTrue(controller.previewPanes.showsPDF)

        controller.selectTab(at: markdownTab)
        XCTAssertFalse(controller.previewPanes.showsPDF, "the render is back")
        XCTAssertTrue(controller.previewState.renderedText.contains("Heading"))

        controller.selectTab(at: pdfTab)
        XCTAssertTrue(controller.previewPanes.showsPDF)
    }

    // MARK: - The session

    @MainActor
    func testAPDFTabComesBackOnThePageItWasLeftOn() throws {
        let directory = try makeTemporaryDirectory()
        let store = try makeStore()
        let pdf = try makePDF(pages: 4, named: "paper.pdf", in: directory)

        let opened = try makeController(store: store)
        opened.open(url: pdf)
        opened.previewPanes.pdf.currentPageIndex = 2
        opened.flushAll()

        let state = try XCTUnwrap(store.load())
        let tab = try XCTUnwrap(state.tabs.first { $0.path == pdf.path })
        XCTAssertEqual(tab.previewMode, .reading)
        XCTAssertNil(tab.format, "a PDF has no encoding or line endings")
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.selection, 2, "the page is where the tab was left")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.cacheURL(for: tab.id).path),
            "nothing about a PDF belongs in the cache"
        )

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: pdf, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .pdf)
        XCTAssertFalse(relaunched.currentTabState.isDirty)
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertNotNil(relaunched.previewPanes.pdf.shownDocument, "the file is read again")
        XCTAssertEqual(relaunched.previewPanes.pdf.pageCount, 4)
        XCTAssertEqual(relaunched.currentTabState.selection, 2)
    }

    @MainActor
    func testARestoredPDFWhoseFileHasGoneKeepsItsTabAndSaysSo() throws {
        let directory = try makeTemporaryDirectory()
        let store = try makeStore()
        let pdf = try makePDF(pages: 2, named: "paper.pdf", in: directory)

        let opened = try makeController(store: store)
        opened.open(url: pdf)
        opened.flushAll()

        try FileManager.default.removeItem(at: pdf)

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: pdf, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .pdf, "the tab is still there")
        XCTAssertFalse(relaunched.currentTabState.isDirty,
                       "a file that has gone is not an unsaved edit")
        XCTAssertTrue(relaunched.previewPanes.showsPDF)
        XCTAssertNil(relaunched.previewPanes.pdf.shownDocument)
        XCTAssertEqual(relaunched.previewPanes.pdf.missingMessage,
                       "Couldn’t open “paper.pdf”.")
    }

    // MARK: - The footer

    func testThePageCountsAreSpelledOutTheWayTheFooterSaysThem() {
        XCTAssertEqual(TextStats.pageCounts(0), "0 pages")
        XCTAssertEqual(TextStats.pageCounts(1), "1 page")
        XCTAssertEqual(TextStats.pageCounts(12), "12 pages")
        XCTAssertEqual(TextStats.pagePosition(current: 1, total: 12), "Page 1 of 12")
        XCTAssertEqual(TextStats.pagePosition(current: 12, total: 12), "Page 12 of 12")
    }

    @MainActor
    func testTheFooterCountsPagesAndSaysWhichOneIsInFront() throws {
        let controller = try makeController(store: try makeStore())
        let pdf = try makePDF(pages: 3, named: "paper.pdf", in: try makeTemporaryDirectory())
        controller.open(url: pdf)

        XCTAssertEqual(controller.footerRegions.counts.stringValue, "3 pages")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Page 1 of 3")

        // And back to words the moment a text tab is in front.
        controller.newTab()
        XCTAssertEqual(controller.footerRegions.counts.stringValue, "0 words · 0 characters")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Ln 1, Col 1")
    }

    /// A PDF has no encoding or line endings — Todo 2's field is empty there,
    /// the same way the counts and the caret position are their own thing.
    @MainActor
    func testTheEncodingAndLineEndingFieldIsEmptyOverAPDFTab() throws {
        let controller = try makeController(store: try makeStore())
        let pdf = try makePDF(pages: 1, named: "paper.pdf", in: try makeTemporaryDirectory())
        controller.open(url: pdf)

        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "")
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "")

        // And back the moment a text tab is in front.
        controller.newTab()
        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "UTF-8")
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "LF")
    }

    // MARK: - Nothing to save

    @MainActor
    func testSavingAPDFTabDoesNothingAtAll() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(store: try makeStore())
        let pdf = try makePDF(pages: 2, named: "paper.pdf", in: directory)
        let original = try Data(contentsOf: pdf)

        controller.open(url: pdf)
        XCTAssertFalse(controller.currentTabIsSavable, "⌘S and ⇧⌘S are greyed out")
        controller.saveCurrent(forcePanel: false)
        XCTAssertFalse(controller.vimSave(name: nil), ":w has nothing to write")

        XCTAssertEqual(try Data(contentsOf: pdf), original, "the file is untouched")
        XCTAssertFalse(controller.currentTabState.isDirty)
    }

    // MARK: - ⌘F in the document

    /// ⌘F over a PDF is the same pill it is everywhere else, floating in the
    /// document's own column. The editor is collapsed behind it and its bar
    /// stays where it is.
    @MainActor
    func testCommandFOverAPDFOpensThePillInTheDocumentsColumn() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeTextPDF(pages: ["alpha beta"], named: "paper.pdf",
                                             in: try makeTemporaryDirectory()))
        let (pdfView, bar) = try findChrome(of: controller)
        XCTAssertEqual(bar.field.placeholderString, "Find in document")
        XCTAssertFalse(bar.isShown)
        XCTAssertFalse(bar.canReplace, "there is nothing in a document to replace")

        XCTAssertTrue(pdfView.validateUserInterfaceItem(finderItem(.showFindInterface)),
                      "the menu item has to stay enabled or ⌘F never arrives here")
        pdfView.performTextFinderAction(finderItem(.showFindInterface))

        XCTAssertTrue(bar.isShown)
        XCTAssertTrue(controller.previewPanes.pdf.isFindBarVisible)
        XCTAssertEqual(controller.previewMode, .reading, "the search happens where you are")
        // One bar in the window is up, and it is the document's.
        let shown = allFindBars(in: controller).filter(\.isShown)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first === bar, "the editor's own bar stayed down")
    }

    /// Typing searches the document as you go: every match wears a band, the
    /// one being stood on wears the loud one and is the page's selection, and
    /// the count says where in the document it is.
    @MainActor
    func testTypingSearchesTheDocumentAndLandsOnTheFirstMatch() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeAlphaPDF())
        let (pdfView, bar) = try findChrome(of: controller)
        pdfView.performTextFinderAction(finderItem(.showFindInterface))

        type("alpha", into: bar)

        XCTAssertEqual(bar.status, "1 of 3")
        XCTAssertEqual(pdfView.currentSelection?.string?.lowercased(), "alpha",
                       "the match is the page's own selection")
        let bands = try XCTUnwrap(pdfView.highlightedSelections)
        XCTAssertEqual(bands.count, 3, "every match wears one")
        XCTAssertEqual(bands.filter { $0.color == .findHighlightColor }.count, 1,
                       "and exactly one of them is the loud one")
        let session = try XCTUnwrap(pdfView.findSession)
        XCTAssertEqual(session.matches.count, 3)
        XCTAssertFalse(session.isCapped)
        // Case- and diacritic-insensitive, the same as the editor's bar.
        type("ALPHA", into: bar)
        XCTAssertEqual(bar.status, "1 of 3")
    }

    /// ⌘G walks the matches and wraps round the end of the document; ⇧⌘G
    /// walks them back. Both work in a document of more than one page.
    @MainActor
    func testCommandGStepsThroughTheDocumentAndWraps() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeAlphaPDF())
        let (pdfView, bar) = try findChrome(of: controller)
        pdfView.performTextFinderAction(finderItem(.showFindInterface))
        type("alpha", into: bar)
        XCTAssertEqual(bar.status, "1 of 3")

        pdfView.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(bar.status, "2 of 3")
        pdfView.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(bar.status, "3 of 3")
        XCTAssertEqual(controller.previewPanes.pdf.currentPageIndex, 1,
                       "the third is on the second page, and the reader went there")

        pdfView.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(bar.status, "1 of 3", "round the end")
        pdfView.performTextFinderAction(finderItem(.previousMatch))
        XCTAssertEqual(bar.status, "3 of 3", "and round the other way")
        pdfView.performTextFinderAction(finderItem(.previousMatch))
        XCTAssertEqual(bar.status, "2 of 3")
    }

    /// Escape puts the bands down and hands the match over: it stays selected
    /// on the page, and the keyboard goes back to the document.
    @MainActor
    func testEscapeClosesTheBarAndLeavesTheMatchSelected() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeAlphaPDF())
        let (pdfView, bar) = try findChrome(of: controller)
        pdfView.performTextFinderAction(finderItem(.showFindInterface))
        type("alpha", into: bar)
        XCTAssertNotNil(pdfView.highlightedSelections)

        pdfView.performTextFinderAction(finderItem(.hideFindInterface))

        XCTAssertFalse(bar.isShown)
        XCTAssertFalse(controller.previewPanes.pdf.isFindBarVisible)
        XCTAssertNil(pdfView.highlightedSelections, "the bands are down")
        XCTAssertEqual(pdfView.currentSelection?.string?.lowercased(), "alpha",
                       "and the match the reader was on is theirs")
        let responder = controller.window?.firstResponder as? NSView
        XCTAssertTrue(responder === pdfView || responder?.isDescendant(of: pdfView) == true,
                      "the keyboard went back to the document")
        // The query outlives the bar, so ⌘G keeps walking with it closed.
        pdfView.performTextFinderAction(finderItem(.nextMatch))
        XCTAssertEqual(bar.status, "2 of 3")
    }

    /// ⌘E takes the query from what is selected on the page, and puts it on
    /// the find pasteboard the way the editor's does.
    @MainActor
    func testUseSelectionForFindSeedsTheQueryFromThePage() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeAlphaPDF())
        let (pdfView, bar) = try findChrome(of: controller)
        let document = try XCTUnwrap(pdfView.document)
        let selection = try XCTUnwrap(
            document.findString("gamma", withOptions: [.caseInsensitive]).first
        )
        pdfView.setCurrentSelection(selection, animate: false)

        pdfView.performTextFinderAction(finderItem(.setSearchString))

        XCTAssertEqual(bar.query.lowercased(), "gamma")
        XCTAssertEqual(NSPasteboard(name: .find).string(forType: .string)?.lowercased(), "gamma")
        XCTAssertFalse(bar.isShown, "⌘E does not open the bar")
        // And ⌘F now comes up holding it.
        pdfView.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertEqual(bar.status, "1 of 1")
    }

    /// A query the document does not hold says so, and lights nothing.
    @MainActor
    func testAQueryWithNoHitsSaysNoMatches() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeAlphaPDF())
        let (pdfView, bar) = try findChrome(of: controller)
        pdfView.performTextFinderAction(finderItem(.showFindInterface))

        type("zeta", into: bar)

        XCTAssertEqual(bar.status, "No matches")
        XCTAssertNil(pdfView.highlightedSelections)
        XCTAssertEqual(try XCTUnwrap(pdfView.findSession).matches.count, 0)
    }

    /// Find, Find Next, Find Previous and Use Selection all mean something
    /// over a page. Find and Replace… does not: there is nothing to replace.
    @MainActor
    func testFindAndReplaceIsTheOneFindItemAPDFTurnsDown() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeAlphaPDF())
        let (pdfView, _) = try findChrome(of: controller)

        for action in [NSTextFinder.Action.showFindInterface, .hideFindInterface,
                       .nextMatch, .previousMatch, .setSearchString] {
            XCTAssertTrue(pdfView.validateUserInterfaceItem(finderItem(action)),
                          "\(action) belongs over a document")
        }
        for action in [NSTextFinder.Action.showReplaceInterface, .replace, .replaceAll] {
            XCTAssertFalse(pdfView.validateUserInterfaceItem(finderItem(action)),
                           "\(action) has nothing to act on")
        }
        // And the pill's own field says the same, so ⌥⌘F is greyed out while
        // the reader is typing in it too.
        let bar = try findChrome(of: controller).bar
        XCTAssertFalse(bar.handles(.showReplaceInterface))
        XCTAssertTrue(bar.handles(.nextMatch))
    }

    // MARK: - How big the page is drawn

    /// A page smaller than the column is drawn at actual size, not blown up
    /// to fill it. `autoScales` would have made this one 3×.
    @MainActor
    func testANarrowPageInAWideWindowIsDrawnAtActualSize() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeTextPDF(pages: ["alpha beta"], named: "narrow.pdf",
                                             in: try makeTemporaryDirectory(),
                                             size: NSSize(width: 300, height: 400)))
        let pane = controller.previewPanes.pdf
        try XCTUnwrap(controller.window).layoutIfNeeded()

        XCTAssertGreaterThan(pane.bounds.width, 600, "the column is much wider than the page")
        XCTAssertGreaterThan(pane.scaleFactorToFit, 1.5,
                             "autoScales would have drawn this page half again past actual size")
        XCTAssertEqual(pane.scaleFactor, 1, accuracy: 0.001,
                       "paper has a size of its own; past 100% it is being magnified")
    }

    /// A page wider than the column still shrinks to fit it — the cap is
    /// one-sided, since a page that will not fit has to give way.
    @MainActor
    func testAWidePageInANarrowWindowIsShrunkToFit() throws {
        let controller = try makeKeyController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 700, height: 560))
        window.layoutIfNeeded()
        controller.open(url: try makeTextPDF(pages: ["alpha beta"], named: "wide.pdf",
                                             in: try makeTemporaryDirectory(),
                                             size: NSSize(width: 2400, height: 1200)))
        window.layoutIfNeeded()
        let pane = controller.previewPanes.pdf

        XCTAssertLessThan(pane.bounds.width, 2400)
        XCTAssertLessThan(pane.scaleFactor, 1, "it has to give way to fit")
        XCTAssertGreaterThan(pane.scaleFactor, 0, "and it is still drawn")
        XCTAssertLessThanOrEqual(2400 * pane.scaleFactor, pane.bounds.width + 1,
                                 "the whole width of the page is in the column")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(store: SessionStore) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    private func makeStore() throws -> SessionStore {
        SessionStore(directory: try makeTemporaryDirectory())
    }

    /// Which tab a file came back in — a restored session keeps the order it
    /// was written in, but nothing here should depend on that.
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

    /// A real PDF, made by PDFKit rather than checked in: a few blank pages
    /// of a believable size, written to a file the way any other one is.
    private func makePDF(pages: Int, named name: String, in directory: URL) throws -> URL {
        let document = PDFDocument()
        for index in 0 ..< pages {
            let page = PDFPage()
            page.setBounds(NSRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url), "the fixture has to be a real PDF")
        return url
    }

    /// A controller whose window is key and laid out, without a frame of it
    /// reaching the screen: the find bar needs a first responder, and the
    /// suite is not a thing anybody asked to watch.
    @MainActor
    private func makeKeyController() throws -> MainWindowController {
        let controller = try makeController(store: try makeStore())
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    /// The document's view and its pill, which is all a find test reaches for.
    @MainActor
    private func findChrome(
        of controller: MainWindowController
    ) throws -> (pdfView: NotaPDFView, bar: FindBarView) {
        let pane = controller.previewPanes.pdf
        return (try XCTUnwrap(descendant(of: pane, ofType: NotaPDFView.self)),
                try XCTUnwrap(descendant(of: pane, ofType: FindBarView.self)))
    }

    /// Every find pill in the window — the editor's, the render's and the
    /// document's — so a test can say which one of them came up.
    @MainActor
    private func allFindBars(in controller: MainWindowController) -> [FindBarView] {
        guard let root = controller.window?.contentView else { return [] }
        var found: [FindBarView] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let bar = view as? FindBarView { found.append(bar) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// A Find menu item as the menu builds it: nil-targeted, with the action
    /// in its tag.
    private func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(NSTextView.performTextFinderAction(_:))
        item.tag = action.rawValue
        return item
    }

    /// The reader typing in the field, which is what drives an incremental
    /// search.
    private func type(_ query: String, into bar: FindBarView) {
        bar.query = query
        bar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: bar.field)
        )
    }

    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    /// Three `alpha`s over two pages, with something else to search for on
    /// each: the fixture every stepping test walks.
    private func makeAlphaPDF() throws -> URL {
        try makeTextPDF(
            pages: ["alpha beta", "gamma alpha\ndelta alpha"],
            named: "paper.pdf", in: try makeTemporaryDirectory()
        )
    }

    /// A real PDF with real extractable text, drawn rather than checked in:
    /// each string is laid into a page of a `CGPDFContext` with Core Text, so
    /// PDFKit reads back words rather than the blank paper `makePDF` writes.
    private func makeTextPDF(
        pages: [String], named name: String, in directory: URL,
        size: NSSize = NSSize(width: 300, height: 400)
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(
            CGContext(url as CFURL, mediaBox: &box, nil), "the fixture has to be a real PDF"
        )
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor.black,
                ]
            )
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: box.insetBy(dx: 24, dy: 24), transform: nil)
            let frame = CTFramesetterCreateFrame(
                setter, CFRange(location: 0, length: 0), path, nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
